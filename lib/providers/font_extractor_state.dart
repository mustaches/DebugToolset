import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../modules/font_extractor/models/lang_binding.dart';
import '../modules/font_extractor/utils/binary_exporter.dart';
import '../modules/font_extractor/utils/bitmap_converter.dart';
import '../modules/font_extractor/utils/c_array_exporter.dart';
import '../modules/font_extractor/utils/font_coverage.dart';
import '../modules/font_extractor/utils/font_info.dart';
import '../modules/font_extractor/utils/glyph_renderer.dart';
import '../modules/font_extractor/utils/packed_glyph.dart';
import '../modules/font_extractor/utils/unicode_blocks.dart';
import '../modules/font_extractor/utils/width_classify.dart';

enum FontExtractMode {
  /// 主字体 + 后备字体级联回退 (默认)
  fallback,

  /// 多语言/字符类别绑定专属字体模式
  multiLang,
}

/// A group of rendered preview glyphs for a single character set / Unicode block.
class BlockPreviewGroup {
  /// Name of the character set block (e.g. "基本拉丁字母 (Basic Latin)")
  final String blockName;

  /// Range string (e.g. "U+0020-U+007E")
  final String rangeLabel;

  /// List of rendered glyphs in this block
  final List<GlyphBitmap> glyphs;

  /// True if none of the characters in this block exist in the current font
  final bool isMissingInFont;

  /// Display name of the active font
  final String fontName;

  const BlockPreviewGroup({
    required this.blockName,
    required this.rangeLabel,
    required this.glyphs,
    required this.isMissingInFont,
    required this.fontName,
  });
}

/// State for the Font Extractor module.
class FontExtractorState extends ChangeNotifier {
  final GlyphRenderer _renderer = GlyphRenderer();

  // Font sources
  final List<String> _fontPaths = [];
  final Map<String, String> _fontDisplayNames = {};

  // Extraction Mode & Language Bindings
  FontExtractMode _extractMode = FontExtractMode.fallback;
  final List<LangBinding> _langBindings = LangBinding.defaultPresets();
  int _nextBoundOrder = 0;

  void _sortLangBindings() {
    _langBindings.sort((a, b) {
      if (a.boundOrder != null && b.boundOrder != null) {
        return a.boundOrder!.compareTo(b.boundOrder!);
      }
      if (a.boundOrder != null) return -1;
      if (b.boundOrder != null) return 1;
      return a.originalIndex.compareTo(b.originalIndex);
    });
  }

  // Render settings
  double _fontSize = 16;
  int _cellWidth = 8;
  int _cellHeight = 16;
  double _cjkFontSize = 16;
  int _cjkCellSize = 16;
  double _verticalOffset = 0;
  BitmapBitDepth _bitDepth = BitmapBitDepth.one;
  BitmapScanMode _scanMode = BitmapScanMode.rowMajor;
  int _threshold = 128;
  bool _showCellGrid = false;
  bool _showThresholdPreview = true;
  bool _pixelSnap = true;

  // Character set
  final Set<int> _selectedBlockIndexes = {}; // Empty by default when no font is loaded
  String _customRangeInput = '';
  String _importedText = '';

  // Preview
  List<BlockPreviewGroup> _previewGroups = [];
  List<GlyphBitmap> _previewGlyphs = [];
  bool _previewLoading = false;
  double _previewProgress = 0;
  bool _autoRefreshPreview = true;
  int _previewLimit = 100;
  Timer? _autoRefreshTimer;

  // Generation
  bool _isGenerating = false;
  double _progress = 0;
  bool _cancelRequested = false;
  String? _lastError;
  String? _lastOutputDir;

  // ------------------------------------------------------------------
  // Getters
  // ------------------------------------------------------------------
  FontExtractMode get extractMode => _extractMode;
  List<LangBinding> get langBindings => List.unmodifiable(_langBindings);

  List<String> get fontPaths => List.unmodifiable(_fontPaths);
  List<BlockPreviewGroup> get previewGroups => List.unmodifiable(_previewGroups);

  /// User-friendly name for a loaded font (its localized name-table entry,
  /// e.g. "微软雅黑"), falling back to the file name when unavailable.
  ///
  /// The lookup is lazy: if the name has not been resolved yet (e.g. the
  /// font was loaded before this cache existed, or a hot reload dropped the
  /// pending call), it kicks off the asynchronous read now and the UI
  /// updates when it completes.
  String fontDisplayName(String path) {
    final cached = _fontDisplayNames[path];
    if (cached == null) _loadDisplayName(path);
    return cached ?? p.basename(path);
  }
  double get fontSize => _fontSize;
  int get cellWidth => _cellWidth;
  int get cellHeight => _cellHeight;
  double get cjkFontSize => _cjkFontSize;
  int get cjkCellSize => _cjkCellSize;
  double get verticalOffset => _verticalOffset;
  BitmapBitDepth get bitDepth => _bitDepth;
  BitmapScanMode get scanMode => _scanMode;
  int get threshold => _threshold;
  bool get showCellGrid => _showCellGrid;
  bool get showThresholdPreview => _showThresholdPreview;
  bool get pixelSnap => _pixelSnap;
  Set<int> get selectedBlockIndexes => Set.unmodifiable(_selectedBlockIndexes);
  String get customRangeInput => _customRangeInput;
  String get importedText => _importedText;
  List<GlyphBitmap> get previewGlyphs => List.unmodifiable(_previewGlyphs);
  bool get previewLoading => _previewLoading;
  double get previewProgress => _previewProgress;
  bool get autoRefreshPreview => _autoRefreshPreview;
  int get previewLimit => _previewLimit;
  bool get isGenerating => _isGenerating;
  double get progress => _progress;
  String? get lastError => _lastError;
  String? get lastOutputDir => _lastOutputDir;

  // ------------------------------------------------------------------
  // Font management
  // ------------------------------------------------------------------
  Future<void> addFontFile(String path) async {
    final isFirstFont = _fontPaths.isEmpty;
    try {
      await _renderer.addFontFile(path);
      _fontPaths.add(path);
      if (isFirstFont && _selectedBlockIndexes.isEmpty) {
        _selectedBlockIndexes.add(0); // Auto-select Basic Latin for the first font
      }
      _lastError = null;
    } catch (e) {
      _lastError = '字体加载失败: $e';
      notifyListeners();
    }
    _loadDisplayName(path);
    _scheduleAutoRefresh();
  }

  /// Reads the font's localized display name in the background and updates
  /// the cache once available. Each path is attempted only once; on failure
  /// the UI keeps falling back to the file name.
  final Set<String> _displayNameAttempted = {};

  Future<void> _loadDisplayName(String path) async {
    if (_fontDisplayNames.containsKey(path) ||
        !_displayNameAttempted.add(path)) {
      return;
    }
    final info = await readFontNameInfo(path);
    final name = info.displayName;
    if (name != null && name.isNotEmpty && _fontPaths.contains(path)) {
      _fontDisplayNames[path] = name;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------
  // Pixel font design-size warning
  // ------------------------------------------------------------------

  /// Per-path cache of detected pixel-font design sizes (empty = unknown).
  final Map<String, List<int>> _pixelDesignSizes = {};
  final Set<String> _pixelDesignSizesAttempted = {};

  /// Warning shown when the primary font is a pixel font whose design size
  /// does not match the current render size (non-integer scaling blurs the
  /// output). Null when the size matches or the design size is unknown.
  ///
  /// The design-size detection runs lazily in the background (same pattern
  /// as [fontDisplayName]); the warning appears once detection completes.
  String? get pixelFontSizeWarning {
    if (_fontPaths.isEmpty) return null;
    final path = _fontPaths.first;
    final sizes = _pixelDesignSizes[path];
    if (sizes == null) {
      _loadPixelDesignSizes(path);
      return null;
    }
    if (sizes.isEmpty) return null;

    final sizeText = sizes.map((s) => '${s}px').join(' / ');
    final String? mismatch;
    if (!sizes.contains(_fontSize.round())) {
      mismatch = '当前字号 ${_fontSize.round()}px';
    } else if (!sizes.contains(_cjkFontSize.round())) {
      mismatch = '当前全角字号 ${_cjkFontSize.round()}px';
    } else {
      mismatch = null;
    }
    if (mismatch == null) return null;
    return '“${fontDisplayName(path)}”设计点阵尺寸为 $sizeText，$mismatch，'
        '非整数缩放会导致发糊，建议改为 $sizeText';
  }

  Future<void> _loadPixelDesignSizes(String path) async {
    if (_pixelDesignSizes.containsKey(path) ||
        !_pixelDesignSizesAttempted.add(path)) {
      return;
    }
    final sizes = await detectPixelFontDesignSizes(path);
    if (_fontPaths.contains(path)) {
      _pixelDesignSizes[path] = sizes;
      notifyListeners();
    }
  }

  void removeFontAt(int index) {
    if (index < 0 || index >= _fontPaths.length) return;
    final path = _fontPaths[index];
    _fontDisplayNames.remove(path);
    _displayNameAttempted.remove(path);
    _pixelDesignSizes.remove(path);
    _pixelDesignSizesAttempted.remove(path);
    _fontPaths.removeAt(index);
    _renderer.clear();
    for (final p in _fontPaths) {
      _renderer.addFontFile(p);
    }
    if (_fontPaths.isEmpty) {
      _previewGlyphs.clear();
      _previewGroups.clear();
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void removeFontFile(String path) {
    _fontPaths.remove(path);
    _fontDisplayNames.remove(path);
    _displayNameAttempted.remove(path);
    _pixelDesignSizes.remove(path);
    _pixelDesignSizesAttempted.remove(path);
    _renderer.clear();
    for (final p in _fontPaths) {
      _renderer.addFontFile(p);
    }
    if (_fontPaths.isEmpty) {
      _previewGlyphs.clear();
      _previewGroups.clear();
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void clearFonts() {
    _fontPaths.clear();
    _fontDisplayNames.clear();
    _displayNameAttempted.clear();
    _pixelDesignSizes.clear();
    _pixelDesignSizesAttempted.clear();
    _renderer.clear();
    _previewGlyphs.clear();
    _previewGroups.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Render settings
  // ------------------------------------------------------------------
  void setFontSize(double v) {
    _fontSize = v.clamp(4.0, 128.0);
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setCellSize(int w, int h) {
    _cellWidth = w.clamp(1, 128);
    _cellHeight = h.clamp(1, 128);
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setCellWidth(int v) {
    _cellWidth = v.clamp(1, 128);
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setCellHeight(int v) {
    _cellHeight = v.clamp(1, 128);
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setCjkFontSize(double v) {
    _cjkFontSize = v.clamp(4.0, 128.0);
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setCjkCellSize(int v) {
    _cjkCellSize = v.clamp(1, 128);
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setVerticalOffset(double v) {
    _verticalOffset = v.clamp(-64.0, 64.0);
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setBitDepth(BitmapBitDepth v) {
    _bitDepth = v;
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setScanMode(BitmapScanMode v) {
    _scanMode = v;
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setThreshold(int v) {
    _threshold = v.clamp(0, 255);
    notifyListeners();
  }

  void setShowCellGrid(bool v) {
    _showCellGrid = v;
    notifyListeners();
  }

  void setShowThresholdPreview(bool v) {
    _showThresholdPreview = v;
    notifyListeners();
  }

  void setPixelSnap(bool v) {
    _pixelSnap = v;
    notifyListeners();
    _scheduleAutoRefresh();
  }

  /// Preset helper: sets cell size & font size to 1:1 integer values
  /// (e.g. 8x16, 16x16, font size = height) and enables pixelSnap.
  void applyOneToOnePreset({
    int width = 8,
    int height = 16,
    int cjkSize = 16,
  }) {
    _cellWidth = width;
    _cellHeight = height;
    _fontSize = height.toDouble();
    _cjkCellSize = cjkSize;
    _cjkFontSize = cjkSize.toDouble();
    _pixelSnap = true;
    notifyListeners();
    _scheduleAutoRefresh();
  }

  // ------------------------------------------------------------------
  // Character set
  // ------------------------------------------------------------------
  Set<int>? _previousBlockIndexes;
  bool _noneSelected = false;
  Set<int>? _indexesBeforeNone;

  bool get isAllBlocksSelected =>
      kUnicodeBlocks.isNotEmpty &&
      _selectedBlockIndexes.length == kUnicodeBlocks.length;

  /// Whether the "全不选" checkbox is active (all blocks force-unchecked,
  /// with the previous selection saved for restore).
  bool get isNoneSelected => _noneSelected;

  void toggleSelectAllBlocks(bool selectAll) {
    if (selectAll) {
      if (!isAllBlocksSelected) {
        if (_noneSelected) {
          // 全不选 was active: the snapshot to restore on uncheck is the
          // selection from before 全不选 was checked, and 全不选 is cancelled.
          _previousBlockIndexes = _indexesBeforeNone != null
              ? Set<int>.from(_indexesBeforeNone!)
              : <int>{};
          _indexesBeforeNone = null;
          _noneSelected = false;
        } else {
          _previousBlockIndexes = Set<int>.from(_selectedBlockIndexes);
        }
        _selectedBlockIndexes.clear();
        for (int i = 0; i < kUnicodeBlocks.length; i++) {
          _selectedBlockIndexes.add(i);
        }
      }
    } else {
      _selectedBlockIndexes.clear();
      if (_previousBlockIndexes != null) {
        _selectedBlockIndexes.addAll(_previousBlockIndexes!);
        _previousBlockIndexes = null;
      }
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void toggleSelectNoneBlocks(bool selectNone) {
    if (selectNone) {
      if (_noneSelected) return;
      if (isAllBlocksSelected && _previousBlockIndexes != null) {
        // 全选 was active: keep the pre-全选 selection as the restore
        // snapshot; clearing the selection also unchecks 全选.
        _indexesBeforeNone = Set<int>.from(_previousBlockIndexes!);
        _previousBlockIndexes = null;
      } else {
        _indexesBeforeNone = Set<int>.from(_selectedBlockIndexes);
      }
      _selectedBlockIndexes.clear();
      _noneSelected = true;
    } else {
      if (!_noneSelected) return;
      _noneSelected = false;
      _selectedBlockIndexes.clear();
      if (_indexesBeforeNone != null) {
        _selectedBlockIndexes.addAll(_indexesBeforeNone!);
        _indexesBeforeNone = null;
      }
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void toggleBlock(int index, bool selected) {
    if (selected) {
      _selectedBlockIndexes.add(index);
      _noneSelected = false; // manual selection cancels 全不选
    } else {
      _selectedBlockIndexes.remove(index);
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  /// Selects the Unicode blocks corresponding to the given language bindings.
  void selectBlocksForBindings(List<LangBinding> bindings) {
    if (bindings.isEmpty) return;
    _selectedBlockIndexes.clear();
    for (final binding in bindings) {
      for (final block in binding.blocks) {
        for (int i = 0; i < kUnicodeBlocks.length; i++) {
          final kb = kUnicodeBlocks[i];
          if (kb.start <= block.end && kb.end >= block.start) {
            _selectedBlockIndexes.add(i);
          }
        }
      }
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void setCustomRangeInput(String v) {
    _customRangeInput = v;
    notifyListeners();
    _scheduleAutoRefresh();
  }

  Future<void> importTextFile(String path) async {
    try {
      _importedText = await File(path).readAsString();
      _lastError = null;
    } catch (e) {
      _lastError = '文本导入失败: $e';
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  void clearImportedText() {
    _importedText = '';
    notifyListeners();
    _scheduleAutoRefresh();
  }

  /// Builds the final grapheme list from blocks, custom ranges and the
  /// imported text (deduplicated, stable order).
  List<String> buildCharset() {
    final seen = <int>{};
    final out = <String>[];

    if (_extractMode == FontExtractMode.multiLang) {
      final boundBindings = _langBindings
          .where((b) => b.fontPath != null && b.fontPath!.isNotEmpty)
          .toList();
      for (final binding in boundBindings) {
        for (final block in binding.blocks) {
          for (int cp = block.start; cp <= block.end; cp++) {
            if (seen.add(cp)) out.add(String.fromCharCode(cp));
          }
        }
      }
    } else {
      final codePoints = expandToCodePoints(
        blocks: _selectedBlockIndexes.map((i) => kUnicodeBlocks[i]),
        customRanges: _parseRangesSafe(),
      );
      for (final cp in codePoints) {
        if (seen.add(cp)) out.add(String.fromCharCode(cp));
      }
    }

    for (final r in _parseRangesSafe()) {
      for (int cp = r.start; cp <= r.end; cp++) {
        if (seen.add(cp)) out.add(String.fromCharCode(cp));
      }
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
    if (_extractMode == FontExtractMode.multiLang) {
      final boundBindings = _langBindings
          .where((b) => b.fontPath != null && b.fontPath!.isNotEmpty)
          .toList();
      final seen = <int>{};
      for (final binding in boundBindings) {
        for (final block in binding.blocks) {
          for (int cp = block.start; cp <= block.end; cp++) {
            seen.add(cp);
          }
        }
      }
      size = seen.length;
    } else {
      for (final i in _selectedBlockIndexes) {
        size += kUnicodeBlocks[i].length;
      }
    }
    for (final r in _parseRangesSafe()) {
      size += r.end - r.start + 1;
    }
    return size;
  }

  /// Suggested output base name: 字体名_格宽x格高.
  String get suggestedBaseName {
    final fontName = _fontPaths.isEmpty
        ? 'font'
        : p.basenameWithoutExtension(_fontPaths.first);
    return '${fontName}_${_cellWidth}x$_cellHeight';
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

  void setPreviewLimit(int v) {
    final clamped = v.clamp(0, 100000);
    if (_previewLimit == clamped) return;
    _previewLimit = clamped;
    notifyListeners();
    _scheduleAutoRefresh();
  }

  /// Enables/disables automatic preview refresh. When enabled, any change
  /// to fonts, render settings or the charset re-renders the preview after
  /// a short debounce.
  void setAutoRefreshPreview(bool v) {
    if (_autoRefreshPreview == v) return;
    _autoRefreshPreview = v;
    notifyListeners();
    if (v && _renderer.hasFont) _scheduleAutoRefresh();
  }

  void _scheduleAutoRefresh() {
    if (!_autoRefreshPreview || !_renderer.hasFont) return;
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer(const Duration(milliseconds: 600), () {
      if (_autoRefreshPreview && !_previewLoading && !_isGenerating) {
        refreshPreview();
      }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
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
      final activeFontName = _fontPaths.isNotEmpty
          ? fontDisplayName(_fontPaths.first)
          : '当前字体';

      final groups = <BlockPreviewGroup>[];
      final sections = <({
        String name,
        String rangeLabel,
        List<int> codePoints,
        List<String>? graphemes,
        String? fontName,
      })>[];

      if (_extractMode == FontExtractMode.multiLang) {
        final boundBindings = _langBindings
            .where((b) => b.fontPath != null && b.fontPath!.isNotEmpty)
            .toList();

        for (final binding in boundBindings) {
          final fontName = fontDisplayName(binding.fontPath!);
          for (final block in binding.blocks) {
            final limitCount = (_previewLimit == 0)
                ? block.length
                : math.min(block.length, _previewLimit);
            final cps = List<int>.generate(limitCount, (i) => block.start + i);
            sections.add((
              name: '${binding.name} (${block.name})',
              rangeLabel: '${formatCodePoint(block.start)}-${formatCodePoint(block.end)}',
              codePoints: cps,
              graphemes: null,
              fontName: fontName,
            ));
          }
        }
      } else if (_selectedBlockIndexes.isNotEmpty) {
        final sortedBlockIndexes = _selectedBlockIndexes.toList()
          ..sort((a, b) => kUnicodeBlocks[a].start.compareTo(kUnicodeBlocks[b].start));
        for (final idx in sortedBlockIndexes) {
          if (idx < 0 || idx >= kUnicodeBlocks.length) continue;
          final block = kUnicodeBlocks[idx];
          final limitCount = (_previewLimit == 0)
              ? block.length
              : math.min(block.length, _previewLimit);
          final cps = List<int>.generate(limitCount, (i) => block.start + i);
          sections.add((
            name: block.name,
            rangeLabel: '${formatCodePoint(block.start)}-${formatCodePoint(block.end)}',
            codePoints: cps,
            graphemes: null,
            fontName: activeFontName,
          ));
        }
      } else if (_fontPaths.isNotEmpty) {
        // Fallback: detect blocks present in font's cmap
        final fontCmap = await readFontCmap(_fontPaths.first);
        if (fontCmap != null && fontCmap.isNotEmpty) {
          final fontCps = expandToCodePoints(customRanges: fontCmap).toSet();
          for (final block in kUnicodeBlocks) {
            final blockCps = <int>[];
            for (int cp = block.start; cp <= block.end; cp++) {
              if (fontCps.contains(cp)) {
                blockCps.add(cp);
                if (_previewLimit > 0 && blockCps.length >= _previewLimit) {
                  break;
                }
              }
            }
            if (blockCps.isNotEmpty) {
              sections.add((
                name: block.name,
                rangeLabel: '${formatCodePoint(block.start)}-${formatCodePoint(block.end)}',
                codePoints: blockCps,
                graphemes: null,
                fontName: activeFontName,
              ));
            }
          }
        }
      }

      // Add Custom Range section if specified
      final customRanges = _parseRangesSafe();
      if (customRanges.isNotEmpty) {
        final allCps = expandToCodePoints(customRanges: customRanges);
        final cps = (_previewLimit == 0)
            ? allCps
            : allCps.take(_previewLimit).toList();
        if (cps.isNotEmpty) {
          sections.add((
            name: '自定义码点范围',
            rangeLabel: _customRangeInput,
            codePoints: cps,
            graphemes: null,
            fontName: activeFontName,
          ));
        }
      }

      // Add Imported Text section if specified
      if (_importedText.isNotEmpty) {
        final allGraphemes = _importedText.characters.toList();
        final textGraphemes = (_previewLimit == 0)
            ? allGraphemes
            : allGraphemes.take(_previewLimit).toList();
        if (textGraphemes.isNotEmpty) {
          sections.add((
            name: '从文本导入字符',
            rangeLabel: '${textGraphemes.length} 个字素',
            codePoints: const [],
            graphemes: textGraphemes,
            fontName: activeFontName,
          ));
        }
      }

      int totalItems = 0;
      for (final sec in sections) {
        totalItems += (sec.graphemes ?? sec.codePoints).length;
      }
      if (totalItems == 0) totalItems = 1;

      int processed = 0;
      final allFlatGlyphs = <GlyphBitmap>[];

      for (final sec in sections) {
        final items =
            sec.graphemes ?? sec.codePoints.map(String.fromCharCode).toList();
        final groupGlyphs = <GlyphBitmap>[];
        for (final g in items) {
          final glyph = await _render(g);
          groupGlyphs.add(glyph);
          allFlatGlyphs.add(glyph);
          processed++;
          _previewProgress = processed / totalItems;
          if (processed % 16 == 0 || processed == totalItems) {
            notifyListeners();
          }
        }

        final isMissing =
            groupGlyphs.isEmpty || groupGlyphs.every((b) => b.isMissing);

        groups.add(BlockPreviewGroup(
          blockName: sec.name,
          rangeLabel: sec.rangeLabel,
          glyphs: groupGlyphs,
          isMissingInFont: isMissing,
          fontName: sec.fontName ?? activeFontName,
        ));
      }

      _previewGroups = groups;
      _previewGlyphs = allFlatGlyphs;
    } catch (e) {
      _lastError = '预览渲染失败: $e';
    }
    _previewLoading = false;
    notifyListeners();
  }

  void setExtractMode(FontExtractMode mode) {
    _extractMode = mode;
    if (mode == FontExtractMode.multiLang) {
      _sortLangBindings();
      final boundList = _langBindings
          .where((b) => b.fontPath != null && b.fontPath!.isNotEmpty)
          .toList();
      if (boundList.isNotEmpty) {
        selectBlocksForBindings(boundList);
      } else {
        final defaultZh = _langBindings.where((b) => b.id == 'zh_cn').toList();
        if (defaultZh.isNotEmpty) {
          selectBlocksForBindings(defaultZh);
        }
      }
    }
    notifyListeners();
    _scheduleAutoRefresh();
  }

  Future<void> bindLangFont(String langId, String fontPath) async {
    try {
      await _renderer.addFontFile(fontPath);
      if (!_fontPaths.contains(fontPath)) {
        _fontPaths.add(fontPath);
      }
      final name = fontDisplayName(fontPath);

      final index = _langBindings.indexWhere((b) => b.id == langId);
      if (index != -1) {
        final current = _langBindings[index];
        final order = current.boundOrder ?? ++_nextBoundOrder;
        final binding = current.copyWith(
          fontPath: fontPath,
          fontDisplayName: name,
          boundOrder: order,
        );
        _langBindings[index] = binding;
        _sortLangBindings();

        // Auto-select Unicode blocks for this bound language
        for (final block in binding.blocks) {
          for (int i = 0; i < kUnicodeBlocks.length; i++) {
            final kb = kUnicodeBlocks[i];
            if (kb.start <= block.end && kb.end >= block.start) {
              _selectedBlockIndexes.add(i);
            }
          }
        }
      }
      _lastError = null;
      notifyListeners();
      _scheduleAutoRefresh();
    } catch (e) {
      _lastError = '绑定字体失败: $e';
      notifyListeners();
    }
  }

  void unbindLangFont(String langId) {
    final index = _langBindings.indexWhere((b) => b.id == langId);
    if (index != -1) {
      final current = _langBindings[index];
      _langBindings[index] = current.copyWith(
        clearFontPath: true,
        clearFontDisplayName: true,
        clearBoundOrder: true,
      );
      _sortLangBindings();
      notifyListeners();
      _scheduleAutoRefresh();
    }
  }

  void addCustomLangBinding(String name, String flag, String regionTag,
      List<UnicodeBlock> blocks,
      {String continentTag = '', String countryTag = '自定义', String scriptTag = ''}) {
    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    final nextOriginalIndex = _langBindings.length;
    _langBindings.add(LangBinding(
      id: id,
      name: name,
      flag: flag,
      continentTag: continentTag,
      regionTag: regionTag,
      countryTag: countryTag,
      scriptTag: scriptTag,
      blocks: blocks,
      originalIndex: nextOriginalIndex,
    ));
    _sortLangBindings();
    notifyListeners();
  }

  void removeLangBinding(String langId) {
    _langBindings.removeWhere((b) => b.id == langId);
    _sortLangBindings();
    notifyListeners();
    _scheduleAutoRefresh();
  }

  String? _findBoundFamily(int cp) {
    if (_extractMode != FontExtractMode.multiLang) return null;
    for (final binding in _langBindings) {
      final fontPath = binding.fontPath;
      if (fontPath == null) continue;
      for (final block in binding.blocks) {
        if (cp >= block.start && cp <= block.end) {
          return _renderer.getFamilyForPath(fontPath);
        }
      }
    }
    return null;
  }

  Future<GlyphBitmap> _render(String grapheme) {
    final cp = grapheme.runes.isEmpty ? 0 : grapheme.runes.first;
    final primaryFamily = _findBoundFamily(cp);
    switch (classifyWidth(cp)) {
      case GlyphWidthClass.full:
        return _renderer.renderGrapheme(
          grapheme,
          fontSize: _cjkFontSize,
          cellWidth: _cjkCellSize,
          cellHeight: _cjkCellSize,
          verticalOffset: _verticalOffset,
          pixelSnap: _pixelSnap,
          primaryFamily: primaryFamily,
        );
      case GlyphWidthClass.half:
        return _renderer.renderGrapheme(
          grapheme,
          fontSize: _fontSize,
          cellWidth: _cellWidth,
          cellHeight: _cellHeight,
          verticalOffset: _verticalOffset,
          pixelSnap: _pixelSnap,
          primaryFamily: primaryFamily,
        );
      case GlyphWidthClass.proportional:
        // Neither half-width nor full-width (Devanagari, Arabic, Thai,
        // Greek, ...): let the renderer measure the font's real advance
        // and size the cell to fit.
        return _renderer.renderGrapheme(
          grapheme,
          fontSize: _fontSize,
          cellWidth: null,
          cellHeight: _cellHeight,
          verticalOffset: _verticalOffset,
          pixelSnap: _pixelSnap,
          primaryFamily: primaryFamily,
        );
    }
  }

  // ------------------------------------------------------------------
  // Template (.gflm)
  // ------------------------------------------------------------------

  /// Template format version written by [exportTemplate].
  static const int templateVersion = 1;

  /// Serializes the current extraction configuration to a JSON map.
  Map<String, dynamic> exportTemplate() {
    return {
      'version': templateVersion,
      'extractMode': _extractMode.name,
      'nextBoundOrder': _nextBoundOrder,
      'fontPaths': List<String>.of(_fontPaths),
      'fontSize': _fontSize,
      'cellWidth': _cellWidth,
      'cellHeight': _cellHeight,
      'cjkFontSize': _cjkFontSize,
      'cjkCellSize': _cjkCellSize,
      'verticalOffset': _verticalOffset,
      'bitDepth': _bitDepth.name,
      'scanMode': _scanMode.name,
      'threshold': _threshold,
      'showCellGrid': _showCellGrid,
      'selectedBlockIndexes': _selectedBlockIndexes.toList()..sort(),
      'customRangeInput': _customRangeInput,
      'importedText': _importedText,
      'autoRefreshPreview': _autoRefreshPreview,
      'langBindings': _langBindings
          .where((b) => b.fontPath != null && b.fontPath!.isNotEmpty)
          .map((b) => {
                'id': b.id,
                'fontPath': b.fontPath,
                'fontDisplayName': b.fontDisplayName,
                'boundOrder': b.boundOrder,
              })
          .toList(),
    };
  }

  /// Applies a template map previously produced by [exportTemplate].
  ///
  /// Returns the font file paths that no longer exist (or failed to load)
  /// and were skipped. Throws [FormatException] when [json] is not a valid
  /// template.
  Future<List<String>> applyTemplate(Map<String, dynamic> json) async {
    double numValue(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;

    if (json['fontPaths'] is! List) {
      throw const FormatException('不是有效的字库提取模板文件');
    }

    clearFonts();
    if (json['extractMode'] is String) {
      _extractMode = FontExtractMode.values.asNameMap()[json['extractMode']] ??
          FontExtractMode.fallback;
    }
    if (json['nextBoundOrder'] is num) {
      _nextBoundOrder = (json['nextBoundOrder'] as num).toInt();
    }
    _fontSize = numValue('fontSize', 14).clamp(4, 200);
    _cellWidth = numValue('cellWidth', 8).round().clamp(1, 256);
    _cellHeight = numValue('cellHeight', 16).round().clamp(1, 256);
    _cjkFontSize = numValue('cjkFontSize', 16).clamp(4, 200);
    _cjkCellSize = numValue('cjkCellSize', 16).round().clamp(16, 256);
    _verticalOffset = numValue('verticalOffset', 0);
    _bitDepth = BitmapBitDepth.values.asNameMap()[json['bitDepth']] ??
        BitmapBitDepth.one;
    _scanMode = BitmapScanMode.values.asNameMap()[json['scanMode']] ??
        BitmapScanMode.rowMajor;
    _threshold = numValue('threshold', 128).round().clamp(0, 255);
    _showCellGrid = json['showCellGrid'] == true;
    _selectedBlockIndexes
      ..clear()
      ..addAll((json['selectedBlockIndexes'] as List? ?? const [])
          .whereType<num>()
          .map((e) => e.toInt())
          .where((i) => i >= 0 && i < kUnicodeBlocks.length));
    _customRangeInput = json['customRangeInput'] as String? ?? '';
    _importedText = json['importedText'] as String? ?? '';
    _autoRefreshPreview = json['autoRefreshPreview'] == true;

    final missing = <String>[];
    for (final path in (json['fontPaths'] as List).whereType<String>()) {
      if (!File(path).existsSync()) {
        missing.add(path);
        continue;
      }
      try {
        await _renderer.addFontFile(path);
        _fontPaths.add(path);
        _loadDisplayName(path);
      } catch (_) {
        missing.add(path);
      }
    }

    if (json['langBindings'] is List) {
      for (final item in json['langBindings'] as List) {
        if (item is Map<String, dynamic>) {
          final id = item['id'] as String?;
          final path = item['fontPath'] as String?;
          final name = item['fontDisplayName'] as String?;
          final order = (item['boundOrder'] as num?)?.toInt();
          if (id != null && path != null && File(path).existsSync()) {
            final idx = _langBindings.indexWhere((b) => b.id == id);
            if (idx != -1) {
              _langBindings[idx] = _langBindings[idx].copyWith(
                fontPath: path,
                fontDisplayName: name,
                boundOrder: order,
              );
              try {
                await _renderer.addFontFile(path);
                if (!_fontPaths.contains(path)) _fontPaths.add(path);
              } catch (_) {}
            }
          }
        }
      }
      _sortLangBindings();
    }

    _lastError = null;
    notifyListeners();
    return missing;
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
          // Glyphs the font cannot display (missing glyph, or a fake
          // hex-value placeholder box like Unifont's) are neither shown
          // nor exported.
          if (bmp.isMissing) continue;
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
          columnMajor: _scanMode == BitmapScanMode.columnMajor,
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

  /// Whether any currently active selected block, custom range or imported text
  /// contains full-width (CJK / Hiragana / Katakana / etc.) characters.
  bool get hasFullWidthActive {
    for (final idx in _selectedBlockIndexes) {
      if (idx >= 0 && idx < kUnicodeBlocks.length) {
        final block = kUnicodeBlocks[idx];
        if (_isBlockFullWidth(block)) {
          return true;
        }
      }
    }
    for (final range in _parseRangesSafe()) {
      if (isFullWidthCodePoint(range.start) ||
          isFullWidthCodePoint(range.end) ||
          isFullWidthCodePoint((range.start + range.end) ~/ 2)) {
        return true;
      }
    }
    for (final g in _importedText.characters) {
      if (g.runes.isNotEmpty && isFullWidthCodePoint(g.runes.first)) {
        return true;
      }
    }
    return false;
  }

  bool _isBlockFullWidth(UnicodeBlock block) {
    return isFullWidthCodePoint(block.start) ||
        isFullWidthCodePoint(block.end) ||
        isFullWidthCodePoint((block.start + block.end) ~/ 2);
  }

  /// Whether any currently active selected block, custom range or imported
  /// text contains proportional-width characters (Devanagari, Arabic,
  /// Thai, Greek, ...) whose width is measured from the font.
  bool get hasProportionalActive {
    bool isProp(int cp) =>
        classifyWidth(cp) == GlyphWidthClass.proportional;
    for (final idx in _selectedBlockIndexes) {
      if (idx >= 0 && idx < kUnicodeBlocks.length) {
        final block = kUnicodeBlocks[idx];
        if (isProp(block.start) ||
            isProp(block.end) ||
            isProp((block.start + block.end) ~/ 2)) {
          return true;
        }
      }
    }
    for (final range in _parseRangesSafe()) {
      if (isProp(range.start) ||
          isProp(range.end) ||
          isProp((range.start + range.end) ~/ 2)) {
        return true;
      }
    }
    for (final g in _importedText.characters) {
      if (g.runes.isNotEmpty && isProp(g.runes.first)) {
        return true;
      }
    }
    return false;
  }

  /// Automatically selects all Unicode blocks that overlap with the ranges
  /// in the given [ScriptGroup].
  void selectBlocksForScriptGroup(ScriptGroup sg) {
    final newIndexes = <int>{0}; // Always keep Basic Latin selected
    for (final range in sg.ranges) {
      for (int i = 0; i < kUnicodeBlocks.length; i++) {
        final block = kUnicodeBlocks[i];
        if (range.start <= block.end && range.end >= block.start) {
          newIndexes.add(i);
        }
      }
    }
    _selectedBlockIndexes.clear();
    _selectedBlockIndexes.addAll(newIndexes);

    // Auto-adapt for CJK full-width scripts
    if (sg.name == '中文' || sg.name == '日文' || sg.name == '韩文' || sg.name == '彝文') {
      // Also check U+FF00~U+FFEF (Halfwidth and Fullwidth Forms)
      final fwIndex = kUnicodeBlocks.indexWhere((b) => b.start == 0xFF00 && b.end == 0xFFEF);
      if (fwIndex != -1) {
        _selectedBlockIndexes.add(fwIndex);
      }
      if (_cjkCellSize < 16) {
        _cjkCellSize = 16;
      }
    } else {
      _cellWidth = (_cellHeight ~/ 2).clamp(1, 256);
    }

    notifyListeners();
    _scheduleAutoRefresh();
  }

  /// Automatically selects Unicode blocks in fallback mode based on the user's
  /// selection of continent, region, country and target script in the font picker.
  /// If all filters are "全部" (isDefaultAll) and a [fontPath] is provided,
  /// all character set blocks contained within that font's `cmap` are automatically checked!
  Future<void> selectBlocksForFilter({
    required String continent,
    required String region,
    required String country,
    ScriptGroup? scriptGroup,
    String? fontPath,
  }) async {
    if (_extractMode != FontExtractMode.fallback) return;

    final isDefaultAll = continent == '全部' &&
        region == '全部' &&
        country == '全部' &&
        scriptGroup == null;

    if (isDefaultAll) {
      if (fontPath != null && fontPath.isNotEmpty) {
        final fontCmap = await readFontCmap(fontPath);
        if (fontCmap != null && fontCmap.isNotEmpty) {
          final newIndexes = <int>{0}; // Always keep Basic Latin selected
          for (int i = 0; i < kUnicodeBlocks.length; i++) {
            final block = kUnicodeBlocks[i];
            if (coverageOf(fontCmap, block.start, block.end) > 0) {
              newIndexes.add(i);
            }
          }
          _selectedBlockIndexes.clear();
          _selectedBlockIndexes.addAll(newIndexes);

          if (hasFullWidthActive && _cjkCellSize < 16) {
            _cjkCellSize = 16;
          }

          notifyListeners();
          _scheduleAutoRefresh();
        }
      }
      return;
    }

    final matchingGroups = <ScriptGroup>[];

    if (scriptGroup != null) {
      matchingGroups.add(scriptGroup);
    } else {
      for (final g in kScriptGroups) {
        if (continent != '全部' && g.continent != continent) continue;
        if (region != '全部' && g.region != region) continue;
        if (country != '全部' && g.country != country) continue;
        matchingGroups.add(g);
      }
    }

    if (matchingGroups.isEmpty) return;

    final newIndexes = <int>{0}; // Keep Basic Latin (ASCII) selected by default

    for (final group in matchingGroups) {
      for (final range in group.ranges) {
        for (int i = 0; i < kUnicodeBlocks.length; i++) {
          final block = kUnicodeBlocks[i];
          if (range.start <= block.end && range.end >= block.start) {
            newIndexes.add(i);
          }
        }
      }
      if (group.name.contains('中文') ||
          group.name.contains('日文') ||
          group.name.contains('韩文') ||
          group.name.contains('彝文')) {
        final fwIndex = kUnicodeBlocks
            .indexWhere((b) => b.start == 0xFF00 && b.end == 0xFFEF);
        if (fwIndex != -1) newIndexes.add(fwIndex);
      }
    }

    _selectedBlockIndexes.clear();
    _selectedBlockIndexes.addAll(newIndexes);

    notifyListeners();
    _scheduleAutoRefresh();
  }
}
