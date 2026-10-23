// 一次性：把端到端渲染产出的 sch.svg 经 flutter_svg 光栅化为 PNG 预览。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';

void main() {
  testWidgets('render sch.svg to png', (tester) async {
    final raw = File(
            r'G:\DebugToolSet\scratch\ip_sch\isp_ip_multi_band_eq_top\sch_core.svg')
        .readAsStringSync();
    final bytes = utf8.encode(adaptNetlistsvgSvg(raw));
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        width: 1600,
        height: 1200,
        color: const Color(0xFFE8E8E8),
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: SvgPicture.memory(bytes, width: 1500),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await boundary.toImage(pixelRatio: 2);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File(r'G:\DebugToolSet\scratch\ip_sch\sch_core_preview.png')
        .writeAsBytesSync(png!.buffer.asUint8List());
  });
}
