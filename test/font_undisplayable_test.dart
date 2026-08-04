import 'dart:typed_data';

import 'package:debug_tool_set/modules/font_extractor/utils/binary_exporter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/bitmap_converter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/c_array_exporter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/dfnt_font.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/glyph_renderer.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/packed_glyph.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/unicode_assigned.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isUndisplayableCodePoint', () {
    test('table is sorted, merged and within range', () {
      for (int i = 0; i < kUndisplayableRanges.length; i++) {
        final r = kUndisplayableRanges[i];
        expect(r.$1 <= r.$2, isTrue, reason: 'range $i inverted');
        expect(r.$1 >= 0 && r.$2 <= 0x10FFFF, isTrue);
        if (i > 0) {
          expect(r.$1 > kUndisplayableRanges[i - 1].$2 + 1, isTrue,
              reason: 'range $i not merged/sorted');
        }
      }
    });

    test('unassigned code points are undisplayable', () {
      expect(isUndisplayableCodePoint(0x0378), isTrue);
      expect(isUndisplayableCodePoint(0x0379), isTrue);
      expect(isUndisplayableCodePoint(0x10FFFF), isTrue);
    });

    test('noncharacters and surrogates are undisplayable', () {
      expect(isUndisplayableCodePoint(0xFDD0), isTrue);
      expect(isUndisplayableCodePoint(0xFDEF), isTrue);
      expect(isUndisplayableCodePoint(0xFFFE), isTrue);
      expect(isUndisplayableCodePoint(0xFFFF), isTrue);
      expect(isUndisplayableCodePoint(0xD800), isTrue);
      expect(isUndisplayableCodePoint(0xDFFF), isTrue);
    });

    test('control and format characters are undisplayable', () {
      expect(isUndisplayableCodePoint(0x0000), isTrue);
      expect(isUndisplayableCodePoint(0x0009), isTrue); // tab
      expect(isUndisplayableCodePoint(0x001F), isTrue);
      expect(isUndisplayableCodePoint(0x007F), isTrue);
      expect(isUndisplayableCodePoint(0x00AD), isTrue); // soft hyphen (Cf)
      expect(isUndisplayableCodePoint(0x200B), isTrue); // ZWSP (Cf)
      expect(isUndisplayableCodePoint(0xFEFF), isTrue); // BOM (Cf)
    });

    test('assigned displayable code points are kept', () {
      expect(isUndisplayableCodePoint(0x0020), isFalse); // space
      expect(isUndisplayableCodePoint(0x0041), isFalse); // A
      expect(isUndisplayableCodePoint(0x0860), isFalse); // Syriac suppl. (v14+)
      expect(isUndisplayableCodePoint(0x4E2D), isFalse); // 中
      expect(isUndisplayableCodePoint(0x1F600), isFalse); // emoji
      expect(isUndisplayableCodePoint(0xE000), isFalse); // PUA (assigned)
    });

    test('out-of-range code points are undisplayable', () {
      expect(isUndisplayableCodePoint(-1), isTrue);
      expect(isUndisplayableCodePoint(0x110000), isTrue);
    });
  });

  group('GlyphRenderer undisplayable handling', () {
    test('Unifont hex-box glyphs become blank missing glyphs', () async {
      final renderer = GlyphRenderer();
      await renderer.addFontFile('Font/unifont13.0.06/unifont-13.0.06.ttf');

      // U+0378 is unassigned: Unifont draws a box filled with the hex
      // value "0378". It must not be exported as a real glyph.
      final fake = await renderer.renderGrapheme(
        String.fromCharCode(0x0378),
        fontSize: 16,
        cellWidth: null,
        cellHeight: 16,
      );
      expect(fake.isMissing, isTrue);
      expect(fake.pixels.every((v) => v == 0), isTrue);

      // Noncharacters drawn as hex boxes are blanked too.
      final nonchar = await renderer.renderGrapheme(
        String.fromCharCode(0xFDD0),
        fontSize: 16,
        cellWidth: null,
        cellHeight: 16,
      );
      expect(nonchar.isMissing, isTrue);
      expect(nonchar.pixels.every((v) => v == 0), isTrue);

      // Control characters drawn as hex boxes are blanked too.
      final control = await renderer.renderGrapheme(
        String.fromCharCode(0x0001),
        fontSize: 16,
        cellWidth: 8,
        cellHeight: 16,
      );
      expect(control.isMissing, isTrue);
      expect(control.pixels.every((v) => v == 0), isTrue);

      // A real glyph still renders with ink.
      final real = await renderer.renderGrapheme(
        'A',
        fontSize: 16,
        cellWidth: 8,
        cellHeight: 16,
      );
      expect(real.isMissing, isFalse);
      expect(real.pixels.any((v) => v != 0), isTrue);
    });

    test('hex boxes for code points assigned after the font was made',
        () async {
      final renderer = GlyphRenderer();
      await renderer.addFontFile('Font/unifont13.0.06/unifont-13.0.06.ttf');

      // U+20C0 (SOM SIGN) was added in Unicode 14; Unifont 13.0.06 draws
      // its unassigned-placeholder box filled with the hex value "20C0".
      for (final cellWidth in <int?>[null, 8, 16]) {
        final fake = await renderer.renderGrapheme(
          String.fromCharCode(0x20C0),
          fontSize: 16,
          cellWidth: cellWidth,
          cellHeight: 16,
        );
        expect(fake.isMissing, isTrue,
            reason: 'U+20C0 hex box must be detected (cellWidth=$cellWidth)');
        expect(fake.pixels.every((v) => v == 0), isTrue,
            reason: 'missing glyphs must carry a blank bitmap');
      }

      // Real glyphs from the same and other blocks must survive:
      // currency signs, CJK, and box-like glyphs (square, double square).
      for (final cp in [0x20B9, 0x20AC, 0x4E2D, 0x56DE, 0x25A1, 0x0041]) {
        final real = await renderer.renderGrapheme(
          String.fromCharCode(cp),
          fontSize: 16,
          cellWidth: null,
          cellHeight: 16,
        );
        expect(real.isMissing, isFalse,
            reason: 'U+${cp.toRadixString(16)} is a real glyph');
        expect(real.pixels.any((v) => v != 0), isTrue);
      }
    });

    test('hex box detection follows the bound primary family', () async {
      // Simulates multi-language binding: blocks are rendered with a bound
      // font that is NOT the first loaded family. Detection references
      // (tofu and hex-box probes) must use that same bound font.
      final renderer = GlyphRenderer();
      final family17 =
          await renderer.addFontFile('Font/unifont17.0.05/unifont-17.0.05.otf');
      final family13 =
          await renderer.addFontFile('Font/unifont13.0.06/unifont-13.0.06.ttf');

      // U+0870-U+089F (Arabic Extended-B) was added in Unicode 14: Unifont
      // 13.0.06 only draws hex-value placeholder boxes for it. Every digit
      // combination must be caught, not just ones overlapping the probes.
      for (final cp in [
        0x0870, 0x0882, 0x0885, 0x0887, 0x088A, 0x088E,
        0x0897, 0x089A, 0x089B, 0x089D, 0x089E, 0x089F,
      ]) {
        final fake = await renderer.renderGrapheme(
          String.fromCharCode(cp),
          fontSize: 16,
          cellWidth: null,
          cellHeight: 16,
          primaryFamily: family13,
        );
        expect(fake.isMissing, isTrue,
            reason: 'U+${cp.toRadixString(16)} hex box must be detected');
        expect(fake.pixels.every((v) => v == 0), isTrue);
      }

      // U+1715 (TAGALOG SIGN PAMUDPOD, a Mc mark added in Unicode 14):
      // the shaping engine prepends a dotted circle to the standalone
      // mark, so Unifont's hex box is rendered shifted to the right.
      final mark = await renderer.renderGrapheme(
        String.fromCharCode(0x1715),
        fontSize: 16,
        cellWidth: null,
        cellHeight: 16,
        primaryFamily: family13,
      );
      expect(mark.isMissing, isTrue,
          reason: 'U+1715 hex box behind a dotted circle must be detected');
      expect(mark.pixels.every((v) => v == 0), isTrue);

      // A real spacing mark and the dotted circle itself must survive.
      for (final cp in [0x1714, 0x25CC]) {
        final real = await renderer.renderGrapheme(
          String.fromCharCode(cp),
          fontSize: 16,
          cellWidth: null,
          cellHeight: 16,
          primaryFamily: family13,
        );
        expect(real.isMissing, isFalse,
            reason: 'U+${cp.toRadixString(16)} is a real glyph');
        expect(real.pixels.any((v) => v != 0), isTrue);
      }

      // U+20C0 is a placeholder box in Unifont 13 but a real glyph in
      // Unifont 17; the verdict must follow the bound font.
      final fake13 = await renderer.renderGrapheme(
        String.fromCharCode(0x20C0),
        fontSize: 16,
        cellWidth: null,
        cellHeight: 16,
        primaryFamily: family13,
      );
      expect(fake13.isMissing, isTrue);

      final real17 = await renderer.renderGrapheme(
        String.fromCharCode(0x20C0),
        fontSize: 16,
        cellWidth: null,
        cellHeight: 16,
        primaryFamily: family17,
      );
      expect(real17.isMissing, isFalse,
          reason: 'U+20C0 is a real glyph in Unifont 17');
      expect(real17.pixels.any((v) => v != 0), isTrue);
    });
  });

  group('DfntFont empty glyph data', () {
    test('parses zero-length glyph data without errors', () {
      final bin = BinaryExporter.export(
        cellWidth: 8,
        cellHeight: 16,
        bitsPerPixel: 1,
        columnMajor: false,
        glyphs: [
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
            codePoint: 0x0378,
            width: 16,
            height: 16,
            advance: 16,
            offsetX: 0,
            offsetY: 0,
            data: Uint8List(0),
          ),
        ],
      );
      final font = DfntFont.parse(bin);
      expect(font.glyphCount, 2);
      final missing = font.glyphs[0x0378]!;
      expect(missing.data, isEmpty);
      expect(missing.width, 16);
      // The grid preview renders empty-data glyphs as blank, so unpacking
      // must never be attempted for them (it would throw FormatException).
      expect(
        () => unpackBitmap(
          bytes: missing.data,
          width: missing.width,
          height: missing.height,
          depth: BitmapBitDepth.one,
          scan: BitmapScanMode.rowMajor,
        ),
        throwsFormatException,
      );
      final real = font.glyphs[0x41]!;
      expect(real.data.length, 16);
    });
  });

  group('CArrayExporter empty glyph data', () {
    test('emits a zero-length entry for missing glyphs', () {
      final result = CArrayExporter.export(
        symbolName: 'test_font',
        fontLabel: 'TestFont 16px 8x16',
        cellWidth: 8,
        cellHeight: 16,
        bitsPerPixel: 1,
        glyphs: [
          PackedGlyph(
            codePoint: 0x0378,
            width: 16,
            height: 16,
            advance: 16,
            offsetX: 0,
            offsetY: 0,
            data: Uint8List(0),
          ),
        ],
      );
      expect(result.source, contains('// U+0378 (16x16, 0B)'));
      expect(result.source, contains('{ 0x0378, 16, 16, 16, 0, 0, 0, 0 }'));
      expect(result.source, contains('test_font_glyph_count = 1'));
    });
  });
}
