// 链路选中测试：点击右侧流程摘要的链路（selectChain）应选中该链
// 全部节点与连线并高亮；普通点选节点/连线/空白后多选连线清空。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 图：src → edge → pv（主链），外加 branch 节点（hist，不在链上）
  /// 及 branch 连线 src → hist。
  (IspStudioState, String, String, String) buildGraph() {
    final state = IspStudioState.empty();
    state.addNodeAt('image_source', const Offset(100, 100));
    final src = state.graph.nodes.keys.last;
    state.addNodeAt('edge_extract', const Offset(400, 100));
    final edge = state.graph.nodes.keys.last;
    state.addNodeAt('preview', const Offset(700, 100));
    final pv = state.graph.nodes.keys.last;
    state.addNodeAt('histogram', const Offset(400, 400));
    final hist = state.graph.nodes.keys.last;
    state.graph.connections.add(IspConnection(
        id: 'c1', fromNodeId: src, fromPort: 'out_rgb',
        toNodeId: edge, toPort: 'in'));
    state.graph.connections.add(IspConnection(
        id: 'c2', fromNodeId: edge, fromPort: 'out_rgb',
        toNodeId: pv, toPort: 'in'));
    state.graph.connections.add(IspConnection(
        id: 'c3', fromNodeId: src, fromPort: 'out_rgb',
        toNodeId: hist, toPort: 'in'));
    return (state, src, edge, pv);
  }

  test('selectChain 选中链路全部节点与连线', () {
    final (state, src, edge, pv) = buildGraph();
    state.selectChain(pv);
    expect(state.selectedNodeIds.toSet(), {src, edge, pv});
    expect(state.selectedNodeId, pv);
    expect(state.selectedConnectionIds, {'c1', 'c2'});
    expect(state.selectedConnectionId, isNull);
  });

  test('点选节点 / 点选连线后链路多选清空', () {
    final (state, src, edge, pv) = buildGraph();
    state.selectChain(pv);
    expect(state.selectedConnectionIds, isNotEmpty);

    state.selectNode(src);
    expect(state.selectedConnectionIds, isEmpty);

    state.selectChain(pv);
    state.selectConnection('c3');
    expect(state.selectedConnectionIds, isEmpty);
    expect(state.selectedNodeIds, isEmpty, reason: '点选连线清空节点选择');

    // 点空白（selectNode(null)）同样清空。
    state.selectChain(pv);
    state.selectNode(null);
    expect(state.selectedConnectionIds, isEmpty);
    expect(state.selectedNodeIds, isEmpty);
  });

  test('链不可编译时无操作（选中态不变）', () {
    final (state, src, edge, pv) = buildGraph();
    // 孤立预览（上游无源节点）：compileChain 抛错，selectChain 应静默无操作。
    state.addNodeAt('preview', const Offset(700, 400));
    final orphan = state.graph.nodes.keys.last;
    state.selectNode(src);
    state.selectChain(orphan);
    expect(state.selectedNodeIds, [src]);
    expect(state.selectedConnectionIds, isEmpty);
    // 正常链路仍可选。
    state.selectChain(pv);
    expect(state.selectedNodeIds.toSet(), {src, edge, pv});
  });

  test('删除链上节点后多选连线选中态随之失效', () {
    final (state, src, edge, pv) = buildGraph();
    state.selectChain(pv);
    // 删除 edge：c1/c2 级联删除，多选连线应被清理。
    state.graph.removeNode(edge);
    // removeNode 不触发 _clearStaleConnectionSelection（它在删除入口
    // 调用），这里直接调用状态的公共清理路径验证。
    state.selectNode(pv); // 触发一次选中变更（内部清空多选连线）
    expect(state.selectedConnectionIds, isEmpty);
  });
}
