// 一次性：测量实际网表轨道数与走线长度。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('measure routing length', () {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    for (final b in model.blocks.take(8)) {
      print(
        'BLOCK ${b.title} origin=${b.origin} boxOrigin=${b.boxOrigin} '
        'boxSize=${b.boxSize} size=${b.size}',
      );
    }
    double length(NlWire w) =>
        w.segments.fold(0, (sum, s) => sum + (s.$2 - s.$1).distance);
    final total = model.wires.fold<double>(0, (sum, w) => sum + length(w));
    print(
      'METRIC tracks=${model.trackCount} '
      'zLoads=${model.zLoadCount} trackLoads=${model.trackLoadCount} '
      'totalLength=${total.toStringAsFixed(1)} wires=${model.wires.length}',
    );
    final longest = [...model.wires]
      ..sort((a, b) => length(b).compareTo(length(a)));
    for (final w in longest.take(8)) {
      print(
        'LONG ${w.from.ownerTitle}/${w.from.port} ${w.label} '
        'length=${length(w).toStringAsFixed(1)} loads=${w.loads.length}',
      );
    }
  });
}
