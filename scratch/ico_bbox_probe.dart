// 一次性脚本：分析 ico 各帧的内容包围盒/笔画宽度/颜色。
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  for (final path in args) {
    final bytes = File(path).readAsBytesSync();
    final dec = img.IcoDecoder();
    dec.startDecode(bytes);
    // ignore: avoid_print
    print('$path (${dec.numFrames()} 帧):');
    for (var i = 0; i < dec.numFrames(); i++) {
      final f = dec.decodeFrame(i);
      if (f == null) continue;
      var x0 = f.width, y0 = f.height, x1 = -1, y1 = -1, n = 0;
      num rSum = 0, gSum = 0, bSum = 0;
      // 行覆盖宽度直方图（估笔画宽：取最频繁的连续段长度）。
      for (var y = 0; y < f.height; y++) {
        for (var x = 0; x < f.width; x++) {
          final p = f.getPixel(x, y);
          if (p.a > 128) {
            n++;
            rSum += p.r;
            gSum += p.g;
            bSum += p.b;
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
          }
        }
      }
      if (n == 0) continue;
      // ignore: avoid_print
      print('  frame$i ${f.width}x${f.height} 内容=($x0,$y0)-($x1,$y1) '
          '色=(${rSum ~/ n},${gSum ~/ n},${bSum ~/ n})');
    }
  }
}
