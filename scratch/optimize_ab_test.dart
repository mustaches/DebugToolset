// 一次性：真实网表跑完整布线优化，记录结果与收敛语义。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('optimize real', (tester) async {
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
      final watch = Stopwatch()..start();
      final r = await optimizeNetlistRouting(
        levels,
        model.canvasSize,
        attempts: 6,
        onProgress: (_, _, _) {},
      );
      watch.stop();
      print(
        'OPT elapsed=${watch.elapsedMilliseconds}ms '
        'cross=${r.initialCrossings}->${r.crossings} '
        'bends=${r.initialBends}->${r.bends} '
        'len=${r.initialLength.toStringAsFixed(0)}->${r.length.toStringAsFixed(0)} '
        'moved=${r.movedBlocks} passes=${r.passes} converged=${r.converged} '
        'attempts=${r.attempts}',
      );
    });
  });
}
