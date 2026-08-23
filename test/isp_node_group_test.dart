import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_canvas.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_layout.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('节点编组（状态层）', () {
    late IspStudioState state;

    setUp(() {
      state = IspStudioState.empty();
    });

    /// 拖三个节点并返回 id。
    List<String> addThree() {
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;
      state.addNodeAt('histogram', const Offset(800, 100));
      final n3 = state.graph.nodes.keys.last;
      return [n1, n2, n3];
    }

    test('编组后点选任一成员即全选整组', () {
      final ids = addThree();
      state.updateBoxSelection(const Offset(50, 50), const Offset(650, 250));
      state.endBoxSelection();
      expect(state.selectedNodeIds, containsAll([ids[0], ids[1]]));

      state.groupSelectedNodes();
      expect(state.graph.groups.single.nodeIds, {ids[0], ids[1]});
      expect(state.groupIdOf(ids[0]), isNotNull);
      expect(state.groupIdOf(ids[2]), isNull);

      // 先清空选择，再点选 n2 → 整组选中，selectedNodeId 为被点节点。
      state.selectNode(null);
      state.selectNode(ids[1]);
      expect(state.selectedNodeIds, containsAll([ids[0], ids[1]]));
      expect(state.selectedNodeIds, isNot(contains(ids[2])));
      expect(state.selectedNodeId, ids[1]);
    });

    test('multiSelect 对编组整体切换', () {
      final ids = addThree();
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes();

      // 组 + 独立节点各一：ctrl 点组成员 → 整组加入/移出。
      state.selectNode(ids[2]);
      state.selectNode(ids[1], multiSelect: true);
      expect(state.selectedNodeIds, containsAll([ids[0], ids[1], ids[2]]));
      state.selectNode(ids[0], multiSelect: true);
      expect(state.selectedNodeIds, [ids[2]]);
    });

    test('取消编组后恢复单独选中', () {
      final ids = addThree();
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes();
      final gid = state.graph.groups.single.id;

      state.ungroup(gid);
      expect(state.graph.groups, isEmpty);
      expect(state.groupIdOf(ids[0]), isNull);

      state.selectNode(ids[1]);
      expect(state.selectedNodeIds, [ids[1]]);
    });

    test('重新编组会把成员从旧组摘除，旧组不足 2 人解散', () {
      final ids = addThree();
      // 第一组：n1+n2。
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes();
      expect(state.graph.groups.single.nodeIds, {ids[0], ids[1]});

      // 框选 n2、n3（框选不做编组联动，可取出组内子集）后重新编组：
      // n2 从旧组摘除，旧组只剩 n1 解散；新组为 {n2, n3}。
      state.updateBoxSelection(const Offset(350, 50), const Offset(850, 250));
      state.endBoxSelection();
      expect(state.selectedNodeIds, containsAll([ids[1], ids[2]]));
      state.groupSelectedNodes();
      expect(state.graph.groups.length, 1);
      expect(state.graph.groups.single.nodeIds, {ids[1], ids[2]});
    });

    test('删除节点级联移出编组，组不足 2 人解散', () {
      final ids = addThree();
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes();

      state.removeNode(ids[0]);
      expect(state.graph.groups, isEmpty);
    });

    test('编组随序列化往返保留，旧文件无 groups 字段兼容', () {
      final graph = IspGraph();
      final n1 = graph.addNode('preview', 0, 0);
      final n2 = graph.addNode('histogram', 0, 0);
      graph.groups.add(IspNodeGroup('g1', {n1, n2}, name: '核心组'));

      final restored = IspGraph.fromJson(graph.toJson());
      expect(restored.groups.single.nodeIds, {n1, n2});
      // 编组名随序列化往返保留。
      expect(restored.groups.single.name, '核心组');

      // 旧格式：无 groups 字段。
      final legacy = graph.toJson()..remove('groups');
      expect(IspGraph.fromJson(legacy).groups, isEmpty);

      // 旧格式：有 groups 但无 name 字段 → 补默认名「编组#N」。
      final noName = graph.toJson();
      (noName['groups'] as List).cast<Map>().first.remove('name');
      expect(IspGraph.fromJson(noName).groups.single.name, '编组#1');

      // 成员引用缺失节点：剔除后不足 2 人则丢弃。
      final dangling = graph.toJson();
      (dangling['groups'] as List).cast<Map>().first['nodes'] = [n1, 'nope'];
      expect(IspGraph.fromJson(dangling).groups, isEmpty);
    });

    test('编组默认名自动编号与重命名', () {      final ids = addThree();
      // 再加一个节点，使两个编组可以共存验证序号递增。
      state.addNodeAt('histogram', const Offset(700, 100));
      final n4 = state.graph.nodes.keys.last;
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes();
      expect(state.graph.groups.single.name, '编组#1');
      // 共存第二组：默认名取现有最大序号 +1。
      state.selectNode(ids[2]);
      state.selectNode(n4, multiSelect: true);
      state.groupSelectedNodes();
      expect(state.graph.groups.length, 2);
      expect(state.graph.groups.last.name, '编组#2');
      // 指定名与重命名。
      state.renameGroup(state.graph.groups.last.id, '自定义组');
      expect(state.graph.groups.last.name, '自定义组');
    });

    test('编组包围框顶部延伸组名净空带（组名不被节点遮挡）', () {
      final graph = IspGraph();
      final n1 = graph.addNode('preview', 100, 100);
      final n2 = graph.addNode('histogram', 100, 400);
      graph.groups.add(IspNodeGroup('g1', {n1, n2}, name: '组A'));
      final bounds = ispGroupBounds(graph, graph.groups.single)!;
      // 顶部 = 最高成员节点顶缘 - 8px 外扩 - 组名带高度。
      expect(bounds.top, 100 - 8 - kGroupNameStripHeight);
      expect(bounds.bottom, greaterThan(400));
    });
  });

  group('节点编组（右键菜单）', () {
    Future<Offset> titleCenterOf(WidgetTester tester, String nameText) async {
      final finder = find.ancestor(
          of: find.textContaining(nameText),
          matching: find.byType(IspNodeWidget));
      expect(finder, findsOneWidget);
      return tester.getTopLeft(finder) +
          Offset(tester.getSize(finder).width / 2, kNodeTitleHeight / 2);
    }

    Future<void> rightClick(WidgetTester tester, Offset pos) async {
      final gesture =
          await tester.startGesture(pos, buttons: kSecondaryButton);
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('标题栏右键完成编组与取消编组', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.empty();
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      // 未多选时右键标题栏：不弹菜单。
      await rightClick(tester, await titleCenterOf(tester, '预览'));
      expect(find.text('编组'), findsNothing);

      // 框选两个节点后右键任一选中节点标题栏 → 出现「编组」。
      state.updateBoxSelection(const Offset(50, 50), const Offset(650, 250));
      state.endBoxSelection();
      await tester.pump();
      await rightClick(tester, await titleCenterOf(tester, '预览'));
      expect(find.text('编组'), findsOneWidget);
      await tester.tap(find.text('编组'));
      await tester.pumpAndSettle();
      // 弹出命名对话框，预填默认名「编组#1」，确定后完成编组。
      expect(find.text('编组命名'), findsOneWidget);
      expect(find.widgetWithText(TextField, '编组#1'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(state.graph.groups.single.nodeIds, {n1, n2});
      expect(state.graph.groups.single.name, '编组#1');

      // 编组后右键组成员标题栏 → 出现「取消编组」。
      await rightClick(tester, await titleCenterOf(tester, 'Image'));
      expect(find.text('取消编组'), findsOneWidget);
      await tester.tap(find.text('取消编组'));
      await tester.pumpAndSettle();
      expect(state.graph.groups, isEmpty);
    });

    testWidgets('编组框内左键拖动整个编组', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.empty();
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;
      state.selectNode(n1);
      state.selectNode(n2, multiSelect: true);
      state.groupSelectedNodes();
      state.selectNode(null);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      final x1 = state.graph.nodes[n1]!.x, y1 = state.graph.nodes[n1]!.y;
      final x2 = state.graph.nodes[n2]!.x, y2 = state.graph.nodes[n2]!.y;

      // 编组框内、两节点卡片之间的空隙（画布坐标 340,110：n1 卡片
      // 右缘 290、n2 卡片左缘 400）。
      final canvasOrigin = tester.getTopLeft(find.byType(IspNodeCanvas));
      final global = canvasOrigin +
          state.canvasOffset +
          const Offset(340, 110) * state.canvasZoom;
      final gesture =
          await tester.startGesture(global, buttons: kPrimaryButton);
      await gesture.moveBy(const Offset(50, 30));
      await gesture.up();
      await tester.pumpAndSettle();

      // 整组被选中且两个成员同步位移（网格吸附 10px，容差 1.1）。
      expect(state.selectedNodeIds, containsAll([n1, n2]));
      expect(state.graph.nodes[n1]!.x - x1, closeTo(50, 1.1));
      expect(state.graph.nodes[n1]!.y - y1, closeTo(30, 1.1));
      expect(state.graph.nodes[n2]!.x - x2, closeTo(50, 1.1));
      expect(state.graph.nodes[n2]!.y - y2, closeTo(30, 1.1));
    });
  });
}
