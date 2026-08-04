import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/ebdt_parser.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/glyph_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

int _gray(List<int> px) => px.where((v) => v != 0 && v != 255).length;

void main() {
  const path = r'C:\Windows\Fonts\msgothic.ttc';

  test('msgothic pipeline vs direct EBDT', () async {
    if (!File(path).existsSync()) return;

    // 1. Direct EBDT extraction for several code points at 16px
    for (final cp in [0x4E2D, 0x3042, 0x0041, 0x6587, 0x6F22]) {
      final px = await EmbeddedBitmapParser.readNativeBitmap(
        path: path,
        codePoint: cp,
        targetSize: 16,
        cellWidth: 16,
        cellHeight: 16,
      );
      // ignore: avoid_print
      print('EBDT direct U+${cp.toRadixString(16).toUpperCase()}: '
          '${px == null ? "NULL" : "hit, gray=${_gray(px)}"}');
    }

    // 2. Full pipeline render
    final r = GlyphRenderer();
    await r.addFontFile(path);
    for (final ch in ['中', 'あ', 'A', '文']) {
      final g = await r.renderGrapheme(ch,
          fontSize: 16, cellWidth: 16, cellHeight: 16);
      // ignore: avoid_print
      print('pipeline "$ch": missing=${g.isMissing} gray=${_gray(g.pixels)}');
      // print matrix for the first char
      if (ch == '中') {
        final sb = StringBuffer();
        for (int y = 0; y < g.height; y++) {
          for (int x = 0; x < g.width; x++) {
            final v = g.pixels[y * g.width + x];
            sb.write(v == 0
                ? ' . '
                : v == 255
                    ? ' ##'
                    : ' ${v.toRadixString(16).padLeft(2, '0')}');
          }
          sb.writeln();
        }
        // ignore: avoid_print
        print(sb);
      }
    }
  });
}
