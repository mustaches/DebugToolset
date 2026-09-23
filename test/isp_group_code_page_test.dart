import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/code_browser.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/group_code_page.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/group_compile_dialog.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 递归收集 span 树的 (文本, 样式) 叶段。
  List<(String, TextStyle?)> collectLeafSpans(TextSpan root) {
    final out = <(String, TextStyle?)>[];
    void visit(TextSpan s) {
      if (s.text != null) out.add((s.text!, s.style));
      for (final c in s.children ?? const <InlineSpan>[]) {
        if (c is TextSpan) visit(c);
      }
    }

    visit(root);
    return out;
  }

  /// 叶段中是否存在覆盖 [text] 且黄底黑字（悬停高亮样式）的段。
  bool hasIdentHl(List<(String, TextStyle?)> leaves, String text) =>
      leaves.any(
        (p) =>
            p.$1 == text &&
            p.$2?.backgroundColor == const Color(0xFFFFF176) &&
            p.$2?.color == Colors.black,
      );

  /// 搭一个可导出 C 的编组：white_balance → gamma。
  (IspStudioState, String) makeGroup() {
    final state = IspStudioState();
    final wb = state.graph.addNode('white_balance', 0, 0);
    final gamma = state.graph.addNode('gamma', 200, 0);
    expect(state.graph.connect(wb, 'out', gamma, 'in'), isNull);
    state.graph.groups.add(IspNodeGroup('g1', {wb, gamma}, name: 'pipe'));
    return (state, 'g1');
  }

  Widget wrap(IspStudioState state, String groupId,
      {GroupCompileRunner? compileRunner,
      Future<Map<String, String>> Function(IspGraph, IspNodeGroup)?
          filesBuilder}) {
    return ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
            body: GroupCodePage(
                groupId: groupId,
                compileRunner: compileRunner,
                filesBuilder: filesBuilder)),
      ),
    );
  }

  /// 立即返回的假文件集（绕开 rootBundle 真实资产 IO，widget 测试用）。
  Future<Map<String, String>> fakeFiles(IspGraph graph, IspNodeGroup group) {
    return Future.value({
      'wb.h': '/* wb.h */\n',
      'wb.c': '/* wb.c */\n',
      'isp_pipeline_pipe.h': '/* top h */\n',
      'isp_pipeline_pipe.c': '/* top c */\nint isp_pipeline_pipe_run(void);\n',
      'isp_common.h': '/* common h */\n',
      'isp_common.c': '/* common c */\n',
    });
  }

  /// 「Go to REF」悬停测试用假文件集：top 层 isp_pipeline_pipe.c（默认
  /// 选中）第 2 行调用 isp_wb_run，其定义在 wb.c 第 2 行；第 6 行（0-based）
  /// 引用宏 ISP_OK，其定义在 isp_common.h 第 2 行。
  Future<Map<String, String>> fakeRefFiles(
      IspGraph graph, IspNodeGroup group) {
    return Future.value({
      'wb.h': '/* wb.h */\n',
      'wb.c': '/* wb.c */\nint isp_wb_run(void) {\n  return 0;\n}\n',
      'isp_pipeline_pipe.h': '/* top h */\n',
      'isp_pipeline_pipe.c':
          '/* top c */\nint isp_pipeline_pipe_run(void) {\n  return isp_wb_run();\n}\n\nint check_ok(void) {\n  if (ISP_OK == 0) {\n    return 1;\n  }\n  return 0;\n}\n',
      'isp_common.h': '/* common h */\n#define ISP_OK 0\n',
    });
  }

  /// 立即成功的假编译器：回调两行输出后返回成功结果。
  GroupCompileRunner fakeCompileOk() {
    return (files, target, {topName, compilerPath, onOutput}) async {
      onOutput?.call('fake 编译器输出第一行\n');
      onOutput?.call('fake 输出第二行\n');
      return CCompileResult(
        success: true,
        exitCode: 0,
        commandLine: 'fake-cl $topName',
        output: 'fake out',
        workDir: r'C:\tmp\fake',
        artifactPath: r'C:\tmp\fake\app.exe',
        sourceCount: 3,
      );
    };
  }

  testWidgets('编组代码页：文件树三分组 + 只读页头 + 导出按钮', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state, groupId, filesBuilder: fakeFiles));
    await tester.pump();
    await tester.pump();

    expect(find.text('只读'), findsOneWidget);
    // 文件清单分组：顶层 / 节点封装 / 算法参考。
    expect(find.text('顶层'), findsOneWidget);
    expect(find.text('节点封装'), findsOneWidget);
    expect(find.text('算法参考（c_ref）'), findsOneWidget);
    // 大类分组标题：亮蓝色高亮背景（VSCode 主题蓝 0xFF007ACC）整行铺满 + 白字。
    for (final label in ['顶层', '节点封装', '算法参考（c_ref）']) {
      final title = tester.widget<Text>(find.text(label));
      expect(title.style?.color, Colors.white, reason: label);
      final ancestors = tester.widgetList<Container>(
        find.ancestor(
            of: find.text(label), matching: find.byType(Container)),
      );
      expect(
        ancestors.any((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).color ==
                const Color(0xFF007ACC)),
        isTrue,
        reason: label,
      );
    }
    // top 层与 c_ref 共享层文件在列。
    expect(find.text('isp_pipeline_pipe.h'), findsOneWidget);
    expect(find.text('isp_pipeline_pipe.c'), findsOneWidget);
    expect(find.text('isp_common.h'), findsOneWidget);
    // 文件条目左缩进两个字符（原 padding 10 + 字号 11 × 2 = 32），
    // 从属于大类分组标题。
    for (final file in ['isp_pipeline_pipe.h', 'isp_common.h']) {
      final item = tester.widget<Container>(
        find
            .ancestor(
                of: find.text(file), matching: find.byType(Container))
            .first,
      );
      expect(item.padding, const EdgeInsets.fromLTRB(32, 4, 10, 4),
          reason: file);
    }
    // 「导出代码」保留在文件清单底部；「编译」在页头下方工具栏。
    expect(find.text('导出代码'), findsOneWidget);
    expect(find.text('编译'), findsOneWidget);
    expect(find.byKey(const ValueKey('groupCompileButton')), findsOneWidget);
    // 编译按钮图标为自绘 VS「生成项目」风格 SVG（锤子 + 砖墙）。
    expect(find.byType(SvgPicture), findsOneWidget);

    // 点工具栏「编译」弹出编译验证对话框（只做目标选择，不执行编译）。
    await tester.tap(find.byKey(const ValueKey('groupCompileButton')));
    await tester.pump();
    expect(find.text('编译验证'), findsOneWidget);
    expect(find.text('X86（本机 MSVC）'), findsOneWidget);
    expect(find.text('ARM（arm-none-eabi-gcc）'), findsOneWidget);
    expect(find.text('Linux 交叉'), findsOneWidget);
    expect(find.text('开始编译'), findsOneWidget);
    // 取消对话框，回到代码页，终端不出现。
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.text('编译验证'), findsNothing);
    expect(find.byKey(const ValueKey('groupCompileTerminal')), findsNothing);

    // 切换选中文件（点击 .h 项）不崩溃。
    await tester.tap(find.text('isp_pipeline_pipe.h'));
    await tester.pump();
    expect(find.text('只读'), findsOneWidget);

    // 「临时main调用（不导出）」分组展示编译 stub main.c（通用形态，不进导出物）；
    // 其标题为红色底白字（VS 系红 0xFFC42B1C），其它分组仍为亮蓝。
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
    expect(
      mainTitleAncestors.any((c) =>
          c.decoration is BoxDecoration &&
          (c.decoration! as BoxDecoration).color == const Color(0xFF007ACC)),
      isFalse,
    );
    expect(find.text('main.c'), findsOneWidget);
    await tester.tap(find.text('main.c'));
    await tester.pump();
    final stubShown = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .textSpan!
        .toPlainText();
    expect(stubShown, contains('volatile entry'));
    expect(stubShown, contains('isp_pipeline_pipe_run'));
    expect(stubShown, isNot(contains('_sbrk'))); // 通用形态不带 ARM 桩
  });

  testWidgets('悬停函数调用显示 Go to REF，点击跳转定义文件', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state, groupId, filesBuilder: fakeRefFiles));
    await tester.pump();
    await tester.pump();
    expect(find.text('只读'), findsOneWidget);

    // 行高 = 12 × 1.45 = 17.4；前缀宽度用同款 TextPainter 实测（适配
    // 测试环境 Ahem 字体）。
    final lineHeight =
        kCodeBrowserStyle.fontSize! * kCodeBrowserStyle.height!;
    TextPainter measure(String s) => TextPainter(
          text: TextSpan(text: s, style: kCodeBrowserStyle),
          textDirection: TextDirection.ltr,
        )..layout();
    final prefix = measure('  return ');
    addTearDown(prefix.dispose);

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);

    // 悬停第 2 行（0-based）`  return isp_wb_run();` 中的 isp_wb_run 上。
    final codeTopLeft =
        tester.getTopLeft(find.byType(SelectableText).first);
    await gesture.moveTo(
        codeTopLeft + Offset(prefix.width + 2, 2 * lineHeight + 8));
    await tester.pump();
    expect(find.text('Go to REF'), findsOneWidget);

    // 点击跳转：弹层消失，左侧选中 wb.c，代码区显示其内容（含定义行）。
    await tester.tap(find.text('Go to REF'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Go to REF'), findsNothing);
    final shown = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .textSpan!
        .toPlainText();
    expect(shown, contains('int isp_wb_run(void) {'));

    // 悬停非索引标识符（wb.c 第 2 行的 return）不出弹层。
    final indent = measure('  ');
    addTearDown(indent.dispose);
    final topLeft2 =
        tester.getTopLeft(find.byType(SelectableText).first);
    await gesture.moveTo(
        topLeft2 + Offset(indent.width + 2, 2 * lineHeight + 8));
    await tester.pump();
    expect(find.text('Go to REF'), findsNothing);

    // 移出代码区，确保无遗留弹层。
    await gesture.moveTo(Offset.zero);
    await tester.pump();
  });

  testWidgets('悬停分屏预览：出现、空白不收起、右栏悬停保持、× 仅关预览',
      (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state, groupId, filesBuilder: fakeRefFiles));
    await tester.pump();
    await tester.pump();
    expect(find.text('只读'), findsOneWidget);
    // 预览未打开（终端未开）：仅左栏一个 SelectableText。
    expect(find.byType(SelectableText), findsOneWidget);

    final lineHeight =
        kCodeBrowserStyle.fontSize! * kCodeBrowserStyle.height!;
    TextPainter measure(String s) => TextPainter(
          text: TextSpan(text: s, style: kCodeBrowserStyle),
          textDirection: TextDirection.ltr,
        )..layout();
    final prefix = measure('  return ');
    addTearDown(prefix.dispose);

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);

    /// 左栏第 2 行（0-based）`  return isp_wb_run();` 内横向 dx 处。
    Offset hoverAt(double dx) =>
        tester.getTopLeft(find.byType(SelectableText).first) +
        Offset(dx, 2 * lineHeight + 8);
    List<SelectableText> panes() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .toList();

    // 1) 悬停 isp_wb_run → 左右分屏：右栏为定义预览，标题栏含函数名、
    // 「文件:行号」与「Go to REF」按钮。
    await gesture.moveTo(hoverAt(prefix.width + 2));
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(panes()[0].textSpan!.toPlainText(),
        contains('int isp_pipeline_pipe_run(void) {'));
    expect(panes()[1].textSpan!.toPlainText(),
        contains('int isp_wb_run(void) {'));
    expect(find.text('isp_wb_run'), findsOneWidget);
    expect(find.text('wb.c:2'), findsOneWidget);
    expect(find.text('Go to REF'), findsOneWidget);

    // 2) 悬停到非索引位置（return 关键字）预览不收起。
    final indent = measure('  ');
    addTearDown(indent.dispose);
    await gesture.moveTo(hoverAt(indent.width + 2));
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.text('wb.c:2'), findsOneWidget);

    // 3) 鼠标移入右栏，预览不收起（预览只能由用户显式关闭）。
    await gesture.moveTo(tester.getCenter(find.text('wb.c:2')));
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));

    // 4) 鼠标移出代码区到页外位置，等 500ms 预览仍在（不自动收起）。
    await gesture.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.text('wb.c:2'), findsOneWidget);

    // 5) 点 × 仅关预览不跳文件：回到单栏，主视图仍是 isp_pipeline_pipe.c。
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Go to REF'), findsNothing);
    expect(find.text('wb.c:2'), findsNothing);
    final shown = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!
        .toPlainText();
    expect(shown, contains('int isp_pipeline_pipe_run(void) {'));
    expect(shown, contains('return isp_wb_run();'));
  });

  testWidgets('悬停高亮：左栏标识符与右栏定义处黄底黑字，移开保持，新悬停替换',
      (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state, groupId, filesBuilder: fakeRefFiles));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);

    final lineHeight =
        kCodeBrowserStyle.fontSize! * kCodeBrowserStyle.height!;
    TextPainter measure(String s) => TextPainter(
          text: TextSpan(text: s, style: kCodeBrowserStyle),
          textDirection: TextDirection.ltr,
        )..layout();
    final prefix = measure('  return ');
    addTearDown(prefix.dispose);

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);

    Offset hoverAt(double dx, [int line = 2]) =>
        tester.getTopLeft(find.byType(SelectableText).first) +
        Offset(dx, line * lineHeight + 8);
    List<SelectableText> panes() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .toList();

    // 悬停 isp_wb_run：左栏该标识符与右栏定义行上的名字都黄底黑字高亮。
    await gesture.moveTo(hoverAt(prefix.width + 2));
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(hasIdentHl(collectLeafSpans(panes()[0].textSpan!), 'isp_wb_run'),
        isTrue);
    expect(hasIdentHl(collectLeafSpans(panes()[1].textSpan!), 'isp_wb_run'),
        isTrue);

    // 移到非索引标识符（return）：高亮粘性保持（isp_wb_run 仍亮），
    // 预览保持不收起。
    final indent = measure('  ');
    addTearDown(indent.dispose);
    await gesture.moveTo(hoverAt(indent.width + 2));
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.text('wb.c:2'), findsOneWidget);
    expect(hasIdentHl(collectLeafSpans(panes()[0].textSpan!), 'isp_wb_run'),
        isTrue);
    // 右栏定义处高亮同样不随左栏悬停移动变化。
    expect(hasIdentHl(collectLeafSpans(panes()[1].textSpan!), 'isp_wb_run'),
        isTrue);

    // 悬停到另一个索引内标识符 isp_pipeline_pipe_run（其定义就在本行，
    // 不切换预览）：旧高亮熄灭、新标识符亮起。
    final intPrefix = measure('int ');
    addTearDown(intPrefix.dispose);
    await gesture.moveTo(hoverAt(intPrefix.width + 2, 1));
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.text('wb.c:2'), findsOneWidget);
    expect(hasIdentHl(collectLeafSpans(panes()[0].textSpan!), 'isp_wb_run'),
        isFalse);
    expect(
        hasIdentHl(
            collectLeafSpans(panes()[0].textSpan!), 'isp_pipeline_pipe_run'),
        isTrue);
    // 右栏定义处高亮不随左栏悬停切换变化。
    expect(hasIdentHl(collectLeafSpans(panes()[1].textSpan!), 'isp_wb_run'),
        isTrue);

    // × 收尾：回到单栏，主视图仍是 isp_pipeline_pipe.c。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('wb.c:2'), findsNothing);

    // 移出代码区，确保无遗留状态。
    await gesture.moveTo(Offset.zero);
    await tester.pump();
  });

  testWidgets('预览标题栏「Go to REF」：关闭预览并正式跳转主视图', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state, groupId, filesBuilder: fakeRefFiles));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);

    final lineHeight =
        kCodeBrowserStyle.fontSize! * kCodeBrowserStyle.height!;
    final prefix = TextPainter(
      text: TextSpan(text: '  return ', style: kCodeBrowserStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    addTearDown(prefix.dispose);

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);

    // 悬停 isp_wb_run 打开分屏预览。
    await gesture.moveTo(tester.getTopLeft(find.byType(SelectableText)) +
        Offset(prefix.width + 2, 2 * lineHeight + 8));
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.text('Go to REF'), findsOneWidget);

    // 点「Go to REF」：预览关闭，主视图切到 wb.c 定义处。
    await tester.tap(find.text('Go to REF'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Go to REF'), findsNothing);
    expect(find.text('wb.c:2'), findsNothing);
    final shown = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!
        .toPlainText();
    expect(shown, contains('int isp_wb_run(void) {'));
    expect(shown, isNot(contains('int isp_pipeline_pipe_run(void) {')));
  });

  testWidgets('悬停宏名显示分屏预览（#define 定义行）并可用 × 收尾', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state, groupId, filesBuilder: fakeRefFiles));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);

    final lineHeight =
        kCodeBrowserStyle.fontSize! * kCodeBrowserStyle.height!;
    final prefix = TextPainter(
      text: TextSpan(text: '  if (', style: kCodeBrowserStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    addTearDown(prefix.dispose);

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);

    // 悬停第 6 行（0-based）`  if (ISP_OK == 0) {` 中的 ISP_OK 上。
    await gesture.moveTo(tester.getTopLeft(find.byType(SelectableText)) +
        Offset(prefix.width + 2, 6 * lineHeight + 8));
    await tester.pump();

    // 分屏预览出现：右栏为 isp_common.h（含 #define 定义行），标题栏显示
    // 宏名、「文件:行号」与「Go to REF」。
    expect(find.byType(SelectableText), findsNWidgets(2));
    final panes = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .toList();
    expect(panes[0].textSpan!.toPlainText(),
        contains('int isp_pipeline_pipe_run(void) {'));
    expect(panes[1].textSpan!.toPlainText(), contains('#define ISP_OK 0'));
    expect(find.text('ISP_OK'), findsOneWidget);
    expect(find.text('isp_common.h:2'), findsOneWidget);
    expect(find.text('Go to REF'), findsOneWidget);

    // 左栏悬停处与右栏 #define 定义行上的 ISP_OK 均黄底黑字高亮。
    expect(hasIdentHl(collectLeafSpans(panes[0].textSpan!), 'ISP_OK'), isTrue);
    expect(hasIdentHl(collectLeafSpans(panes[1].textSpan!), 'ISP_OK'), isTrue);

    // 点 × 收尾：回到单栏，主视图仍是 isp_pipeline_pipe.c。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Go to REF'), findsNothing);
    expect(find.text('isp_common.h:2'), findsNothing);
    final shown = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!
        .toPlainText();
    expect(shown, contains('if (ISP_OK == 0) {'));

    // 移出代码区，确保无遗留弹层。
    await gesture.moveTo(Offset.zero);
    await tester.pump();
  });

  testWidgets('编组解散后显示占位', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state, groupId, filesBuilder: fakeFiles));
    await tester.pump();
    await tester.pump();
    expect(find.text('只读'), findsOneWidget);

    state.ungroup(groupId);
    await tester.pump();
    expect(find.text('编组已被解散'), findsOneWidget);
  });

  testWidgets('生成抛错时显示错误信息而非卡在生成中', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    Future<Map<String, String>> throwingBuilder(
        IspGraph graph, IspNodeGroup group) async {
      throw StateError('节点 X 的输出 out 既不是组内边也不是组输出');
    }

    await tester
        .pumpWidget(wrap(state, groupId, filesBuilder: throwingBuilder));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('生成代码失败'), findsOneWidget);
    expect(find.textContaining('既不是组内边也不是组输出'), findsOneWidget);
    expect(find.text('生成中…'), findsNothing);
  });

  testWidgets('校验不过的编组显示错误原因而非文件树', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    // histogram 为 PC 侧节点，不在可导出 C 类型之列。
    final h = state.graph.addNode('histogram', 0, 0);
    final g = state.graph.addNode('gamma', 200, 0);
    state.graph.groups.add(IspNodeGroup('g1', {h, g}, name: 'bad'));

    await tester.pumpWidget(wrap(state, 'g1'));
    await tester.pump();

    expect(find.text('只读'), findsOneWidget);
    expect(find.textContaining('暂不支持导出 C 代码'), findsOneWidget);
    expect(find.text('顶层'), findsNothing);
  });

  test('openGroupCodeTab / ungroup 的标签生命周期', () {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    // 不存在的编组不打开标签。
    state.openGroupCodeTab('gx');
    expect(state.openCodeTabs, isEmpty);

    state.openGroupCodeTab(groupId);
    expect(state.openCodeTabs, ['group:$groupId']);
    expect(state.activeTab, 1);
    // 重复打开只激活不重复添加。
    state.openGroupCodeTab(groupId);
    expect(state.openCodeTabs.length, 1);

    // 解散编组自动关闭其标签。
    state.ungroup(groupId);
    expect(state.openCodeTabs, isEmpty);
    expect(state.activeTab, 0);
  });

  testWidgets('编译后终端面板出现并流式打印，状态转成功', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);

    // 文件生成注入假实现（立即返回，不依赖 rootBundle 资产 IO）。
    await tester.pumpWidget(wrap(state, groupId,
        compileRunner: fakeCompileOk(), filesBuilder: fakeFiles));
    await tester.pump();
    await tester.pump();
    // 默认无终端面板。
    expect(find.byKey(const ValueKey('groupCompileTerminal')), findsNothing);

    // 工具栏「编译」→ 对话框确认开始 → 终端面板打开并显示流式输出。
    await tester.tap(find.byKey(const ValueKey('groupCompileButton')));
    await tester.pump();
    await tester.tap(find.text('开始编译'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('groupCompileTerminal')), findsOneWidget);
    expect(find.text('编译 — X86'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.textContaining('fake 编译器输出第一行'), findsOneWidget);
    expect(find.textContaining('fake 输出第二行'), findsOneWidget);

    // 终端高度约为代码区的 1/3（Expanded flex 3 : 1）。
    final termH =
        tester.getSize(find.byKey(const ValueKey('groupCompileTerminal'))).height;
    final codeH = tester.getSize(find.byType(CodeArea)).height;
    expect(codeH / termH, closeTo(3, 0.1));

    // 关闭终端（非编译中可关），代码区恢复占满。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byKey(const ValueKey('groupCompileTerminal')), findsNothing);
  });

  /// 直接泵编译对话框（注入 fake WSL 探测，不依赖真机 WSL 时序）。
  Future<void> pumpDialog(WidgetTester tester, WslProber prober) {
    sessionCompilerPaths.clear(); // 会话内手动路径，跨用例隔离
    return tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GroupCompileDialog(wslProber: prober))));
  }

  String pathFieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('Linux 交叉探测：等待态 → 成功回填（不覆盖用户输入）', (tester) async {
    final gate = Completer<CToolchain?>();
    await pumpDialog(tester, ({Duration? startupTimeout, Duration? timeout, onPhase}) => gate.future);
    await tester.tap(find.text('Linux 交叉'));
    await tester.pump();
    // 探测中：环形进度 + 等待文案（初始为 WSL 启动阶段），路径框可输入。
    expect(find.text('正在启动 WSL…'), findsOneWidget);

    // 探测期间用户手动输入：探测完成后不覆盖用户内容。
    await tester.enterText(find.byType(TextField), 'user-gcc');
    gate.complete(const CToolchain(
        CCompileTarget.linuxCross, 'wsl:Ubuntu:/home/x/gcc', {}));
    await tester.pump();
    expect(find.text('已自动探测到交叉编译器'), findsOneWidget);
    expect(pathFieldText(tester), 'user-gcc');
  });

  testWidgets('Linux 交叉探测：路径框为空时成功回填', (tester) async {
    final gate = Completer<CToolchain?>();
    await pumpDialog(tester, ({Duration? startupTimeout, Duration? timeout, onPhase}) => gate.future);
    await tester.tap(find.text('Linux 交叉'));
    await tester.pump();
    expect(find.text('正在启动 WSL…'), findsOneWidget);

    gate.complete(const CToolchain(
        CCompileTarget.linuxCross, 'wsl:Ubuntu:/home/x/gcc', {}));
    await tester.pump();
    expect(find.text('已自动探测到交叉编译器'), findsOneWidget);
    expect(pathFieldText(tester), 'wsl:Ubuntu:/home/x/gcc');
  });

  testWidgets('Linux 交叉探测：超时未找到显示安装提示', (tester) async {
    // fake 探测在阶段二返回 null（等价于 WSL 就绪后探测超时未找到）。
    await pumpDialog(tester,
        ({Duration? startupTimeout, Duration? timeout, onPhase}) async {
      onPhase?.call('detect');
      return null;
    });
    await tester.tap(find.text('Linux 交叉'));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在探测交叉编译器（含 WSL）…'), findsNothing);
    expect(find.textContaining('未检测到 Linux 交叉编译器'), findsOneWidget);
    expect(find.textContaining('~/toolchains/bin'), findsOneWidget);
    expect(find.textContaining('wsl:<发行版>:<路径>'), findsOneWidget);
  });

  testWidgets('Linux 交叉探测：WSL 慢启动后成功（不出超时提示）', (tester) async {
    final gate = Completer<void>();
    await pumpDialog(tester,
        ({Duration? startupTimeout, Duration? timeout, onPhase}) async {
      // 阶段一「启动中」挂起（模拟 WSL 冷启动慢），放行后进入阶段二并命中。
      onPhase?.call('startup');
      await gate.future;
      onPhase?.call('detect');
      return const CToolchain(
          CCompileTarget.linuxCross, 'wsl:Ubuntu:/home/x/gcc', {});
    });
    await tester.tap(find.text('Linux 交叉'));
    await tester.pump();
    // 阶段一文案。
    expect(find.text('正在启动 WSL…'), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('已自动探测到交叉编译器'), findsOneWidget);
    expect(pathFieldText(tester), 'wsl:Ubuntu:/home/x/gcc');
    expect(find.textContaining('未检测到'), findsNothing);
  });

  testWidgets('Linux 交叉探测：WSL 不就绪直接安装提示', (tester) async {
    await pumpDialog(tester, ({Duration? startupTimeout, Duration? timeout, onPhase}) async {
      onPhase?.call('startup');
      return null; // 阶段一失败（未装 WSL / 冷启动超时未就绪）
    });
    await tester.tap(find.text('Linux 交叉'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('未检测到可用的 WSL 或交叉工具链'), findsOneWidget);
  });

  testWidgets('Linux 交叉探测：阶段二超时显示常规安装提示', (tester) async {
    await pumpDialog(tester, ({Duration? startupTimeout, Duration? timeout, onPhase}) async {
      onPhase?.call('startup');
      onPhase?.call('detect');
      return null; // 阶段二超时未命中
    });
    await tester.tap(find.text('Linux 交叉'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('未检测到 Linux 交叉编译器'), findsOneWidget);
    expect(find.textContaining('未检测到可用的 WSL'), findsNothing);
  });

  testWidgets('编译中：状态显示编译中、关闭禁用、编译按钮隐藏', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    final gate = Completer<CCompileResult>();
    GroupCompileRunner blockingRunner() {
      return (files, target, {topName, compilerPath, onOutput}) =>
          gate.future;
    }

    await tester.pumpWidget(wrap(state, groupId,
        compileRunner: blockingRunner(), filesBuilder: fakeFiles));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('groupCompileButton')));
    await tester.pump();
    await tester.tap(find.text('开始编译'));
    await tester.pump();

    expect(find.byKey(const ValueKey('groupCompileTerminal')), findsOneWidget);
    // 工具栏按钮与终端标题栏均显示「编译中…」。
    expect(find.text('编译中…'), findsNWidgets(2));
    // 编译中工具栏「编译」按钮禁用（防重复点击）。
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('groupCompileButton')))
            .onTap,
        isNull);
    // 终端关闭按钮禁用。
    final closeInk = tester.widget<InkWell>(find
        .ancestor(of: find.byIcon(Icons.close), matching: find.byType(InkWell))
        .first);
    expect(closeInk.onTap, isNull);

    // 放行编译 → 状态转成功，按钮恢复可用。
    gate.complete(CCompileResult(
      success: true,
      exitCode: 0,
      commandLine: 'fake',
      output: '',
      workDir: r'C:\tmp\fake',
      artifactPath: r'C:\tmp\fake\app.exe',
      sourceCount: 0,
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('编译'), findsOneWidget);
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('groupCompileButton')))
            .onTap,
        isNotNull);
  });
}
