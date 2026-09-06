// MUSIQ 新后台入口（musiqScoreInIsolate，优化 10）在真机 5MP 馈源
// 尺寸（2592×1940）上的端到端性能基准：
//   dart run scratch/musiq_score_bench.dart
// 直接在当前 isolate 调用 musiqScoreInIsolate（其内自起 NnPool，
// 核数-4）——与生产 compute(...) 路径相比仅差一次 isolate 消息往返
// （~20MB rgba 拷贝），耗时口径一致。基线：旧路径（transformer 全部
// 同步堵 UI isolate）456s。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/musiq_dart.dart';

const int kW = 2592, kH = 1940;

/// 高纹理彩色测试帧（图案同 test/isp_pyiqa_test.dart 的 busyFrame）。
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
      rgba[i + 2] = (128 +
              70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<void> main() async {
  if (!File(musiqWeightsPath).existsSync()) {
    print('MUSIQ_BENCH_ERROR 缺少权重 $musiqWeightsPath');
    exit(1);
  }
  var sw = Stopwatch()..start();
  final rgba = busyFrame(kW, kH);
  print('MUSIQ_BENCH busyFrame ${kW}x$kH gen = ${sw.elapsedMilliseconds}ms');
  sw = Stopwatch()..start();
  final v = await musiqScoreInIsolate(
      {'rgba': rgba, 'width': kW, 'height': kH});
  print('MUSIQ_BENCH ${kW}x$kH 端到端 = ${sw.elapsedMilliseconds}ms '
      'score=$v（旧路径基线 456000ms）');
}
