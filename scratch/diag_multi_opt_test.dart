// 一次性：跑 Multi_band_EQ 的完整布线优化，复现优化结果里的 netOverlap。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('opt overlap', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_multi_band_eq_core/net.json')
            .readAsStringSync(),
      );
      final m = nl.modules.values.first;
      final model = buildNetlistDiagramModel(
        m,
        layout: NlLayoutAlgorithm.layered,
      );
      final levels = model.flattened();
      final before = routeNetlistWires(levels, model.canvasSize);
      final d0 = computeNlRoutingDiagnostics(
        levels,
        model.canvasSize,
        routes: before.segments,
        junctions: before.junctions,
      );
      print(
        'BEFORE cross=${d0.crossings} bends=${d0.bends} '
        'violations=${d0.violationCounts}',
      );
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
        'AFTER cross=${d.crossings} bends=${d.bends} len=${d.length} '
        'violations=${d.violationCounts} fallback=${r.result.fallbackCount} '
        'moved=${r.movedBlocks} passes=${r.passes} converged=${r.converged}',
      );
      for (final v in d.violations) {
        print('  ${v.kind.name} ${v.detail}');
      }
    });
  });
}
