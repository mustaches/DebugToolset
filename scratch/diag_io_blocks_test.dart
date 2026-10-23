// 一次性：查看端口块结构（是否每端口一块、块高度/间距）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('io blocks', (tester) async {
    await tester.runAsync(() async {
      final nl = YosysNetlist.parse(
        File('scratch/ip_sch/isp_ip_multi_band_eq_core/net.json')
            .readAsStringSync(),
      );
      final m = nl.modules.values.first;
      final model = buildNetlistDiagramModel(m);
      for (final b in model.blocks.where((b) => b.isIo)) {
        print(
          'IO "${b.title}" origin=(${b.boxOrigin.dx},${b.boxOrigin.dy}) '
          'size=${b.boxSize} pins=${[...b.ins, ...b.outs].length} '
          'names=${[for (final p in [...b.ins, ...b.outs]) '${p.port}@${p.pos.dy}']}',
        );
      }
      print('total blocks=${model.blocks.length}');
    });
  });
}
