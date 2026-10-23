// 一次性脚本：打印指定点的像素颜色。
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final im =
      img.decodePng(File('scratch/dim_test_drag.png').readAsBytesSync())!;
  for (final xy in [
    [798, 140],
    [799, 141],
    [800, 145],
    [797, 157],
    [700, 140],
    [715, 140],
    [830, 140],
    [830, 170],
  ]) {
    final p = im.getPixel(xy[0], xy[1]);
    // ignore: avoid_print
    print('(${xy[0]},${xy[1]}) = (${p.r},${p.g},${p.b})');
  }
}
