// 一次性：密集扇入/扇出走线与 6px 分支圆点预览。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('render dense fanout preview', () async {
    final cells = <String, Object>{};
    for (var s = 0; s < 4; s++) {
      cells['not_$s'] = {
        'type': r'$not',
        'parameters': <String, Object>{},
        'connections': {'A': 1, 'Y': 100 + s},
      };
      for (var k = 0; k < 4; k++) {
        cells['and_${s}_$k'] = {
          'type': r'$and',
          'parameters': <String, Object>{},
          'connections': {
            'A': 100 + s,
            'B': k.isEven ? 100 + ((s + 1) % 4) : 1,
            'Y': 200 + s * 4 + k,
          },
        };
      }
    }
    cells['or_final'] = {
      'type': r'$or',
      'parameters': <String, Object>{},
      'connections': {'A': 200, 'B': 201, 'Y': 999},
    };
    final json = jsonEncode({
      'modules': {
        'm': {
          'ports': {
            'i': {
              'direction': 'input',
              'bits': [1],
            },
            'o': {
              'direction': 'output',
              'bits': [999],
            },
          },
          'cells': cells,
          'netnames': <String, Object>{},
        },
      },
    });
    final model = buildNetlistDiagramModel(
      YosysNetlist.parse(json).module('m')!,
    );
    final svg = buildNetlistSvg(model, fontFamily: 'Arial');
    File('scratch/ip_sch/fanout_layout.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
    File('scratch/ip_sch/fanout_layout.png').writeAsBytesSync(png);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
