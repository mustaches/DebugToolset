import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/glyph_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

String _dump(List<int> px, int w, int h) {
  final sb = StringBuffer();
  int gray = 0, on = 0;
  for (final v in px) {
    if (v != 0 && v != 255) gray++;
    if (v >= 128) on++;
  }
  sb.writeln('non-binary(gray) pixels: $gray, on(>=128): $on');
  for (int y = 0; y < h; y++) {
    final row = StringBuffer();
    for (int x = 0; x < w; x++) {
      final v = px[y * w + x];
      row.write(v == 0
          ? ' .  '
          : v == 255
              ? ' ## '
              : ' ${v.toRadixString(16).padLeft(2, '0')} ');
    }
    sb.writeln(row);
  }
  return sb.toString();
}

void main() {
  test('dump pixel-font render matrices', () async {
    final fonts = {
      'ark-pixel-16px': 'Font/ark-pixel-16px.ttf',
      'VonwaonBitmap-16px': 'Font/VonwaonBitmap-16px.ttf',
      'unifont-17.0.05': 'Font/unifont-17.0.05.otf',
    };
    for (final e in fonts.entries) {
      if (!File(e.value).existsSync()) continue;
      final r = GlyphRenderer();
      await r.addFontFile(e.value);
      for (final ch in ['中', 'A']) {
        final g = await r.renderGrapheme(ch,
            fontSize: 16, cellWidth: 16, cellHeight: 16);
        // ignore: avoid_print
        print('=== ${e.key} "$ch" missing=${g.isMissing} '
            'naturalW=${g.naturalWidth} ===');
        // ignore: avoid_print
        print(_dump(g.pixels, g.width, g.height));
      }
    }
  });

  test('size-mismatch produces gray fringe', () async {
    int grayOf(List<int> px) => px.where((v) => v != 0 && v != 255).length;

    // zpix / fusion-pixel are 12px-design fonts rendered at 16px
    for (final f in ['Font/zpix.ttf', 'Font/fusion-pixel-12px.ttf']) {
      final r = GlyphRenderer();
      await r.addFontFile(f);
      final g = await r.renderGrapheme('中',
          fontSize: 16, cellWidth: 16, cellHeight: 16);
      // ignore: avoid_print
      print('$f @16px -> gray pixels: ${grayOf(g.pixels)}');
      final g12 = await r.renderGrapheme('中',
          fontSize: 12, cellWidth: 16, cellHeight: 16);
      // ignore: avoid_print
      print('$f @12px -> gray pixels: ${grayOf(g12.pixels)}');
    }

    // 16px-design font rendered at 15px (off-size)
    final r = GlyphRenderer();
    await r.addFontFile('Font/ark-pixel-16px.ttf');
    final g = await r.renderGrapheme('中',
        fontSize: 15, cellWidth: 16, cellHeight: 16);
    // ignore: avoid_print
    print('ark-pixel @15px -> gray pixels: ${grayOf(g.pixels)}');
  });
}
