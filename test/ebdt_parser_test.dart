import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/ebdt_parser.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/glyph_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const msgothic = r'C:\Windows\Fonts\msgothic.ttc';
  const simsun = r'C:\Windows\Fonts\simsun.ttc';

  bool binaryOnly(List<int> px) => px.every((v) => v == 0 || v == 255);

  int inkWidth(List<int> px, int w, int h) {
    var x0 = w, x1 = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (px[y * w + x] == 255) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
        }
      }
    }
    return x1 < 0 ? 0 : x1 - x0 + 1;
  }

  group('EmbeddedBitmapParser (MS Gothic, indexFormat 5)', () {
    test('CJK and half-width glyphs hit the 16px strike', () async {
      if (!File(msgothic).existsSync()) return;
      for (final cp in [0x4E2D, 0x3042, 0x6587, 0x6F22, 0x0041]) {
        final px = await EmbeddedBitmapParser.readNativeBitmap(
          path: msgothic,
          codePoint: cp,
          targetSize: 16,
          cellWidth: 16,
          cellHeight: 16,
        );
        expect(px, isNotNull,
            reason: 'U+${cp.toRadixString(16)} should hit EBDT');
        expect(binaryOnly(px!), isTrue);
        expect(px.any((v) => v == 255), isTrue,
            reason: 'U+${cp.toRadixString(16)} should have ink');
      }
    });

    test('imageFormat 5 uses bigGlyphMetrics (half-width is 8px wide)',
        () async {
      if (!File(msgothic).existsSync()) return;
      final px = await EmbeddedBitmapParser.readNativeBitmap(
        path: msgothic,
        codePoint: 0x0041, // 'A'
        targetSize: 16,
        cellWidth: 16,
        cellHeight: 16,
      );
      expect(px, isNotNull);
      // The 'A' bitmap in the 16px strike is 8px wide; decoding it as
      // 16x16 (the old bug) would stretch it across the whole cell.
      expect(inkWidth(px!, 16, 16), lessThanOrEqualTo(9));
    });

    test('dingbats without bitmaps return null instead of garbage', () async {
      if (!File(msgothic).existsSync()) return;
      // MS Gothic has vector outlines but no EBDT bitmaps for the Dingbats
      // block. A mis-parsed format-5 header used to produce phantom glyph
      // array entries here, returning garbage noise bitmaps.
      for (final cp in [0x2700, 0x2713, 0x2717, 0x27BF]) {
        final px = await EmbeddedBitmapParser.readNativeBitmap(
          path: msgothic,
          codePoint: cp,
          targetSize: 16,
          cellWidth: 16,
          cellHeight: 16,
        );
        expect(px, isNull,
            reason: 'U+${cp.toRadixString(16)} has no strike bitmap');
      }
    });

    test('dingbats still render via vector fallback in the pipeline',
        () async {
      if (!File(msgothic).existsSync()) return;
      final r = GlyphRenderer();
      await r.addFontFile(msgothic);
      final g = await r.renderGrapheme('✓',
          fontSize: 16, cellWidth: 16, cellHeight: 16);
      expect(g.isMissing, isFalse);
      expect(g.pixels.any((v) => v >= 128), isTrue,
          reason: '✓ should have ink from the vector fallback');
    });
  });

  group('EmbeddedBitmapParser (SimSun regression)', () {
    test('common glyphs still hit at 12/16px', () async {
      if (!File(simsun).existsSync()) return;
      for (final size in [12, 16]) {
        final px = await EmbeddedBitmapParser.readNativeBitmap(
          path: simsun,
          codePoint: 0x4E2D,
          targetSize: size,
          cellWidth: size,
          cellHeight: size,
        );
        expect(px, isNotNull, reason: 'SimSun 中 @${size}px should hit');
        expect(binaryOnly(px!), isTrue);
      }
    });
  });
}
