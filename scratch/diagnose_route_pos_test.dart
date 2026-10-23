// 一次性：定位 routePos 检查中剩余 pin 节点竖线并输出预览。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  test('diagnose remaining pin node crossings', () async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final mb = state.graph.addNode('multi_band_eq', 0, 0);
    state.graph.nodes[mb]!.paramValues['codegenMode'] = 'lut_fixed';
    state.graph.groups.add(IspNodeGroup('g1', {mb}, name: 'eq'));
    final files = buildGroupIpFiles(
      state.graph,
      state.graph.groups.single,
      const IpGenOptions(vendor: IpVendor.generic),
    );
    final res = await extractSchematicNetlist(
      files,
      topName: schematicTopModule(files),
    );
    expect(res.success, isTrue, reason: res.log);
    final core = res.netlist!.modules.values.firstWhere(
      (m) => m.cells.length > 5,
    );
    final model = buildNetlistDiagramModel(core);
    for (final b in model.blocks.where(
      (b) =>
          b.title.startsWith('add26') ||
          b.title.startsWith('lt26') ||
          b.title.startsWith('rom24'),
    )) {
      print('CANDIDATE ${b.title} col=${b.column} row=${b.row}');
    }
    final svg = buildNetlistSvg(model);
    File('scratch/ip_sch/route_pos_preview.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg));
    File('scratch/ip_sch/route_pos_preview.png').writeAsBytesSync(png);
    for (final title in ['adff18516', 'adff18521', 'mux18494']) {
      final block = model.blocks.firstWhere((b) => b.title == title);
      print('BLOCK $title origin=${block.boxOrigin} size=${block.boxSize}');
      for (final p in [...block.ins, ...block.outs]) {
        print(
          '  PIN ${p.port} edge=${p.edge} pos=${p.pos} route=${p.routePos}',
        );
      }
      for (final w in model.wires.where((w) => w.touches(block))) {
        print('  WIRE ${w.label} from=${w.from.ownerTitle}/${w.from.port}');
        for (final l in w.loads) {
          print(
            '    LOAD ${l.ownerTitle}/${l.port} pos=${l.pos} route=${l.routePos}',
          );
        }
        for (final (a, b) in w.segments) {
          print('    ($a) -> ($b)');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
