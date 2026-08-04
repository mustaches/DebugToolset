import 'dart:math' as math;

import 'package:debug_tool_set/modules/ui_designer/editor/canvas_view.dart';
import 'package:debug_tool_set/providers/ui_designer_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('适配窗口: 画布保持逻辑尺寸渲染且完整适配视口', (tester) async {
    final state = UiDesignerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: CanvasView())),
      ),
    );
    await tester.pumpAndSettle();

    // 默认工程 480x320，默认测试视口 800x600。
    const logicalW = 480.0;
    const logicalH = 320.0;
    final viewport = tester.getSize(find.byType(CanvasView));
    final fit = math.min(
      (viewport.width - 40) / logicalW,
      (viewport.height - 40) / logicalH,
    ).clamp(0.05, 8.0);

    // 缩放后的布局占位应为 逻辑尺寸 * fit，且不超出视口。
    final canvasBox = find.byWidgetPredicate(
      (w) =>
          w is SizedBox &&
          w.width != null &&
          (w.width! - logicalW * fit).abs() < 0.01,
    );
    expect(canvasBox, findsOneWidget);
    final canvasSize = tester.getSize(canvasBox);
    expect(canvasSize.width, lessThanOrEqualTo(viewport.width - 39));
    expect(canvasSize.height, lessThanOrEqualTo(viewport.height - 39));

    // 关键回归断言: 画布表面(带背景色/边框的 Container)必须保持逻辑
    // 尺寸。若 SizedBox 的紧约束穿透 Transform.scale 拉伸了表面，背景与
    // 边框会被二次放大为 逻辑尺寸 * fit²，右侧和下方溢出工作区。
    final surface = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.constraints != null &&
          w.constraints!.maxWidth == logicalW &&
          w.constraints!.maxHeight == logicalH,
    );
    expect(surface, findsOneWidget);
    expect(tester.getSize(surface), const Size(logicalW, logicalH));

    // 网格按逻辑尺寸铺满画布表面(边框向内缩进 1px)。
    final grid = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter != null,
    );
    expect(grid, findsOneWidget);
    expect(
        tester.getSize(grid), const Size(logicalW - 2, logicalH - 2));
  });
}
