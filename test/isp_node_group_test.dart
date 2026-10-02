import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_canvas.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_layout.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_property_panel.dart';
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

    test('选择中包含已编组节点时不允许再编组', () {
      final ids = addThree();
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes();
      expect(state.graph.groups.single.nodeIds, {ids[0], ids[1]});
      // 编组联动使选择即整组成员 → 不允许再编组。
      expect(state.canGroupSelectedNodes, isFalse);

      // 框选 n2（已编组）+ n3（未编组）：不允许编组，旧组保持原样。
      state.updateBoxSelection(const Offset(350, 50), const Offset(850, 250));
      state.endBoxSelection();
      expect(state.selectedNodeIds, containsAll([ids[1], ids[2]]));
      expect(state.canGroupSelectedNodes, isFalse);
      state.groupSelectedNodes();
      expect(state.graph.groups.length, 1);
      expect(state.graph.groups.single.nodeIds, {ids[0], ids[1]});

      // 先取消编组后，n2+n3 才允许编为新组。
      state.ungroup(state.graph.groups.single.id);
      expect(state.canGroupSelectedNodes, isTrue);
      state.groupSelectedNodes();
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

    test('多段色彩均衡器单节点编组随序列化往返保留', () {
      final graph = IspGraph();
      final eq = graph.addNode('multi_band_eq', 0, 0);
      graph.groups.add(IspNodeGroup('g1', {eq}, name: 'EQ组'));

      final restored = IspGraph.fromJson(graph.toJson());
      expect(restored.groups.single.nodeIds, {eq});
      expect(restored.groups.single.name, 'EQ组');

      // 其他类型的单成员编组（旧数据/异常数据）仍丢弃。
      final n2 = graph.addNode('histogram', 0, 0);
      final json = graph.toJson();
      (json['groups'] as List)
          .add({'id': 'g9', 'name': '坏组', 'nodes': [n2]});
      expect(IspGraph.fromJson(json).groups.single.nodeIds, {eq});
    });

    test('删除无关节点不解散均衡器单节点编组', () {
      state.addNodeAt('multi_band_eq', const Offset(100, 100));
      final eq = state.graph.nodes.keys.last;
      state.addNodeAt('histogram', const Offset(400, 100));
      final other = state.graph.nodes.keys.last;
      state.selectNode(eq);
      expect(state.canGroupSelectedNodes, isTrue);
      state.groupSelectedNodes();
      expect(state.graph.groups.single.nodeIds, {eq});

      // 删除组外节点：单节点编组保持。
      state.removeNode(other);
      expect(state.graph.groups.single.nodeIds, {eq});

      // 删除均衡器节点本身：编组解散。
      state.removeNode(eq);
      expect(state.graph.groups, isEmpty);
    });

    test('均衡器单节点编组随保存/打开 .ispflow 文件往返保留', () async {
      final dir = await Directory.systemTemp.createTemp('isp_flow_eq_group_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/t.ispflow';

      state.addNodeAt('multi_band_eq', const Offset(100, 100));
      final eq = state.graph.nodes.keys.last;
      state.selectNode(eq);
      state.groupSelectedNodes(name: 'EQ组');
      await state.saveGraphToFile(path);

      state.ungroup(state.graph.groups.single.id);
      expect(state.graph.groups, isEmpty);
      await state.importGraphFromFile(path);
      expect(state.graph.groups.single.nodeIds, {eq});
      expect(state.graph.groups.single.name, 'EQ组');
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

    test('可导出 C 与不可导出 C 的节点混合时不允许编组', () {
      state.addNodeAt('gamma', const Offset(100, 100)); // 可导出 C
      final n1 = state.graph.nodes.keys.last;
      state.addNodeAt('histogram', const Offset(400, 100)); // PC 侧节点
      final n2 = state.graph.nodes.keys.last;
      state.addNodeAt('ccm', const Offset(700, 100)); // 可导出 C
      final n3 = state.graph.nodes.keys.last;

      // 混合选择：判定为混合，编组为空操作。
      state.selectNode(n1);
      state.selectNode(n2, multiSelect: true);
      expect(state.selectionMixesCExportNodes, isTrue);
      state.groupSelectedNodes();
      expect(state.graph.groups, isEmpty);

      // 纯可导出 C 选择：允许编组。
      state.selectNode(n1);
      state.selectNode(n3, multiSelect: true);
      expect(state.selectionMixesCExportNodes, isFalse);
      state.groupSelectedNodes();
      expect(state.graph.groups.single.nodeIds, {n1, n3});
    });

    test('编组随保存/打开 .ispflow 文件往返保留', () async {
      final dir = await Directory.systemTemp.createTemp('isp_flow_group_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/t.ispflow';

      final ids = addThree();
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes(name: '核心组');
      await state.saveGraphToFile(path);

      // 保存的文件本身应包含 groups 字段。
      expect(await File(path).readAsString(), contains('"groups"'));

      // 取消编组后再打开该文件：编组应从文件恢复。
      state.ungroup(state.graph.groups.single.id);
      expect(state.graph.groups, isEmpty);
      await state.importGraphFromFile(path);
      expect(state.graph.groups.single.nodeIds, {ids[0], ids[1]});
      expect(state.graph.groups.single.name, '核心组');
    });

    test('未选中状态下 beginNodeDrag 组内节点，整组进入拖动组', () {
      final ids = addThree();
      state.selectNode(ids[0]);
      state.selectNode(ids[1], multiSelect: true);
      state.groupSelectedNodes();
      // 清空选择：模拟直接按住标题栏拖动（拖动前未点选）。
      state.selectNode(null);

      state.beginNodeDrag(ids[0]);
      state.moveNode(ids[0], const Offset(50, 30));
      state.endNodeDrag();

      // 组内两个成员同步位移，组外节点不动。
      expect(state.graph.nodes[ids[0]]!.x - 100, closeTo(50, 1.1));
      expect(state.graph.nodes[ids[0]]!.y - 100, closeTo(30, 1.1));
      expect(state.graph.nodes[ids[1]]!.x - 400, closeTo(50, 1.1));
      expect(state.graph.nodes[ids[1]]!.y - 100, closeTo(30, 1.1));
      expect(state.graph.nodes[ids[2]]!.x, 800);
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

    testWidgets('编组框内任意位置右键弹出编组菜单', (tester) async {
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

      Offset globalOf(Offset canvasPos) =>
          tester.getTopLeft(find.byType(IspNodeCanvas)) +
          state.canvasOffset +
          canvasPos * state.canvasZoom;

      // 1) 编组框内两节点卡片之间的空隙右键 → 出现「取消编组」。
      await rightClick(tester, globalOf(const Offset(340, 110)));
      expect(find.text('取消编组'), findsOneWidget);
      await tester.tap(find.text('取消编组'));
      await tester.pumpAndSettle();
      expect(state.graph.groups, isEmpty);

      // 2) 重新编组后右键节点卡片主体（标题栏下方）→ 同样弹出菜单。
      state.selectNode(n1);
      state.selectNode(n2, multiSelect: true);
      state.groupSelectedNodes();
      state.selectNode(null);
      await tester.pump();
      await rightClick(tester,
          globalOf(Offset(150, 100 + kNodeTitleHeight + 20)));
      expect(find.text('取消编组'), findsOneWidget);
      await tester.tap(find.text('取消编组'));
      await tester.pumpAndSettle();
      expect(state.graph.groups, isEmpty);
    });

    testWidgets('混合可/不可导出 C 节点编组时弹出说明并取消', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.empty();
      state.addNodeAt('gamma', const Offset(100, 100)); // 可导出 C
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('histogram', const Offset(400, 100)); // PC 侧节点
      final n2 = state.graph.nodes.keys.last;

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      // 混合选择后点工具栏编组按钮 → 弹说明对话框，不产生编组。
      state.selectNode(n1);
      state.selectNode(n2, multiSelect: true);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.group_add));
      await tester.pumpAndSettle();
      expect(find.text('无法编组'), findsOneWidget);
      expect(find.text('编组命名'), findsNothing);
      await tester.tap(find.text('知道了'));
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

    testWidgets('编组内节点标题栏左键拖动整个编组', (tester) async {
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

      // 直接按住 n2 标题栏拖动（此前未点选，选中集为空）。
      final gesture = await tester.startGesture(
          await titleCenterOf(tester, '预览'), buttons: kPrimaryButton);
      await gesture.moveBy(const Offset(50, 30));
      await gesture.up();
      await tester.pumpAndSettle();

      // 两个成员同步位移（网格吸附 10px，容差 1.1）。
      expect(state.graph.nodes[n1]!.x - x1, closeTo(50, 1.1));
      expect(state.graph.nodes[n1]!.y - y1, closeTo(30, 1.1));
      expect(state.graph.nodes[n2]!.x - x2, closeTo(50, 1.1));
      expect(state.graph.nodes[n2]!.y - y2, closeTo(30, 1.1));
    });
  });

  group('节点编组（属性面板）', () {
    testWidgets('选中编组时右侧面板从上到下显示全部成员节点参数', (tester) async {
      final state = IspStudioState.empty();
      // n1 在下方（y=400），n2 在上方（y=100）：验证面板按画布纵向
      // 位置排序，而非插入/选择顺序。
      state.addNodeAt('image_source', const Offset(100, 400));
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('preview', const Offset(100, 100));
      final n2 = state.graph.nodes.keys.last;
      state.selectNode(n1);
      state.selectNode(n2, multiSelect: true);
      state.groupSelectedNodes();
      // 点选组内任一成员 → 编组联动全选整组。
      state.selectNode(n1);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: NodePropertyPanel())),
        ),
      );
      await tester.pumpAndSettle();

      // 两个成员的参数区都出现。
      expect(find.text('Image#1'), findsOneWidget);
      expect(find.text('预览#1'), findsOneWidget);
      expect(find.text('图片文件'), findsOneWidget);
      expect(find.text('播放帧率'), findsOneWidget);

      // 从上到下：画布上方的「预览」排在「Image」之前。
      final topPreview = tester.getTopLeft(find.text('预览#1')).dy;
      final topImage = tester.getTopLeft(find.text('Image#1')).dy;
      expect(topPreview, lessThan(topImage));
    });
  });
}
