// 一次性：真实网表的直线预览（团拓扑）SVG/PNG 快照，供目视验收布局。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_block_diagram.dart'
    show SchPalette;
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('straight preview snapshot', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    var segments = 0;
    for (final w in model.wires) {
      segments += nlStraightWireSegments(w).length;
    }
    // ignore: avoid_print
    print(
      'CANVAS ${model.canvasSize.width}x${model.canvasSize.height} '
      'blocks=${model.blocks.length} wires=${model.wires.length} '
      'segments=$segments',
    );
    final svg = buildNetlistSvg(model, palette: SchPalette.dark);
    File('scratch/nl_straight_final.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
    File('scratch/nl_straight_final.png').writeAsBytesSync(png);
  });
}
