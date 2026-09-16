// 优化 15 验证探针：Vgg16Gpu.channelStatsPair（GPU 归约）vs
// forwardDownload + CPU 逐元素统计 的逐通道对比与计时。
// flutter run scratch/dists_stats_probe_main.dart -d windows --release
// （配合 run_bench_watchdog.sh，完成标记 DISTS_STATS_DONE）
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_dart.dart';
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

/// CPU 逐通道统计（fp64，同 dists 打分头的累加口径）。
Float64List cpuStats(NnTensor a, NnTensor b) {
  final c = a.channels, s = a.height * a.width;
  final out = Float64List(c * 5);
  for (var ch = 0; ch < c; ch++) {
    final base = ch * s;
    var sa = 0.0, sa2 = 0.0, sb = 0.0, sb2 = 0.0, sab = 0.0;
    for (var i = 0; i < s; i++) {
      final x = a.data[base + i];
      final y = b.data[base + i];
      sa += x;
      sa2 += x * x;
      sb += y;
      sb2 += y * y;
      sab += x * y;
    }
    out[ch * 5] = sa;
    out[ch * 5 + 1] = sa2;
    out[ch * 5 + 2] = sb;
    out[ch * 5 + 3] = sb2;
    out[ch * 5 + 4] = sab;
  }
  return out;
}

Future<void> probeSize(GpuNnBackend g, Vgg16Gpu vgg, int w, int h) async {
  final a = busyFrame(w, h);
  final b = busyFrame(w, h, noisy: true);
  final x0 = simpleInput(a, w, h);
  final x1 = simpleInput(b, w, h);

  var sw = Stopwatch()..start();
  final h0 = await vgg.forwardSubmit(x0, useL2Pooling: true);
  final h1 = await vgg.forwardSubmit(x1, useL2Pooling: true);
  final submitMs = sw.elapsedMilliseconds;
  sw.reset();
  final stats = await vgg.channelStatsPair(h0, h1);
  final statsMs = sw.elapsedMilliseconds;

  sw.reset();
  final f0 = await vgg.forward(x0, useL2Pooling: true);
  final f1 = await vgg.forward(x1, useL2Pooling: true);
  final serialMs = sw.elapsedMilliseconds;

  var worstRel = 0.0;
  String worstDesc = '';
  for (var k = 0; k < 5; k++) {
    final ref = cpuStats(f0[k], f1[k]);
    final st = stats[k];
    for (var i = 0; i < ref.length; i++) {
      final d = (st.sums[i] - ref[i]).abs();
      final rel = d / (ref[i].abs() + 1e-12);
      // 绝对差同样关注（均值类统计过零时相对差失真）
      final score = d < 1e-6 ? 0.0 : rel;
      if (score > worstRel) {
        worstRel = score;
        worstDesc = 'slice$k idx$i gpu=${st.sums[i]} cpu=${ref[i]}';
      }
    }
  }
  print('DISTS_STATS ${w}x$h | submit ${submitMs}ms | '
      'channelStatsPair ${statsMs}ms | 串行 forward 对照 ${serialMs}ms | '
      'worstRel=$worstRel ($worstDesc)');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('dists stats probe')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      final g = await GpuNnBackend.tryCreate();
      if (g == null) {
        print('DISTS_STATS_ERROR 无 GPU 后端');
      } else {
        final vgg = await Vgg16Gpu.load(g, lpipsVggWeightsPath);
        await probeSize(g, vgg, 256, 192);
        await probeSize(g, vgg, 1024, 768);
        await probeSize(g, vgg, 1688, 3000);
        print('DISTS_STATS_DONE');
        vgg.dispose();
        g.dispose();
      }
    } catch (e, st) {
      print('DISTS_STATS_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
