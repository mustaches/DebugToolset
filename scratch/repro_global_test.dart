// 一次性：复现用户“布局优化 → 自动布线”流程，找小 U 形/断头/回折。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('repro', (tester) async {
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
        allowGlobalReorder: true,
        longWireWeight: 0.5,
        swapPins: true,
        maxRounds: 512,
        onProgress: (_) {},
      );
      print(
        'LAYOUT cells=${layout.nodes} len=${layout.initialLength.toStringAsFixed(0)}'
        '->${layout.length.toStringAsFixed(0)} rounds=${layout.rounds} '
        'canvas=${layout.model.canvasSize}',
      );
      final model = layout.model;
      final levels = model.flattened();
      final routes = await optimizeNetlistRouting(
        levels,
        model.canvasSize,
        attempts: 6,
        options: const NlRouteOptOptions(),
        onProgress: (_, _, _) {},
      );
      final d = computeNlRoutingDiagnostics(
        levels,
        model.canvasSize,
        routes: routes.result.segments,
        junctions: routes.result.junctions,
      );
      print(
        'ROUTE cross=${d.crossings} bends=${d.bends} len=${d.length.toStringAsFixed(0)} '
        'violations=${d.violationCounts} fallback=${routes.result.fallbackCount}',
      );

      var spurs = 0;
      var backtracks = 0;
      var loops = 0;
      for (final e in routes.result.segments.entries) {
        final pins = <(int, int)>{
          ((e.key.from.pos.dx * 100).round(), (e.key.from.pos.dy * 100).round()),
          for (final l in e.key.loads)
            ((l.pos.dx * 100).round(), (l.pos.dy * 100).round()),
        };
        final deg = <(int, int), int>{};
        for (final s in e.value) {
          for (final p in [s.$1, s.$2]) {
            final key = ((p.dx * 100).round(), (p.dy * 100).round());
            deg[key] = (deg[key] ?? 0) + 1;
          }
        }
        for (final ent in deg.entries) {
          if (ent.value == 1 && !pins.contains(ent.key)) {
            spurs++;
            print(
              'SPUR ${e.key.label} at (${ent.key.$1 / 100},${ent.key.$2 / 100})',
            );
          }
        }
        // 回折：连续两段方向相反。
        for (var i = 0; i + 1 < e.value.length; i++) {
          final a = e.value[i], b = e.value[i + 1];
          final h1 = (a.$1.dy - a.$2.dy).abs() < 0.01;
          final h2 = (b.$1.dy - b.$2.dy).abs() < 0.01;
          if (h1 != h2) continue;
          if (h1) {
            final d1 = (a.$2.dx - a.$1.dx).sign;
            final d2 = (b.$2.dx - b.$1.dx).sign;
            if (d1 != d2 && (a.$2.dx - b.$1.dx).abs() < 0.01) backtracks++;
          } else {
            final d1 = (a.$2.dy - a.$1.dy).sign;
            final d2 = (b.$2.dy - b.$1.dy).sign;
            if (d1 != d2 && (a.$2.dy - b.$1.dy).abs() < 0.01) backtracks++;
          }
        }
        // 小矩形环：连续 4 段回到起点。
        final pts = <(double, double)>[];
        for (final s in e.value) {
          if (pts.isEmpty) pts.add((s.$1.dx, s.$1.dy));
          pts.add((s.$2.dx, s.$2.dy));
        }
        for (var i = 0; i + 4 < pts.length; i++) {
          final dx = (pts[i].$1 - pts[i + 4].$1).abs();
          final dy = (pts[i].$2 - pts[i + 4].$2).abs();
          if (dx < 0.01 && dy < 0.01) {
            loops++;
            print(
              'LOOP ${e.key.label} at (${pts[i].$1},${pts[i].$2}) '
              'size=${_bbox(pts.sublist(i, i + 5))}',
            );
          }
        }
      }
      print('spurs=$spurs backtracks=$backtracks loops=$loops');
    });
  });
}

String _bbox(List<(double, double)> pts) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pts) {
    minX = math.min(minX, p.$1);
    minY = math.min(minY, p.$2);
    maxX = math.max(maxX, p.$1);
    maxY = math.max(maxY, p.$2);
  }
  return '${(maxX - minX).toStringAsFixed(0)}x${(maxY - minY).toStringAsFixed(0)}';
}
