// 一次性：重复跑优化，检查是否有非确定性/偶发 netOverlap。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('opt repeat', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_multi_band_eq_core/net.json')
            .readAsStringSync(),
      );
      final m = nl.modules.values.first;
      for (var run = 0; run < 5; run++) {
        final model = buildNetlistDiagramModel(
          m,
          layout: NlLayoutAlgorithm.layered,
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
          'RUN$run cross=${d.crossings} bends=${d.bends} '
          'len=${d.length.toStringAsFixed(0)} violations=${d.violationCounts} '
          'fallback=${r.result.fallbackCount}',
        );
        for (final v in d.violations) {
          print('   ${v.kind.name} ${v.detail}');
        }
      }
    });
  });
}
