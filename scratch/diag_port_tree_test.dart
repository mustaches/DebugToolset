// 涓€娆℃€э細妫€鏌?out_valid 绔彛涓嬬Щ鍚庡崟缃戝眬閮ㄩ噸甯冩槸鍚︽垚鍔熴€?import 'dart:io';

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
      nlShiftPin(port!, 30);
      final next = nlRerouteTreeWire(
        levels,
        model.canvasSize,
        routes,
        wire!,
      );
      print('next=${next != null} clean=${next == null ? null : nlRouteIsClean(next)} '
          'segments=${next?.segments[wire]?.length}');
      if (next != null) {
        for (final s in next.segments[wire] ?? const []) {
          print('  (${s.$1.dx},${s.$1.dy})->(${s.$2.dx},${s.$2.dy})');
        }
      }
    });
  });
}

