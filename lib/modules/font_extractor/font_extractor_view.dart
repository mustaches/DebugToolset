import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/font_extractor_state.dart';
import 'widgets/charset_panel.dart';
import 'widgets/font_settings_panel.dart';
import 'widgets/glyph_preview_grid.dart';

/// Main view for the Font Extractor module.
class FontExtractorView extends StatefulWidget {
  const FontExtractorView({super.key});

  @override
  State<FontExtractorView> createState() => _FontExtractorViewState();
}

class _FontExtractorViewState extends State<FontExtractorView> {
  final _baseNameController = TextEditingController(text: 'myfont');
  bool _writeC = true;
  bool _writeBin = true;

  @override
  void dispose() {
    _baseNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();

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
        if (state.isGenerating)
          LinearProgressIndicator(
            value: state.progress,
            minHeight: 3,
            backgroundColor: const Color(0xFF252525),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 330,
                color: const Color(0xFF252525),
                child: const SingleChildScrollView(
                  padding: EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FontSettingsPanel(),
                      SizedBox(height: 16),
                      Divider(height: 1),
                      SizedBox(height: 12),
                      CharsetPanel(),
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
      ],
    );
  }

  Widget _buildTopBar(BuildContext context, FontExtractorState state) {
    return Container(
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ElevatedButton.icon(
            onPressed: state.previewLoading ? null : state.refreshPreview,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('刷新预览', style: TextStyle(fontSize: 12)),
            style: _btnStyle(),
          ),
          Container(width: 1, height: 24, color: Colors.grey.shade800),
          SizedBox(
            width: 120,
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
          _formatCheck('C 数组', _writeC, (v) => setState(() => _writeC = v)),
          _formatCheck('二进制', _writeBin, (v) => setState(() => _writeBin = v)),
          ElevatedButton.icon(
            onPressed: state.isGenerating || (!_writeC && !_writeBin)
                ? null
                : () => _generate(context, state),
            icon: const Icon(Icons.build, size: 16),
            label: const Text('生成字库', style: TextStyle(fontSize: 12)),
            style: _btnStyle(),
          ),
          if (state.isGenerating)
            TextButton.icon(
              onPressed: state.cancelGenerate,
              icon: const Icon(Icons.stop, size: 14, color: Colors.redAccent),
              label: const Text('取消',
                  style: TextStyle(fontSize: 12, color: Colors.redAccent)),
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

  ButtonStyle _btnStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF333333),
      foregroundColor: Colors.cyanAccent,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
  }
}
