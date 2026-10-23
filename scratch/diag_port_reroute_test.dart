// 一次性：检查 out_valid 端口下移后单网局部重布是否成功。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('port local reroute', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_multi_band_eq_core/net.json')
            .readAsStringSync(),
      );
      final m = nl.modules.values.first;
      final model = buildNetlistDiagramModel(m);
      final levels = model.flattened();
      final routes = routeNetlistWires(levels, model.canvasSize);
      NlPin? port;
      for (final level in levels) {
        for (final p in level.ports) {
          if (p.port == 'out_valid') port = p;
        }
      }
      print('port=${port?.pos}');
      NlWire? wire;
      for (final level in levels) {
        for (final w in level.wires) {
          if (w.loads.any((l) => identical(l, port))) wire = w;
        }
      }
      print('wire=${wire?.label} loads=${wire?.loads.length}');
      print('initial clean=${nlRouteIsClean(routes)} '
          'ovPairs=${nlRoutingOverlapPairCount(routes)}');
      final oldPos = port!.pos;
      nlShiftPin(port, 15);
      final next = nlReroutePortBranch(
        levels,
        model.canvasSize,
        routes,
        wire!,
        oldPos,
        port.pos,
      );
      print('next=${next != null} clean=${next == null ? null : nlRouteIsClean(next)} '
          'segments=${next?.segments[wire]?.length}');
      if (next != null) {
        bool overlap(List<(Offset, Offset)> a, List<(Offset, Offset)> b) {
          for (final s in a) {
            final ha = (s.$1.dy - s.$2.dy).abs() < 0.01;
            for (final t in b) {
              final hb = (t.$1.dy - t.$2.dy).abs() < 0.01;
              if (ha != hb) continue;
              if (ha && (s.$1.dy - t.$1.dy).abs() < 0.01) {
                final a0 = math.min(s.$1.dx, s.$2.dx);
                final a1 = math.max(s.$1.dx, s.$2.dx);
                final b0 = math.min(t.$1.dx, t.$2.dx);
                final b1 = math.max(t.$1.dx, t.$2.dx);
                if (math.min(a1, b1) - math.max(a0, b0) > 0.01) return true;
              } else if (!ha && (s.$1.dx - t.$1.dx).abs() < 0.01) {
                final a0 = math.min(s.$1.dy, s.$2.dy);
                final a1 = math.max(s.$1.dy, s.$2.dy);
                final b0 = math.min(t.$1.dy, t.$2.dy);
                final b1 = math.max(t.$1.dy, t.$2.dy);
                if (math.min(a1, b1) - math.max(a0, b0) > 0.01) return true;
              }
            }
          }
          return false;
        }

        final entries = next.segments.entries.toList();
        for (var i = 0; i < entries.length; i++) {
          for (var j = i + 1; j < entries.length; j++) {
            if (overlap(entries[i].value, entries[j].value)) {
              print('OVERLAP wireA=${identical(entries[i].key, wire)} '
                  'wireB=${identical(entries[j].key, wire)}');
              print('  A=${entries[i].value}');
              print('  B=${entries[j].value}');
            }
          }
        }
        for (final s in next.segments[wire] ?? const []) {
          print('  (${s.$1.dx},${s.$1.dy})->(${s.$2.dx},${s.$2.dy})');
        }
      }
    });
  });
}
