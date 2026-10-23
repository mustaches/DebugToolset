// 一次性：统计有多少网可走通道预布线（单/多负载、相邻一列）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('channel eligible', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_eq6_axis/net.json').readAsStringSync(),
      );
      final module = nl.modules.values.firstWhere((m) => m.cells.length > 5);
      final model = buildNetlistDiagramModel(
        module,
        layout: NlLayoutAlgorithm.layered,
      );
      final pinBlock = <NlPin, NlBlock>{};
      for (final b in model.blocks) {
        for (final p in [...b.ins, ...b.outs]) {
          pinBlock[p] = b;
        }
      }
      var single = 0, multi = 0, fanout = 0;
      for (final w in model.wires) {
        final fb = pinBlock[w.from];
        if (fb == null) continue;
        final same = w.loads.every(
          (l) => pinBlock[l]?.column == fb.column + 1,
        );
        if (!same) continue;
        if (w.loads.length == 1) {
          single++;
        } else {
          multi++;
        }
        if (w.loads.length > 1) fanout++;
      }
      print('eligible single=$single multi=$multi');
      print('all fanout=$fanout total=${model.wires.length}');
    });
  });
}
