// 一次性验证：乘法器测试流程的预览#1 链 GPU vs CPU 出图对比 + GPU 计时。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/exporters.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('预览#1 链 GPU 出图与 CPU 一致', () async {
    final f = File('G:/DebugToolSet/IspFlow/乘法器测试流程.ispflow');
    final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    final graph = IspGraph.fromJson(m);
    final chain = compileChain(graph, 'n4');

    // GPU 支持预判 + 执行（顺带捕获 n2 边缘图显示）。
    expect(GpuPipeline.isSupportedChain(chain), isTrue,
        reason: '乘法器流程主链应被 GPU 支持');
    final gpu = (await GpuPipeline.tryCreate())!;
    final sw = Stopwatch()..start();
    final result = await gpu.run(chain, 0,
        displayCaptures: {'n2': 'n2', 'n2#in': 'n1'});
    sw.stop();
    // ignore: avoid_print
    print('GPU 主链执行: ${sw.elapsedMilliseconds}ms');
    for (final e in result.timingsUs.entries) {
      final node = graph.nodes[e.key];
      // ignore: avoid_print
      print('  ${node?.name ?? e.key}: ${(e.value / 1000).toStringAsFixed(1)}ms');
    }

    final bd = await result.image.toByteData();
    final gpuRgba = bd!.buffer.asUint8List();
    await File('G:/DebugToolSet/scratch/mul_n4_gpu.png')
        .writeAsBytes(encodePngRgba(gpuRgba, result.width, result.height));

    // CPU 对照。
    final cpuRgba = await runChainFrame(chain, 0);
    expect(gpuRgba.length, cpuRgba.length);
    var maxDiff = 0;
    var diffCount = 0;
    var bigDiff = 0;
    var flips = 0;
    for (var i = 0; i < gpuRgba.length; i += 4) {
      final d = (gpuRgba[i] - cpuRgba[i]).abs();
      if (d > 0) diffCount++;
      if (d > 3) {
        bigDiff++;
        // 门限边界翻转特征：一侧为 0（rel 临界点左右判定不同）。
        if (gpuRgba[i] == 0 || cpuRgba[i] == 0) flips++;
      }
      if (d > maxDiff) maxDiff = d;
    }
    // ignore: avoid_print
    print('GPU vs CPU 出图：最大差 $maxDiff，不同像素 '
        '$diffCount/${gpuRgba.length ~/ 4}，差>3 的像素 $bigDiff'
        '（其中门限边界翻转 $flips）');
    // 浮点路径容差：大差像素必须全部是门限边界的 0/v 翻转，且占比极小
    // （float32 与 double 在 rel≈threshold 临界点判定不同所致）。
    expect(flips, bigDiff, reason: '大差像素应全为门限边界 0/v 翻转');
    expect(bigDiff, lessThan(gpuRgba.length ~/ 4 * 0.0001),
        reason: '门限边界翻转像素应极少');
  }, timeout: const Timeout.factor(20));
}
