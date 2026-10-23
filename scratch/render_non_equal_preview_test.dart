// 一次性：非等宽总线连接的源位域标签预览。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('render non-equal source range', () async {
    const json = r'''
    {"modules": {"m": {
      "ports": {},
      "cells": {
        "mux": {"type": "$mux", "parameters": {},
          "connections": {"A": 0, "B": 1, "S": 1,
                          "Y": [300,301,302,303,304,305,306,307,308,309,310,311,312,313,314,315,316]}},
        "sink": {"type": "$add", "parameters": {},
          "connections": {"A": [300,301,302,303,304,305,306,307], "B": 0, "Y": 400}}
      },
      "netnames": {
        "n1_hwrap": {"bits": [300,301,302,303,304,305,306,307,308,309,310,311,312,313,314,315,316]},
        "n1_res_h": {"bits": [300,301,302,303,304,305,306,307]}
      }
    }}}
    ''';
    final model = buildNetlistDiagramModel(
      YosysNetlist.parse(json).module('m')!,
    );
    final svg = buildNetlistSvg(model, fontFamily: 'Arial');
    File('scratch/ip_sch/non_equal_source_range.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
    File('scratch/ip_sch/non_equal_source_range.png').writeAsBytesSync(png);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
