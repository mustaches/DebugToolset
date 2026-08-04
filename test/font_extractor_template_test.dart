import 'dart:convert';

import 'package:debug_tool_set/modules/font_extractor/utils/bitmap_converter.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/unicode_blocks.dart';
import 'package:debug_tool_set/providers/font_extractor_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FontExtractorState template', () {
    test('export/apply round-trips the full configuration', () async {
      final a = FontExtractorState();
      a.setFontSize(24);
      a.setCellSize(12, 24);
      a.setVerticalOffset(-2.5);
      a.setBitDepth(BitmapBitDepth.eight);
      a.setScanMode(BitmapScanMode.columnMajor);
      a.setThreshold(100);
      a.setShowCellGrid(true);
      a.toggleBlock(0, true);
      a.toggleBlock(4, true);
      a.setCustomRangeInput('0x20-0x7E');
      a.setAutoRefreshPreview(true);

      // Survive an actual JSON encode/decode cycle.
      final json =
          jsonDecode(jsonEncode(a.exportTemplate())) as Map<String, dynamic>;

      final b = FontExtractorState();
      final missing = await b.applyTemplate(json);

      expect(missing, isEmpty);
      expect(b.fontPaths, isEmpty);
      expect(b.fontSize, a.fontSize);
      expect(b.cellWidth, a.cellWidth);
      expect(b.cellHeight, a.cellHeight);
      expect(b.verticalOffset, a.verticalOffset);
      expect(b.bitDepth, a.bitDepth);
      expect(b.scanMode, a.scanMode);
      expect(b.threshold, a.threshold);
      expect(b.showCellGrid, a.showCellGrid);
      expect(b.selectedBlockIndexes, a.selectedBlockIndexes);
      expect(b.customRangeInput, a.customRangeInput);
      expect(b.importedText, a.importedText);
      expect(b.autoRefreshPreview, a.autoRefreshPreview);
    });

    test('applyTemplate reports font files that no longer exist', () async {
      final state = FontExtractorState();
      final missing = await state.applyTemplate({
        'fontPaths': ['C:/nonexistent/font_a.ttf', 'C:/nonexistent/font_b.otf'],
      });

      expect(missing,
          ['C:/nonexistent/font_a.ttf', 'C:/nonexistent/font_b.otf']);
      expect(state.fontPaths, isEmpty);
    });

    test('applyTemplate throws FormatException on invalid template', () {
      final state = FontExtractorState();
      expect(() => state.applyTemplate({}), throwsFormatException);
      expect(() => state.applyTemplate({'fontPaths': 'not-a-list'}),
          throwsFormatException);
    });

    test('applyTemplate filters out-of-range block indexes', () async {
      final state = FontExtractorState();
      await state.applyTemplate({
        'fontPaths': <String>[],
        'selectedBlockIndexes': [0, 3, 999, -1],
      });

      expect(state.selectedBlockIndexes, {0, 3});
    });

    test('applyTemplate falls back to defaults for missing fields', () async {
      final state = FontExtractorState();
      state.setFontSize(48);
      state.setThreshold(42);

      await state.applyTemplate({'fontPaths': <String>[]});

      expect(state.fontSize, 14);
      expect(state.cellWidth, 8);
      expect(state.cellHeight, 16);
      expect(state.bitDepth, BitmapBitDepth.one);
      expect(state.scanMode, BitmapScanMode.rowMajor);
      expect(state.threshold, 128);
      expect(state.selectedBlockIndexes, isEmpty);
    });
  });

  group('suggestedBaseName', () {
    test('follows 字体名_格宽x格高', () {
      final state = FontExtractorState();
      expect(state.suggestedBaseName, 'font_8x16');

      state.setCellSize(12, 24);
      expect(state.suggestedBaseName, 'font_12x24');
    });
  });

  group('multiLang binding order', () {
    test('earlier bound languages appear at the top of langBindings list', () async {
      final state = FontExtractorState();
      state.setExtractMode(FontExtractMode.multiLang);

      const testFont = 'Font/unifont13.0.06/unifont-13.0.06.ttf';

      // Bind ja_jp first
      await state.bindLangFont('ja_jp', testFont);
      expect(state.langBindings.first.id, 'ja_jp');
      expect(state.langBindings.first.boundOrder, 1);

      // Bind zh_cn second
      await state.bindLangFont('zh_cn', testFont);
      expect(state.langBindings[0].id, 'ja_jp');
      expect(state.langBindings[1].id, 'zh_cn');
      expect(state.langBindings[1].boundOrder, 2);

      // Unbind ja_jp
      state.unbindLangFont('ja_jp');
      expect(state.langBindings.first.id, 'zh_cn');
    });
  });

  group('selectBlocksForFilter in fallback mode', () {
    test('auto-selects Unicode blocks based on continent/region/country/script selection', () {
      final state = FontExtractorState();
      state.setExtractMode(FontExtractMode.fallback);

      // Select Japan in picker
      state.selectBlocksForFilter(
        continent: '亚洲',
        region: '东亚',
        country: '日本',
      );

      expect(state.selectedBlockIndexes, isNotEmpty);
      expect(state.hasFullWidthActive, isTrue);

      // Select Russia in picker
      state.selectBlocksForFilter(
        continent: '欧洲',
        region: '东欧',
        country: '俄罗斯',
      );

      expect(state.selectedBlockIndexes, isNotEmpty);
    });
  });

  group('kUnicodeBlocks ordering', () {
    test('is sorted in strict linear ascending order of start code point', () {
      for (int i = 1; i < kUnicodeBlocks.length; i++) {
        final prev = kUnicodeBlocks[i - 1];
        final curr = kUnicodeBlocks[i];
        expect(curr.start, greaterThanOrEqualTo(prev.start),
            reason: '${curr.name} (0x${curr.start.toRadixString(16)}) should be >= ${prev.name} (0x${prev.start.toRadixString(16)})');
      }
    });
  });

  group('20-bit Unicode code point support', () {
    test('formatCodePoint correctly handles 16-bit BMP and 20-bit Plane 1-16 code points', () {
      expect(formatCodePoint(0x0041), 'U+0041');
      expect(formatCodePoint(0x4E00), 'U+4E00');
      expect(formatCodePoint(0x1B170), 'U+1B170');
      expect(formatCodePoint(0x20000), 'U+20000');
      expect(formatCodePoint(0x30000), 'U+30000');
      expect(formatCodePoint(0x10FFFF), 'U+10FFFF');
    });

    test('kUnicodeBlocks contains blocks across all Unicode Planes 0 to 16', () {
      expect(kUnicodeBlocks.any((b) => b.start == 0x0000), isTrue); // Plane 0 BMP
      expect(kUnicodeBlocks.any((b) => b.start == 0x1B170), isTrue); // Plane 1 SMP Nushu
      expect(kUnicodeBlocks.any((b) => b.start == 0x20000), isTrue); // Plane 2 SIP CJK Ext B
      expect(kUnicodeBlocks.any((b) => b.start == 0x30000), isTrue); // Plane 3 TIP CJK Ext G
      expect(kUnicodeBlocks.any((b) => b.start == 0xE0000), isTrue); // Plane 14 SSP Tags
      expect(kUnicodeBlocks.any((b) => b.start == 0xF0000), isTrue); // Plane 15 PUA-A
      expect(kUnicodeBlocks.any((b) => b.start == 0x100000), isTrue); // Plane 16 PUA-B
    });

    test('auto-selects all blocks present in font cmap when all filters are 全部', () async {
      final state = FontExtractorState();
      state.setExtractMode(FontExtractMode.fallback);

      const unifontPath = 'Font/unifont13.0.06/unifont-13.0.06.ttf';

      await state.selectBlocksForFilter(
        continent: '全部',
        region: '全部',
        country: '全部',
        fontPath: unifontPath,
      );

      expect(state.selectedBlockIndexes, isNotEmpty);
      expect(state.selectedBlockIndexes.contains(0), isTrue);
    });
  });
}
