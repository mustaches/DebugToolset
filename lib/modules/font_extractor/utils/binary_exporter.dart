import 'dart:typed_data';

import 'packed_glyph.dart';

/// Packs extracted font data into a compact binary file.
///
/// Layout (all integers little-endian):
/// - Header, 16 bytes:
///   - magic "DFNT" (4)
///   - version u16 (=1)
///   - cellWidth u8
///   - cellHeight u8
///   - bitsPerPixel u8
///   - scanMode u8 (0=row-major, 1=column-major)
///   - glyphCount u32
///   - reserved u16
/// - Glyph table, `glyphCount` x 16 bytes:
///   - codepoint u32
///   - width u8, height u8, advance u8
///   - offsetX i8, offsetY i8
///   - reserved u8
///   - dataOffset u32 (absolute file offset of the bitmap bytes)
///   - dataSize u16
/// - Bitmap blob: concatenated packed bitmaps.
class BinaryExporter {
  BinaryExporter._();

  static const int headerSize = 16;
  static const int entrySize = 16;
  static const int version = 1;

  static Uint8List export({
    required int cellWidth,
    required int cellHeight,
    required int bitsPerPixel,
    required bool columnMajor,
    required List<PackedGlyph> glyphs,
  }) {
    final dataStart = headerSize + entrySize * glyphs.length;
    final total = dataStart +
        glyphs.fold<int>(0, (sum, g) => sum + g.data.length);
    final out = ByteData(total);

    int p = 0;
    // Header
    out.setUint8(p++, 0x44); // 'D'
    out.setUint8(p++, 0x46); // 'F'
    out.setUint8(p++, 0x4E); // 'N'
    out.setUint8(p++, 0x54); // 'T'
    out.setUint16(p, version, Endian.little);
    p += 2;
    out.setUint8(p++, cellWidth);
    out.setUint8(p++, cellHeight);
    out.setUint8(p++, bitsPerPixel);
    out.setUint8(p++, columnMajor ? 1 : 0);
    out.setUint32(p, glyphs.length, Endian.little);
    p += 4;
    out.setUint16(p, 0, Endian.little); // reserved
    p += 2;

    // Glyph table
    int dataOffset = dataStart;
    final bytes = BytesBuilder();
    for (final g in glyphs) {
      out.setUint32(p, g.codePoint, Endian.little);
      p += 4;
      out.setUint8(p++, g.width);
      out.setUint8(p++, g.height);
      out.setUint8(p++, g.advance);
      out.setInt8(p++, g.offsetX);
      out.setInt8(p++, g.offsetY);
      out.setUint8(p++, 0); // reserved
      out.setUint32(p, dataOffset, Endian.little);
      p += 4;
      out.setUint16(p, g.data.length, Endian.little);
      p += 2;

      bytes.add(g.data);
      dataOffset += g.data.length;
    }

    // Bitmap blob
    final blob = bytes.toBytes();
    out.buffer.asUint8List().setRange(p, total, blob);
    return out.buffer.asUint8List();
  }
}
