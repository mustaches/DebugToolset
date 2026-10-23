// 一次性：框图渲染预览（PNG 输出目检）。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/ip_gen_plan.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_block_diagram.dart';

void main() {
  testWidgets('render block diagram to png', (tester) async {
    final text =
        File('IspFlow/多段色彩均衡器.ispflow').readAsStringSync();
    final graph =
        IspGraph.fromJson(jsonDecode(text) as Map<String, Object?>);
    final group = graph.groups.single;
    final plan = planGroupIp(
        graph, group, const IpGenOptions(vendor: IpVendor.generic));
    final model = buildSchModel(plan, graph, group);
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        width: model.canvasSize.width + 40,
        height: model.canvasSize.height + 40,
        color: const Color(0xFF1E1E1E),
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: model.canvasSize.width,
              height: model.canvasSize.height,
              child: IpBlockDiagram(model: model),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await boundary.toImage(pixelRatio: 2);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File(r'G:\DebugToolSet\scratch\ip_sch\block_preview.png')
        .writeAsBytesSync(png!.buffer.asUint8List());
  });
}
