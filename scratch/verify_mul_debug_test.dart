// 一次性调试脚本：抓取乘法器测试流程链上各节点的中间输出，
// 定位乘法器两路输入实际取到的数据。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('抓取 n4 链各节点输出，分析乘法器输入来源', () async {
    final f = File('G:/DebugToolSet/IspFlow/乘法器测试流程.ispflow');
    final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    final graph = IspGraph.fromJson(m);
    const w = 5472, h = 3648;

    final outs = <String, List<int>>{};
    final fmts = <String, String>{};
    await runChainFrame(compileChain(graph, 'n4'), 0,
        onNodeOutput: (nodeId, data, format, width, height) {
      outs[nodeId] = data;
      fmts[nodeId] = format;
    });

    for (final id in ['n1', 'n2', 'n10', 'n13', 'n7', 'n4']) {
      // ignore: avoid_print
      print('$id: format=${fmts[id]} len=${outs[id]?.length}');
    }

    // E：n2 输出的边缘图（rgb 交织，取 0 通道）。
    final edgeRgb = outs['n2']!;
    // Y：n10 输出（应为 yuv 交织，取 0 通道）。
    final yuvData = outs['n10']!;
    // P：n7 乘法器输出（mono w*h）。
    final prod = outs['n7']!;

    // 采样若干边缘像素（E>0 处），比较 P 与 E、Y 的关系。
    var n = 0, matchE = 0, matchExY = 0, matchY = 0;
    for (var p = 0; p < w * h && n < 100000; p++) {
      final e = edgeRgb[p * 3];
      if (e == 0) continue;
      n++;
      final y = fmts['n10'] == 'yuv' ? yuvData[p * 3] : -1;
      final pv = prod[p];
      if (pv == e) matchE++;
      if (pv == y) matchY++;
      if (y >= 0 && (pv - e * y ~/ 255).abs() <= 1) matchExY++;
    }
    // ignore: avoid_print
    print('边缘像素采样 $n：P==E $matchE，P==Y $matchY，P≈E×Y/255 $matchExY');
  }, timeout: const Timeout.factor(20));
}
