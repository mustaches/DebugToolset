// SimWave Signal 右键「跳转到Verilog」与 IP 代码页信号名高亮测试。
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/sim_wave_store.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/code_browser.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_generator_page.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/sim_wave_tab.dart';
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
    if (s.style?.backgroundColor == const Color(0xFFFFB300) &&
        s.text != null) {
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

void main() {
  group('highlightWordOccurrences / containsVerilogWord', () {
    test('词边界高亮：in_data2 中的 in_data 不高亮，文本不丢失', () {
      const style = TextStyle(color: Colors.white);
      const src = 'in_data = in_data2 + (in_data)';
      final spans = highlightWordOccurrences(
          [const TextSpan(text: src, style: style)], 'in_data');
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

  testWidgets('Signal 右键「跳转到Verilog」：打开 IP 页并设置高亮词',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd),
        groupId: groupId, vendor: IpVendor.generic);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
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
    expect(state.openCodeTabs, contains('gip:$groupId@generic'),
        reason: '打开来源编组的 IP 标签页');
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
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
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
            .widget<MenuItemButton>(find.widgetWithText(
                MenuItemButton, '跳转到Verilog（高亮信号名）'))
            .onPressed,
        isNull,
        reason: '无来源编组时置灰');
  });

  testWidgets('IP 代码页信号名高亮：词边界 + 自动选文件 + 指示清除',
      (tester) async {
    final (state, groupId) = makeGroup();
    addTearDown(state.dispose);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: IpGeneratorPage(
            groupId: groupId,
            options: const IpGenOptions(vendor: IpVendor.generic),
            filesBuilder: () async => {
              'z_core.v': '// 无目标信号\nmodule z; endmodule\n',
              'a_core.v': 'module a;\n'
                  'wire [23:0] in_data;\n'
                  'wire [23:0] in_data2;\n'
                  'assign out_data = in_data;\n'
                  'endmodule\n',
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 初始选中首个文件 z_core.v（不含 in_data）；设置高亮后自动切到
    // 首个含该信号的 a_core.v。
    state.setIpCodeHighlight('in_data');
    await tester.pumpAndSettle();
    await tester.pump();
    final codeArea = tester.widget<CodeArea>(find.byType(CodeArea));
    expect(amberTexts(codeArea.spans), ['in_data', 'in_data'],
        reason: '词边界高亮两处（in_data2 不高亮）——已自动切到 a_core.v');
    // 工具栏高亮指示与清除。
    expect(find.text('高亮 in_data'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(state.ipCodeHighlight, isNull);
    expect(
        amberTexts(tester.widget<CodeArea>(find.byType(CodeArea)).spans),
        isEmpty,
        reason: '清除后无高亮');
  });
}
