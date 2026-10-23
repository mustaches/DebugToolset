// 一次性脚本：探测截图指定带的蓝色像素分布。
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final im =
      img.decodePng(File('scratch/dim_test_t3.png').readAsBytesSync())!;
  bool isBlue(int x, int y) {
    final p = im.getPixel(x, y);
    return p.b > 130 && p.b > p.g * 1.15 && p.b > p.r * 1.8;
  }

  for (var y = 183; y <= 196; y++) {
    var cnt = 0;
    var first = -1;
    for (var x = 620; x <= 980; x++) {
      if (isBlue(x, y)) {
        cnt++;
        if (first < 0) first = x;
      }
    }
    // ignore: avoid_print
    print('y=$y blue=$cnt first=$first');
  }
  // 箭头线实际颜色抽样（肉眼所见箭头线 y≈189，x≈700）。
  for (var y = 186; y <= 193; y++) {
    final p = im.getPixel(700, y);
    // ignore: avoid_print
    print('(700,$y) = (${p.r},${p.g},${p.b},${p.a})');
  }
}
