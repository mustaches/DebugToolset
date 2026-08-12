import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('IspStudioState Box Selection Tests', () {
    late IspStudioState state;

    setUp(() {
      state = IspStudioState.empty();
    });

    test('updateBoxSelection selects all nodes touched by the selection box', () {
      state.addNodeAt('image_source', const Offset(100, 100)); // width 190
      final n1 = state.graph.nodes.keys.first;

      state.addNodeAt('preview', const Offset(400, 100)); // width 190
      final n2 = state.graph.nodes.keys.last;

      state.addNodeAt('rgb_splitter', const Offset(800, 100)); // width 190
      final n3 = state.graph.nodes.keys.last;

      // Drag selection box from (50, 50) to (450, 250)
      // This box touches n1 (100..290) and n2 (400..590, touched at 400..450), but NOT n3 (800..990)
      state.updateBoxSelection(const Offset(50, 50), const Offset(450, 250));

      expect(state.selectionBoxRect, const Rect.fromLTRB(50, 50, 450, 250));
      expect(state.selectedNodeIds.contains(n1), true);
      expect(state.selectedNodeIds.contains(n2), true);
      expect(state.selectedNodeIds.contains(n3), false);

      // n1 was touched first in node loop or order
      expect(state.primarySelectedNodeId, n1);

      state.endBoxSelection();
      expect(state.selectionBoxRect, null);
    });

    test('updateBoxSelection with multiSelect appends touched nodes to current selection', () {
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;

      state.addNodeAt('preview', const Offset(400, 100));
      final n2 = state.graph.nodes.keys.last;

      // Select n1 first manually
      state.selectNode(n1, multiSelect: false);
      expect(state.primarySelectedNodeId, n1);

      // Box select over n2 with multiSelect = true
      state.updateBoxSelection(const Offset(350, 50), const Offset(600, 250),
          multiSelect: true);

      expect(state.selectedNodeIds.contains(n1), true);
      expect(state.selectedNodeIds.contains(n2), true);
      expect(state.primarySelectedNodeId, n1); // n1 remains primary

      state.endBoxSelection();
    });
  });
}
