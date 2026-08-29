import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  group('color_balance 色彩平衡', () {
    test('流水线集成：cyan_red 提升 R 通道，双联预览出图', () async {
      Future<(int, IspStudioState, String)> redSum(double cyanRed) async {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('image_source', 0, 0);
        final cbId = state.graph.addNode('color_balance', 220, 0);
        final pvId = state.graph.addNode('preview', 520, 0);
        state.setParam(srcId, 'filePath', 'IspFlow/DemoPhoto/1.jpg');
        state.setParam(cbId, 'cyan_red', cyanRed);
        expect(state.graph.connect(srcId, 'out_rgb', cbId, 'in'), isNull);
        expect(state.graph.connect(cbId, 'out_rgb', pvId, 'in'), isNull);
        await state.runPreview();
        expect(state.statusMessage, contains('预览就绪'),
            reason: '预览应成功: ${state.statusMessage}');
        final img = state.previewImages[pvId];
        expect(img, isNotNull);
        final byteData =
            await img!.toByteData(format: ui.ImageByteFormat.rawRgba);
        final px = byteData!.buffer.asUint8List();
        var sum = 0;
        for (var i = 0; i < px.length; i += 4) {
          sum += px[i];
        }
        return (sum, state, cbId);
      }

      final (base, baseState, baseCb) = await redSum(0);
      final (shifted, _, _) = await redSum(100);
      expect(shifted, greaterThan(base),
          reason: 'cyan_red=100 应提升中间调 R 通道');
      // 调节器自身的调整后/调整前预览图都应生成。
      expect(baseState.previewImages[baseCb], isNotNull,
          reason: '色彩平衡节点应有调整后预览图');
      expect(baseState.previewInputImages[baseCb], isNotNull,
          reason: '色彩平衡节点应有调整前预览图');
    });

    testWidgets('节点内嵌三行渐变滑杆调试块', (tester) async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final id = state.graph.addNode('color_balance', 0, 0);
      final node = state.graph.nodes[id]!;
      final type = IspNodeRegistry.byId('color_balance')!;
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

      // 三行滑杆的标签与滑块，双联预览的标签。
      for (final label in ['青色', '红色', '洋红', '绿色', '黄色', '蓝色']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('调整前'), findsOneWidget);
      expect(find.text('调整后'), findsOneWidget);
      final sliders = find.byType(Slider);
      expect(sliders, findsNWidgets(3));

      // 三行滑杆轨道中心应与节点中心对齐（行内左右装饰对称）。
      final nodeCenterX = tester.getCenter(find.byType(IspNodeWidget)).dx;
      for (var i = 0; i < 3; i++) {
        expect(tester.getCenter(sliders.at(i)).dx, closeTo(nodeCenterX, 0.5),
            reason: '第 ${i + 1} 行滑杆应与节点中心对齐');
      }

      // 默认尺寸：宽度加倍、附加区与显示类调节器一致（280）。
      expect(node.width, kNodeWidth * 2);
      expect(node.extraHeight, 280);
    });
  });
}
