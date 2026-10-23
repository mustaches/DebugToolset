// 一次性：只加宽指定列间隙后重跑优化，验证能否消掉 add260_Y 的台阶。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('widen', (tester) async {
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
      final baseModel = layout.model;
      final levels = baseModel.flattened();
      final base = await optimizeNetlistRouting(
        levels,
        baseModel.canvasSize,
        attempts: 6,
        options: const NlRouteOptOptions(),
        onProgress: (_, _, _) {},
      );
      final dm = nlRoutingMetrics(base.result);
      print('BASE cross=${dm.crossings} bends=${dm.bends} len=${dm.length}');
      // 找 add260_Y 的 from/load 所在列。
      final wire = baseModel.wires.firstWhere((w) => w.label == 'add260_Y');
      int? colOfPin(NlPin p) {
        for (final b in baseModel.blocks) {
          if ([...b.ins, ...b.outs].any((x) => identical(x, p))) {
            return b.column;
          }
        }
        return null;
      }

      final fc = colOfPin(wire.from);
      final lc = colOfPin(wire.loads.first);
      print('add260_Y fromCol=$fc loadCol=$lc');
      for (final gap in [
        {if (fc != null) fc: 1},
        {if (fc != null) fc: 2},
        {if (lc != null) lc: 1},
      ]) {
        final model = buildNetlistDiagramModel(
          m,
          layout: NlLayoutAlgorithm.compact,
          rowOrders: layout.rowOrders,
          mirroredBlocks: layout.mirroredBlocks,
          pinOrders: layout.pinOrders,
          columnGapExtra: gap,
        );
        final lv = model.flattened();
        final r = await optimizeNetlistRouting(
          lv,
          model.canvasSize,
          attempts: 6,
          options: const NlRouteOptOptions(),
          onProgress: (_, _, _) {},
        );
        final d = nlRoutingMetrics(r.result);
        print(
          'GAP $gap canvas=${model.canvasSize} cross=${d.crossings} '
          'bends=${d.bends} len=${d.length}',
        );
      }
    });
  });
}
