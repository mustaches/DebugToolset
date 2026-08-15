import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  late ui.Image waveformImage;
  late ui.Image vectorscopeImage;

  setUpAll(() async {
    waveformImage = await createTestImage(width: 64, height: 256);
    vectorscopeImage = await createTestImage(width: 512, height: 512);
  });

  tearDownAll(() {
    waveformImage.dispose();
    vectorscopeImage.dispose();
  });

  Widget wrapNode(IspStudioState state, Widget child) =>
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(home: Scaffold(body: Center(child: child))),
      );

  testWidgets('示波器节点在 instrumentImages 设置后显示 RawImage',
      (tester) async {
    final state = IspStudioState();
    final node = IspNode.create(
        IspNodeRegistry.byId('waveform')!, 'wave1', 0, 0);
    state.graph.nodes[node.id] = node;
    state.instrumentResults[node.id] = {
      'kind': 'waveform',
      'columns': 64,
    };
    state.instrumentImages[node.id] = waveformImage;

    await tester.pumpWidget(wrapNode(
      state,
      IspNodeWidget(
        node: node,
        type: IspNodeRegistry.byId('waveform')!,
        selected: false,
        globalToCanvas: (o) => o,
        onConnectionDragEnd: () {},
        onToggleMaximize: () {},
        inputPortKeyFor: (_) => GlobalKey(),
      ),
    ));
    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('矢量示波器节点在 instrumentImages 设置后显示 RawImage',
      (tester) async {
    final state = IspStudioState();
    final node = IspNode.create(
        IspNodeRegistry.byId('vectorscope')!, 'vec1', 0, 0);
    state.graph.nodes[node.id] = node;
    state.instrumentResults[node.id] = {'kind': 'vectorscope'};
    state.instrumentImages[node.id] = vectorscopeImage;

    await tester.pumpWidget(wrapNode(
      state,
      IspNodeWidget(
        node: node,
        type: IspNodeRegistry.byId('vectorscope')!,
        selected: false,
        globalToCanvas: (o) => o,
        onConnectionDragEnd: () {},
        onToggleMaximize: () {},
        inputPortKeyFor: (_) => GlobalKey(),
      ),
    ));
    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('instrumentTick 触发后示波器节点从无图切换到 RawImage',
      (tester) async {
    final state = IspStudioState();
    final node = IspNode.create(
        IspNodeRegistry.byId('waveform')!, 'wave2', 0, 0);
    state.graph.nodes[node.id] = node;
    state.instrumentResults[node.id] = {
      'kind': 'waveform',
      'columns': 64,
    };

    await tester.pumpWidget(wrapNode(
      state,
      IspNodeWidget(
        node: node,
        type: IspNodeRegistry.byId('waveform')!,
        selected: false,
        globalToCanvas: (o) => o,
        onConnectionDragEnd: () {},
        onToggleMaximize: () {},
        inputPortKeyFor: (_) => GlobalKey(),
      ),
    ));
    await tester.pump();

    expect(find.text('未运行'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);

    state.instrumentImages[node.id] = waveformImage;
    state.instrumentTick.value++;
    await tester.pump();

    expect(find.text('未运行'), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('notifyListeners 与 instrumentTick 同时触发仍显示 RawImage',
      (tester) async {
    final state = IspStudioState();
    final node = IspNode.create(
        IspNodeRegistry.byId('waveform')!, 'wave3', 0, 0);
    state.graph.nodes[node.id] = node;
    state.instrumentResults[node.id] = {
      'kind': 'waveform',
      'columns': 64,
    };

    await tester.pumpWidget(wrapNode(
      state,
      IspNodeWidget(
        node: node,
        type: IspNodeRegistry.byId('waveform')!,
        selected: false,
        globalToCanvas: (o) => o,
        onConnectionDragEnd: () {},
        onToggleMaximize: () {},
        inputPortKeyFor: (_) => GlobalKey(),
      ),
    ));
    await tester.pump();

    expect(find.text('未运行'), findsOneWidget);

    state.instrumentImages[node.id] = waveformImage;
    state.instrumentTick.value++;
    state.notifyListeners();
    await tester.pump();

    expect(find.text('未运行'), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  });

  // 回归守卫：单次运行/暂停路径只调 notifyListeners（不递增
  // instrumentTick）时，仪器附加区也必须重建——ValueListenableBuilder
  // 复用 element 且 valueListenable 未变时不会重新调用 builder，
  // 若不递增 instrumentTick 会永远停在「未运行」。
  testWidgets('仅 notifyListeners（不递增 instrumentTick）时仪器区也应更新',
      (tester) async {
    final state = IspStudioState();
    final node = IspNode.create(
        IspNodeRegistry.byId('vectorscope')!, 'vec9', 0, 0);
    state.graph.nodes[node.id] = node;

    await tester.pumpWidget(wrapNode(
      state,
      IspNodeWidget(
        node: node,
        type: IspNodeRegistry.byId('vectorscope')!,
        selected: false,
        globalToCanvas: (o) => o,
        onConnectionDragEnd: () {},
        onToggleMaximize: () {},
        inputPortKeyFor: (_) => GlobalKey(),
      ),
    ));
    await tester.pump();
    expect(find.text('未运行'), findsOneWidget);

    // 模拟 runPreview 完成：设置图像后只 notifyListeners。
    state.instrumentImages[node.id] = vectorscopeImage;
    state.notifyListeners();
    await tester.pump();

    expect(find.text('未运行'), findsNothing,
        reason: 'notifyListeners 重建后仪器区应显示图像');
    expect(find.byType(RawImage), findsOneWidget);
  });
}
