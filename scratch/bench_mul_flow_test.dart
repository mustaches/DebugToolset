// 一次性基准：测量乘法器测试流程各预览链与逐节点耗时，定位瓶颈。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('乘法器流程逐链/逐节点耗时', () async {
    final f = File('G:/DebugToolSet/IspFlow/乘法器测试流程.ispflow');
    final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    final graph = IspGraph.fromJson(m);

    for (final sink in ['n2', 'n13', 'n4']) {
      final chain = compileChain(graph, sink);
      final timings = <String, int>{};
      final sw = Stopwatch()..start();
      await runChainFrame(chain, 0, nodeTimingsUs: timings);
      sw.stop();
      final gpuOk = GpuPipeline.isSupportedChain(chain);
      // ignore: avoid_print
      print('链 → $sink：${sw.elapsedMilliseconds}ms，GPU 可执行: $gpuOk');
      for (final e in timings.entries) {
        final node = graph.nodes[e.key];
        // ignore: avoid_print
        print('  ${node?.name ?? e.key} (${node?.typeId}): '
            '${(e.value / 1000).toStringAsFixed(0)}ms');
      }
    }
  }, timeout: const Timeout.factor(20));
}
