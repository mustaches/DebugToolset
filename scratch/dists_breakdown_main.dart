// DISTS/VGG16 GPU 链两阶段分解计时（1688×3000，与生产同 API）：
// flutter run scratch/dists_breakdown_main.dart -d windows --release
// （配合 run_bench_watchdog.sh，完成标记 DISTS_BD_DONE）
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';

Uint8List busyFrame(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = (128 + 70 * math.sin(x / 3.1) * math.cos(y / 2.7)).toInt();
      rgba[i + 1] = (128 + 70 * math.cos(x / 4.1) * math.sin(y / 3.3)).toInt();
      rgba[i + 2] = (128 + 70 * math.sin((x - y) / 3.7)).toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

NnTensor simpleInput(Uint8List rgba, int w, int h) {
  final s = w * h;
  final data = Float32List(3 * s);
  for (var c = 0; c < 3; c++) {
    for (var i = 0, j = c; i < s; i++, j += 4) {
      data[c * s + i] = rgba[j] / 255.0;
    }
  }
  return NnTensor(data, [1, 3, h, w]);
}

Future<void> bench() async {
  const w = 1688, h = 3000;
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    print('DISTS_BD_ERROR 无 GPU 后端');
    return;
  }
  var sw = Stopwatch()..start();
  final vgg = await Vgg16Gpu.load(g, lpipsVggWeightsPath);
  print('DISTS_BD 权重上传 ${sw.elapsedMilliseconds}ms');

  final rgba = busyFrame(w, h);
  sw.reset();
  final x0 = simpleInput(rgba, w, h);
  final x1 = simpleInput(rgba, w, h);
  print('DISTS_BD 输入构造 ${sw.elapsedMilliseconds}ms');

  // 生产编排（优化 11）：submit0 → submit1 → download0 → download1
  sw.reset();
  final h0 = await vgg.forwardSubmit(x0, useL2Pooling: true);
  print('DISTS_BD submit0 ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final h1 = await vgg.forwardSubmit(x1, useL2Pooling: true);
  print('DISTS_BD submit1 ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final f0 = await vgg.forwardDownload(h0);
  print('DISTS_BD download0 ${sw.elapsedMilliseconds}ms '
      '(切片: ${f0.map((t) => t.data.length).join(',')})');
  sw.reset();
  final f1 = await vgg.forwardDownload(h1);
  print('DISTS_BD download1 ${sw.elapsedMilliseconds}ms');

  // 对照：单图串行 forward（无流水线）
  sw.reset();
  final fs = await vgg.forward(x0, useL2Pooling: true);
  print('DISTS_BD 单图串行 forward ${sw.elapsedMilliseconds}ms '
      '(切片: ${fs.map((t) => t.data.length).join(',')})');
  print('DISTS_BD_DONE');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('dists breakdown')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await bench();
    } catch (e, st) {
      print('DISTS_BD_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
