import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../utils/bitmap_converter.dart';
import '../utils/unicode_blocks.dart';
import '../../../modules/font_extractor/utils/glyph_renderer.dart';
import '../../../providers/font_extractor_state.dart';

/// Preview grid of rendered glyphs with zoom control.
class GlyphPreviewGrid extends StatefulWidget {
  const GlyphPreviewGrid({super.key});

  @override
  State<GlyphPreviewGrid> createState() => _GlyphPreviewGridState();
}

class _GlyphPreviewGridState extends State<GlyphPreviewGrid> {
  static const List<double> _zoomSteps = [
    1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 16.0, 20.0, 24.0
  ];
  int _zoomIndex = 2; // Default to 3x (index 2)
  double get _zoom => _zoomSteps[_zoomIndex];

  late final TextEditingController _limitController;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    final state = context.read<FontExtractorState>();
    _limitController =
        TextEditingController(text: '${state.previewLimit}');
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _limitController.dispose();
    super.dispose();
  }

  void _onLimitChanged(FontExtractorState state, String v) {
    final count = int.tryParse(v);
    if (count != null && count >= 0) {
      state.setPreviewLimit(count);
      _refreshDebounce?.cancel();
      if (state.fontPaths.isEmpty) return;
      _refreshDebounce = Timer(const Duration(milliseconds: 600), () {
        if (mounted) context.read<FontExtractorState>().refreshPreview();
      });
    }
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
            const SizedBox(width: 10),
            const Text('数量：',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            SizedBox(
              width: 55,
              height: 28,
              child: TextField(
                controller: _limitController,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '100',
                  hintStyle: const TextStyle(fontSize: 10, color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF252525),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade800),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade800),
                  ),
                ),
                onChanged: (v) => _onLimitChanged(state, v),
                onSubmitted: (_) => _refreshNow(),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: state.previewLoading ? null : _refreshNow,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新预览', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0A4A5A),
                foregroundColor: Colors.cyanAccent,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
            const SizedBox(width: 8),
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
                          state.setAutoRefreshPreview(v ?? true),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text('自动刷新', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.zoom_out, size: 14, color: Colors.grey),
            SizedBox(
              width: 400,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  tickMarkShape:
                      const RoundSliderTickMarkShape(tickMarkRadius: 2.5),
                  activeTickMarkColor: Colors.cyanAccent,
                  inactiveTickMarkColor: Colors.grey.shade600,
                  activeTrackColor: const Color(0xFF0A4A5A),
                  inactiveTrackColor: const Color(0xFF333333),
                  thumbColor: Colors.cyanAccent,
                  overlayColor: Colors.cyanAccent.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: _zoomIndex.toDouble(),
                  min: 0,
                  max: (_zoomSteps.length - 1).toDouble(),
                  divisions: _zoomSteps.length - 1,
                  onChanged: (v) => setState(() => _zoomIndex = v.round()),
                ),
              ),
            ),
            const Icon(Icons.zoom_in, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              '${_zoom.toStringAsFixed(0)}x',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.cyanAccent,
                fontFamily: 'Consolas',
              ),
            ),
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
                    message: state.previewLimit == 0
                        ? '全量预览模式（数量为 0）：预览所选字符集的全部字符；\n'
                            '未包含在当前字体中的字符集会单独提示。\n'
                            '点击“生成字库”即可导出所选字符集的全部字模'
                        : '按字符集分类预览各区块头部前 ${state.previewLimit} 个字符（填 0 预览全部）；\n'
                            '未包含在当前字体中的字符集会单独提示。\n'
                            '点击“生成字库”即可导出所选字符集的全部字模',
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.extractMode == FontExtractMode.multiLang &&
                  state.langBindings.any(
                      (b) => b.fontPath != null && b.fontPath!.isNotEmpty))
                _buildBoundLanguagesSidebar(context, state),
              Expanded(
                child: Container(
                  color: const Color(0xFF1E1E1E),
                  child: state.previewGroups.isEmpty
                      ? const Center(
                          child: Text(
                            '尚未生成预览 — 从左侧 ① 添加字体开始，然后点击上方“刷新预览”按钮',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: state.previewGroups.length,
                          itemBuilder: (context, groupIdx) {
                            final group = state.previewGroups[groupIdx];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Block Header Bar
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2D2D2D),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.grey.shade800),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        group.isMissingInFont
                                            ? Icons.warning_amber_rounded
                                            : Icons.folder_special,
                                        size: 15,
                                        color: group.isMissingInFont
                                            ? Colors.amberAccent
                                            : Colors.cyanAccent,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        group.blockName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '(${group.rangeLabel})',
                                        style: const TextStyle(
                                          color: Colors.cyanAccent,
                                          fontSize: 11,
                                          fontFamily: 'Consolas',
                                        ),
                                      ),
                                      if (group.fontName.isNotEmpty) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1E1E1E),
                                            borderRadius:
                                                BorderRadius.circular(3),
                                            border: Border.all(
                                                color: Colors.grey.shade700),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                  Icons.font_download_outlined,
                                                  size: 11,
                                                  color: Colors.cyanAccent),
                                              const SizedBox(width: 4),
                                              Text(
                                                group.fontName,
                                                style: const TextStyle(
                                                  color: Colors.cyanAccent,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                      const Spacer(),
                                      Text(
                                        '${group.glyphs.length} 字素',
                                        style: const TextStyle(
                                            color: Colors.grey, fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 6),
                                if (group.isMissingInFont)
                                  Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.only(bottom: 16),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2A1E1E),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                          color: Colors.redAccent
                                              .withValues(alpha: 0.5)),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.info_outline,
                                            size: 16, color: Colors.amberAccent),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            '此字符集在“${group.fontName}”里不存在或未分配字模',
                                            style: const TextStyle(
                                              color: Colors.amberAccent,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: group.glyphs.map((g) {
                                        return GlyphCellView(
                                          glyph: g,
                                          scale: _zoom,
                                          showCellGrid: state.showCellGrid,
                                          showThresholdPreview:
                                              state.showThresholdPreview,
                                          verticalOffset: state.verticalOffset,
                                          threshold: state.threshold,
                                          bitDepth: state.bitDepth,
                                        );
                                      }).toList(),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBoundLanguagesSidebar(
      BuildContext context, FontExtractorState state) {
    final boundList = state.langBindings
        .where((b) => b.fontPath != null && b.fontPath!.isNotEmpty)
        .toList();

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: const Color(0xFF222222),
        border: Border(
          right: BorderSide(color: Colors.grey.shade800),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sidebar Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color: const Color(0xFF2B2B2B),
            child: Row(
              children: [
                const Icon(Icons.language, size: 16, color: Colors.cyanAccent),
                const SizedBox(width: 6),
                const Text(
                  '已绑定语言',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A4A5A),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${boundList.length}',
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Bound languages list
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: boundList.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final item = boundList[index];
                final fontName =
                    item.fontDisplayName ?? p.basename(item.fontPath!);

                return Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.shade800),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A4A5A),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '#${index + 1}',
                              style: const TextStyle(
                                fontSize: 9,
                                color: Colors.cyanAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            item.flag,
                            style: const TextStyle(fontSize: 13),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF333333),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              item.scriptTag,
                              style: const TextStyle(
                                color: Colors.cyanAccent,
                                fontSize: 9,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.font_download_outlined,
                              size: 12, color: Colors.grey),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              fontName,
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 10,
                                fontFamily: 'Consolas',
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${item.blocks.length} 个字符区块 | ${item.sampleText}',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 9,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A single glyph cell: the rendered bitmap plus its code point label,
/// with optional cell-grid and vertical-offset overlays. Shared by the
/// full preview grid and the bitmap-step sample preview.
///
/// The grayscale pixels are composited once into a 1:1 [ui.Image] (white
/// ink on transparent background) and drawn with
/// [FilterQuality.none], so every bitmap pixel maps to an exact device
/// pixel block without resampling blur — the same approach as the font
/// test dialog's `_BitmapPainter`.
class GlyphCellView extends StatefulWidget {
  final GlyphBitmap glyph;
  final double scale;
  final bool showCellGrid;
  final bool showThresholdPreview;
  final double verticalOffset;
  final int threshold;
  final BitmapBitDepth bitDepth;

  const GlyphCellView({
    super.key,
    required this.glyph,
    required this.scale,
    required this.showCellGrid,
    required this.showThresholdPreview,
    required this.verticalOffset,
    required this.threshold,
    required this.bitDepth,
  });

  @override
  State<GlyphCellView> createState() => _GlyphCellViewState();
}

class _GlyphCellViewState extends State<GlyphCellView> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _rebuildImage();
  }

  @override
  void didUpdateWidget(GlyphCellView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.glyph.pixels != widget.glyph.pixels ||
        oldWidget.glyph.width != widget.glyph.width ||
        oldWidget.glyph.height != widget.glyph.height ||
        oldWidget.threshold != widget.threshold ||
        oldWidget.showThresholdPreview != widget.showThresholdPreview ||
        oldWidget.bitDepth != widget.bitDepth) {
      _rebuildImage();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  /// Composites the grayscale pixels into RGBA bytes (white ink, coverage
  /// as alpha; optionally binarized by the 1bpp threshold) and decodes a
  /// 1:1 [ui.Image]. The previous image is disposed once the new one is
  /// ready.
  void _rebuildImage() {
    final g = widget.glyph;
    final rgba = Uint8List(g.width * g.height * 4);
    for (int i = 0; i < g.width * g.height; i++) {
      final v = g.pixels[i];
      final int a;
      if (widget.showThresholdPreview) {
        a = v >= widget.threshold ? 255 : 0;
      } else {
        a = v;
      }
      // decodeImageFromPixels expects PREMULTIPLIED alpha: the RGB channels
      // must already be scaled by alpha. Writing (255,255,255,0) for the
      // background would blend as opaque white (verified by engine
      // readback), turning the whole cell white — so use rgb = a.
      rgba[i * 4] = a;
      rgba[i * 4 + 1] = a;
      rgba[i * 4 + 2] = a;
      rgba[i * 4 + 3] = a;
    }
    ui.decodeImageFromPixels(
      rgba,
      g.width,
      g.height,
      ui.PixelFormat.rgba8888,
      (img) {
        if (!mounted) {
          img.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = img;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final glyph = widget.glyph;
    final label =
        '${formatCodePoint(glyph.codePoint)} '
        '${glyph.grapheme}${glyph.isMissing ? ' (缺字)' : ''}';

    return Tooltip(
      message: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: glyph.width * widget.scale,
            height: glyph.height * widget.scale,
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
                image: _image,
                cellWidth: glyph.width,
                cellHeight: glyph.height,
                showCellGrid: widget.showCellGrid,
                verticalOffset: widget.verticalOffset,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            formatCodePoint(glyph.codePoint),
            style: const TextStyle(
                fontSize: 10, color: Colors.white, fontFamily: 'Consolas'),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Draws the 1:1 glyph image scaled up with nearest-neighbor sampling,
/// optionally overlaying the cell grid (width/height) and vertical offset
/// baseline.
class _GlyphPainter extends CustomPainter {
  final ui.Image? image;
  final int cellWidth;
  final int cellHeight;
  final bool showCellGrid;
  final double verticalOffset;

  _GlyphPainter({
    required this.image,
    required this.cellWidth,
    required this.cellHeight,
    required this.showCellGrid,
    required this.verticalOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      // Nearest-neighbor: bitmap pixels stay hard-edged at any zoom.
      final paint = Paint()..filterQuality = FilterQuality.none;
      final src = Rect.fromLTWH(
          0, 0, img.width.toDouble(), img.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(img, src, dst, paint);
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

    // Vertical offset baseline, amber accent dashed line.
    final baseLineY =
        (cellHeight * 0.75 + verticalOffset) * (size.height / cellHeight);
    if (baseLineY >= 0 && baseLineY <= size.height) {
      final dashPaint = Paint()
        ..color = Colors.amberAccent.withValues(alpha: 0.85)
        ..strokeWidth = 1.2;
      const dashLen = 3.0;
      const gapLen = 2.0;
      double x = 0;
      while (x < size.width) {
        final seg = (x + dashLen).clamp(0.0, size.width).toDouble();
        canvas.drawLine(
          Offset(x, baseLineY),
          Offset(seg, baseLineY),
          dashPaint,
        );
        x += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.showCellGrid != showCellGrid ||
      oldDelegate.cellWidth != cellWidth ||
      oldDelegate.cellHeight != cellHeight ||
      oldDelegate.verticalOffset != verticalOffset;
}
