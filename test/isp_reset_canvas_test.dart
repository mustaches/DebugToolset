import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  Future<IspStudioState> pumpView(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = IspStudioState.withDefaultGraph();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('清除画布：警告窗口三个按钮，取消保留节点', (tester) async {
    final state = await pumpView(tester);
    final nodeCount = state.graph.nodes.length;
    expect(nodeCount, greaterThan(0));

    await tester.tap(find.byTooltip('清除画布'));
    await tester.pump();
    await tester.pump();
    expect(find.text('本操作将清除当前画布上的所有节点。'), findsOneWidget);
    expect(find.text('保存并清除'), findsOneWidget);
    // 标题与按钮同名，按钮用 TextButton 限定。
    expect(find.widgetWithText(TextButton, '清除画布'), findsOneWidget);
    expect(find.text('取消操作'), findsOneWidget);

    await tester.tap(find.text('取消操作'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(state.graph.nodes.length, nodeCount);
  });

  testWidgets('清除画布：清空全部节点', (tester) async {
    final state = await pumpView(tester);
    expect(state.graph.nodes, isNotEmpty);

    await tester.tap(find.byTooltip('清除画布'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '清除画布'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(state.graph.nodes, isEmpty);
    expect(state.graph.connections, isEmpty);
    expect(state.statusMessage, contains('画布已清空'));
  });
}
