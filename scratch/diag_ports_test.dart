// 一次性：列出端口对齐情况与 in_sof 等端口的实际走线。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('ports', (tester) async {
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
      final model = layout.model;
      final levels = model.flattened();
      final routes = await optimizeNetlistOptimizationPlaceholder(
        levels,
        model.canvasSize,
      );
      print('portBends=${nlPortBendCount(levels, routes.result)}');
      for (final level in levels) {
        for (final pin in level.ports) {
          if (!['in_sof', 'in_left', 'clk', 'rst_n', 'in_data'].contains(
            pin.port,
          )) {
            continue;
          }
          NlWire? wire;
          for (final w in level.wires) {
            if (identical(w.from, pin) ||
                w.loads.any((l) => identical(l, pin))) {
              wire = w;
              break;
            }
          }
          print(
            'PORT ${pin.port} pos=(${pin.pos.dx},${pin.pos.dy}) '
            'dir=${pin.dir} wire=${wire?.label} '
            'from=${wire == null ? null : (wire.from.pos.dx, wire.from.pos.dy)} '
            'loads=${wire == null ? null : [for (final l in wire.loads) (l.pos.dx, l.pos.dy)]}',
          );
          if (wire != null) {
            for (final s in routes.result.segments[wire] ?? const []) {
              print('  (${s.$1.dx},${s.$1.dy})->(${s.$2.dx},${s.$2.dy})');
            }
          }
        }
      }
    });
  });
}

Future<NlRoutingOptimizationResult> optimizeNetlistOptimizationPlaceholder(
  List<NlLevel> levels,
  dynamic canvas,
) => optimizeNetlistRouting(
  levels,
  canvas,
  attempts: 6,
  options: const NlRouteOptOptions(),
  onProgress: (_, _, _) {},
);
