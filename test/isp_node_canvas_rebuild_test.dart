import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  late ui.Image testImage;

  setUpAll(() async {
    testImage = await createTestImage(width: 512, height: 512);
  });

  tearDownAll(() {
    testImage.dispose();
  });

  // 复现真实画布结构：ChangeNotifierProvider → Stack > Positioned > IspNodeWidget，
  // 与 node_canvas.dart 一致。验证 notifyListeners（runPreview 路径）后
  // vectorscope 节点仪器区从「未运行」切换为 RawImage。
  testWidgets('画布结构下 notifyListeners 后 vectorscope 仪器区更新',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    final node = IspNode.create(
        IspNodeRegistry.byId('vectorscope')!, 'n25', 0, 0);
    state.graph.nodes[node.id] = node;

    Widget buildApp() => ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: node.x,
                    top: node.y,
                    child: IspNodeWidget(
                      node: node,
                      type: IspNodeRegistry.byId('vectorscope')!,
                      selected: false,
                      globalToCanvas: (o) => o,
                      onConnectionDragEnd: () {},
                      onToggleMaximize: () {},
                      inputPortKeyFor: (_) => GlobalKey(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    await tester.pumpWidget(buildApp());
    await tester.pump();
    expect(find.text('未运行'), findsOneWidget,
        reason: '初始应显示「未运行」');

    // 模拟 runPreview 完成：写入图像 + 仅 notifyListeners（与
    // _runInstruments 末尾的行为一致，不递增 instrumentTick）。
    state.instrumentImages[node.id] = testImage;
    state.notifyListeners();
    await tester.pump();

    expect(find.text('未运行'), findsNothing,
        reason: 'notifyListeners 重建后不应再显示「未运行」');
    // 节点内还有 image==null 的小图标 RawImage（端口/角标占位），按渲染
    // 的图像对象过滤后才指向仪器附加区本身。
    expect(
      find.byWidgetPredicate((w) => w is RawImage && w.image == testImage),
      findsOneWidget,
      reason: '应显示 vectorscope RawImage',
    );
  });
}
