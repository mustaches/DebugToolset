import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../modules/font_extractor/utils/binary_exporter.dart';
import '../modules/font_extractor/utils/bitmap_converter.dart';
import '../modules/font_extractor/utils/c_array_exporter.dart';
import '../modules/font_extractor/utils/glyph_renderer.dart';
import '../modules/font_extractor/utils/packed_glyph.dart';
import '../modules/font_extractor/utils/unicode_blocks.dart';

/// State for the Font Extractor module.
class FontExtractorState extends ChangeNotifier {
  final GlyphRenderer _renderer = GlyphRenderer();

  // Font sources
  final List<String> _fontPaths = [];

  // Render settings
  double _fontSize = 14;
  int _cellWidth = 8;
  int _cellHeight = 16;
  double _verticalOffset = 0;
  BitmapBitDepth _bitDepth = BitmapBitDepth.one;
  BitmapScanMode _scanMode = BitmapScanMode.rowMajor;
  int _threshold = 128;
  bool _showCellGrid = false;

  // Character set
  final Set<int> _selectedBlockIndexes = {0}; // Basic Latin by default
  String _customRangeInput = '';
  String _importedText = '';

  // Preview
  List<GlyphBitmap> _previewGlyphs = [];
  bool _previewLoading = false;
  double _previewProgress = 0;

  // Generation
  bool _isGenerating = false;
  double _progress = 0;
  bool _cancelRequested = false;
  String? _lastError;
  String? _lastOutputDir;

  // ------------------------------------------------------------------
  // Getters
  // ------------------------------------------------------------------
  List<String> get fontPaths => List.unmodifiable(_fontPaths);
  double get fontSize => _fontSize;
  int get cellWidth => _cellWidth;
  int get cellHeight => _cellHeight;
  double get verticalOffset => _verticalOffset;
  BitmapBitDepth get bitDepth => _bitDepth;
  BitmapScanMode get scanMode => _scanMode;
  int get threshold => _threshold;
  bool get showCellGrid => _showCellGrid;
  Set<int> get selectedBlockIndexes => Set.unmodifiable(_selectedBlockIndexes);
  String get customRangeInput => _customRangeInput;
  String get importedText => _importedText;
  List<GlyphBitmap> get previewGlyphs => List.unmodifiable(_previewGlyphs);
  bool get previewLoading => _previewLoading;
  double get previewProgress => _previewProgress;
  bool get isGenerating => _isGenerating;
  double get progress => _progress;
  String? get lastError => _lastError;
  String? get lastOutputDir => _lastOutputDir;

  // ------------------------------------------------------------------
  // Font management
  // ------------------------------------------------------------------
  Future<void> addFontFile(String path) async {
    try {
      await _renderer.addFontFile(path);
      _fontPaths.add(path);
      _lastError = null;
    } catch (e) {
      _lastError = '字体加载失败: $e';
    }
    notifyListeners();
  }

  void removeFontAt(int index) {
    if (index < 0 || index >= _fontPaths.length) return;
    _fontPaths.removeAt(index);
    _renderer.removeLastFamily();
    notifyListeners();
  }

  void clearFonts() {
    _fontPaths.clear();
    _renderer.clear();
    _previewGlyphs = [];
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Settings
  // ------------------------------------------------------------------
  void setFontSize(double v) {
    _fontSize = v.clamp(4, 200);
    notifyListeners();
  }

  void setCellSize(int w, int h) {
    _cellWidth = w.clamp(1, 256);
    _cellHeight = h.clamp(1, 256);
    notifyListeners();
  }

  void setVerticalOffset(double v) {
    _verticalOffset = v;
    notifyListeners();
  }

  void setBitDepth(BitmapBitDepth v) {
    _bitDepth = v;
    notifyListeners();
  }

  void setScanMode(BitmapScanMode v) {
    _scanMode = v;
    notifyListeners();
  }

  void setThreshold(int v) {
    _threshold = v.clamp(0, 255);
    notifyListeners();
  }

  void setShowCellGrid(bool v) {
    _showCellGrid = v;
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Character set
  // ------------------------------------------------------------------
  void toggleBlock(int index, bool selected) {
    if (selected) {
      _selectedBlockIndexes.add(index);
    } else {
      _selectedBlockIndexes.remove(index);
    }
    notifyListeners();
  }

  void setCustomRangeInput(String v) {
    _customRangeInput = v;
    notifyListeners();
  }

  Future<void> importTextFile(String path) async {
    try {
      _importedText = await File(path).readAsString();
      _lastError = null;
    } catch (e) {
      _lastError = '文本导入失败: $e';
    }
    notifyListeners();
  }

  void clearImportedText() {
    _importedText = '';
    notifyListeners();
  }

  /// Builds the final grapheme list from blocks, custom ranges and the
  /// imported text (deduplicated, stable order).
  List<String> buildCharset() {
    final codePoints = expandToCodePoints(
      blocks: _selectedBlockIndexes.map((i) => kUnicodeBlocks[i]),
      customRanges: _parseRangesSafe(),
    );
    final seen = <int>{};
    final out = <String>[];
    for (final cp in codePoints) {
      if (seen.add(cp)) out.add(String.fromCharCode(cp));
    }
    for (final g in _importedText.characters) {
      if (g.trim().isEmpty) continue;
      final cp = g.runes.first;
      if (seen.add(cp)) out.add(g);
    }
    return out;
  }

  int get charsetSize {
    int size = 0;
    for (final i in _selectedBlockIndexes) {
      size += kUnicodeBlocks[i].length;
    }
    for (final r in _parseRangesSafe()) {
      size += r.end - r.start + 1;
    }
    return size;
  }

  List<({int start, int end})> _parseRangesSafe() {
    if (_customRangeInput.trim().isEmpty) return const [];
    try {
      return parseRangeInput(_customRangeInput);
    } on FormatException {
      return const [];
    }
  }

  String? get customRangeError {
    if (_customRangeInput.trim().isEmpty) return null;
    try {
      parseRangeInput(_customRangeInput);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  // ------------------------------------------------------------------
  // Preview
  // ------------------------------------------------------------------

  /// Default preview size when no preview range is specified.
  static const int previewLimit = 200;

  String _previewRangeInput = '';
  String get previewRangeInput => _previewRangeInput;

  void setPreviewRangeInput(String v) {
    _previewRangeInput = v;
    notifyListeners();
  }

  String? get previewRangeError {
    if (_previewRangeInput.trim().isEmpty) return null;
    try {
      parseRangeInput(_previewRangeInput);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  List<({int start, int end})> _previewRangesSafe() {
    if (_previewRangeInput.trim().isEmpty) return const [];
    try {
      return parseRangeInput(_previewRangeInput);
    } on FormatException {
      return const [];
    }
  }

  Future<void> refreshPreview() async {
    if (!_renderer.hasFont) {
      _lastError = '请先加载字体文件';
      notifyListeners();
      return;
    }
    _previewLoading = true;
    _previewProgress = 0;
    _lastError = null;
    notifyListeners();

    try {
      // A valid preview range overrides the charset (rendered in full,
      // with progress feedback); otherwise preview the first
      // [previewLimit] graphemes of the charset.
      final previewRanges = _previewRangesSafe();
      final List<String> subset;
      if (previewRanges.isNotEmpty) {
        subset = expandToCodePoints(customRanges: previewRanges)
            .map(String.fromCharCode)
            .toList();
      } else {
        subset = buildCharset().take(previewLimit).toList();
      }
      final glyphs = <GlyphBitmap>[];
      for (int i = 0; i < subset.length; i++) {
        glyphs.add(await _render(subset[i]));
        _previewProgress = (i + 1) / subset.length;
        // Throttle notifications so huge ranges don't spam rebuilds.
        if (i % 16 == 15 || i == subset.length - 1) notifyListeners();
      }
      _previewGlyphs = glyphs;
    } catch (e) {
      _lastError = '预览渲染失败: $e';
    }
    _previewLoading = false;
    notifyListeners();
  }

  Future<GlyphBitmap> _render(String grapheme) {
    return _renderer.renderGrapheme(
      grapheme,
      fontSize: _fontSize,
      cellWidth: _cellWidth,
      cellHeight: _cellHeight,
      verticalOffset: _verticalOffset,
    );
  }

  // ------------------------------------------------------------------
  // Generation
  // ------------------------------------------------------------------
  void cancelGenerate() {
    _cancelRequested = true;
  }

  /// Renders the full charset, packs bitmaps and writes the chosen output
  /// files into [outputDir] with base name [baseName].
  Future<bool> generate({
    required String outputDir,
    required String baseName,
    bool writeC = true,
    bool writeBin = true,
  }) async {
    if (!_renderer.hasFont) {
      _lastError = '请先加载字体文件';
      notifyListeners();
      return false;
    }
    _isGenerating = true;
    _cancelRequested = false;
    _progress = 0;
    _lastError = null;
    notifyListeners();

    try {
      final charset = buildCharset();
      final packed = <PackedGlyph>[];
      const chunk = 100;
      for (int i = 0; i < charset.length; i += chunk) {
        if (_cancelRequested) {
          _lastError = '已取消';
          _isGenerating = false;
          notifyListeners();
          return false;
        }
        final end = (i + chunk > charset.length) ? charset.length : i + chunk;
        for (int j = i; j < end; j++) {
          final bmp = await _render(charset[j]);
          if (bmp.isMissing) continue; // skip glyphs the font cannot draw
          final bytes = packBitmap(
            pixels: bmp.pixels,
            width: bmp.width,
            height: bmp.height,
            depth: _bitDepth,
            scan: _scanMode,
            threshold: _threshold,
          );
          packed.add(PackedGlyph(
            codePoint: bmp.codePoint,
            width: bmp.width,
            height: bmp.height,
            advance: bmp.advance,
            offsetX: 0,
            offsetY: 0,
            data: bytes,
          ));
        }
        _progress = end / charset.length;
        notifyListeners();
        await Future.delayed(Duration.zero);
      }

      final fontLabel =
          '${_fontPaths.isNotEmpty ? p.basename(_fontPaths.first) : 'font'} '
          '${_fontSize.toStringAsFixed(0)}px ${_cellWidth}x$_cellHeight';

      if (writeC) {
        final result = CArrayExporter.export(
          symbolName: _sanitizeSymbol(baseName),
          fontLabel: fontLabel,
          cellWidth: _cellWidth,
          cellHeight: _cellHeight,
          bitsPerPixel: _bitDepth == BitmapBitDepth.one ? 1 : 8,
          glyphs: packed,
        );
        await File(p.join(outputDir, '${baseName}_font.c'))
            .writeAsString(result.source);
        await File(p.join(outputDir, '${baseName}_font.h'))
            .writeAsString(result.header);
      }
      if (writeBin) {
        final bin = BinaryExporter.export(
          cellWidth: _cellWidth,
          cellHeight: _cellHeight,
          bitsPerPixel: _bitDepth == BitmapBitDepth.one ? 1 : 8,
          columnMajor: _scanMode == BitmapScanMode.columnMajor,
          glyphs: packed,
        );
        await File(p.join(outputDir, '$baseName.bin'))
            .writeAsBytes(Uint8List.fromList(bin));
      }

      _lastOutputDir = outputDir;
      _isGenerating = false;
      _progress = 1;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = '生成失败: $e';
      _isGenerating = false;
      notifyListeners();
      return false;
    }
  }

  String _sanitizeSymbol(String name) {
    final s = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    if (s.isEmpty || RegExp(r'^[0-9]').hasMatch(s)) return 'font_$s';
    return s;
  }
}
