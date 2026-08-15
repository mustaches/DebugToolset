import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  test('矢量示波器测试流程：预览运行后 vectorscope 应有结果与显示图像', () async {
    final state = IspStudioState();
    await state.importGraphFromFile('IspFlow/矢量示波器测试.ispflow');
    expect(state.statusMessage, contains('已打开流程'));

    final vecId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'vectorscope')
        .key;

    final tickBefore = state.instrumentTick.value;
    await state.runPreview();

    expect(state.statusMessage, contains('预览就绪'),
        reason: '预览应成功: ${state.statusMessage}');
    expect(state.instrumentResults[vecId], isNotNull,
        reason: 'vectorscope 应有分析结果');
    expect(state.instrumentImages[vecId], isNotNull,
        reason: 'vectorscope 应有显示图像');
    // 回归守卫：仪器附加区用 ValueListenableBuilder 只监听 instrumentTick，
    // runPreview 路径必须递增它，否则仪器区在部分时序下停在「未运行」。
    expect(state.instrumentTick.value, greaterThan(tickBefore),
        reason: 'runPreview 完成后 instrumentTick 应递增以触发仪器区重建');

    // 图像不能是全透明的（counts 全 0 时 intensityRgba 出全透明图，
    // RawImage 渲染为空白，用户会误以为"未运行"）。
    final result = state.instrumentResults[vecId]!;
    final counts = result['counts'];
    if (counts is Uint32List) {
      final total = counts.fold<int>(0, (s, c) => s + c);
      expect(total, greaterThan(0), reason: 'vectorscope 计数不应全为 0');
    }
    final img = state.instrumentImages[vecId]!;
    final byteData =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(byteData, isNotNull);
    final px = byteData!.buffer.asUint8List();
    var nonTransparent = 0;
    for (var i = 3; i < px.length; i += 4) {
      if (px[i] != 0) nonTransparent++;
    }
    expect(nonTransparent, greaterThan(0),
        reason: 'vectorscope 图像不应全透明（$nonTransparent/${px.length ~/ 4} 像素不透明）');
  });
}

