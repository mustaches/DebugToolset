import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/glyph_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

int _gray(List<int> px) => px.where((v) => v != 0 && v != 255).length;

void main() {
  testWidgets('render at different devicePixelRatio', (tester) async {
    const path = r'C:\Windows\Fonts\msgothic.ttc';
    if (!File(path).existsSync()) return;
    final r = GlyphRenderer();
    await r.addFontFile(path);

    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      tester.view.devicePixelRatio = dpr;
      final g = await r.renderGrapheme('中',
          fontSize: 16, cellWidth: 16, cellHeight: 16);
      // ignore: avoid_print
      print('dpr=$dpr -> width=${g.width} gray=${_gray(g.pixels)}');
      tester.view.resetDevicePixelRatio();
    }
  });
}
