import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../modules/font_extractor/utils/bitmap_converter.dart';
import '../../../providers/font_extractor_state.dart';

/// Section body: bitmap render settings (size, cell, offset, threshold,
/// bit depth, scan mode, cell-grid overlay toggle).
class BitmapSection extends StatelessWidget {
  const BitmapSection({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.pixelFontSizeWarning != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2416),
              borderRadius: BorderRadius.circular(4),
              border:
                  Border.all(color: Colors.amberAccent.withValues(alpha: 0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 14, color: Colors.amberAccent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    state.pixelFontSizeWarning!,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.amberAccent),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        _groupContainer(
          title: '半角字符 (ASCII/拉丁/其它)',
          children: [
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
              onMinus: () =>
                  state.setCellSize(state.cellWidth - 1, state.cellHeight),
              onPlus: () =>
                  state.setCellSize(state.cellWidth + 1, state.cellHeight),
              onSubmit: (v) => state.setCellSize(v, state.cellHeight),
            ),
            _numberRow(
              label: '单元格高',
              value: '${state.cellHeight}',
              onMinus: () =>
                  state.setCellSize(state.cellWidth, state.cellHeight - 1),
              onPlus: () =>
                  state.setCellSize(state.cellWidth, state.cellHeight + 1),
              onSubmit: (v) => state.setCellSize(state.cellWidth, v),
            ),
          ],
        ),
        if (state.fontPaths.isNotEmpty && state.hasFullWidthActive) ...[
          const SizedBox(height: 8),
          _groupContainer(
            title: '全角字符 (中/日/韩/彝)',
            children: [
              _numberRow(
                label: '字号 (px)',
                value: state.cjkFontSize.toStringAsFixed(0),
                onMinus: () => state.setCjkFontSize(state.cjkFontSize - 1),
                onPlus: () => state.setCjkFontSize(state.cjkFontSize + 1),
                onSubmit: (v) => state.setCjkFontSize(v.toDouble()),
              ),
              _numberRow(
                label: '单元格大小',
                value: '${state.cjkCellSize}',
                onMinus: () => state.setCjkCellSize(state.cjkCellSize - 1),
                onPlus: () => state.setCjkCellSize(state.cjkCellSize + 1),
                onSubmit: state.setCjkCellSize,
              ),
            ],
          ),
        ],
        if (state.fontPaths.isNotEmpty && state.hasProportionalActive) ...[
          const SizedBox(height: 8),
          _groupContainer(
            title: '变宽字符 (天城文/阿拉伯/泰文/希腊等)',
            children: const [
              Text(
                '宽度按字体实际字形自动测定，字号与单元格高同半角组',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
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
            const Text('位深度',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
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
            const Text('扫描方式',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
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
        const SizedBox(height: 6),
        Row(
          children: [
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
            const Text('预览中显示单元格网格',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: state.showThresholdPreview,
                onChanged: (v) => state.setShowThresholdPreview(v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 6),
            const Text('预览中应用阈值效果 (1bpp)',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: state.pixelSnap,
                onChanged: (v) => state.setPixelSnap(v ?? true),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 6),
            const Text('1:1 像素硬对齐 (消除次像素模糊)',
                style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
          ],
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: state.applyOneToOnePreset,
          icon: const Icon(Icons.grid_on, size: 14),
          label: const Text('一键 1:1 像素模式预设', style: TextStyle(fontSize: 11)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0A4A5A),
            foregroundColor: Colors.cyanAccent,
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
      ],
    );
  }

  Widget _groupContainer({
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: Colors.grey.shade900),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.cyanAccent,
            ),
          ),
          const SizedBox(height: 6),
          ...children,
        ],
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
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
        color: const Color(0xFF252525),
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
