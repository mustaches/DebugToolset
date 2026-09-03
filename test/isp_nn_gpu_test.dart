// GPU NN 后端（nn_gpu.dart，fp16 打包 FragmentShader conv2d）测试：
// - fp16 编解码与 shader 往返精度（Q2 替代路径实测）；
// - conv3x3 与 CPU ops.conv2d 对拍（含通道 pad、1x1 嵌入、多 pass 累加）；
// - 两个 VGG 形态的性能记录（CPU vs GPU 端到端 / GPU 仅渲染）。
// 无 GPU 环境（shader 加载失败）时全部跳过。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart'
    as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List randF32(int n, int seed, {double scale = 1.0}) {
  final rng = math.Random(seed);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (rng.nextDouble() * 2 - 1) * scale;
  }
  return out;
}

/// 尺度感知的最大相对误差：maxAbs / rms(expected)。
(double, double) errStats(Float32List actual, Float32List expected) {
  var maxAbs = 0.0, sumSq = 0.0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxAbs) maxAbs = d;
    sumSq += expected[i] * expected[i];
  }
  return (maxAbs, maxAbs / math.sqrt(sumSq / expected.length));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GpuNnBackend? gpu;

  setUpAll(() async {
    gpu = await GpuNnBackend.tryCreate();
    if (gpu == null) {
      // ignore: avoid_print
      print('GpuNnBackend 初始化失败（无 GPU 环境），跳过全部用例');
    }
  });

  test('fp16 编解码往返精度', () {
    final rng = math.Random(7);
    var worst = 0.0;
    for (var i = 0; i < 100000; i++) {
      // 覆盖 ±1e-7..±6e4 幅值（含次正规区间）
      final v = (rng.nextDouble() * 2 - 1) *
          math.pow(10.0, rng.nextDouble() * 11 - 7);
      final back = halfBitsToFloat(floatToHalfBits(v));
      // 正规数相对误差 ≤ 2^-11；次正规绝对误差 ≤ 2^-25（IEEE half 固有）
      final tol = 6e-4 * v.abs() + 3e-8;
      final d = (back - v).abs() - tol;
      if (d > worst) worst = d;
    }
    // ignore: avoid_print
    print('fp16 往返超容差量: $worst（≤0 为通过）');
    expect(worst, lessThanOrEqualTo(0.0));
  });

  test('conv3x3 与 CPU 对拍（多形状）', () async {
    final g = gpu;
    if (g == null) return;
    // (W, H, cin, cout, k)
    for (final (w, h, cin, cout, k) in [
      (32, 24, 8, 12, 3), // 基本形状
      (24, 24, 3, 16, 3), // 输入通道 pad 到 4
      (24, 24, 16, 6, 3), // 输出通道 pad 到 8
      (24, 24, 16, 16, 1), // 1x1 嵌入 3x3 中心 tap
      (8, 8, 512, 32, 3), // cinG=128 → 2 pass 累加
      (16, 16, 4, 4, 3), // 最小通道组
    ]) {
      final x = NnTensor(randF32(cin * h * w, cin * 31 + cout), [1, cin, h, w]);
      final wgt = NnTensor(
          randF32(cout * cin * k * k, cin + cout, scale: 0.3),
          [cout, cin, k, k]);
      final bias = randF32(cout, w + h, scale: 0.5);
      final pad = k == 3 ? 1 : 0;
      final cpu = ops.conv2d(x, wgt, bias: bias, padH: pad, padW: pad);
      final out = await g.conv2dAsync(x, wgt, bias: bias, padH: pad, padW: pad);
      expect(out.shape, cpu.shape, reason: '$cin->$cout ${w}x$h k$k');
      final (maxAbs, rel) = errStats(out.data, cpu.data);
      // ignore: avoid_print
      print('conv ${w}x$h $cin->$cout k$k: maxAbs=$maxAbs relToRms=$rel');
      expect(rel, lessThan(1e-2), reason: '$cin->$cout ${w}x$h k$k');
    }
  });

  test('无偏置 / 不支持的形态', () async {
    final g = gpu;
    if (g == null) return;
    const w = 16, h = 16, cin = 8, cout = 8;
    final x = NnTensor(randF32(cin * h * w, 1), [1, cin, h, w]);
    final wgt =
        NnTensor(randF32(cout * cin * 9, 2, scale: 0.3), [cout, cin, 3, 3]);
    final cpu = ops.conv2d(x, wgt, padH: 1, padW: 1);
    final out = await g.conv2dAsync(x, wgt, padH: 1, padW: 1);
    final (_, rel) = errStats(out.data, cpu.data);
    // ignore: avoid_print
    print('conv 无偏置: relToRms=$rel');
    expect(rel, lessThan(1e-2));
    // stride 2 → UnsupportedError（调用方回退 CPU）
    expect(() => g.conv2dAsync(x, wgt, strideH: 2, strideW: 2, padH: 1, padW: 1),
        throwsA(isA<UnsupportedError>()));
    // 同步接口未实现（异步入口替代）
    expect(() => g.conv2d(x, wgt, padH: 1, padW: 1),
        throwsA(isA<UnimplementedError>()));
  });

  test('conv3x3 性能记录（test 环境为软件光栅，数值仅供参考；'
      '真实 GPU 性能见 scratch/nn_gpu_bench_main.dart）', () async {
    final g = gpu;
    if (g == null) return;
    // 软件光栅可承受的中等形状；大形状（256²×64→64、128²×256→256）
    // 的真机计时由 scratch/nn_gpu_bench_main.dart 承担。
    const size = 64, cin = 64, cout = 64;
    final x = NnTensor(randF32(cin * size * size, 11), [1, cin, size, size]);
    final wgt = NnTensor(randF32(cout * cin * 9, 12, scale: 0.1),
        [cout, cin, 3, 3]);
    final bias = randF32(cout, 13, scale: 0.1);
    final flops = 2.0 * size * size * cout * cin * 9;

    var sw = Stopwatch()..start();
    final cpu = ops.conv2d(x, wgt, bias: bias, padH: 1, padW: 1);
    final cpuMs = sw.elapsedMilliseconds;

    sw = Stopwatch()..start();
    final out = await g.conv2dAsync(x, wgt, bias: bias, padH: 1, padW: 1);
    final gpuE2eMs = sw.elapsedMilliseconds;

    final (_, rel) = errStats(out.data, cpu.data);
    // ignore: avoid_print
    print('perf(test-env 软件光栅) ${size}x$size $cin->$cout: '
        'CPU ${cpuMs}ms (${(flops / cpuMs / 1e6).toStringAsFixed(2)} GFLOPS) | '
        'GPU 端到端 ${gpuE2eMs}ms '
        '(${(flops / gpuE2eMs / 1e6).toStringAsFixed(2)} GFLOPS) | '
        'relToRms=$rel');
    expect(rel, lessThan(1e-2));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
