import 'dart:io';
import 'dart:typed_data';
import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';

Future<void> main() async {
  final (rgb, w, h) = await decodeImageFileToRgb16('IspFlow/DemoPhoto/3.jpg', maxValue: 255);
  final rgba = Uint8List(w * h * 4);
  for (var i = 0, j = 0, k = 0; i < w * h; i++, j += 3, k += 4) {
    rgba[k] = rgb[j]; rgba[k+1] = rgb[j+1]; rgba[k+2] = rgb[j+2]; rgba[k+3] = 255;
  }
  final (ra2, rw, rh) = downsampleRgba82x(rgba, w, h);

  var sw = Stopwatch()..start();
  final vs = ilniqeScore(ra2, rw, rh);
  final tSerial = sw.elapsedMilliseconds;

  sw.reset();
  final vp = await ilniqeScoreParallel(ra2, rw, rh, workers: 6);
  final tPar = sw.elapsedMilliseconds;

  sw.reset();
  final vp2 = await ilniqeScoreParallel(ra2, rw, rh, workers: 12);
  final tPar12 = sw.elapsedMilliseconds;

  print('serial:    ${tSerial}ms  score=$vs');
  print('parallel6: ${tPar}ms  score=$vp  identical=${vs == vp}');
  print('parallel12:${tPar12}ms  score=$vp2 identical=${vs == vp2}');
  exit(0);
}
