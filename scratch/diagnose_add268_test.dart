// 一次性：检查 ADD268 到 gt274/mux274 的位域与标签。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('diagnose ADD268 bit ranges', () {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    for (final title in ['add268', 'gt274', 'mux274']) {
      final block = model.blocks.firstWhere((b) => b.title == title);
      print('BLOCK $title');
      for (final p in [...block.ins, ...block.outs]) {
        print(
          '  PIN ${p.display} width=${p.width} bits=${p.bits.length} '
          'nets=${p.nets.map((n) => '${n.display}/${n.bits.length}').join('|')}',
        );
      }
    }
    for (final w in model.wires.where(
      (w) =>
          w.from.ownerTitle == 'add268' ||
          w.from.ownerTitle == 'gt274' ||
          w.from.ownerTitle == 'mux274' ||
          w.loads.any(
            (l) => l.ownerTitle == 'gt274' || l.ownerTitle == 'mux274',
          ),
    )) {
      print(
        'WIRE ${w.from.ownerTitle}/${w.from.port} label=${w.label} '
        'bits=${w.bits.length} fromBits=${w.from.bits.length} '
        'loads=${w.loads.map((l) => l.ownerTitle + '/' + l.display).join('|')}',
      );
      print('  actualBits=${w.bits}');
    }
  });
}
