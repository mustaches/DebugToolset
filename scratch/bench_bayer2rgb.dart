// 基准：加载真实 IspFlow/Bayer2RGB.ispflow，逐节点计时（µs）。
// 运行: dart compile exe scratch/bench_bayer2rgb.dart -o scratch/bench_bayer2rgb.exe
//      scratch/bench_bayer2rgb.exe
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

Future<void> main() async {
  final json =
      jsonDecode(File('IspFlow/Bayer2RGB.ispflow').readAsStringSync())
          as Map<String, Object?>;
  final graph = IspGraph.fromJson(json);

  // 四个汇点：预览#1(n3)、预览#2(n8，最长链)、直方图#1(n55)、直方图#2(n56)。
  const sinks = ['n8', 'n3', 'n55', 'n56'];
  final merged = <String, int>{};
  for (final sink in sinks) {
    final chain = compileChain(graph, sink);
    final timings = <String, int>{};
    final sw = Stopwatch()..start();
    await runChainFrame(chain, 0, nodeTimingsUs: timings);
    sw.stop();
    print('--- 链 → $sink: ${chain.length} 节点, 整帧 ${sw.elapsedMilliseconds} ms');
    for (final op in chain) {
      final id = op['nodeId'] as String;
      final us = timings[id] ?? 0;
      merged[id] = (merged[id] ?? 0) + us;
      if (us > 0) {
        print('  $id  ${op['typeId']}'.padRight(34) +
            '${(us / 1000).toStringAsFixed(1).padLeft(9)} ms');
      }
    }
  }
  print('=== 各节点累计耗时（>100ms 标 *）===');
  final names = {for (final n in graph.nodes.values) n.id: n.name};
  final entries = merged.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  var total = 0;
  for (final e in entries) {
    total += e.value;
    final ms = e.value / 1000;
    print('${ms >= 100 ? '*' : ' '} ${e.key}  ${names[e.key] ?? ''}'
        .padRight(40) +
        '${ms.toStringAsFixed(1).padLeft(9)} ms');
  }
  print('合计 ${(total / 1000).toStringAsFixed(1)} ms');
}
