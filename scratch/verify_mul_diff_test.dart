// 一次性验证脚本：对比 预览#1（乘法器输出）与 高频边缘提取节点
// 自身预览（n2 链出图）是否一致。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/exporters.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('对比预览#1 与 n2 边缘图', () async {
    final f = File('G:/DebugToolSet/IspFlow/乘法器测试流程.ispflow');
    final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    final graph = IspGraph.fromJson(m);
    const w = 5472, h = 3648;

    final rgbaMul = await runChainFrame(compileChain(graph, 'n4'), 0);
    final rgbaEdge = await runChainFrame(compileChain(graph, 'n2'), 0);
    await File('G:/DebugToolSet/scratch/mul_n2_edge.png')
        .writeAsBytes(encodePngRgba(rgbaEdge, w, h));

    var same = 0, diff = 0, edgeNonZero = 0;
    for (var i = 0; i < rgbaMul.length; i += 4) {
      if (rgbaEdge[i] > 0) edgeNonZero++;
      if (rgbaMul[i] == rgbaEdge[i]) {
        same++;
      } else {
        diff++;
      }
    }
    final total = w * h;
    // ignore: avoid_print
    print('n2 边缘图非黑 ${(100 * edgeNonZero / total).toStringAsFixed(1)}%；'
        '预览#1 与边缘图相同像素 ${(100 * same / total).toStringAsFixed(1)}%，'
        '不同 ${(100 * diff / total).toStringAsFixed(1)}%');
  }, timeout: const Timeout.factor(20));
}
