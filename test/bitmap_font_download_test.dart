import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/bitmap_font_catalog.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/font_downloader.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/font_info.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/glyph_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('matchAssetName', () {
    // 2026-07-29 从 GitHub Release 页面核实的真实资产名样本。
    const arkAssets = [
      'ark-pixel-font-16px-monospaced-bdf-v2026.07.20.zip',
      'ark-pixel-font-16px-monospaced-ms.bitmap.ttf-v2026.07.20.zip',
      'ark-pixel-font-16px-monospaced-otb-v2026.07.20.zip',
      'ark-pixel-font-16px-monospaced-otf-v2026.07.20.zip',
      'ark-pixel-font-16px-monospaced-ttf.woff-v2026.07.20.zip',
      'ark-pixel-font-16px-monospaced-ttf.woff2-v2026.07.20.zip',
      'ark-pixel-font-16px-monospaced-ttf-v2026.07.20.zip',
      'ark-pixel-font-16px-proportional-ttf-v2026.07.20.zip',
      'ark-pixel-font-12px-monospaced-ttf-v2026.07.20.zip',
    ];

    test('方舟像素 16px 命中等宽 ttf zip', () {
      final entry =
          kBitmapFontCatalog.firstWhere((e) => e.id == 'ark-pixel-16px');
      expect(
        matchAssetName(arkAssets, entry.assetPattern),
        'ark-pixel-font-16px-monospaced-ttf-v2026.07.20.zip',
      );
    });

    test('缝合像素 12px 命中等宽 ttf zip', () {
      const fusionAssets = [
        'fusion-pixel-font-12px-monospaced-bdf-v2026.07.20.zip',
        'fusion-pixel-font-12px-monospaced-otf-v2026.07.20.zip',
        'fusion-pixel-font-12px-monospaced-ttf.woff2-v2026.07.20.zip',
        'fusion-pixel-font-12px-monospaced-ttf-v2026.07.20.zip',
        'fusion-pixel-font-12px-proportional-ttf-v2026.07.20.zip',
        'fusion-pixel-font-10px-monospaced-ttf-v2026.07.20.zip',
      ];
      final entry =
          kBitmapFontCatalog.firstWhere((e) => e.id == 'fusion-pixel-12px');
      expect(
        matchAssetName(fusionAssets, entry.assetPattern),
        'fusion-pixel-font-12px-monospaced-ttf-v2026.07.20.zip',
      );
    });

    test('Zpix 命中 zpix.ttf，排除 zpix.bdf', () {
      final entry = kBitmapFontCatalog.firstWhere((e) => e.id == 'zpix-12px');
      expect(
        matchAssetName(['zpix.bdf', 'zpix.ttf'], entry.assetPattern),
        'zpix.ttf',
      );
      expect(matchAssetName(['zpix.bdf'], entry.assetPattern), isNull);
    });

    test('无匹配返回 null', () {
      expect(matchAssetName(['foo.zip', 'bar.ttf'], r'^nomatch'), isNull);
    });
  });

  group('fileNameFromUrl', () {
    test('普通 URL', () {
      expect(fileNameFromUrl('https://example.com/fonts/zpix.ttf'), 'zpix.ttf');
    });

    test('带 query 的 URL', () {
      expect(
        fileNameFromUrl('https://example.com/a/font.otf?raw=true&v=2'),
        'font.otf',
      );
    });

    test('无扩展名回退 download.ttf', () {
      expect(fileNameFromUrl('https://example.com/download'), 'download.ttf');
      expect(fileNameFromUrl('https://example.com/'), 'download.ttf');
      expect(fileNameFromUrl('not a url'), 'download.ttf');
    });
  });

  group('extractFirstFontFromZip', () {
    List<int> buildZip(Map<String, String> files) {
      final archive = Archive();
      for (final e in files.entries) {
        archive.addFile(
            ArchiveFile(e.key, e.value.length, utf8.encode(e.value)));
      }
      return ZipEncoder().encode(archive)!;
    }

    test('选中第一个 ttf/otf 文件', () {
      final zip = buildZip({
        'readme.txt': 'hello',
        'font-a.otf': 'OTF-CONTENT',
        'font-b.ttf': 'TTF-CONTENT',
      });
      final result = extractFirstFontFromZip(zip);
      expect(result, isNotNull);
      expect(utf8.decode(result!), 'OTF-CONTENT');
    });

    test('无字体文件返回 null', () {
      final zip = buildZip({'readme.txt': 'hello', 'data.json': '{}'});
      expect(extractFirstFontFromZip(zip), isNull);
    });
  });

  group('readEmbeddedBitmapSizes', () {
    test('无内嵌点阵的字体返回空列表且不抛异常', () async {
      // VonwaonBitmap 是纯矢量 TTF，无 EBLC/EBDT 表。
      final sizes =
          await readEmbeddedBitmapSizes('Font/VonwaonBitmap-16px.ttf');
      expect(sizes, isEmpty);
    });

    test('不存在的文件返回空列表且不抛异常', () async {
      expect(await readEmbeddedBitmapSizes('no/such/font.ttf'), isEmpty);
    });
  });

  group('detectPixelFontDesignSizes', () {
    test('名称含 Npx 的字体返回对应尺寸', () async {
      expect(await detectPixelFontDesignSizes('Font/ark-pixel-16px.ttf'),
          [16]);
      expect(await detectPixelFontDesignSizes('Font/fusion-pixel-12px.ttf'),
          [12]);
      expect(await detectPixelFontDesignSizes('Font/VonwaonBitmap-16px.ttf'),
          [16]);
    });

    test('名称无尺寸提示的字体返回空列表（未知）', () async {
      // zpix 文件名与字体名都不含 "Npx"，设计尺寸无法推断。
      expect(await detectPixelFontDesignSizes('Font/zpix.ttf'), isEmpty);
    });

    test('不存在的文件返回空列表且不抛异常', () async {
      expect(await detectPixelFontDesignSizes('no/such/font.ttf'), isEmpty);
    });
  });

  group('pixelSnap', () {
    int grayOf(List<int> px) =>
        px.where((v) => v != 0 && v != 255).length;

    // 半角 'A' 在 VonwaonBitmap-16px 中宽 8px；单元格宽 15 时居中偏移
    // dx = (15 - 8) / 2 = 3.5 为分数像素，可检验 snap 是否生效。
    test('分数偏移：snap=true 无灰像素，snap=false 产生灰边', () async {
      final renderer = GlyphRenderer();
      await renderer.addFontFile('Font/VonwaonBitmap-16px.ttf');

      final snapped = await renderer.renderGrapheme('A',
          fontSize: 16,
          cellWidth: 15,
          cellHeight: 16,
          verticalOffset: 0,
          pixelSnap: true);
      expect(snapped.isMissing, isFalse);
      expect(grayOf(snapped.pixels), 0);

      final smooth = await renderer.renderGrapheme('A',
          fontSize: 16,
          cellWidth: 15,
          cellHeight: 16,
          verticalOffset: 0,
          pixelSnap: false);
      expect(smooth.isMissing, isFalse);
      expect(grayOf(smooth.pixels), greaterThan(0));
    });

    test('整数偏移：snap 开关不影响输出', () async {
      final renderer = GlyphRenderer();
      await renderer.addFontFile('Font/VonwaonBitmap-16px.ttf');

      final snapped = await renderer.renderGrapheme('A',
          fontSize: 16,
          cellWidth: 16,
          cellHeight: 16,
          pixelSnap: true);
      final smooth = await renderer.renderGrapheme('A',
          fontSize: 16,
          cellWidth: 16,
          cellHeight: 16,
          pixelSnap: false);
      expect(grayOf(snapped.pixels), 0);
      expect(grayOf(smooth.pixels), 0);
    });
  });
}
