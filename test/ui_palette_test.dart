import 'package:debug_tool_set/modules/ui_designer/editor/widget_palette.dart';
import 'package:debug_tool_set/modules/ui_designer/models/widget_registry.dart';
import 'package:debug_tool_set/providers/ui_designer_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('palette: 每行3个30px按钮(3px间距/左右6px)带tooltip',
      (tester) async {
    final state = UiDesignerState();
    addTearDown(state.dispose);
    // 侧边栏宽108 = 左右各6 + 30x3 + 3x2
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(
            home: Scaffold(
                body: SizedBox(
                    width: 108, height: 600, child: WidgetPalette()))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Tooltip),
        findsNWidgets(WidgetRegistry.all.length));
    expect(find.byType(Icon), findsNWidgets(WidgetRegistry.all.length));

    // 紧凑 Wrap, 3px 间距
    final wrap = tester.widget<Wrap>(find.byType(Wrap));
    expect(wrap.spacing, 3);
    expect(wrap.runSpacing, 3);

    // 按钮固定 30x30
    final buttons = find.byType(SizedBox).evaluate().where((e) {
      final w = e.widget;
      return w is SizedBox && w.height == 30 && w.width == 30;
    }).toList();
    expect(buttons.length, WidgetRegistry.all.length);

    // 每行3个: 前3个按钮同一行, 第4个在下一行
    final y0 = tester.getTopLeft(find.byWidget(buttons[0].widget)).dy;
    final y1 = tester.getTopLeft(find.byWidget(buttons[1].widget)).dy;
    final y2 = tester.getTopLeft(find.byWidget(buttons[2].widget)).dy;
    final y3 = tester.getTopLeft(find.byWidget(buttons[3].widget)).dy;
    expect(y0, y1);
    expect(y0, y2);
    expect(y3, greaterThan(y0));

    // 点击图标添加控件
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(state.currentPage!.widgets.length, 1);
  });
}
