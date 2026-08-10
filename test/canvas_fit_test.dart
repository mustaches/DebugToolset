import 'dart:math' as math;

import 'package:debug_tool_set/modules/ui_designer/editor/canvas_view.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_widget.dart';
import 'package:debug_tool_set/modules/ui_designer/models/widget_registry.dart';
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

  testWidgets('50%缩放: 无溢出错误且画布表面保持逻辑尺寸', (tester) async {
    final state = UiDesignerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: CanvasView())),
      ),
    );
    state.setZoom(0.5);
    await tester.pumpAndSettle();

    // scale < 1 时逻辑表面(480x320)大于占位盒(240x160)，
    // 使用 OverflowBox 不应产生溢出异常。
    expect(tester.takeException(), isNull);

    const logicalW = 480.0;
    const logicalH = 320.0;
    final canvasBox = find.byWidgetPredicate(
      (w) => w is SizedBox && w.width == logicalW * 0.5 && w.height != null,
    );
    expect(canvasBox, findsOneWidget);
    expect(tester.getSize(canvasBox), Size(logicalW * 0.5, logicalH * 0.5));

    final surface = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.constraints != null &&
          w.constraints!.maxWidth == logicalW &&
          w.constraints!.maxHeight == logicalH,
    );
    expect(surface, findsOneWidget);
    expect(tester.getSize(surface), const Size(logicalW, logicalH));
  });

  testWidgets('400%缩放: 水平/垂直滚动条均可拖动滚动', (tester) async {
    final state = UiDesignerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: CanvasView())),
      ),
    );
    state.setZoom(4);
    await tester.pumpAndSettle();

    // 480x320 @ 400% = 1920x1280，超出 800x600 视口，双向都需要滚动。
    final scrollables =
        tester.stateList<ScrollableState>(find.byType(Scrollable)).toList();
    final horizontal =
        scrollables.firstWhere((s) => s.position.axis == Axis.horizontal);
    final vertical =
        scrollables.firstWhere((s) => s.position.axis == Axis.vertical);
    expect(horizontal.position.maxScrollExtent, greaterThan(0));
    expect(vertical.position.maxScrollExtent, greaterThan(0));

    // 滚动条钉在视口边缘：右侧垂直条与底部水平条。
    final vBar = find.byKey(const Key('canvas_v_scrollbar'));
    final hBar = find.byKey(const Key('canvas_h_scrollbar'));
    expect(vBar, findsOneWidget);
    expect(hBar, findsOneWidget);

    // 拖动底部水平滚动条。
    final hRect = tester.getRect(hBar);
    await tester.dragFrom(
      Offset(hRect.left + 30, hRect.center.dy),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontal.position.pixels, greaterThan(0));

    // 拖动右侧垂直滚动条。
    final vRect = tester.getRect(vBar);
    await tester.dragFrom(
      Offset(vRect.center.dx, vRect.top + 30),
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();
    expect(vertical.position.pixels, greaterThan(0));
  });

  testWidgets('拖动控制点调整控件大小时矩形跟随鼠标', (tester) async {
    final state = UiDesignerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: CanvasView())),
      ),
    );
    state.setZoom(1);
    final page = state.currentPage!;
    page.widgets.add(UiWidgetModel(
      id: 'w1',
      type: 'label',
      name: 'label_1',
      x: 10,
      y: 10,
      width: 100,
      height: 40,
      props: WidgetRegistry.of('label')!.defaultProps(),
    ));
    state.setSelection(['w1']);
    await tester.pumpAndSettle();

    // 东南角控制点: 逻辑坐标 (110,50)，100% 缩放 + 20 padding
    // 对应全局坐标 (130,70)。分多次移动拖出 (90,60)。
    // 注意 PanGestureRecognizer 的触发阈值 kPanSlop≈36 会吸收
    // 首段位移，实际生效约 (60,40)。
    final gesture = await tester.startGesture(const Offset(130, 70));
    await gesture.moveBy(const Offset(30, 20));
    await gesture.moveBy(const Offset(30, 20));
    await gesture.moveBy(const Offset(30, 20));
    await gesture.up();
    await tester.pumpAndSettle();

    // 旧逻辑把单帧增量作用于起始矩形，最终只会移动最后一帧的
    // 增量(约 30px)。累加后应跟随鼠标移动约 60px。
    final rect = page.widgetById('w1')!.rect;
    expect(rect.width, greaterThan(145));
    expect(rect.height, greaterThan(72));
    expect(rect.width, lessThan(170));
    expect(rect.height, lessThan(90));
  });

  testWidgets('八个控制点均可拖动调整大小', (tester) async {
    final state = UiDesignerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: CanvasView())),
      ),
    );
    state.setZoom(1);
    final page = state.currentPage!;
    page.widgets.add(UiWidgetModel(
      id: 'w1',
      type: 'label',
      name: 'label_1',
      x: 50,
      y: 50,
      width: 100,
      height: 40,
      props: WidgetRegistry.of('label')!.defaultProps(),
    ));
    state.setSelection(['w1']);
    await tester.pumpAndSettle();

    // 各控制点拖出 (30,20) 后矩形应有变化(首段位移被手势阈值
    // 吸收，实际生效约 (30,20))。
    // 控制点中心: NW N NE E SE S SW W
    final r = page.widgetById('w1')!.rect;
    final centers = [
      r.topLeft, r.topCenter, r.topRight, r.centerRight,
      r.bottomRight, r.bottomCenter, r.bottomLeft, r.centerLeft,
    ];
    for (var i = 0; i < 8; i++) {
      final origin = page.widgetById('w1')!.rect;
      // 100% 缩放 + 20 padding。
      final start = centers[i] + const Offset(20, 20);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(30, 20));
      await gesture.moveBy(const Offset(30, 20));
      await gesture.up();
      await tester.pumpAndSettle();
      final after = page.widgetById('w1')!.rect;
      expect(after, isNot(equals(origin)), reason: '控制点 $i 拖动无效');
      // 还原供下一个控制点测试。
      page.widgetById('w1')!.setRect(Rect.fromLTWH(50, 50, 100, 40));
      state.notifyMove();
      await tester.pumpAndSettle();
    }
  });
}
