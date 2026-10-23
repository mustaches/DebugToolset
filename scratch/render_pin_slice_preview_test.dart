// 一次性：多驱动总线输入按位域拆分针脚预览。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('render split input pin fields', () async {
    final cells = <String, Object>{};
    for (var i = 0; i < 3; i++) {
      cells['mux$i'] = {
        'type': r'$mux',
        'parameters': <String, Object>{},
        'connections': {
          'A': 0,
          'B': 1,
          'S': 1,
          'Y': [for (var j = 0; j < 8; j++) 100 + i * 8 + j],
        },
      };
    }
    cells['sink'] = {
      'type': r'$mux',
      'parameters': <String, Object>{},
      'connections': {
        'A': 0,
        'B': [for (var bit = 100; bit < 124; bit++) bit],
        'S': 1,
        'Y': 200,
      },
    };
    final json = jsonEncode({
      'modules': {
        'm': {
          'ports': <String, Object>{},
          'cells': cells,
          'netnames': {
            'res_l': {
              'bits': [for (var bit = 100; bit < 108; bit++) bit],
            },
            'res_s': {
              'bits': [for (var bit = 108; bit < 116; bit++) bit],
            },
            'res_h': {
              'bits': [for (var bit = 116; bit < 124; bit++) bit],
            },
          },
        },
      },
    });
    final model = buildNetlistDiagramModel(
      YosysNetlist.parse(json).module('m')!,
    );
    final svg = buildNetlistSvg(model, fontFamily: 'Arial');
    File('scratch/ip_sch/mux4670_pin_slices.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
    File('scratch/ip_sch/mux4670_pin_slices.png').writeAsBytesSync(png);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
