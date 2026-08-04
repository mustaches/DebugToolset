import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../../providers/text_editor_state.dart';
import 'utils/file_type_groups.dart';
import 'utils/folder_diff.dart';
import 'utils/syntax_highlighter.dart';
import 'widgets/diff_view.dart';
import 'widgets/folder_compare_view.dart';
import 'widgets/folder_patch_dialog.dart';
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

    if (state.mode == TextCompareMode.folder) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(context, state),
          if (state.originalDir != null || state.modifiedDir != null)
            _buildFolderPathBar(state),
          const Expanded(child: FolderCompareView()),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(context, state),
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
          SegmentedButton<TextCompareMode>(
            segments: const [
              ButtonSegment<TextCompareMode>(
                value: TextCompareMode.files,
                label: Text('文件', style: TextStyle(fontSize: 11)),
                icon: Icon(Icons.insert_drive_file_outlined, size: 14),
              ),
              ButtonSegment<TextCompareMode>(
                value: TextCompareMode.folder,
                label: Text('文件夹', style: TextStyle(fontSize: 11)),
                icon: Icon(Icons.folder_copy_outlined, size: 14),
              ),
            ],
            selected: {state.mode},
            onSelectionChanged: (set) => state.setMode(set.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: WidgetStateProperty.all(EdgeInsets.zero),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return const Color(0xFF0A4A5A);
                }
                return const Color(0xFF252525);
              }),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return Colors.cyanAccent;
                }
                return Colors.grey;
              }),
            ),
          ),
          ..._buildModeButtons(context, state),
        ],
      ),
    );
  }

  List<Widget> _buildModeButtons(BuildContext context, TextEditorState state) {
    if (state.mode == TextCompareMode.folder) {
      return [
        _ToolbarButton(
          icon: Icons.folder_open,
          label: '打开原文件夹',
          onPressed: () => _pickOriginalFolder(context, state),
        ),
        _ToolbarButton(
          icon: Icons.folder_open_outlined,
          label: '打开修改文件夹',
          onPressed: () => _pickModifiedFolder(context, state),
        ),
        if (state.folderCompared)
          _ToolbarButton(
            icon: Icons.close,
            label: '放弃差异',
            onPressed: state.isComparingFolder
                ? null
                : () => state.discardFolderCompare(),
          )
        else
          _ToolbarButton(
            icon: Icons.compare_arrows,
            label: state.isComparingFolder ? '对比中…' : '比较差异',
            onPressed: state.originalDir != null &&
                    state.modifiedDir != null &&
                    !state.isComparingFolder
                ? () => _startFolderCompare(context, state)
                : null,
          ),
        _ToolbarButton(
          icon: Icons.upload,
          label: '生成补丁',
          onPressed: state.folderCompared &&
                  state.folderEntries.any((e) =>
                      e.status != FolderFileStatus.unchanged &&
                      e.status != FolderFileStatus.binary)
              ? () => _saveFolderPatch(context, state)
              : null,
        ),
        _ToolbarButton(
          icon: Icons.healing,
          label: '应用补丁',
          onPressed: () => _applyFolderPatch(context),
        ),
        _ToolbarButton(
          icon: Icons.undo,
          label: '回退补丁',
          onPressed: () => _revertFolderPatch(context),
        ),
        _ToolbarButton(
          icon: Icons.clear_all,
          label: '清空',
          onPressed:
              state.hasFolderContent ? () => state.clearFolder() : null,
        ),
      ];
    }
    return [
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
      if (state.hasCompared)
        _ToolbarButton(
          icon: Icons.close,
          label: '放弃差异',
          onPressed: () => state.discardDiff(),
        )
      else
        _ToolbarButton(
          icon: Icons.compare_arrows,
          label: '比较差异',
          onPressed: state.originalContent.isNotEmpty || state.modifiedContent.isNotEmpty
              ? () => state.compare()
              : null,
        ),
      _ToolbarButton(
        icon: Icons.upload,
        label: '生成补丁',
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
    ];
  }

  Widget _buildFolderPathBar(TextEditorState state) {
    return Container(
      color: const Color(0xFF2A2A2A),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Text('原: ',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          Expanded(
            child: Text(
              state.originalDir ?? '（未选择）',
              style: const TextStyle(
                  fontSize: 11, fontFamily: 'Consolas', color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 16),
          const Text('改: ',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          Expanded(
            child: Text(
              state.modifiedDir ?? '（未选择）',
              style: const TextStyle(
                  fontSize: 11, fontFamily: 'Consolas', color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
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
          ),
        ),
        Container(width: 1, color: Colors.grey.shade800),
        Expanded(
          child: _TextPane(
            title: '修改后',
            path: state.modifiedPath,
            content: state.modifiedContent,
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

  /// Starts the folder comparison and shows the progress dialog; the dialog
  /// closes itself when the comparison finishes.
  void _startFolderCompare(BuildContext context, TextEditorState state) {
    state.compareFolders();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _FolderCompareProgressDialog(),
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

  Future<void> _pickOriginalFolder(
      BuildContext context, TextEditorState state) async {
    try {
      final dir = await getDirectoryPath();
      if (dir != null) {
        await state.loadOriginalFolder(dir);
      }
    } catch (e) {
      if (!context.mounted) return;
      _showSnackBar(context, '打开原文件夹失败: $e', Colors.redAccent);
    }
  }

  Future<void> _pickModifiedFolder(
      BuildContext context, TextEditorState state) async {
    try {
      final dir = await getDirectoryPath();
      if (dir != null) {
        await state.loadModifiedFolder(dir);
      }
    } catch (e) {
      if (!context.mounted) return;
      _showSnackBar(context, '打开修改文件夹失败: $e', Colors.redAccent);
    }
  }

  Future<void> _saveFolderPatch(
      BuildContext context, TextEditorState state) async {
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
      if (state.originalDir != null && state.modifiedDir != null) {
        final originalName = p.basename(state.originalDir!);
        final modifiedName = p.basename(state.modifiedDir!);
        suggestedName =
            '${originalName}_patch_to_${modifiedName}_$timestamp.patch';

        final parentDir = p.dirname(state.originalDir!);
        final patchDir = p.join(parentDir, 'patch');
        await Directory(patchDir).create(recursive: true);
        initialDirectory = patchDir;
      } else {
        suggestedName = 'project_changes_$timestamp.patch';
      }

      final location = await getSaveLocation(
        initialDirectory: initialDirectory,
        acceptedTypeGroups: [patchType, allType],
        suggestedName: suggestedName,
      );
      if (location != null) {
        await state.saveFolderPatch(location.path);
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

  Future<void> _applyFolderPatch(BuildContext context) async {
    final applied = await showFolderPatchDialog(context);
    if (applied && context.mounted) {
      _showSnackBar(context, '补丁应用成功', Colors.green);
    }
  }

  Future<void> _revertFolderPatch(BuildContext context) async {
    final reverted = await showFolderPatchDialog(context, revertMode: true);
    if (reverted && context.mounted) {
      _showSnackBar(context, '补丁回退成功', Colors.green);
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

  const _TextPane({
    required this.title,
    this.path,
    required this.content,
  });

  @override
  State<_TextPane> createState() => _TextPaneState();
}

class _TextPaneState extends State<_TextPane> {
  static const double _itemExtent = 22.0;
  final _scrollController = ScrollController();

  late List<String> _lines;
  late String? _language;

  @override
  void initState() {
    super.initState();
    _lines = widget.content.split('\n');
    _language = _detectLanguage(widget.path);
  }

  @override
  void didUpdateWidget(covariant _TextPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content || oldWidget.path != widget.path) {
      _lines = widget.content.split('\n');
      _language = _detectLanguage(widget.path);
    }
  }

  String? _detectLanguage(String? path) {
    if (path == null) return null;
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return ext.isEmpty ? null : ext;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
              Text(widget.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.path != null ? p.basename(widget.path!) : '（未加载）',
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 11, fontFamily: 'Consolas'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_lines.isNotEmpty)
                Text(
                  '${_lines.length} 行',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFF1E1E1E),
            child: SelectionArea(
              child: ListView.builder(
                controller: _scrollController,
                itemExtent: _itemExtent,
                itemCount: _lines.length,
                itemBuilder: (context, index) {
                  final lineText = _lines[index];
                  return Container(
                    height: _itemExtent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 50,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                              fontFamily: 'Consolas',
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(width: 1, color: Colors.grey.shade800),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(
                                color: kVscodePlain,
                                fontSize: 13,
                                fontFamily: 'Consolas',
                              ),
                              children: SyntaxHighlighter.highlightText(
                                lineText,
                                _language,
                                baseStyle: const TextStyle(
                                  color: kVscodePlain,
                                  fontSize: 13,
                                  fontFamily: 'Consolas',
                                ),
                              ),
                            ),
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
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

/// Progress dialog shown while the two folder trees are being compared.
///
/// The first row shows the file currently being compared on the left
/// (original) side, the second row the one on the right (modified) side;
/// a progress bar sits below. The dialog pops itself once the comparison
/// finishes.
class _FolderCompareProgressDialog extends StatelessWidget {
  const _FolderCompareProgressDialog();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TextEditorState>();
    if (!state.isComparingFolder) {
      // Comparison finished: close after this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).pop();
      });
    }
    final total = state.folderCompareTotal;
    final processed = state.folderCompareProcessed;
    return AlertDialog(
      backgroundColor: const Color(0xFF252525),
      title: const Text('正在比较文件夹差异',
          style: TextStyle(color: Colors.white, fontSize: 14)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pathRow('左:', state.folderComparePathA, processed),
            const SizedBox(height: 4),
            _pathRow('右:', state.folderComparePathB, processed),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: total > 0 ? processed / total : null,
              backgroundColor: Colors.grey.shade800,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
            ),
            const SizedBox(height: 6),
            Text(
              total > 0 ? '$processed / $total' : '正在扫描文件…',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pathRow(String label, String? path, int processed) {
    return Row(
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            path ?? (processed == 0 ? '…' : '（此侧不存在）'),
            style: const TextStyle(
                color: Colors.white70, fontSize: 11, fontFamily: 'Consolas'),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}
