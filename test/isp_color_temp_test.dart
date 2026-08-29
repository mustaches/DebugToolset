import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/color_temp.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  group('color_temp 模型', () {
    test('白点：色温越低 R 越大 B 越小，6500K 近似中性', () {
      final w3000 = cctToWhitePoint(3000);
      final w6500 = cctToWhitePoint(6500);
      final w12000 = cctToWhitePoint(12000);
      expect(w3000[0], greaterThan(w6500[0]), reason: '低色温 R 更强');
      expect(w3000[2], lessThan(w6500[2]), reason: '低色温 B 更弱');
      expect(w12000[0], lessThan(w6500[0]));
      expect(w12000[2], greaterThan(w6500[2]));
      for (final w in [w3000, w6500, w12000]) {
        expect(w[1], 1.0, reason: 'G 通道归一化为 1');
      }
    });

    test('增益：目标==参考恒等；目标更高偏冷（B 增 R 减）', () {
      expect(colorTempGains(5000, 5000), [1.0, 1.0, 1.0]);
      final cooler = colorTempGains(8000, 5000);
      expect(cooler[0], lessThan(1.0));
      expect(cooler[1], 1.0);
      expect(cooler[2], greaterThan(1.0));
      final warmer = colorTempGains(3000, 6500);
      expect(warmer[0], greaterThan(1.0));
      expect(warmer[2], lessThan(1.0));
      // 未测量（参考 <= 0）按 6500K 参考。
      expect(colorTempGains(6500, 0), [1.0, 1.0, 1.0]);
    });

    test('CCM 为增益对角阵', () {
      final ccm = colorTempCcm([0.7, 1.0, 1.6]);
      expect(ccm, [0.7, 0, 0, 0, 1.0, 0, 0, 0, 1.6]);
    });

    test('测量：中性灰约 5500K，暖图更低、冷图更高', () {
      Uint8List frame(int r, int g, int b) {
        final rgba = Uint8List(16 * 16 * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i] = r;
          rgba[i + 1] = g;
          rgba[i + 2] = b;
          rgba[i + 3] = 255;
        }
        return rgba;
      }

      final neutral = measureCctFromRgba(frame(128, 128, 128), 16, 16)!;
      expect(neutral, inInclusiveRange(4000, 7000),
          reason: '中性灰的 McCamy 估计应落在常见日光范围');
      final warm = measureCctFromRgba(frame(200, 140, 60), 16, 16)!;
      final cool = measureCctFromRgba(frame(60, 140, 200), 16, 16)!;
      expect(warm, lessThan(neutral));
      expect(cool, greaterThan(neutral));
      // 空帧/全黑返回 null。
      expect(measureCctFromRgba(Uint8List(0), 0, 0), isNull);
      expect(measureCctFromRgba(frame(0, 0, 0), 16, 16), isNull);
    });
  });

  group('color_temp_adjuster 节点', () {
    test('流水线集成：测量显示为按钮，点击后滑块设为测量值', () async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final srcId = state.graph.addNode('image_source', 0, 0);
      final ctId = state.graph.addNode('color_temp_adjuster', 220, 0);
      final pvId = state.graph.addNode('preview', 520, 0);
      state.setParam(srcId, 'filePath', 'IspFlow/DemoPhoto/1.jpg');
      expect(state.graph.connect(srcId, 'out_rgb', ctId, 'in'), isNull);
      expect(state.graph.connect(ctId, 'out_rgb', pvId, 'in'), isNull);

      Future<int> blueSum() async {
        await state.runPreview();
        expect(state.statusMessage, contains('预览就绪'),
            reason: '预览应成功: ${state.statusMessage}');
        final img = state.previewImages[pvId]!;
        final byteData =
            await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final px = byteData!.buffer.asUint8List();
        var sum = 0;
        for (var i = 0; i < px.length; i += 4) {
          sum += px[i + 2];
        }
        return sum;
      }

      // 运行：自动测量输入色温并显示，但滑块不被改动。
      final base = await blueSum();
      final measured = state.measuredColorTemps[ctId];
      expect(measured, isNotNull, reason: '应自动测量输入色温');
      final node = state.graph.nodes[ctId]!;
      expect((node.paramValues['temperature'] as num).round(), 6500,
          reason: '测量只更新显示，不应改动滑块');
      // 调整前/调整后预览图与调整后 RGB 直方图都应生成。
      expect(state.previewImages[ctId], isNotNull);
      expect(state.previewInputImages[ctId], isNotNull);
      final hist = state.colorTempHistograms[ctId];
      expect(hist, isNotNull, reason: '应生成调整后 RGB 直方图');
      expect(hist!.$1.fold<int>(0, (s, c) => s + c), greaterThan(0));

      // 点击测量值按钮：滑块设为测量值，参考基准同步（增益恒等）。
      await state.applyMeasuredColorTemp(ctId);
      expect((node.paramValues['temperature'] as num).round(), measured,
          reason: '点击测量值后滑块应设为测量值');
      expect(node.paramValues['measured_cct'], measured,
          reason: '参考色温应一并设为测量值');

      // 手动调高目标色温（偏冷）：B 通道总和应上升，且滑块不被测量覆盖。
      final target = (measured! + 3000).clamp(1800, 12000).toDouble();
      state.setParam(ctId, 'temperature', target);
      final shifted = await blueSum();
      expect((node.paramValues['temperature'] as num).round(),
          target.round(),
          reason: '手动设定后滑块不应被测量覆盖');
      expect(shifted, greaterThan(base), reason: '调高目标色温应偏冷（B 增）');
    });

    testWidgets('节点内嵌色温调试块（滑杆 + 测量值 + CCM 矩阵）', (tester) async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final id = state.graph.addNode('color_temp_adjuster', 0, 0);
      final node = state.graph.nodes[id]!;
      final type = IspNodeRegistry.byId('color_temp_adjuster')!;
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

      expect(find.text('1800K'), findsOneWidget);
      expect(find.text('12000K'), findsOneWidget);
      expect(find.text('CCM'), findsOneWidget);
      expect(find.text('测量: 未运行'), findsOneWidget);
      expect(find.text('目标: 6500 K'), findsOneWidget);
      expect(find.text('调整前'), findsOneWidget);
      expect(find.text('调整后'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      // 恒等（未测量按 6500 参考，目标 6500）：CCM 对角 3 个 1.000，
      // 非对角 6 个 0.000（9 个长方框）。
      expect(find.text('1.000'), findsNWidgets(3));
      expect(find.text('0.000'), findsNWidgets(6));

      // 默认尺寸：宽度加倍、附加区与显示类调节器一致（280）。
      expect(node.width, kNodeWidth * 2);
      expect(node.extraHeight, 280);
    });

    testWidgets('点击测量值按钮：滑块设为测量值', (tester) async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final id = state.graph.addNode('color_temp_adjuster', 0, 0);
      final node = state.graph.nodes[id]!;
      final type = IspNodeRegistry.byId('color_temp_adjuster')!;
      // 模拟一次运行后的测量结果。
      state.measuredColorTemps[id] = 4320;
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

      expect(find.text('测量: 4320 K'), findsOneWidget);
      await tester.tap(find.text('测量: 4320 K'));
      await tester.pump();
      expect((node.paramValues['temperature'] as num).round(), 4320,
          reason: '点击测量值后滑块应设为测量值');
      expect(node.paramValues['measured_cct'], 4320,
          reason: '参考色温应一并设为测量值');
    });

    testWidgets('右下角直方图区有数据时尺寸非零', (tester) async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final id = state.graph.addNode('color_temp_adjuster', 0, 0);
      final node = state.graph.nodes[id]!;
      final type = IspNodeRegistry.byId('color_temp_adjuster')!;
      // 模拟一次运行后的直方图数据。
      final hist = Uint32List(256)..[128] = 100;
      state.colorTempHistograms[id] = (hist, hist, hist);
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

      final histArea = find.byKey(const ValueKey('colorTempHist'));
      expect(histArea, findsOneWidget);
      final size = tester.getSize(histArea);
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0),
          reason: '有数据时直方图区不应塌缩为 0');
    });
  });
}
