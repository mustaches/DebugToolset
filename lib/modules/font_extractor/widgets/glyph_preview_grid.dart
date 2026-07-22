import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../modules/font_extractor/utils/glyph_renderer.dart';
import '../../../providers/font_extractor_state.dart';

/// Preview grid of rendered glyphs with zoom control.
class GlyphPreviewGrid extends StatefulWidget {
  const GlyphPreviewGrid({super.key});

  @override
  State<GlyphPreviewGrid> createState() => _GlyphPreviewGridState();
}

class _GlyphPreviewGridState extends State<GlyphPreviewGrid> {
  double _zoom = 3.0;
  late final TextEditingController _rangeController;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    _rangeController = TextEditingController(
        text: context.read<FontExtractorState>().previewRangeInput);
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _rangeController.dispose();
    super.dispose();
  }

  /// Typing a range auto-refreshes the preview after a short pause
  /// (only when a font is loaded, so typing before that is a no-op).
  void _onRangeChanged(FontExtractorState state, String v) {
    state.setPreviewRangeInput(v);
    _refreshDebounce?.cancel();
    if (state.fontPaths.isEmpty) return;
    _refreshDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) context.read<FontExtractorState>().refreshPreview();
    });
  }

  void _refreshNow() {
    _refreshDebounce?.cancel();
    context.read<FontExtractorState>().refreshPreview();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('字模预览',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            SizedBox(
              width: 170,
              height: 28,
              child: TextField(
                controller: _rangeController,
                style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '预览范围 如 U+4E00-U+4E7F（空=前200）',
                  hintStyle: const TextStyle(fontSize: 10, color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF252525),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade800),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade800),
                  ),
                ),
                onChanged: (v) => _onRangeChanged(state, v),
                onSubmitted: (_) => _refreshNow(),
              ),
            ),
            Tooltip(
              message: '按范围刷新预览',
              child: InkWell(
                onTap: state.previewLoading ? null : _refreshNow,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.refresh, size: 16, color: Colors.cyanAccent),
                ),
              ),
            ),
            InkWell(
              onTap: () =>
                  state.setAutoRefreshPreview(!state.autoRefreshPreview),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: Checkbox(
                      value: state.autoRefreshPreview,
                      onChanged: (v) =>
                          state.setAutoRefreshPreview(v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text('自动刷新', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            if (state.previewRangeError != null)
              Tooltip(
                message: state.previewRangeError!,
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.error_outline,
                      size: 14, color: Colors.redAccent),
                ),
              ),
            const SizedBox(width: 12),
            const Icon(Icons.zoom_out, size: 14, color: Colors.grey),
            SizedBox(
              width: 120,
              child: Slider(
                value: _zoom,
                min: 1,
                max: 8,
                divisions: 7,
                onChanged: (v) => setState(() => _zoom = v),
              ),
            ),
            const Icon(Icons.zoom_in, size: 14, color: Colors.grey),
            const Spacer(),
            if (state.previewLoading)
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${(state.previewProgress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Text('${state.previewGlyphs.length} 字素',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '预览范围留空时显示字符集前 '
                        '${FontExtractorState.previewLimit} 个字素；'
                        '填写范围（如 U+4E00-U+4E7F）则完整预览该范围，'
                        '输入停顿或回车后自动刷新。\n'
                        '点击“生成字库”会导出全部选中的字符',
                    child: const Icon(Icons.info_outline,
                        size: 12, color: Colors.grey),
                  ),
                ],
              ),
          ],
        ),
        if (state.previewLoading)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(
              value: state.previewProgress,
              minHeight: 3,
              backgroundColor: const Color(0xFF252525),
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            color: const Color(0xFF1E1E1E),
            child: state.previewGlyphs.isEmpty
                ? const Center(
                    child: Text(
                      '尚未生成预览 — 从左侧 ① 添加字体开始，然后点击上方刷新图标',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent:
                          (state.cellWidth * _zoom) + 12,
                      mainAxisExtent: (state.cellHeight * _zoom) + 26,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                    ),
                    itemCount: state.previewGlyphs.length,
                    itemBuilder: (context, index) {
                      return GlyphCellView(
                        glyph: state.previewGlyphs[index],
                        scale: _zoom,
                        showCellGrid: state.showCellGrid,
                        cellWidth: state.cellWidth,
                        cellHeight: state.cellHeight,
                        verticalOffset: state.verticalOffset,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// A single glyph cell: the rendered bitmap plus its code point label,
/// with optional cell-grid and vertical-offset overlays. Shared by the
/// full preview grid and the bitmap-step sample preview.
class GlyphCellView extends StatelessWidget {
  final GlyphBitmap glyph;
  final double scale;
  final bool showCellGrid;
  final int cellWidth;
  final int cellHeight;
  final double verticalOffset;

  const GlyphCellView({
    super.key,
    required this.glyph,
    required this.scale,
    required this.showCellGrid,
    required this.cellWidth,
    required this.cellHeight,
    required this.verticalOffset,
  });

  @override
  Widget build(BuildContext context) {
    final label =
        'U+${glyph.codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')} '
        '${glyph.grapheme}${glyph.isMissing ? ' (缺字)' : ''}';

    return Tooltip(
      message: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: glyph.width * scale,
            height: glyph.height * scale,
            decoration: BoxDecoration(
              color: const Color(0xFF252525),
              border: Border.all(
                color: glyph.isMissing
                    ? Colors.redAccent.withValues(alpha: 0.6)
                    : Colors.grey.shade800,
              ),
            ),
            child: CustomPaint(
              painter: _GlyphPainter(
                glyph.pixels,
                glyph.width,
                glyph.height,
                showCellGrid: showCellGrid,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                verticalOffset: verticalOffset,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'U+${glyph.codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}',
            style: const TextStyle(
                fontSize: 8, color: Colors.grey, fontFamily: 'Consolas'),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Paints grayscale pixels as white squares, optionally overlaying the
/// cell grid (width/height) and vertical offset baseline.
class _GlyphPainter extends CustomPainter {
  final Uint8List pixels;
  final int width;
  final int height;
  final bool showCellGrid;
  final int cellWidth;
  final int cellHeight;
  final double verticalOffset;

  _GlyphPainter(
    this.pixels,
    this.width,
    this.height, {
    required this.showCellGrid,
    required this.cellWidth,
    required this.cellHeight,
    required this.verticalOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / width;
    final cellH = size.height / height;
    final paint = Paint();
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final v = pixels[y * width + x];
        if (v == 0) continue;
        paint.color = Colors.white.withValues(alpha: v / 255);
        canvas.drawRect(
          Rect.fromLTWH(x * cellW, y * cellH, cellW + 0.5, cellH + 0.5),
          paint,
        );
      }
    }

    if (!showCellGrid) return;

    // Cell boundary grid (cellWidth / cellHeight), grey.
    final gridPaint = Paint()
      ..color = Colors.grey.shade800
      ..strokeWidth = 1;
    final stepX = size.width / cellWidth;
    final stepY = size.height / cellHeight;
    for (int i = 1; i < cellWidth; i++) {
      final x = i * stepX;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (int i = 1; i < cellHeight; i++) {
      final y = i * stepY;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Vertical offset baseline, dark blue dashed line.
    final offsetY = verticalOffset * (size.height / cellHeight);
    if (offsetY > 0 && offsetY < size.height) {
      final dashPaint = Paint()
        ..color = const Color(0xFF1A3A5C)
        ..strokeWidth = 1;
      const dashLen = 4.0;
      const gapLen = 3.0;
      double x = 0;
      while (x < size.width) {
        final seg = (x + dashLen).clamp(0.0, size.width).toDouble();
        canvas.drawLine(
          Offset(x, offsetY),
          Offset(seg, offsetY),
          dashPaint,
        );
        x += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.pixels != pixels ||
      oldDelegate.showCellGrid != showCellGrid ||
      oldDelegate.cellWidth != cellWidth ||
      oldDelegate.cellHeight != cellHeight ||
      oldDelegate.verticalOffset != verticalOffset;
}
