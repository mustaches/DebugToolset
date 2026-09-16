// 优化 16 验证探针：LPIPS GPU 归约快路径（lpipsStatsPair）vs
// CPU 池路径的端到端分数与计时（含 norms/3 项统计正确性的间接验证）。
// flutter run scratch/lpips_stats_probe_main.dart -d windows --release
// （配合 run_bench_watchdog.sh，完成标记 LPIPS_STATS_DONE）
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';

Uint8List busyFrame(int w, int h, {bool noisy = false}) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      var r = (128 + 70 * math.sin(x / 3.1) * math.cos(y / 2.7)).toInt();
      var g = (128 + 70 * math.cos(x / 4.1) * math.sin(y / 3.3)).toInt();
      var b = (128 + 70 * math.sin((x - y) / 3.7)).toInt();
      if (noisy) {
        r = (r + (i * 31) % 61 - 30).clamp(0, 255);
        g = (g + ((i + 1) * 31) % 61 - 30).clamp(0, 255);
        b = (b + ((i + 2) * 31) % 61 - 30).clamp(0, 255);
      }
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<void> probeSize(Vgg16Gpu vgg, NnPool pool, int w, int h,
    {bool identical = false}) async {
  final a = busyFrame(w, h);
  final b = identical ? busyFrame(w, h) : busyFrame(w, h, noisy: true);
  var sw = Stopwatch()..start();
  final gpuV = await lpipsScoreParallel(a, b, w, h, pool: pool,
      vggForward: vgg);
  final gpuMs = sw.elapsedMilliseconds;
  sw.reset();
  final cpuV = await lpipsScoreParallel(a, b, w, h, pool: pool);
  final cpuMs = sw.elapsedMilliseconds;
  final diff = (gpuV - cpuV).abs();
  print('LPIPS_STATS ${w}x$h${identical ? "（同图）" : ""} | '
      'GPU归约 ${gpuMs}ms | CPU池 ${cpuMs}ms | '
      'gpu=$gpuV cpu=$cpuV |diff|=$diff');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('lpips stats probe')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      final g = await GpuNnBackend.tryCreate();
      if (g == null) {
        print('LPIPS_STATS_ERROR 无 GPU 后端');
      } else {
        final vgg = await Vgg16Gpu.load(g, lpipsVggWeightsPath);
        final pool = NnPool();
        await pool.start(math.max(2, Platform.numberOfProcessors - 4));
        // 完全相同图像：LPIPS 应为 0（归约路径的消减误差暴露检查）。
        await probeSize(vgg, pool, 256, 192, identical: true);
        await probeSize(vgg, pool, 256, 192);
        await probeSize(vgg, pool, 1024, 768);
        await probeSize(vgg, pool, 1688, 3000);
        print('LPIPS_STATS_DONE');
        pool.dispose();
        vgg.dispose();
        g.dispose();
      }
    } catch (e, st) {
      print('LPIPS_STATS_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
