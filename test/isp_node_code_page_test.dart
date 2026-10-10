import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_code_page.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  testWidgets('嵌入式节点显示 C 代码视图（文件树 + 只读页头）', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final srcId = state.graph.addNode('bayer_source', 0, 0);

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
    // 文件层次列表：共享层（isp_common.*）+ 本节点文件两组。
    expect(find.text('共享层'), findsOneWidget);
    expect(find.text('本节点文件'), findsOneWidget);
    // 节点页分组标题保持灰色小标题，不用亮蓝高亮背景（编组页才开启）。
    final sharedTitle = tester.widget<Text>(find.text('共享层'));
    expect(sharedTitle.style?.color, Colors.grey);
    final sharedAncestors = tester.widgetList<Container>(
      find.ancestor(
          of: find.text('共享层'), matching: find.byType(Container)),
    );
    expect(
      sharedAncestors.any((c) =>
          c.decoration is BoxDecoration &&
          (c.decoration! as BoxDecoration).color == const Color(0xFF007ACC)),
      isFalse,
    );
    expect(find.text('isp_common.h'), findsOneWidget);
    expect(find.text('isp_unpack.h'), findsOneWidget);
    expect(find.text('isp_unpack.c'), findsOneWidget);
    // C 视图顶部为编译工具栏（图标按钮）；「导出代码」已上移至工具栏。
    expect(find.byKey(const ValueKey('nodeCompileButton')), findsOneWidget);
    // 工具栏图标为 codicons PNG（编译 build + 导出 git-stash-pop；节点页
    // 无运行验证按钮）。
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byTooltip('导出代码'), findsOneWidget);
    // 终端面板默认不出现。
    expect(find.byKey(const ValueKey('nodeCompileTerminal')), findsNothing);
    // C 视图不显示变量表。
    expect(find.text('变量名'), findsNothing);

    // 切换选中文件（点击 .h 项）不崩溃。
    await tester.tap(find.text('isp_unpack.h'));
    await tester.pump();
    expect(find.text('只读'), findsOneWidget);

    // 「临时main调用（不导出）」分组展示空 main 版编译 stub（不进导出物）；
    // 其标题为红色底白字（0xFFC42B1C，节点页其余分组仍为灰色小标题）。
    expect(find.text('临时main调用（不导出）'), findsOneWidget);
    final mainTitle = tester.widget<Text>(find.text('临时main调用（不导出）'));
    expect(mainTitle.style?.color, Colors.white);
    final mainTitleAncestors = tester.widgetList<Container>(
      find.ancestor(
          of: find.text('临时main调用（不导出）'), matching: find.byType(Container)),
    );
    expect(
      mainTitleAncestors.any((c) =>
          c.decoration is BoxDecoration &&
          (c.decoration! as BoxDecoration).color == const Color(0xFFC42B1C)),
      isTrue,
    );
    expect(find.text('main.c'), findsOneWidget);
    await tester.tap(find.text('main.c'));
    await tester.pump();
    await tester.pump(); // FutureBuilder 等 stub future 微任务完成
    final stubShown = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .textSpan!
        .toPlainText();
    expect(stubShown, contains('int main(void) { return 0; }'));
    expect(stubShown, isNot(contains('_sbrk'))); // 通用形态不带 ARM 桩
  });

  testWidgets('PC 侧节点保留 Dart 视图并附说明横幅', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final id = state.graph.addNode('histogram', 0, 0);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: id)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('只读'), findsOneWidget);
    expect(
      find.textContaining('无嵌入式 C 参考实现，以下为 Dart 实现源码'),
      findsOneWidget,
    );
    // Dart 视图仍显示变量表。
    expect(find.text('变量名'), findsOneWidget);
    // PC 侧节点无编译工具栏。
    expect(find.byKey(const ValueKey('nodeCompileButton')), findsNothing);
  });

  testWidgets('C 视图编译：终端面板流式输出并转成功，可关闭', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final srcId = state.graph.addNode('gamma', 0, 0);

    // 假编译器：回调两行输出后返回成功。
    GroupCompileRunner fakeRunner() {
      return (files, target, {topName, compilerPath, onOutput}) async {
        onOutput?.call('fake 节点编译输出第一行\n');
        onOutput?.call('fake 节点编译输出第二行\n');
        return CCompileResult(
          success: true,
          exitCode: 0,
          commandLine: 'fake-cl',
          output: 'fake out',
          workDir: r'C:\tmp\fake',
          artifactPath: r'C:\tmp\fake\app.exe',
          sourceCount: files.length,
        );
      };
    }

    // 编译文件加载注入假实现：c_ref 资产为真实 IO，在 widget 测试的
    // 假异步区内不会按 pump 完成（缓存还会被先跑的用例污染），注入后
    // 完全不碰 IO。
    Future<Map<String, String>> fakeFilesLoader(List<String> files) =>
        Future.value({for (final f in files) f: '/* $f */\n'});
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
              body: NodeCodePage(
                  nodeId: srcId,
                  compileRunner: fakeRunner(),
                  filesLoader: fakeFilesLoader)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('nodeCompileButton')), findsOneWidget);

    // 工具栏「编译」→ 对话框确认开始 → 终端面板打开并显示流式输出。
    await tester.tap(find.byKey(const ValueKey('nodeCompileButton')));
    await tester.pump();
    expect(find.text('编译验证'), findsOneWidget);
    await tester.tap(find.text('开始编译'));
    // 对话框返回 → 读文件 → 假编译器，链路多为微任务，轮询 pump 到状态出现。
    for (var i = 0; i < 20 && find.text('成功').evaluate().isEmpty; i++) {
      await tester.pump();
    }

    expect(find.byKey(const ValueKey('nodeCompileTerminal')), findsOneWidget);
    expect(find.text('编译 — X86'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.textContaining('fake 节点编译输出第一行'), findsOneWidget);
    expect(find.textContaining('fake 节点编译输出第二行'), findsOneWidget);

    // 非编译中可关闭终端。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byKey(const ValueKey('nodeCompileTerminal')), findsNothing);
  });

  testWidgets('变量表 DEC/HEX 切换格式化运行数组值', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    // preview 为 PC 侧节点（Dart 视图 + 变量表），输出 rgba 为 Uint8List。
    final srcId = state.graph.addNode('preview', 0, 0);
    // 模拟预览运行后的采样（2x2 单通道）。
    state.nodeOutputCaptures = {
      srcId: {
        'format': 'mono',
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
    expect(find.text('255'), findsWidgets);
    expect(find.text('4095'), findsWidgets);

    // 切到 HEX：>0xFF 补 4 位，其余补 2 位。
    await tester.tap(find.text('HEX'));
    await tester.pump();
    expect(find.text('0xFF'), findsWidgets);
    expect(find.text('0x10'), findsWidgets);
    expect(find.text('0x0FFF'), findsWidgets);

    // 切回 DEC。
    await tester.tap(find.text('DEC'));
    await tester.pump();
    expect(find.text('255'), findsWidgets);
  });

  testWidgets('Input 区显示参数实际值与上游运行采样', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    // PC 侧节点：video_source（源，参数类输入）→ image_output（汇）。
    final srcId = state.graph.addNode('video_source', 0, 0);
    final outId = state.graph.addNode('image_output', 220, 0);
    expect(state.graph.connect(srcId, 'out_rgb', outId, 'in'), isNull);

    // 未运行时：源节点的参数类输入直接显示实际参数值
    //（ffmpegPath 取参数实际值；maxValue 按 bitDepth=8 推导为 255）。
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: srcId)),
        ),
      ),
    );
    expect(find.text('Input（参数值）'), findsOneWidget);
    expect(find.text('tools/ffmpeg/ffmpeg.exe'), findsWidgets);
    expect(find.text('255'), findsWidgets); // maxValue（2^8-1）

    // 运行后：图片输出的 rgba 输入显示上游采样（三维坐标），
    // width/height 取上游帧尺寸，format/quality 显示参数实际值。
    state.nodeOutputCaptures = {
      srcId: {
        'format': 'mono',
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
          home: Scaffold(body: NodeCodePage(nodeId: outId)),
        ),
      ),
    );
    expect(find.text('Input（运行值）'), findsOneWidget);
    expect(find.text('(0, 0, 0)'), findsOneWidget); // rgba 数组坐标
    expect(find.text('255'), findsWidgets);
    expect(find.text('2'), findsAtLeastNWidgets(2)); // width 与 height（另有代码行号）
    expect(find.text('jpg'), findsWidgets); // format 参数
    expect(find.text('100'), findsWidgets); // quality 参数
  });

  testWidgets('GPU 端口回读合并表（无 sample）不视为运行采样', (tester) async {
    // GPU 路径预览后，端口回读（矢量示波器馈源等）会以 'port' →
    // {'data','width','height} 子表合并进 nodeOutputCaptures[节点]；
    // 源节点自身不在 GPU 采样之列，其表可能只有端口子表、没有 'sample'。
    // 代码页应将这类表按「未运行」处理而不是对 null sample 强转崩溃。
    final state = IspStudioState();
    addTearDown(state.dispose);
    final srcId = state.graph.addNode('image_source', 0, 0);
    // PC 侧汇节点（Dart 视图）：image_output。
    final outId = state.graph.addNode('image_output', 220, 0);
    expect(state.graph.connect(srcId, 'out_rgb', outId, 'in'), isNull);

    state.nodeOutputCaptures = {
      // 上游（源节点）：仅端口回读子表，无 sample。
      srcId: {
        'out_rgb': {'data': [0, 0, 0, 0], 'width': 2, 'height': 2},
      },
      // 本节点：真实采样 + 端口回读子表并存。
      outId: {
        'format': 'rgb',
        'length': 12,
        'width': 2,
        'height': 2,
        'sample': List<int>.filled(12, 128),
        'in': {'data': [0, 0, 0, 0], 'width': 2, 'height': 2},
      },
    };

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: NodeCodePage(nodeId: outId)),
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
