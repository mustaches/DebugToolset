// FPN 桥接路径耗时基准（readback → CPU applyFpn[quickselect] → upload）：
// flutter run -d windows -t scratch/bench_fpn_gpu.dart [--dart-define=W=4096 --dart-define=H=3072]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const kW = int.fromEnvironment('W', defaultValue: 1920);
const kH = int.fromEnvironment('H', defaultValue: 1080);

Future<void> bench() async {
  const w = kW, h = kH;
  final data = Uint16List(w * h);
  var s = 7;
  for (var i = 0; i < data.length; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    data[i] = 1023 & s;
  }
  final tex = await GpuPipeline.uploadPacked(data, w, h, 1);

  final sw = Stopwatch()..start();
  final bytes = await GpuPipeline.readbackBytes(tex);
  final tRead = sw.elapsedMicroseconds;
  sw.reset();
  final copy = bytes.buffer.asUint16List();
  applyFpn(copy,
      width: w, height: h, pattern: BayerPattern.rggb,
      row: true, col: true, maxCorr: 64);
  final tCpu = sw.elapsedMicroseconds;
  sw.reset();
  final up = await GpuPipeline.uploadPacked(copy, w, h, 1);
  final tUpload = sw.elapsedMicroseconds;
  print('FPN_BENCH ${w}x$h 桥接: read=${tRead / 1000}ms '
      'cpu=${tCpu / 1000}ms upload=${tUpload / 1000}ms '
      'total=${(tRead + tCpu + tUpload) / 1000}ms');
  tex.dispose();
  up.dispose();

  // 对照：纯 CPU applyFpn。
  final cpu = Uint16List.fromList(data);
  sw.reset();
  applyFpn(cpu,
      width: w, height: h, pattern: BayerPattern.rggb,
      row: true, col: true, maxCorr: 64);
  print('FPN_BENCH ${w}x$h 纯CPU(quickselect): ${sw.elapsedMicroseconds / 1000}ms');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('fpn bench')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await bench();
    } catch (e, st) {
      print('FPN_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  });
}
