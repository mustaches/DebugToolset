// 一次性：Multi_band_EQ 单趟布线指标（改 A* 平行惩罚前后对比）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('multi current', (tester) async {
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
        final routes = routeNetlistWires(levels, model.canvasSize);
        final d = computeNlRoutingDiagnostics(
          levels,
          model.canvasSize,
          routes: routes.segments,
          junctions: routes.junctions,
        );
        print(
          'layered=$layered canvas=${model.canvasSize} cross=${d.crossings} '
          'bends=${d.bends} p95=${d.bendP95} max=${d.bendMax} '
          'len=${d.length.toStringAsFixed(0)} detour=${d.detour?.toStringAsFixed(3)} '
          'parallel=${d.parallelPairs} violations=${d.violationCounts}',
        );
      }
    });
  });
}
