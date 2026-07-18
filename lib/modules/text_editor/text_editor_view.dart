import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../../providers/text_editor_state.dart';
import 'utils/file_type_groups.dart';
import 'utils/highlight_text_controller.dart';
import 'widgets/diff_view.dart';
import 'widgets/patch_dialog.dart';

/// Main view for the Text Editor / Diff-Patch module.
///
/// Provides two editable text panes (Original / Modified), a toolbar to load
/// files, compare them, save the resulting patch, and apply a patch to a file.
class TextEditorView extends StatelessWidget {
  const TextEditorView({super.key});

  @override
  Widget build(BuildContext context) {
    return const _TextEditorBody();
  }
}

class _TextEditorBody extends StatelessWidget {
  const _TextEditorBody();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TextEditorState>();
    final hasContent = state.originalContent.isNotEmpty || state.modifiedContent.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(context, state),
        const SizedBox(height: 8),
        if (state.hasCompared && state.diffResult.isNotEmpty)
          Container(
            color: const Color(0xFF252525),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                _diffStat(
                  label: '删除',
                  count: state.diffResult.where((l) => l.isDelete).length,
                  color: Colors.redAccent,
                ),
                const SizedBox(width: 16),
                _diffStat(
                  label: '新增',
                  count: state.diffResult.where((l) => l.isInsert).length,
                  color: Colors.green,
                ),
                const SizedBox(width: 16),
                _diffStat(
                  label: '相同',
                  count: state.diffResult.where((l) => l.isEqual).length,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        if (state.hasCompared && state.diffResult.isNotEmpty) const SizedBox(height: 8),
        Expanded(
          child: state.hasCompared
              ? DiffView(
              diffLines: state.diffResult,
              originalPath: state.originalPath,
              modifiedPath: state.modifiedPath,
            )
              : hasContent
                  ? _buildSplitEditor(context, state)
                  : const _EmptyPlaceholder(),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, TextEditorState state) {
    return Container(
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _ToolbarButton(
            icon: Icons.folder_open,
            label: '打开原文件',
            onPressed: () => _pickOriginalFile(context, state),
          ),
          _ToolbarButton(
            icon: Icons.folder_open_outlined,
            label: '打开修改文件',
            onPressed: () => _pickModifiedFile(context, state),
          ),
          _ToolbarButton(
            icon: Icons.compare_arrows,
            label: '比较差异',
            onPressed: state.originalContent.isNotEmpty || state.modifiedContent.isNotEmpty
                ? () => state.compare()
                : null,
          ),
          _ToolbarButton(
            icon: Icons.save_alt,
            label: '保存补丁',
            onPressed: state.diffResult.isNotEmpty ? () => _savePatch(context, state) : null,
          ),
          _ToolbarButton(
            icon: Icons.healing,
            label: '应用补丁',
            onPressed: () => _applyPatch(context),
          ),
          _ToolbarButton(
            icon: Icons.undo,
            label: '回退补丁',
            onPressed: () => _revertPatch(context),
          ),
          _ToolbarButton(
            icon: Icons.clear_all,
            label: '清空',
            onPressed: state.hasContent ? () => state.clear() : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSplitEditor(BuildContext context, TextEditorState state) {
    return Row(
      children: [
        Expanded(
          child: _TextPane(
            title: '原文件',
            path: state.originalPath,
            content: state.originalContent,
            onChanged: state.setOriginalContent,
          ),
        ),
        Container(width: 1, color: Colors.grey.shade800),
        Expanded(
          child: _TextPane(
            title: '修改后',
            path: state.modifiedPath,
            content: state.modifiedContent,
            onChanged: state.setModifiedContent,
          ),
        ),
      ],
    );
  }

  Widget _diffStat({required String label, required int count, required Color color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text('$label: $count', style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }

  Future<void> _pickOriginalFile(BuildContext context, TextEditorState state) async {
    try {
      final file = await openFile(acceptedTypeGroups: kTextEditorFileGroups);
      if (file != null) {
        await state.loadOriginalFile(file.path);
      }
    } catch (e) {
      if (!context.mounted) return;
      _showSnackBar(context, '打开原文件失败: $e', Colors.redAccent);
    }
  }

  Future<void> _pickModifiedFile(BuildContext context, TextEditorState state) async {
    try {
      final file = await openFile(acceptedTypeGroups: kTextEditorFileGroups);
      if (file != null) {
        await state.loadModifiedFile(file.path);
      }
    } catch (e) {
      if (!context.mounted) return;
      _showSnackBar(context, '打开修改文件失败: $e', Colors.redAccent);
    }
  }

  Future<void> _savePatch(BuildContext context, TextEditorState state) async {
    const XTypeGroup patchType = XTypeGroup(
      label: 'Patch Files (*.patch, *.diff)',
      extensions: ['patch', 'diff'],
    );
    const XTypeGroup allType = XTypeGroup(label: 'All Files', extensions: []);

    try {
      final now = DateTime.now();
      final timestamp = '${now.year.toString().padLeft(4, '0')}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';

      final String suggestedName;
      String? initialDirectory;
      if (state.originalPath != null && state.modifiedPath != null) {
        final originalName = p.basenameWithoutExtension(state.originalPath!);
        final modifiedName = p.basenameWithoutExtension(state.modifiedPath!);
        suggestedName = '${originalName}_patch_to_${modifiedName}_$timestamp.patch';

        final originalDir = p.dirname(state.originalPath!);
        final patchDir = p.join(originalDir, 'patch');
        await Directory(patchDir).create(recursive: true);
        initialDirectory = patchDir;
      } else {
        suggestedName = 'changes_$timestamp.patch';
      }

      final location = await getSaveLocation(
        initialDirectory: initialDirectory,
        acceptedTypeGroups: [patchType, allType],
        suggestedName: suggestedName,
      );
      if (location != null) {
        await state.savePatch(location.path);
        if (context.mounted) {
          _showSnackBar(context, '补丁已保存至 ${location.path}', Colors.green);
        }
      }
    } catch (e) {
      if (context.mounted) {
        _showSnackBar(context, '保存补丁失败: $e', Colors.redAccent);
      }
    }
  }

  Future<void> _applyPatch(BuildContext context) async {
    final applied = await showPatchApplyDialog(context);
    if (applied && context.mounted) {
      _showSnackBar(context, '补丁应用成功', Colors.green);
    }
  }

  Future<void> _revertPatch(BuildContext context) async {
    final reverted = await showPatchApplyDialog(context, revertMode: true);
    if (reverted && context.mounted) {
      _showSnackBar(context, '补丁回退成功', Colors.green);
    }
  }

  void _showSnackBar(BuildContext context, String message, Color backgroundColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(backgroundColor: backgroundColor, content: Text(message)),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16, color: onPressed != null ? Colors.cyanAccent : Colors.grey),
      label: Text(label, style: TextStyle(color: onPressed != null ? Colors.cyanAccent : Colors.grey, fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF333333),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        disabledBackgroundColor: const Color(0xFF2A2A2A),
      ),
    );
  }
}

class _TextPane extends StatefulWidget {
  final String title;
  final String? path;
  final String content;
  final ValueChanged<String> onChanged;

  const _TextPane({
    required this.title,
    this.path,
    required this.content,
    required this.onChanged,
  });

  @override
  State<_TextPane> createState() => _TextPaneState();
}

class _TextPaneState extends State<_TextPane> {
  static const double _fontSize = 13.0;
  static const double _lineHeightFactor = 1.4;
  static const double _contentPadding = 12.0;
  static const double _gutterWidth = 56.0;

  late final HighlightTextEditingController _controller;
  final _textScrollController = ScrollController();
  final _gutterScrollController = ScrollController();
  double _lineHeight = _fontSize * _lineHeightFactor;

  @override
  void initState() {
    super.initState();
    final style = const TextStyle(
      color: Colors.white,
      fontSize: _fontSize,
      fontFamily: 'Consolas',
      height: _lineHeightFactor,
    );
    _controller = HighlightTextEditingController(
      text: widget.content,
      language: _detectLanguage(widget.path),
      style: style,
    );
    _textScrollController.addListener(_syncGutterScroll);
    _measureLineHeight();
  }

  void _measureLineHeight() {
    const style = TextStyle(
      color: Colors.white,
      fontSize: _fontSize,
      fontFamily: 'Consolas',
      height: _lineHeightFactor,
    );
    const strut = StrutStyle(
      fontSize: _fontSize,
      height: _lineHeightFactor,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final painter = TextPainter(
      text: const TextSpan(text: '0', style: style),
      strutStyle: strut,
      textDirection: TextDirection.ltr,
    )..layout();
    _lineHeight = painter.preferredLineHeight;
  }

  @override
  void didUpdateWidget(covariant _TextPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.text != widget.content) {
      final selection = _controller.selection;
      _controller.text = widget.content;
      final newOffset = selection.baseOffset.clamp(0, _controller.text.length);
      _controller.selection = TextSelection.collapsed(offset: newOffset);
    }
    _controller.setLanguage(_detectLanguage(widget.path));
  }

  String? _detectLanguage(String? path) {
    if (path == null) return null;
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return ext.isEmpty ? null : ext;
  }

  @override
  void dispose() {
    _textScrollController.removeListener(_syncGutterScroll);
    _textScrollController.dispose();
    _gutterScrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncGutterScroll() {
    if (_gutterScrollController.hasClients) {
      _gutterScrollController.jumpTo(_textScrollController.offset);
    }
  }

  int get _lineCount => _controller.text.split('\n').length;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: const Color(0xFF2A2A2A),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.path != null ? p.basename(widget.path!) : '（未加载）',
                  style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'Consolas'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Line number gutter
              Container(
                width: _gutterWidth,
                color: const Color(0xFF252525),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                  child: ListView.builder(
                    controller: _gutterScrollController,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: _contentPadding),
                    itemExtent: _lineHeight,
                    itemCount: _lineCount,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: _fontSize,
                            fontFamily: 'Consolas',
                            height: _lineHeightFactor,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Container(width: 1, color: Colors.grey.shade800),
              // Text editor
              Expanded(
                child: Container(
                  color: const Color(0xFF1E1E1E),
                  child: TextField(
                    controller: _controller,
                    onChanged: widget.onChanged,
                    maxLines: null,
                    expands: true,
                    scrollController: _textScrollController,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: _fontSize,
                      fontFamily: 'Consolas',
                      height: _lineHeightFactor,
                    ),
                    strutStyle: const StrutStyle(
                      fontSize: _fontSize,
                      height: _lineHeightFactor,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.all(_contentPadding),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.text_fields, size: 64, color: Colors.grey.shade700),
          const SizedBox(height: 16),
          const Text('文本编辑器 / 差异补丁', style: TextStyle(color: Colors.grey, fontSize: 16)),
          const SizedBox(height: 8),
          const Text('请打开两个文本文件，然后点击“比较差异”', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }
}
