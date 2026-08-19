/// 临时验证：加载两个 ICG 方案 .ispflow 流程图并实际执行帧 0。
/// 用法：dart run scratch/verify_icg_flows.dart（工作目录须为工程根，
/// 流程图内 RAW 源为相对路径）。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

Future<void> runFlow(String path, List<String> sinkIds) async {
  final json =
      jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
  final graph = IspGraph.fromJson(json);
  print('$path: 节点 ${graph.nodes.length}, 连接 ${graph.connections.length}');
  for (final sink in sinkIds) {
    final chain = compileChain(graph, sink);
    final srcs =
        chain.where((op) => sourceTypes.contains(op['typeId'])).length;
    print('  汇点 $sink: 链长 ${chain.length}, 源节点 $srcs, '
        '算子: ${chain.map((op) => op['typeId']).join(' -> ')}');
    final sw = Stopwatch()..start();
    final rgba = await runChainFrame(chain, 0);
    var mn = 255, mx = 0, sum = 0;
    for (var i = 0; i < rgba.length; i += 401 * 4) {
      final v = rgba[i] > rgba[i + 1]
          ? (rgba[i] > rgba[i + 2] ? rgba[i] : rgba[i + 2])
          : (rgba[i + 1] > rgba[i + 2] ? rgba[i + 1] : rgba[i + 2]);
      if (v < mn) mn = v;
      if (v > mx) mx = v;
      sum += v;
    }
    final n = rgba.length ~/ (401 * 4);
    print('    帧 0: RGBA ${rgba.length} 字节, 耗时 ${sw.elapsedMilliseconds}ms, '
        'RGB 峰值采样 min=$mn max=$mx mean=${(sum / n).toStringAsFixed(1)}');
  }
}

Future<void> main() async {
  await runFlow('IspFlow/白光ISP流程.ispflow', ['n15']);
  await runFlow('IspFlow/ICG荧光融合ISP流程.ispflow', ['n22', 'n24']);
  print('全部流程验证通过');
}
