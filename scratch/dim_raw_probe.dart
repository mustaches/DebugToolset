// 一次性脚本：打印指定矩形内非黑像素的原始颜色（不过滤）。
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final im = img.decodePng(File(args[0]).readAsBytesSync())!;
  final x0 = int.parse(args[1]), y0 = int.parse(args[2]);
  final x1 = int.parse(args[3]), y1 = int.parse(args[4]);
  for (var y = y0; y <= y1; y++) {
    final parts = <String>[];
    for (var x = x0; x <= x1; x++) {
      final p = im.getPixel(x, y);
      if (p.r + p.g + p.b > 24) {
        parts.add('($x,$y)=${p.r.toInt()},${p.g.toInt()},${p.b.toInt()}');
      }
    }
    if (parts.isNotEmpty) {
      // ignore: avoid_print
      print(parts.join(' '));
    }
  }
}
