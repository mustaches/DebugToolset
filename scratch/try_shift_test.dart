// 一次性：手工把 in_sof 上移，看看指标是否真的变好、为何没被采纳。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('try shift', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_multi_band_eq_core/net.json')
            .readAsStringSync(),
      );
      final m = nl.modules.values.first;
      final layout = await optimizeNetlistLayout(
        m,
        netlist: nl,
        topology: NlNetTopology.star,
        allowMirror: true,
        swapPins: true,
        maxRounds: 512,
        onProgress: (_) {},
      );
      final levels = layout.model.flattened();
      final base = await optimizeNetlistRouting(
        levels,
        layout.model.canvasSize,
        attempts: 6,
        options: const NlRouteOptOptions(),
        onProgress: (_, _, _) {},
      );
      final bm = nlRoutingMetrics(base.result);
      print('BASE cross=${bm.crossings} bends=${bm.bends} len=${bm.length}');
      NlPin? target;
      for (final level in levels) {
        for (final p in level.ports) {
          if (p.port == 'in_sof') target = p;
        }
      }
      print('pin=${target?.pos}');
      for (final dy in [-45.0, -15.0, 15.0]) {
        target!.pos += Offset(0, dy);
        target.edge += Offset(0, dy);
        final r = routeNetlistWires(
          levels,
          layout.model.canvasSize,
          orderMode: 0,
        );
        final mm = nlRoutingMetrics(r);
        print(
          'dy=$dy cross=${mm.crossings} bends=${mm.bends} len=${mm.length} '
          'fallback=${r.fallbackCount}',
        );
        target.pos -= Offset(0, dy);
        target.edge -= Offset(0, dy);
      }
    });
  });
}
