import 'dart:math' as math;

import 'package:pdf/pdf.dart';

List<String> paginateMarkdownForPrint(
  String content,
  PdfPageFormat format,
  double fontSize,
) {
  final bodySize = fontSize * 1.5;
  final width = format.width - format.marginLeft - format.marginRight;
  final height =
      format.height - format.marginTop - format.marginBottom - bodySize * 3.2;
  final blocks = _markdownBlocks(content);
  final pages = <String>[];
  final current = <String>[];
  var usedHeight = 0.0;

  for (final block in blocks) {
    final blockHeight = _blockHeight(block, width, bodySize);
    if (current.isNotEmpty && usedHeight + blockHeight > height) {
      pages.add(current.join('\n\n'));
      current.clear();
      usedHeight = 0;
    }
    current.add(block);
    usedHeight += blockHeight;
  }
  if (current.isNotEmpty) pages.add(current.join('\n\n'));
  return pages.isEmpty ? [''] : pages;
}

List<String> _markdownBlocks(String content) {
  final lines = content.replaceAll('\r\n', '\n').split('\n');
  final blocks = <String>[];
  final current = <String>[];
  var inFence = false;

  void flush() {
    if (current.isEmpty) return;
    blocks.add(current.join('\n').trimRight());
    current.clear();
  }

  for (final line in lines) {
    final trimmed = line.trimLeft();
    final isFence = trimmed.startsWith('```') || trimmed.startsWith('~~~');
    if (line.trim().isEmpty && !inFence) {
      flush();
      continue;
    }
    if (!inFence &&
        current.isNotEmpty &&
        RegExp(r'^#{1,6}\s').hasMatch(trimmed)) {
      flush();
    }
    current.add(line);
    if (isFence) inFence = !inFence;
  }
  flush();
  return blocks;
}

double _blockHeight(String block, double width, double fontSize) {
  final lines = block.split('\n');
  final first = lines.first.trimLeft();
  final heading = RegExp(r'^(#{1,6})\s').firstMatch(first);
  if (heading != null) {
    final level = heading.group(1)!.length;
    const factors = [1.8, 1.5, 1.3, 1.15, 1.05, 1.0];
    final size = fontSize * factors[level - 1];
    return _wrappedLines(first.substring(heading.end), width, size) *
            size *
            1.35 +
        (level <= 2 ? 13 : 10);
  }
  if (first.startsWith('```') || first.startsWith('~~~')) {
    return math.max(1, lines.length - 2) * fontSize * 0.9 * 1.25 + 21;
  }
  if (first.startsWith('|')) {
    final columns = math.max(1, _tableCells(lines.first).length);
    var height = 7.0;
    for (final line in lines) {
      final cells = _tableCells(line);
      if (cells.every((cell) => RegExp(r'^:?-{3,}:?$').hasMatch(cell))) {
        continue;
      }
      var rowLines = 1;
      for (final cell in cells) {
        rowLines = math.max(
          rowLines,
          _wrappedLines(cell, width / columns - 10, fontSize),
        );
      }
      height += rowLines * fontSize * 1.35 + 8;
    }
    return height;
  }
  if (RegExp(r'^\s*([-*+]|\d+\.)\s').hasMatch(lines.first)) {
    var height = 0.0;
    for (final line in lines) {
      final item = RegExp(r'^(\s*)(?:[-*+]|\d+\.)\s').firstMatch(line);
      final indent = item?.group(1)?.length ?? 0;
      final text = item == null ? line : line.substring(item.end);
      height +=
          _wrappedLines(text, width - 18 - indent * 4, fontSize) *
              fontSize *
              1.35 +
          3;
    }
    return height;
  }
  final text = lines.join(' ').trim();
  return _wrappedLines(text, width, fontSize) * fontSize * 1.35 + 5;
}

List<String> _tableCells(String line) {
  return line
      .trim()
      .replaceAll(RegExp(r'^\||\|$'), '')
      .split('|')
      .map((cell) => cell.trim())
      .toList();
}

int _wrappedLines(String text, double width, double fontSize) {
  final plain = text
      .replaceAll(RegExp(r'`([^`]*)`'), r'$1')
      .replaceAll(RegExp(r'\*\*([^*]*)\*\*'), r'$1')
      .replaceAll(RegExp(r'\*([^*]*)\*'), r'$1')
      .replaceAll(RegExp(r'\[([^]]*)\]\([^)]*\)'), r'$1');
  final capacity = math.max(1.0, width / fontSize);
  var units = 0.0;
  for (final rune in plain.runes) {
    units += rune > 0x7f ? 1.0 : 0.55;
  }
  return math.max(1, (units / capacity).ceil());
}
