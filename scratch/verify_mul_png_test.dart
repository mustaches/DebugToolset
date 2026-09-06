// 一次性验证脚本：运行乘法器测试流程，把预览#1（乘法器输出）、
// 边缘图（n2 out_mono）、Y 亮度（n13 输入）各导出 PNG 供人工查看。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/exporters.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('导出乘法器流程各节点出图 PNG', () async {
    final f = File('G:/DebugToolSet/IspFlow/乘法器测试流程.ispflow');
    final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    final graph = IspGraph.fromJson(m);

    // 预览#1 链（n4）：链末端默认色调映射出图。
    final chain = compileChain(graph, 'n4');
    final rgba = await runChainFrame(chain, 0);
    final w = 5472, h = 3648;
    await File('G:/DebugToolSet/scratch/mul_n4_out.png')
        .writeAsBytes(encodePngRgba(rgba, w, h));

    // 统计亮度分布，判断画面观感。
    final hist = List<int>.filled(256, 0);
    for (var i = 0; i < rgba.length; i += 4) {
      hist[rgba[i]]++;
    }
    var nonBlack = 0, over32 = 0, over128 = 0;
    for (var v = 1; v < 256; v++) {
      nonBlack += hist[v];
      if (v > 32) over32 += hist[v];
      if (v > 128) over128 += hist[v];
    }
    final total = w * h;
    // ignore: avoid_print
    print('预览#1 亮度分布：非黑 ${(100 * nonBlack / total).toStringAsFixed(1)}%，'
        '>32: ${(100 * over32 / total).toStringAsFixed(2)}%，'
        '>128: ${(100 * over128 / total).toStringAsFixed(2)}%');

    // 预览#2 链（n13）：Y 亮度图。
    final rgba2 = await runChainFrame(compileChain(graph, 'n13'), 0);
    await File('G:/DebugToolSet/scratch/mul_n13_y.png')
        .writeAsBytes(encodePngRgba(rgba2, w, h));
  }, timeout: const Timeout.factor(20));
}
