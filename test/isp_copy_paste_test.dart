// 节点复制粘贴测试：参数/尺寸/内部连线/完整编组的复制与级联偏移。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('节点复制粘贴', () {
    test('复制粘贴保留类型/参数/尺寸，位置级联偏移并选中新节点', () {
      final state = IspStudioState.empty();
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.last;
      state.graph.nodes[n1]!.paramValues['bitDepth'] = '16';
      state.graph.nodes[n1]!.width = 240;

      state.selectNode(n1);
      state.copySelectedNodes();
      state.pasteNodes();

      expect(state.graph.nodes.length, 2);
      final n2 = state.graph.nodes.keys.last;
      expect(n2, isNot(n1));
      final node2 = state.graph.nodes[n2]!;
      expect(node2.typeId, 'image_source');
      expect(node2.paramValues['bitDepth'], '16');
      expect(node2.width, 240);
      // 级联偏移 +20；再粘贴一次 +40（相对原位）。
      expect(node2.x, 120);
      expect(node2.y, 120);
      // 新节点被选中，旧节点未选。
      expect(state.selectedNodeIds, [n2]);
      // 实例名自动编号不与原节点重名。
      expect(node2.name, isNot(state.graph.nodes[n1]!.name));

      state.pasteNodes();
      final n3 = state.graph.nodes.keys.last;
      expect(state.graph.nodes[n3]!.x, 140);
      expect(state.graph.nodes[n3]!.y, 140);
    });

    test('选中集内部连线与完整编组一并复制', () {
      final state = IspStudioState.empty();
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.last;
      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;
      state.graph.connections.add(IspConnection(
          id: 'c1', fromNodeId: n1, fromPort: 'out_rgb',
          toNodeId: n2, toPort: 'in'));
      state.selectNode(n1);
      state.selectNode(n2, multiSelect: true);
      state.groupSelectedNodes();
      // 第三个节点不在选中集：其连线不复制。
      state.addNodeAt('histogram', const Offset(700, 100));
      final n3 = state.graph.nodes.keys.last;
      state.graph.connections.add(IspConnection(
          id: 'c2', fromNodeId: n2, fromPort: 'out',
          toNodeId: n3, toPort: 'in'));

      // 复制前确保选中集恰为 n1+n2（addNodeAt 可能改变选中；
      // 编组联动下点选 n1 即全选整组，无需再 multiSelect n2——
      // 那会触发反选）。
      state.selectNode(n1);
      expect(state.selectedNodeIds, containsAll([n1, n2]));
      state.copySelectedNodes();
      state.pasteNodes();

      expect(state.graph.nodes.length, 5); // 3 原有 + 2 粘贴
      // 内部连线复制（新 id、指向新节点），连向未选中节点的连线不复制。
      final pasted = state.graph.connections
          .where((c) => c.id != 'c1' && c.id != 'c2')
          .toList();
      expect(pasted.length, 1);
      expect(pasted.single.fromNodeId, isNot(n1));
      expect(pasted.single.toNodeId, isNot(n2));
      expect(state.graph.nodes.containsKey(pasted.single.fromNodeId), isTrue);
      expect(state.graph.nodes.containsKey(pasted.single.toNodeId), isTrue);
      // 完整编组复制：新组包含两个新节点。
      expect(state.graph.groups.length, 2);
      final newGroup = state.graph.groups.last;
      expect(newGroup.nodeIds, containsAll(
          [pasted.single.fromNodeId, pasted.single.toNodeId]));
      expect(newGroup.name, state.graph.groups.first.name);
      // 新组成员不与旧组交叉。
      expect(newGroup.nodeIds.intersection({n1, n2}), isEmpty);
    });

    test('空选择复制为空操作，空剪贴板粘贴为空操作', () {
      final state = IspStudioState.empty();
      state.addNodeAt('preview', const Offset(100, 100));
      state.pasteNodes(); // 空剪贴板
      expect(state.graph.nodes.length, 1);
      state.selectNode(null);
      state.copySelectedNodes(); // 空选择
      state.pasteNodes();
      expect(state.graph.nodes.length, 1);
    });
  });
}
