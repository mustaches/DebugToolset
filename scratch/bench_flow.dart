// 基准：加载指定 .ispflow，对指定汇点链逐节点计时（µs）。
// 运行: dart compile exe scratch/bench_flow.dart -o scratch/bench_flow.exe
//      scratch/bench_flow.exe [flow路径] [汇点nodeId]
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

Future<void> main(List<String> args) async {
  final flowPath =
      args.isNotEmpty ? args[0] : 'IspFlow/白光ISP流程.ispflow';
  final json =
      jsonDecode(File(flowPath).readAsStringSync()) as Map<String, Object?>;
  final graph = IspGraph.fromJson(json);
  // 未指定汇点：取第一个 preview 节点。
  var sink = args.length > 1 ? args[1] : null;
  sink ??= graph.nodes.values
      .firstWhere((n) => n.typeId == 'preview' || n.typeId == 'hsl_debugger')
      .id;

  final chain = compileChain(graph, sink);
  final names = {for (final n in graph.nodes.values) n.id: n.name};
  final timings = <String, int>{};
  final sw = Stopwatch()..start();
  await runChainFrame(chain, 0, nodeTimingsUs: timings);
  sw.stop();
  print('链 → $sink: ${chain.length} 节点, 整帧 ${sw.elapsedMilliseconds} ms');
  for (final op in chain) {
    final id = op['nodeId'] as String;
    final us = timings[id] ?? 0;
    final ms = us / 1000;
    print('${ms >= 50 ? '*' : ' '} $id ${op['typeId']} ${names[id] ?? ''}'
        .padRight(52) +
        '${ms.toStringAsFixed(1).padLeft(9)} ms');
  }
}
