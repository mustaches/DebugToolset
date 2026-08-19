/// 临时定位：白光ISP流程逐级亮度轨迹，找出"整体发白"发生在哪一级。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

Future<void> main() async {
  final json = jsonDecode(
      await File('IspFlow/白光ISP流程.ispflow').readAsString())
      as Map<String, Object?>;
  final graph = IspGraph.fromJson(json);
  final chain = compileChain(graph, 'n15');
  final nameOf = {for (final op in chain) op['nodeId']: op['typeId']};

  final order = <String>[];
  final stats = <String, String>{};
  await runChainFrame(chain, 0,
      onNodeOutput: (nodeId, data, format, width, height) {
    if (stats.containsKey(nodeId)) return; // 末端节点会回调两次，取中间格式
    order.add(nodeId);
    final maxV = format == 'rgba' ? 255.0 : 1023.0;
    var sum = 0;
    var mx = 0;
    final step = data.length > 4096 ? data.length ~/ 4096 : 1;
    var n = 0;
    for (var i = 0; i < data.length; i += step) {
      sum += data[i];
      if (data[i] > mx) mx = data[i];
      n++;
    }
    stats[nodeId] =
        '$format ${width}x$height mean=${(sum / n / maxV * 100).toStringAsFixed(1)}% '
        'max=$mx/${maxV.toInt()}';
  });
  for (final id in order) {
    print('${(nameOf[id] ?? id).toString().padRight(16)} ${stats[id]}');
  }
  exit(0);
}
