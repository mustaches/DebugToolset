import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_align_mode.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_layout.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('IspStudioState 10px Grid Snapping Tests', () {
    late IspStudioState state;

    setUp(() {
      state = IspStudioState.empty();
    });

    test('snapToGrid rounds to nearest 10px multiple', () {
      expect(IspStudioState.snapToGrid(0), 0);
      expect(IspStudioState.snapToGrid(4.9), 0);
      expect(IspStudioState.snapToGrid(5.1), 10);
      expect(IspStudioState.snapToGrid(14.0), 10);
      expect(IspStudioState.snapToGrid(17.8), 20);
      expect(IspStudioState.snapToGrid(-12.3), -10);
    });

    test('addNodeAt snaps top-left corner (x, y) to 10px grid', () {
      state.addNodeAt('image_source', const Offset(104.3, 56.8));
      final node = state.graph.nodes.values.first;
      expect(node.x, 100.0);
      expect(node.y, 60.0);
    });

    test('Stepped dragging moves nodes in 10px grid steps', () {
      state.addNodeAt('image_source', const Offset(100, 100));
      final id = state.graph.nodes.keys.first;
      state.beginNodeDrag(id);

      // Drag 3px -> rounded to 100
      state.moveNode(id, const Offset(3, 3));
      expect(state.graph.nodes[id]!.x, 100.0);
      expect(state.graph.nodes[id]!.y, 100.0);

      // Drag accum total 6px -> rounded to 110
      state.moveNode(id, const Offset(3, 3));
      expect(state.graph.nodes[id]!.x, 110.0);
      expect(state.graph.nodes[id]!.y, 110.0);

      state.endNodeDrag();
    });

    test('框选多节点后拖动任一选中节点，整组同步移动', () {
      state.addNodeAt('image_source', const Offset(100, 100));
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('preview', const Offset(400, 200));
      final n2 = state.graph.nodes.keys.last;
      state.addNodeAt('rgb_splitter', const Offset(800, 100));
      final n3 = state.graph.nodes.keys.last;

      // 框选 n1、n2（不含 n3）。
      state.updateBoxSelection(const Offset(50, 50), const Offset(650, 350));
      state.endBoxSelection();
      expect(state.selectedNodeIds, containsAll([n1, n2]));

      state.beginNodeDrag(n2);
      state.moveNode(n2, const Offset(13, 7));
      // 组内两节点按网格同步移动（13→10、7→10），相对位置不变。
      expect(state.graph.nodes[n1]!.x, 110.0);
      expect(state.graph.nodes[n1]!.y, 110.0);
      expect(state.graph.nodes[n2]!.x, 410.0);
      expect(state.graph.nodes[n2]!.y, 210.0);
      // 未选中的 n3 不动。
      expect(state.graph.nodes[n3]!.x, 800.0);
      expect(state.graph.nodes[n3]!.y, 100.0);
      state.endNodeDrag();

      // 拖动不在多选集合内的节点：只移动它自己。
      state.beginNodeDrag(n3);
      state.moveNode(n3, const Offset(20, 0));
      expect(state.graph.nodes[n3]!.x, 820.0);
      expect(state.graph.nodes[n1]!.x, 110.0);
      expect(state.graph.nodes[n2]!.x, 410.0);
      state.endNodeDrag();
    });

    test('Align modes snap target positions to 10px grid', () {
      state.addNodeAt('image_source', const Offset(104, 53)); // snapped to 100, 50
      final n1 = state.graph.nodes.keys.first;
      state.addNodeAt('rgb_splitter', const Offset(307, 204)); // snapped to 310, 200
      final n2 = state.graph.nodes.keys.last;

      state.alignNodes(IspAlignMode.left);
      expect(state.graph.nodes[n1]!.x, 100.0);
      expect(state.graph.nodes[n2]!.x, 100.0);

      state.alignNodes(IspAlignMode.top);
      expect(state.graph.nodes[n1]!.y, 50.0);
      expect(state.graph.nodes[n2]!.y, 50.0);
    });

    test('Resizing bottom-right corner handle snaps bottom-right corner to 10px grid', () {
      state.addNodeAt('preview', const Offset(100, 100));
      final id = state.graph.nodes.keys.first;
      final node = state.graph.nodes[id]!;

      state.beginNodeResize(id);
      state.resizePreview(id, const Offset(13.4, 18.2));
      state.endNodeResize();

      final rightX = node.x + node.width;
      final type = IspNodeRegistry.byId(node.typeId)!;
      final bottomY = node.y + nodeHeight(type, previewExtraHeight: node.extraHeight);

      expect(rightX % 10.0, 0.0);
      expect(bottomY % 10.0, 0.0);
    });
  });
}
