import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_align_mode.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('IspStudioState Alignment Tests', () {
    late IspStudioState state;
    late String node1;
    late String node2;
    late String node3;

    setUp(() {
      state = IspStudioState.empty();
      node1 = state.graph.addNode('image_source', 100, 50); // width 190
      node2 = state.graph.addNode('rgb_splitter', 300, 200); // width 190
      node3 = state.graph.addNode('preview', 500, 100); // width 190
    });

    test('Align Left aligns all nodes to minimum X', () {
      state.alignNodes(IspAlignMode.left);
      expect(state.graph.nodes[node1]!.x, 100);
      expect(state.graph.nodes[node2]!.x, 100);
      expect(state.graph.nodes[node3]!.x, 100);
    });

    test('Align Right aligns all nodes to maximum X + width', () {
      // Bounding right = 500 + 190 = 690 (since node3.x = 500, width = 190)
      state.alignNodes(IspAlignMode.right);
      final maxX = 500 + state.graph.nodes[node3]!.width;
      expect(state.graph.nodes[node1]!.x, maxX - state.graph.nodes[node1]!.width);
      expect(state.graph.nodes[node2]!.x, maxX - state.graph.nodes[node2]!.width);
      expect(state.graph.nodes[node3]!.x, maxX - state.graph.nodes[node3]!.width);
    });

    test('Align Horizontal Center aligns node midpoints', () {
      // Bounding box: minX=100, maxX=690, center=395
      state.alignNodes(IspAlignMode.horizontalCenter);
      for (final id in [node1, node2, node3]) {
        final n = state.graph.nodes[id]!;
        expect(n.x + n.width / 2, closeTo(395, 0.001));
      }
    });

    test('Align Top aligns all nodes to minimum Y', () {
      state.alignNodes(IspAlignMode.top);
      expect(state.graph.nodes[node1]!.y, 50);
      expect(state.graph.nodes[node2]!.y, 50);
      expect(state.graph.nodes[node3]!.y, 50);
    });

    test('Distribute Horizontal creates equal gaps between nodes', () {
      // node1: x=100, node2: x=300, node3: x=500
      state.alignNodes(IspAlignMode.distributeHorizontal);
      final n1 = state.graph.nodes[node1]!;
      final n2 = state.graph.nodes[node2]!;
      final n3 = state.graph.nodes[node3]!;

      final gap1 = n2.x - (n1.x + n1.width);
      final gap2 = n3.x - (n2.x + n2.width);
      expect(gap1, closeTo(gap2, 0.001));
    });

    test('Align operates on selected nodes when 2+ nodes are selected', () {
      state.selectNode(node1, multiSelect: true);
      state.selectNode(node2, multiSelect: true);

      state.alignNodes(IspAlignMode.left);
      // node1 and node2 aligned to minX (100)
      expect(state.graph.nodes[node1]!.x, 100);
      expect(state.graph.nodes[node2]!.x, 100);
      // node3 unselected, remains at original 500
      expect(state.graph.nodes[node3]!.x, 500);
    });
  });
}
