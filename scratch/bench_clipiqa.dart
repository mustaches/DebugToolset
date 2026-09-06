// 临时基准：CLIPIQA Dart 实现 256×192 单次评分耗时（单线程 vs 池并行）。
// 运行：dart run scratch/bench_clipiqa.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clipiqa_dart.dart';

Uint8List busyFrame(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 1] = (128 +
              70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
              40 * math.cos((2 * x - y) / 6.7))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 2] =
          (128 + 70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
              .clamp(0.0, 255.0)
              .toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<void> main() async {
  const w = 256, h = 192;
  final a = busyFrame(w, h);

  var sw = Stopwatch()..start();
  final s1 = clipiqaScore(a, w, h);
  sw.stop();
  print('单线程: ${sw.elapsedMilliseconds} ms  score=$s1');

  // 池并行：先跑一遍暖机（含 isolate 启动），再计时纯计算。
  await clipiqaScoreParallel(a, w, h);
  sw = Stopwatch()..start();
  final s2 = await clipiqaScoreParallel(a, w, h);
  sw.stop();
  print('池并行(含启动): ${sw.elapsedMilliseconds} ms  score=$s2');
}
