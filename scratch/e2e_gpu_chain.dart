// GPU 链端到端验证：
// flutter run -d windows -t scratch/e2e_gpu_chain.dart [--dart-define=FLOW=... --dart-define=SINK=...]
// 1) 冷/热各跑一次最长链打印逐节点耗时；
// 2) 逐前缀二分对比 GPU vs CPU 色调映射结果，定位数值分歧节点。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const kFlow =
    String.fromEnvironment('FLOW', defaultValue: 'IspFlow/Bayer2RGB.ispflow');
const kSink = String.fromEnvironment('SINK', defaultValue: 'n8');
const kBisect = bool.fromEnvironment('BISECT', defaultValue: true);

Future<void> compareRun(GpuPipeline gpu, List<Map<String, Object?>> chain,
    String tag) async {
  final sw = Stopwatch()..start();
  final result = await gpu.run(chain, 0);
  final gpuMs = sw.elapsedMilliseconds;
  final gpuRgba = await GpuPipeline.readbackBytes(result.image);
  result.image.dispose();
  sw.reset();
  final cpuRgba = await runChainFrame(chain, 0);
  final cpuMs = sw.elapsedMilliseconds;
  var maxDiff = 0;
  var over2 = 0;
  for (var i = 0; i < gpuRgba.length; i++) {
    final d = (gpuRgba[i] - cpuRgba[i]).abs();
    if (d > maxDiff) maxDiff = d;
    if (d > 2) over2++;
  }
  print('E2E $tag: GPU ${gpuMs}ms CPU ${cpuMs}ms maxDiff=$maxDiff '
      'over2=$over2 (${(over2 / gpuRgba.length * 100).toStringAsFixed(3)}%)');
}

Future<void> bench() async {
  final json = jsonDecode(File(kFlow).readAsStringSync())
      as Map<String, Object?>;
  final graph = IspGraph.fromJson(json);
  final chain = compileChain(graph, kSink);
  print('E2E isSupportedChain=${GpuPipeline.isSupportedChain(chain)}');
  final gpu = await GpuPipeline.tryCreate();
  if (gpu == null) {
    print('E2E_ERROR GPU shader 加载失败');
    return;
  }

  // 冷跑（含各 shader 首次编译）。显示捕获/回读端口为 Bayer2RGB 专用，
  // 其它流程置空。
  final captures = kSink == 'n8'
      ? const {'n3': 'n1', 'n21': 'n21', 'n21#in': 'n22'}
      : const <String, String>{};
  final ports = kSink == 'n8'
      ? const {'n36:out_y', 'n49:out_mono'}
      : const <String>{};
  var sw = Stopwatch()..start();
  var result = await gpu.run(chain, 0,
      displayCaptures: captures, rgbaReadbackPorts: ports);
  print('E2E 冷跑 ${sw.elapsedMilliseconds}ms，逐节点:');
  result.timingsUs.forEach((id, us) {
    print('  $id ${(us / 1000).toStringAsFixed(1)}ms');
  });
  // 热跑（shader 已编译）。
  sw.reset();
  result = await gpu.run(chain, 0,
      displayCaptures: captures, rgbaReadbackPorts: ports);
  print('E2E 热跑 ${sw.elapsedMilliseconds}ms，逐节点:');
  result.timingsUs.forEach((id, us) {
    print('  $id ${(us / 1000).toStringAsFixed(1)}ms');
  });

  if (!kBisect) {
    await compareRun(gpu, chain, '全链');
    return;
  }
  // 逐前缀二分定位分歧（处理节点子序列，跳过汇点）。
  final procLen = chain.length - 1;
  for (var k = 2; k <= procLen; k++) {
    final sub = chain.sublist(0, k);
    await compareRun(gpu, sub, '前缀→${sub.last['nodeId']}(${sub.last['typeId']})');
  }
  // 全链（含 gamma 节点出图参数）。
  await compareRun(gpu, chain, '全链');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('gpu e2e')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await bench();
    } catch (e, st) {
      print('E2E_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  });
}
