// SimWave Signal 右键「跳转到Verilog」与 IP 代码页信号名高亮测试。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pdf;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/vivado_runner.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/demo_prj_log_tab.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/sim_wave_store.dart';
import 'package:debug_tool_set/modules/isp_studio/models/demo_prj_session.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/code_browser.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_generator_page.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/sim_wave_tab.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/verilog_print_preview.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

// 最小 VCD：clk 周期 10ns + 24 位总线跳变。
const _kTestVcd = '''
\$timescale 1ps \$end
\$scope module tb \$end
\$var wire 1 ! clk \$end
\$var wire 24 " in_data [23:0] \$end
\$upscope \$end
\$enddefinitions \$end
#0
0!
b000000000000000000000000 "
#5000
1!
b000000111111111101111111 "
#10000
0!
b111111111111111111111111 "
#15000
1!
''';

/// 含编组的简单状态（multi_band_eq lut_fixed，IP 导出白名单形态）。
(IspStudioState, String) makeGroup() {
  final state = IspStudioState();
  final mb = state.graph.addNode('multi_band_eq', 0, 0);
  state.graph.nodes[mb]!.paramValues['codegenMode'] = 'lut_fixed';
  state.graph.groups.add(IspNodeGroup('g1', {mb}, name: 'eq'));
  return (state, 'g1');
}

/// 收集 spans 树中琥珀高亮底色的文本片段。
List<String> amberTexts(List<TextSpan> spans) {
  final out = <String>[];
  void walk(TextSpan s) {
    if (s.style?.backgroundColor == const Color(0xFFFFB300) && s.text != null) {
      out.add(s.text!);
    }
    for (final c in s.children ?? const <InlineSpan>[]) {
      if (c is TextSpan) walk(c);
    }
  }

  for (final s in spans) {
    walk(s);
  }
  return out;
}

String plainText(pdf.InlineSpan span) {
  if (span is! pdf.TextSpan) return '';
  return '${span.text ?? ''}${span.children?.map(plainText).join() ?? ''}';
}

void main() {
  group('highlightWordOccurrences / containsVerilogWord', () {
    test('词边界高亮：in_data2 中的 in_data 不高亮，文本不丢失', () {
      const style = TextStyle(color: Colors.white);
      const src = 'in_data = in_data2 + (in_data)';
      final spans = highlightWordOccurrences([
        const TextSpan(text: src, style: style),
      ], 'in_data');
      expect(amberTexts(spans), ['in_data', 'in_data']);
      // 拼回全文不变。
      final buf = StringBuffer();
      void walk(TextSpan s) {
        buf.write(s.text ?? '');
        for (final c in s.children ?? const <InlineSpan>[]) {
          if (c is TextSpan) walk(c);
        }
      }

      for (final s in spans) {
        walk(s);
      }
      expect(buf.toString(), src);
    });

    test('containsVerilogWord 词边界判定', () {
      expect(containsVerilogWord('wire in_data;', 'in_data'), isTrue);
      expect(containsVerilogWord('wire in_data2;', 'in_data'), isFalse);
      expect(containsVerilogWord('in_data2 = in_data;', 'in_data'), isTrue);
      expect(containsVerilogWord('', 'in_data'), isFalse);
    });
  });

  testWidgets('Signal 右键「跳转到Verilog」：打开 IP 页并设置高亮词', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    SimWaveStore.instance.registerWave(
      utf8.encode(_kTestVcd),
      groupId: groupId,
      vendor: IpVendor.generic,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
      ),
    );
    await tester.pumpAndSettle();

    // 信号名面板内 in_data 行的全局中心（x 限定 Signal 列表区）。
    Offset? pos;
    for (final e in find.text('in_data [23:0]').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final p = box.localToGlobal(box.size.center(Offset.zero));
      if (p.dx > 200 && p.dx < 360) pos = p;
    }
    expect(pos, isNotNull);
    await tester.tapAt(pos!, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('跳转到Verilog（高亮信号名）'), findsOneWidget);
    await tester.tap(find.text('跳转到Verilog（高亮信号名）'));
    await tester.pumpAndSettle();
    expect(
      state.openCodeTabs,
      contains('gip:$groupId@generic'),
      reason: '打开来源编组的 IP 标签页',
    );
    expect(state.activeTab, 1, reason: '激活 IP 标签页');
    expect(state.ipCodeHighlight, 'in_data', reason: '高亮词为信号名');
  });

  testWidgets('Open VCD 来源（无编组）时「跳转到Verilog」置灰', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final (state, _) = makeGroup();
    addTearDown(state.dispose);
    // 无 groupId/vendor（Open VCD 路径）：来源为空。
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
      ),
    );
    await tester.pumpAndSettle();

    Offset? pos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final p = box.localToGlobal(box.size.center(Offset.zero));
      if (p.dx > 200 && p.dx < 360) pos = p;
    }
    expect(pos, isNotNull);
    await tester.tapAt(pos!, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, '跳转到Verilog（高亮信号名）'),
          )
          .onPressed,
      isNull,
      reason: '无来源编组时置灰',
    );
  });

  testWidgets('IP 代码页信号名高亮：词边界 + 自动选文件 + 指示清除', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: IpGeneratorPage(
              groupId: groupId,
              options: const IpGenOptions(vendor: IpVendor.generic),
              filesBuilder: () async => {
                'z_core.v': '// 无目标信号\nmodule z; endmodule\n',
                'a_core.v':
                    'module a;\n'
                    'wire [23:0] in_data;\n'
                    'wire [23:0] in_data2;\n'
                    'assign out_data = in_data;\n'
                    'endmodule\n',
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 初始选中首个文件 z_core.v（不含 in_data）；设置高亮后自动切到
    // 首个含该信号的 a_core.v。
    state.setIpCodeHighlight('in_data');
    await tester.pumpAndSettle();
    await tester.pump();
    final codeArea = tester.widget<CodeArea>(find.byType(CodeArea));
    expect(amberTexts(codeArea.spans), [
      'in_data',
      'in_data',
    ], reason: '词边界高亮两处（in_data2 不高亮）——已自动切到 a_core.v');
    // 工具栏高亮指示与清除。
    expect(find.text('高亮 in_data'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(state.ipCodeHighlight, isNull);
    expect(
      amberTexts(tester.widget<CodeArea>(find.byType(CodeArea)).spans),
      isEmpty,
      reason: '清除后无高亮',
    );
  });

  test('长 Verilog 文件自动分页并返回实际页数', () async {
    final content = [for (var i = 1; i <= 600; i++) 'line $i'].join('\n');
    int? pageCount;
    final bytes = await buildVerilogPdf(
      'long_core.v',
      content,
      PdfPageFormat.a4,
      onPageCount: (count) => pageCount = count,
    );
    expect(bytes, isNotEmpty);
    expect(bytes.sublist(0, 4), [0x25, 0x50, 0x44, 0x46]);
    expect(pageCount, greaterThan(1));
  });

  test('打印内容带连续且对齐的粗体源代码行号', () {
    final content = [for (var i = 1; i <= 12; i++) 'line $i'].join('\n');
    final spans = buildVerilogLineNumberSpans(
      content,
      6,
      pdf.Font.courier(),
      const <pdf.Font>[],
    );
    final first = spans.first as pdf.TextSpan;
    final second = spans[1] as pdf.TextSpan;
    final last = spans.last as pdf.TextSpan;
    expect(first.text, '    1');
    expect(second.text, '    2');
    expect(last.text, '   12');
    expect(first.style?.fontWeight, pdf.FontWeight.bold);
    expect(plainText(first), '    1  line 1');
    expect(plainText(last), '   12  line 12');
  });

  test('打印保留原始换行和缩进而不二次折行', () {
    String repeat(String value, int count) => List.filled(count, value).join();
    final longLine = repeat('a', 115);
    final spans = buildVerilogLineNumberSpans(
      '  $longLine\n  ${repeat('b', 110)}',
      6,
      pdf.Font.courier(),
      const <pdf.Font>[],
    );
    expect(spans, hasLength(2));
    expect(plainText(spans[0]), '    1    $longLine');
    expect(plainText(spans[1]), '    2    ${repeat('b', 110)}');
  });

  test('Verilog 语法高亮区分关键字注释字符串和数值', () {
    final spans = buildVerilogLineNumberSpans(
      'module demo; // comment\n'
      'wire [15:0] value = 16\'h0013;\n'
      'initial \$display("hello");\n'
      '/* block\n'
      'comment */ endmodule',
      6,
      pdf.Font.courier(),
      const <pdf.Font>[],
    );
    final tokens = <pdf.TextSpan>[];
    void collect(pdf.InlineSpan span) {
      if (span is pdf.TextSpan) {
        tokens.add(span);
        span.children?.forEach(collect);
      }
    }

    spans.forEach(collect);
    expect(
      tokens.singleWhere((span) => span.text == 'module').style?.color,
      verilogKeywordColor,
    );
    expect(
      tokens.singleWhere((span) => span.text == '// comment').style?.color,
      verilogCommentColor,
    );
    expect(
      tokens.singleWhere((span) => span.text == "16'h0013").style?.color,
      verilogNumberColor,
    );
    expect(
      tokens.singleWhere((span) => span.text == '"hello"').style?.color,
      verilogStringColor,
    );
    expect(
      tokens.singleWhere((span) => span.text == '/* block').style?.color,
      verilogCommentColor,
    );
    expect(
      tokens.singleWhere((span) => span.text == 'comment */').style?.color,
      verilogCommentColor,
    );
  });

  test('白底打印语法颜色的 Y 值保持在 80 左右', () {
    for (final color in [
      verilogKeywordColor,
      verilogCommentColor,
      verilogStringColor,
      verilogNumberColor,
      verilogDirectiveColor,
    ]) {
      expect(verilogPrintLuma(color), greaterThanOrEqualTo(70));
      expect(verilogPrintLuma(color), lessThanOrEqualTo(90));
    }
  });

  test('中文使用独立 Unicode 回退字体并支持调整字号', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const unicodePath = 'Font/unifont13.0.06/unifont-13.0.06.ttf';
    final unicodeFont = pdf.Font.ttf(await rootBundle.load(unicodePath));
    for (final path in [
      unicodePath,
      'Font/ark-pixel-16px.ttf',
      'Font/fusion-pixel-12px.ttf',
      'Font/zpix.ttf',
    ]) {
      final font = pdf.Font.ttf(await rootBundle.load(path));
      final bytes = await buildVerilogPdf(
        '中文核心.v',
        'module demo;\n// 中文注释：多段色彩均衡器\nendmodule',
        PdfPageFormat.a4,
        fontSize: 12,
        codeFont: font,
        titleFont: font,
        fallbackFonts: [font, if (path != unicodePath) unicodeFont],
      );
      expect(bytes, isNotEmpty, reason: path);
      expect(bytes.sublist(0, 4), [0x25, 0x50, 0x44, 0x46], reason: path);
    }
  });

  test('页眉页脚可固定使用微软雅黑', () async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (!file.existsSync()) return;
    final font = pdf.Font.ttf(
      ByteData.sublistView(standaloneTtfFromBytes(await file.readAsBytes())),
    );
    final bytes = await buildVerilogPdf(
      '中文核心.v',
      'module demo;\n// 中文注释\nendmodule',
      PdfPageFormat.a4,
      headerFooterFont: font,
    );
    expect(bytes, isNotEmpty);
    expect(bytes.sublist(0, 4), [0x25, 0x50, 0x44, 0x46]);
  });

  testWidgets('长文件预览进度按已完成页面更新', (tester) async {
    final content = [for (var i = 1; i <= 150; i++) 'line $i'].join('\n');
    final pageCount = (content.split('\n').length + 51) ~/ 52;

    Future<void> pumpProgress(int completed) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VerilogRenderProgress(completed: completed, total: pageCount),
        ),
      ),
    );

    await pumpProgress(0);
    var bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('verilog-render-progress-bar')),
    );
    expect(bar.value, 0.0);
    expect(find.text('正在渲染预览：0/3 页'), findsOneWidget);

    await pumpProgress(2);
    bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('verilog-render-progress-bar')),
    );
    expect(bar.value, closeTo(2 / 3, 0.0001));
    expect(find.text('正在渲染预览：2/3 页'), findsOneWidget);
  });

  testWidgets('打印进度在中央卡片突出显示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VerilogPrintingOverlay(completed: 2, total: 5)),
      ),
    );
    expect(
      find.byKey(const ValueKey('verilog-printing-overlay')),
      findsOneWidget,
    );
    expect(find.text('正在打印'), findsOneWidget);
    expect(find.text('2/5 页'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('verilog-printing-overlay-bar')),
    );
    expect(bar.value, closeTo(0.4, 0.0001));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VerilogPrintingOverlay(
            completed: 0,
            total: null,
            title: '正在更新字体与排版…',
            detail: '正在重新生成 PDF，请稍候',
            icon: Icons.text_fields,
          ),
        ),
      ),
    );
    expect(find.text('正在更新字体与排版…'), findsOneWidget);
    expect(find.text('正在重新生成 PDF，请稍候'), findsOneWidget);
    final updatingBar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('verilog-printing-overlay-bar')),
    );
    expect(updatingBar.value, isNull);
  });

  testWidgets('打印按钮打开当前文件预览并在完成后关闭', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: IpGeneratorPage(
              groupId: groupId,
              options: const IpGenOptions(vendor: IpVendor.generic),
              filesBuilder: () async => {
                'demo_core.v': 'module demo;\nendmodule\n',
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('print-verilog-code')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('打印预览 · demo_core.v'), findsOneWidget);
    expect(find.byType(VerilogVectorPreview), findsOneWidget);
    expect(find.byType(PdfPreview), findsNothing);
    await tester.tap(find.byTooltip('退出预览'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(VerilogVectorPreview), findsNothing);
  });

  testWidgets('字体设置提供字号和中英文字体选项', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VerilogPrintPreview(
            fileName: 'demo_core.v',
            content: 'module demo;\nendmodule',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('verilog-preview-zoom-label')),
      findsOneWidget,
    );
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('verilog-preview-zoom-in')));
    await tester.pump();
    expect(find.text('125%'), findsOneWidget);
    final zoomedPreview = tester.widget<VerilogVectorPreview>(
      find.byType(VerilogVectorPreview),
    );
    expect(zoomedPreview.scale, 1.25);
    expect(find.byType(PdfPreview), findsNothing);
    await tester.tap(find.byKey(const ValueKey('verilog-preview-zoom-out')));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('verilog-font-settings')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('打印字体设置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('verilog-print-font-size')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('verilog-print-english-font')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('verilog-print-chinese-font')),
      findsOneWidget,
    );
    expect(verilogPrintFontSizes, [5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0]);
    expect(formatVerilogFontSize(5.5), '5.5 pt');
    expect(verilogFontSizeToLogicalPixels(6.5), closeTo(8.6667, 0.0001));
    await tester.tap(find.byKey(const ValueKey('verilog-apply-font-settings')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('打印字体设置'), findsNothing);
    expect(find.text('正在更新字体与排版…'), findsNothing);
  });

  test('每页行数按实际字体行高计算并自动充满', () {
    final lines = verilogLinesPerPage(
      format: PdfPageFormat.a4,
      fontSize: 6.5,
      englishFont: 'Courier',
    );
    expect(lines, greaterThan(52));
  });

  testWidgets('版式设置提供四方向留白比例', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VerilogPrintPreview(
            fileName: 'demo_core.v',
            content: 'module demo;\nendmodule',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('verilog-layout-settings')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('版式设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-margin-left')), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-margin-top')), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-margin-right')), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-margin-bottom')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('verilog-apply-layout-settings')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('版式设置'), findsNothing);
  });

  testWidgets('IP 页面在后台 isolate 完成真实生成并显示代码', (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: IpGeneratorPage(
              groupId: groupId,
              options: const IpGenOptions(vendor: IpVendor.generic),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    await tester.pump();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (find.byType(CodeArea).evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump();
    expect(find.textContaining('生成 IP 包失败'), findsNothing);
    expect(find.byType(CodeArea), findsOneWidget);
  });

  test('demo 生成日志使用独立标签并保留会话', () {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final session = state.openDemoPrjLogTab('g1', 'demo_custom');
    expect(state.openCodeTabs, ['demo:g1']);
    expect(state.activeTab, 1);
    expect(state.demoPrjSessions['demo:g1'], same(session));
    session.append('Vivado log\n');
    expect(session.log.toString(), 'Vivado log\n');
    session.complete(
      const VivadoDemoResult(
        success: true,
        output: '',
        exitCode: 0,
        projectPath: 'demo_custom.xpr',
      ),
    );
    expect(session.running, isFalse);
    expect(session.result?.success, isTrue);
    state.openDemoPrjLogTab('g1', 'demo_custom');
    expect(state.openCodeTabs, hasLength(1));
  });

  test('demo 导出成功与失败均在根目录保存固定名称的完整日志', () async {
    final dir = await Directory.systemTemp.createTemp('demo_prj_log_test_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    for (final success in [true, false]) {
      final session = DemoPrjSession('demo_custom');
      session.append('正在生成 demo_custom…\n');
      if (success) {
        session.append('demo_custom 生成成功\n');
        session.complete(
          const VivadoDemoResult(
            success: true,
            output: '',
            exitCode: 0,
            projectPath: 'demo_custom.xpr',
          ),
        );
      } else {
        session.append('ERROR: 生成失败\n');
        session.fail('Vivado exit 1');
      }
      await saveDemoPrjExportLog(dir.path, session.log.toString());
      final logFile = File(
        '${dir.path}${Platform.pathSeparator}$demoPrjExportLogName',
      );
      expect(await logFile.exists(), isTrue);
      expect(await logFile.readAsString(), session.log.toString());
    }
  });

  test('Vivado 日志按消息级别着色并保留换行', () {
    final spans = highlightVivadoLog(
      'INFO: start\nWARNING: check\nERROR: failed\nPASS frame=64x8x6\nplain\n',
    );
    expect(spans, hasLength(6));
    expect(spans[0].text, 'INFO: start\n');
    expect(spans[0].style?.color, const Color(0xFF569CD6));
    expect(spans[1].style?.color, const Color(0xFFD7BA7D));
    expect(spans[2].style?.color, const Color(0xFFF44747));
    expect(spans[3].style?.color, const Color(0xFF4EC9B0));
    expect(spans[4].style?.color, kCodeBrowserStyle.color);
  });

  testWidgets('demo 日志标签完整显示流式日志、行号与完成状态', (tester) async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    final session = state.openDemoPrjLogTab('g1', 'demo_custom');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(body: DemoPrjLogTab(groupId: 'g1')),
        ),
      ),
    );
    expect(find.text('等待 Vivado 输出…'), findsOneWidget);
    expect(find.text('生成中…'), findsOneWidget);
    session.append('INFO: start\nWARNING: check\nPASS frame=64x8x6\n');
    await tester.pump();
    expect(find.byType(CodeArea), findsOneWidget);
    expect(find.text('1\n2\n3\n4'), findsOneWidget);
    expect(find.textContaining('PASS frame=64x8x6'), findsOneWidget);
    session.complete(
      const VivadoDemoResult(
        success: true,
        output: '',
        exitCode: 0,
        projectPath: 'demo_custom.xpr',
      ),
    );
    await tester.pump();
    expect(find.text('生成成功'), findsOneWidget);
  });
}
