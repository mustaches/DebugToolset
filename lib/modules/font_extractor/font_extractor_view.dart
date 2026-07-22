import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../providers/font_extractor_state.dart';
import 'widgets/bitmap_section.dart';
import 'widgets/charset_panel.dart';
import 'widgets/font_section.dart';
import 'widgets/font_test_dialog.dart';
import 'widgets/glyph_preview_grid.dart';
import 'widgets/section_card.dart';

/// Main view for the Font Extractor module: a single-screen workbench.
///
/// Left column: numbered, collapsible configuration cards (1. font,
/// 2. bitmap params, 3. charset) whose headers always show a one-line
/// summary and a ready/attention status mark. Right: the glyph preview.
/// Bottom: a persistent output bar with file name, formats and the
/// generate/test actions, so re-generating never requires navigation.
class FontExtractorView extends StatefulWidget {
  const FontExtractorView({super.key});

  @override
  State<FontExtractorView> createState() => _FontExtractorViewState();
}

class _FontExtractorViewState extends State<FontExtractorView> {
  final _baseNameController = TextEditingController();
  bool _writeC = true;
  bool _writeBin = true;

  /// Last auto-filled suggestion; while the field still holds it (or is
  /// empty) the name follows 字体名_格宽x格高 automatically. Once the
  /// user types something else, their input is kept.
  String _lastSuggested = '';

  @override
  void dispose() {
    _baseNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();

    final suggested = state.suggestedBaseName;
    if (_baseNameController.text.isEmpty ||
        _baseNameController.text == _lastSuggested) {
      if (_baseNameController.text != suggested) {
        _baseNameController.text = suggested;
      }
    }
    _lastSuggested = suggested;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTopBar(context, state),
        if (state.lastError != null)
          Container(
            color: const Color(0xFF4A2020),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              state.lastError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 11),
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 340,
                color: const Color(0xFF252525),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionCard(
                        number: 1,
                        title: '字体',
                        summary: _fontSummary(state),
                        status: state.fontPaths.isEmpty
                            ? SectionStatus.attention
                            : SectionStatus.ok,
                        child: const FontSection(),
                      ),
                      SectionCard(
                        number: 2,
                        title: '点阵参数',
                        summary: _bitmapSummary(state),
                        status: SectionStatus.ok,
                        child: const BitmapSection(),
                      ),
                      SectionCard(
                        number: 3,
                        title: '字符集',
                        summary: _charsetSummary(state),
                        status: _charsetReady(state)
                            ? SectionStatus.ok
                            : SectionStatus.attention,
                        child: const CharsetPanel(),
                      ),
                    ],
                  ),
                ),
              ),
              Container(width: 1, color: Colors.grey.shade800),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: GlyphPreviewGrid(),
                ),
              ),
            ],
          ),
        ),
        if (state.isGenerating)
          LinearProgressIndicator(
            value: state.progress,
            minHeight: 3,
            backgroundColor: const Color(0xFF252525),
          ),
        _buildOutputBar(context, state),
      ],
    );
  }

  // ------------------------------------------------------------------
  // Summaries / status
  // ------------------------------------------------------------------

  String _fontSummary(FontExtractorState state) {
    if (state.fontPaths.isEmpty) return '未加载';
    final first = state.fontDisplayName(state.fontPaths.first);
    return state.fontPaths.length > 1
        ? '$first 等 ${state.fontPaths.length} 个'
        : first;
  }

  String _bitmapSummary(FontExtractorState state) {
    final depth = state.bitDepth.name == 'one' ? '1bpp' : '8bpp';
    final scan = state.scanMode.name == 'rowMajor' ? '行扫描' : '列扫描';
    return '${state.fontSize.toStringAsFixed(0)}px '
        '${state.cellWidth}x${state.cellHeight} $depth $scan';
  }

  bool _charsetReady(FontExtractorState state) =>
      state.charsetSize > 0 || state.importedText.isNotEmpty;

  String _charsetSummary(FontExtractorState state) {
    final parts = <String>['${state.charsetSize} 个码点'];
    if (state.importedText.isNotEmpty) {
      parts.add('导入 ${state.importedText.characters.length} 字素');
    }
    return parts.join(' + ');
  }

  // ------------------------------------------------------------------
  // Top bar: title + template menu
  // ------------------------------------------------------------------

  Widget _buildTopBar(BuildContext context, FontExtractorState state) {
    return Container(
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Text(
            '字库提取',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '按 ①②③ 顺序配置，底部 ④ 输出',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: '模板',
            color: const Color(0xFF333333),
            onSelected: (v) {
              if (v == 'save') {
                _saveTemplate(context, state);
              } else {
                _loadTemplate(context, state);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'save',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.save_alt, size: 16),
                  title: Text('保存模板', style: TextStyle(fontSize: 12)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'load',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.folder_open, size: 16),
                  title: Text('加载模板', style: TextStyle(fontSize: 12)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF333333),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmark_outline,
                      size: 14, color: Colors.cyanAccent),
                  SizedBox(width: 4),
                  Text('模板',
                      style: TextStyle(fontSize: 12, color: Colors.cyanAccent)),
                  Icon(Icons.arrow_drop_down,
                      size: 14, color: Colors.cyanAccent),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Bottom output bar
  // ------------------------------------------------------------------

  Widget _buildOutputBar(BuildContext context, FontExtractorState state) {
    final canGenerate = state.fontPaths.isNotEmpty &&
        !state.isGenerating &&
        (_writeC || _writeBin);
    final String? disabledReason;
    if (state.fontPaths.isEmpty) {
      disabledReason = '请先在 ① 中添加字体';
    } else if (!_writeC && !_writeBin) {
      disabledReason = '请至少勾选一种输出格式';
    } else {
      disabledReason = null;
    }

    return Container(
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: const BoxDecoration(
              color: Color(0xFF0A4A5A),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Text('4',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 8),
          const Text('输出',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          SizedBox(
            width: 220,
            child: TextField(
              controller: _baseNameController,
              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
              decoration: InputDecoration(
                isDense: true,
                labelText: '输出文件名',
                labelStyle: const TextStyle(fontSize: 10, color: Colors.grey),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: Colors.grey.shade800),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: Colors.grey.shade800),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _formatCheck('C 数组', _writeC, (v) => setState(() => _writeC = v)),
          const SizedBox(width: 10),
          _formatCheck('二进制', _writeBin, (v) => setState(() => _writeBin = v)),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: canGenerate ? () => _generate(context, state) : null,
            icon: const Icon(Icons.build, size: 16),
            label: const Text('生成字库', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0A4A5A),
              foregroundColor: Colors.cyanAccent,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => _openFontTest(context, state),
            icon: const Icon(Icons.play_circle_outline, size: 16),
            label: const Text('测试字库', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF333333),
              foregroundColor: Colors.cyanAccent,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
          if (state.isGenerating)
            TextButton.icon(
              onPressed: state.cancelGenerate,
              icon: const Icon(Icons.stop, size: 14, color: Colors.redAccent),
              label: const Text('取消',
                  style: TextStyle(fontSize: 12, color: Colors.redAccent)),
            ),
          const Spacer(),
          if (disabledReason != null)
            Text(
              disabledReason,
              style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
            )
          else if (state.lastOutputDir != null)
            Text(
              '上次输出: ${state.lastOutputDir}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _formatCheck(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Template save / load (.gflm)
  // ------------------------------------------------------------------

  static const _templateTypeGroup = XTypeGroup(
    label: '字库提取模板',
    extensions: ['gflm'],
  );

  Future<void> _saveTemplate(
      BuildContext context, FontExtractorState state) async {
    try {
      final baseName = _baseNameController.text.trim();
      final location = await getSaveLocation(
        acceptedTypeGroups: const [_templateTypeGroup],
        suggestedName: '${baseName.isEmpty ? 'myfont' : baseName}.gflm',
        confirmButtonText: '保存模板',
      );
      if (location == null) return;
      var path = location.path;
      if (!path.toLowerCase().endsWith('.gflm')) path = '$path.gflm';
      final json = state.exportTemplate()
        ..['baseName'] = baseName
        ..['writeC'] = _writeC
        ..['writeBin'] = _writeBin;
      await File(path)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.green, content: Text('模板已保存到 $path')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.redAccent, content: Text('模板保存失败: $e')),
        );
      }
    }
  }

  Future<void> _loadTemplate(
      BuildContext context, FontExtractorState state) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [_templateTypeGroup],
        confirmButtonText: '加载模板',
      );
      if (file == null) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('不是有效的字库提取模板文件');
      }
      final missing = await state.applyTemplate(decoded);
      setState(() {
        final baseName = decoded['baseName'];
        if (baseName is String && baseName.isNotEmpty) {
          _baseNameController.text = baseName;
        }
        if (decoded['writeC'] is bool) _writeC = decoded['writeC'] as bool;
        if (decoded['writeBin'] is bool) _writeBin = decoded['writeBin'] as bool;
      });
      if (state.fontPaths.isNotEmpty) await state.refreshPreview();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor:
                missing.isEmpty ? Colors.green : Colors.orange.shade800,
            content: Text(missing.isEmpty
                ? '模板已加载'
                : '模板已加载，${missing.length} 个字体文件不存在，已跳过'),
          ),
        );
      }
    } on FormatException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.redAccent,
              content: Text('模板加载失败: ${e.message}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.redAccent, content: Text('模板加载失败: $e')),
        );
      }
    }
  }

  // ------------------------------------------------------------------
  // Generate / test
  // ------------------------------------------------------------------

  Future<void> _openFontTest(
      BuildContext context, FontExtractorState state) async {
    // Pre-load the last generated font file if it still exists.
    String? initialPath;
    final dir = state.lastOutputDir;
    final baseName = _baseNameController.text.trim();
    if (dir != null && baseName.isNotEmpty) {
      for (final candidate in [
        p.join(dir, '$baseName.bin'),
        p.join(dir, '${baseName}_font.c'),
      ]) {
        if (File(candidate).existsSync()) {
          initialPath = candidate;
          break;
        }
      }
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => FontTestDialog(initialPath: initialPath),
    );
  }

  Future<void> _generate(BuildContext context, FontExtractorState state) async {
    final baseName = _baseNameController.text.trim();
    if (baseName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            backgroundColor: Colors.redAccent, content: Text('请填写输出文件名')),
      );
      return;
    }
    try {
      final dir = await getDirectoryPath(confirmButtonText: '选择输出目录');
      if (dir == null) return;
      if (!context.mounted) return;
      final ok = await state.generate(
        outputDir: dir,
        baseName: baseName,
        writeC: _writeC,
        writeBin: _writeBin,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: ok ? Colors.green : Colors.redAccent,
            content: Text(ok ? '字库已生成到 $dir' : (state.lastError ?? '生成失败')),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.redAccent, content: Text('生成失败: $e')),
        );
      }
    }
  }
}
