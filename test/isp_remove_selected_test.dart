// 多选删除测试：删除键（removeSelected）应删除全部选中节点，
// 而非仅主选中（黄色高亮）节点。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  test('多选时 removeSelected 删除全部选中节点', () {
    final state = IspStudioState.empty();
    for (var i = 0; i < 3; i++) {
      state.addNodeAt('histogram', Offset(100.0 + i * 300, 100));
    }
    final ids = state.graph.nodes.keys.toList();
    // 选中前两个（第三个不选）。
    state.selectNode(ids[0]);
    state.selectNode(ids[1], multiSelect: true);
    expect(state.selectedNodeIds.length, 2);

    state.removeSelected();

    expect(state.graph.nodes.keys.toList(), [ids[2]]);
    expect(state.selectedNodeIds, isEmpty);
    expect(state.selectedNodeId, isNull);
  });

  test('单选时行为不变（删除唯一选中节点）；选中连线时优先删连线', () {
    final state = IspStudioState.empty();
    state.addNodeAt('image_source', const Offset(100, 100));
    final n1 = state.graph.nodes.keys.last;
    state.addNodeAt('preview', const Offset(400, 100));
    final n2 = state.graph.nodes.keys.last;
    state.graph.connections.add(IspConnection(
        id: 'c1', fromNodeId: n1, fromPort: 'out_rgb',
        toNodeId: n2, toPort: 'in'));

    // 选中连线：删除键删连线，不动节点。
    state.selectConnection('c1');
    state.removeSelected();
    expect(state.graph.connections, isEmpty);
    expect(state.graph.nodes.length, 2);

    // 单选节点：删除该节点。
    state.selectNode(n1);
    state.removeSelected();
    expect(state.graph.nodes.keys.toList(), [n2]);
  });
}
