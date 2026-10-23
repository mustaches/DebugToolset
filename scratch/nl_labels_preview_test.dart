// 一次性：实例名/类型名移入符号后的 SVG 预览。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('labels inside preview', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    final svg = buildNetlistSvg(model);
    final png = await rasterizeSvgPng(
      Uint8List.fromList(utf8.encode(svg)),
      scale: 1,
    );
    File('scratch/nl_labels_inside.png').writeAsBytesSync(png);
    // ignore: avoid_print
    print('SVG ${svg.length} bytes, png ${png.length} bytes');
  });
}
