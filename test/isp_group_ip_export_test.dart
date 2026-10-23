// ISP Studio IP Generator（编组 → FPGA Verilog IP 包）测试。
// 围绕「多段色彩均衡器.ispflow」验证校验/规划/Verilog 发射/golden/仿真。
// iverilog 不在场时仿真用例自动 skip（仿黑盒测试的 MSVC skip 模式）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_gen_plan.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_stimulus.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_validate.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/iverilog_sim.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_stimulus_dialog.dart';

void main() {
  final samplePath = 'IspFlow/多段色彩均衡器.ispflow';

  IspGraph loadSample() {
    final text = File(samplePath).readAsStringSync();
    final json = jsonDecode(text) as Map<String, Object?>;
    return IspGraph.fromJson(json);
  }

  IspNodeGroup sampleGroup(IspGraph graph) => graph.groups.single;

  group('IP 导出校验', () {
    test('多段色彩均衡器（lut_fixed）放行', () {
      final graph = loadSample();
      expect(validateGroupIpExport(graph, sampleGroup(graph)), isNull);
    });

    test('非白名单节点拒绝（列节点名）', () {
      final graph = IspGraph();
      final ccm = graph.addNode('ccm', 0, 0);
      graph.nodes[ccm]!.name = 'ccm';
      graph.groups.add(IspNodeGroup('g1', {ccm}, name: 'g'));
      final err = validateGroupIpExport(graph, graph.groups.single);
      expect(err, contains('多段色彩均衡器'));
      expect(err, contains('色彩校正')); // ccm 显示名
    });

    test('multi_band_eq 非 lut_fixed 拒绝', () {
      final graph = IspGraph();
      final mb = graph.addNode('multi_band_eq', 0, 0);
      graph.nodes[mb]!.name = 'mb';
      graph.nodes[mb]!.paramValues['codegenMode'] = 'lut';
      graph.groups.add(IspNodeGroup('g1', {mb}, name: 'g'));
      expect(validateGroupIpExport(graph, graph.groups.single),
          contains('lut_fixed'));
    });
  });

  group('IP 规划', () {
    test('位深推导（8bit 源 → PIX_BITS=8、MAXV=255、topName）', () {
      final graph = loadSample();
      final plan = planGroupIp(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic));
      expect(plan.pixBits, 8);
      expect(plan.maxValue, 255);
      expect(plan.lutDepth, 256);
      expect(plan.topName, 'isp_ip_multi_band_eq');
      expect(plan.totalDelay, 0);
    });

    test('选项 pixBits 覆盖位深', () {
      final graph = loadSample();
      final plan = planGroupIp(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic, pixBits: 10));
      expect(plan.pixBits, 10);
      expect(plan.maxValue, 1023);
      expect(plan.lutDepth, 1024);
    });
  });

  group('IP 生成物结构', () {
    test('通用目标文件集与核心/tb/golden 结构', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic));
      expect(
          files.keys.toList(),
          equals([
            'isp_ip_multi_band_eq_core.v',
            'isp_ip_multi_band_eq_top.v',
            'tb_isp_ip_multi_band_eq.v',
            'golden_in.hex',
            'golden_hash.txt',
            'README.md',
          ]));
      final core = files['isp_ip_multi_band_eq_core.v']!;
      expect(core, contains('module isp_ip_multi_band_eq_core'));
      expect(core, contains('parameter integer PIX_BITS  = 8'));
      expect(core, contains('MAXV = (1 << PIX_BITS) - 1'));
      expect(core, contains('_shift_lut'));
      expect(core, contains('_s_mul_q14'));
      expect(core, contains('_l_mul_q14'));
      expect(core, contains('in_ready = ~out_valid | out_ready'));
      final tb = files['tb_isp_ip_multi_band_eq.v']!;
      expect(tb, contains('EXPECTED_HASH = 32\'h'));
      expect(tb, contains('\$readmemh'));
      expect(tb, contains('\$dumpvars')); // 波形转储供内嵌波形标签页展示
      // golden_in.hex 帧尺寸 = 默认 64×8×6 帧。
      final inLines = files['golden_in.hex']!.trim().split('\n');
      expect(inLines.length, kIpSimW * kIpSimH * kIpSimFrames);
      // golden_hash.txt 与 tb 内嵌哈希一致。
      final hashTxt = files['golden_hash.txt']!.trim();
      expect(hashTxt, matches(RegExp(r'^0x[0-9a-f]{8}$')));
      expect(tb, contains(hashTxt.substring(2)));
    });

    test('Vivado 目标附 axis 封装与 package_ip.tcl', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.vivado));
      expect(files.keys, contains('isp_ip_multi_band_eq_axis.v'));
      expect(files.keys, contains('package_ip.tcl'));
      expect(files['package_ip.tcl']!, contains('ipx::package_project'));
    });

    test('Vivado 目标：参数校验列表 + xgui 定制界面 + 优化策略参数', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.vivado));
      // xgui 定制界面文件随包产出（打包时拷入组件 xgui/ 目录）。
      final xgui = files['xgui/isp_ip_multi_band_eq_v1_0.tcl']!;
      expect(xgui, contains('ipgui::add_page'));
      expect(xgui, contains('基本配置'));
      expect(xgui, contains('优化策略'));
      expect(xgui, contains('ipgui::add_param \$IPINST -name "FOLD"'));
      // package_ip.tcl：四个定制参数 + 校验列表 + FOLD 面积档联动。
      final tcl = files['package_ip.tcl']!;
      expect(tcl, contains('ipx::add_user_parameter GSTRATEGY'));
      expect(tcl, contains('ipx::add_user_parameter FOLD'));
      expect(tcl, contains('value_validation_list {8 10 12 14 16}'));
      expect(tcl, contains('enablement_tcl_expr'));
      // RTL 顶层带优化策略参数（预留，generate 分档待窗口算子）。
      expect(files['isp_ip_multi_band_eq_top.v']!, contains('GSTRATEGY'));
      expect(files['isp_ip_multi_band_eq_axis.v']!, contains('FOLD'));
    });

    test('资源估算写入 README 且数值合理', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic));
      final readme = files['README.md']!;
      expect(readme, contains('资源估算'));
      expect(readme, contains('DSP'));
      expect(readme, contains('1.0 px/clk'));
      // 规划层直接对拍：8 位域（MAXV=255）时 ROM = 256×50 bit、
      // 折算 1 块 36K BRAM、性能档 2 个 DSP。
      final plan = planGroupIp(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic));
      expect(plan.resources.romBits, 256 * 50);
      expect(plan.resources.bram36k, 1);
      expect(plan.resources.estDsps, 2);
      expect(plan.resources.latencyCycles, 1);
      expect(readme, contains('${plan.resources.romBits} bit'));
      // 平衡档：乘法器绑 LUT，DSP 为 0。
      final planBal = planGroupIp(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic, gstrategy: 1));
      expect(planBal.resources.estDsps, 0);
      expect(planBal.resources.estLuts,
          greaterThan(plan.resources.estLuts));
    });

    test('Libero 目标附 libero 封装', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.libero));
      expect(files.keys, contains('isp_ip_multi_band_eq_libero.v'));
    });
  });

  group('一键仿真', () {
    test('激励参数化：自定义尺寸/帧数/图案/握手压力写入 tb 与 golden', () {
      final graph = loadSample();
      const stim = IpSimStimulus(
        width: 32,
        height: 16,
        frames: 2,
        frameGapCycles: 100,
        pattern: IpSimPattern.hGradient,
        seed: 0xABCDEF01,
        inGapPct: 25,
        outStallPct: 50,
      );
      expect(stim.validate(), isNull);
      expect(stim.isDefault, isFalse);
      expect(const IpSimStimulus().isDefault, isTrue);
      final files = buildGroupIpFiles(
          graph, sampleGroup(graph), const IpGenOptions(vendor: IpVendor.generic),
          stimulus: stim);
      // golden_in.hex 行数 = 32×16×2 帧。
      final inLines = files['golden_in.hex']!.trim().split('\n');
      expect(inLines.length, 32 * 16 * 2);
      final tb = files['tb_isp_ip_multi_band_eq.v']!;
      expect(tb, contains('W  = 32'));
      expect(tb, contains('H  = 16'));
      expect(tb, contains('FRAMES = 2'));
      expect(tb, contains('FRAME_GAP = 100'));
      expect(tb, contains('GAP_PCT   = 25'));
      expect(tb, contains('STALL_PCT = 50'));
      expect(tb, contains("SEED = 32'habcdef01"));
      expect(tb, contains('水平渐变'));
      // golden_hash.txt 与 tb 内嵌哈希一致，且与默认激励的哈希不同。
      final hashTxt = files['golden_hash.txt']!.trim();
      expect(tb, contains(hashTxt.substring(2)));
      final defFiles = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic));
      expect(files['golden_hash.txt'], isNot(defFiles['golden_hash.txt']));
      // README 写入激励参数摘要。
      expect(files['README.md']!, contains('32×16 × 2 帧，帧间隔 100 拍'));
    });

    test('激励参数校验：越界值给出错误说明', () {
      expect(const IpSimStimulus(width: 0).validate(), isNotNull);
      expect(const IpSimStimulus(height: 9000).validate(), isNotNull);
      expect(const IpSimStimulus(frames: 0).validate(), isNotNull);
      expect(const IpSimStimulus(frameGapCycles: -1).validate(), isNotNull);
      expect(const IpSimStimulus(inGapPct: 100).validate(), isNotNull);
      expect(const IpSimStimulus(clkMHz: 0).validate(), isNotNull);
      expect(const IpSimStimulus(clkMHz: 1001).validate(), isNotNull);
      expect(const IpSimStimulus(clkMHz: double.nan).validate(), isNotNull);
      expect(const IpSimStimulus().validate(), isNull);
    });

    test('CLK 频率：默认 100MHz 保持 always #5，自定义频率烘焙半周期', () {
      final graph = loadSample();
      // 默认：逐字节保持历史形态（always #5，无频率注释）。
      final defTb = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic))['tb_isp_ip_multi_band_eq.v']!;
      expect(defTb, contains('always #5 clk = ~clk;'));
      expect(defTb, isNot(contains('CLK 频率')));
      // 50MHz：半周期 10ns + 注释；summary 带 CLK 段。
      const stim50 = IpSimStimulus(clkMHz: 50);
      expect(stim50.isDefault, isFalse);
      expect(stim50.summary(), contains('CLK50M'));
      expect(const IpSimStimulus().summary(), isNot(contains('CLK')));
      final tb50 = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic),
          stimulus: stim50)['tb_isp_ip_multi_band_eq.v']!;
      expect(tb50, contains('// CLK 频率 50 MHz'));
      expect(tb50, contains('always #10 clk = ~clk;'));
      // 小数频率：148.5MHz → 半周期 3.367ns（1ps 精度去尾零）。
      final tb148 = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic),
          stimulus: const IpSimStimulus(clkMHz: 148.5))['tb_isp_ip_multi_band_eq.v']!;
      expect(tb148, contains('// CLK 频率 148.5 MHz'));
      expect(tb148, contains('always #3.367 clk = ~clk;'));
      // 半周期/频率格式助手。
      expect(ipClkHalfNs(100), '5');
      expect(ipClkHalfNs(200), '2.5');
      expect(fmtClkMHz(100), '100');
      expect(fmtClkMHz(74.25), '74.25');
    });

    testWidgets('激励参数对话框：CLK 频率输入（默认 100，可改小数，越界报错）',
        (tester) async {
      IpSimStimulus? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showIpStimulusDialog(context);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 默认回填 100（经 MHz 后缀定位 CLK 字段；hint 也在树中，
      // 不用文本计数）。
      final clkField = find.widgetWithText(TextFormField, 'MHz');
      expect(clkField, findsOneWidget);
      expect(tester.widget<TextFormField>(clkField).controller!.text, '100',
          reason: 'CLK 频率默认回填 100');
      // 改为 74.25 并确认 → 返回参数带 clkMHz。
      await tester.enterText(clkField, '74.25');
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.clkMHz, 74.25);
      expect(result!.validate(), isNull);
      // 越界（2000）→ 报错且不回传。
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'MHz'), '2000');
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(find.textContaining('CLK频率须在 1~1000 MHz 之间'), findsOneWidget);
    });

    test('iverilog 实仿（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return; // 无 iverilog 跳过
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic));
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
      expect(r.output, contains('PASS'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('激励图案：24 位色彩模式（HSL/RGB/YUV × 字节序）', () {
      // HSL 高字节H：像素 (0,0) = 色相 0、S 满、L 中值；(w-1,0) 色相满。
      final hsl = IpStimulusGen(
          const IpSimStimulus(
              width: 3, height: 2, pattern: IpSimPattern.hsl24Hi),
          255);
      expect(hsl.next(0, 0), (0, 255, 127));
      expect(hsl.next(2, 0), (255, 255, 127));
      // RGB 高字节B（Lo）：第一/第三通道互换——R 水平渐变落到低字节字段。
      final rgbLo = IpStimulusGen(
          const IpSimStimulus(
              width: 3, height: 2, pattern: IpSimPattern.rgb24Lo),
          255);
      expect(rgbLo.next(0, 0), (127, 0, 0)); // R=0,G=0,B=127 → Lo 打包
      expect(rgbLo.next(2, 1), (127, 255, 255)); // R=255,G=255 → (B,G,R)
      // YUV 高字节Y：Y 水平渐变、U 垂直渐变、V 中值。
      final yuv = IpStimulusGen(
          const IpSimStimulus(
              width: 3, height: 2, pattern: IpSimPattern.yuv24Hi),
          255);
      expect(yuv.next(1, 1), (127, 255, 127));
      expect(IpSimPattern.hsl24Lo.colorHighByteFirst, isFalse);
      expect(IpSimPattern.yuv24Hi.colorSpace, 'YUV');
      expect(IpSimPattern.random.isColor24, isFalse);
    });

    test('握手压力激励实仿 PASS（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return; // 无 iverilog 跳过
      final graph = loadSample();
      // 小帧 + 多帧 + 帧间隔 + 输入气泡/输出背压：验证 tb 驱动/监控在
      // 帧间隔与握手下不重发、不重计，golden 数据口径不变。
      const stim = IpSimStimulus(
        width: 16,
        height: 8,
        frames: 2,
        frameGapCycles: 10,
        inGapPct: 30,
        outStallPct: 40,
      );
      final files = buildGroupIpFiles(
          graph, sampleGroup(graph), const IpGenOptions(vendor: IpVendor.generic),
          stimulus: stim);
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
      expect(r.output, contains('PASS'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('无 iverilog 时 runIpSimulation 返回失败并提示', () async {
      final r = await runIpSimulation(const {},
          iverilog: const IverilogToolchain(
              r'X:\not-exist\iverilog.exe', r'X:\not-exist\vvp.exe'));
      // 编译启动失败（exitCode -1）。
      expect(r.success, isFalse);
    });
  });
}
