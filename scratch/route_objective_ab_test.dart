// 一次性 A/B：严格字典序 vs ε-字典序会选中哪个布线候选。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_route_objective.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('objective A/B', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_eq6_axis/net.json').readAsStringSync(),
      );
      final module = nl.modules.values.firstWhere((m) => m.cells.length > 5);
      final model = buildNetlistDiagramModel(
        module,
        layout: NlLayoutAlgorithm.layered,
      );
      final levels = model.flattened();
      final candidates = <(String, NlRouteScore)>[];
      for (var mode = 0; mode <= 6; mode++) {
        for (final near in [false, true]) {
          final routes = routeNetlistWires(
            levels,
            model.canvasSize,
            orderMode: mode,
            nearLoadFirst: near,
          );
          final diag = computeNlRoutingDiagnostics(
            levels,
            model.canvasSize,
            routes: routes.segments,
            junctions: routes.junctions,
          );
          final score = NlRouteScore.fromDiagnostics(diag);
          candidates.add(('m$mode${near ? '_near' : ''}', score));
          print(
            '${candidates.last.$1}: cross=${score.crossings} '
            'bends=${score.bends} p95=${score.bendP95} '
            'detour=${score.detour.toStringAsFixed(3)} '
            'parallel=${score.parallelPairs} '
            'density=${score.densityPeak.toStringAsFixed(2)} '
            'legal=${score.legal} violations=${diag.violationCounts} '
            'fallback=${routes.fallbackCount}',
          );
        }
      }

      (String, NlRouteScore) best(NlObjectiveConfig cfg, String tag) {
        var b = candidates.first;
        for (final c in candidates.skip(1)) {
          if (compareNlRouteScores(c.$2, b.$2, config: cfg) < 0) b = c;
        }
        print(
          'BEST[$tag] ${b.$1} cross=${b.$2.crossings} bends=${b.$2.bends} '
          'p95=${b.$2.bendP95} detour=${b.$2.detour.toStringAsFixed(3)}',
        );
        return b;
      }

      final strict = best(NlObjectiveConfig.strict, 'strict');
      final eps = best(const NlObjectiveConfig(), 'epsilon');
      print('different=${strict.$1 != eps.$1}');
    });
  });
}
