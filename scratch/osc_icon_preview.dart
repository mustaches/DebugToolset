// 一次性脚本：把图标按侧栏实际渲染（22px、灰色、深色底）生成预览。
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final icon = img.decodePng(File('icons/oscilloscope.png').readAsBytesSync())!;
  final small = img.copyResize(icon, width: 22, height: 22);
  // 侧栏底色（Theme surface 近似 #1F1F1F）+ 未选中灰色。
  final canvas = img.Image(width: 40, height: 44);
  img.fill(canvas, color: img.ColorRgb8(31, 31, 31));
  final tinted = img.Image.from(small);
  for (final p in tinted) {
    p
      ..r = 158
      ..g = 158
      ..b = 158;
  }
  img.compositeImage(canvas, tinted, dstX: 9, dstY: 11);
  final zoom = img.copyResize(canvas,
      width: 160, height: 176, interpolation: img.Interpolation.nearest);
  File('scratch/osc_icon_preview.png').writeAsBytesSync(img.encodePng(zoom));
  // ignore: avoid_print
  print('done');
}
