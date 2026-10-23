// 一次性：真实网表上对比全量 / 增量布线指标的开销与一致性。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('incremental bench', (tester) async {
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
      final result = routeNetlistWires(levels, model.canvasSize);
      final entries = result.segments.entries.toList();
      final ids = <NlWire, int>{
        for (var i = 0; i < entries.length; i++) entries[i].key: i,
      };

      final full = nlRoutingMetrics(result);
      final inc = NlIncrementalRouteMetrics();
      for (final e in entries) {
        inc.upsert(ids[e.key]!, e.value, junctions: result.junctions[e.key] ?? const []);
      }
      expect(inc.snapshot().crossings, full.crossings);
      expect(inc.snapshot().bends, full.bends);
      expect(inc.snapshot().length, closeTo(full.length, 0.01));
      expect(inc.snapshot().bendP95, full.bendP95);

      const rounds = 40;
      final sw = Stopwatch()..start();
      for (var i = 0; i < rounds; i++) {
        nlRoutingMetrics(result);
      }
      sw.stop();
      final fullMs = sw.elapsedMicroseconds / 1000;

      final sw2 = Stopwatch()..start();
      for (var i = 0; i < rounds; i++) {
        final e = entries[i % entries.length];
        inc.upsert(
          ids[e.key]!,
          e.value,
          junctions: result.junctions[e.key] ?? const [],
        );
      }
      sw2.stop();
      final incMs = sw2.elapsedMicroseconds / 1000;
      print(
        'BENCH wires=${entries.length} full=${fullMs.toStringAsFixed(2)}ms '
        '(${(fullMs / rounds).toStringAsFixed(3)}ms/次) '
        'incremental=${incMs.toStringAsFixed(2)}ms '
        '(${(incMs / rounds).toStringAsFixed(3)}ms/次) '
        'speedup=${(fullMs / incMs).toStringAsFixed(1)}x',
      );
      print(
        'FINAL cross=${inc.crossings}/${full.crossings} '
        'bends=${inc.snapshot().bends}/${full.bends} '
        'len=${inc.length.toStringAsFixed(1)}/${full.length.toStringAsFixed(1)}',
      );
    });
  });
}
