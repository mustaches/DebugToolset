// RN50 GPU 纹理驻留链（CLIPIQA）的真实 GPU 基准入口：
//   flutter run -d windows -t scratch/nn_gpu_rn50_bench_main.dart
// 在真实 Windows/Impeller 环境对比 CLIPIQA 的 GPU 主干链（+
// NnPool 并行 attention）与纯 CPU 池路径的耗时与分数，并对拍
// Python 桥接基线（验收口径：GPU vs Python 相对偏差 ≤1e-3）。
// 224²/1024×768 走单纹理路径，1688×3000 与 2736×3648 走分块
// （banded）路径；flutter test 环境为软件光栅，性能数值无意义，
// 正确性/精度测试在 test/isp_nn_gpu_rn50_test.dart。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clip_rn50_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clipiqa_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 高纹理彩色测试帧（图案同 test/isp_pyiqa_test.dart 的 busyFrame）。
Uint8List busyFrame(int w, int h, {bool noisy = false}) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      var r = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0)
          .toInt();
      var g = (128 +
              70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
              40 * math.cos((2 * x - y) / 6.7))
          .clamp(0.0, 255.0)
          .toInt();
      var b = (128 +
              70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
          .clamp(0.0, 255.0)
          .toInt();
      if (noisy) {
        final base = (y * w + x) * 3;
        r = (r + (base * 31) % 61 - 30).clamp(0, 255);
        g = (g + ((base + 1) * 31) % 61 - 30).clamp(0, 255);
        b = (b + ((base + 2) * 31) % 61 - 30).clamp(0, 255);
      }
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

/// 调 iqa_bridge.py 一次性模式取 Python 参考分（同
/// test/isp_clipiqa_dart_test.dart 的口径；环境缺失返回 null）。
Future<double?> pyRef(Uint8List a, int w, int h) async {
  if (!PyIqaWorker.available) return null;
  final aPath = await pyIqaWriteTempPng(a, w, h);
  final res = await Process.run(
      pyIqaPythonPath, [pyIqaBridgePath, '--metric', 'clipiqa', '--a', aPath],
      workingDirectory: Directory.current.path);
  for (final line in const LineSplitter().convert(res.stdout as String)) {
    final t = line.trimLeft();
    if (!t.startsWith('{')) continue;
    final obj = jsonDecode(t) as Map<String, Object?>;
    if (obj['ok'] == true) return (obj['score'] as num).toDouble();
    return null;
  }
  return null;
}

Future<void> bench() async {
  if (!File(clipiqaWeightsPath).existsSync()) {
    print('NN_RN50_BENCH_ERROR 缺少权重 $clipiqaWeightsPath');
    return;
  }
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    print('NN_RN50_BENCH_ERROR backend 初始化失败');
    return;
  }
  var sw = Stopwatch()..start();
  final rn50Gpu = await ClipRn50Gpu.load(g, clipiqaWeightsPath);
  print('NN_RN50_BENCH 权重上传 ${sw.elapsedMilliseconds}ms');

  final pool = NnPool();
  await pool.start();
  try {
    // CPU 池对比到 1688×3000 为止（5MP 的 CPU 路径超 6 分钟，跳过）；
    // 2736×3648 只跑 GPU 路径 + Python 基线对拍。
    for (final (w, h, runCpu) in [
      (224, 224, true),
      (1024, 768, true),
      (1688, 3000, true),
      (2736, 3648, false),
    ]) {
      final a = busyFrame(w, h, noisy: true);
      double? cpuV;
      int? cpuMs;
      if (runCpu) {
        // CPU 池路径（预热 1 次后计时 1 次）。
        await clipiqaScoreParallel(a, w, h, pool: pool);
        sw = Stopwatch()..start();
        cpuV = await clipiqaScoreParallel(a, w, h, pool: pool);
        cpuMs = sw.elapsedMilliseconds;
      }
      // GPU 主干链路径（先直接调 forwardTrunk 探测支持性——
      // scoreParallel 内部会吞掉异常回退 CPU，无法用于探测）。
      try {
        await rn50Gpu.forwardTrunk(clipiqaInput(a, w, h));
      } catch (e) {
        print('NN_RN50_BENCH CLIPIQA ${w}x$h | GPU路径 不支持（$e） | '
            'score cpu=$cpuV');
        continue;
      }
      var usedGpu = false;
      sw = Stopwatch()..start();
      final gpuV = await clipiqaScoreParallel(a, w, h,
          pool: pool, gpuTrunk: rn50Gpu, onBackend: (u) => usedGpu = u);
      final gpuMs = sw.elapsedMilliseconds;
      final pyV = await pyRef(a, w, h);
      final relPy =
          pyV == null ? double.nan : (gpuV - pyV).abs() / pyV.abs();
      final relCpu =
          cpuV == null ? double.nan : (gpuV - cpuV).abs() / cpuV.abs();
      print('NN_RN50_BENCH CLIPIQA ${w}x$h | usedGpu=$usedGpu | '
          'CPU池 ${cpuMs ?? '-'}ms | GPU路径 ${gpuMs}ms | '
          'score cpu=$cpuV gpu=$gpuV python=$pyV | '
          'relErrVsPython=$relPy relErrVsCpu=$relCpu');
    }
  } finally {
    pool.dispose();
    rn50Gpu.dispose();
    g.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('nn gpu rn50 bench')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await bench();
    } catch (e, st) {
      print('NN_RN50_BENCH_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
