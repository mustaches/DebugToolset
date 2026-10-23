// 一次性：端口对齐偏差诊断（compact vs layered）。
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('port alignment diag', (tester) async {
    await tester.runAsync(() async {
      final file = File('scratch/ip_sch/isp_ip_eq6_axis/net.json');
      final nl = YosysNetlist.parse(file.readAsStringSync());
      final module = nl.modules.values.firstWhere((m) => m.cells.length > 5);
      for (final algo in NlLayoutAlgorithm.values) {
        final model = buildNetlistDiagramModel(module, layout: algo);
        print('\n=== ${algo.name} canvas=${model.canvasSize}');
        var total = 0;
        var aligned = 0;
        for (final w in model.wires) {
          for (final l in w.loads) {
            if (w.from.isPort) {
              total++;
              if ((w.from.pos.dy - l.pos.dy).abs() <= 15) aligned++;
            }
            if (l.isPort) {
              total++;
              if ((l.pos.dy - w.from.pos.dy).abs() <= 15) aligned++;
            }
          }
        }
        print('TOTAL=$total ALIGNED=$aligned '
            'rate=${(aligned / total).toStringAsFixed(3)}');
        for (final w in model.wires) {
          final ports = <(String, Offset, Offset)>[];
          if (w.from.isPort) {
            for (final l in w.loads) {
              ports.add(('out ${w.from.port}->${l.port}', w.from.pos, l.pos));
            }
          }
          for (final l in w.loads) {
            if (!l.isPort) continue;
            ports.add(('in ${l.port}<-${w.from.port}', l.pos, w.from.pos));
          }
          for (final (label, a, b) in ports) {
            final dy = (a.dy - b.dy).abs();
            if (dy > 0.01) {
              print('$label dy=${dy.toStringAsFixed(1)} '
                  'a=${a.dy} b=${b.dy}');
            }
          }
        }
      }
    });
  });
}
