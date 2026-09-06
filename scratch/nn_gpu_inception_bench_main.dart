// InceptionV3 GPU 纹理驻留链（FID/KID patch 特征）的真实 GPU 基准入口：
//   flutter run -d windows -t scratch/nn_gpu_inception_bench_main.dart
// 在真实 Windows/Impeller 环境：
// 1. eval_set ref_0/test_0（256×192，2 patch）GPU 特征 vs torch 黄金值
//    （test/golden/inception_feats_golden.nnw）worstCos/worstRelL2；
// 2. 256×192 / 1024×768 / 1688×3000 的 GPU vs CPU 并行特征提取耗时；
// 3. eval_set 5 对图的 FID/KID 端到端：GPU 特征 vs CPU 特征 vs Python
//    桥接基线（既有口径：FID 相对误差 ≤1e-2，KID 同量级）。
// flutter test 环境为软件光栅，性能数值无意义；正确性测试在
// test/isp_nn_gpu_inception_test.dart。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_v3_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nnw_reader.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as img;

const evalDir = 'scratch/eval_set';
const goldenDir = 'test/golden';

/// PNG → RGBA8888（同 test/isp_fid_kid_dart_test.dart）。
Uint8List loadRgba(String path) {
  final image = img.decodePng(File(path).readAsBytesSync())!;
  final w = image.width, h = image.height;
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      final i = (y * w + x) * 4;
      rgba[i] = p.r.toInt();
      rgba[i + 1] = p.g.toInt();
      rgba[i + 2] = p.b.toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

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

/// 特征集合 vs 黄金值 [n,2048]：worstCos / worstRelL2。
(double, double) goldenStats(Float32List feats, Float32List golden) {
  final n = golden.length ~/ inceptionFeatureDim;
  var worstCos = 1.0, worstL2 = 0.0;
  for (var p = 0; p < n; p++) {
    var dot = 0.0, na = 0.0, nb = 0.0, d2 = 0.0;
    final off = p * inceptionFeatureDim;
    for (var i = 0; i < inceptionFeatureDim; i++) {
      final a = feats[off + i], b = golden[off + i];
      dot += a * b;
      na += a * a;
      nb += b * b;
      d2 += (a - b) * (a - b);
    }
    worstCos = math.min(worstCos, dot / math.sqrt(na * nb));
    worstL2 = math.max(worstL2, math.sqrt(d2) / math.sqrt(nb));
  }
  return (worstCos, worstL2);
}

/// FID/KID 端到端：5 对图特征（[gpuNet] 非空走 GPU 链）→ FID/KID 出分。
Future<(double, double)> fidKid(InceptionV3Gpu? gpuNet) async {
  final accRef = FidAccumulator();
  final accTest = FidAccumulator();
  final refFeats = <Float32List>[];
  final testFeats = <Float32List>[];
  for (var i = 0; i < 5; i++) {
    final rgbaR = loadRgba('$evalDir/ref_$i.png');
    final rgbaT = loadRgba('$evalDir/test_$i.png');
    final fr = await inceptionPatchFeaturesParallel(rgbaR, 256, 192,
        gpuNet: gpuNet);
    final ft = await inceptionPatchFeaturesParallel(rgbaT, 256, 192,
        gpuNet: gpuNet);
    accRef.addBatch(fr, 2);
    accTest.addBatch(ft, 2);
    refFeats.add(fr);
    testFeats.add(ft);
  }
  final refAll = Float32List(10 * fidFeatureDim);
  final testAll = Float32List(10 * fidFeatureDim);
  for (var i = 0; i < 5; i++) {
    refAll.setRange(
        i * 2 * fidFeatureDim, (i + 1) * 2 * fidFeatureDim, refFeats[i]);
    testAll.setRange(
        i * 2 * fidFeatureDim, (i + 1) * 2 * fidFeatureDim, testFeats[i]);
  }
  return (fidCompute(accRef, accTest), kidCompute(refAll, 10, testAll, 10));
}

/// Python 基线（桥接 --serve，add×10 + score，同 isp_fid_kid 端到端）。
Future<double?> pyScore(String metric) async {
  if (!PyIqaWorker.available) return null;
  final worker = PyIqaWorker.forMetric(metric);
  await worker.distReset();
  for (var i = 0; i < 5; i++) {
    await worker.distAdd('ref', '$evalDir/ref_$i.png');
    await worker.distAdd('test', '$evalDir/test_$i.png');
  }
  final s = await worker.distScore();
  return s?.$1;
}

Future<void> bench() async {
  if (!File(inceptionV3WeightsPath).existsSync()) {
    print('NN_INC_BENCH_ERROR 缺少权重 $inceptionV3WeightsPath');
    return;
  }
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    print('NN_INC_BENCH_ERROR backend 初始化失败');
    return;
  }
  var sw = Stopwatch()..start();
  final incGpu = await InceptionV3Gpu.load(g, inceptionV3WeightsPath);
  print('NN_INC_BENCH 权重上传 ${sw.elapsedMilliseconds}ms');

  try {
    // 1. 黄金值对拍（ref_0/test_0，各 2 patch）。
    if (File('$goldenDir/inception_feats_golden.nnw').existsSync() &&
        File('$evalDir/ref_0.png').existsSync()) {
      final reader = NnwReader.open('$goldenDir/inception_feats_golden.nnw');
      try {
        for (final (key, file) in [('ref_0.feats', 'ref_0.png'),
          ('test_0.feats', 'test_0.png')]) {
          final golden = reader.readTensor(key);
          final rgba = loadRgba('$evalDir/$file');
          sw = Stopwatch()..start();
          final feats =
              await inceptionPatchFeaturesParallel(rgba, 256, 192, gpuNet: incGpu);
          final ms = sw.elapsedMilliseconds;
          final (wc, wl2) = goldenStats(feats, golden.data);
          print('NN_INC_BENCH_GOLDEN $key: worstCos=$wc worstRelL2=$wl2 '
              '| GPU 2patch ${ms}ms');
        }
      } finally {
        reader.close();
      }
    }

    // 2. 耗时对比（GPU 串行 vs CPU patch 并行）。
    for (final (w, h) in [(256, 192), (1024, 768), (1688, 3000)]) {
      final a = busyFrame(w, h, noisy: true);
      await inceptionPatchFeaturesParallel(a, w, h); // CPU 预热
      sw = Stopwatch()..start();
      await inceptionPatchFeaturesParallel(a, w, h);
      final cpuMs = sw.elapsedMilliseconds;
      await inceptionPatchFeaturesParallel(a, w, h, gpuNet: incGpu); // 预热
      sw = Stopwatch()..start();
      await inceptionPatchFeaturesParallel(a, w, h, gpuNet: incGpu);
      final gpuMs = sw.elapsedMilliseconds;
      final n = inceptionPatchGrid(w, h).length;
      print('NN_INC_BENCH ${w}x$h ($n patch) | CPU并行 ${cpuMs}ms | '
          'GPU链 ${gpuMs}ms');
    }

    // 3. FID/KID 端到端（5 对图）。
    if (File('$evalDir/ref_4.png').existsSync()) {
      sw = Stopwatch()..start();
      final (gpuFid, gpuKid) = await fidKid(incGpu);
      final gpuMs = sw.elapsedMilliseconds;
      sw = Stopwatch()..start();
      final (cpuFid, cpuKid) = await fidKid(null);
      final cpuMs = sw.elapsedMilliseconds;
      final pyFid = await pyScore('fid');
      final pyKid = await pyScore('kid');
      String rel(double v, double? ref) =>
          ref == null ? 'nan' : '${(v - ref).abs() / ref.abs()}';
      print('NN_INC_BENCH_FIDKID FID: gpu=$gpuFid cpu=$cpuFid python=$pyFid '
          '| relErrGpuVsPython=${rel(gpuFid, pyFid)} '
          'relErrGpuVsCpu=${rel(gpuFid, cpuFid)}');
      print('NN_INC_BENCH_FIDKID KID: gpu=$gpuKid cpu=$cpuKid python=$pyKid '
          '| 出分+特征 GPU ${gpuMs}ms CPU ${cpuMs}ms');
    }
  } finally {
    incGpu.dispose();
    g.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('nn gpu inception bench')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await bench();
    } catch (e, st) {
      print('NN_INC_BENCH_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
