// 一次性脚本：细查指定矩形内的蓝像素。
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final im = img.decodePng(File(args[0]).readAsBytesSync())!;
  final x0 = int.parse(args[1]), y0 = int.parse(args[2]);
  final x1 = int.parse(args[3]), y1 = int.parse(args[4]);
  bool isBlue(int x, int y) {
    final p = im.getPixel(x, y);
    final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
    final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
    return lo > 120 && hi - lo < 70;
  }

  for (var y = y0; y <= y1; y++) {
    final buf = StringBuffer();
    for (var x = x0; x <= x1; x++) {
      buf.write(isBlue(x, y) ? '#' : '.');
    }
    final s = buf.toString();
    if (s.contains('#')) {
      // ignore: avoid_print
      print('y=$y $s');
    }
  }
}
