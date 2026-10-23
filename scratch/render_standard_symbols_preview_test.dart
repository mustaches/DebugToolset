// 一次性：代表性网表的标准符号 SVG/PNG 预览（无外部工具链）。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

const _json = r'''
{"modules": {"gallery": {
  "ports": {"i": {"direction": "input", "bits": [1]},
            "o": {"direction": "output", "bits": [99]}},
  "cells": {
    "$and$g.v:1$1": {"type": "$and", "parameters": {},
      "connections": {"A": 1, "B": 1, "Y": 10}},
    "$or$g.v:2$2": {"type": "$or", "parameters": {},
      "connections": {"A": 10, "B": 10, "Y": 11}},
    "$xor$g.v:3$3": {"type": "$xor", "parameters": {},
      "connections": {"A": 11, "B": 1, "Y": 12}},
    "$xnor$g.v:4$4": {"type": "$xnor", "parameters": {},
      "connections": {"A": 12, "B": 1, "Y": 13}},
    "$not$g.v:5$5": {"type": "$not", "parameters": {},
      "connections": {"A": 13, "Y": 14}},
    "$mux$g.v:6$6": {"type": "$mux", "parameters": {},
      "connections": {"A": 14, "B": 1, "S": 1, "Y": 15}},
    "$add$g.v:7$7": {"type": "$add", "parameters": {},
      "connections": {"A": 15, "B": 1, "Y": 16}},
    "$gt$g.v:8$8": {"type": "$gt", "parameters": {},
      "connections": {"A": 16, "B": 1, "Y": 17}},
    "$shl$g.v:9$9": {"type": "$shl", "parameters": {},
      "connections": {"A": 17, "B": 1, "Y": 18}},
    "$adff$g.v:10$10": {"type": "$adff",
      "parameters": {"CLK_POLARITY": 1, "ARST_POLARITY": 0},
      "connections": {"D": 18, "CLK": 1, "ARST": 1, "Q": 19}},
    "$memrd$g.v:11$11": {"type": "$memrd", "parameters": {"MEMID": "demo_rom"},
      "connections": {"ADDR": 19, "EN": 1, "CLK": 1, "DATA": 20}},
    "$tribuf$g.v:12$12": {"type": "$tribuf", "parameters": {},
      "connections": {"A": 20, "EN": 1, "Y": 99}}
  },
  "netnames": {"i": {"bits": [1]}, "o": {"bits": [99]}}
}}}
''';

void main() {
  test('render representative standard symbols', () async {
    final module = YosysNetlist.parse(_json).module('gallery')!;
    final model = buildNetlistDiagramModel(module);
    final svg = buildNetlistSvg(model, fontFamily: 'Arial');
    File('scratch/ip_sch/standard_symbols.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
    File('scratch/ip_sch/standard_symbols.png').writeAsBytesSync(png);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('render actual Canvas standard symbols', (tester) async {
    final module = YosysNetlist.parse(_json).module('gallery')!;
    final model = buildNetlistDiagramModel(module);
    final key = GlobalKey();
    tester.view.physicalSize = model.canvasSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: NetlistDiagram(model: model),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      'scratch/ip_sch/standard_symbols_canvas.png',
    ).writeAsBytesSync(data!.buffer.asUint8List());
  });
}
