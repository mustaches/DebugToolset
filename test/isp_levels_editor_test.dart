import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_property_panel.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('曲线调节器：点击/拖动已有控制点不应新增点', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final id = state.graph.addNode('levels_curves', 0, 0);
    state.setParam(id, 'points', [
      [0.0, 0.0],
      [2048.0, 2048.0],
      [4095.0, 4095.0],
    ]);
    final node = state.graph.nodes[id]!;
    final type = IspNodeRegistry.byId('levels_curves')!;
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider.value(
        value: state,
        child: Scaffold(
          body: Center(
            child: IspNodeWidget(
              node: node,
              type: type,
              selected: false,
              globalToCanvas: (o) => o,
              onConnectionDragEnd: () {},
              onToggleMaximize: () {},
              inputPortKeyFor: (p) => GlobalKey(),
            ),
          ),
        ),
      ),
    ));

    // 编辑器曲线区 = 唯一同时带 onTapDown 与 onPanStart 的 GestureDetector。
    final editorFinder = find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onTapDown != null && w.onPanStart != null);
    expect(editorFinder, findsOneWidget);
    final topLeft = tester.getTopLeft(editorFinder);
    final size = tester.getSize(editorFinder);
    Offset toGlobal(double x, double y) => topLeft +
        Offset(x / 4095 * size.width, (1 - y / 4095) * size.height);

    int pointCount() => (node.paramValues['points'] as List).length;
    expect(pointCount(), 3);

    // 单击已有控制点：不应新增。
    await tester.tapAt(toGlobal(2048, 2048));
    await tester.pump();
    expect(pointCount(), 3, reason: '单击已有控制点不应新增点');

    // 双击已有控制点：不删除（删点只走拖出曲线区）。
    final center = toGlobal(2048, 2048);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pump();
    expect(pointCount(), 3, reason: '双击不应删除控制点');

    // 命中半径 12 屏幕像素：点旁 10px 处单击仍视为点上（不新增）。
    await tester.tapAt(center + const Offset(10, 0));
    await tester.pump();
    expect(pointCount(), 3, reason: '命中半径内的点击不应新增点');

    // 拖动已有控制点：不应新增，且点的 y 被拖动改变。
    final g = await tester.startGesture(toGlobal(2048, 2048));
    await tester.pump();
    await g.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(pointCount(), 3, reason: '拖动已有控制点不应新增点');
    final pts = (node.paramValues['points'] as List).cast<List>();
    expect((pts[1][1] as num).toDouble(), greaterThan(2048.0),
        reason: '向上拖动应增大输出值');
    await g.up();
    await tester.pump();
  });

  testWidgets('曲线调节器：旧存档节点（缺 curveMode/gamma）属性面板回退默认值显示',
      (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final id = state.graph.addNode('levels_curves', 0, 0);
    // 模拟旧版 .ispflow 载入的节点：没有后加的 curveMode/gamma 参数。
    state.graph.nodes[id]!.paramValues.remove('curveMode');
    state.graph.nodes[id]!.paramValues.remove('gamma');
    state.selectNode(id);

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider.value(
        value: state,
        child: const Scaffold(body: NodePropertyPanel()),
      ),
    ));

    // 曲线公式下拉框应显示默认值 spline，而不是空白。
    expect(find.text('曲线公式'), findsOneWidget);
    final dropdown =
        tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
    expect(dropdown.value, 'spline', reason: '缺失的 curveMode 应回退默认值显示');
    expect(find.text('spline'), findsOneWidget);
    // Gamma 参数同样回退默认值显示。
    expect(find.text('Gamma'), findsOneWidget);
  });
}
