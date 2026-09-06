// 一次性验证脚本：加载用户的乘法器测试流程并运行预览#1 链。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('乘法器测试流程.ispflow 预览#1（乘法器输出）可运行且为灰度图', () async {
    final f = File('G:/DebugToolSet/IspFlow/乘法器测试流程.ispflow');
    final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    final graph = IspGraph.fromJson(m);
    // 预览#1 = n4（乘法器输出的汇点）。
    final chain = compileChain(graph, 'n4');
    final rgba = await runChainFrame(chain, 0);
    expect(rgba.length % 4, 0);
    var nonBlack = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      expect(rgba[i], rgba[i + 1], reason: 'mono 出图应灰度');
      expect(rgba[i + 1], rgba[i + 2]);
      if (rgba[i] > 0) nonBlack++;
    }
    // 边缘×亮度调制结果不应全黑。
    expect(nonBlack, greaterThan(0));
    // ignore: avoid_print
    print('预览#1 出图 ${rgba.length ~/ 4} 像素，非黑像素 $nonBlack');
  });
}
