import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';

void main() {
  const w = 3840, h = 2160;
  final frame = Uint8List(w * h * 3 ~/ 2);
  for (var i = 0; i < frame.length; i++) {
    frame[i] = i & 0xFF;
  }
  var step = 1;
  while (h ~/ step > 480) {
    step *= 2;
  }
  print('step=$step out=${w ~/ step}x${h ~/ step}');
  for (var i = 0; i < 5; i++) {
    yuv420p8ToRgbaStep(frame, w, h, step, limited: true, matrix: 1);
  }
  const n = 60;
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    yuv420p8ToRgbaStep(frame, w, h, step, limited: true, matrix: 1);
  }
  print('yuv420p8ToRgbaStep 480p 馈源: ${sw.elapsedMicroseconds / n} us/帧');
}
