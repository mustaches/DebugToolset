// 一次性：把复现流程的布线结果导出 SVG/PNG，便于目视对比。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  testWidgets('render repro', (tester) async {
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
      final svg = buildNetlistSvg(
        model,
        autoRoutes: routes.result.segments,
        autoJunctions: routes.result.junctions,
      );
      File('scratch/repro.svg').writeAsStringSync(svg);
      final png = await rasterizeSvgPng(utf8.encode(svg), scale: 1);
      File('scratch/repro.png').writeAsBytesSync(png);
      print('written ${svg.length} bytes svg, ${png.length} png');
    });
  });
}
