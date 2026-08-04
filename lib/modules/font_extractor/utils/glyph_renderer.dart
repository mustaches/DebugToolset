import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;

import 'ebdt_parser.dart';
import 'unicode_assigned.dart';

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
  final Map<String, String> _pathToFamily = {};
  final Map<String, String> _familyToPath = {};
  int _familyCounter = 0;

  // .notdef reference pixels, cached per render configuration (the key
  // includes the effective primary family).
  final Map<String, Uint8List> _tofuPixels = {};

  // Hex-box templates, cached per render configuration (see
  // [_looksLikeHexBox]). Null values mean "no box template for this config".
  final Map<String, _HexBoxTemplate?> _boxTemplates = {};

  /// Currently loaded font families, primary first, fallbacks after.
  List<String> get families => List.unmodifiable(_families);

  bool get hasFont => _families.isNotEmpty;

  /// Returns registered family name for a loaded file path, or null.
  String? getFamilyForPath(String path) => _pathToFamily[path];

  /// Loads a font file (TTF/OTF) and registers it as a temporary family.
  /// Reuses existing registration if already loaded.
  Future<String> addFontFile(String path) async {
    final existing = _pathToFamily[path];
    if (existing != null) return existing;

    final bytes = await File(path).readAsBytes();
    final family = await addFontBytes(bytes);
    _pathToFamily[path] = family;
    _familyToPath[family] = path;
    return family;
  }

  /// Registers raw font bytes as a temporary family.
  Future<String> addFontBytes(Uint8List bytes) async {
    final family = 'FEX_${_familyCounter++}';
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _families.add(family);
    _tofuPixels.clear(); // invalidate .notdef cache
    _boxTemplates.clear();
    _dottedCircleRefs.clear();
    return family;
  }

  /// Removes the most recently added family (e.g. after a failed pick).
  void removeLastFamily() {
    if (_families.isNotEmpty) {
      final removed = _families.removeLast();
      final path = _pathToFamily.entries
          .firstWhere((e) => e.value == removed,
              orElse: () => const MapEntry('', ''))
          .key;
      if (path.isNotEmpty) {
        _pathToFamily.remove(path);
        _familyToPath.remove(removed);
      }
      _tofuPixels.clear();
      _boxTemplates.clear();
      _dottedCircleRefs.clear();
    }
  }

  /// Clears all loaded families.
  void clear() {
    _families.clear();
    _pathToFamily.clear();
    _familyToPath.clear();
    _tofuPixels.clear();
    _boxTemplates.clear();
    _dottedCircleRefs.clear();
  }

  /// Renders [grapheme] into a cell of [cellWidth]x[cellHeight] grayscale
  /// pixels. The line box (ascent+descent) is centered vertically so marks
  /// above and below the base character stay inside the cell;
  /// [verticalOffset] shifts the glyph down (positive) or up (negative).
  /// If [primaryFamily] is specified, attempts rendering with that family first.
  ///
  /// [pixelSnap] controls sub-pixel placement of the glyph origin: when
  /// true (default) the origin is rounded to whole pixels, giving crisp
  /// 1:1 output with no gray fringe — required for pixel fonts rendered at
  /// their design size. When false the origin keeps its fractional part
  /// (smooth positioning), which allows gray edge pixels; useful together
  /// with fractional [verticalOffset] for fine baseline tuning.
  ///
  /// When [cellWidth] is null, the width is measured from the font's actual
  /// glyph advance (for proportional scripts like Devanagari or Arabic):
  /// the measured width is ceiled, aligned up to a multiple of 8px (byte
  /// alignment required by the output bitmap rows) and clamped to
  /// [8, 4 * cellHeight]. Embedded bitmap strikes are skipped in that case
  /// because they require a fixed target cell.
  Future<GlyphBitmap> renderGrapheme(
    String grapheme, {
    required double fontSize,
    required int? cellWidth,
    required int cellHeight,
    double verticalOffset = 0,
    bool pixelSnap = true,
    String? primaryFamily,
  }) async {
    final mainFamily =
        primaryFamily ?? (_families.isEmpty ? null : _families.first);

    // 0. Proportional mode: measure the real advance to size the cell.
    // Width must be a multiple of 8 so every bitmap row is byte-aligned.
    var effectiveCellWidth = cellWidth;
    if (effectiveCellWidth == null) {
      final measured = await _measure(
        grapheme,
        fontSize: fontSize,
        primaryFamily: primaryFamily,
      );
      effectiveCellWidth = _alignUp8(
        measured.ceil().clamp(1, 4 * cellHeight),
      );
    }

    // 0.5 Undisplayable code points (unassigned, noncharacters, control and
    // format characters): fonts like GNU Unifont ship glyphs for the whole
    // BMP and draw these as a box filled with the code point's own hex
    // value. Never export such fake glyphs — return a blank missing glyph.
    if (grapheme.runes.isNotEmpty &&
        isUndisplayableCodePoint(grapheme.runes.first)) {
      return GlyphBitmap(
        grapheme: grapheme,
        codePoint: grapheme.runes.first,
        width: effectiveCellWidth,
        height: cellHeight,
        advance: effectiveCellWidth,
        naturalWidth: 0,
        pixels: Uint8List(effectiveCellWidth * cellHeight),
        isMissing: true,
      );
    }

    // 1. Try native EBLC/EBDT 1-bit embedded bitmap strikes first (e.g. SimSun)
    final fontPath = _familyToPath[mainFamily];
    if (fontPath != null && grapheme.runes.isNotEmpty && cellWidth != null) {
      final nativePixels = await EmbeddedBitmapParser.readNativeBitmap(
        path: fontPath,
        codePoint: grapheme.runes.first,
        targetSize: fontSize.round(),
        cellWidth: effectiveCellWidth,
        cellHeight: cellHeight,
      );
      if (nativePixels != null) {
        return GlyphBitmap(
          grapheme: grapheme,
          codePoint: grapheme.runes.first,
          width: effectiveCellWidth,
          height: cellHeight,
          advance: effectiveCellWidth,
          naturalWidth: effectiveCellWidth,
          pixels: nativePixels,
          isMissing: false,
        );
      }
    }

    // 2. Fall back to Skia vector rasterization with integer pixel-snapping
    final rendered = await _rasterize(
      grapheme,
      fontSize: fontSize,
      cellWidth: effectiveCellWidth,
      cellHeight: cellHeight,
      verticalOffset: verticalOffset,
      pixelSnap: pixelSnap,
      primaryFamily: primaryFamily,
    );

    var isMissing = await _looksLikeTofu(
      rendered.$1,
      fontSize: fontSize,
      cellWidth: effectiveCellWidth,
      cellHeight: cellHeight,
      verticalOffset: verticalOffset,
      pixelSnap: pixelSnap,
      primaryFamily: primaryFamily,
    );
    if (!isMissing) {
      isMissing = await _looksLikeHexBox(
        rendered.$1,
        fontSize: fontSize,
        cellWidth: effectiveCellWidth,
        cellHeight: cellHeight,
        verticalOffset: verticalOffset,
        pixelSnap: pixelSnap,
        primaryFamily: primaryFamily,
      );
    }

    return GlyphBitmap(
      grapheme: grapheme,
      codePoint: grapheme.runes.first,
      width: effectiveCellWidth,
      height: cellHeight,
      advance: effectiveCellWidth,
      naturalWidth: rendered.$2.ceil(),
      // Missing glyphs carry a blank bitmap so no placeholder (.notdef
      // box or fake hex-value box) is ever shown or exported.
      pixels: isMissing ? Uint8List(rendered.$1.length) : rendered.$1,
      isMissing: isMissing,
    );
  }

  /// Rounds [w] up to the next multiple of 8 (byte-aligned bitmap rows).
  static int _alignUp8(int w) => (w + 7) & ~7;

  /// Measures the natural advance width of [grapheme] at [fontSize] using
  /// the same family/fallback setup as rasterization.
  Future<double> _measure(
    String grapheme, {
    required double fontSize,
    String? primaryFamily,
  }) async {
    final mainFamily =
        primaryFamily ?? (_families.isEmpty ? null : _families.first);
    final fallbackFamilies = _families.where((f) => f != mainFamily).toList();
    if (fallbackFamilies.isEmpty) fallbackFamilies.add('monospace');

    final textStyle = ui.TextStyle(
      color: const ui.Color(0xFFFFFFFF),
      fontSize: fontSize,
      fontFamily: mainFamily,
      fontFamilyFallback: fallbackFamilies,
    );
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(textDirection: ui.TextDirection.ltr),
    )
      ..pushStyle(textStyle)
      ..addText(grapheme);
    final paragraph = builder.build();
    paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));
    final width = paragraph.longestLine;
    paragraph.dispose();
    return width;
  }

  /// Rasterizes [grapheme]; returns (grayscale pixels, natural ink width).
  ///
  /// [pixelSnap] rounds the glyph origin to whole pixels (crisp 1:1, no
  /// gray fringe); when false the fractional position is kept (smooth
  /// placement, gray edge pixels possible).
  Future<(Uint8List, double)> _rasterize(
    String grapheme, {
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    required double verticalOffset,
    bool pixelSnap = true,
    String? primaryFamily,
  }) async {
    final mainFamily =
        primaryFamily ?? (_families.isEmpty ? null : _families.first);
    final fallbackFamilies = _families.where((f) => f != mainFamily).toList();
    if (fallbackFamilies.isEmpty) fallbackFamilies.add('monospace');

    final textStyle = ui.TextStyle(
      color: const ui.Color(0xFFFFFFFF),
      fontSize: fontSize,
      fontFamily: mainFamily,
      fontFamilyFallback: fallbackFamilies,
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

    if (metrics.isNotEmpty) {
      final m = metrics.first;
      dx = (cellWidth - naturalWidth) / 2;
      dy = (cellHeight - (m.ascent + m.descent)) / 2 + verticalOffset;
      if (pixelSnap) {
        // 1:1 Hard integer pixel alignment
        dx = dx.roundToDouble();
        dy = dy.roundToDouble();
      }
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.save();
    canvas.translate(dx, dy);
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
  /// missing glyphs. [pixelSnap] must match the candidate's render config
  /// so the reference is pixel-comparable.
  Future<bool> _looksLikeTofu(
    Uint8List pixels, {
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    required double verticalOffset,
    bool pixelSnap = true,
    String? primaryFamily,
  }) async {
    if (!hasFont) return false;

    final mainFamily =
        primaryFamily ?? (_families.isEmpty ? null : _families.first);
    final key = '$mainFamily|${_families.join('|')}|$fontSize|'
        '${cellWidth}x$cellHeight|$verticalOffset|$pixelSnap';
    var ref = _tofuPixels[key];
    if (ref == null) {
      final tofu = await _rasterize(
        '\uFFFF',
        fontSize: fontSize,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        verticalOffset: verticalOffset,
        pixelSnap: pixelSnap,
        primaryFamily: primaryFamily,
      );
      ref = tofu.$1;
      _tofuPixels[key] = ref;
    }

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

  /// Code points that are unassigned in every Unicode version (both older
  /// than any font we may load and still unassigned in Unicode 16), chosen
  /// so their hex representations differ in every digit position. Fonts like
  /// GNU Unifont claim the whole BMP in their cmap and draw these as a box
  /// filled with the code point's own hex digits.
  static const _hexBoxProbes = [0x0378, 0x0379, 0x2FE0, 0x2FE1];

  /// Grayscale level at or above which a pixel counts as ink.
  static const _inkThreshold = 128;

  /// Detects fake "hex box" glyphs: some fonts (e.g. GNU Unifont) contain
  /// glyphs for code points that were unassigned when the font was made but
  /// got assigned later (e.g. U+20C0, added in Unicode 14, in a Unicode 13
  /// font). Those glyphs are boxes filled with the code point's own hex
  /// value, not real characters.
  ///
  /// A template is built per render configuration by rendering
  /// [_hexBoxProbes]: pixels lit in every probe form the box frame, and the
  /// bounding box of the varying pixels covers the digit area. A candidate
  /// is fake when it carries the full frame and has no ink outside the
  /// frame plus digit area. When the probes don't form a consistent box
  /// family (normal fonts render .notdef or nothing for them), detection is
  /// disabled and this always returns false.
  Future<bool> _looksLikeHexBox(
    Uint8List pixels, {
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    required double verticalOffset,
    bool pixelSnap = true,
    String? primaryFamily,
  }) async {
    if (!hasFont) return false;

    final mainFamily =
        primaryFamily ?? (_families.isEmpty ? null : _families.first);
    final key = '$mainFamily|${_families.join('|')}|$fontSize|'
        '${cellWidth}x$cellHeight|$verticalOffset|$pixelSnap';
    var template = _boxTemplates[key];
    if (template == null && !_boxTemplates.containsKey(key)) {
      template = await _buildHexBoxTemplate(
        fontSize: fontSize,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        verticalOffset: verticalOffset,
        pixelSnap: pixelSnap,
        primaryFamily: primaryFamily,
      );
      _boxTemplates[key] = template;
    }
    if (template == null) return false;
    if (pixels.length != template.frameMask.length) return false;

    if (_matchesHexBoxTemplate(pixels, template, cellWidth, cellHeight)) {
      return true;
    }

    // Standalone combining marks (e.g. U+1715, a Mc mark unassigned when
    // the font was made) get a dotted circle (U+25CC) prepended by the
    // shaping engine, pushing the placeholder box to the right so the
    // direct match above fails. Strip the dotted circle, re-center the
    // remaining ink, and match again.
    final stripped = await _stripDottedCircle(
      pixels,
      fontSize: fontSize,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      verticalOffset: verticalOffset,
      pixelSnap: pixelSnap,
      primaryFamily: primaryFamily,
    );
    if (stripped == null) return false;
    return _matchesHexBoxTemplate(stripped, template, cellWidth, cellHeight);
  }

  /// Matches [pixels] against the hex box [template]: the candidate must
  /// carry (nearly) the full box frame and have no ink outside the frame
  /// plus digit area.
  bool _matchesHexBoxTemplate(Uint8List pixels, _HexBoxTemplate template,
      int cellWidth, int cellHeight) {
    // The candidate must carry (nearly) the full box frame.
    int frameOff = 0;
    for (int i = 0; i < pixels.length; i++) {
      if (template.frameMask[i] && pixels[i] < _inkThreshold) frameOff++;
    }
    if (frameOff > 1 + template.frameCount ~/ 50) return false;

    // ... and no ink outside the frame plus digit area.
    int outsideInk = 0;
    for (int y = 0; y < cellHeight; y++) {
      for (int x = 0; x < cellWidth; x++) {
        final i = y * cellWidth + x;
        if (template.frameMask[i] || pixels[i] < _inkThreshold) continue;
        if (x >= template.digitLeft &&
            x <= template.digitRight &&
            y >= template.digitTop &&
            y <= template.digitBottom) {
          continue;
        }
        outsideInk++;
      }
    }
    return outsideInk <= 1 + pixels.length ~/ 200;
  }

  // Dotted circle (U+25CC) reference pixels, cached per render
  // configuration. Null values mean "font has no dotted circle glyph".
  final Map<String, Uint8List?> _dottedCircleRefs = {};

  /// Locates the dotted circle the shaping engine prepends to standalone
  /// combining marks inside [pixels], erases it and re-centers the
  /// remaining ink in the cell. Returns null when the font has no dotted
  /// circle glyph or [pixels] does not start with one.
  Future<Uint8List?> _stripDottedCircle(
    Uint8List pixels, {
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    required double verticalOffset,
    bool pixelSnap = true,
    String? primaryFamily,
  }) async {
    final mainFamily =
        primaryFamily ?? (_families.isEmpty ? null : _families.first);
    final key = '$mainFamily|${_families.join('|')}|$fontSize|'
        '${cellWidth}x$cellHeight|$verticalOffset|$pixelSnap';
    var ref = _dottedCircleRefs[key];
    if (ref == null && !_dottedCircleRefs.containsKey(key)) {
      ref = (await _rasterize(
        '◌',
        fontSize: fontSize,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        verticalOffset: verticalOffset,
        pixelSnap: pixelSnap,
        primaryFamily: primaryFamily,
      ))
          .$1;
      _dottedCircleRefs[key] = ref;
    }
    if (ref == null) return null;

    // Bounding box of the reference's ink.
    int bx0 = cellWidth, by0 = cellHeight, bx1 = -1, by1 = -1;
    int refOnCount = 0;
    for (int y = 0; y < cellHeight; y++) {
      for (int x = 0; x < cellWidth; x++) {
        if (ref[y * cellWidth + x] >= _inkThreshold) {
          refOnCount++;
          if (x < bx0) bx0 = x;
          if (x > bx1) bx1 = x;
          if (y < by0) by0 = y;
          if (y > by1) by1 = y;
        }
      }
    }
    if (refOnCount == 0) return null;
    final bw = bx1 - bx0 + 1;
    final bh = by1 - by0 + 1;

    // Slide the reference pattern horizontally across the candidate (the
    // vertical position is identical: same font, size and line metrics).
    int? foundX;
    for (int ox = 0; ox + bw <= cellWidth; ox++) {
      int missing = 0;
      int extra = 0;
      for (int y = 0; y < bh; y++) {
        for (int x = 0; x < bw; x++) {
          final refOn = ref[(by0 + y) * cellWidth + bx0 + x] >= _inkThreshold;
          final candOn = pixels[(by0 + y) * cellWidth + ox + x] != 0;
          if (refOn && !candOn) missing++;
          if (!refOn && candOn) extra++;
        }
      }
      if (missing <= 1 + refOnCount ~/ 20 &&
          extra <= 2 + refOnCount ~/ 10) {
        foundX = ox;
        break;
      }
    }
    if (foundX == null) return null;

    // Erase the dotted circle area, then re-center the remaining ink so it
    // lines up with the probe boxes (same ink shape, same centering).
    final out = Uint8List.fromList(pixels);
    for (int y = 0; y < bh; y++) {
      for (int x = 0; x < bw; x++) {
        out[(by0 + y) * cellWidth + foundX + x] = 0;
      }
    }
    int ix0 = cellWidth, iy0 = cellHeight, ix1 = -1, iy1 = -1;
    for (int y = 0; y < cellHeight; y++) {
      for (int x = 0; x < cellWidth; x++) {
        if (out[y * cellWidth + x] >= _inkThreshold) {
          if (x < ix0) ix0 = x;
          if (x > ix1) ix1 = x;
          if (y < iy0) iy0 = y;
          if (y > iy1) iy1 = y;
        }
      }
    }
    if (ix1 < 0) return Uint8List(cellWidth * cellHeight); // nothing left
    final inkW = ix1 - ix0 + 1;
    final inkH = iy1 - iy0 + 1;
    final dx = ((cellWidth - inkW) / 2).floor() - ix0;
    final dy = ((cellHeight - inkH) / 2).floor() - iy0;
    final shifted = Uint8List(cellWidth * cellHeight);
    for (int y = 0; y < cellHeight; y++) {
      final sy = y - dy;
      if (sy < 0 || sy >= cellHeight) continue;
      for (int x = 0; x < cellWidth; x++) {
        final sx = x - dx;
        if (sx < 0 || sx >= cellWidth) continue;
        shifted[y * cellWidth + x] = out[sy * cellWidth + sx];
      }
    }
    return shifted;
  }

  /// Renders the probe code points and derives the box template, or returns
  /// null when the font does not draw hex boxes for the probes.
  Future<_HexBoxTemplate?> _buildHexBoxTemplate({
    required double fontSize,
    required int cellWidth,
    required int cellHeight,
    required double verticalOffset,
    bool pixelSnap = true,
    String? primaryFamily,
  }) async {
    final probes = <Uint8List>[];
    for (final cp in _hexBoxProbes) {
      final rendered = await _rasterize(
        String.fromCharCode(cp),
        fontSize: fontSize,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        verticalOffset: verticalOffset,
        pixelSnap: pixelSnap,
        primaryFamily: primaryFamily,
      );
      if (rendered.$1.length != cellWidth * cellHeight) return null;
      probes.add(rendered.$1);
    }

    final pixelCount = cellWidth * cellHeight;
    final allOn = List<bool>.filled(pixelCount, false);
    int varCount = 0;
    int left = cellWidth, top = cellHeight, right = -1, bottom = -1;
    for (int i = 0; i < pixelCount; i++) {
      int onCount = 0;
      for (final p in probes) {
        if (p[i] >= _inkThreshold) onCount++;
      }
      if (onCount == probes.length) {
        allOn[i] = true;
      } else if (onCount > 0) {
        varCount++;
        final x = i % cellWidth;
        final y = i ~/ cellWidth;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }

    // A valid template needs digit positions that actually vary between
    // probes (identical probes would be .notdef).
    if (varCount < 4 || varCount > pixelCount * 3 ~/ 5) return null;

    // The frame is what all probes share OUTSIDE the digit area. Pixels
    // shared inside the digit area are accidental overlaps between the
    // probe's specific digit shapes — keeping them in the frame would make
    // the check depend on the candidate's own digits and miss boxes.
    final frameMask = List<bool>.filled(pixelCount, false);
    int frameCount = 0;
    for (int y = 0; y < cellHeight; y++) {
      for (int x = 0; x < cellWidth; x++) {
        final i = y * cellWidth + x;
        if (allOn[i] &&
            !(x >= left && x <= right && y >= top && y <= bottom)) {
          frameMask[i] = true;
          frameCount++;
        }
      }
    }
    if (frameCount < 8) return null;

    // Grow the digit area by 1px so any digit shape fits inside it.
    left = left > 0 ? left - 1 : 0;
    top = top > 0 ? top - 1 : 0;
    if (right < cellWidth - 1) right++;
    if (bottom < cellHeight - 1) bottom++;

    return _HexBoxTemplate(
      frameMask: frameMask,
      frameCount: frameCount,
      digitLeft: left,
      digitTop: top,
      digitRight: right,
      digitBottom: bottom,
    );
  }
}

/// Box template derived from a font's hex-box placeholder glyphs; see
/// [GlyphRenderer._looksLikeHexBox].
class _HexBoxTemplate {
  /// Pixels lit in every probe (the box frame), length = cellWidth*cellHeight.
  final List<bool> frameMask;
  final int frameCount;

  /// Bounding box (inclusive) of the pixels that vary between probes,
  /// covering the digit area inside the frame.
  final int digitLeft;
  final int digitTop;
  final int digitRight;
  final int digitBottom;

  const _HexBoxTemplate({
    required this.frameMask,
    required this.frameCount,
    required this.digitLeft,
    required this.digitTop,
    required this.digitRight,
    required this.digitBottom,
  });
}
