// 一次性脚本：save 与 dimension 图标并排预览（28px、白、深色底）。
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final canvas = img.Image(width: 80, height: 40);
  img.fill(canvas, color: img.ColorRgb8(37, 37, 37));
  var x = 6;
  for (final name in ['save', 'dimension']) {
    final icon =
        img.decodePng(File('icons/$name.png').readAsBytesSync())!;
    img.compositeImage(canvas, img.copyResize(icon, width: 28, height: 28),
        dstX: x, dstY: 6);
    x += 38;
  }
  final zoom = img.copyResize(canvas,
      width: 320, height: 160, interpolation: img.Interpolation.nearest);
  File('scratch/dim_trim_preview.png').writeAsBytesSync(img.encodePng(zoom));
  // ignore: avoid_print
  print('done');
}
