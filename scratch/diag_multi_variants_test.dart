// 一次性：多配置跑 Multi_band_EQ 优化，定位 84/133 + netOverlap 的来源。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('opt variants', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_multi_band_eq_core/net.json')
            .readAsStringSync(),
      );
      final m = nl.modules.values.first;
      for (final layered in [true, false]) {
        for (final gap in [false, true]) {
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
            options: NlRouteOptOptions(variableRowGap: gap),
            onProgress: (_, _, _) {},
          );
          final d = computeNlRoutingDiagnostics(
            levels,
            model.canvasSize,
            routes: r.result.segments,
            junctions: r.result.junctions,
          );
          print(
            'CFG layered=$layered gap=$gap cells=${model.blocks.length} '
            'canvas=${model.canvasSize} cross=${d.crossings} bends=${d.bends} '
            'len=${d.length.toStringAsFixed(0)} violations=${d.violationCounts} '
            'fallback=${r.result.fallbackCount}',
          );
          for (final v in d.violations) {
            print('   ${v.kind.name} ${v.detail}');
          }
        }
      }
    });
  });
}
