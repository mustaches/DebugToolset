// 一次性：对比团/星拓扑在同一条网上的段数与长度。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('topo compare', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_eq6_axis/net.json').readAsStringSync(),
      );
      final module = nl.modules.values.firstWhere((m) => m.cells.length > 5);
      final model = buildNetlistDiagramModel(
        module,
        layout: NlLayoutAlgorithm.layered,
      );
      final sorted = [...model.wires]
        ..sort((a, b) => b.loads.length.compareTo(a.loads.length));
      for (final w in sorted.take(5)) {
        double len(NlNetTopology t) => nlStraightWireSegments(
          w,
          t,
        ).fold(0.0, (s, e) => s + (e.$2 - e.$1).distance);
        print(
          'wire=${w.label} loads=${w.loads.length} '
          'cliqueSeg=${nlStraightWireSegments(w, NlNetTopology.clique).length} '
          'starSeg=${nlStraightWireSegments(w, NlNetTopology.star).length} '
          'cliqueLen=${len(NlNetTopology.clique).toStringAsFixed(0)} '
          'starLen=${len(NlNetTopology.star).toStringAsFixed(0)}',
        );
      }
      final loadsHist = <int, int>{};
      for (final w in model.wires) {
        loadsHist[w.loads.length] = (loadsHist[w.loads.length] ?? 0) + 1;
      }
      print('loads histogram=$loadsHist');
    });
  });
}
