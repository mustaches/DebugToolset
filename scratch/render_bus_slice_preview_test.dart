// 一次性：总线位段标签与单比特/总线混合线宽预览。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

Future<void> _save(NetlistDiagramModel model, String name) async {
  final svg = buildNetlistSvg(model, fontFamily: 'Arial');
  File('scratch/ip_sch/$name.svg').writeAsStringSync(svg);
  final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
  File('scratch/ip_sch/$name.png').writeAsBytesSync(png);
}

void main() {
  test('render bus slice previews', () async {
    final cells = <String, Object>{};
    for (var i = 0; i < 3; i++) {
      final bits = [for (var j = 0; j < 8; j++) 100 + i * 8 + j];
      cells['mux$i'] = {
        'type': r'$mux',
        'parameters': <String, Object>{},
        'connections': {'A': 0, 'B': 1, 'S': 1, 'Y': bits},
      };
      cells['sink$i'] = {
        'type': r'$add',
        'parameters': <String, Object>{},
        'connections': {'A': bits, 'B': 0, 'Y': 200 + i},
      };
    }
    final sliceJson = jsonEncode({
      'modules': {
        'm': {
          'ports': {
            'i': {
              'direction': 'input',
              'bits': [1],
            },
          },
          'cells': cells,
          'netnames': {
            'n1_res_l': {
              'bits': [for (var bit = 100; bit < 124; bit++) bit],
            },
          },
        },
      },
    });
    await _save(
      buildNetlistDiagramModel(YosysNetlist.parse(sliceJson).module('m')!),
      'bus_slices',
    );

    const mixedJson = r'''
    {"modules": {"m": {
      "ports": {},
      "cells": {
        "gt": {"type": "$gt", "parameters": {},
          "connections": {"A": 0, "B": 1, "Y": 50}},
        "mux": {"type": "$mux", "parameters": {},
          "connections": {"A": 0, "B": 1, "S": 1, "Y": [60,61,62]}},
        "sink": {"type": "$add", "parameters": {},
          "connections": {"A": [50,60,61,62], "B": 0, "Y": 70}}
      },
      "netnames": {
        "cmp": {"bits": [50]},
        "data_bus": {"bits": [60,61,62]},
        "mixed": {"bits": [50,60,61,62]}
      }
    }}}
    ''';
    await _save(
      buildNetlistDiagramModel(YosysNetlist.parse(mixedJson).module('m')!),
      'single_and_bus',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}
