// 一次性：打印用户新红圈附近的线段与引脚。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('geom', (tester) async {
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
      final routes = await optimizeNetlistRouting(
        levels,
        model.canvasSize,
        attempts: 6,
        options: const NlRouteOptOptions(),
        onProgress: (_, _, _) {},
      );
      const targets = [
        (1440.0, 800.0),
        (700.0, 1350.0),
        (520.0, 1200.0),
      ];
      for (final t in targets) {
        print('=== target $t');
        for (final e in routes.result.segments.entries) {
          final near = e.value.any((s) => _distToSeg(t, s.$1, s.$2) < 120);
          if (!near) continue;
          print(
            'wire "${e.key.label}" from=(${e.key.from.pos.dx},${e.key.from.pos.dy}) '
            'loads=${[for (final l in e.key.loads) '(${l.pos.dx},${l.pos.dy})']}',
          );
          for (final s in e.value) {
            if (_distToSeg(t, s.$1, s.$2) < 120) {
              print('  (${s.$1.dx},${s.$1.dy})->(${s.$2.dx},${s.$2.dy})');
            }
          }
        }
      }
    });
  });
}

double _distToSeg((double, double) p, Offset a, Offset b) {
  final dx = b.dx - a.dx, dy = b.dy - a.dy;
  final len2 = dx * dx + dy * dy;
  if (len2 < 0.01) {
    return math.sqrt(
      math.pow(p.$1 - a.dx, 2) + math.pow(p.$2 - a.dy, 2),
    );
  }
  var t = ((p.$1 - a.dx) * dx + (p.$2 - a.dy) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final x = a.dx + t * dx, y = a.dy + t * dy;
  return math.sqrt(math.pow(p.$1 - x, 2) + math.pow(p.$2 - y, 2));
}
