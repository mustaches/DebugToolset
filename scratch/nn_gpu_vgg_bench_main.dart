// VGG16 GPU 纹理驻留链的真实 GPU 基准入口：
//   flutter run -d windows -t scratch/nn_gpu_vgg_bench_main.dart
// 在真实 Windows/Impeller 环境对比 LPIPS 的 GPU 驻留链路径与 CPU
// 池并行路径耗时（256×192/512×384 走单纹理路径，1024×768 与
// 1688×3000 走分块（banded）路径；flutter test 环境为软件光栅，
// 性能数值无意义，正确性/精度测试在 test/isp_nn_gpu_vgg_test.dart）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/dists_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
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

Future<void> bench() async {
  if (!File(lpipsVggWeightsPath).existsSync() ||
      !File(lpipsLinWeightsPath).existsSync()) {
    print('NN_VGG_BENCH_ERROR 缺少权重 $lpipsVggWeightsPath / '
        '$lpipsLinWeightsPath');
    return;
  }
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    print('NN_VGG_BENCH_ERROR backend 初始化失败');
    return;
  }
  var sw = Stopwatch()..start();
  final vggGpu = await Vgg16Gpu.load(g, lpipsVggWeightsPath);
  print('NN_VGG_BENCH 权重上传 ${sw.elapsedMilliseconds}ms');

  final pool = NnPool();
  await pool.start();
  try {
    for (final (w, h) in [(256, 192), (512, 384), (1024, 768), (1688, 3000)]) {
      final a = busyFrame(w, h);
      final b = busyFrame(w, h, noisy: true);

      // CPU 池并行路径（预热 1 次后计时 1 次）。
      await lpipsScoreParallel(a, b, w, h, pool: pool);
      sw = Stopwatch()..start();
      final cpuV = await lpipsScoreParallel(a, b, w, h, pool: pool);
      final cpuMs = sw.elapsedMilliseconds;

      // GPU 驻留链路径（先直接调 forward 探测支持性并预热——
      // scoreParallel 内部会吞掉异常回退 CPU，无法用于探测）。
      var gpuSupported = true;
      try {
        await vggGpu.forward(lpipsInput(a, w, h));
      } catch (_) {
        gpuSupported = false;
      }
      if (!gpuSupported) {
        print('NN_VGG_BENCH LPIPS ${w}x$h | CPU池 ${cpuMs}ms | '
            'GPU路径 不支持（scoreParallel 内部整链回退 CPU） | '
            'score cpu=$cpuV');
        continue;
      }
      sw = Stopwatch()..start();
      final gpuV = await lpipsScoreParallel(a, b, w, h, vggForward: vggGpu);
      final gpuMs = sw.elapsedMilliseconds;

      // 纯前向（单侧输入、含上传与 5 层切片回读，不含指标后处理）。
      sw = Stopwatch()..start();
      await vggGpu.forward(lpipsInput(a, w, h));
      final fwdMs = sw.elapsedMilliseconds;

      final d = (gpuV - cpuV).abs();
      print('NN_VGG_BENCH LPIPS ${w}x$h | CPU池 ${cpuMs}ms | '
          'GPU路径 ${gpuMs}ms | GPU单侧前向 ${fwdMs}ms | '
          'score cpu=$cpuV gpu=$gpuV |diff|=$d');

      // DISTS（L2pooling 变体，banded 链的另一条池化分支）：同样对比
      // CPU 池与 GPU 路径耗时与分数差。
      await distsScoreParallel(a, b, w, h, pool: pool);
      sw = Stopwatch()..start();
      final cpuVd = await distsScoreParallel(a, b, w, h, pool: pool);
      final cpuMsD = sw.elapsedMilliseconds;
      sw = Stopwatch()..start();
      final gpuVd =
          await distsScoreParallel(a, b, w, h, pool: pool, vggForward: vggGpu);
      final gpuMsD = sw.elapsedMilliseconds;
      final dd = (gpuVd - cpuVd).abs();
      print('NN_VGG_BENCH DISTS ${w}x$h | CPU池 ${cpuMsD}ms | '
          'GPU路径 ${gpuMsD}ms | score cpu=$cpuVd gpu=$gpuVd |diff|=$dd');
    }
  } finally {
    pool.dispose();
    vggGpu.dispose();
    g.dispose();
  }
}

/// 调 iqa_bridge.py 一次性模式取 Python 参考分（同
/// test/isp_lpips_dists_dart_test.dart 的口径；环境缺失返回 null）。
Future<double?> pyRef(String metric, Uint8List a, Uint8List b, int w,
    int h) async {
  if (!PyIqaWorker.available) return null;
  final aPath = await pyIqaWriteTempPng(a, w, h);
  final bPath = await pyIqaWriteTempPng(b, w, h);
  final res = await Process.run(
      pyIqaPythonPath,
      [pyIqaBridgePath, '--metric', metric, '--a', aPath, '--b', bPath],
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

/// 端到端精度对拍（真机 GPU；test 环境的软件光栅跑不动这些尺寸，故精度
/// 对拍在此记录）：
/// - 256×192 busyFrame 干净/加噪对（单纹理路径）：逐层切片 GPU vs CPU
///   （两种池化变体）+ LPIPS/DISTS 三方分数（GPU / CPU 池 / Python 基线）；
/// - 1024×768 busyFrame 对（分块 banded 路径，4 带）：LPIPS/DISTS 三方
///   分数与耗时（验收口径：GPU vs Python 相对偏差 ≤1e-3）。
Future<void> precision() async {
  if (!File(lpipsVggWeightsPath).existsSync() ||
      !File(lpipsLinWeightsPath).existsSync() ||
      !File(distsWeightsPath).existsSync()) {
    print('NN_VGG_BENCH_ERROR 缺少 .nnw 权重，跳过精度对拍');
    return;
  }
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    print('NN_VGG_BENCH_ERROR backend 初始化失败');
    return;
  }
  final vggGpu = await Vgg16Gpu.load(g, lpipsVggWeightsPath);
  final pool = NnPool();
  await pool.start();
  try {
    const w = 256, h = 192;
    final a = busyFrame(w, h);
    final b = busyFrame(w, h, noisy: true);

    // 逐层切片特征 GPU vs CPU（两种池化变体）。
    final x = lpipsInput(a, w, h);
    final cpuVgg = Vgg16Dart.load(lpipsVggWeightsPath);
    for (final l2 in [false, true]) {
      final cpuFeats = cpuVgg.forward(x, useL2Pooling: l2);
      final gpuFeats = await vggGpu.forward(x, useL2Pooling: l2);
      const names = ['relu1_2', 'relu2_2', 'relu3_3', 'relu4_3', 'relu5_3'];
      for (var k = 0; k < 5; k++) {
        var maxAbs = 0.0, sumSq = 0.0;
        for (var i = 0; i < cpuFeats[k].numel; i++) {
          final d = (gpuFeats[k].data[i] - cpuFeats[k].data[i]).abs();
          if (d > maxAbs) maxAbs = d;
          sumSq += cpuFeats[k].data[i] * cpuFeats[k].data[i];
        }
        final rel = maxAbs / math.sqrt(sumSq / cpuFeats[k].numel);
        print('NN_VGG_BENCH_LAYER 256x192 l2=$l2 ${names[k]} '
            '${cpuFeats[k].shape} maxAbs=$maxAbs relToRms=$rel');
      }
    }

    for (final metric in ['lpips', 'dists']) {
      final pyV = await pyRef(metric, a, b, w, h);
      final gpuV = metric == 'lpips'
          ? await lpipsScoreParallel(a, b, w, h, pool: pool, vggForward: vggGpu)
          : await distsScoreParallel(a, b, w, h, pool: pool, vggForward: vggGpu);
      final cpuV = metric == 'lpips'
          ? await lpipsScoreParallel(a, b, w, h, pool: pool)
          : await distsScoreParallel(a, b, w, h, pool: pool);
      final relPy =
          pyV == null ? double.nan : (gpuV - pyV).abs() / pyV.abs();
      final relCpu = (gpuV - cpuV).abs() / cpuV.abs();
      print('NN_VGG_BENCH_PRECISION $metric 256x192 | gpu=$gpuV '
          'cpu=$cpuV python=$pyV | relErrVsPython=$relPy '
          'relErrVsCpu=$relCpu');
    }

    // 大图（1024×768，conv1_x 折叠纹素数 32HW ≥ 2^24 → 自动走分块路径，
    // 4 带）端到端精度对拍：验证 banded 链的 LPIPS/DISTS 分数 vs CPU 池
    // 与 Python 基线（验收口径：relErrVsPython ≤ 1e-3）。
    const bw = 1024, bh = 768;
    final ba = busyFrame(bw, bh);
    final bb = busyFrame(bw, bh, noisy: true);
    for (final metric in ['lpips', 'dists']) {
      final pyV = await pyRef(metric, ba, bb, bw, bh);
      final sw = Stopwatch()..start();
      final gpuV = metric == 'lpips'
          ? await lpipsScoreParallel(ba, bb, bw, bh,
              pool: pool, vggForward: vggGpu)
          : await distsScoreParallel(ba, bb, bw, bh,
              pool: pool, vggForward: vggGpu);
      final gpuMs = sw.elapsedMilliseconds;
      sw.reset();
      final cpuV = metric == 'lpips'
          ? await lpipsScoreParallel(ba, bb, bw, bh, pool: pool)
          : await distsScoreParallel(ba, bb, bw, bh, pool: pool);
      final cpuMs = sw.elapsedMilliseconds;
      final relPy =
          pyV == null ? double.nan : (gpuV - pyV).abs() / pyV.abs();
      final relCpu = (gpuV - cpuV).abs() / cpuV.abs();
      print('NN_VGG_BENCH_PRECISION $metric ${bw}x$bh (banded) | gpu=$gpuV '
          'cpu=$cpuV python=$pyV | relErrVsPython=$relPy '
          'relErrVsCpu=$relCpu | GPU ${gpuMs}ms CPU池 ${cpuMs}ms');
    }
  } finally {
    pool.dispose();
    vggGpu.dispose();
    g.dispose();
  }
}

/// busyFrame RGBA → LPIPS ScalingLayer 输出（常量同 lpips_dart.dart）。
NnTensor lpipsInput(Uint8List rgba, int width, int height) {
  const shift = [-0.030, -0.088, -0.188];
  const scale = [0.458, 0.448, 0.450];
  final s = width * height;
  final data = Float32List(3 * s);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    for (var i = 0, j = c; i < s; i++, j += 4) {
      data[base + i] = ((rgba[j] / 255.0) * 2.0 - 1.0 - shift[c]) / scale[c];
    }
  }
  return NnTensor(data, [1, 3, height, width]);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('nn gpu vgg bench')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await precision();
      await bench();
    } catch (e, st) {
      print('NN_VGG_BENCH_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
