// 一次性脚本：报告截图中蓝色竖线的列位置与纵向范围。
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final im = img.decodePng(File(args[0]).readAsBytesSync())!;
  bool isBlue(int x, int y) {
    final p = im.getPixel(x, y);
    return p.b > p.g * 1.15 && p.b > p.r * 1.8 && (p.b + p.g + p.r) > 200;
  }

  // 逐列统计 y=100..800 内的蓝像素数；竖线 = 高计数列。
  final colCount = <int, int>{};
  for (var x = 380; x < 1500; x++) {
    var c = 0;
    var yMin = -1, yMax = -1;
    for (var y = 100; y < 800; y++) {
      if (isBlue(x, y)) {
        c++;
        if (yMin < 0) yMin = y;
        yMax = y;
      }
    }
    if (c > 20) colCount[x] = c;
    if (c > 20) {
      // ignore: avoid_print
      print('x=$x count=$c y=$yMin..$yMax');
    }
  }
}
