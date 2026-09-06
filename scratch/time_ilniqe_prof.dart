import 'dart:io';
import 'dart:typed_data';
import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'ilniqe_prof.dart';

Future<void> main() async {
  final (rgb, w, h) = await decodeImageFileToRgb16('IspFlow/DemoPhoto/3.jpg', maxValue: 255);
  final rgba = Uint8List(w * h * 4);
  for (var i = 0, j = 0, k = 0; i < w * h; i++, j += 3, k += 4) {
    rgba[k] = rgb[j]; rgba[k+1] = rgb[j+1]; rgba[k+2] = rgb[j+2]; rgba[k+3] = 255;
  }
  final (ra2, rw, rh) = downsampleRgba82x(rgba, w, h);
  final v = ilniqeScore(ra2, rw, rh);
  print('score = $v');
  final keys = profTimings.keys.toList()..sort();
  for (final k in keys) {
    print('${k.padRight(26)} ${(profTimings[k]! / 1000).toStringAsFixed(0).padLeft(7)} ms');
  }
  exit(0);
}
