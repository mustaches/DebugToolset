// 一次性性能粗测脚本（scratch/ 不参与静态分析）：
// conv 3x3 s1 p1，单线程 vs NnPool 并行。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';

Future<void> bench(int hw, int cin, int cout, int workers) async {
  final rng = math.Random(0);
  final x = NnTensor(
      Float32List.fromList(
          [for (var i = 0; i < cin * hw * hw; i++) rng.nextDouble() - 0.5]),
      [1, cin, hw, hw]);
  final w = NnTensor(
      Float32List.fromList(
          [for (var i = 0; i < cout * cin * 9; i++) rng.nextDouble() - 0.5]),
      [cout, cin, 3, 3]);
  final flops = 2.0 * cout * cin * 9 * hw * hw / 1e9;

  var sw = Stopwatch()..start();
  final single = conv2d(x, w, padH: 1, padW: 1);
  sw.stop();
  final tSingle = sw.elapsedMilliseconds;

  final pool = NnPool();
  await pool.start(workers);
  sw = Stopwatch()..start();
  final par = await pool.parallelConv2d(x, w, padH: 1, padW: 1);
  sw.stop();
  final tPar = sw.elapsedMilliseconds;
  pool.dispose();

  var diff = 0.0;
  for (var i = 0; i < single.numel; i++) {
    final d = (single.data[i] - par.data[i]).abs();
    if (d > diff) diff = d;
  }
  stdout.writeln('conv3x3 ${hw}x$hw cin=$cin cout=$cout '
      '(${flops.toStringAsFixed(1)} GFLOP): '
      '单线程 ${tSingle}ms, ${workers} worker ${tPar}ms, '
      '加速 ${(tSingle / tPar).toStringAsFixed(2)}x, maxDiff=$diff');
}

Future<void> main() async {
  stdout.writeln('CPU 核数: ${Platform.numberOfProcessors}');
  await bench(128, 64, 64, 8); // 热身 + 小规模
  await bench(256, 64, 64, 8);
  await bench(512, 64, 64, 8);
}
