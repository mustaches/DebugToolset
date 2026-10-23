// 一次性诊断：分层布局 + 正交布线下的同轴重叠来自哪些线段。
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('overlap diag', (tester) async {
    await tester.runAsync(() async {
      final file = File('scratch/ip_sch/isp_ip_eq6_axis/net.json');
      final nl = YosysNetlist.parse(file.readAsStringSync());
      final module = nl.modules.values.firstWhere((m) => m.cells.length > 5);
      final model = buildNetlistDiagramModel(
        module,
        layout: NlLayoutAlgorithm.layered,
      );
      final levels = model.flattened();
      final routes = routeNetlistWires(levels, model.canvasSize);
      final diag = computeNlRoutingDiagnostics(
        levels,
        model.canvasSize,
        routes: routes.segments,
        junctions: routes.junctions,
      );
      print('violations=${diag.violations.length}');
      for (final v in diag.violations) {
        print('\n=== ${v.kind.name} ${v.wires} at ${v.at} ${v.detail}');
        for (final name in v.wires.split(' / ')) {
          final w = diag.wires.firstWhere(
            (x) => x.name == name,
            orElse: () => diag.wires.first,
          );
          print('wire $name pins=${w.segments.length} segs');
          final near = w.segments.where((s) {
            final mid = (s.$1 + s.$2) / 2;
            return (mid - v.at).distance < 80;
          });
          for (final s in near) {
            print('  ${s.$1} -> ${s.$2}  len=${(s.$2 - s.$1).distance}');
          }
        }
        // 附近的块框与引脚。
        for (final level in levels) {
          for (final b in level.blocks) {
            final r = b.boxOrigin + level.offset;
            if ((r - v.at).distance < 120) {
              print('block ${b.id} box=$r size=${b.boxSize}');
            }
            for (final p in [...b.ins, ...b.outs]) {
              if ((p.pos + level.offset - v.at).distance < 40) {
                print('  pin ${b.id}/${p.port} pos=${p.pos + level.offset} '
                    'edge=${p.edge + level.offset}');
              }
            }
          }
        }
      }
    });
  });
}
