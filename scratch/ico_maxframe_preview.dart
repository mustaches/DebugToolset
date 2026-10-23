// 一次性脚本：抽出 ico 最大帧并排预览（白底 4x 放大）。
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final frames = <img.Image>[];
  for (final path in args) {
    final dec = img.IcoDecoder();
    dec.startDecode(File(path).readAsBytesSync());
    img.Image? best;
    for (var i = 0; i < dec.numFrames(); i++) {
      final f = dec.decodeFrame(i);
      if (f != null && (best == null || f.width > best.width)) best = f;
    }
    if (best != null) frames.add(best);
  }
  final w = frames.fold(0, (a, f) => a + f.width) + 8 * (frames.length - 1);
  final h = frames.fold(0, (a, f) => f.height > a ? f.height : a);
  final row = img.Image(width: w, height: h, numChannels: 4);
  img.fill(row, color: img.ColorRgb8(255, 255, 255));
  var x = 0;
  for (final f in frames) {
    img.compositeImage(row, f, dstX: x);
    x += f.width + 8;
  }
  final zoom = img.copyResize(row,
      width: w * 4, height: h * 4, interpolation: img.Interpolation.nearest);
  File('scratch/ico_maxframe_preview.png').writeAsBytesSync(img.encodePng(zoom));
  // ignore: avoid_print
  print('done ${frames.map((f) => '${f.width}x${f.height}').toList()}');
}
