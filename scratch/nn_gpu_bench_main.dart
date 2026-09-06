// NN GPU conv 真实 GPU 基准入口：
//   flutter run -d windows -t scratch/nn_gpu_bench_main.dart
// 在真实 Windows/Impeller 环境测量 GpuNnBackend 的两个 VGG conv3x3 形态
// （flutter test 环境为软件光栅，性能数值无意义，正确性测试在
// test/isp_nn_gpu_test.dart）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart'
    as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

Float32List randF32(int n, int seed, {double scale = 1.0}) {
  final rng = math.Random(seed);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (rng.nextDouble() * 2 - 1) * scale;
  }
  return out;
}

Future<void> bench() async {
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    print('NN_BENCH_ERROR backend 初始化失败');
    return;
  }
  for (final (size, cin, cout) in [(256, 64, 64), (128, 256, 256)]) {
    final x = NnTensor(randF32(cin * size * size, 11), [1, cin, size, size]);
    final wgt = NnTensor(
        randF32(cout * cin * 9, 12, scale: 0.1), [cout, cin, 3, 3]);
    final bias = randF32(cout, 13, scale: 0.1);
    final flops = 2.0 * size * size * cout * cin * 9;

    var sw = Stopwatch()..start();
    final cpu = ops.conv2d(x, wgt, bias: bias, padH: 1, padW: 1);
    final cpuMs = sw.elapsedMilliseconds;

    sw = Stopwatch()..start();
    final xGpu = await g.uploadFeatureMap(x);
    final upXMs = sw.elapsedMilliseconds;

    sw = Stopwatch()..start();
    final wGpu = await g.uploadConvWeights(wgt, cin, bias: bias);
    final upWMs = sw.elapsedMilliseconds;

    sw = Stopwatch()..start();
    var out = g.conv2dGpu(xGpu, wGpu); // 预热（含驱动 shader 编译）
    final warmMs = sw.elapsedMilliseconds;

    // (a) 连续 5 次渲染 + 1 次回读（队列重叠，摊薄提交开销）
    sw = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      out.dispose();
      out = g.conv2dGpu(xGpu, wGpu);
    }
    final back = await g.downloadFeatureMap(out, channels: cout);
    final burstMs = sw.elapsedMicroseconds / 1000.0;

    // (b) 渲染+回读串行 3 次（真实单层端到端驻留成本）
    var serialMs = 0.0;
    for (var i = 0; i < 3; i++) {
      sw = Stopwatch()..start();
      final o = g.conv2dGpu(xGpu, wGpu);
      await g.downloadFeatureMap(o, channels: cout);
      serialMs += sw.elapsedMicroseconds / 1000.0;
      o.dispose();
    }
    serialMs /= 3;

    // (c) 全异步端到端（含打包/上传/回读/解包）
    sw = Stopwatch()..start();
    await g.conv2dAsync(x, wgt, bias: bias, padH: 1, padW: 1);
    final e2eMs = sw.elapsedMilliseconds;

    var maxAbs = 0.0, sumSq = 0.0;
    for (var i = 0; i < back.data.length; i++) {
      final d = (back.data[i] - cpu.data[i]).abs();
      if (d > maxAbs) maxAbs = d;
      sumSq += cpu.data[i] * cpu.data[i];
    }
    final rel = maxAbs / math.sqrt(sumSq / cpu.data.length);

    print('NN_BENCH ${size}x$size $cin->$cout | '
        'CPU ${cpuMs}ms (${(flops / cpuMs / 1e6).toStringAsFixed(2)} GFLOPS) | '
        'upload x=${upXMs}ms w=${upWMs}ms | warm(含编译) ${warmMs}ms | '
        'render×5+read=${burstMs.toStringAsFixed(1)}ms '
        '(≈${((burstMs) / 5).toStringAsFixed(2)}ms/层, '
        '${(flops / (burstMs / 5) / 1e6).toStringAsFixed(1)} GFLOPS) | '
        'render+read 串行 ${serialMs.toStringAsFixed(2)}ms/层 | '
        'e2e ${e2eMs}ms | relToRms=$rel');
    out.dispose();
    xGpu.dispose();
    wGpu.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('nn gpu bench')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await bench();
    } catch (e, st) {
      print('NN_BENCH_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
