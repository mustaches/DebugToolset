import 'dart:typed_data';

import 'package:debug_tool_set/modules/font_extractor/utils/binary_exporter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/bitmap_converter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/c_array_exporter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/c_array_parser.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/dfnt_font.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/packed_glyph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('unpackBitmap', () {
    // Deterministic 10x12 grayscale pattern.
    List<int> pattern() =>
        List.generate(10 * 12, (i) => (i * 37 + 11) % 256);

    test('round-trips 8bpp row-major', () {
      final pixels = pattern();
      final packed = packBitmap(
        pixels: pixels,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.eight,
        scan: BitmapScanMode.rowMajor,
      );
      final unpacked = unpackBitmap(
        bytes: packed,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.eight,
        scan: BitmapScanMode.rowMajor,
      );
      expect(unpacked, pixels);
    });

    test('round-trips 8bpp column-major', () {
      final pixels = pattern();
      final packed = packBitmap(
        pixels: pixels,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.eight,
        scan: BitmapScanMode.columnMajor,
      );
      final unpacked = unpackBitmap(
        bytes: packed,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.eight,
        scan: BitmapScanMode.columnMajor,
      );
      expect(unpacked, pixels);
    });

    test('round-trips 1bpp row-major (binarized)', () {
      final pixels = pattern();
      final packed = packBitmap(
        pixels: pixels,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.rowMajor,
        threshold: 128,
      );
      final unpacked = unpackBitmap(
        bytes: packed,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.rowMajor,
      );
      expect(
        unpacked,
        pixels.map((v) => v >= 128 ? 255 : 0).toList(),
      );
    });

    test('round-trips 1bpp column-major (binarized, partial page)', () {
      final pixels = pattern(); // height 12 -> 2 pages, second partial
      final packed = packBitmap(
        pixels: pixels,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.columnMajor,
        threshold: 128,
      );
      final unpacked = unpackBitmap(
        bytes: packed,
        width: 10,
        height: 12,
        depth: BitmapBitDepth.one,
        scan: BitmapScanMode.columnMajor,
      );
      expect(
        unpacked,
        pixels.map((v) => v >= 128 ? 255 : 0).toList(),
      );
    });

    test('throws FormatException when data is too short', () {
      expect(
        () => unpackBitmap(
          bytes: Uint8List(2),
          width: 10,
          height: 12,
          depth: BitmapBitDepth.one,
          scan: BitmapScanMode.rowMajor,
        ),
        throwsFormatException,
      );
    });
  });

  group('DfntFont.parse', () {
    Uint8List buildFont({bool columnMajor = false, int bitsPerPixel = 1}) {
      final a = PackedGlyph(
        codePoint: 0x41,
        width: 8,
        height: 16,
        advance: 8,
        offsetX: 0,
        offsetY: 0,
        data: Uint8List.fromList(List.generate(16, (i) => 0x80 >> (i % 8))),
      );
      final zh = PackedGlyph(
        codePoint: 0x4F60,
        width: 8,
        height: 16,
        advance: 8,
        offsetX: 0,
        offsetY: 0,
        data: Uint8List.fromList(List.generate(16, (i) => i)),
      );
      return BinaryExporter.export(
        cellWidth: 8,
        cellHeight: 16,
        bitsPerPixel: bitsPerPixel,
        columnMajor: columnMajor,
        glyphs: [a, zh],
      );
    }

    test('round-trips header and glyph table', () {
      final bin = buildFont();
      final font = DfntFont.parse(bin);

      expect(font.cellWidth, 8);
      expect(font.cellHeight, 16);
      expect(font.bitsPerPixel, 1);
      expect(font.columnMajor, isFalse);
      expect(font.glyphCount, 2);

      final a = font.glyphFor('A')!;
      expect(a.codePoint, 0x41);
      expect(a.width, 8);
      expect(a.height, 16);
      expect(a.advance, 8);
      expect(a.data, List.generate(16, (i) => 0x80 >> (i % 8)));

      expect(font.glyphFor('你')!.codePoint, 0x4F60);
      expect(font.glyphFor('B'), isNull);
    });

    test('parses column-major 8bpp header flags', () {
      final font = DfntFont.parse(
          buildFont(columnMajor: true, bitsPerPixel: 8));
      expect(font.columnMajor, isTrue);
      expect(font.bitsPerPixel, 8);
    });

    test('rejects non-DFNT data', () {
      expect(() => DfntFont.parse(Uint8List(4)), throwsFormatException);
      expect(
        () => DfntFont.parse(Uint8List.fromList('NOPE........'.codeUnits)),
        throwsFormatException,
      );
    });

    test('rejects truncated glyph table', () {
      final bin = buildFont();
      expect(
        () => DfntFont.parse(Uint8List.sublistView(bin, 0, 20)),
        throwsFormatException,
      );
    });
  });

  group('CArrayFontParser', () {
    final glyphs = [
      PackedGlyph(
        codePoint: 0x41,
        width: 8,
        height: 16,
        advance: 8,
        offsetX: 0,
        offsetY: 0,
        data: Uint8List.fromList(List.generate(16, (i) => 0x80 >> (i % 8))),
      ),
      PackedGlyph(
        codePoint: 0x4F60,
        width: 8,
        height: 16,
        advance: 8,
        offsetX: 0,
        offsetY: 0,
        data: Uint8List.fromList(List.generate(16, (i) => i)),
      ),
    ];

    test('round-trips CArrayExporter output', () {
      final result = CArrayExporter.export(
        symbolName: 'test_font',
        fontLabel: 'TestFont 14px 8x16',
        cellWidth: 8,
        cellHeight: 16,
        bitsPerPixel: 1,
        columnMajor: true,
        glyphs: glyphs,
      );
      final font = CArrayFontParser.parse(result.source);

      expect(font.cellWidth, 8);
      expect(font.cellHeight, 16);
      expect(font.bitsPerPixel, 1);
      expect(font.columnMajor, isTrue);
      expect(font.glyphCount, 2);
      expect(font.glyphFor('A')!.data,
          List.generate(16, (i) => 0x80 >> (i % 8)));
      expect(font.glyphFor('你')!.data, List.generate(16, (i) => i));
      expect(font.glyphFor('B'), isNull);
    });

    test('defaults to row-major for files without Scan metadata', () {
      final result = CArrayExporter.export(
        symbolName: 'test_font',
        fontLabel: 'TestFont 14px 8x16',
        cellWidth: 8,
        cellHeight: 16,
        bitsPerPixel: 8,
        glyphs: glyphs,
      );
      // Simulate a file generated before the Scan field existed.
      final source = result.source.replaceFirst(', Scan: row', '');
      final font = CArrayFontParser.parse(source);

      expect(font.columnMajor, isFalse);
      expect(font.bitsPerPixel, 8);
    });

    test('rejects sources without a data array or glyph table', () {
      expect(() => CArrayFontParser.parse('void main() {}'),
          throwsFormatException);
      expect(
        () => CArrayFontParser.parse(
            'static const uint8_t x_data[] = { 0x01, 0x02 };'),
        throwsFormatException,
      );
    });
  });
}
