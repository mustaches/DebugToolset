// NnPool.parallelGemm 并行扩展性微基准（定位 MUSIQ encoder/embedding
// 池并行未达预期的问题）：
//   dart run scratch/nn_gemm_probe.dart
// 对 MUSIQ 的三种 GEMM 形状分别测：单线程 sgemm（预热后）vs
// pool.parallelGemm（16 worker），打印加速比。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/gemm.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';

Float32List rand(int n, int seed) {
  var s = seed;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (s / 0x7fffffff) * 2 - 1;
  }
  return out;
}

Future<void> benchShape(String name, int m, int n, int k, bool transB,
    NnPool pool) async {
  final a = rand(m * k, 1);
  final b = rand(n * k, 2); // transB 时 [n,k]，否则 [k,n]（元素数相同）
  final gflop = 2.0 * m * n * k / 1e9;

  // 单线程（先预热 1 次再计时）。
  sgemm(a, b, Float32List(m * n), m, n, k, transB: transB);
  var sw = Stopwatch()..start();
  sgemm(a, b, Float32List(m * n), m, n, k, transB: transB);
  final syncMs = sw.elapsedMilliseconds;

  // 池并行（先预热 1 次再计时）。
  await pool.parallelGemm(a, b, m, n, k, transB: transB);
  sw = Stopwatch()..start();
  await pool.parallelGemm(a, b, m, n, k, transB: transB);
  final parMs = sw.elapsedMilliseconds;

  print('GEMM_PROBE $name [m=$m n=$n k=$k transB=$transB] '
      '${gflop.toStringAsFixed(1)}GF | sync ${syncMs}ms '
      '(${(gflop / (syncMs / 1e3)).toStringAsFixed(2)} GFLOPS) | '
      'pool ${parMs}ms '
      '(${(gflop / (parMs / 1e3)).toStringAsFixed(2)} GFLOPS) | '
      'speedup ${(syncMs / parMs).toStringAsFixed(2)}x');
}

Future<void> main() async {
  print('GEMM_PROBE cores=${Platform.numberOfProcessors}');
  final pool = NnPool();
  await pool.start(math.max(2, Platform.numberOfProcessors - 4));
  print('GEMM_PROBE workers=${pool.workerCount}');
  // 小形状预热全 worker 的 JIT（排除冷启动干扰）。
  final wa = rand(256 * 256, 3), wb = rand(256 * 256, 4);
  for (var i = 0; i < 8; i++) {
    await pool.parallelGemm(wa, wb, 256, 256, 256);
    sgemm(wa, wb, Float32List(256 * 256), 256, 256, 256);
  }
  await benchShape('embedding', 5134, 384, 16384, true, pool);
  await benchShape('scores', 5136, 5136, 64, true, pool);
  await benchShape('av', 5136, 64, 5136, false, pool);
  await benchShape('qkv', 5136, 384, 384, true, pool);
  await benchShape('fc1', 5136, 1152, 384, true, pool);
  await benchShape('square4k', 4096, 4096, 4096, false, pool);
  pool.dispose();
}
