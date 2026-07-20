import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/font_coverage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('coverageOf', () {
    test('empty cmap covers nothing', () {
      expect(coverageOf(const [], 0x20, 0x7E), 0);
    });

    test('full containment', () {
      const cmap = [(start: 0x0000, end: 0x00FF)];
      expect(coverageOf(cmap, 0x20, 0x7E), 1.0);
    });

    test('no overlap', () {
      const cmap = [(start: 0x4E00, end: 0x9FFF)];
      expect(coverageOf(cmap, 0x20, 0x7E), 0);
    });

    test('partial overlap at range edges', () {
      const cmap = [(start: 0x0041, end: 0x005A)]; // A-Z
      // Query 0x20-0x60: covered part is 0x41-0x5A = 26 of 65 code points.
      expect(coverageOf(cmap, 0x20, 0x60), closeTo(26 / 65, 1e-9));
    });

    test('sums across multiple cmap segments', () {
      const cmap = [(start: 0x30, end: 0x39), (start: 0x41, end: 0x5A)];
      // Query 0x30-0x5A: 10 digits + 26 letters = 36 of 43.
      expect(coverageOf(cmap, 0x30, 0x5A), closeTo(36 / 43, 1e-9));
    });

    test('single code point query', () {
      const cmap = [(start: 0x41, end: 0x41)];
      expect(coverageOf(cmap, 0x41, 0x41), 1.0);
      expect(coverageOf(cmap, 0x42, 0x42), 0);
    });
  });

  group('coverageOfRanges', () {
    test('weights ranges by their length', () {
      const cmap = [(start: 0x0000, end: 0x0009)]; // 10 code points
      const query = [
        (start: 0x0000, end: 0x0009), // fully covered, 10
        (start: 0x0010, end: 0x0019), // not covered, 10
      ];
      expect(coverageOfRanges(cmap, query), 0.5);
    });

    test('empty query is zero', () {
      expect(coverageOfRanges(const [(start: 0, end: 0x10FFFF)], const []), 0);
    });
  });

  group('readFontCmap', () {
    test('returns null for a non-font file', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/not_a_font_${DateTime.now().microsecondsSinceEpoch}.bin');
      await tmp.writeAsBytes([1, 2, 3, 4, 5, 6, 7, 8]);
      addTearDown(() => tmp.existsSync() ? tmp.deleteSync() : null);
      expect(await readFontCmap(tmp.path), isNull);
    });

    test('msyh.ttc covers CJK but not Thai', () async {
      final font = File(r'C:\Windows\Fonts\msyh.ttc');
      if (!font.existsSync()) {
        // ignore: avoid_print
        print('msyh.ttc not found, skipping');
        return;
      }
      final cmap = await readFontCmap(font.path);
      expect(cmap, isNotNull);
      // CJK Unified Ideographs.
      expect(coverageOf(cmap!, 0x4E00, 0x9FFF), greaterThan(0.9));
      // Basic Latin should be fully covered.
      expect(coverageOf(cmap, 0x20, 0x7E), 1.0);
      // Thai should be (essentially) absent.
      expect(coverageOf(cmap, 0x0E00, 0x0E7F), lessThan(0.05));
    });

    test('arial.ttf covers Latin and Cyrillic but not CJK', () async {
      final font = File(r'C:\Windows\Fonts\arial.ttf');
      if (!font.existsSync()) {
        // ignore: avoid_print
        print('arial.ttf not found, skipping');
        return;
      }
      final cmap = await readFontCmap(font.path);
      expect(cmap, isNotNull);
      expect(coverageOf(cmap!, 0x20, 0x7E), 1.0);
      expect(coverageOf(cmap, 0x0400, 0x04FF), greaterThan(0.9));
      expect(coverageOf(cmap, 0x4E00, 0x9FFF), lessThan(0.01));
    });
  });
}
