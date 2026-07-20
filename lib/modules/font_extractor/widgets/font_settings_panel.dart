import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../modules/font_extractor/utils/bitmap_converter.dart';
import '../../../modules/font_extractor/utils/unicode_blocks.dart';
import '../../../modules/font_extractor/widgets/font_picker_dialog.dart';
import '../../../providers/font_extractor_state.dart';

/// Left-panel section for font files and render settings.
class FontSettingsPanel extends StatelessWidget {
  const FontSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('字体 (等宽字体优先)'),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ElevatedButton.icon(
              onPressed: () => _pickFont(context, state),
              icon: const Icon(Icons.font_download, size: 14),
              label: const Text('添加字体', style: TextStyle(fontSize: 12)),
              style: _btnStyle(),
            ),
            if (state.fontPaths.isNotEmpty)
              ElevatedButton.icon(
                onPressed: state.clearFonts,
                icon: const Icon(Icons.clear_all, size: 14),
                label: const Text('清空', style: TextStyle(fontSize: 12)),
                style: _btnStyle(),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (state.fontPaths.isEmpty)
          const Text('未加载字体', style: TextStyle(color: Colors.grey, fontSize: 11))
        else
          ...List.generate(state.fontPaths.length, (i) {
            final path = state.fontPaths[i];
            return Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    i == 0 ? Icons.font_download : Icons.subdirectory_arrow_right,
                    size: 12,
                    color: i == 0 ? Colors.cyanAccent : Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      p.basename(path) + (i == 0 ? ' (主)' : ' (后备)'),
                      style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  InkWell(
                    onTap: () => state.removeFontAt(i),
                    child: const Icon(Icons.close, size: 12, color: Colors.grey),
                  ),
                ],
              ),
            );
          }),
        const SizedBox(height: 14),
        Row(
          children: [
            _sectionTitle('点阵参数'),
            const Spacer(),
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: state.showCellGrid,
                onChanged: (v) => state.setShowCellGrid(v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 6),
            const Text('可预览', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        _numberRow(
          label: '字号 (px)',
          value: state.fontSize.toStringAsFixed(0),
          onMinus: () => state.setFontSize(state.fontSize - 1),
          onPlus: () => state.setFontSize(state.fontSize + 1),
          onSubmit: (v) => state.setFontSize(v.toDouble()),
        ),
        _numberRow(
          label: '单元格宽',
          value: '${state.cellWidth}',
          onMinus: () => state.setCellSize(state.cellWidth - 1, state.cellHeight),
          onPlus: () => state.setCellSize(state.cellWidth + 1, state.cellHeight),
          onSubmit: (v) => state.setCellSize(v, state.cellHeight),
        ),
        _numberRow(
          label: '单元格高',
          value: '${state.cellHeight}',
          onMinus: () => state.setCellSize(state.cellWidth, state.cellHeight - 1),
          onPlus: () => state.setCellSize(state.cellWidth, state.cellHeight + 1),
          onSubmit: (v) => state.setCellSize(state.cellWidth, v),
        ),
        _numberRow(
          label: '垂直偏移',
          value: state.verticalOffset.toStringAsFixed(0),
          onMinus: () => state.setVerticalOffset(state.verticalOffset - 1),
          onPlus: () => state.setVerticalOffset(state.verticalOffset + 1),
          onSubmit: (v) => state.setVerticalOffset(v.toDouble()),
        ),
        _numberRow(
          label: '阈值 (1bpp)',
          value: '${state.threshold}',
          onMinus: () => state.setThreshold(state.threshold - 8),
          onPlus: () => state.setThreshold(state.threshold + 8),
          onSubmit: state.setThreshold,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('位深度', style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 8),
            _choiceChip(
              label: '1bpp',
              selected: state.bitDepth == BitmapBitDepth.one,
              onTap: () => state.setBitDepth(BitmapBitDepth.one),
            ),
            const SizedBox(width: 6),
            _choiceChip(
              label: '8bpp',
              selected: state.bitDepth == BitmapBitDepth.eight,
              onTap: () => state.setBitDepth(BitmapBitDepth.eight),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('扫描方式', style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 8),
            _choiceChip(
              label: '行扫描',
              selected: state.scanMode == BitmapScanMode.rowMajor,
              onTap: () => state.setScanMode(BitmapScanMode.rowMajor),
            ),
            const SizedBox(width: 6),
            _choiceChip(
              label: '列扫描',
              selected: state.scanMode == BitmapScanMode.columnMajor,
              onTap: () => state.setScanMode(BitmapScanMode.columnMajor),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickFont(BuildContext context, FontExtractorState state) async {
    try {
      final path = await showFontPickerDialog(
        context,
        targetRanges: _currentCharsetRanges(state),
      );
      if (path != null) {
        await state.addFontFile(path);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.redAccent, content: Text('打开字体失败: $e')),
        );
      }
    }
  }

  /// The charset currently selected in the extractor (checked Unicode
  /// blocks plus custom ranges), used by the font picker to show per-font
  /// coverage. Unparseable custom-range input is ignored.
  List<({int start, int end})>? _currentCharsetRanges(FontExtractorState state) {
    final ranges = <({int start, int end})>[
      for (final i in state.selectedBlockIndexes)
        (start: kUnicodeBlocks[i].start, end: kUnicodeBlocks[i].end),
    ];
    try {
      if (state.customRangeInput.trim().isNotEmpty) {
        ranges.addAll(parseRangeInput(state.customRangeInput));
      }
    } catch (_) {}
    return ranges.isEmpty ? null : ranges;
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _numberRow({
    required String label,
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    required ValueChanged<int> onSubmit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          _stepperButton(Icons.remove, onMinus),
          _EditableNumber(value: value, onSubmit: onSubmit),
          _stepperButton(Icons.add, onPlus),
        ],
      ),
    );
  }

  Widget _stepperButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: const Color(0xFF333333),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Icon(icon, size: 14, color: Colors.cyanAccent),
      ),
    );
  }

  Widget _choiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0A4A5A) : const Color(0xFF333333),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: selected ? Colors.cyanAccent : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.cyanAccent : Colors.grey,
          ),
        ),
      ),
    );
  }

  ButtonStyle _btnStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF333333),
      foregroundColor: Colors.cyanAccent,
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
  }
}

/// An editable numeric value box used between the -/+ steppers.
///
/// Shows the current state value; the user can also click it and type a
/// number directly. The value is committed on Enter or focus loss and
/// validated by the state's setter (which clamps to the allowed range).
/// Invalid input reverts to the current value.
class _EditableNumber extends StatefulWidget {
  final String value;
  final ValueChanged<int> onSubmit;

  const _EditableNumber({required this.value, required this.onSubmit});

  @override
  State<_EditableNumber> createState() => _EditableNumberState();
}

class _EditableNumberState extends State<_EditableNumber> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode()
      ..addListener(() {
        if (!_focusNode.hasFocus) _commit();
      });
  }

  @override
  void didUpdateWidget(_EditableNumber oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow external changes (stepper buttons) unless the user is typing.
    if (!_focusNode.hasFocus && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = widget.value;
      return;
    }
    if (parsed.toString() != widget.value) {
      widget.onSubmit(parsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 3),
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
