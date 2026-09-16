import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/widgets/node_code_page.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  testWidgets('变量表 DEC/HEX 切换格式化运行数组值', (tester) async {
    final state = IspStudioState.withDefaultGraph();
    final srcId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'bayer_source')
        .key;
    // 模拟预览运行后的采样（2x2 马赛克）。
    state.nodeOutputCaptures = {
      srcId: {
        'format': 'mosaic',
        'length': 4,
        'width': 2,
        'height': 2,
        'sample': [255, 16, 0, 4095],
      },
    };

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: srcId)),
        ),
      ),
    );

    // 默认 DEC：三维坐标 + 十进制值。
    expect(find.text('(0, 0, 0)'), findsOneWidget);
    expect(find.text('255'), findsOneWidget);
    expect(find.text('4095'), findsOneWidget);

    // 切到 HEX：>0xFF 补 4 位，其余补 2 位。
    await tester.tap(find.text('HEX'));
    await tester.pump();
    expect(find.text('0xFF'), findsOneWidget);
    expect(find.text('0x10'), findsOneWidget);
    expect(find.text('0x0FFF'), findsOneWidget);

    // 切回 DEC。
    await tester.tap(find.text('DEC'));
    await tester.pump();
    expect(find.text('255'), findsOneWidget);
  });

  testWidgets('Input 区显示参数实际值与上游运行采样', (tester) async {
    final state = IspStudioState.withDefaultGraph();
    // 默认图：n1=bayer_source → n2=black_level。
    final srcId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'bayer_source')
        .key;
    final blId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'black_level')
        .key;

    // 未运行时：源节点的参数类输入直接显示实际参数值。
    final widthParam = state.graph.nodes[srcId]!.paramValues['width'];
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: srcId)),
        ),
      ),
    );
    expect(find.text('Input（参数值）'), findsOneWidget);
    expect(find.text('$widthParam'), findsWidgets);

    // 运行后：黑电平的 bayer 输入显示上游采样（三维坐标），
    // width/height 取上游帧尺寸，r/gr/gb/b 显示参数实际值。
    state.nodeOutputCaptures = {
      srcId: {
        'format': 'mosaic',
        'length': 4,
        'width': 2,
        'height': 2,
        'sample': [255, 16, 0, 4095],
      },
    };
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: blId)),
        ),
      ),
    );
    expect(find.text('Input（运行值）'), findsOneWidget);
    expect(find.text('(0, 0, 0)'), findsOneWidget); // bayer 数组坐标
    expect(find.text('255'), findsOneWidget);
    expect(find.text('2'), findsAtLeastNWidgets(2)); // width 与 height（另有代码行号）
    expect(find.text('0.0'), findsNWidgets(4)); // r / gr / gb / b 默认参数
  });

  testWidgets('GPU 端口回读合并表（无 sample）不视为运行采样', (tester) async {
    // GPU 路径预览后，端口回读（矢量示波器馈源等）会以 'port' →
    // {'data','width','height} 子表合并进 nodeOutputCaptures[节点]；
    // 源节点自身不在 GPU 采样之列，其表可能只有端口子表、没有 'sample'。
    // 代码页应将这类表按「未运行」处理而不是对 null sample 强转崩溃。
    final state = IspStudioState();
    addTearDown(state.dispose);
    final srcId = state.graph.addNode('image_source', 0, 0);
    final ccId = state.graph.addNode('color_controller', 220, 0);
    expect(state.graph.connect(srcId, 'out_hsl', ccId, 'in'), isNull);

    state.nodeOutputCaptures = {
      // 上游（源节点）：仅端口回读子表，无 sample。
      srcId: {
        'out_hsl': {'data': [0, 0, 0, 0], 'width': 2, 'height': 2},
      },
      // 本节点：真实采样 + 端口回读子表并存。
      ccId: {
        'format': 'hsl',
        'length': 12,
        'width': 2,
        'height': 2,
        'sample': List<int>.filled(12, 128),
        'out': {'data': [0, 0, 0, 0], 'width': 2, 'height': 2},
      },
    };

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: ccId)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('Input（未运行）'), findsOneWidget);
    expect(find.text('Output（运行值）'), findsOneWidget);

    // 源节点自身打开代码页同样不崩溃。
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: srcId)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('Output（未运行）'), findsOneWidget);
  });
}
