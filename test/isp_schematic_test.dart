// ISP Studio 电路图浏览（sch: 标签页，yosys + netlistsvg 管线）测试。
// 端到端渲染用例在无 yosys/netlistsvg 的环境自动 skip（仿 iverilog 用例）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_gen_plan.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_block_diagram.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/schematic_tab.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 含编组的简单状态（multi_band_eq lut_fixed，IP 导出白名单形态）。
  (IspStudioState, String) makeGroup() {
    final state = IspStudioState();
    final mb = state.graph.addNode('multi_band_eq', 0, 0);
    state.graph.nodes[mb]!.paramValues['codegenMode'] = 'lut_fixed';
    state.graph.groups.add(IspNodeGroup('g1', {mb}, name: 'eq'));
    return (state, 'g1');
  }

  group('标签生命周期', () {
    test('openSchematicTab / 重复激活 / ungroup 联动关闭', () {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);

      // 不存在的编组不打开标签。
      state.openSchematicTab('gx', IpVendor.generic);
      expect(state.openCodeTabs, isEmpty);

      state.openSchematicTab(groupId, IpVendor.vivado);
      expect(state.openCodeTabs, ['sch:$groupId@vivado']);
      expect(state.activeTab, 1);
      // 重复打开（同厂商）只激活不重复添加；换厂商可同开。
      state.openSchematicTab(groupId, IpVendor.vivado);
      expect(state.openCodeTabs.length, 1);
      state.openSchematicTab(groupId, IpVendor.libero);
      expect(state.openCodeTabs.length, 2);

      // 解散编组自动关闭其全部标签（含 sch:）。
      state.ungroup(groupId);
      expect(state.openCodeTabs, isEmpty);
      expect(state.activeTab, 0);
    });
  });

  group('工具链探测', () {
    test('detectYosys：空目录返回 null，有 yosys.exe 返回路径', () {
      expect(detectYosys(searchDirs: const []), isNull);
      final dir = Directory.systemTemp.createTempSync('yosys_probe_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}\\yosys.exe').createSync();
      final tc = detectYosys(searchDirs: [dir.path]);
      expect(tc, isNotNull);
      expect(tc!.exe, endsWith('yosys.exe'));
    });

    test('detectNetlistsvg：缺包返回 null，包+node 齐备返回路径', () {
      final dir = Directory.systemTemp.createTempSync('nlsvg_probe_');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 无 node_modules/netlistsvg：null（即使 PATH 有 node 也不可用）。
      expect(detectNetlistsvg(packageDir: dir.path), isNull);
      final js = File(
          '${dir.path}\\node_modules\\netlistsvg\\bin\\netlistsvg.js')
        ..createSync(recursive: true);
      expect(js.existsSync(), isTrue);
      // 包齐备：包内 node.exe（或 PATH node 兜底）可用。
      final node = File('${dir.path}\\node.exe')..createSync();
      expect(detectNetlistsvg(packageDir: dir.path), isNotNull);
      // 显式注入的 nodeExe 优先。
      final tc = detectNetlistsvg(packageDir: dir.path, nodeExe: node.path);
      expect(tc, isNotNull);
      expect(tc!.nodeExe, node.path);
      expect(tc.netlistsvgJs, contains('netlistsvg.js'));
    });
  });

  group('顶层模块选择', () {
    test('厂商封装优先：axis > libero > top，vendorHint 优先对应封装', () {
      expect(
        schematicTopModule({'x_top.v': ''}),
        'x_top',
      );
      expect(
        schematicTopModule({'x_top.v': '', 'x_axis.v': ''}),
        'x_axis',
      );
      expect(
        schematicTopModule({'x_top.v': '', 'x_axis.v': '', 'x_libero.v': ''},
            vendorHint: 'libero'),
        'x_libero',
      );
      // hint 厂商无对应封装时回退既有顺序。
      expect(
        schematicTopModule({'x_top.v': ''}, vendorHint: 'vivado'),
        'x_top',
      );
    });
  });

  group('框图模型（buildSchModel）', () {
    test('单节点编组：in/out 端口组钉左右缘，节点块居中列，连线位宽标注',
        () {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      final group = state.graph.groups.single;
      final nodeId = group.nodeIds.single;
      final plan = planGroupIp(state.graph, group,
          const IpGenOptions(vendor: IpVendor.generic));
      final model = buildSchModel(plan, state.graph, group);

      // 块：#in + 节点 + #out；列：-1 / 0 / 1。
      final byId = {for (final b in model.blocks) b.id: b};
      expect(byId.keys, containsAll(['#in', nodeId, '#out']));
      expect(byId['#in']!.column, -1);
      expect(byId[nodeId]!.column, 0);
      expect(byId['#out']!.column, 1);

      // 连线：in → 节点 in、节点 out → out（无上游源时按缺省 10bit
      // 推导：10b × 3 通道 = 30b；multi_band_eq 为 HSL 域节点）。
      expect(model.wires, hasLength(2));
      expect(model.wires.every((w) => w.label.startsWith('30b ')), isTrue);
      expect(model.wires[0].from.pos.dx, lessThan(model.wires[0].to.pos.dx));
      // 画布尺寸为正。
      expect(model.canvasSize.width, greaterThan(0));
      expect(model.canvasSize.height, greaterThan(0));
    });
  });

  group('电路图标签页', () {
    const okSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="120" '
        'height="60"><rect width="120" height="60" fill="#123456"/></svg>';

    Future<void> pumpTab(
      WidgetTester tester,
      IspStudioState state,
      String groupId, {
      required Future<SchRenderResult> Function(Map<String, String> files,
              {required String topName,
              void Function(String chunk)? onOutput}) renderer,
    }) {
      return tester.pumpWidget(ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: SchematicTab(
              groupId: groupId,
              renderer: renderer,
              filesBuilder: (g, gr, o) async =>
                  {'isp_ip_eq_core.v': '// core', 'isp_ip_eq_top.v': '// top'},
            ),
          ),
        ),
      ));
    }

    testWidgets('渲染成功显示 SVG 电路图，日志面板收起', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(tester, state, groupId,
          renderer: (files, {required topName, onOutput}) async {
        onOutput?.call('fake 渲染日志\n');
        return SchRenderResult(
          success: true,
          svgBytes: utf8.encode(okSvg),
          log: 'fake 渲染日志\n',
          svgPath: 'x/sch.svg',
        );
      });
      await tester.pump();
      // 默认模块框图视图；切到 RTL 网表触发懒渲染。
      await tester.tap(find.byTooltip('RTL 网表（yosys + netlistsvg）'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byTooltip('重新生成'), findsOneWidget);
      expect(find.byTooltip('导出SVG'), findsOneWidget);
      // 信息区：编组名 + 变体 + 厂商 + 只读。
      expect(find.text('eq (g1)'), findsOneWidget);
      expect(find.text('编组·电路图'), findsOneWidget);
      expect(find.text('只读'), findsOneWidget);
      // 成功后日志面板默认收起（日志内容不在树中）。
      expect(find.textContaining('fake 渲染日志'), findsNothing);
    });

    testWidgets('默认模块框图：IO 端口组 + 节点块 + 位宽连线', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(tester, state, groupId,
          renderer: (files, {required topName, onOutput}) async =>
              throw StateError('不应触发 RTL 渲染'));
      await tester.pump();
      await tester.pump();
      // 框图直绘：输入/输出端口组 + 均衡器节点块（实例名 + 类型）。
      expect(find.text('输入端口'), findsOneWidget);
      expect(find.text('输出端口'), findsOneWidget);
      expect(find.text('多段色彩均衡器#1'), findsWidgets);
      expect(find.text('多段色彩均衡器'), findsWidgets);
      // 位宽标注由 CustomPaint 绘制（非 Text 组件），在下方模型测试中
      // 断言；此处仅验结构文本。RTL 渲染未被触发（无错误页）。
      expect(find.textContaining('渲染失败'), findsNothing);
    });

    testWidgets('框图点节点块打开其代码标签页', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(tester, state, groupId,
          renderer: (files, {required topName, onOutput}) async =>
              const SchRenderResult(success: false, log: ''));
      await tester.pump();
      await tester.pump();
      // 均衡器节点块点击 → 打开节点代码标签（key 为节点 id）。
      await tester.tap(find.text('多段色彩均衡器#1').first);
      await tester.pump();
      final nodeId = state.graph.groups.single.nodeIds.single;
      expect(state.openCodeTabs, contains(nodeId));
    });

    testWidgets('工具缺失显示安装提示（yosys）', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(tester, state, groupId,
          renderer: (files, {required topName, onOutput}) async =>
              const SchRenderResult(
                  success: false, log: '', missingTool: 'yosys'));
      await tester.pump();
      await tester.tap(find.byTooltip('RTL 网表（yosys + netlistsvg）'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('未检测到 yosys'), findsOneWidget);
      expect(find.textContaining('tools/yosys'), findsOneWidget);
      expect(find.byType(SvgPicture), findsNothing);
    });

    testWidgets('渲染失败显示错误与日志面板', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(tester, state, groupId,
          renderer: (files, {required topName, onOutput}) async {
        onOutput?.call('yosys 报错：语法错误\n');
        return const SchRenderResult(success: false, log: 'yosys 报错：语法错误\n');
      });
      await tester.pump();
      await tester.tap(find.byTooltip('RTL 网表（yosys + netlistsvg）'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('电路图渲染失败'), findsOneWidget);
      expect(find.textContaining('yosys 报错'), findsOneWidget);
    });

    testWidgets('编组解散后显示占位', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(tester, state, groupId,
          renderer: (files, {required topName, onOutput}) async =>
              const SchRenderResult(success: false, log: ''));
      await tester.pump();
      state.ungroup(groupId);
      await tester.pump();
      expect(find.text('编组已被解散'), findsOneWidget);
    });
  });

  group('SVG 适配（flutter_svg 不支持 <style> 块）', () {
    test('根元素补 fill/stroke，text 补属性，splitjoinBody 实心', () {
      const inSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="10">'
          '<style>svg{stroke:#000;fill:none}</style>'
          '<rect width="30" height="140" class="cell_u"/>'
          '<text x="15" y="-4" class="nodelabel cell_u">clk</text>'
          '<text x="-3" y="-4" class="inputPortLabel cell_u">in</text>'
          '<text x="5" y="-4" style="fill:#000; stroke:none">已有内联</text>'
          '<path d="M0,0 L5,5" class="splitjoinBody"/>'
          '</svg>';
      final out = adaptNetlistsvgSvg(inSvg);
      expect(out, contains('<svg fill="none" stroke="#000" '));
      // cell 矩形不再被默认填充（继承根 fill=none）。
      expect(out, contains('<rect width="30"'));
      // nodelabel 居中 + 填充/字号内联。
      expect(
          out,
          contains(
              'class="nodelabel cell_u" fill="#000" stroke="none" font-size="10" font-weight="bold" font-family="monospace" text-anchor="middle"'));
      // inputPortLabel 右对齐。
      expect(out, contains('text-anchor="end"'));
      // 已有内联样式的不重复补 fill。
      expect(out, contains('style="fill:#000; stroke:none"'));
      // splitjoinBody 实心（自闭合标签处属性插在 / 前）。
      expect(out, contains('class="splitjoinBody" fill="#000"/>'));
    });
  });

  group('端到端渲染（无工具链自动 skip）', () {
    test('多段色彩均衡器 IP 包 → SVG', () async {
      final yosys = detectYosys();
      final nlsvg = detectNetlistsvg();
      if (yosys == null || nlsvg == null) {
        markTestSkipped('无 yosys/netlistsvg 工具链');
        return;
      }
      final text =
          File('IspFlow/多段色彩均衡器.ispflow').readAsStringSync();
      final graph = IspGraph.fromJson(jsonDecode(text) as Map<String, Object?>);
      final files = buildGroupIpFiles(graph, graph.groups.single,
          const IpGenOptions(vendor: IpVendor.generic));
      final top = schematicTopModule(files, vendorHint: 'generic');
      final r = await renderSchematic(files,
          topName: top, yosys: yosys, netlistsvg: nlsvg);
      expect(r.success, isTrue, reason: r.log);
      final svg = utf8.decode(r.svgBytes!);
      expect(svg, contains('<svg'));
      // 已内联样式适配（flutter_svg 不支持 <style> 块）。
      expect(svg, contains('fill="none" stroke="#000"'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
