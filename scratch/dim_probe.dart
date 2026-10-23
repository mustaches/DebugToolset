// 一次性脚本：测量 save.png 内容上下沿与 dimension.png 各列范围。
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final save = img.decodePng(File('icons/save.png').readAsBytesSync())!;
  var top = -1, bottom = -1;
  for (var y = 0; y < save.height; y++) {
    var any = false;
    for (var x = 0; x < save.width; x++) {
      if (save.getPixel(x, y).a > 0) {
        any = true;
        break;
      }
    }
    if (any) {
      if (top < 0) top = y;
      bottom = y;
    }
  }
  // ignore: avoid_print
  print('save.png: 内容上下沿 y=$top..$bottom（共 ${save.height}）');

  final dim = img.decodePng(File('icons/dimension.png').readAsBytesSync())!;
  // ignore: avoid_print
  print('dimension.png ${dim.width}x${dim.height} 各列内容范围（非空列）:');
  for (var x = 0; x < dim.width; x++) {
    var t = -1, b = -1;
    for (var y = 0; y < dim.height; y++) {
      if (dim.getPixel(x, y).a > 0) {
        if (t < 0) t = y;
        b = y;
      }
    }
    if (t >= 0) {
      // ignore: avoid_print
      print('  x=$x y=$t..$b 高度=${b - t + 1}');
    }
  }
}
