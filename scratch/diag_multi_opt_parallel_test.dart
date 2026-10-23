// 一次性：平行惩罚开启后，Multi_band_EQ 的完整优化结果。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('multi opt', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_multi_band_eq_core/net.json')
            .readAsStringSync(),
      );
      final m = nl.modules.values.first;
      for (final layered in [true, false]) {
        final model = buildNetlistDiagramModel(
          m,
          layout: layered
              ? NlLayoutAlgorithm.layered
              : NlLayoutAlgorithm.compact,
        );
        final levels = model.flattened();
        final r = await optimizeNetlistRouting(
          levels,
          model.canvasSize,
          attempts: 6,
          onProgress: (_, _, _) {},
        );
        final d = computeNlRoutingDiagnostics(
          levels,
          model.canvasSize,
          routes: r.result.segments,
          junctions: r.result.junctions,
        );
        print(
          'OPT layered=$layered cross=${d.crossings} bends=${d.bends} '
          'p95=${d.bendP95} max=${d.bendMax} len=${d.length.toStringAsFixed(0)} '
          'parallel=${d.parallelPairs} violations=${d.violationCounts} '
          'fallback=${r.result.fallbackCount}',
        );
      }
    });
  });
}
