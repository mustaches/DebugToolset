import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('IspStudioState Selection Order & Size Matching Tests', () {
    late IspStudioState state;

    setUp(() {
      state = IspStudioState.empty();
    });

    test('primarySelectedNodeId is the first node selected', () {
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('preview', const Offset(300, 100));
      final n2 = state.graph.nodes.keys.last;

      // Select n1 first, then n2
      state.selectNode(n1, multiSelect: false);
      state.selectNode(n2, multiSelect: true);

      expect(state.primarySelectedNodeId, n1);
      expect(state.selectedNodeIds.contains(n1), true);
      expect(state.selectedNodeIds.contains(n2), true);
    });

    test('matchSelectedNodesSize updates all selected nodes to match first node size', () {
      state.addNodeAt('preview', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.graph.nodes[n1]!.width = 280;
      state.graph.nodes[n1]!.extraHeight = 220;

      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;
      state.graph.nodes[n2]!.width = 160;
      state.graph.nodes[n2]!.extraHeight = 120;

      // Select n1 (yellow primary), then n2 (blue secondary)
      state.selectNode(n1, multiSelect: false);
      state.selectNode(n2, multiSelect: true);

      expect(state.primarySelectedNodeId, n1);
      expect(state.graph.nodes[n2]!.width, 160);

      // Trigger size match
      state.matchSelectedNodesSize();

      expect(state.graph.nodes[n2]!.width, 280);
      expect(state.graph.nodes[n2]!.extraHeight, 220);
    });

    test('matchSelectedNodesWidth updates only width of secondary nodes', () {
      state.addNodeAt('preview', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.graph.nodes[n1]!.width = 300;
      state.graph.nodes[n1]!.extraHeight = 200;

      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;
      state.graph.nodes[n2]!.width = 160;
      state.graph.nodes[n2]!.extraHeight = 120;

      state.selectNode(n1, multiSelect: false);
      state.selectNode(n2, multiSelect: true);

      state.matchSelectedNodesWidth();

      expect(state.graph.nodes[n2]!.width, 300);
      expect(state.graph.nodes[n2]!.extraHeight, 120); // extraHeight unchanged
    });

    test('matchSelectedNodesHeight updates only height of secondary nodes', () {
      state.addNodeAt('preview', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.graph.nodes[n1]!.width = 300;
      state.graph.nodes[n1]!.extraHeight = 200;

      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;
      state.graph.nodes[n2]!.width = 160;
      state.graph.nodes[n2]!.extraHeight = 120;

      state.selectNode(n1, multiSelect: false);
      state.selectNode(n2, multiSelect: true);

      state.matchSelectedNodesHeight();

      expect(state.graph.nodes[n2]!.width, 160); // width unchanged
      expect(state.graph.nodes[n2]!.extraHeight, 200);
    });
  });
}
