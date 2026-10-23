// 一次性脚本：把 ico 最大帧 alpha 打印为 ASCII 图。
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final dec = img.IcoDecoder();
  dec.startDecode(File(args[0]).readAsBytesSync());
  img.Image? best;
  for (var i = 0; i < dec.numFrames(); i++) {
    final f = dec.decodeFrame(i);
    if (f != null && (best == null || f.width > best.width)) best = f;
  }
  final f = best!;
  for (var y = 0; y < f.height; y++) {
    final buf = StringBuffer();
    for (var x = 0; x < f.width; x++) {
      final a = f.getPixel(x, y).a;
      buf.write(a > 128 ? '#' : a > 40 ? '+' : '.');
    }
    // ignore: avoid_print
    print(buf.toString());
  }
}
