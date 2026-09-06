// sGEMM / conv2d 性能基准（scratch/ 不参与静态分析）。
// 用法: dart run scratch/nn_gemm_bench.dart [--quick]
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/gemm.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';

double benchGemm(int m, int n, int k,
    {bool transA = false, bool transB = false, int reps = 3}) {
  final rng = math.Random(1);
  final a = Float32List.fromList([
    for (var i = 0; i < (transA ? k : m) * (transA ? m : k); i++)
      rng.nextDouble() - 0.5
  ]);
  final b = Float32List.fromList([
    for (var i = 0; i < (transB ? n : k) * (transB ? k : n); i++)
      rng.nextDouble() - 0.5
  ]);
  final c = Float32List(m * n);
  // 热身（触发 JIT 优化）
  sgemm(a, b, c, m, n, k, transA: transA, transB: transB);
  var best = double.infinity;
  for (var r = 0; r < reps; r++) {
    final sw = Stopwatch()..start();
    sgemm(a, b, c, m, n, k, transA: transA, transB: transB);
    sw.stop();
    final t = sw.elapsedMicroseconds / 1e6;
    if (t < best) best = t;
  }
  final gflops = 2.0 * m * n * k / best / 1e9;
  stdout.writeln('gemm ${m}x$n x$k transA=$transA transB=$transB: '
      '${(best * 1e3).toStringAsFixed(1)}ms, ${gflops.toStringAsFixed(2)} GFLOPS');
  return gflops;
}

double benchConv(int hw, int cin, int cout,
    {int kernel = 3, int stride = 1, int pad = 1, int groups = 1, int reps = 2}) {
  final rng = math.Random(2);
  final x = NnTensor(
      Float32List.fromList(
          [for (var i = 0; i < cin * hw * hw; i++) rng.nextDouble() - 0.5]),
      [1, cin, hw, hw]);
  final cpg = cin ~/ groups;
  final w = NnTensor(
      Float32List.fromList([
        for (var i = 0; i < cout * cpg * kernel * kernel; i++)
          rng.nextDouble() - 0.5
      ]),
      [cout, cpg, kernel, kernel]);
  final oh = convOutSize(hw, kernel, stride, pad);
  final flops = 2.0 * cout * cpg * kernel * kernel * oh * oh / 1e9;
  conv2d(x, w,
      strideH: stride, strideW: stride, padH: pad, padW: pad, groups: groups);
  var best = double.infinity;
  for (var r = 0; r < reps; r++) {
    final sw = Stopwatch()..start();
    conv2d(x, w,
        strideH: stride, strideW: stride, padH: pad, padW: pad, groups: groups);
    sw.stop();
    final t = sw.elapsedMicroseconds / 1e6;
    if (t < best) best = t;
  }
  stdout.writeln('conv${kernel}x$kernel s$stride ${hw}x$hw cin=$cin cout=$cout '
      'groups=$groups (${flops.toStringAsFixed(2)} GFLOP): '
      '${(best * 1e3).toStringAsFixed(1)}ms, '
      '${(flops / best).toStringAsFixed(2)} GFLOPS');
  return flops / best;
}

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  stdout.writeln('CPU 核数: ${Platform.numberOfProcessors}');
  // 方阵 gemm
  benchGemm(512, 512, 512);
  benchGemm(1024, 1024, 1024, reps: quick ? 1 : 2);
  // transB（linear 形态）
  benchGemm(512, 512, 512, transB: true);
  benchGemm(197, 768, 768, transB: true, reps: quick ? 1 : 2);
  // conv 形态（im2col 后）：m=cout, n=oh*ow, k=cpg*9
  benchGemm(64, 256 * 256, 576, reps: quick ? 1 : 2);
  // 1x1 conv 形态
  benchGemm(128, 128 * 128, 128, reps: quick ? 1 : 2);
  // conv 端到端
  benchConv(128, 64, 64);
  benchConv(256, 64, 64, reps: quick ? 1 : 2);
  if (!quick) {
    benchConv(512, 64, 64, reps: 1);
  }
  // 1x1 快路径
  benchConv(128, 128, 128, kernel: 1, pad: 0);
  // depthwise
  benchConv(256, 64, 64, stride: 2, groups: 64, reps: quick ? 1 : 2);
}
