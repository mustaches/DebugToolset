// 一次性：真实网表的走线密度热力图预览。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('heatmap preview', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    final heatmap = computeNlHeatmap(
      model.flattened(),
      model.canvasSize,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & model.canvasSize,
      Paint()..color = const Color(0xFF1E1E1E),
    );
    // 底部先画一遍直线，确认热力与走线位置对应。
    final line = Paint()
      ..color = const Color(0xFF4A6A8A)
      ..strokeWidth = 1;
    for (final w in model.wires) {
      for (final (a, b) in nlStraightWireSegments(w)) {
        canvas.drawLine(a, b, line);
      }
    }
    final painter = NetlistHeatmapPainter(heatmap);
    painter.paint(canvas, model.canvasSize);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      model.canvasSize.width.round(),
      model.canvasSize.height.round(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      'scratch/nl_heatmap_preview.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print(
      'HEATMAP ${heatmap.columns}x${heatmap.rows} cells, '
      'max=${heatmap.values.fold<double>(0, (a, b) => a > b ? a : b)}',
    );
  });
}
