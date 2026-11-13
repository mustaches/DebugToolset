library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pdf;
import 'package:printing/printing.dart';

import 'markdown_pagination.dart';
import 'markdown_pdf.dart';
import 'markdown_print_body.dart';
import 'system_pdf_printer.dart';

const _englishFontPaths = <String, String?>{
  'Courier': null,
  'Unifont': 'Font/unifont13.0.06/unifont-13.0.06.ttf',
  'Ark Pixel': 'Font/ark-pixel-16px.ttf',
  'Fusion Pixel': 'Font/fusion-pixel-12px.ttf',
  'Zpix': 'Font/zpix.ttf',
};
const _chineseFontPaths = <String, String>{
  'Unifont': 'Font/unifont13.0.06/unifont-13.0.06.ttf',
  'Ark Pixel': 'Font/ark-pixel-16px.ttf',
  'Fusion Pixel': 'Font/fusion-pixel-12px.ttf',
  'Zpix': 'Font/zpix.ttf',
};
const verilogPrintFontSizes = <double>[5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0];

String formatVerilogFontSize(double size) {
  return '${size % 1 == 0 ? size.toInt() : size} pt';
}

var _printFontSize = 6.5;
var _printEnglishFont = 'Courier';
var _printChineseFont = 'Unifont';
var _printMarginLeft = 5.0;
var _printMarginTop = 4.0;
var _printMarginRight = 5.0;
var _printMarginBottom = 4.0;
Future<Uint8List>? _microsoftYaHeiBytes;
Future<Uint8List>? _microsoftYaHeiBoldBytes;

Uint8List standaloneTtfFromBytes(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 12 || data.getUint32(0) != 0x74746366) return bytes;
  final fontOffset = data.getUint32(12);
  final tableCount = data.getUint16(fontOffset + 4);
  final tableStart = fontOffset + 12;
  final newOffsets = <int>[];
  var nextOffset = 12 + tableCount * 16;
  for (var index = 0; index < tableCount; index++) {
    final length = data.getUint32(tableStart + index * 16 + 12);
    newOffsets.add(nextOffset);
    nextOffset = (nextOffset + length + 3) & ~3;
  }

  final header = ByteData(12 + tableCount * 16);
  for (var index = 0; index < 12; index++) {
    header.setUint8(index, data.getUint8(fontOffset + index));
  }
  for (var index = 0; index < tableCount; index++) {
    final source = tableStart + index * 16;
    final target = 12 + index * 16;
    for (var byte = 0; byte < 8; byte++) {
      header.setUint8(target + byte, data.getUint8(source + byte));
    }
    header.setUint32(target + 8, newOffsets[index]);
    header.setUint32(target + 12, data.getUint32(source + 12));
  }

  final output = BytesBuilder();
  output.add(header.buffer.asUint8List());
  for (var index = 0; index < tableCount; index++) {
    while (output.length < newOffsets[index]) {
      output.addByte(0);
    }
    final sourceOffset = data.getUint32(tableStart + index * 16 + 8);
    final length = data.getUint32(tableStart + index * 16 + 12);
    output.add(bytes.sublist(sourceOffset, sourceOffset + length));
  }
  return output.toBytes();
}

Future<Uint8List> _loadMicrosoftYaHeiBytes() {
  return _microsoftYaHeiBytes ??= File(
    'C:/Windows/Fonts/msyh.ttc',
  ).readAsBytes().then(standaloneTtfFromBytes);
}

Future<Uint8List> _loadMicrosoftYaHeiBoldBytes() {
  return _microsoftYaHeiBoldBytes ??= File(
    'C:/Windows/Fonts/msyhbd.ttc',
  ).readAsBytes().then(standaloneTtfFromBytes);
}

Future<({Uint8List bytes, int pageCount})> _buildVerilogPdfTask(
  (
    String,
    String,
    PdfPageFormat,
    double,
    Uint8List?,
    Uint8List?,
    Uint8List?,
    Uint8List?,
    Uint8List?,
  )
  request,
) async {
  var pageCount = 0;
  final englishBytes = request.$5;
  final chineseBytes = request.$6;
  final unicodeBytes = request.$7;
  final microsoftYaHeiBytes = request.$8;
  final microsoftYaHeiBoldBytes = request.$9;
  final codeFont = englishBytes == null
      ? pdf.Font.courier()
      : pdf.Font.ttf(ByteData.sublistView(englishBytes));
  final titleFont = englishBytes == null ? pdf.Font.courierBold() : codeFont;
  final bytes = await buildVerilogPdf(
    request.$1,
    request.$2,
    request.$3,
    fontSize: request.$4,
    codeFont: codeFont,
    titleFont: titleFont,
    headerFooterFont: microsoftYaHeiBytes == null
        ? null
        : pdf.Font.ttf(ByteData.sublistView(microsoftYaHeiBytes)),
    headerBoldFont: microsoftYaHeiBoldBytes == null
        ? null
        : pdf.Font.ttf(ByteData.sublistView(microsoftYaHeiBoldBytes)),
    fallbackFonts: [
      if (chineseBytes != null)
        pdf.Font.ttf(ByteData.sublistView(chineseBytes)),
      if (unicodeBytes != null)
        pdf.Font.ttf(ByteData.sublistView(unicodeBytes)),
    ],
    onPageCount: (count) => pageCount = count,
  );
  return (bytes: bytes, pageCount: pageCount);
}

const verilogKeywordColor = PdfColor(0.15, 0.3, 0.7);
const verilogCommentColor = PdfColor(0.12, 0.45, 0.18);
const verilogStringColor = PdfColor(0.55, 0.25, 0.1);
const verilogNumberColor = PdfColor(0.06, 0.4, 0.45);
const verilogDirectiveColor = PdfColor(0.5, 0.18, 0.65);

double verilogPrintLuma(PdfColor color) {
  return 255 * (0.299 * color.red + 0.587 * color.green + 0.114 * color.blue);
}

double verilogFontSizeToLogicalPixels(double fontSize) {
  return fontSize * 96.0 / 72.0;
}

List<pdf.InlineSpan> buildVerilogLineNumberSpans(
  String content,
  double fontSize,
  pdf.Font codeFont,
  List<pdf.Font> fallbackFonts,
) {
  const lineNumberWidth = 5;
  final codeStyle = pdf.TextStyle(
    font: codeFont,
    fontSize: fontSize,
    fontFallback: fallbackFonts,
  );
  final lineNumberStyle = pdf.TextStyle(
    font: pdf.Font.courierBold(),
    fontSize: fontSize,
    fontWeight: pdf.FontWeight.bold,
    fontFallback: fallbackFonts,
  );
  final lines = content.split('\n');
  var inBlockComment = false;
  return [
    for (var index = 0; index < lines.length; index++)
      () {
        final highlighted = _buildVerilogCodeSpans(
          lines[index],
          codeStyle,
          inBlockComment,
        );
        inBlockComment = highlighted.inBlockComment;
        return pdf.TextSpan(
          text: (index + 1).toString().padLeft(lineNumberWidth),
          style: lineNumberStyle,
          children: [
            pdf.TextSpan(text: '  '),
            ...highlighted.spans,
          ],
        );
      }(),
  ];
}

({List<pdf.InlineSpan> spans, bool inBlockComment}) _buildVerilogCodeSpans(
  String line,
  pdf.TextStyle codeStyle,
  bool inBlockComment,
) {
  final commentStyle = codeStyle.copyWith(color: verilogCommentColor);
  final spans = <pdf.InlineSpan>[];
  var index = 0;
  while (index < line.length) {
    if (inBlockComment) {
      final end = line.indexOf('*/', index);
      if (end < 0) {
        spans.add(
          pdf.TextSpan(text: line.substring(index), style: commentStyle),
        );
        return (spans: spans, inBlockComment: true);
      }
      spans.add(
        pdf.TextSpan(text: line.substring(index, end + 2), style: commentStyle),
      );
      index = end + 2;
      inBlockComment = false;
      continue;
    }

    final lineComment = line.indexOf('//', index);
    final blockComment = line.indexOf('/*', index);
    if (lineComment < 0 && blockComment < 0) {
      spans.addAll(_buildVerilogTokenSpans(line.substring(index), codeStyle));
      break;
    }
    if (blockComment >= 0 && (lineComment < 0 || blockComment < lineComment)) {
      if (blockComment > index) {
        spans.addAll(
          _buildVerilogTokenSpans(
            line.substring(index, blockComment),
            codeStyle,
          ),
        );
      }
      final end = line.indexOf('*/', blockComment + 2);
      if (end < 0) {
        spans.add(
          pdf.TextSpan(text: line.substring(blockComment), style: commentStyle),
        );
        return (spans: spans, inBlockComment: true);
      }
      spans.add(
        pdf.TextSpan(
          text: line.substring(blockComment, end + 2),
          style: commentStyle,
        ),
      );
      index = end + 2;
      continue;
    }

    if (lineComment > index) {
      spans.addAll(
        _buildVerilogTokenSpans(line.substring(index, lineComment), codeStyle),
      );
    }
    spans.add(
      pdf.TextSpan(text: line.substring(lineComment), style: commentStyle),
    );
    break;
  }
  return (spans: spans, inBlockComment: inBlockComment);
}

List<pdf.InlineSpan> _buildVerilogTokenSpans(
  String text,
  pdf.TextStyle codeStyle,
) {
  if (text.isEmpty) return const [];
  final keywordStyle = codeStyle.copyWith(color: verilogKeywordColor);
  final stringStyle = codeStyle.copyWith(color: verilogStringColor);
  final numberStyle = codeStyle.copyWith(color: verilogNumberColor);
  final directiveStyle = codeStyle.copyWith(color: verilogDirectiveColor);
  final pattern = RegExp(
    r'''"(?:\\.|[^"\\])*"|`[A-Za-z_][A-Za-z0-9_]*|\b(?:module|endmodule|input|output|inout|wire|reg|logic|parameter|localparam|generate|endgenerate|genvar|if|else|begin|end|always|always_ff|always_comb|always_latch|initial|assign|for|while|repeat|function|endfunction|task|endtask|integer|signed|unsigned|posedge|negedge|case|casez|casex|endcase|default|typedef|enum|struct|union|package|import|export|return|break|continue)\b|\b\d+(?:\'[sS]?[dDhHoObB])?[0-9a-fA-FxXzZ_]*\b''',
  );
  final spans = <pdf.InlineSpan>[];
  var index = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > index) {
      spans.add(pdf.TextSpan(text: text.substring(index, match.start)));
    }
    final token = match.group(0)!;
    final style = token.startsWith('`')
        ? directiveStyle
        : token.startsWith('"')
        ? stringStyle
        : RegExp(r'^\d').hasMatch(token)
        ? numberStyle
        : keywordStyle;
    spans.add(pdf.TextSpan(text: token, style: style));
    index = match.end;
  }
  if (index < text.length) {
    spans.add(pdf.TextSpan(text: text.substring(index)));
  }
  return spans;
}

Future<Uint8List> buildVerilogPdf(
  String fileName,
  String content,
  PdfPageFormat format, {
  double fontSize = 6.5,
  pdf.Font? codeFont,
  pdf.Font? titleFont,
  pdf.Font? headerFooterFont,
  pdf.Font? headerBoldFont,
  List<pdf.Font>? fallbackFonts,
  void Function(int pageCount)? onPageCount,
}) async {
  final document = pdf.Document();
  final effectiveCodeFont = codeFont ?? pdf.Font.courier();
  final effectiveTitleFont = titleFont ?? pdf.Font.courierBold();
  final effectiveHeaderFooterFont = headerFooterFont ?? effectiveTitleFont;
  final effectiveHeaderBoldFont = headerBoldFont ?? effectiveHeaderFooterFont;
  document.addPage(
    pdf.MultiPage(
      pageFormat: format,
      maxPages: 100000,
      header: (context) => pdf.Column(
        children: [
          pdf.Row(
            children: [
              pdf.Text(
                'ISP Studio',
                style: pdf.TextStyle(
                  font: effectiveHeaderBoldFont,
                  fontSize: fontSize + 2,
                  fontWeight: pdf.FontWeight.bold,
                  fontFallback: fallbackFonts ?? const <pdf.Font>[],
                ),
              ),
              pdf.Spacer(),
              pdf.Text(
                fileName,
                style: pdf.TextStyle(
                  font: effectiveHeaderBoldFont,
                  fontSize: fontSize + 2,
                  fontWeight: pdf.FontWeight.bold,
                  fontFallback: fallbackFonts ?? const <pdf.Font>[],
                ),
              ),
            ],
          ),
          pdf.SizedBox(height: 6),
          pdf.Divider(height: 1, thickness: 0.6, color: PdfColors.grey700),
          pdf.SizedBox(height: 8),
        ],
      ),
      footer: (context) => pdf.Column(
        children: [
          pdf.Divider(height: 1, thickness: 0.6, color: PdfColors.grey700),
          pdf.SizedBox(height: 5),
          pdf.Center(
            child: pdf.Text(
              '- ${context.pageNumber} -',
              style: pdf.TextStyle(
                font: effectiveHeaderFooterFont,
                fontSize: fontSize,
                fontFallback: fallbackFonts ?? const <pdf.Font>[],
              ),
            ),
          ),
        ],
      ),
      build: (context) => fileName.toLowerCase().endsWith('.md')
          ? buildMarkdownPdfWidgets(
              content,
              fontSize: fontSize * 1.5,
              bodyFont: effectiveHeaderFooterFont,
              boldFont: effectiveHeaderBoldFont,
              codeFont: effectiveCodeFont,
              fallbackFonts: fallbackFonts ?? const <pdf.Font>[],
            )
          : [
              pdf.Column(
                crossAxisAlignment: pdf.CrossAxisAlignment.start,
                children: [
                  for (final span in buildVerilogLineNumberSpans(
                    content,
                    fontSize,
                    effectiveCodeFont,
                    fallbackFonts ?? const <pdf.Font>[],
                  ))
                    pdf.RichText(text: span),
                ],
              ),
            ],
    ),
  );
  final pageCount = document.document.pdfPageList.pages.length;
  final bytes = await document.save(enableEventLoopBalancing: true);
  onPageCount?.call(pageCount);
  return bytes;
}

class VerilogPrintPreview extends StatefulWidget {
  final String fileName;
  final String content;
  final void Function(BuildContext context)? onPrinted;

  const VerilogPrintPreview({
    super.key,
    required this.fileName,
    required this.content,
    this.onPrinted,
  });

  @override
  State<VerilogPrintPreview> createState() => _VerilogPrintPreviewState();
}

class _VerilogPrintPreviewState extends State<VerilogPrintPreview> {
  final _documentCache = <String, Future<Uint8List>>{};
  final _pageCountByFormat = <String, int>{};
  late final LayoutCallback _buildDocument = _documentFor;
  var _printing = false;
  var _printedPages = 0;
  int? _printTotalPages;
  var _fontRevision = 0;
  var _previewScale = 1.0;
  var _pageFormatName = 'A4';
  var _landscape = false;

  String _formatKey(PdfPageFormat format) => [
    format.width,
    format.height,
    format.marginLeft,
    format.marginTop,
    format.marginRight,
    format.marginBottom,
  ].join(':');

  Future<Uint8List> _loadFontBytes(String path) async {
    final data = await rootBundle.load(path);
    return data.buffer.asUint8List();
  }

  Future<Uint8List> _documentFor(PdfPageFormat format) {
    final key = _formatKey(format);
    return _documentCache.putIfAbsent(key, () async {
      final revision = _fontRevision;
      try {
        final englishPath = _englishFontPaths[_printEnglishFont];
        final englishBytes = englishPath == null
            ? null
            : await _loadFontBytes(englishPath);
        final needsChinese =
            widget.content.runes.any((rune) => rune > 0x7f) ||
            widget.fileName.runes.any((rune) => rune > 0x7f);
        final chinesePath = _chineseFontPaths[_printChineseFont]!;
        final chineseBytes = needsChinese
            ? await _loadFontBytes(chinesePath)
            : null;
        const unicodePath = 'Font/unifont13.0.06/unifont-13.0.06.ttf';
        final unicodeBytes = needsChinese && chinesePath != unicodePath
            ? await _loadFontBytes(unicodePath)
            : null;
        final microsoftYaHeiBytes = Platform.isWindows
            ? await _loadMicrosoftYaHeiBytes()
            : null;
        final microsoftYaHeiBoldBytes = Platform.isWindows
            ? await _loadMicrosoftYaHeiBoldBytes()
            : null;
        final result = await compute(_buildVerilogPdfTask, (
          widget.fileName,
          widget.content,
          format,
          _printFontSize,
          englishBytes,
          chineseBytes,
          unicodeBytes,
          microsoftYaHeiBytes,
          microsoftYaHeiBoldBytes,
        ));
        if (revision == _fontRevision) {
          _pageCountByFormat[key] = result.pageCount;
        }
        return result.bytes;
      } catch (_) {
        rethrow;
      }
    });
  }

  Future<void> _openFontSettings() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => const _VerilogFontSettingsDialog(),
    );
    if (changed == true && mounted) {
      setState(() {
        _fontRevision++;
        _documentCache.clear();
        _pageCountByFormat.clear();
      });
    }
  }

  Future<void> _openLayoutSettings() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => const _VerilogLayoutSettingsDialog(),
    );
    if (changed == true && mounted) {
      setState(() {
        _documentCache.clear();
        _pageCountByFormat.clear();
      });
    }
  }

  void _handlePrinted(BuildContext context) {
    widget.onPrinted?.call(context);
    Navigator.of(context).pop();
  }

  void _handlePrintError(BuildContext context, dynamic error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('打印失败：$error')));
  }

  Future<void> _print(
    BuildContext context,
    LayoutCallback build,
    PdfPageFormat format,
  ) async {
    if (_printing) return;
    setState(() {
      _printing = true;
      _printedPages = 0;
      _printTotalPages = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      final bytes = await build(format);
      if (!mounted) return;
      final printed = await SystemPdfPrinter.printDocument(
        bytes: bytes,
        name: widget.fileName,
        format: format,
        onProgress: (completed, total) {
          if (mounted) {
            setState(() {
              _printedPages = completed;
              _printTotalPages = total;
            });
          }
        },
      );
      if (!mounted) return;
      if (printed) _handlePrinted(this.context);
    } catch (error) {
      if (mounted) _handlePrintError(this.context, error);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  PdfPageFormat get _currentFormat {
    final format = _pageFormatName == 'Letter'
        ? PdfPageFormat.letter
        : PdfPageFormat.a4;
    final oriented = _landscape ? format.landscape : format.portrait;
    return PdfPageFormat(
      oriented.width,
      oriented.height,
      marginLeft: oriented.width * _printMarginLeft / 100,
      marginTop: oriented.height * _printMarginTop / 100,
      marginRight: oriented.width * _printMarginRight / 100,
      marginBottom: oriented.height * _printMarginBottom / 100,
    );
  }

  void _setPreviewScale(double scale) {
    setState(() => _previewScale = scale.clamp(0.5, 3.0));
  }

  Widget _buildVectorPreview() {
    return VerilogVectorPreview(
      fileName: widget.fileName,
      content: widget.content,
      fontSize: _printFontSize,
      englishFont: _printEnglishFont,
      chineseFont: _printChineseFont,
      scale: _previewScale,
      format: _currentFormat,
      formatName: _pageFormatName,
      landscape: _landscape,
      onScaleChanged: _setPreviewScale,
      onFormatNameChanged: (name) {
        setState(() => _pageFormatName = name);
      },
      onOrientationChanged: (landscape) {
        setState(() => _landscape = landscape);
      },
      onFontSettings: _openFontSettings,
      onLayoutSettings: _openLayoutSettings,
      onPrint: () => _print(context, _buildDocument, _currentFormat),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF3C3C3C),
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 1200,
        height: 820,
        child: Column(
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF2A2A2A),
                border: Border(bottom: BorderSide(color: Color(0xFF444444))),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 18,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '打印预览 · ${widget.fileName}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                    ),
                  ),
                  IconButton(
                    tooltip: '退出预览',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close,
                      size: 18,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  _buildVectorPreview(),
                  if (_printing)
                    Positioned.fill(
                      child: VerilogPrintingOverlay(
                        completed: _printedPages,
                        total: _printTotalPages,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              height: _printing ? 42 : 30,
              padding: EdgeInsets.symmetric(
                horizontal: _printing ? 16 : 0,
                vertical: _printing ? 6 : 0,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF2A2A2A),
                border: Border(top: BorderSide(color: Color(0xFF444444))),
              ),
              child: _printing
                  ? Row(
                      key: const ValueKey('verilog-system-print-progress'),
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: _printTotalPages == null
                                ? null
                                : _printedPages / _printTotalPages!,
                            minHeight: 3,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _printTotalPages == null
                              ? '正在打开系统打印窗口…'
                              : '正在打印：$_printedPages/$_printTotalPages 页',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    )
                  : const Center(
                      child: Text(
                        '调整版式后，点击预览工具栏中的打印图标完成打印',
                        style: TextStyle(fontSize: 11, color: Colors.white60),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

final _pageDecoration = BoxDecoration(
  color: Colors.white,
  border: Border.all(color: const Color(0xFF9E9E9E), width: 0.6),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.55),
      blurRadius: 32,
      spreadRadius: 3,
      offset: const Offset(0, 14),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.35),
      blurRadius: 8,
      offset: const Offset(0, 3),
    ),
  ],
);

class VerilogVectorPreview extends StatefulWidget {
  final String fileName;
  final String content;
  final double fontSize;
  final String englishFont;
  final String chineseFont;
  final double scale;
  final PdfPageFormat format;
  final String formatName;
  final bool landscape;
  final ValueChanged<double> onScaleChanged;
  final ValueChanged<String> onFormatNameChanged;
  final ValueChanged<bool> onOrientationChanged;
  final VoidCallback onFontSettings;
  final VoidCallback onLayoutSettings;
  final VoidCallback onPrint;

  const VerilogVectorPreview({
    super.key,
    required this.fileName,
    required this.content,
    required this.fontSize,
    required this.englishFont,
    required this.chineseFont,
    required this.scale,
    required this.format,
    required this.formatName,
    required this.landscape,
    required this.onScaleChanged,
    required this.onFormatNameChanged,
    required this.onOrientationChanged,
    required this.onFontSettings,
    required this.onLayoutSettings,
    required this.onPrint,
  });

  @override
  State<VerilogVectorPreview> createState() => _VerilogVectorPreviewState();
}

class _VerilogVectorPreviewState extends State<VerilogVectorPreview> {
  late List<pdf.InlineSpan> _lineSpans;
  late List<String> _markdownPages;

  @override
  void initState() {
    super.initState();
    _rebuildSpans();
  }

  @override
  void didUpdateWidget(covariant VerilogVectorPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.fileName != widget.fileName ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.englishFont != widget.englishFont ||
        oldWidget.chineseFont != widget.chineseFont ||
        oldWidget.format.width != widget.format.width ||
        oldWidget.format.height != widget.format.height ||
        oldWidget.format.marginLeft != widget.format.marginLeft ||
        oldWidget.format.marginTop != widget.format.marginTop ||
        oldWidget.format.marginRight != widget.format.marginRight ||
        oldWidget.format.marginBottom != widget.format.marginBottom) {
      _rebuildSpans();
    }
  }

  void _rebuildSpans() {
    if (widget.fileName.toLowerCase().endsWith('.md')) {
      _lineSpans = const [];
      _markdownPages = paginateMarkdownForPrint(
        widget.content,
        widget.format,
        widget.fontSize,
      );
      return;
    }
    _lineSpans = buildVerilogLineNumberSpans(
      widget.content,
      widget.fontSize,
      pdf.Font.courier(),
      const <pdf.Font>[],
    );
  }

  int get _linesPerPage => verilogLinesPerPage(
    format: widget.format,
    fontSize: widget.fontSize,
    englishFont: widget.englishFont,
  );

  Widget _buildZoomControls() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF333333),
        border: Border.all(color: const Color(0xFF555555)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('verilog-preview-zoom-out'),
            tooltip: '缩小预览',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: widget.scale > 0.5
                ? () => widget.onScaleChanged(widget.scale - 0.25)
                : null,
            icon: const Icon(Icons.zoom_out),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${(widget.scale * 100).round()}%',
              key: const ValueKey('verilog-preview-zoom-label'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          IconButton(
            key: const ValueKey('verilog-preview-zoom-in'),
            tooltip: '放大预览',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: widget.scale < 3.0
                ? () => widget.onScaleChanged(widget.scale + 0.25)
                : null,
            icon: const Icon(Icons.zoom_in),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF3C3C3C),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: widget.fileName.toLowerCase().endsWith('.md')
                  ? _markdownPages.length
                  : (_lineSpans.length + _linesPerPage - 1) ~/ _linesPerPage,
              itemBuilder: (context, index) {
                final start = index * _linesPerPage;
                final end = start + _linesPerPage < _lineSpans.length
                    ? start + _linesPerPage
                    : _lineSpans.length;
                return _VerilogVectorPage(
                  key: ValueKey('verilog-preview-page-$index'),
                  spans: widget.fileName.toLowerCase().endsWith('.md')
                      ? const []
                      : _lineSpans.sublist(start, end),
                  content: widget.fileName.toLowerCase().endsWith('.md')
                      ? _markdownPages[index]
                      : widget.content,
                  pageIndex: index,
                  pageCount: widget.fileName.toLowerCase().endsWith('.md')
                      ? _markdownPages.length
                      : (_lineSpans.length + _linesPerPage - 1) ~/
                            _linesPerPage,
                  format: widget.format,
                  scale: widget.scale,
                  fontSize: widget.fontSize,
                  englishFont: widget.englishFont,
                  fileName: widget.fileName,
                );
              },
            ),
          ),
        ),
        Container(
          height: 46,
          color: const Color(0xFF2A2A2A),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 100,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: widget.formatName,
                    dropdownColor: const Color(0xFF2A2A2A),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    items: const [
                      DropdownMenuItem(value: 'A4', child: Text('A4')),
                      DropdownMenuItem(value: 'Letter', child: Text('Letter')),
                    ],
                    onChanged: (value) {
                      if (value != null) widget.onFormatNameChanged(value);
                    },
                  ),
                ),
              ),
              IconButton(
                tooltip: '纵向',
                onPressed: () => widget.onOrientationChanged(false),
                icon: const Icon(Icons.stay_current_portrait, size: 20),
              ),
              IconButton(
                tooltip: '横向',
                onPressed: () => widget.onOrientationChanged(true),
                icon: const Icon(Icons.stay_current_landscape, size: 20),
              ),
              const SizedBox(width: 8),
              _buildZoomControls(),
              IconButton(
                key: const ValueKey('verilog-layout-settings'),
                tooltip: '版式设置',
                onPressed: widget.onLayoutSettings,
                icon: const Icon(Icons.margin_outlined),
              ),
              IconButton(
                key: const ValueKey('verilog-font-settings'),
                tooltip: '字体设置',
                onPressed: widget.onFontSettings,
                icon: const Icon(Icons.text_fields),
              ),
              IconButton(
                key: const ValueKey('verilog-print-action'),
                tooltip: '打印',
                onPressed: widget.onPrint,
                icon: const Icon(Icons.print),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VerilogVectorPage extends StatefulWidget {
  final List<pdf.InlineSpan> spans;
  final String content;
  final int pageIndex;
  final int pageCount;
  final PdfPageFormat format;
  final double scale;
  final double fontSize;
  final String englishFont;
  final String fileName;

  const _VerilogVectorPage({
    super.key,
    required this.spans,
    required this.content,
    required this.pageIndex,
    required this.pageCount,
    required this.format,
    required this.scale,
    required this.fontSize,
    required this.englishFont,
    required this.fileName,
  });

  @override
  State<_VerilogVectorPage> createState() => _VerilogVectorPageState();
}

class _VerilogVectorPageState extends State<_VerilogVectorPage> {
  final _controller = ScrollController();

  void _centerAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent / 2);
    });
  }

  @override
  void initState() {
    super.initState();
    _centerAfterFrame();
  }

  @override
  void didUpdateWidget(covariant _VerilogVectorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scale != widget.scale) _centerAfterFrame();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final headerStyle = TextStyle(
      fontFamily: 'Microsoft YaHei',
      fontSize: verilogFontSizeToLogicalPixels(widget.fontSize + 2),
      color: Colors.black,
    );
    final codeStyle = TextStyle(
      fontFamily: _englishFontFamilies[widget.englishFont],
      fontSize: verilogFontSizeToLogicalPixels(widget.fontSize),
      color: Colors.black,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseWidth = constraints.maxWidth < 760
            ? constraints.maxWidth
            : 760.0;
        return Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: baseWidth * widget.scale,
              child: Container(
                margin: const EdgeInsets.fromLTRB(36, 24, 36, 40),
                decoration: _pageDecoration,
                child: AspectRatio(
                  aspectRatio: widget.format.width / widget.format.height,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(
                      widget.format.marginLeft * widget.scale,
                      widget.format.marginTop * widget.scale,
                      widget.format.marginRight * widget.scale,
                      widget.format.marginBottom * widget.scale,
                    ),
                    color: Colors.white,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              'ISP Studio',
                              style: headerStyle.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Expanded(
                              child: Text(
                                widget.fileName,
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                                style: headerStyle.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Divider(height: 1, thickness: 0.6),
                        const SizedBox(height: 8),
                        Expanded(
                          child: SingleChildScrollView(
                            child: widget.fileName.toLowerCase().endsWith('.md')
                                ? MarkdownPrintBody(
                                    text: widget.content,
                                    fontSize:
                                        verilogFontSizeToLogicalPixels(
                                          widget.fontSize * 1.5,
                                        ) *
                                        widget.scale,
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (final span in widget.spans)
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text.rich(
                                            _flutterSpan(
                                              span,
                                              _englishFontFamilies[widget
                                                  .englishFont]!,
                                              widget.fontSize,
                                            ),
                                            textScaler: TextScaler.linear(
                                              widget.scale,
                                            ),
                                            textAlign: TextAlign.left,
                                            style: codeStyle,
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                        ),
                        const Divider(height: 1, thickness: 0.6),
                        const SizedBox(height: 5),
                        Center(
                          child: Text(
                            '- ${widget.pageIndex + 1} -',
                            style: headerStyle.copyWith(
                              fontSize: verilogFontSizeToLogicalPixels(
                                widget.fontSize,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

int verilogLinesPerPage({
  required PdfPageFormat format,
  required double fontSize,
  required String englishFont,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: 'Ag',
      style: TextStyle(
        fontFamily: _englishFontFamilies[englishFont],
        fontSize: verilogFontSizeToLogicalPixels(fontSize),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final lineHeight = painter.height > 0 ? painter.height : fontSize;
  final availableHeight =
      format.height - format.marginTop - format.marginBottom - 70;
  return (availableHeight / lineHeight).floor().clamp(1, 10000);
}

const _englishFontFamilies = <String, String>{
  'Courier': 'Courier New',
  'Unifont': 'Unifont',
  'Ark Pixel': 'ArkPixel',
  'Fusion Pixel': 'FusionPixel',
  'Zpix': 'Zpix',
};

Color _flutterColor(PdfColor? color) {
  if (color == null) return Colors.black;
  return Color.fromARGB(
    (color.alpha * 255).round(),
    (color.red * 255).round(),
    (color.green * 255).round(),
    (color.blue * 255).round(),
  );
}

InlineSpan _flutterSpan(
  pdf.InlineSpan span,
  String fontFamily,
  double fontSize,
) {
  if (span is! pdf.TextSpan) return const TextSpan();
  final style = span.style;
  return TextSpan(
    text: span.text,
    style: TextStyle(
      color: _flutterColor(style?.color),
      fontFamily: style?.fontWeight == pdf.FontWeight.bold
          ? 'Courier New'
          : fontFamily,
      fontSize: style?.fontSize == null
          ? fontSize
          : verilogFontSizeToLogicalPixels(style!.fontSize!),
      fontWeight: style?.fontWeight == pdf.FontWeight.bold
          ? FontWeight.bold
          : FontWeight.normal,
    ),
    children: span.children
        ?.map((child) => _flutterSpan(child, fontFamily, fontSize))
        .toList(),
  );
}

class _VerilogLayoutSettingsDialog extends StatefulWidget {
  const _VerilogLayoutSettingsDialog();

  @override
  State<_VerilogLayoutSettingsDialog> createState() =>
      _VerilogLayoutSettingsDialogState();
}

class _VerilogLayoutSettingsDialogState
    extends State<_VerilogLayoutSettingsDialog> {
  late final _leftController = TextEditingController(
    text: _printMarginLeft.toString(),
  );
  late final _topController = TextEditingController(
    text: _printMarginTop.toString(),
  );
  late final _rightController = TextEditingController(
    text: _printMarginRight.toString(),
  );
  late final _bottomController = TextEditingController(
    text: _printMarginBottom.toString(),
  );
  String? _error;

  @override
  void dispose() {
    _leftController.dispose();
    _topController.dispose();
    _rightController.dispose();
    _bottomController.dispose();
    super.dispose();
  }

  Widget _marginField(String label, TextEditingController controller, Key key) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: key,
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: '$label（%）'),
      ),
    );
  }

  void _apply() {
    final values = [
      _leftController.text,
      _topController.text,
      _rightController.text,
      _bottomController.text,
    ].map(double.tryParse).toList();
    if (values.any((value) => value == null || value < 0 || value > 50)) {
      setState(() => _error = '请输入 0–50 之间的数值');
      return;
    }
    _printMarginLeft = values[0]!;
    _printMarginTop = values[1]!;
    _printMarginRight = values[2]!;
    _printMarginBottom = values[3]!;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('版式设置'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _marginField(
              '左侧留白',
              _leftController,
              const ValueKey('layout-margin-left'),
            ),
            _marginField(
              '上方留白',
              _topController,
              const ValueKey('layout-margin-top'),
            ),
            _marginField(
              '右侧留白',
              _rightController,
              const ValueKey('layout-margin-right'),
            ),
            _marginField(
              '下方留白',
              _bottomController,
              const ValueKey('layout-margin-bottom'),
            ),
            Text(
              _error ?? '左右按页宽计算，上下按页高计算，范围 0–50%。',
              style: TextStyle(
                fontSize: 12,
                color: _error == null ? Colors.white60 : Colors.redAccent,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('verilog-apply-layout-settings'),
          onPressed: _apply,
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class _VerilogFontSettingsDialog extends StatefulWidget {
  const _VerilogFontSettingsDialog();

  @override
  State<_VerilogFontSettingsDialog> createState() =>
      _VerilogFontSettingsDialogState();
}

class _VerilogFontSettingsDialogState
    extends State<_VerilogFontSettingsDialog> {
  var _fontSize = _printFontSize;
  var _englishFont = _printEnglishFont;
  var _chineseFont = _printChineseFont;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('打印字体设置'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<double>(
              key: const ValueKey('verilog-print-font-size'),
              initialValue: _fontSize,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '字号'),
              items: verilogPrintFontSizes
                  .map(
                    (size) => DropdownMenuItem(
                      value: size,
                      child: Text(formatVerilogFontSize(size)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _fontSize = value);
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const ValueKey('verilog-print-english-font'),
              initialValue: _englishFont,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '英文等宽字体'),
              items: _englishFontPaths.keys
                  .map(
                    (font) => DropdownMenuItem(value: font, child: Text(font)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _englishFont = value);
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const ValueKey('verilog-print-chinese-font'),
              initialValue: _chineseFont,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '中文 Unicode 字体'),
              items: _chineseFontPaths.keys
                  .map(
                    (font) => DropdownMenuItem(value: font, child: Text(font)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _chineseFont = value);
              },
            ),
            const SizedBox(height: 12),
            const Text(
              '中文字体用于英文等宽字体不支持的字符，随 PDF 一同嵌入。',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('verilog-apply-font-settings'),
          onPressed: () {
            _printFontSize = _fontSize;
            _printEnglishFont = _englishFont;
            _printChineseFont = _chineseFont;
            Navigator.of(context).pop(true);
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class VerilogPrintingOverlay extends StatelessWidget {
  final int completed;
  final int? total;
  final String? title;
  final String? detail;
  final IconData icon;

  const VerilogPrintingOverlay({
    super.key,
    required this.completed,
    required this.total,
    this.title,
    this.detail,
    this.icon = Icons.print_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.65),
      child: Center(
        child: Container(
          key: const ValueKey('verilog-printing-overlay'),
          width: 380,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF252525),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF666666)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 18,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: Colors.white70),
              const SizedBox(height: 14),
              Text(
                title ?? (total == null ? '正在打开系统打印窗口…' : '正在打印'),
                style: const TextStyle(fontSize: 17, color: Colors.white),
              ),
              const SizedBox(height: 18),
              LinearProgressIndicator(
                key: const ValueKey('verilog-printing-overlay-bar'),
                value: total == null ? null : completed / total!,
                minHeight: 7,
              ),
              const SizedBox(height: 10),
              Text(
                detail ?? (total == null ? '请稍候' : '$completed/$total 页'),
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class VerilogRenderProgress extends StatelessWidget {
  final int completed;
  final int total;

  const VerilogRenderProgress({
    super.key,
    required this.completed,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('verilog-render-progress'),
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFF2A2A2A),
      child: Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              key: const ValueKey('verilog-render-progress-bar'),
              value: total == 0 ? null : completed / total,
              minHeight: 4,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '正在渲染预览：$completed/$total 页',
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

Future<void> showVerilogPrintPreview(
  BuildContext context,
  String fileName,
  String content, {
  void Function(BuildContext context)? onPrinted,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => VerilogPrintPreview(
      fileName: fileName,
      content: content,
      onPrinted: onPrinted,
    ),
  );
}
