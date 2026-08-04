import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/ebdt_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = r'C:\Windows\Fonts\msgothic.ttc';

  test('dingbats U+2700-27BF EBDT dump', () async {
    if (!File(path).existsSync()) return;
    int hit = 0, miss = 0;
    final arts = <int, List<int>>{};
    for (int cp = 0x2700; cp <= 0x27BF; cp++) {
      final px = await EmbeddedBitmapParser.readNativeBitmap(
        path: path,
        codePoint: cp,
        targetSize: 16,
        cellWidth: 16,
        cellHeight: 16,
      );
      if (px == null) {
        miss++;
      } else {
        hit++;
        if (arts.length < 8 && px.any((v) => v == 255)) arts[cp] = px;
      }
    }
    // ignore: avoid_print
    print('hit=$hit miss=$miss');
    for (final e in arts.entries) {
      // ignore: avoid_print
      print('--- U+${e.key.toRadixString(16).toUpperCase()} ---');
      final sb = StringBuffer();
      for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
          sb.write(e.value[y * 16 + x] == 255 ? '#' : '.');
        }
        sb.writeln();
      }
      // ignore: avoid_print
      print(sb);
    }
  });
}
