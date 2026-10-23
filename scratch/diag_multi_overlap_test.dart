// 一次性：复现 Multi_band_EQ 网表的硬约束，打印重叠线段与所属网。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('diag overlap', (tester) async {
    await tester.runAsync(() async {
      for (final path in [
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
        'scratch/ip_sch/isp_ip_multi_band_eq_core/net.json',
      ]) {
        final nl = YosysNetlist.parse(File(path).readAsStringSync());
        print('FILE $path modules=${nl.modules.keys.join(",")}');
        for (final m in nl.modules.values) {
          if (m.cells.isEmpty) continue;
          final model = buildNetlistDiagramModel(
            m,
            layout: NlLayoutAlgorithm.layered,
          );
          if (model.blocks.length < 5) continue;
          final routes = routeNetlistWires(
            model.flattened(),
            model.canvasSize,
          );
          final diag = computeNlRoutingDiagnostics(
            model.flattened(),
            model.canvasSize,
            routes: routes.segments,
            junctions: routes.junctions,
          );
          print(
            'MODULE ${m.name} cells=${m.cells.length} blocks=${model.blocks.length} '
            'cross=${diag.crossings} bends=${diag.bends} '
            'violations=${diag.violationCounts} fallback=${routes.fallbackCount}',
          );
          for (final v in diag.violations.where(
            (v) => v.kind == NlViolationKind.netOverlap,
          )) {
            print('  OVERLAP ${v.detail}');
          }
          // 列出所有水平段按 y 分组，找同 y 重叠的异网对。
          final byY = <int, List<(String, double, double)>>{};
          for (final e in routes.segments.entries) {
            for (final s in e.value) {
              if ((s.$1.dy - s.$2.dy).abs() > 0.01) continue;
              final key = (s.$1.dy * 100).round();
              byY
                  .putIfAbsent(key, () => [])
                  .add((
                    e.key.label,
                    s.$1.dx < s.$2.dx ? s.$1.dx : s.$2.dx,
                    s.$1.dx > s.$2.dx ? s.$1.dx : s.$2.dx,
                  ));
            }
          }
          for (final entry in byY.entries) {
            final list = entry.value;
            for (var i = 0; i < list.length; i++) {
              for (var j = i + 1; j < list.length; j++) {
                if (list[i].$1 == list[j].$1) continue;
                final overlap =
                    (list[i].$3 < list[j].$3 ? list[i].$3 : list[j].$3) -
                    (list[i].$2 > list[j].$2 ? list[i].$2 : list[j].$2);
                if (overlap > 0.01) {
                  print(
                    '  SEG y=${entry.key / 100} ${list[i].$1}[${list[i].$2},${list[i].$3}] '
                    'vs ${list[j].$1}[${list[j].$2},${list[j].$3}] overlap=$overlap',
                  );
                }
              }
            }
          }
        }
      }
    });
  });
}
