import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/font_extractor/utils/binary_exporter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/bitmap_converter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/c_array_exporter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/font_info.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/packed_glyph.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/unicode_blocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('parseRangeInput', () {
    test('parses single hex value', () {
      final r = parseRangeInput('0x41');
      expect(r, [(start: 0x41, end: 0x41)]);
    });

    test('parses hex range', () {
      final r = parseRangeInput('0x20-0x7E');
      expect(r, [(start: 0x20, end: 0x7E)]);
    });

    test('parses U+ prefix range', () {
      final r = parseRangeInput('U+4E00-U+9FFF');
      expect(r, [(start: 0x4E00, end: 0x9FFF)]);
    });

    test('parses decimal range', () {
      final r = parseRangeInput('32-126');
      expect(r, [(start: 32, end: 126)]);
    });

    test('parses mixed input with commas and spaces', () {
      final r = parseRangeInput('0x41, 0x42-0x44 U+0301');
      expect(r.length, 3);
      expect(r[0], (start: 0x41, end: 0x41));
      expect(r[1], (start: 0x42, end: 0x44));
      expect(r[2], (start: 0x301, end: 0x301));
    });

    test('parses plain hex letters without 0x prefix', () {
      final r = parseRangeInput('4E00-9FFF');
      expect(r, [(start: 0x4E00, end: 0x9FFF)]);
    });

    test('rejects invalid input', () {
      expect(() => parseRangeInput('hello'), throwsFormatException);
      expect(() => parseRangeInput('0x7E-0x20'), throwsFormatException);
      expect(() => parseRangeInput('0x110000'), throwsFormatException);
    });
  });

  group('expandToCodePoints', () {
    test('expands and dedupes blocks and ranges', () {
      const block = UnicodeBlock('Test', 0x41, 0x43);
      final cps = expandToCodePoints(
        blocks: [block],
        customRanges: [(start: 0x43, end: 0x45)],
      );
      expect(cps, [0x41, 0x42, 0x43, 0x44, 0x45]);
    });
  });

  group('packBitmap 1bpp row-major', () {
    test('packs 8x2 pattern MSB first', () {
      // Row 0: 10101010 -> 0xAA, Row 1: 01010101 -> 0x55
      final pixels = <int>[
        255, 0, 255, 0, 255, 0, 255, 0,
        0, 255, 0, 255, 0, 255, 0, 255,
      ];
      final out = packBitmap(
        pixels: pixels,
        width: 8,
        height: 2,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.rowMajor,
      );
      expect(out, [0xAA, 0x55]);
    });

    test('pads partial byte in last column', () {
      // width 5, row: 11111 -> 0xF8
      final pixels = List.filled(5, 255);
      final out = packBitmap(
        pixels: pixels,
        width: 5,
        height: 1,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.rowMajor,
      );
      expect(out, [0xF8]);
    });

    test('respects threshold boundary', () {
      final pixels = [127, 128, 129, 255, 0, 0, 0, 0];
      final out = packBitmap(
        pixels: pixels,
        width: 8,
        height: 1,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.rowMajor,
        threshold: 128,
      );
      // 127<128 off, 128>=128 on, 129 on, 255 on -> 01110000 = 0x70
      expect(out, [0x70]);
    });
  });

  group('packBitmap 1bpp column-major', () {
    test('packs vertical strips LSB first', () {
      // 2x8: column 0 all on -> 0xFF; column 1 all off -> 0x00
      final pixels = <int>[];
      for (int y = 0; y < 8; y++) {
        pixels.addAll([255, 0]);
      }
      final out = packBitmap(
        pixels: pixels,
        width: 2,
        height: 8,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.columnMajor,
      );
      expect(out, [0xFF, 0x00]);
    });

    test('handles partial last page', () {
      // 1x10: top 8 on, bottom 2 on
      final pixels = List.filled(10, 255);
      final out = packBitmap(
        pixels: pixels,
        width: 1,
        height: 10,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.columnMajor,
      );
      expect(out, [0xFF, 0x03]);
    });
  });

  group('packBitmap 8bpp', () {
    test('row-major passes pixels through', () {
      final pixels = [1, 2, 3, 4];
      final out = packBitmap(
        pixels: pixels,
        width: 2,
        height: 2,
        depth: BitmapBitDepth.eight,
        scan: BitmapScanMode.rowMajor,
      );
      expect(out, [1, 2, 3, 4]);
    });

    test('column-major transposes', () {
      final pixels = [1, 2, 3, 4]; // (0,0)=1 (1,0)=2 (0,1)=3 (1,1)=4
      final out = packBitmap(
        pixels: pixels,
        width: 2,
        height: 2,
        depth: BitmapBitDepth.eight,
        scan: BitmapScanMode.columnMajor,
      );
      expect(out, [1, 3, 2, 4]);
    });
  });

  group('packedByteLength', () {
    test('computes sizes', () {
      expect(
        packedByteLength(
          width: 8,
          height: 16,
          depth: BitmapBitDepth.one,
          scan: BitmapScanMode.rowMajor,
        ),
        16,
      );
      expect(
        packedByteLength(
          width: 9,
          height: 16,
          depth: BitmapBitDepth.one,
          scan: BitmapScanMode.rowMajor,
        ),
        32,
      );
      expect(
        packedByteLength(
          width: 8,
          height: 16,
          depth: BitmapBitDepth.eight,
          scan: BitmapScanMode.rowMajor,
        ),
        128,
      );
    });
  });

  group('CArrayExporter', () {
    test('emits source and header with glyph entries', () {
      final glyphs = [
        PackedGlyph(
          codePoint: 0x41,
          width: 8,
          height: 2,
          advance: 8,
          offsetX: 0,
          offsetY: 0,
          data: Uint8List.fromList([0xAA, 0x55]),
        ),
        PackedGlyph(
          codePoint: 0x42,
          width: 8,
          height: 2,
          advance: 8,
          offsetX: 0,
          offsetY: 0,
          data: Uint8List.fromList([0xFF]),
        ),
      ];
      final result = CArrayExporter.export(
        symbolName: 'test_font',
        fontLabel: 'TestFont 14px 8x2',
        cellWidth: 8,
        cellHeight: 2,
        bitsPerPixel: 1,
        glyphs: glyphs,
      );

      expect(result.source, contains('test_font_data[]'));
      expect(result.source, contains('0xaa'));
      expect(result.source, contains('0x0041'));
      expect(result.source, contains('{ 0x0041, 8, 2, 8, 0, 0, 0, 2 }'));
      expect(result.source, contains('{ 0x0042, 8, 2, 8, 0, 0, 2, 1 }'));
      expect(result.source, contains('test_font_glyph_count = 2'));
      expect(result.header, contains('typedef struct'));
      expect(result.header, contains('extern const font_glyph_t test_font_glyphs[]'));
    });
  });

  group('BinaryExporter', () {
    test('round-trips header and glyph table', () {
      final glyphs = [
        PackedGlyph(
          codePoint: 0x41,
          width: 8,
          height: 16,
          advance: 8,
          offsetX: 0,
          offsetY: 0,
          data: Uint8List.fromList(List.filled(16, 0xAB)),
        ),
        PackedGlyph(
          codePoint: 0x4E2D,
          width: 8,
          height: 16,
          advance: 8,
          offsetX: 0,
          offsetY: 0,
          data: Uint8List.fromList(List.filled(16, 0xCD)),
        ),
      ];
      final bin = BinaryExporter.export(
        cellWidth: 8,
        cellHeight: 16,
        bitsPerPixel: 1,
        columnMajor: false,
        glyphs: glyphs,
      );

      final bd = ByteData.sublistView(bin);
      // Magic "DFNT"
      expect(bin.sublist(0, 4), [0x44, 0x46, 0x4E, 0x54]);
      expect(bd.getUint16(4, Endian.little), 1); // version
      expect(bd.getUint8(6), 8); // cellW
      expect(bd.getUint8(7), 16); // cellH
      expect(bd.getUint8(8), 1); // bpp
      expect(bd.getUint8(9), 0); // row-major
      expect(bd.getUint32(10, Endian.little), 2); // count

      // First glyph entry
      int p = 16;
      expect(bd.getUint32(p, Endian.little), 0x41);
      expect(bd.getUint8(p + 4), 8);
      expect(bd.getUint8(p + 5), 16);
      expect(bd.getUint8(p + 6), 8);
      final dataOffset0 = bd.getUint32(p + 10, Endian.little);
      final dataSize0 = bd.getUint16(p + 14, Endian.little);
      expect(dataSize0, 16);

      // Second glyph entry
      p += 16;
      expect(bd.getUint32(p, Endian.little), 0x4E2D);
      final dataOffset1 = bd.getUint32(p + 10, Endian.little);
      expect(dataOffset1, dataOffset0 + 16);

      // Bitmap blob
      expect(bin[dataOffset0], 0xAB);
      expect(bin[dataOffset1], 0xCD);
      expect(bin.length, 16 + 16 * 2 + 32);
    });
  });

  group('isMonospaceFontFile', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('font_info_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    Uint8List makeSimpleFont({required bool isFixedPitch, bool includePost = true}) {
      final builder = BytesBuilder();
      // sfnt header
      builder.add([
        0x00, 0x01, 0x00, 0x00, // version 1.0
        0x00, includePost ? 0x01 : 0x00, // numTables
        0x00, 0x10, // searchRange
        0x00, 0x00, // entrySelector
        0x00, 0x00, // rangeShift
      ]);
      final headerEnd = builder.length;
      final directorySize = includePost ? 16 : 0;
      final tableOffset = headerEnd + directorySize;
      if (includePost) {
        // post table directory entry
        builder.add([
          // tag 'post'
          0x70, 0x6F, 0x73, 0x74,
          // checksum (ignored by implementation)
          0x00, 0x00, 0x00, 0x00,
          // offset
          (tableOffset >> 24) & 0xFF, (tableOffset >> 16) & 0xFF,
          (tableOffset >> 8) & 0xFF, tableOffset & 0xFF,
          // length
          0x00, 0x00, 0x00, 0x20,
        ]);
      }
      if (includePost) {
        builder.add([
          // format 3.0
          0x00, 0x03, 0x00, 0x00,
          // italicAngle
          0x00, 0x00, 0x00, 0x00,
          // underlinePosition, underlineThickness
          0x00, 0x00, 0x00, 0x00,
          // isFixedPitch
          if (isFixedPitch) ...[0x00, 0x00, 0x00, 0x01] else ...[0x00, 0x00, 0x00, 0x00],
          // memory sizes (4 dwords)
          0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00,
        ]);
      }
      return Uint8List.fromList(builder.toBytes());
    }

    test('returns true when post.isFixedPitch is 1', () async {
      final path = p.join(tempDir.path, 'mono.ttf');
      File(path).writeAsBytesSync(makeSimpleFont(isFixedPitch: true));
      expect(await isMonospaceFontFile(path), isTrue);
    });

    test('returns false when post.isFixedPitch is 0', () async {
      final path = p.join(tempDir.path, 'prop.ttf');
      File(path).writeAsBytesSync(makeSimpleFont(isFixedPitch: false));
      expect(await isMonospaceFontFile(path), isFalse);
    });

    test('returns false when post table is missing', () async {
      final path = p.join(tempDir.path, 'no_post.ttf');
      File(path).writeAsBytesSync(makeSimpleFont(isFixedPitch: true, includePost: false));
      expect(await isMonospaceFontFile(path), isFalse);
    });
  });
}
