import 'dart:typed_data';

import 'binary_exporter.dart';

/// A single glyph entry parsed from a DFNT binary font file.
class DfntGlyph {
  final int codePoint;
  final int width;
  final int height;
  final int advance;
  final int offsetX;
  final int offsetY;

  /// Packed bitmap bytes (see `packBitmap`).
  final Uint8List data;

  const DfntGlyph({
    required this.codePoint,
    required this.width,
    required this.height,
    required this.advance,
    required this.offsetX,
    required this.offsetY,
    required this.data,
  });
}

/// A parsed DFNT binary font file (the format written by [BinaryExporter]).
class DfntFont {
  final int cellWidth;
  final int cellHeight;
  final int bitsPerPixel;
  final bool columnMajor;
  final Map<int, DfntGlyph> glyphs;

  const DfntFont({
    required this.cellWidth,
    required this.cellHeight,
    required this.bitsPerPixel,
    required this.columnMajor,
    required this.glyphs,
  });

  int get glyphCount => glyphs.length;

  /// Looks up the glyph for [grapheme] by its first code point.
  DfntGlyph? glyphFor(String grapheme) =>
      grapheme.isEmpty ? null : glyphs[grapheme.runes.first];

  /// Parses DFNT [bytes]. Throws [FormatException] on invalid data.
  static DfntFont parse(Uint8List bytes) {
    if (bytes.length < BinaryExporter.headerSize) {
      throw const FormatException('文件太小，不是有效的 DFNT 字库');
    }
    final d = ByteData.sublistView(bytes);
    if (d.getUint8(0) != 0x44 || // 'D'
        d.getUint8(1) != 0x46 || // 'F'
        d.getUint8(2) != 0x4E || // 'N'
        d.getUint8(3) != 0x54) {
      // 'T'
      throw const FormatException('不是 DFNT 格式的字库文件');
    }
    final version = d.getUint16(4, Endian.little);
    if (version != BinaryExporter.version) {
      throw FormatException('不支持的 DFNT 版本: $version');
    }
    final cellWidth = d.getUint8(6);
    final cellHeight = d.getUint8(7);
    final bitsPerPixel = d.getUint8(8);
    final columnMajor = d.getUint8(9) == 1;
    final glyphCount = d.getUint32(10, Endian.little);

    final tableEnd =
        BinaryExporter.headerSize + BinaryExporter.entrySize * glyphCount;
    if (bytes.length < tableEnd) {
      throw const FormatException('DFNT 字形表不完整');
    }

    final glyphs = <int, DfntGlyph>{};
    int p = BinaryExporter.headerSize;
    for (int i = 0; i < glyphCount; i++) {
      final codePoint = d.getUint32(p, Endian.little);
      final width = d.getUint8(p + 4);
      final height = d.getUint8(p + 5);
      final advance = d.getUint8(p + 6);
      final offsetX = d.getInt8(p + 7);
      final offsetY = d.getInt8(p + 8);
      final dataOffset = d.getUint32(p + 10, Endian.little);
      final dataSize = d.getUint16(p + 14, Endian.little);
      p += BinaryExporter.entrySize;
      if (dataOffset + dataSize > bytes.length) {
        throw FormatException('字形 U+${codePoint.toRadixString(16)} 数据越界');
      }
      glyphs[codePoint] = DfntGlyph(
        codePoint: codePoint,
        width: width,
        height: height,
        advance: advance,
        offsetX: offsetX,
        offsetY: offsetY,
        data: Uint8List.sublistView(bytes, dataOffset, dataOffset + dataSize),
      );
    }

    return DfntFont(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      bitsPerPixel: bitsPerPixel,
      columnMajor: columnMajor,
      glyphs: glyphs,
    );
  }
}
