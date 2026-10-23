// 一次性：检查红色路径对应的内部网绕行情况。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('diagnose red route candidates', () {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    const targets = {
      'add257',
      'add260',
      'gt259',
      'lt260',
      'mux260',
      'add267',
      'add268',
      'mul265',
      'mul266',
    };
    for (final b in model.blocks.where((b) => targets.contains(b.title))) {
      print(
        'BLOCK ${b.title} col=${b.column} row=${b.row} '
        'origin=${b.origin} size=${b.size} box=${b.boxOrigin}/${b.boxSize}',
      );
    }
    for (final w in model.wires.where(
      (w) =>
          targets.contains(w.from.ownerTitle) ||
          w.loads.any((l) => targets.contains(l.ownerTitle)),
    )) {
      double length(NlWire w) =>
          w.segments.fold(0.0, (sum, s) => sum + (s.$2 - s.$1).distance);
      print(
        'WIRE ${w.from.ownerTitle}/${w.from.port} ${w.label} '
        'length=${length(w).toStringAsFixed(1)} '
        'loads=${w.loads.map((l) => l.ownerTitle + '/' + l.display).join('|')}',
      );
      for (final (a, b) in w.segments) {
        print('  ($a) -> ($b)');
      }
    }
    double lengthOf(String owner) {
      final w = model.wires.singleWhere((w) => w.from.ownerTitle == owner);
      return w.segments.fold<double>(
        0,
        (sum, s) => sum + (s.$2 - s.$1).distance,
      );
    }

    expect(lengthOf('add260'), lessThan(1000));
    expect(lengthOf('lt260'), lessThan(600));
    expect(lengthOf('rom248'), lessThan(500));
  });
}
