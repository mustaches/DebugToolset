import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;

/// A single rendered glyph (one grapheme cluster) as a grayscale bitmap.
class GlyphBitmap {
  /// The grapheme that was rendered (base char + optional combining marks).
  final String grapheme;

  /// First code point of the grapheme; used as the lookup key in output.
  final int codePoint;

  /// Cell dimensions in pixels.
  final int width;
  final int height;

  /// Fixed advance width in pixels (monospace cell width).
  final int advance;

  /// Natural (unclipped) ink width of the rendered glyph.
  final int naturalWidth;

  /// Grayscale coverage, length = width*height, row-major (0-255).
  final Uint8List pixels;

  /// True when the font has no glyph for this grapheme (rendered .notdef).
  final bool isMissing;

  const GlyphBitmap({
    required this.grapheme,
    required this.codePoint,
    required this.width,
    required this.height,
    required this.advance,
    required this.naturalWidth,
    required this.pixels,
    required this.isMissing,
  });
}

/// Renders graphemes into grayscale bitmaps using Flutter's text engine
/// (Skia paragraph), which provides correct shaping, bidi handling and
/// combining-mark placement out of the box.
class GlyphRenderer {
  final List<String> _families = [];
  int _familyCounter = 0;

  // .notdef reference pixels, cached per render configuration.
  Uint8List? _tofuPixels;
  String? _tofuKey;

  /// Currently loaded font families, primary first, fallbacks after.
  List<String> get families => List.unmodifiable(_families);

  bool get hasFont => _families.isNotEmpty;

  /// Loads a font file (TTF/OTF) and registers it as a temporary family.
  /// The first loaded font becomes the primary family; later ones are
  /// fallbacks used when the primary lacks a glyph.
  Future<String> addFontFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return addFontBytes(bytes);
  }

  /// Registers raw font bytes as a temporary family.
  Future<String> addFontBytes(Uint8List bytes) async {
    final family = 'FEX_${_familyCounter++}';
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _families.add(family);
    _tofuKey = null; // invalidate .notdef cache
    return family;
  }

  /// Removes the most recently added family (e.g. after a failed pick).
  void removeLastFamily() {
    if (_families.isNotEmpty) {
      _families.removeLast();
      _tofuKey = null;
    }
  }

  /// Clears all loaded families.
  void clear() {
    _families.clear();
    _tofuKey = null;
    _tofuPixels = null;
  }

  /// Renders [grapheme] into a cell of [cellWidth]x[cellHeight] grayscale
  /// pixels. The line box (ascent+descent) is centered vertically so marks
  /// above and below the base character stay inside the cell;
  /// [verticalOffset] shifts the glyph down (positive) or up (negative).
  Future<GlyphBitmap> renderGrapheme(
    String grapheme, {
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    double verticalOffset = 0,
  }) async {
    final rendered = await _rasterize(
      grapheme,
      fontSize: fontSize,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      verticalOffset: verticalOffset,
    );

    final isMissing = await _looksLikeTofu(
      rendered.$1,
      fontSize: fontSize,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      verticalOffset: verticalOffset,
    );

    return GlyphBitmap(
      grapheme: grapheme,
      codePoint: grapheme.runes.first,
      width: cellWidth,
      height: cellHeight,
      advance: cellWidth,
      naturalWidth: rendered.$2.ceil(),
      pixels: rendered.$1,
      isMissing: isMissing,
    );
  }

  /// Rasterizes [grapheme]; returns (grayscale pixels, natural ink width).
  Future<(Uint8List, double)> _rasterize(
    String grapheme, {
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    required double verticalOffset,
  }) async {
    final textStyle = ui.TextStyle(
      color: const ui.Color(0xFFFFFFFF),
      fontSize: fontSize,
      fontFamily: _families.isEmpty ? null : _families.first,
      fontFamilyFallback:
          _families.length > 1 ? _families.sublist(1) : const ['monospace'],
    );
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textDirection: ui.TextDirection.ltr),
    )
      ..pushStyle(textStyle)
      ..addText(grapheme);
    final paragraph = builder.build();
    // Layout with unbounded width so we can measure the natural ink size.
    paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));

    final metrics = paragraph.computeLineMetrics();
    final naturalWidth = paragraph.longestLine;
    double dx = 0;
    double dy = verticalOffset;
    double scale = 1.0;
    if (metrics.isNotEmpty) {
      final m = metrics.first;
      // If the glyph is wider than the cell, scale it down so the whole
      // grapheme is visible in the preview and the generated bitmap.
      if (naturalWidth > cellWidth) {
        scale = cellWidth / naturalWidth;
        dx = 0;
      } else {
        dx = (cellWidth - m.width) / 2;
      }
      // Center the scaled line box vertically in the cell.
      dy = (cellHeight - (m.ascent + m.descent) * scale) / 2 + verticalOffset;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);
    canvas.drawParagraph(paragraph, ui.Offset.zero);
    canvas.restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(cellWidth, cellHeight);
    final byteData = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );

    final rgba = byteData!.buffer.asUint8List();
    final gray = Uint8List(cellWidth * cellHeight);
    for (int i = 0; i < gray.length; i++) {
      gray[i] = rgba[i * 4 + 3]; // alpha = coverage
    }

    image.dispose();
    picture.dispose();
    paragraph.dispose();

    return (gray, naturalWidth);
  }

  /// Compares pixels against a cached .notdef render (U+FFFF) to detect
  /// missing glyphs.
  Future<bool> _looksLikeTofu(
    Uint8List pixels, {
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    required double verticalOffset,
  }) async {
    if (!hasFont) return false;

    final key = '${_families.join('|')}|$fontSize|${cellWidth}x$cellHeight|'
        '$verticalOffset';
    if (_tofuKey != key || _tofuPixels == null) {
      final tofu = await _rasterize(
        '\uFFFF',
        fontSize: fontSize,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        verticalOffset: verticalOffset,
      );
      _tofuPixels = tofu.$1;
      _tofuKey = key;
    }

    final ref = _tofuPixels!;
    if (ref.length != pixels.length) return false;
    // An all-blank glyph (e.g. space) is not tofu.
    bool anyOn = false;
    for (int i = 0; i < pixels.length; i++) {
      if (pixels[i] != 0) {
        anyOn = true;
        break;
      }
    }
    if (!anyOn) return false;
    // Identical coverage to .notdef means the font lacks this glyph.
    for (int i = 0; i < pixels.length; i++) {
      if (pixels[i] != ref[i]) return false;
    }
    return true;
  }
}
