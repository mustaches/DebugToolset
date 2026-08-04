import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../utils/bitmap_converter.dart';
import '../utils/c_array_parser.dart';
import '../utils/dfnt_font.dart';
import '../utils/width_classify.dart';

/// Active view tab in the font test dialog.
enum FontTestTab {
  /// Continuous multiline text sample rendering.
  textSample,

  /// Grid view showing individual glyph bitmaps in the font library.
  glyphGrid,
}

/// Dialog for testing an extracted font library: loads a generated DFNT
/// `.bin` or `.c` file, renders sample text, and provides a glyph bitmap grid
/// preview to inspect individual glyphs.
class FontTestDialog extends StatefulWidget {
  /// BIN or C file to load immediately (e.g. the last generated output).
  final String? initialPath;

  const FontTestDialog({super.key, this.initialPath});

  @override
  State<FontTestDialog> createState() => _FontTestDialogState();
}

class _PlacedGlyph {
  final double x;
  final double y;
  final DfntGlyph? glyph; // null = missing in the font
  final bool isFullWidthMissing;
  const _PlacedGlyph(this.x, this.y, this.glyph,
      {this.isFullWidthMissing = false});
}

class _FontTestDialogState extends State<FontTestDialog> {
  FontTestTab _activeTab = FontTestTab.textSample;

  final _textController =
      TextEditingController(text: 'Hello, World! 你好，世界！ 0123');
  final _searchController = TextEditingController();
  final _pixelCache = <int, Uint8List>{};

  DfntFont? _font;
  String? _fontPath;
  String? _error;
  double _scale = 6;
  double _gridScale = 2.0;
  String _gridSearchQuery = '';

  ui.Image? _renderedImage;
  String? _renderedKey;
  bool _isRendering = false;
  double _renderedWidth = 100;
  double _renderedHeight = 100;

  /// True when the dialog is maximized to fill the whole window.
  bool _maximized = false;

  List<Rect> _missingRects = [];

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPath;
    if (initial != null) _load(initial);
  }

  @override
  void dispose() {
    _textController.dispose();
    _searchController.dispose();
    _renderedImage?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '字库文件', extensions: ['bin', 'c']),
      ],
      confirmButtonText: '选择字库文件',
    );
    if (file != null) _load(file.path);
  }

  Future<void> _load(String path) async {
    try {
      final DfntFont font;
      if (path.toLowerCase().endsWith('.c')) {
        font = CArrayFontParser.parse(await File(path).readAsString());
      } else {
        font = DfntFont.parse(await File(path).readAsBytes());
      }
      setState(() {
        _font = font;
        _fontPath = path;
        _error = null;
        _pixelCache.clear();
        _renderedImage?.dispose();
        _renderedImage = null;
        _renderedKey = null;
        _missingRects = [];
      });
    } on FormatException catch (e) {
      setState(() {
        _font = null;
        _fontPath = path;
        _error = e.message;
        _renderedImage?.dispose();
        _renderedImage = null;
        _renderedKey = null;
        _missingRects = [];
      });
    } catch (e) {
      setState(() {
        _font = null;
        _fontPath = path;
        _error = '读取失败: $e';
        _renderedImage?.dispose();
        _renderedImage = null;
        _renderedKey = null;
        _missingRects = [];
      });
    }
  }

  Uint8List _getGlyphPixels(DfntFont font, DfntGlyph glyph) {
    return _pixelCache.putIfAbsent(
      glyph.codePoint,
      // Glyphs the source font cannot display are stored with empty bitmap
      // data; render them as blank instead of failing to unpack.
      () => glyph.data.isEmpty
          ? Uint8List(glyph.width * glyph.height)
          : unpackBitmap(
              bytes: glyph.data,
              width: glyph.width,
              height: glyph.height,
              depth: font.bitsPerPixel == 1
                  ? BitmapBitDepth.one
                  : BitmapBitDepth.eight,
              scan: font.columnMajor
                  ? BitmapScanMode.columnMajor
                  : BitmapScanMode.rowMajor,
            ),
    );
  }

  Future<ui.Image> _generateBitmapImage(
      String text, DfntFont font) async {
    final lineStep = font.cellHeight + 2;

    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');

    final placedGlyphs = <_PlacedGlyph>[];
    int currentY = 0;
    int maxW = font.cellWidth;

    for (final line in lines) {
      int currentX = 0;
      for (final g in line.characters) {
        final glyph = font.glyphFor(g);
        final isFull =
            g.runes.isNotEmpty && isFullWidthCodePoint(g.runes.first);
        final int defaultAdv = isFull ? font.cellHeight : font.cellWidth;
        final adv = glyph?.advance ?? defaultAdv;
        placedGlyphs.add(_PlacedGlyph(
          currentX.toDouble(),
          currentY.toDouble(),
          glyph,
          isFullWidthMissing: glyph == null && isFull,
        ));
        currentX += adv;
        if (currentX > maxW) maxW = currentX;
      }
      currentY += lineStep;
    }

    final imgW = maxW.clamp(1, 4096);
    final imgH = (currentY > 0 ? currentY : lineStep).clamp(1, 8192);

    _renderedWidth = imgW.toDouble();
    _renderedHeight = imgH.toDouble();

    final missing = <Rect>[];
    final rgba = Uint8List(imgW * imgH * 4);
    for (final pl in placedGlyphs) {
      final glyph = pl.glyph;
      if (glyph == null) {
        final width = pl.isFullWidthMissing
            ? font.cellHeight.toDouble()
            : font.cellWidth.toDouble();
        missing.add(Rect.fromLTWH(
          pl.x,
          pl.y,
          width,
          font.cellHeight.toDouble(),
        ));
        continue;
      }

      final pixels = _getGlyphPixels(font, glyph);

      final gx = pl.x.round();
      final gy = pl.y.round();

      for (int py = 0; py < glyph.height; py++) {
        final destY = gy + py;
        if (destY < 0 || destY >= imgH) continue;
        for (int px = 0; px < glyph.width; px++) {
          final destX = gx + px;
          if (destX < 0 || destX >= imgW) continue;
          final v = pixels[py * glyph.width + px];
          if (v == 0) continue;

          final idx = (destY * imgW + destX) * 4;
          rgba[idx] = 0;        // R
          rgba[idx + 1] = 255;  // G (CyanAccent: #00FFFF)
          rgba[idx + 2] = 255;  // B
          rgba[idx + 3] = v;    // Alpha (1..255)
        }
      }
    }

    _missingRects = missing;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      imgW,
      imgH,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void _updateRenderedImageIfNeeded(DfntFont font) {
    final key =
        '${_textController.text}_${font.cellWidth}_${font.cellHeight}_${font.glyphCount}';
    if (_renderedKey == key || _isRendering) return;

    _isRendering = true;
    _generateBitmapImage(_textController.text, font).then((img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _renderedImage?.dispose();
        _renderedImage = img;
        _renderedKey = key;
        _isRendering = false;
      });
    }).catchError((_) {
      if (mounted) setState(() => _isRendering = false);
    });
  }

  List<DfntGlyph> _filterGlyphs(DfntFont font) {
    final all = font.glyphs.values.toList()
      ..sort((a, b) => a.codePoint.compareTo(b.codePoint));
    final q = _gridSearchQuery.trim().toLowerCase();
    if (q.isEmpty) return all;

    return all.where((g) {
      final grapheme = String.fromCharCode(g.codePoint);
      if (grapheme.toLowerCase().contains(q)) return true;
      final hex = g.codePoint.toRadixString(16).toLowerCase();
      final uHex = 'u+${hex.padLeft(4, '0')}';
      final dec = g.codePoint.toString();
      return hex.contains(q) || uHex.contains(q) || dec.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final font = _font;
    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      insetPadding:
          _maximized ? EdgeInsets.zero : const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_maximized ? 0 : 4),
      ),
      child: SizedBox(
        width: _maximized ? double.infinity : 860,
        height: _maximized ? double.infinity : 620,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('测试字库',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  if (font != null)
                    Text(
                      '单元格 ${font.cellWidth}x${font.cellHeight} · '
                      '${font.bitsPerPixel}bpp · '
                      '${font.columnMajor ? '列扫描' : '行扫描'} · '
                      '${font.glyphCount} 个字形',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      _maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                      size: 18,
                    ),
                    onPressed: () =>
                        setState(() => _maximized = !_maximized),
                    tooltip: _maximized ? '还原' : '最大化',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label:
                        const Text('选择字库文件', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF333333),
                      foregroundColor: Colors.cyanAccent,
                      minimumSize: const Size(0, 30),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _fontPath == null
                          ? '未加载字库文件'
                          : p.basename(_fontPath!),
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'Consolas'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SegmentedButton<FontTestTab>(
                    segments: const [
                      ButtonSegment<FontTestTab>(
                        value: FontTestTab.textSample,
                        label: Text('文本排版测试', style: TextStyle(fontSize: 11)),
                        icon: Icon(Icons.text_fields, size: 14),
                      ),
                      ButtonSegment<FontTestTab>(
                        value: FontTestTab.glyphGrid,
                        label: Text('字模点阵预览', style: TextStyle(fontSize: 11)),
                        icon: Icon(Icons.grid_on, size: 14),
                      ),
                    ],
                    selected: {_activeTab},
                    onSelectionChanged: (set) =>
                        setState(() => _activeTab = set.first),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      padding: WidgetStateProperty.all(EdgeInsets.zero),
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return const Color(0xFF0A4A5A);
                        }
                        return const Color(0xFF252525);
                      }),
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return Colors.cyanAccent;
                        }
                        return Colors.grey;
                      }),
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.redAccent)),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: font == null
                    ? Container(
                        color: const Color(0xFF101010),
                        child: const Center(
                          child: Text('请选择生成的 .bin 或 .c 字库文件',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                        ),
                      )
                    : _activeTab == FontTestTab.textSample
                        ? _buildTextSampleView(font)
                        : _buildGlyphGridView(font),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextSampleView(DfntFont font) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _textController,
          minLines: 2,
          maxLines: 3,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
          decoration: InputDecoration(
            isDense: true,
            labelText: '样例文本 (支持粘贴多行)',
            labelStyle: const TextStyle(fontSize: 11, color: Colors.grey),
            filled: true,
            fillColor: const Color(0xFF252525),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: Colors.grey.shade800),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: Colors.grey.shade800),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        Row(
          children: [
            const Text('缩放', style: TextStyle(fontSize: 11)),
            Expanded(
              child: Slider(
                value: _scale,
                min: 0.2,
                max: 8.0,
                divisions: 78,
                onChanged: (v) =>
                    setState(() => _scale = (v * 10).round() / 10.0),
              ),
            ),
            Text('${_scale.toStringAsFixed(1)}x',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        Expanded(
          child: Container(
            color: const Color(0xFF101010),
            child: LayoutBuilder(
              builder: (context, constraints) {
                _updateRenderedImageIfNeeded(font);
                final image = _renderedImage;
                if (image == null) {
                  return const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                return SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  padding: const EdgeInsets.all(4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _renderedWidth * _scale,
                      height: _renderedHeight * _scale,
                      child: CustomPaint(
                        painter: _BitmapPainter(
                          image: image,
                          missingRects: _missingRects,
                          scale: _scale,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGlyphGridView(DfntFont font) {
    final filtered = _filterGlyphs(font);
    final cellWidth = font.cellWidth;
    final cellHeight = font.cellHeight;

    // 字符框放大到 1.3 倍，避免高字模（如 U+0B94）溢出
    final itemWidth = (cellWidth * _gridScale + 28).clamp(70.0, 260.0) * 1.3;
    final itemHeight = (cellHeight * _gridScale + 48).clamp(80.0, 320.0) * 1.3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 240,
              height: 28,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  prefixIcon: const Icon(Icons.search, size: 14),
                  hintText: '搜索字符或码点 (如: 女, 1B170)...',
                  hintStyle: const TextStyle(fontSize: 11, color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF252525),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade800),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade800),
                  ),
                ),
                onChanged: (v) => setState(() => _gridSearchQuery = v),
              ),
            ),
            const SizedBox(width: 12),
            const Text('点阵大小:', style: TextStyle(fontSize: 11, color: Colors.grey)),
            SizedBox(
              width: 100,
              child: Slider(
                value: _gridScale,
                min: 1.0,
                max: 5.0,
                divisions: 8,
                onChanged: (v) =>
                    setState(() => _gridScale = (v * 2).round() / 2.0),
              ),
            ),
            Text('${_gridScale.toStringAsFixed(1)}x',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const Spacer(),
            Text(
              '显示 ${filtered.length} / ${font.glyphCount} 个字模',
              style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            color: const Color(0xFF101010),
            padding: const EdgeInsets.all(6),
            child: filtered.isEmpty
                ? const Center(
                    child: Text('未找到匹配的字模',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                  )
                : GridView.builder(
                    key: ValueKey(
                        '${_gridSearchQuery}_${_gridScale}_${filtered.length}'),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: itemWidth,
                      mainAxisExtent: itemHeight,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final glyph = filtered[index];
                      final pixels = _getGlyphPixels(font, glyph);
                      final grapheme = String.fromCharCode(glyph.codePoint);
                      final isPrintable = glyph.codePoint >= 0x20 &&
                          glyph.codePoint != 0x7F &&
                          glyph.codePoint != 0xFEFF;

                      return InkWell(
                        onTap: () =>
                            _showGlyphDetailDialog(context, font, glyph, pixels),
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.grey.shade800),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Text(
                                    isPrintable ? grapheme : '?',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    'U+${glyph.codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white,
                                      fontFamily: 'Consolas',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Expanded(
                                child: Center(
                                  child: Container(
                                    width: glyph.width * _gridScale,
                                    height: glyph.height * _gridScale,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.grey.shade900,
                                        width: 0.5,
                                      ),
                                    ),
                                    child: CustomPaint(
                                      painter: _GlyphCardPainter(
                                        pixels: pixels,
                                        width: glyph.width,
                                        height: glyph.height,
                                        scale: _gridScale,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${glyph.width}x${glyph.height}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade300,
                                  fontFamily: 'Consolas',
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  void _showGlyphDetailDialog(
      BuildContext context, DfntFont font, DfntGlyph glyph, Uint8List pixels) {
    final grapheme = String.fromCharCode(glyph.codePoint);
    final hexStr =
        'U+${glyph.codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';
    final isPrintable = glyph.codePoint >= 0x20 &&
        glyph.codePoint != 0x7F &&
        glyph.codePoint != 0xFEFF;

    // Formatted C array string of this single glyph's bitmap bytes.
    final cHexList = <String>[];
    for (int i = 0; i < glyph.data.length; i++) {
      cHexList.add('0x${glyph.data[i].toRadixString(16).padLeft(2, '0')}');
    }
    final cDataStr =
        '// Glyph $hexStr (${isPrintable ? grapheme : 'unprintable'}), ${glyph.width}x${glyph.height}, ${glyph.data.length}B\n'
        'static const uint8_t glyph_${glyph.codePoint.toRadixString(16)}[] = {\n  '
        '${_formatHexLines(cHexList, 12)}\n};';

    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        double detailScale = (260.0 / glyph.height).clamp(2.0, 12.0);
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              child: SizedBox(
                width: 680,
                height: 500,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.grid_on,
                              size: 16, color: Colors.cyanAccent),
                          const SizedBox(width: 6),
                          Text(
                            '字模详情 · $hexStr (${isPrintable ? grapheme : '?'})',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => Navigator.of(dialogCtx).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Left: High-resolution bitmap view
                            Expanded(
                              flex: 5,
                              child: Container(
                                color: const Color(0xFF101010),
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: Center(
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.vertical,
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Container(
                                              width: glyph.width * detailScale,
                                              height:
                                                  glyph.height * detailScale,
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                    color: Colors.grey.shade800),
                                              ),
                                              child: CustomPaint(
                                                painter: _GlyphDetailPainter(
                                                  pixels: pixels,
                                                  width: glyph.width,
                                                  height: glyph.height,
                                                  pixelScale: detailScale,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const Text('放缩',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey)),
                                        Expanded(
                                          child: Slider(
                                            value: detailScale,
                                            min: 1.0,
                                            max: 16.0,
                                            onChanged: (v) => setDialogState(
                                                () => detailScale = v),
                                          ),
                                        ),
                                        Text('${detailScale.toStringAsFixed(1)}x',
                                            style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            // Right: Glyph metadata & raw C array preview
                            Expanded(
                              flex: 6,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF252525),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Table(
                                      columnWidths: const {
                                        0: IntrinsicColumnWidth(),
                                        1: FlexColumnWidth(),
                                      },
                                      children: [
                                        _infoRow('字符字素:',
                                            isPrintable ? grapheme : '不可见字符'),
                                        _infoRow('Unicode 码点:',
                                            '$hexStr (${glyph.codePoint})'),
                                        _infoRow('点阵尺寸:',
                                            '${glyph.width} × ${glyph.height} px'),
                                        _infoRow('步进 (Advance):',
                                            '${glyph.advance} px'),
                                        _infoRow('基线偏移 (Offset):',
                                            'X: ${glyph.offsetX}, Y: ${glyph.offsetY}'),
                                        _infoRow('数据大小:',
                                            '${glyph.data.length} 字节 (${font.bitsPerPixel}bpp ${font.columnMajor ? '列扫描' : '行扫描'})'),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      const Text('字模 C 数组数据:',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey)),
                                      const Spacer(),
                                      TextButton.icon(
                                        onPressed: () {
                                          Clipboard.setData(
                                              ClipboardData(text: cDataStr));
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                              backgroundColor: Colors.green,
                                              content: Text('已复制字模 C 数组到剪贴板'),
                                              duration: Duration(seconds: 1),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.copy, size: 12),
                                        label: const Text('复制数据',
                                            style: TextStyle(fontSize: 10)),
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.cyanAccent,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF101010),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                            color: Colors.grey.shade800),
                                      ),
                                      child: SingleChildScrollView(
                                        child: SelectableText(
                                          cDataStr,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontFamily: 'Consolas',
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  TableRow _infoRow(String label, String value) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
          child: Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
          child: Text(value,
              style: const TextStyle(fontSize: 11, color: Colors.white)),
        ),
      ],
    );
  }

  String _formatHexLines(List<String> hexList, int perLine) {
    final lines = <String>[];
    for (int i = 0; i < hexList.length; i += perLine) {
      final end =
          (i + perLine > hexList.length) ? hexList.length : i + perLine;
      lines.add(hexList.sublist(i, end).join(', '));
    }
    return lines.join(',\n  ');
  }
}

class _BitmapPainter extends CustomPainter {
  final ui.Image image;
  final List<Rect> missingRects;
  final double scale;

  _BitmapPainter({
    required this.image,
    required this.missingRects,
    required this.scale,
  });

  static final Paint _missingPaint = Paint()
    ..color = Colors.redAccent
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.none;
    final src = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, paint);

    if (missingRects.isNotEmpty) {
      canvas.save();
      canvas.scale(scale, scale);
      for (final r in missingRects) {
        canvas.drawRect(r, _missingPaint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BitmapPainter old) =>
      old.image != image ||
      old.missingRects != missingRects ||
      old.scale != scale;
}

class _GlyphCardPainter extends CustomPainter {
  final Uint8List pixels;
  final int width;
  final int height;
  final double scale;

  _GlyphCardPainter({
    required this.pixels,
    required this.width,
    required this.height,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF141414);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final fgPaint = Paint()..color = Colors.cyanAccent;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final v = pixels[y * width + x];
        if (v > 0) {
          fgPaint.color = Colors.cyanAccent.withValues(alpha: v / 255.0);
          canvas.drawRect(
            Rect.fromLTWH(x * scale, y * scale, scale, scale),
            fgPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphCardPainter old) =>
      old.pixels != pixels ||
      old.scale != scale ||
      old.width != width ||
      old.height != height;
}

class _GlyphDetailPainter extends CustomPainter {
  final Uint8List pixels;
  final int width;
  final int height;
  final double pixelScale;

  _GlyphDetailPainter({
    required this.pixels,
    required this.width,
    required this.height,
    required this.pixelScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF0A0A0A);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final pxPaint = Paint();
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final v = pixels[y * width + x];
        if (v > 0) {
          pxPaint.color = Colors.cyanAccent.withValues(alpha: v / 255.0);
          canvas.drawRect(
            Rect.fromLTWH(
                x * pixelScale, y * pixelScale, pixelScale, pixelScale),
            pxPaint,
          );
        }
      }
    }

    if (pixelScale >= 4) {
      final linePaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..strokeWidth = 1.0;
      for (int x = 0; x <= width; x++) {
        canvas.drawLine(
          Offset(x * pixelScale, 0),
          Offset(x * pixelScale, height * pixelScale),
          linePaint,
        );
      }
      for (int y = 0; y <= height; y++) {
        canvas.drawLine(
          Offset(0, y * pixelScale),
          Offset(width * pixelScale, y * pixelScale),
          linePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphDetailPainter old) =>
      old.pixels != pixels ||
      old.width != width ||
      old.height != height ||
      old.pixelScale != pixelScale;
}
