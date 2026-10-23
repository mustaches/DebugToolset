// 一次性：单信号/总线最小间距修正后的实际网表预览。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('render clearance fixed core', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    final svg = buildNetlistSvg(model, fontFamily: 'Arial');
    File('scratch/ip_sch/clearance_fixed.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg), scale: 1.5);
    File('scratch/ip_sch/clearance_fixed.png').writeAsBytesSync(png);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
