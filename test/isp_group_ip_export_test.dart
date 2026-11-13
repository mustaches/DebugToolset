// ISP Studio IP Generator（编组 → FPGA Verilog IP 包）测试。
// 围绕「多段色彩均衡器.ispflow」验证校验/规划/Verilog 发射/golden/仿真。
// iverilog 不在场时仿真用例自动 skip（仿黑盒测试的 MSVC skip 模式）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:debug_tool_set/modules/isp_studio/codegen/generated_text_io.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/hsl_pipe_verilog.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_gen_plan.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_stimulus.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_validate.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/iverilog_sim.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/verilog_format.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/vivado_parts.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/vivado_runner.dart';
import 'package:debug_tool_set/modules/isp_studio/models/demo_prj_session.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/demo_prj_dialog.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_gen_dialog.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_stimulus_dialog.dart';

/// 构造一个只含给定节点类型（每类一个）的图，供 UI/规划层用例使用。
IspGraph _graphWith(List<String> types) {
  final graph = IspGraph();
  for (final t in types) {
    final id = graph.addNode(t, 0, 0);
    graph.nodes[id]!.name = t;
  }
  return graph;
}

void main() {
  final samplePath = 'IspFlow/IP_Gen_flow/HSL_MBC_EQ.ispflow';

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
      expect(
        validateGroupIpExport(graph, graph.groups.single),
        contains('lut_fixed'),
      );
    });
  });

  group('IP 规划', () {
    test('位深推导（8bit 源 → PIX_BITS=8、MAXV=255、topName）', () {
      final graph = loadSample();
      final plan = planGroupIp(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
      );
      expect(plan.pixBits, 8);
      expect(plan.maxValue, 255);
      expect(plan.lutDepth, 256);
      expect(plan.topName, 'ISP_IP_MBC_EQ');
      expect(plan.totalDelay, 0);
    });

    test('全部 Process/Datapath 节点具有合法英文名与 IP 名', () {
      expect(IspNodeRegistry.singleNodeGroupTypeIds, hasLength(47));
      for (final typeId in IspNodeRegistry.singleNodeGroupTypeIds) {
        final englishName = IspNodeRegistry.byId(typeId)!.englishName;
        expect(englishName, isNotNull, reason: '$typeId 缺少英文名');
        expect(
          englishName,
          matches(RegExp(r'^[A-Za-z][A-Za-z0-9_]*$')),
          reason: typeId,
        );
        final graph = IspGraph();
        final id = graph.addNode(typeId, 0, 0);
        final group = IspNodeGroup('g1', {id}, name: 'custom_name');
        expect(
          groupIpTopName(graph, group),
          'ISP_IP_$englishName',
          reason: typeId,
        );
      }
    });

    test('选项 pixBits 覆盖位深', () {
      final graph = loadSample();
      final plan = planGroupIp(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic, pixBits: 10),
      );
      expect(plan.pixBits, 10);
      expect(plan.maxValue, 1023);
      expect(plan.lutDepth, 1024);
    });
  });

  group('IP 生成物结构', () {
    test('通用目标文件集与核心/tb/golden 结构', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
      );
      expect(
        files.keys.toList(),
        equals([
          'ISP_IP_MBC_EQ_core.v',
          'ISP_IP_MBC_EQ_top.v',
          'tb_ISP_IP_MBC_EQ.v',
          'golden_in.hex',
          'golden_hash.txt',
          'README.md',
          'ISP_IP_MBC_EQ_V2.0_UserGuide.md',
        ]),
      );
      final userGuide = files['ISP_IP_MBC_EQ_V2.0_UserGuide.md']!;
      expect(userGuide, startsWith('# ISP_IP_MBC_EQ V2.0 User Guide'));
      expect(userGuide, contains('Pixel Bits'));
      expect(userGuide, contains('Max Width'));
      expect(userGuide, contains('Number Of Color Picker Channels'));
      expect(userGuide, contains('Multiply Strategy'));
      expect(userGuide, contains('Fold Factor'));
      expect(userGuide, contains('Band Pipeline'));
      expect(userGuide, contains('0、1、2、3'));
      expect(userGuide, contains('DSP 输入、乘法与输出全流水'));
      expect(userGuide, contains('## IO 接口与数据格式'));
      expect(
        userGuide,
        contains('s_axis_tdata[23:0] = {H[7:0], S[7:0], L[7:0]}'),
      );
      expect(userGuide, contains('par_b{i}_hc'));
      expect(userGuide, contains('par_b{i}_q'));
      expect(userGuide, contains('par_b{i}_dh'));
      expect(userGuide, contains('par_b{i}_s1'));
      expect(userGuide, contains('par_b{i}_l1'));
      expect(userGuide, contains("32'd46603"));
      expect(userGuide, contains("-32'sd1966080"));
      final core = files['ISP_IP_MBC_EQ_core.v']!;
      expect(core, contains('module ISP_IP_MBC_EQ_core'));
      expect(core, contains('parameter integer PIX_BITS  = 8'));
      expect(core, contains('MAXV = (1 << PIX_BITS) - 1'));
      expect(core, contains('_shift_lut'));
      expect(core, contains('_s_mul_q14'));
      expect(core, contains('_l_mul_q14'));
      expect(core, contains('in_ready = ~out_valid | out_ready'));
      final tb = files['tb_ISP_IP_MBC_EQ.v']!;
      expect(tb, contains('EXPECTED_HASH = 32\'h'));
      expect(tb, contains('\$readmemh'));
      expect(tb, contains('\$dumpvars')); // 波形转储供内嵌波形标签页展示
      // golden_in.hex 帧尺寸 = 默认 64×8×1 帧。
      final inLines = files['golden_in.hex']!.trim().split('\n');
      expect(inLines.length, kIpSimW * kIpSimH * kIpSimFrames);
      // golden_hash.txt 与 tb 内嵌哈希一致。
      final hashTxt = files['golden_hash.txt']!.trim();
      expect(hashTxt, matches(RegExp(r'^0x[0-9a-f]{8}$')));
      expect(tb, contains(hashTxt.substring(2)));
    });

    test('所有 Verilog 生成物每行最多 110 字符且参数完整', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      for (final entry in files.entries.where((e) => e.key.endsWith('.v'))) {
        for (final line in entry.value.split('\n')) {
          expect(
            line.length,
            lessThanOrEqualTo(110),
            reason: '${entry.key}: $line',
          );
        }
      }
      final core = files['ISP_IP_MBC_EQ_core.v']!;
      for (final line
          in core
              .split('\n')
              .where((line) => line.contains(RegExp(r'n1_shift_lut\s*\[')))) {
        expect(
          ';'.allMatches(line).length,
          lessThanOrEqualTo(1),
          reason: '每条 LUT 赋值必须独占一行：$line',
        );
      }
      final lutIndents = <int>{};
      for (final line
          in core
              .split('\n')
              .where(
                (line) => line.contains(RegExp(r'n1_shift_lut\s*\[\d+\]')),
              )) {
        lutIndents.add(line.length - line.trimLeft().length);
      }
      expect(lutIndents, hasLength(1), reason: '所有 LUT 赋值必须左对齐');
      for (final line
          in core.split('\n').where((line) => line.contains('.par_b'))) {
        expect(
          '.par_b'.allMatches(line).length,
          1,
          reason: '每个命名端口连接必须独占一行：$line',
        );
      }
      expect(core, contains('.par_b15_l1(par_b15_l1)'));
      expect(
        core.split('\n').where((line) => line.contains('.par_b')).length,
        greaterThan(16),
      );
    });

    test('长表达式折叠多余空白并在运算符前换行', () {
      final source =
          "    (* use_dsp = \"no\" *) wire signed [63:0] p1 = 64'sd603 + ((\$signed(fr) * p1)      + 64'sd32768 + 64'sd32768) >>> 16);";
      final lines = formatVerilogSource(source).split('\n');
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(110));
        expect(line.trimLeft(), isNot('16);'));
      }
      final formatted = lines.join('\n');
      expect(formatted, contains('>>> 16);'));
      expect(formatted, isNot(contains('      +')));
    });

    test('长字符串排版不会拆开 Verilog 字符串字面量', () {
      final source =
          '      \$display("PASS configured IMPL_MODE=%0d NUM_BANDS=%0d; '
          'golden hash uses a different configuration, frame-count check only", '
          'IMPL_MODE, NUM_BANDS);';
      final formatted = formatVerilogSource(source);
      for (final line in formatted.split('\n')) {
        expect(
          '"'.allMatches(line).length.isEven,
          isTrue,
          reason: '字符串被拆行：$line',
        );
      }
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      final demoTb = files['demo/tb_demo.v']!;
      for (final line in demoTb.split('\n')) {
        if (line.trimLeft().startsWith('//')) continue;
        expect('"'.allMatches(line).length.isEven, isTrue, reason: line);
      }
      expect(demoTb, contains('localparam integer GOLDEN_CHECK = 1'));
      expect(demoTb, contains('got == N && GOLDEN_CHECK == 0'));
      expect(demoTb, isNot(contains('dut.inst.')));
      expect(demoTb, contains('repeat (12) @(posedge clk);'));
      expect(demoTb, contains("@(negedge clk);\n    rst_n = 1'b1;"));
      expect(demoTb, contains('frame-count check only"'));
    });

    test('统一核心包含 LUT/函数双实现并默认跟随节点模式', () {
      final graph = loadSample();
      final fxPlan = planGroupIp(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      expect(fxPlan.implMode, 1);
      // 段数取自流程本身（示例流程是用户可编辑文件，band_count 会随取色器增减）。
      final fxNode = graph.nodes.values
          .firstWhere((n) => n.typeId == 'multi_band_eq');
      expect(fxPlan.fxBandCount, fxNode.paramValues['band_count']);
      final fxFiles = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      final fxCore = fxFiles['ISP_IP_MBC_EQ_core.v']!;
      expect(fxCore, contains('module ISP_IP_MBC_EQ_lut_core'));
      expect(fxCore, contains('module ISP_IP_MBC_EQ_fx_core'));
      expect(fxCore, contains('parameter integer IMPL_MODE = 1'));
      expect(RegExp('Generated by').allMatches(fxCore), hasLength(1));
      expect(RegExp('Target vendor').allMatches(fxCore), hasLength(1));
      expect(RegExp('`timescale').allMatches(fxCore), hasLength(1));
      expect(
        fxFiles['demo/create_demo_project.tcl'],
        contains('set_property CONFIG.IMPL_MODE {1} [get_ips ISP_IP_MBC_EQ]'),
      );
      for (final node in graph.nodes.values) {
        if (node.typeId == 'multi_band_eq') {
          node.paramValues['codegenMode'] = 'lut_fixed';
        }
      }
      final lutFiles = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      expect(
        lutFiles['ISP_IP_MBC_EQ_core.v'],
        contains('parameter integer IMPL_MODE = 0'),
      );
      expect(
        lutFiles['demo/create_demo_project.tcl'],
        contains('set_property CONFIG.IMPL_MODE {0} [get_ips ISP_IP_MBC_EQ]'),
      );
    });

    test('Vivado 目标附 axis 封装与 package_ip.tcl', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      expect(files.keys, contains('ISP_IP_MBC_EQ_axis.v'));
      expect(files.keys, contains('package_ip.tcl'));
      expect(files['package_ip.tcl']!, contains('ipx::package_project'));
      // 演示工程（demo/）：演示顶层 + golden tb（打包容器 IP 实例）+
      // 一键建工程脚本（位置无关）。
      expect(files.keys, contains('demo/demo_top.v'));
      expect(files.keys, contains('demo/tb_demo.v'));
      expect(files.keys, contains('demo/create_demo_project.tcl'));
      final xdc = files['demo/timing.xdc']!;
      expect(xdc, contains('create_clock -period 40.000 -name aclk'));
      expect(xdc, contains('-waveform {0.000 20.000}'));
      expect(xdc, isNot(contains('CLOCK_DEDICATED_ROUTE')));
      final demoTop = files['demo/demo_top.v']!;
      expect(demoTop, contains('IBUF u_ibuf'));
      expect(demoTop, contains('BUFGCE #(.CE_TYPE("SYNC")) u_bufgce'));
      expect(demoTop, contains('.CE(1\'b1)'));
      expect(demoTop, contains('u_dut ( .aclk(aclk_int), .* );'));
      final clockRoute = files['demo/clock_route.tcl']!;
      expect(clockRoute, contains('CLOCK_DEDICATED_ROUTE FALSE'));
      expect(clockRoute, contains('get_nets -quiet aclk_IBUF_inst/O'));
      expect(clockRoute, contains('if {[llength \$clockNets] > 0}'));
      expect(xdc, contains('set_input_delay -clock aclk -max 8.000'));
      expect(xdc, contains('set_output_delay -clock aclk -max 8.000'));
      expect(xdc, contains('# 1. Clocks'));
      expect(xdc, contains('# 2. Input and output ports'));
      expect(xdc, contains('# 3. Clock domain crossings'));
      expect(
        xdc,
        contains('set_max_delay -from [all_inputs] -to [all_outputs] 40.000'),
      );
      expect(
        xdc,
        contains('set_min_delay -from [all_inputs] -to [all_outputs] 0.000'),
      );
      expect(xdc, isNot(contains('set_clock_groups')));
      expect(xdc, isNot(contains('get_ports {CH_Enable')));
      final demoTcl = files['demo/create_demo_project.tcl']!;
      expect(demoTcl, contains('add_files -fileset constrs_1'));
      expect(demoTcl, contains('timing.xdc'));
      expect(demoTcl, contains('clock_route.tcl'));
      expect(demoTcl, contains('STEPS.OPT_DESIGN.TCL.PRE'));
      expect(demoTcl, contains('add_files -fileset utils_1'));
      expect(demoTcl, contains('} else {'));
      expect(demoTcl, contains('info script'));
      expect(demoTcl, contains('create_ip -name \$ipName'));
      expect(demoTcl, contains('config_ip_cache -disable'));
      expect(
        demoTcl,
        contains('set_msg_config -id {Synth 8-5409} -new_severity INFO'),
      );
      expect(demoTcl, contains('-module_name ISP_IP_MBC_EQ'));
      expect(demoTcl, isNot(contains('eq_ip')));
      expect(demoTcl, contains('create_ip_run [get_ips ISP_IP_MBC_EQ]'));
      expect(
        demoTcl,
        contains(
          'set_property strategy Flow_PerfOptimized_high [get_runs synth_1]',
        ),
      );
      expect(
        demoTcl,
        contains(
          'set_property strategy Flow_PerfOptimized_high [get_runs ISP_IP_MBC_EQ_synth_1]',
        ),
      );
      expect(
        demoTcl,
        contains('set_property strategy Performance_Explore [get_runs impl_1]'),
      );
      // 演示 tb 直接例化可配置 IP，通配连接适配动态隐藏的参数端口。
      expect(
        files['demo/tb_demo.v']!,
        contains('.m_axis_tready(m_axis_tready)'),
      );
      expect(files.keys, isNot(contains('demo/pins.xdc')));
    });

    test('默认 demo 工程名跟随英文流程名，中文流程保留英文回退', () {
      const cases = {
        'IspFlow/IP_Gen_flow/HSL_MBC_EQ.ispflow': 'HSL_Multi_Band_Color_EQ',
        'IspFlow/IP_Gen_flow/YUV_MBC_EQ.ispflow': 'YUV_Multi_Band_Color_EQ',
      };
      for (final entry in cases.entries) {
        final json =
            jsonDecode(File(entry.key).readAsStringSync())
                as Map<String, Object?>;
        final graph = IspGraph.fromJson(json);
        final group = graph.groups.single;
        expect(defaultGroupDemoProjectName(graph, group), entry.value);
        expect(
          defaultGroupDemoProjectName(graph, group, flowName: 'YUV2HSL'),
          'YUV2HSL',
        );
        expect(
          defaultGroupDemoProjectName(graph, group, flowName: 'My ISP Flow'),
          'My_ISP_Flow',
        );
        expect(
          defaultGroupDemoProjectName(graph, group, flowName: '123Flow'),
          '_123Flow',
        );
      }
    });

    test('demo 导出目录自动追加工程名', () {
      final parent = Directory.current.path;
      expect(
        demoPrjExportDirectory(parent, 'YUV2HSL'),
        p.join(parent, 'YUV2HSL'),
      );
      expect(
        demoPrjExportDirectory(parent, 'HSL_MBC_EQ'),
        p.join(parent, 'HSL_MBC_EQ'),
      );
    });

    test('demo_prj：具体器件与 IP 配置贯通打包和建工程脚本', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(
          vendor: IpVendor.vivado,
          series: VivadoSeries.artix7,
          targetPart: 'xc7a35t-csg324-2',
          targetFamily: 'artix7',
          pixBits: 12,
          maxWidth: 2048,
          gstrategy: 0,
          fold: 4,
          dspPipe: 2,
          projectName: 'my_equalizer_demo',
        ),
      );
      final packageTcl = files['package_ip.tcl']!;
      final demoTcl = files['demo/create_demo_project.tcl']!;
      expect(
        packageTcl,
        contains('create_project -in_memory -part xc7a35t-csg324-2'),
      );
      expect(
        packageTcl,
        contains('-taxonomy /UserIP -import_files -force_update_compile_order'),
      );
      expect(
        packageTcl,
        isNot(contains('update_compile_order -fileset sources_1')),
      );
      expect(
        packageTcl,
        contains('set_property supported_families {artix7 Production}'),
      );
      expect(
        demoTcl,
        contains(
          'create_project -force my_equalizer_demo ./my_equalizer_demo -part xc7a35t-csg324-2',
        ),
      );
      expect(
        demoTcl,
        contains('set_property CONFIG.PIX_BITS {12} [get_ips ISP_IP_MBC_EQ]'),
      );
      expect(
        demoTcl,
        contains(
          'set_property CONFIG.MAX_WIDTH {2048} [get_ips ISP_IP_MBC_EQ]',
        ),
      );
      expect(
        demoTcl,
        contains('set_property CONFIG.GSTRATEGY {0} [get_ips ISP_IP_MBC_EQ]'),
      );
      expect(
        demoTcl,
        contains('set_property CONFIG.FOLD {4} [get_ips ISP_IP_MBC_EQ]'),
      );
      expect(
        demoTcl,
        contains('set_property CONFIG.DSP_PIPE {2} [get_ips ISP_IP_MBC_EQ]'),
      );
    });

    test('Vivado 器件解析忽略日志并保留带空格属性', () {
      final parts = parseVivadoParts(
        'Vivado v2024.2\n'
        'DTS_PART\txazu3eg-sfvc784-1-i\tAutomotive\tzynquplus\tZynq UltraScale+\tsfvc784\t-1\tI\tS\n'
        'DTS_PART\txc7a35tcsg324-2L\tGeneral Purpose\tartix7\t\tcsg324\t-2L\t\tL\n',
      );
      expect(parts, hasLength(2));
      expect(parts[0].category, 'Automotive');
      expect(parts[0].familyDisplay, 'Zynq UltraScale+');
      expect(parts[1].familyDisplay, 'artix7');
      expect(parts[1].staticPower, 'L');
      expect(parts[1].temperature, isEmpty);
    });

    test('Vivado 探测支持注入 bin 目录', () async {
      final dir = await Directory.systemTemp.createTemp('vivado_detect_');
      try {
        final exe = File('${dir.path}${Platform.pathSeparator}vivado.exe');
        await exe.writeAsString('');
        expect(detectVivado(searchDirs: [dir.path])?.executable, exe.path);
        expect(
          detectVivado(
            searchDirs: ['${dir.path}${Platform.pathSeparator}missing'],
          ),
          isNull,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('Vivado 多安装按版本排序并去重', () async {
      final root = await Directory.systemTemp.createTemp('vivado_installs_');
      try {
        Future<String> makeInstall(String version) async {
          final bin = Directory(
            '${root.path}${Platform.pathSeparator}$version${Platform.pathSeparator}bin',
          );
          await bin.create(recursive: true);
          final exe = File('${bin.path}${Platform.pathSeparator}vivado.exe');
          await exe.writeAsString('');
          return bin.path;
        }

        final oldBin = await makeInstall('2020.2');
        await makeInstall('2024.2');
        final newBin = Directory(
          '${root.path}${Platform.pathSeparator}2026.1${Platform.pathSeparator}Vivado${Platform.pathSeparator}bin',
        );
        await newBin.create(recursive: true);
        await File(
          '${newBin.path}${Platform.pathSeparator}vivado.bat',
        ).writeAsString('');
        final all = detectVivadoInstallations(
          searchDirs: [oldBin],
          installRoots: [root.path],
        );
        expect(all, hasLength(3));
        expect(all[0].version, '2026.1');
        expect(all[1].version, '2024.2');
        expect(all[2].version, '2020.2');
        expect(preferredVivadoToolchain(all)?.version, '2020.2');
        expect(preferredVivadoToolchain([all[0], all[1]])?.version, '2026.1');
        expect(all[0], VivadoToolchain(all[0].executable));
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('注册表 LaunchVlmString 支持自定义安装路径', () {
      final bins = parseVivadoRegistryBins(
        r'    LaunchVlmString    REG_SZ    d:\AMDDesignTools\2026.1\Vivado\bin\unwrapped\win64.o\vvgl.exe d:\AMDDesignTools\2026.1\Vivado\bin\vlm.bat'
        '\n'
        r'    LaunchVlmString    REG_SZ    "D:\Custom Tools\2027.1\Vivado\bin\unwrapped\win64.o\vvgl.exe" "D:\Custom Tools\2027.1\Vivado\bin\vlm.bat"',
      );
      expect(bins, hasLength(2));
      expect(
        bins,
        contains(
          File(
            r'd:\AMDDesignTools\2026.1\Vivado\bin\unwrapped\win64.o\vvgl.exe',
          ).parent.parent.parent.path,
        ),
      );
      expect(
        bins,
        contains(
          File(
            r'D:\Custom Tools\2027.1\Vivado\bin\unwrapped\win64.o\vvgl.exe',
          ).parent.parent.parent.path,
        ),
      );
    });

    testWidgets('demo_prj 对话框联动筛选、搜索并返回选中器件', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const parts = [
        VivadoPart(
          name: 'xc7a35t-csg324-2',
          category: 'General Purpose',
          family: 'artix7',
          familyDisplay: 'Artix-7',
          package: 'csg324',
          speed: '-2',
          temperature: 'C',
          staticPower: 'S',
        ),
        VivadoPart(
          name: 'xc7k325tffg900-2',
          category: 'General Purpose',
          family: 'kintex7',
          familyDisplay: 'Kintex-7',
          package: 'ffg900',
          speed: '-2',
          temperature: 'C',
          staticPower: 'S',
        ),
        VivadoPart(
          name: 'xazu3eg-sfvc784-1-i',
          category: 'Automotive',
          family: 'zynquplus',
          familyDisplay: 'Zynq UltraScale+',
          package: 'sfvc784',
          speed: '-1',
          temperature: 'I',
          staticPower: 'S',
        ),
      ];
      IpGenOptions? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showDemoPrjDialog(
                  context,
                  initial: const IpGenOptions(
                    vendor: IpVendor.vivado,
                    series: VivadoSeries.artix7,
                    targetPart: 'xc7a35t-csg324-2',
                    pixBits: 12,
                  ),
                  defaultProjectName: 'HSL_Multi_Band_Color_EQ',
                  vivado: const VivadoToolchain('fake-vivado'),
                  parts: parts,
                );
              },
              child: const Text('open-demo'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-demo'));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3 个器件'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Package'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ffg900').last);
      await tester.pumpAndSettle();
      expect(find.text('1 / 3 个器件'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, 'Speed'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('-2').last);
      await tester.pumpAndSettle();
      expect(find.text('1 / 3 个器件'), findsOneWidget);
      await tester.tap(find.text('Reset All Filters'));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3 个器件'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '325t');
      await tester.pumpAndSettle();
      expect(find.text('1 / 3 个器件'), findsOneWidget);
      await tester.tap(find.text('xc7k325tffg900-2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成工程'));
      await tester.pumpAndSettle();
      expect(find.text('请输入工程名'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller
            ?.text,
        'HSL_Multi_Band_Color_EQ',
      );
      await tester.enterText(find.byType(TextFormField), 'my_video_demo');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result?.projectName, 'my_video_demo');
      expect(result?.targetPart, 'xc7k325tffg900-2');
      expect(result?.targetFamily, 'kintex7');
      expect(result?.pixBits, 12);
      expect(result?.vendor, IpVendor.vivado);
    });

    testWidgets('默认 PART 与六项过滤器按预设值初始化', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const defaultPart = VivadoPart(
        name: 'xczu15eg-ffvb1156-2-i',
        category: 'General Purpose',
        family: 'zynquplus',
        familyDisplay: 'Zynq UltraScale+',
        package: 'ffvb1156',
        speed: '-2',
        temperature: 'I',
        staticPower: 'S',
      );
      const otherPart = VivadoPart(
        name: 'xc7a35t-csg324-2',
        category: 'General Purpose',
        family: 'artix7',
        familyDisplay: 'Artix-7',
        package: 'csg324',
        speed: '-2',
        temperature: 'C',
        staticPower: 'S',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDemoPrjDialog(
                context,
                initial: const IpGenOptions(vendor: IpVendor.vivado),
                vivado: const VivadoToolchain('fake-vivado'),
                parts: const [defaultPart, otherPart],
              ),
              child: const Text('open-default-demo'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-default-demo'));
      await tester.pumpAndSettle();
      String filterValue(String label) => tester
          .widget<DropdownButtonFormField<String>>(
            find.widgetWithText(DropdownButtonFormField<String>, label),
          )
          .initialValue!;
      expect(filterValue('Category'), 'General Purpose');
      expect(filterValue('Family'), 'Zynq UltraScale+');
      expect(filterValue('Package'), 'ffvb1156');
      expect(filterValue('Speed'), '-2');
      expect(filterValue('Temperature'), 'I');
      expect(filterValue('Static power'), '');
      expect(find.text('1 / 2 个器件'), findsOneWidget);
      expect(find.text('目标 PART：xczu15eg-ffvb1156-2-i'), findsOneWidget);
      await tester.tap(find.text('Reset All Filters'));
      await tester.pumpAndSettle();
      expect(filterValue('Category'), '');
      expect(find.text('2 / 2 个器件'), findsOneWidget);
    });

    testWidgets('demo_prj 切换 Vivado 版本后加载对应器件并返回执行路径', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const oldToolchain = VivadoToolchain(
        r'C:\Xilinx\Vivado\2020.2\bin\vivado.bat',
      );
      const newToolchain = VivadoToolchain(
        r'C:\Xilinx\Vivado\2024.2\bin\vivado.bat',
      );
      VivadoPart part(String name, String family) => VivadoPart(
        name: name,
        category: 'General Purpose',
        family: family,
        familyDisplay: family,
        package: 'pkg',
        speed: '-1',
        temperature: 'C',
        staticPower: 'S',
      );
      IpGenOptions? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showDemoPrjDialog(
                  context,
                  initial: IpGenOptions(
                    vendor: IpVendor.vivado,
                    targetPart: 'xc-old',
                    vivadoExecutable: oldToolchain.executable,
                  ),
                  toolchains: const [newToolchain, oldToolchain],
                  partsLoader: (toolchain) async => [
                    part(
                      toolchain.version == '2024.2' ? 'xc-new' : 'xc-old',
                      toolchain.version,
                    ),
                  ],
                );
              },
              child: const Text('open-versioned-demo'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-versioned-demo'));
      await tester.pumpAndSettle();
      expect(find.text('xc-old'), findsWidgets);
      await tester.tap(
        find.widgetWithText(
          DropdownButtonFormField<VivadoToolchain>,
          'Vivado 版本',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Vivado 2024.2').last);
      await tester.pumpAndSettle();
      expect(find.text('xc-new'), findsOneWidget);
      await tester.tap(find.text('xc-new'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成工程'));
      await tester.pumpAndSettle();
      expect(find.text('请输入工程名'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller
            ?.text,
        'demo_prj',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result?.targetPart, 'xc-new');
      expect(result?.targetFamily, '2024.2');
      expect(result?.vivadoExecutable, newToolchain.executable);
    });

    testWidgets('IP 选项对话框按编组内容显示 YUV 矩阵标准', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // 只有含 YUV↔RGB 节点的编组才显示该配置项（RGB→HSL 等编组不显示）。
      expect(
        groupHasYuvMatrix(
          _graphWith(['csc_rgb2hsl', 'color_temp_adjuster']),
          IspNodeGroup('g', {'n0', 'n1'}),
        ),
        isFalse,
      );
      expect(
        groupHasYuvMatrix(
          _graphWith(['csc_yuv2rgb', 'csc_rgb2hsl']),
          IspNodeGroup('g', {'n0', 'n1'}),
        ),
        isTrue,
      );
      for (final (hasYuv, expected) in [
        (false, findsNothing),
        (true, findsOneWidget),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showIpGenDialog(
                  context,
                  hasYuvMatrix: hasYuv,
                  toolchains: const [VivadoToolchain('fake-vivado')],
                  parts: [
                    VivadoPart(
                      name: 'xczu15eg-ffvb1156-2-i',
                      category: 'General Purpose',
                      family: 'zynquplus',
                      familyDisplay: 'Zynq UltraScale+',
                      package: 'ffvb1156',
                      speed: '-2',
                      temperature: 'I',
                      staticPower: 'S',
                    ),
                  ],
                ),
                child: Text('open-ip-$hasYuv'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open-ip-$hasYuv'));
        await tester.pumpAndSettle();
        expect(find.text('YUV 矩阵标准（YUV↔RGB）'), expected);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      // 导出 demo_prj 对话框同一口径。
      final part = VivadoPart(
        name: 'xczu15eg-ffvb1156-2-i',
        category: 'General Purpose',
        family: 'zynquplus',
        familyDisplay: 'Zynq UltraScale+',
        package: 'ffvb1156',
        speed: '-2',
        temperature: 'I',
        staticPower: 'S',
      );
      for (final (hasYuv, expected) in [
        (false, findsNothing),
        (true, findsOneWidget),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showDemoPrjDialog(
                  context,
                  initial: const IpGenOptions(vendor: IpVendor.vivado),
                  hasYuvMatrix: hasYuv,
                  vivado: const VivadoToolchain('fake-vivado'),
                  parts: [part],
                ),
                child: Text('open-demo-$hasYuv'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open-demo-$hasYuv'));
        await tester.pumpAndSettle();
        expect(find.text('YUV 矩阵标准（YUV↔RGB）'), expected);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('导出IP 对话框支持版本回填和按版本切换器件', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const oldToolchain = VivadoToolchain(
        r'C:\Xilinx\Vivado\2020.2\bin\vivado.bat',
      );
      const newToolchain = VivadoToolchain(
        r'C:\Xilinx\Vivado\2024.2\bin\vivado.bat',
      );
      VivadoPart part(String name) => VivadoPart(
        name: name,
        category: 'General Purpose',
        family: 'family-$name',
        familyDisplay: 'Family',
        package: 'pkg',
        speed: '-1',
        temperature: 'C',
        staticPower: 'S',
      );
      IpGenOptions? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showIpGenDialog(
                  context,
                  initial: IpGenOptions(
                    vendor: IpVendor.vivado,
                    targetPart: 'xc-old',
                    vivadoExecutable: oldToolchain.executable,
                  ),
                  toolchains: const [newToolchain, oldToolchain],
                  partsLoader: (toolchain) async => [
                    part(toolchain.version == '2024.2' ? 'xc-new' : 'xc-old'),
                  ],
                );
              },
              child: const Text('open-versioned-ip'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-versioned-ip'));
      await tester.pumpAndSettle();
      expect(find.text('xc-old'), findsWidgets);
      await tester.tap(
        find.widgetWithText(
          DropdownButtonFormField<VivadoToolchain>,
          'Vivado 版本',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Vivado 2024.2').last);
      await tester.pumpAndSettle();
      expect(find.text('xc-new'), findsOneWidget);
      await tester.tap(find.text('xc-new'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      expect(result?.targetPart, 'xc-new');
      expect(result?.targetFamily, 'family-xc-new');
      expect(result?.vivadoExecutable, newToolchain.executable);
    });

    test('Vivado 目标：参数校验列表 + xgui 定制界面 + 优化策略参数', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      // xgui 定制界面文件随包产出（打包时拷入组件 xgui/ 目录）。
      final xgui = files['xgui/ISP_IP_MBC_EQ_v2_0.tcl']!;
      expect(xgui, contains('ipgui::add_page'));
      expect(xgui, contains('display_name "General"'));
      expect(xgui, contains('display_name "Optimization"'));
      expect(xgui, isNot(contains('dts_text')));
      expect(xgui.codeUnits.every((c) => c <= 127), isTrue);
      expect(xgui, contains('ipgui::add_param \$IPINST -name "FOLD"'));
      expect(RegExp(r'-widget comboBox').allMatches(xgui), hasLength(8));
      expect(RegExp(r'ipgui::add_static_text').allMatches(xgui), hasLength(8));
      expect(xgui, contains('ipgui::add_param \$IPINST -name "IMPL_MODE"'));
      expect(
        xgui,
        contains('display_name "Behavior Implementation (IMPL_MODE)"'),
      );
      expect(xgui, contains('ipgui::add_param \$IPINST -name "WORK_MODE"'));
      expect(xgui, contains('display_name "Work Mode (WORK_MODE)"'));
      expect(xgui, isNot(contains('-tooltip')));
      expect(xgui, isNot(contains('-text_icon')));
      // package_ip.tcl：四个定制参数 + 校验列表 + FOLD 面积档联动。
      final tcl = files['package_ip.tcl']!;
      expect(
        tcl,
        contains(
          'set_property value 3840 [ipx::get_user_parameters MAX_WIDTH]',
        ),
      );
      expect(tcl, contains('ipx::add_user_parameter GSTRATEGY'));
      expect(tcl, contains('ipx::add_user_parameter FOLD'));
      expect(
        tcl,
        contains(
          "set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.GSTRATEGY')) = 0)} [ipx::get_user_parameters FOLD]",
        ),
      );
      expect(
        tcl,
        contains(
          'set_property enablement_resolve_type dependent [ipx::get_user_parameters FOLD]',
        ),
      );
      expect(tcl, contains('value_validation_list {8 10 12 14 16}'));
      expect(
        tcl,
        contains(
          'value_validation_list {320 400 600 640 1000 1280 1920 2048 3840 4096 7680 8192}',
        ),
      );
      expect(tcl, contains('value_validation_type pairs'));
      expect(tcl, contains('[list "Area (folded operators)" 0'));
      expect(tcl, contains('[list "Combinational (lowest latency)" 0'));
      expect(tcl, contains('"Remap HSL color space using LUT file" 0'));
      expect(tcl, contains('"Call a function to modify HSL color space" 1'));
      expect(
        tcl,
        contains(
          "set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.IMPL_MODE')) = 1) && (spirit:decode(id('PARAM_VALUE.NUM_BANDS')) > 0)}",
        ),
      );
      expect(tcl, isNot(contains('dts_text')));
      expect(tcl, contains('set_property version 2.0'));
      expect(tcl, contains('ISP_IP_MBC_EQ_axis_v2_0.tcl'));
      expect(tcl, contains('set xguiDir "./ip_repo/xgui"'));
      expect(tcl, isNot(contains('ipx::get_model_parameters FOLD')));
      // 位置无关：先 cd 到脚本目录（Run Tcl Script 的 cwd 不是脚本目录）。
      expect(tcl, contains('cd [file dirname [file normalize [info script]]]'));
      // RTL 顶层带优化策略参数（预留，generate 分档待窗口算子）。
      expect(files['ISP_IP_MBC_EQ_top.v']!, contains('GSTRATEGY'));
      expect(files['ISP_IP_MBC_EQ_axis.v']!, contains('FOLD'));
    });

    test('资源估算写入 README 且数值合理', () {
      final graph = loadSample();
      for (final node in graph.nodes.values) {
        if (node.typeId == 'multi_band_eq') {
          node.paramValues['codegenMode'] = 'lut_fixed';
        }
      }
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final readme = files['README.md']!;
      expect(readme, contains('资源估算'));
      expect(readme, contains('DSP'));
      expect(readme, contains('1.0 px/clk'));
      // 规划层直接对拍：8 位域（MAXV=255）时 ROM = 256×50 bit、
      // 折算 1 块 36K BRAM、性能档 2 个 DSP。
      final plan = planGroupIp(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
      );
      expect(plan.resources.romBits, 256 * 50);
      expect(plan.resources.bram36k, 1);
      expect(plan.resources.estDsps, 2);
      expect(plan.resources.latencyCycles, 1);
      expect(readme, contains('${plan.resources.romBits} bit'));
      // 平衡档：乘法器绑 LUT，DSP 为 0。
      final planBal = planGroupIp(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic, gstrategy: 1),
      );
      expect(planBal.resources.estDsps, 0);
      expect(planBal.resources.estLuts, greaterThan(plan.resources.estLuts));
    });

    test('Libero 目标附 libero 封装', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.libero),
      );
      expect(files.keys, contains('ISP_IP_MBC_EQ_libero.v'));
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
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: stim,
      );
      // golden_in.hex 行数 = 32×16×2 帧。
      final inLines = files['golden_in.hex']!.trim().split('\n');
      expect(inLines.length, 32 * 16 * 2);
      final tb = files['tb_ISP_IP_MBC_EQ.v']!;
      expect(tb, contains('W  = 32'));
      expect(tb, contains('H  = 16'));
      expect(tb, contains('FRAMES = 2'));
      expect(tb, contains('FRAME_GAP = 100'));
      expect(tb, contains('GAP_PCT   = 25'));
      expect(tb, contains('STALL_PCT = 50'));
      expect(tb, contains("SEED = 32'habcdef01"));
      expect(tb, contains('hGradient'));
      // golden_hash.txt 与 tb 内嵌哈希一致，且与默认激励的哈希不同。
      final hashTxt = files['golden_hash.txt']!.trim();
      expect(tb, contains(hashTxt.substring(2)));
      final defFiles = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
      );
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

    test('CLK 频率：默认 25MHz 生成 always #20，自定义频率烘焙半周期', () {
      final graph = loadSample();
      final defTb = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
      )['tb_ISP_IP_MBC_EQ.v']!;
      expect(defTb, contains('always #20 clk = ~clk;'));
      expect(defTb, isNot(contains('CLK frequency')));
      // 50MHz：半周期 10ns + 注释；summary 带 CLK 段。
      const stim50 = IpSimStimulus(clkMHz: 50);
      expect(stim50.isDefault, isFalse);
      expect(stim50.summary(), contains('CLK50M'));
      expect(const IpSimStimulus().summary(), isNot(contains('CLK')));
      final tb50 = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: stim50,
      )['tb_ISP_IP_MBC_EQ.v']!;
      expect(tb50, contains('// CLK frequency 50 MHz'));
      expect(tb50, contains('always #10 clk = ~clk;'));
      // 小数频率：148.5MHz → 半周期 3.367ns（1ps 精度去尾零）。
      final tb148 = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: const IpSimStimulus(clkMHz: 148.5),
      )['tb_ISP_IP_MBC_EQ.v']!;
      expect(tb148, contains('// CLK frequency 148.5 MHz'));
      expect(tb148, contains('always #3.367 clk = ~clk;'));
      // 半周期/频率格式助手。
      expect(ipClkHalfNs(100), '5');
      expect(ipClkHalfNs(200), '2.5');
      expect(fmtClkMHz(100), '100');
      expect(fmtClkMHz(74.25), '74.25');
    });

    testWidgets('激励参数对话框：默认 1 帧/25MHz，可改小数并校验越界', (tester) async {
      IpSimStimulus? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showIpStimulusDialog(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final framesField = find.widgetWithText(TextFormField, '帧数');
      expect(
        tester.widget<TextFormField>(framesField).controller!.text,
        '1',
        reason: '帧数默认回填 1',
      );
      // 经 MHz 后缀定位 CLK 字段；hint 也在树中，不用文本计数。
      final clkField = find.widgetWithText(TextFormField, 'MHz');
      expect(clkField, findsOneWidget);
      expect(
        tester.widget<TextFormField>(clkField).controller!.text,
        '25',
        reason: 'CLK 频率默认回填 25',
      );
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
      await tester.enterText(find.widgetWithText(TextFormField, 'MHz'), '2000');
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(find.textContaining('CLK频率须在 1~1000 MHz 之间'), findsOneWidget);
    });

    test('ColorTrans 与色温定点 IP：逐类型双模式实仿', () async {
      if (detectIverilog() == null) return;
      const types = [
        'csc_rgb2yuv',
        'csc_rgb2hsl',
        'csc_yuv2rgb',
        'csc_yuv2hsl',
        'csc_hsl2rgb',
        'csc_hsl2yuv',
        'color_temp_adjuster',
      ];
      for (final type in types) {
        for (final mode in ['func_fixed', 'lut_fixed']) {
          final graph = IspGraph();
          final id = graph.addNode(type, 0, 0);
          graph.nodes[id]!.name = 'n1';
          graph.nodes[id]!.paramValues['codegenMode'] = mode;
          if (type == 'color_temp_adjuster') {
            graph.nodes[id]!.paramValues['temperature'] = 4200.0;
          }
          if (type == 'csc_rgb2yuv') {
            graph.nodes[id]!.paramValues['standard'] = 'bt709';
            graph.nodes[id]!.paramValues['range'] = 'limited';
          }
          final group = IspNodeGroup('g1', {id}, name: type);
          expect(validateGroupIpExport(graph, group), isNull);
          final files = buildGroupIpFiles(
            graph,
            group,
            const IpGenOptions(vendor: IpVendor.generic),
            stimulus: const IpSimStimulus(width: 8, height: 2, frames: 2),
          );
          final core =
              files['ISP_IP_${IspNodeRegistry.byId(type)!.englishName}_core.v']!;
          expect(
            core,
            contains(
              'module ISP_IP_${IspNodeRegistry.byId(type)!.englishName}_core',
            ),
          );
          expect(core, isNot(contains('CH_Enable')));
          if (type == 'csc_yuv2rgb' && mode == 'func_fixed') {
            expect(core, contains('dsp_mul'));
            expect(core, contains('_u_rr'));
            expect(core, contains('_u_gg1'));
            expect(core, contains('_u_gg2'));
            expect(core, contains('_u_bb'));
          }
          if (type == 'csc_rgb2hsl') {
            // 默认性能档（GSTRATEGY=2）走全流水 DSP 通路：模块级不再绑 LUT。
            expect(core, isNot(contains('(* use_dsp = "no" *)\nmodule')));
            if (mode == 'func_fixed') {
              expect(core, contains('f_hsl_seed'));
              expect(core, contains('_m1b_reg'));
            }
          }
          if (type == 'csc_yuv2hsl') {
            // YUV2HSL 仍为组合函数数据通路，性能档交给综合器自选 DSP。
            expect(core, isNot(contains('(* use_dsp = "no" *)\nmodule')));
          }
          if ((type == 'csc_rgb2hsl' || type == 'csc_yuv2hsl') &&
              mode == 'func_fixed') {
            expect(core, isNot(contains('reg [31:0] f_recip_seed')));
            if (core.contains('f_recip_seed')) {
              expect(core, contains('function [31:0] f_recip_seed'));
            }
          }
          final r = await runIpSimulation(files);
          expect(r.success, isTrue, reason: '$type/$mode: ${r.output}');
          expect(r.passed, isTrue, reason: '$type/$mode: ${r.output}');
        }
      }
      final graph = IspGraph();
      final ct = graph.addNode('color_temp_adjuster', 0, 0);
      final csc = graph.addNode('csc_rgb2yuv', 0, 0);
      graph.nodes[ct]!.paramValues['codegenMode'] = 'func_fixed';
      graph.nodes[ct]!.paramValues['temperature'] = 4200.0;
      graph.nodes[csc]!.paramValues['codegenMode'] = 'lut_fixed';
      graph.connect(ct, 'out_rgb', csc, 'in');
      final chain = IspNodeGroup('g_chain', {ct, csc}, name: 'fixed_chain');
      expect(validateGroupIpExport(graph, chain), isNull);
      final files = buildGroupIpFiles(
        graph,
        chain,
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: const IpSimStimulus(width: 8, height: 2, frames: 2),
      );
      final result = await runIpSimulation(files);
      expect(result.passed, isTrue, reason: result.output);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('色温 IP：14 位 cct_in/cct_out 运行期端口 + 内部 CCM（多帧实仿）',
        () async {
      final graph = IspGraph();
      final id = graph.addNode('color_temp_adjuster', 0, 0);
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'clr_temp');
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(
          vendor: IpVendor.vivado,
          targetPart: 'xczu15eg-ffvb1156-2-i',
          targetFamily: 'zynquplus',
        ),
        stimulus: const IpSimStimulus(width: 16, height: 8, frames: 4),
      );
      final core = files['ISP_IP_Color_Temperature_core.v']!;
      // 图像接口是 RGB 打包像素流，控制/测量固定 14 位。
      expect(core, contains('input wire [13:0] cct_in'));
      expect(core, contains('output wire [13:0] cct_out'));
      // 内部控制块：白点表 + 倒数表 + 测量 FSM（CCM 系数不作为参数/端口暴露）。
      expect(core, contains('ISP_IP_Color_Temperature_ct_ctrl'));
      expect(core, contains('ct_rcp'));
      // 白点表放进块 RAM（内存名随通道命名，见 _ctWhiteRom）。
      expect(core, contains('ct_wr_mem'));
      expect(core, isNot(contains('parameter integer CCM')));
      expect(core, contains('gain_r'), reason: '内部自动算出的 Q14 增益');
      // 顶层与 AXI 包装同样透出这对端口。
      expect(files['ISP_IP_Color_Temperature_top.v'], contains('cct_in'));
      expect(files['ISP_IP_Color_Temperature_axis.v'], contains('cct_out'));
      // tb 恒定驱动目标色温（与烘焙参数不同）并把测量值并入 golden 哈希。
      expect(
        files['tb_ISP_IP_Color_Temperature.v'],
        contains("reg [13:0] cct_in = 14'd7000"),
      );
      expect(
        files['tb_ISP_IP_Color_Temperature.v'],
        contains("fnv_u16(fnv, {2'b0, cct_out})"),
      );
      if (detectIverilog() == null) return; // 无 iverilog 跳过实仿
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('色温表存储选项 USE_BRAM：默认块 RAM，0 复原组合 ROM（两者逐位一致）',
        () async {
      IspGraph makeGraph() {
        final g = IspGraph();
        final id = g.addNode('color_temp_adjuster', 0, 0);
        g.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
        return g;
      }

      final g1 = makeGraph();
      final grp = IspNodeGroup('g1', {g1.nodes.keys.first}, name: 'clr_temp');
      final bram = buildGroupIpFiles(
        g1,
        grp,
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: const IpSimStimulus(width: 16, height: 8, frames: 3),
      );
      // 两套实现都打进核（generate 选择），默认值随导出选项。
      expect(bram['ISP_IP_Color_Temperature_core.v']!,
          contains('parameter integer USE_BRAM = 1'));
      expect(bram['ISP_IP_Color_Temperature_core.v']!,
          contains('ram_style = "block"'));
      expect(bram['ISP_IP_Color_Temperature_core.v']!,
          contains('ISP_IP_Color_Temperature_ct_gain ('));
      expect(bram['ISP_IP_Color_Temperature_core.v']!,
          contains('ISP_IP_Color_Temperature_ct_gain_lut ('));

      final g2 = makeGraph();
      final grp2 = IspNodeGroup('g2', {g2.nodes.keys.first}, name: 'clr_temp');
      final lut = buildGroupIpFiles(
        g2,
        grp2,
        const IpGenOptions(vendor: IpVendor.generic, useBram: false),
        stimulus: const IpSimStimulus(width: 16, height: 8, frames: 3),
      );
      // 取消勾选只是把默认值改成 0（两套实现仍在核里，Customize IP 可切）。
      expect(lut['ISP_IP_Color_Temperature_core.v']!,
          contains('parameter integer USE_BRAM = 0'));
      expect(lut['ISP_IP_Color_Temperature_core.v']!,
          contains('ISP_IP_Color_Temperature_ct_gain_lut ('));

      // 打包脚本声明该用户参数并给出两项选择（Customize IP 下拉能看到 0 和 1）；
      // package_ip.tcl / xgui 只在 Vivado 目标下生成。
      final g3 = makeGraph();
      final grp3 = IspNodeGroup('g3', {g3.nodes.keys.first}, name: 'clr_temp');
      final vivadoPkg = buildGroupIpFiles(
        g3,
        grp3,
        const IpGenOptions(
          vendor: IpVendor.vivado,
          targetPart: 'xczu15eg-ffvb1156-2-i',
          targetFamily: 'zynquplus',
        ),
        stimulus: const IpSimStimulus(width: 16, height: 8, frames: 2),
      );
      final pkg = vivadoPkg['package_ip.tcl']!;
      expect(pkg, contains('ipx::add_user_parameter USE_BRAM'));
      expect(pkg, contains('set_property value_validation_pairs'));
      expect(pkg, contains('Block RAM (saves CLB LUTs)" 1'));
      expect(pkg, contains('Combinational ROM (previous build)" 0'));
      final xgui = vivadoPkg['xgui/ISP_IP_Color_Temperature_v2_0.tcl']!;
      expect(xgui, contains('name "USE_BRAM"'));
      // 关键：用户参数必须同步到模型参数，否则 CONFIG/Customize IP 改了不生效
      //（wrapper 仍用打包时的默认值）。
      expect(xgui, contains('proc update_MODELPARAM_VALUE.USE_BRAM'));
      expect(vivadoPkg['xgui/ISP_IP_Color_Temperature_v2_0.tcl']!,
          contains('proc update_MODELPARAM_VALUE.DSP_PIPE'));
      expect(vivadoPkg['xgui/ISP_IP_Color_Temperature_v2_0.tcl']!,
          contains('proc update_MODELPARAM_VALUE.PIX_BITS'));

      if (detectIverilog() == null) return; // 无 iverilog 跳过实仿
      final bramRun = await runIpSimulation(bram);
      expect(bramRun.passed, isTrue, reason: 'BRAM 版：${bramRun.output}');
      final lutRun = await runIpSimulation(lut);
      expect(lutRun.passed, isTrue, reason: 'LUT 版：${lutRun.output}');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('多节点编组：色温节点不暴露运行期端口（互连无唯一控制端口）',
        () {
      final graph = IspGraph();
      final ct = graph.addNode('color_temp_adjuster', 0, 0);
      final csc = graph.addNode('csc_rgb2yuv', 0, 0);
      graph.nodes[ct]!.paramValues['codegenMode'] = 'func_fixed';
      graph.nodes[csc]!.paramValues['codegenMode'] = 'func_fixed';
      graph.connect(ct, 'out_rgb', csc, 'in');
      final group = IspNodeGroup('g_chain', {ct, csc}, name: 'fixed_chain');
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: const IpSimStimulus(width: 8, height: 2, frames: 2),
      );
      final core = files['n1/ISP_IP_Color_Temperature_core.v']!;
      expect(core, isNot(contains('cct_in')));
      expect(files['isp_ip_fixed_chain_top.v'], isNot(contains('cct_in')));
    });

    test('HSL 方向种子表 USE_BRAM：块 RAM 版省 LUT，两档 golden 逐位一致',
        () async {
      // YUV→HSL / RGB→HSL 的全流水通路里有一张 256×17 的牛顿种子表
      //（f_hsl_seed）。USE_BRAM=1 时放进 BRAM（读口寄存与本级 rec 同拍，
      // 整链 LAT 不变）；=0 时保留 case 函数写法。两者数值必须一致。
      Map<String, String> ipOf(String typeId, {required bool useBram}) {
        final g = IspGraph();
        final id = g.addNode(typeId, 0, 0);
        g.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
        return buildGroupIpFiles(
          g,
          IspNodeGroup('g_$typeId$useBram', {id}, name: 'csc'),
          IpGenOptions(vendor: IpVendor.generic, useBram: useBram),
          stimulus: const IpSimStimulus(),
        );
      }

      for (final typeId in ['csc_yuv2hsl', 'csc_rgb2hsl']) {
        final name =
            typeId == 'csc_yuv2hsl' ? 'YUV_to_HSL' : 'RGB_to_HSL';
        final bram = ipOf(typeId, useBram: true);
        final lut = ipOf(typeId, useBram: false);
        final core = bram['ISP_IP_${name}_core.v']!;
        // 参数默认值随导出选项；两套实现都在核里（generate 选择）。
        expect(core, contains('parameter integer USE_BRAM = 1'));
        expect(core, contains('rom_style = "block"'));
        expect(core, contains('_seed_rom [0:255]'));
        expect(core, contains("f_hsl_seed({1'b1"));
        expect(lut['ISP_IP_${name}_core.v']!,
            contains('parameter integer USE_BRAM = 0'));
        // 索引在 hsl_m 子模块里算好、随 rec M 同拍寄存（表读取落在 m→q
        // 一个时钟沿），hsl_q 只做打包。
        expect(core, contains('_hsl_m #(.PIX_BITS(PIX_BITS))'));
        expect(core, contains('f_hsl_normk(den)'));
        expect(bram['golden_hash.txt'], lut['golden_hash.txt']);

        if (detectIverilog() == null) continue;
        final rb = await runIpSimulation(bram);
        final rl = await runIpSimulation(lut);
        expect(rb.passed, isTrue, reason: rb.output);
        expect(rl.passed, isTrue, reason: rl.output);
        String fnv(String s) =>
            RegExp(r'fnv=([0-9a-f]{8})').firstMatch(s)?.group(1) ?? '?';
        expect(fnv(rb.output), fnv(rl.output),
            reason: '$typeId：两种表实现必须逐位一致');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('RGB2HSL PIX_BITS=8：牛顿种子表可选 BRAM ROM / case 函数两档', () {
      final graph = IspGraph();
      final id = graph.addNode('csc_rgb2hsl', 0, 0);
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_rgb2hsl');
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.generic, pixBits: 8),
      );
      final core = files['ISP_IP_RGB_to_HSL_core.v']!;
      // f_div_round 的倒数种子仍是函数（组合回退通路的实现，不进综合）。
      expect(core, contains('function [31:0] f_recip_seed'));
      expect(core, contains('f_recip_seed(idx)'));
      expect(core, isNot(contains('reg [31:0] f_recip_seed')));
      // 全流水通路的牛顿种子表：默认 USE_BRAM=1 → 256×17 的 BRAM ROM；
      // 两套实现同时在核里（generate 选择），所以 case 函数版也在。
      expect(core, contains('parameter integer USE_BRAM = 1'));
      expect(core, contains('_seed_rom [0:255]'));
      expect(core, contains('rom_style = "block"'));
      expect(core, contains('function [16:0] f_hsl_seed'));
      expect(core, contains("f_hsl_seed({1'b1"));
      final g2 = IspGraph();
      final id2 = g2.addNode('csc_rgb2hsl', 0, 0);
      g2.nodes[id2]!.paramValues['codegenMode'] = 'func_fixed';
      final lut = buildGroupIpFiles(
        g2,
        IspNodeGroup('g2', {id2}, name: 'csc_rgb2hsl'),
        const IpGenOptions(
            vendor: IpVendor.generic, pixBits: 8, useBram: false),
      )['ISP_IP_RGB_to_HSL_core.v']!;
      expect(lut, contains('parameter integer USE_BRAM = 0'));
    });

    test('Q14 归一化用 Mersenne 折叠除法（与整数除法逐位一致，模型级穷举）', () {
      // 生成物里不应再有 `/ MAXV` 常量除法；改用 f_div_maxv 折叠。
      for (final typeId in ['csc_rgb2hsl', 'csc_hsl2rgb', 'csc_hsl2yuv']) {
        final g = IspGraph();
        final id = g.addNode(typeId, 0, 0);
        g.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
        final core = buildGroupIpFiles(
          g,
          IspNodeGroup('g1', {id}, name: 'ip'),
          const IpGenOptions(vendor: IpVendor.generic),
        ).entries.firstWhere((e) => e.key.endsWith('_core.v')).value;
        // 除法运算符不应残留（注释里也不写 ` / MAXV` 形式，便于这条断言）。
        expect(core, isNot(contains('/ MAXV')), reason: typeId);
        expect(core, contains('f_div_maxv'), reason: typeId);
      }

      // 模型级证明：与 `(v*16384 + MAXV/2) / MAXV` 逐位一致（可达域全扫 +
      // 随机全域），PIX_BITS = 8/10/12/16 各一档。
      int fold(int x, int pb) {
        final maxv = (1 << pb) - 1;
        final dvW = pb + 15;
        final dvN = (dvW + pb - 1) ~/ pb;
        var sum = 0;
        for (var i = 0; i < dvN; i++) {
          sum += (x >> (pb * i)) & maxv;
        }
        var acc = 0;
        for (var i = 1; i < dvN; i++) {
          final d = (x >> (pb * i)) & maxv;
          for (var j = 0; j < i; j++) {
            acc += d << (pb * j);
          }
        }
        for (var i = 1; i < dvN; i++) {
          if (sum >= maxv * i) acc += 1;
        }
        return acc;
      }

      for (final pb in [8, 10, 12, 16]) {
        final maxv = (1 << pb) - 1;
        for (var v = 0; v <= maxv; v++) {
          final x = (v << 14) + (maxv >> 1);
          expect(fold(x, pb), x ~/ maxv, reason: 'pb=$pb v=$v');
        }
        // 全域随机（含边界）
        var seed = 7;
        for (var i = 0; i < 20000; i++) {
          seed = (seed * 1664525 + 1013904223) & 0x7fffffff;
          final x = seed & ((1 << (pb + 15)) - 1);
          expect(fold(x, pb), x ~/ maxv, reason: 'pb=$pb x=$x');
        }
      }
    });

    test('RGB2HSL：面积档绑 LUT，平衡/性能档走全流水 DSP 通路', () {
      final graph = IspGraph();
      final id = graph.addNode('csc_rgb2hsl', 0, 0);
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_rgb2hsl');
      final area = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.generic, gstrategy: 0),
      )['ISP_IP_RGB_to_HSL_core.v']!;
      // 面积档：组合函数 + 模块级 use_dsp="no"（零 DSP）。
      expect(area, contains('(* use_dsp = "no" *)\nmodule'));
      expect(area, isNot(contains('f_hsl_seed')));
      for (final g in [1, 2]) {
        final core = buildGroupIpFiles(
          graph,
          group,
          IpGenOptions(vendor: IpVendor.generic, gstrategy: g),
        )['ISP_IP_RGB_to_HSL_core.v']!;
        // 全流水通路：模块级不绑 LUT，每级乘法前后各有一级寄存。
        expect(core, isNot(contains('(* use_dsp = "no" *)\nmodule')));
        expect(core, contains('f_hsl_seed'));
        final plan = planGroupIp(
          graph,
          group,
          IpGenOptions(vendor: IpVendor.generic, gstrategy: g),
        );
        expect(plan.resources.latencyCycles, kHslPipeLatency);
      }
      final areaPlan = planGroupIp(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.generic, gstrategy: 0),
      );
      expect(areaPlan.resources.latencyCycles, 3);
      expect(areaPlan.resources.estDsps, 0);
    });

    test('YUV2RGB 矩阵标准 BT.601/709/2020：系数、IP 参数与 golden 一致', () async {
      final stdParam = IspNodeRegistry.byId(
        'csc_yuv2rgb',
      )!.params.firstWhere((p) => p.key == 'standard');
      expect(stdParam.defaultValue, 'bt2020');
      if (detectIverilog() == null) return;
      final hashes = <String>{};
      for (final (standard, code) in [
        ('bt601', 0),
        ('bt709', 1),
        ('bt2020', 2),
      ]) {
        final graph = IspGraph();
        final id = graph.addNode('csc_yuv2rgb', 0, 0);
        graph.nodes[id]!.name = 'n1';
        graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
        graph.nodes[id]!.paramValues['standard'] = 'bt601';
        final group = IspNodeGroup('g1', {id}, name: 'csc_yuv2rgb');
        final files = buildGroupIpFiles(
          graph,
          group,
          IpGenOptions(vendor: IpVendor.generic, yuvStandard: standard),
          stimulus: const IpSimStimulus(width: 8, height: 2, frames: 1),
        );
        final core = files['ISP_IP_YUV_to_RGB_core.v']!;
        expect(core, contains('parameter integer YUV_STANDARD = $code'));
        final r = await runIpSimulation(files);
        expect(r.success, isTrue, reason: '$standard: ${r.output}');
        expect(r.passed, isTrue, reason: '$standard: ${r.output}');
        final hash = RegExp(r'fnv=([0-9a-f]+)').firstMatch(r.output)?.group(1);
        expect(hash, isNotNull);
        hashes.add(hash!);
      }
      expect(hashes, hasLength(3));
      final graph = IspGraph();
      final id = graph.addNode('csc_yuv2rgb', 0, 0);
      graph.nodes[id]!.name = 'n1';
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_yuv2rgb');
      final vivadoFiles = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(
          vendor: IpVendor.vivado,
          yuvStandard: 'bt709',
          projectName: 'yuv_std_demo',
        ),
        stimulus: const IpSimStimulus(width: 8, height: 2, frames: 1),
      );
      expect(
        vivadoFiles['package_ip.tcl'],
        contains('value 1 [ipx::get_user_parameters YUV_STANDARD]'),
      );
      expect(
        vivadoFiles['xgui/ISP_IP_YUV_to_RGB_v2_0.tcl'],
        contains(r'ipgui::add_param $IPINST -name "YUV_STANDARD"'),
      );
      expect(
        vivadoFiles['demo/create_demo_project.tcl'],
        contains(
          'set_property CONFIG.YUV_STANDARD {1} [get_ips ISP_IP_YUV_to_RGB]',
        ),
      );
      final guide = vivadoFiles['ISP_IP_YUV_to_RGB_V2.0_UserGuide.md'];
      expect(guide, isNotNull);
      expect(guide, startsWith('# ISP_IP_YUV_to_RGB V2.0 User Guide'));
      expect(guide, contains('YUV_STANDARD'));
      expect(guide, contains('BT.2020'));
      expect(guide, isNot(contains('NUM_BANDS')));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('YUV2HSL：性能档全流水 DSP 通路（28 拍，BT.601 矩阵 + RGB→HSL）', () {
      final graph = IspGraph();
      final id = graph.addNode('csc_yuv2hsl', 0, 0);
      graph.nodes[id]!.name = 'n1';
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_yuv2hsl');
      final perf = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      )['ISP_IP_YUV_to_HSL_core.v']!;
      // 矩阵 4 个 DSP + RGB→HSL 的 11 个，复用 RGB→HSL 三段子模块。
      for (final m in ['_hsl_m #(', '_hsl_q (', '_hsl_corr (', '_hsl_mul #(']) {
        expect(perf, contains(m));
      }
      expect(perf, contains('parameter integer YUV_STANDARD = 2'));
      expect(perf, contains("18'sd91881")); // crV（BT.601）
      expect(perf, contains("18'sd103206")); // crV（BT.709）
      expect(perf, contains('SIGNED_A(1)'));
      expect(
        planGroupIp(
          graph,
          group,
          const IpGenOptions(vendor: IpVendor.vivado),
        ).resources.latencyCycles,
        kYuv2HslPipeLatency,
      );
      // 面积档：组合函数（三段式 normalize/pre/post）+ 绑 LUT。
      final area = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado, gstrategy: 0),
      )['ISP_IP_YUV_to_HSL_core.v']!;
      expect(area, contains('(* use_dsp = "no" *)'));
      expect(area, isNot(contains('_mk_prr')));
      expect(area, contains('f_rgb2hsl_post_q14'));
      expect(
        planGroupIp(
          graph,
          group,
          const IpGenOptions(vendor: IpVendor.vivado, gstrategy: 0),
        ).resources.latencyCycles,
        3,
      );
      // 节点带「YUV 标准」选项（默认 BT.2020），IP 与 demo tcl 均透传。
      expect(
        buildGroupIpFiles(
          graph,
          group,
          const IpGenOptions(vendor: IpVendor.vivado),
        )['demo/create_demo_project.tcl']!,
        contains('set_property CONFIG.YUV_STANDARD {2}'),
      );
      expect(groupHasYuvMatrix(graph, group), isTrue);
    });

    test('IP core 文件头在最前，且只发射本 IP 用到的子模块', () {
      Map<String, String> filesFor(String type) {
        final graph = IspGraph();
        final id = graph.addNode(type, 0, 0);
        graph.nodes[id]!.name = 'n1';
        graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
        return buildGroupIpFiles(
          graph,
          IspNodeGroup('g1', {id}, name: type),
          const IpGenOptions(vendor: IpVendor.vivado),
        );
      }

      final h2y = filesFor('csc_hsl2yuv')['ISP_IP_HSL_to_YUV_core.v']!;
      // 文件头（生成信息 + timescale）在第一行，且早于任何 module。
      expect(h2y, startsWith('// Generated by DebugToolSet ISP Studio'));
      expect(h2y.indexOf('`timescale'), lessThan(h2y.indexOf('module ')));
      // HSL→YUV 只用到 _hsl2rgb_* 与 _hsl_mul：不得塞入 RGB→HSL 专用模块。
      expect(h2y, contains('module ISP_IP_HSL_to_YUV_hsl2rgb_n #('));
      expect(h2y, isNot(contains('module ISP_IP_HSL_to_YUV_hsl_m #(')));
      expect(h2y, isNot(contains('module ISP_IP_HSL_to_YUV_hsl_q (')));
      expect(h2y, isNot(contains('module ISP_IP_HSL_to_YUV_hsl_corr (')));

      final h2r = filesFor('csc_hsl2rgb')['ISP_IP_HSL_to_RGB_core.v']!;
      expect(h2r, startsWith('// Generated by DebugToolSet ISP Studio'));
      expect(h2r, contains('module ISP_IP_HSL_to_RGB_hsl2rgb_c ('));
      expect(h2r, isNot(contains('module ISP_IP_HSL_to_RGB_hsl_m #(')));

      final r2h = filesFor('csc_rgb2hsl')['ISP_IP_RGB_to_HSL_core.v']!;
      expect(r2h, startsWith('// Generated by DebugToolSet ISP Studio'));
      expect(r2h, contains('module ISP_IP_RGB_to_HSL_hsl_corr ('));
      expect(r2h, isNot(contains('module ISP_IP_RGB_to_HSL_hsl2rgb_n #(')));
    });

    test('HSL2YUV：性能档全流水 DSP 通路（18 拍，HSL→RGB + BT.601 矩阵）', () {
      final graph = IspGraph();
      final id = graph.addNode('csc_hsl2yuv', 0, 0);
      graph.nodes[id]!.name = 'n1';
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_hsl2yuv');
      final perf = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      )['ISP_IP_HSL_to_YUV_core.v']!;
      // HSL→RGB 三段子模块复用 + 矩阵乘法模块。
      for (final m in [
        '_hsl2rgb_n',
        '_hsl2rgb_q',
        '_hsl2rgb_c',
        '_hsl_mul',
        '_mx_py0',
        '_mx_pu2',
        '_mx_pv1',
      ]) {
        expect(perf, contains(m));
      }
      // BT.601 系数以有符号常量烘焙进 DSP 的 B 端口。
      // YUV 标准可选：系数按 YUV_STANDARD 三选一（参数常量，DSP B 端口直接用）。
      expect(perf, contains('parameter integer YUV_STANDARD = 2'));
      expect(perf, contains("18'sd19595"));
      expect(perf, contains("18'sd13933"));
      expect(perf, contains("18'sd17216"));
      expect(perf, contains("-18'sd11058"));
      expect(perf, contains('SIGNED_B(1)'));
      expect(
        planGroupIp(
          graph,
          group,
          const IpGenOptions(vendor: IpVendor.vivado),
        ).resources.latencyCycles,
        kHsl2YuvPipeLatency,
      );
      // 面积档：组合函数 + 绑 LUT，单级实现（1 拍）。
      final area = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado, gstrategy: 0),
      )['ISP_IP_HSL_to_YUV_core.v']!;
      expect(area, contains('(* use_dsp = "no" *)'));
      expect(area, isNot(contains('_mx_py0')));
      expect(
        planGroupIp(
          graph,
          group,
          const IpGenOptions(vendor: IpVendor.vivado, gstrategy: 0),
        ).resources.latencyCycles,
        1,
      );
      // HSL→YUV 涉及 YUV 矩阵，编辑组内成员有「YUV 标准」选项。
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      expect(files['ISP_IP_HSL_to_YUV_core.v'], contains('YUV_STANDARD'));
      expect(groupHasYuvMatrix(graph, group), isTrue);
    });

    test('HSL2RGB：性能档全流水 DSP 通路（14 拍）+ 层级子模块', () {
      final graph = IspGraph();
      final id = graph.addNode('csc_hsl2rgb', 0, 0);
      graph.nodes[id]!.name = 'n1';
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_hsl2rgb');
      final perf = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      )['ISP_IP_HSL_to_RGB_core.v']!;
      // 三段组合逻辑拆成保留层级的子模块 + DSP 乘法模块。
      for (final m in ['_hsl2rgb_n', '_hsl2rgb_q', '_hsl2rgb_c', '_hsl_mul']) {
        expect(perf, contains(m));
      }
      expect(perf, contains('(* keep_hierarchy = "yes" *)'));
      expect(perf, contains('.en_a(stage_ready['));
      final perfPlan = planGroupIp(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      expect(perfPlan.resources.latencyCycles, kHsl2RgbPipeLatency);
      // 面积档仍为组合函数 + 模块级绑 LUT。
      final area = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado, gstrategy: 0),
      )['ISP_IP_HSL_to_RGB_core.v']!;
      expect(area, contains('(* use_dsp = "no" *)\nmodule'));
      expect(area, isNot(contains('_hsl2rgb_n')));
      // 非流水 HSL→RGB 是单级实现（1 拍）。
      expect(
        planGroupIp(
          graph,
          group,
          const IpGenOptions(vendor: IpVendor.vivado, gstrategy: 0),
        ).resources.latencyCycles,
        1,
      );
      // demo 的 pre-opt_design Tcl 把无板卡的未约束 I/O 两条 DRC 声明为
      // Advisory（XDC 不支持 if，故放在 clock_route.tcl 里）。
      final hook = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      )['demo/clock_route.tcl']!;
      expect(hook, contains('foreach drc {NSTD-1 UCIO-1}'));
      expect(hook, contains('set_property SEVERITY {Advisory} '));
    });

    test('RGB2HSL 导出包附带 V2.0 用户指南，且不含 YUV 相关项', () {
      final graph = IspGraph();
      final id = graph.addNode('csc_rgb2hsl', 0, 0);
      graph.nodes[id]!.name = 'n1';
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_rgb2hsl');
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      final guide = files['ISP_IP_RGB_to_HSL_V2.0_UserGuide.md'];
      expect(guide, isNotNull);
      expect(guide, startsWith('# ISP_IP_RGB_to_HSL V2.0 User Guide'));
      // 端口/位域/公式/延迟/资源等关键小节齐备。
      expect(guide, contains('m_axis_tdata[3×PB-1 : 2×PB]'));
      expect(guide, contains('_hsl_mul'));
      expect(guide, contains('23 拍'));
      expect(guide, contains('DSP48E2'));
      expect(guide, contains('1589'));
      // HSL 节点不涉及 YUV 矩阵：指南里显式说明「没有该配置项」，
      // 而 IP 实体（core / xgui / demo tcl）里确实不含该参数。
      expect(guide, contains('不涉及 YUV 矩阵'));
      expect(guide, contains('没有 `YUV_STANDARD`'));
      expect(guide, isNot(contains('NUM_BANDS')));
      expect(
        files['ISP_IP_RGB_to_HSL_core.v'],
        isNot(contains('YUV_STANDARD')),
      );
      expect(
        files['xgui/ISP_IP_RGB_to_HSL_v2_0.tcl'],
        isNot(contains('YUV_STANDARD')),
      );
      expect(
        files['demo/create_demo_project.tcl'],
        isNot(contains('CONFIG.YUV_STANDARD')),
      );
      expect(files['README.md']!, isNot(contains('YUV2RGB 矩阵标准')));
    });

    test('RGB2YUV 默认 BT.2020：节点选项、系数与 golden 一致', () async {
      final param = IspNodeRegistry.byId(
        'csc_rgb2yuv',
      )!.params.firstWhere((p) => p.key == 'standard');
      expect(param.defaultValue, 'bt2020');
      expect(param.options, ['bt601', 'bt709', 'bt2020']);
      if (detectIverilog() == null) return;
      final graph = IspGraph();
      final id = graph.addNode('csc_rgb2yuv', 0, 0);
      graph.nodes[id]!.name = 'n1';
      graph.nodes[id]!.paramValues['codegenMode'] = 'func_fixed';
      final group = IspNodeGroup('g1', {id}, name: 'csc_rgb2yuv');
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: const IpSimStimulus(width: 8, height: 2, frames: 1),
      );
      final core = files['ISP_IP_RGB_to_YUV_core.v']!;
      expect(core, contains('parameter integer YUV_STANDARD = 2'));
      expect(core, contains('17216'));
      expect(core, contains('44433'));
      expect(core, contains('3886'));
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);

      final vivadoFiles = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado, yuvStandard: 'bt709'),
        stimulus: const IpSimStimulus(width: 8, height: 2, frames: 1),
      );
      expect(
        vivadoFiles['ISP_IP_RGB_to_YUV_core.v'],
        contains('parameter integer YUV_STANDARD = 1'),
      );
      expect(
        vivadoFiles['package_ip.tcl'],
        contains('value 1 [ipx::get_user_parameters YUV_STANDARD]'),
      );
      expect(
        vivadoFiles['xgui/ISP_IP_RGB_to_YUV_v2_0.tcl'],
        contains(r'ipgui::add_param $IPINST -name "YUV_STANDARD"'),
      );
      expect(
        vivadoFiles['demo/create_demo_project.tcl'],
        contains(
          'set_property CONFIG.YUV_STANDARD {1} [get_ips ISP_IP_RGB_to_YUV]',
        ),
      );
      final guide = vivadoFiles['ISP_IP_RGB_to_YUV_V2.0_UserGuide.md'];
      expect(guide, isNotNull);
      expect(guide, startsWith('# ISP_IP_RGB_to_YUV V2.0 User Guide'));
      expect(guide, contains('YUV_STANDARD'));
      expect(guide, contains('BT.2020'));
      expect(guide, contains('limited'));
      expect(guide, isNot(contains('NUM_BANDS')));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('8bit 倒数表与余数校正：舍入边界和原除法逐位一致', () {
      int reference(int num, int den) =>
          num >= 0 ? (num + (den >> 1)) ~/ den : -((-num + (den >> 1)) ~/ den);
      int reciprocal(int num, int den) {
        final k = 13 - (den.bitLength - 1);
        final dn = k >= 0 ? den << k : den >> -k;
        final y0 = (1 << 44) ~/ ((dn >> 6) << 6);
        final y1 = (y0 * ((1 << 31) - ((dn * y0) >> 14))) >> 30;
        final recip = y1 >> (14 - k);
        final mag = num.abs();
        var q = (mag * recip) >> 30;
        var r = mag - q * den;
        if (r < 0) {
          q--;
          r += den;
        }
        if (r >= den) {
          q++;
          r -= den;
        }
        if ((r << 1) >= den) q++;
        return num < 0 ? -q : q;
      }

      for (var den = 1; den <= 16384; den++) {
        final numerators = <int>{0, 1, den - 1, den, den + 1};
        for (final q in [
          0,
          1,
          2,
          3,
          5,
          6,
          7,
          15,
          31,
          63,
          127,
          255,
          1023,
          4096,
          8192,
          16384,
        ]) {
          for (var r = 0; r < den; r++) {
            if (r > 1 && r != den - 1 && (r - den / 2).abs() > 1) continue;
            numerators.add(q * den + r);
          }
        }
        for (final num in numerators) {
          for (final signed in [num, -num]) {
            expect(
              reciprocal(signed, den),
              reference(signed, den),
              reason: 'num=$signed den=$den',
            );
          }
        }
      }
    });

    test('CSC 16bit 定点：32 位缩窄数据通路双模式逐位一致', () async {
      if (detectIverilog() == null) return;
      for (final type in ['csc_yuv2hsl', 'csc_hsl2yuv']) {
        for (final mode in ['lut_fixed', 'func_fixed']) {
          final graph = IspGraph();
          final id = graph.addNode(type, 0, 0);
          graph.nodes[id]!.paramValues['codegenMode'] = mode;
          final group = IspNodeGroup('g1', {id}, name: type);
          final files = buildGroupIpFiles(
            graph,
            group,
            const IpGenOptions(vendor: IpVendor.generic, pixBits: 16),
            stimulus: const IpSimStimulus(width: 8, height: 2, frames: 2),
          );
          final core =
              files['ISP_IP_${IspNodeRegistry.byId(type)!.englishName}_core.v']!;
          expect(core, contains('function signed [31:0] f_div_round'));
          expect(core, isNot(contains('function signed [63:0] f_div_round')));
          final result = await runIpSimulation(files);
          expect(
            result.success,
            isTrue,
            reason: '$type/$mode: ${result.output}',
          );
          expect(
            result.passed,
            isTrue,
            reason: '$type/$mode: ${result.output}',
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('YUV 通道均衡器三节点链生成并实仿', () async {
      if (detectIverilog() == null) return;
      final json =
          jsonDecode(
                File(
                  'IspFlow/IP_Gen_flow/YUV_MBC_EQ.ispflow',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final graph = IspGraph.fromJson(json);
      final group = graph.groups.single;
      expect(validateGroupIpExport(graph, group), isNull);
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      for (final path in [
        'yuv_hsl_1/ISP_IP_YUV_to_HSL_core.v',
        'n1/ISP_IP_MBC_EQ_core.v',
        'hsl_yuv_1/ISP_IP_HSL_to_YUV_core.v',
      ]) {
        expect(files[path], isNotNull, reason: path);
      }
      expect(files['isp_ip_yuv_core.v'], isNull, reason: '不得再生成合并核心');
      // 互连顶层跟随流程英文名（YUV_MBC_EQ）。
      expect(files['isp_ip_yuv_mbc_eq_core.v'], isNull);
      final interconnect = files['isp_ip_yuv_mbc_eq_top.v']!;
      expect(interconnect, contains('independent IP instance'));
      expect(interconnect, contains('u_yuv_hsl_1'));
      expect(interconnect, contains('u_n1'));
      expect(interconnect, contains('u_hsl_yuv_1'));
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('YUV 三节点 CSC 流水在输入气泡和输出背压下保持逐位一致', () async {
      if (detectIverilog() == null) return;
      final json =
          jsonDecode(
                File(
                  'IspFlow/IP_Gen_flow/YUV_MBC_EQ.ispflow',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final graph = IspGraph.fromJson(json);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: const IpSimStimulus(inGapPct: 25, outStallPct: 25),
      );
      final result = await runIpSimulation(files);
      expect(result.success, isTrue, reason: result.output);
      expect(result.passed, isTrue, reason: result.output);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('三节点 demo_prj 使用三个独立 IP 并在顶层互连', () {
      final json =
          jsonDecode(
                File(
                  'IspFlow/IP_Gen_flow/YUV_MBC_EQ.ispflow',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final graph = IspGraph.fromJson(json);
      final group = graph.groups.single;
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      final top = files['demo/demo_top.v']!;
      const instances = [
        'ISP_IP_YUV_to_HSL',
        'ISP_IP_MBC_EQ',
        'ISP_IP_HSL_to_YUV',
      ];
      for (final instance in instances) {
        expect(top, contains('$instance u_'));
      }
      expect(top, contains('.par_b1_l1(n1_par_b1_l1)'));
      expect(
        top,
        isNot(contains('par_b2_')),
        reason: 'Vivado 在 NUM_BANDS=2 时隐藏第 2～15 段参数端口',
      );
      final script = files['demo/create_demo_project.tcl']!;
      expect(script, contains('config_ip_cache -disable'));
      expect(
        script,
        contains('set_msg_config -id {Synth 8-5409} -new_severity INFO'),
      );
      for (final instance in instances) {
        expect(script, contains('-module_name $instance'));
      }
      // 实现策略与单 IP demo 一致：默认流程在单 SLR 器件上会请求
      // place_design -ultrathreads 报 [Vivado_Tcl 4-1400]。
      expect(script, contains('set_property strategy Performance_Explore'));
      expect(
        script,
        isNot(
          contains('set_property strategy {Vivado Implementation Defaults}'),
        ),
      );
      expect(RegExp('create_ip ').allMatches(script), hasLength(3));
      for (final path in [
        'yuv_hsl_1/package_ip.tcl',
        'n1/package_ip.tcl',
        'hsl_yuv_1/package_ip.tcl',
      ]) {
        expect(files[path], isNotNull, reason: path);
      }
      expect(script, contains('yuv_hsl_1/ip_repo'));
      expect(script, contains('n1/ip_repo'));
      expect(script, contains('hsl_yuv_1/ip_repo'));
    });

    test('多节点同类 IP 的 Component Name 自动添加唯一序号', () {
      final graph = IspGraph();
      final a = graph.addNode('color_temp_adjuster', 0, 0);
      final b = graph.addNode('color_temp_adjuster', 0, 0);
      expect(graph.connect(a, 'out_rgb', b, 'in'), isNull);
      final group = IspNodeGroup('g1', {a, b}, name: 'duplicate_cct');
      final files = buildGroupIpFiles(
        graph,
        group,
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      final script = files['demo/create_demo_project.tcl']!;
      expect(script, contains('-module_name ISP_IP_Color_Temperature\n'));
      expect(script, contains('-module_name ISP_IP_Color_Temperature_2\n'));
      final top = files['demo/demo_top.v']!;
      expect(top, contains('ISP_IP_Color_Temperature u_'));
      expect(top, contains('ISP_IP_Color_Temperature_2 u_'));
    });

    test('iverilog 实仿（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return; // 无 iverilog 跳过
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
      expect(r.output, contains('PASS'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('Vivado 包一键仿真排除 demo 源（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return;
      final graph = loadSample();
      final files = buildGroupIpFiles(
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
      expect(r.output, isNot(contains('demo/tb_demo.v')));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('激励图案：24 位色彩模式（HSL/RGB/YUV × 字节序）', () {
      // HSL 高字节H：像素 (0,0) = 色相 0、S 满、L 中值；(w-1,0) 色相满。
      final hsl = IpStimulusGen(
        const IpSimStimulus(width: 3, height: 2, pattern: IpSimPattern.hsl24Hi),
        255,
      );
      expect(hsl.next(0, 0), (0, 255, 127));
      expect(hsl.next(2, 0), (255, 255, 127));
      // RGB 高字节B（Lo）：第一/第三通道互换——R 水平渐变落到低字节字段。
      final rgbLo = IpStimulusGen(
        const IpSimStimulus(width: 3, height: 2, pattern: IpSimPattern.rgb24Lo),
        255,
      );
      expect(rgbLo.next(0, 0), (127, 0, 0)); // R=0,G=0,B=127 → Lo 打包
      expect(rgbLo.next(2, 1), (127, 255, 255)); // R=255,G=255 → (B,G,R)
      // YUV 高字节Y：Y 水平渐变、U 垂直渐变、V 中值。
      final yuv = IpStimulusGen(
        const IpSimStimulus(width: 3, height: 2, pattern: IpSimPattern.yuv24Hi),
        255,
      );
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
        graph,
        sampleGroup(graph),
        const IpGenOptions(vendor: IpVendor.generic),
        stimulus: stim,
      );
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
      expect(r.output, contains('PASS'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('无 iverilog 时 runIpSimulation 返回失败并提示', () async {
      final r = await runIpSimulation(
        const {},
        iverilog: const IverilogToolchain(
          r'X:\not-exist\iverilog.exe',
          r'X:\not-exist\vvp.exe',
        ),
      );
      // 编译启动失败（exitCode -1）。
      expect(r.success, isFalse);
    });
  });

  group('func_fixed IP（段运算单元，无 ROM 表）', () {
    /// 构造 func_fixed 均衡器编组（[bands] 段，[serial] 工作方式）。
    IspGraph fxGraph(
      List<({double h, double q, double dh, double s, double l})> bands, {
      bool serial = false,
      String groupName = 'mbfx',
    }) {
      final graph = IspGraph();
      final mb = graph.addNode('multi_band_eq', 0, 0);
      graph.nodes[mb]!.name = 'mb';
      graph.nodes[mb]!.paramValues['codegenMode'] = 'func_fixed';
      graph.nodes[mb]!.paramValues['band_count'] = bands.length;
      graph.nodes[mb]!.paramValues['band_mode'] = serial
          ? 'serial'
          : 'parallel';
      for (var i = 0; i < bands.length; i++) {
        graph.nodes[mb]!.paramValues['b${i}_h'] = bands[i].h;
        graph.nodes[mb]!.paramValues['b${i}_q'] = bands[i].q;
        graph.nodes[mb]!.paramValues['b${i}_dh'] = bands[i].dh;
        graph.nodes[mb]!.paramValues['b${i}_s'] = bands[i].s;
        graph.nodes[mb]!.paramValues['b${i}_l'] = bands[i].l;
      }
      graph.groups.add(IspNodeGroup('g1', {mb}, name: groupName));
      return graph;
    }

    const twoBands = [
      (h: 120.0, q: 2.0, dh: 30.0, s: 1.5, l: 0.8),
      (h: 200.0, q: 4.0, dh: -20.0, s: 0.7, l: 1.2),
    ];
    const threeBands = [
      (h: 30.0, q: 0.5, dh: 45.0, s: 1.3, l: 1.1),
      (h: 150.0, q: 0.6, dh: -70.0, s: 0.8, l: 1.0),
      (h: 270.0, q: 0.7, dh: 25.0, s: 1.1, l: 0.9),
    ];

    test('生成的 Verilog 与 Tcl 全部英文 ASCII 且写盘一致', () async {
      final dir = await Directory.systemTemp.createTemp('ip_text_encoding_');
      Future<void> expectEncoding(Map<String, String> files) async {
        await exportGroupIpPackage(files, dir.path);
        for (final entry in files.entries) {
          if (!entry.key.endsWith('.v') && !entry.key.endsWith('.tcl')) {
            continue;
          }
          expect(
            entry.value.codeUnits.every((c) => c <= 127),
            isTrue,
            reason: '${entry.key} contains non-ASCII text',
          );
          final bytes = await File(
            '${dir.path}${Platform.pathSeparator}${entry.key}',
          ).readAsBytes();
          expect(
            generatedTextEncoding.decode(bytes),
            entry.value,
            reason: '${entry.key} 写盘编码不一致',
          );
        }
      }

      try {
        final lutGraph = loadSample();
        for (final node in lutGraph.nodes.values) {
          if (node.typeId == 'multi_band_eq') {
            node.paramValues['codegenMode'] = 'lut_fixed';
          }
        }
        final vivadoFiles = buildGroupIpFiles(
          lutGraph,
          sampleGroup(lutGraph),
          const IpGenOptions(vendor: IpVendor.vivado),
          stimulus: const IpSimStimulus(
            clkMHz: 50,
            pattern: IpSimPattern.hGradient,
          ),
        );
        expect(vivadoFiles['demo/tb_demo.v'], contains('CLK frequency'));
        await expectEncoding(vivadoFiles);
        final parallelGraph = fxGraph(twoBands);
        await expectEncoding(
          buildGroupIpFiles(
            parallelGraph,
            parallelGraph.groups.single,
            const IpGenOptions(vendor: IpVendor.generic),
          ),
        );
        final serialGraph = fxGraph(threeBands, serial: true);
        await expectEncoding(
          buildGroupIpFiles(
            serialGraph,
            serialGraph.groups.single,
            const IpGenOptions(vendor: IpVendor.libero),
          ),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('2020.2 使用系统编码，2024.2 及新版使用 UTF-8', () async {
      final dir = await Directory.systemTemp.createTemp(
        'vivado_version_encoding_',
      );
      const files = {'tb_demo.v': '// 中文注释\n'};
      try {
        for (final entry in {
          r'C:\Xilinx\Vivado\2020.2\bin\vivado.bat': generatedTextEncoding,
          r'C:\Xilinx\Vivado\2024.2\bin\vivado.bat': utf8,
          r'D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat': utf8,
        }.entries) {
          await exportGroupIpPackage(
            files,
            dir.path,
            vivadoExecutable: entry.key,
          );
          final bytes = await File(
            '${dir.path}${Platform.pathSeparator}tb_demo.v',
          ).readAsBytes();
          expect(entry.value.decode(bytes), files['tb_demo.v']);
          if (Platform.isWindows && entry.key.contains('2020.2')) {
            expect(bytes, isNot(equals(utf8.encode(files['tb_demo.v']!))));
          } else {
            expect(bytes, equals(utf8.encode(files['tb_demo.v']!)));
          }
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('Markdown 文档固定 UTF-8，源码仍跟随 Vivado 版本编码', () async {
      final dir = await Directory.systemTemp.createTemp('markdown_encoding_');
      const files = {
        'README.md': '# 中文说明\n',
        'ISP_IP_YUV_to_RGB_V2.0_UserGuide.md': '# 用户指南\n',
        'tb_demo.v': '// 中文注释\n',
      };
      try {
        await exportGroupIpPackage(
          files,
          dir.path,
          vivadoExecutable: r'C:\Xilinx\Vivado\2020.2\bin\vivado.bat',
        );
        for (final name in [
          'README.md',
          'ISP_IP_YUV_to_RGB_V2.0_UserGuide.md',
        ]) {
          final bytes = await File(
            '${dir.path}${Platform.pathSeparator}$name',
          ).readAsBytes();
          expect(bytes, equals(utf8.encode(files[name]!)), reason: name);
        }
        final tbBytes = await File(
          '${dir.path}${Platform.pathSeparator}tb_demo.v',
        ).readAsBytes();
        expect(generatedTextEncoding.decode(tbBytes), files['tb_demo.v']);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('校验放行 func_fixed（func/lut 仍拒绝）', () {
      final g = fxGraph(twoBands);
      expect(validateGroupIpExport(g, g.groups.single), isNull);
      final gSer = fxGraph(threeBands, serial: true);
      expect(validateGroupIpExport(gSer, gSer.groups.single), isNull);
    });

    test('恒等式：Mersenne 折叠与倒数乘全量/密集验证（逐位等价整数除法）', () {
      // h_q16 = (hv*360*2^16 + mv/2)/mv：折叠（4 次 + 末位修正）全量对拍。
      int foldDiv(int t, int k, int m) {
        var acc = 0, q = t;
        for (var i = 0; i < 4; i++) {
          acc += q >> k;
          q = (q >> k) + (q & m);
        }
        if (q >= m) acc += 1;
        return acc;
      }

      const circle = 360 << 16;
      for (var pb = 8; pb <= 16; pb++) {
        final mv = (1 << pb) - 1;
        for (var hv = 0; hv <= mv; hv++) {
          final t = hv * circle + (mv >> 1);
          expect(foldDiv(t, pb, mv), t ~/ mv, reason: 'pb=$pb hv=$hv');
        }
      }
      // shift = roundDiv(v, 360<<s)：mag -> A=(mag+180<<s)>>s -> (A*R)>>33。
      // 密集抽样 + 边界（恒等式另经 scratch/verify_fx_verilog_identities.dart
      // 全量/超密集验证；此处控制用例耗时）。
      const r33 = 23860930; // ceil(2^33/360)
      int roundDiv(int v, int d) => (v >= 0 ? v + (d >> 1) : v - (d >> 1)) ~/ d;
      for (final mv in [255, 1023, 4095, 65535]) {
        for (final s in [16, 30]) {
          final cap = 180 << s;
          final samples = <int>{
            0,
            1,
            cap ~/ 2,
            cap - 1,
            cap,
            1 << s,
            359,
            360,
            361,
          };
          for (var i = 0; i < 20000; i++) {
            samples.add((i * 104729) % (cap + 1));
          }
          for (final dd in samples) {
            for (final sgn in [1, -1]) {
              final v = sgn * dd * mv;
              final a = (v.abs() + (180 << s)) >> s;
              final q = (a * r33) >> 33;
              expect(
                v < 0 ? -q : q,
                roundDiv(v, 360 << s),
                reason: 'mv=$mv s=$s v=$v',
              );
            }
          }
        }
      }
    });

    test('并联两段：每段一个并行单元、无 ROM、默认 LAT=89、golden 逐位', () {
      final graph = fxGraph(twoBands);
      final plan = planGroupIp(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      expect(plan.fxBandCount, 2);
      expect(plan.fxSerial, isFalse);
      expect(plan.resources.romBits, 0);
      expect(plan.resources.latencyCycles, 89);
      expect(plan.resources.estDsps, 11 * 2 + 3); // 性能档默认
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final core = files['ISP_IP_MBC_EQ_core.v']!;
      expect(core, contains('module ISP_IP_MBC_EQ_band_par'));
      expect(core, contains('u_b0_pre'));
      expect(core, contains('u_b0_mid'));
      expect(core, contains('u_b0_post'));
      expect(core, contains('u_b1_post'));
      expect(core, contains('u_b2_post'));
      expect(core, contains('u_b15_post'));
      expect(core, contains('parameter integer NUM_BANDS = 2'));
      expect(core, contains('input  wire [NUM_BANDS-1:0] CH_Enable'));
      expect(core, contains('_shift_lut'));
      expect(core, contains('_s_mul_q14'));
      // DSP_PIPE 选通参数与 GSTRATEGY use_dsp 落地。
      expect(core, contains('parameter integer DSP_PIPE  = 3'));
      expect(core, contains('(* use_dsp = "no" *)'));
      expect(core, contains('(* use_dsp = "yes" *)'));
      // 段参数为运行期输入端口（不烘焙 parameter）：core/top 均有声明。
      expect(core, contains('input  wire [31:0] par_b0_hc'));
      expect(core, contains('input  wire signed [31:0] par_b1_l1'));
      expect(
        files['ISP_IP_MBC_EQ_top.v']!,
        contains('input  wire [31:0] par_b0_hc'),
      );
      // tb：ispflow 参数换算为段参数激励 reg 初值（b0: h=120° → Q16）。
      final tb0 = files['tb_ISP_IP_MBC_EQ.v']!;
      expect(tb0, contains("par_b0_hc = 32'd7864320")); // 120 * 2^16
      expect(tb0, contains("par_b0_q = 32'd46603")); // 2/45 * 2^20
      expect(tb0, contains("par_b0_dh = 32'sd1966080")); // 30 * 2^16
      expect(tb0, contains("par_b0_s1 = 32'sd8192")); // (1.5-1) * 2^14
      expect(tb0, contains("par_b0_l1 = -32'sd3277")); // (0.8-1) * 2^14
      expect(tb0, contains('.par_b0_hc(par_b0_hc)'));
      // golden 与 Dart 定点参考（帧级 applyMultiBandEqFx）逐位一致。
      const stim = IpSimStimulus();
      final gen = IpStimulusGen(stim, plan.maxValue);
      final outBytes = <int>[];
      for (var f = 0; f < stim.frames; f++) {
        final hsl = Uint16List(stim.width * stim.height * 3);
        var i = 0;
        for (var y = 0; y < stim.height; y++) {
          for (var x = 0; x < stim.width; x++) {
            final (h, s, l) = gen.next(x, y);
            hsl[i] = h;
            hsl[i + 1] = s;
            hsl[i + 2] = l;
            i += 3;
          }
        }
        final out = applyMultiBandEqFx(
          hsl,
          0,
          hsl.length ~/ 3,
          maxValue: plan.maxValue,
          bands: twoBands,
          serial: false,
        );
        for (final c in out) {
          outBytes.add(c & 0xFF);
          outBytes.add((c >> 8) & 0xFF);
        }
      }
      final expectHash =
          '0x${fnv1a32(outBytes).toRadixString(16).padLeft(8, '0')}';
      expect(files['golden_hash.txt']!.trim(), expectHash);
      // tb 排空按 got==N 轮询，上限按并联/串联较大的 LAT 放宽。
      expect(files['tb_ISP_IP_MBC_EQ.v']!, contains('while (got < N'));
      expect(files['tb_ISP_IP_MBC_EQ.v']!, contains('drain_i < 893 * 40'));
      expect(files['README.md']!, contains('并联/单段：5+DSP_PIPE 拍流水'));
    });

    test('串联结构：固定16段流水（默认 LAT=889）+ golden 逐位', () {
      final graph = fxGraph(threeBands, serial: true);
      final plan = planGroupIp(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      expect(plan.fxBandCount, 3);
      expect(plan.fxSerial, isTrue);
      expect(plan.resources.latencyCycles, 889);
      expect(plan.resources.estDsps, 13 * 3 + 3);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final core = files['ISP_IP_MBC_EQ_core.v']!;
      expect(core, contains('parameter integer WORK_MODE = 1'));
      expect(core, contains('module ISP_IP_MBC_EQ_band_ser'));
      expect(core, contains('u_b0_pre'));
      expect(core, contains('u_b1_mid'));
      expect(core, contains('u_b2_post'));
      expect(files['tb_ISP_IP_MBC_EQ.v']!, contains('drain_i < 893 * 40'));
      expect(files['README.md']!, contains('串联：16×(1+DSP_PIPE)+4 拍流水'));
    });

    test('v2.0 通道数与逐通道 bypass 配置贯通', () {
      final graph = fxGraph(twoBands);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.vivado),
      );
      final core = files['ISP_IP_MBC_EQ_core.v']!;
      final tcl = files['package_ip.tcl']!;
      final xgui = files['xgui/ISP_IP_MBC_EQ_v2_0.tcl']!;
      expect(tcl, contains('set_property version 2.0'));
      expect(
        tcl,
        contains(
          'file copy -force -- "xgui/ISP_IP_MBC_EQ_v2_0.tcl" "\$xguiDir/ISP_IP_MBC_EQ_axis_v1_0.tcl"',
        ),
      );
      expect(
        tcl,
        contains(
          'value_validation_list {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16}',
        ),
      );
      expect(tcl, contains('ipx::get_ports par_b15_l1'));
      expect(tcl, contains('size_left 1 [ipx::get_ports CH_Enable]'));
      expect(
        tcl,
        contains(
          "size_left_dependency {(spirit:decode(id('MODELPARAM_VALUE.NUM_BANDS')) - 1)}",
        ),
      );
      expect(tcl, contains('size_left_resolve_type dependent'));
      expect(tcl, contains('size_right 0 [ipx::get_ports CH_Enable]'));
      expect(tcl, contains('is_vector true [ipx::get_ports CH_Enable]'));
      expect(
        RegExp(
          "enablement_dependency \\{\\(spirit:decode\\(id\\('PARAM_VALUE.IMPL_MODE'\\)\\) = 1\\) && \\(spirit:decode\\(id\\('PARAM_VALUE.NUM_BANDS'\\)\\) > \\d+\\)\\}",
        ).allMatches(tcl),
        hasLength(80),
      );
      expect(RegExp('driver_value 0').allMatches(tcl), hasLength(81));
      expect(tcl, isNot(contains(r'enablement_tcl_expr {\$NUM_BANDS')));
      expect(
        files['demo/create_demo_project.tcl']!,
        contains('set_property CONFIG.NUM_BANDS {2} [get_ips ISP_IP_MBC_EQ]'),
      );
      expect(core, contains('wire [15:0] ch_enable_ext = CH_Enable;'));
      expect(core, contains('((1 >= NUM_BANDS) || !ch_enable_ext[1])'));
      expect(core, contains('input  wire [31:0] par_b15_hc'));
      expect(core, contains('input  wire [NUM_BANDS-1:0] CH_Enable'));
      final axis = files['ISP_IP_MBC_EQ_axis.v']!;
      expect(axis, contains('input  wire [NUM_BANDS-1:0] CH_Enable'));
      expect(axis, contains('.CH_Enable(CH_Enable)'));
      final demoTop = files['demo/demo_top.v']!;
      final demoTb = files['demo/tb_demo.v']!;
      expect(demoTop, contains('u_dut ( .aclk(aclk_int), .* );'));
      expect(demoTop, contains('localparam integer NUM_BANDS = 2'));
      expect(
        demoTop,
        contains('wire [NUM_BANDS-1:0] CH_Enable = {NUM_BANDS{1\'b1}};'),
      );
      expect(demoTb, contains('.m_axis_tready(m_axis_tready)'));
      expect(demoTb, isNot(contains('dut (.*);')));
      expect(demoTb, isNot(contains('.par_b2_hc(par_b2_hc)')));
      expect(
        demoTb,
        contains(
          'reg [NUM_BANDS-1:0] CH_Enable = CH_ENABLE_VALUE[NUM_BANDS-1:0];',
        ),
      );
      expect(demoTb, isNot(contains('dut.inst.')));
      expect(demoTb, contains('localparam integer GOLDEN_CHECK = 1'));
      expect(files['demo/timing.xdc']!, isNot(contains('get_pins')));
      expect(
        files['demo/timing.xdc']!,
        isNot(contains('get_ports {CH_Enable')),
      );
      final demoTcl = files['demo/create_demo_project.tcl']!;
      expect(
        demoTcl,
        contains(
          'set_property file_type SystemVerilog [get_files \$demoDir/demo_top.v]',
        ),
      );
      expect(
        demoTcl,
        contains(
          'set_property file_type SystemVerilog [get_files \$demoDir/tb_demo.v]',
        ),
      );
      expect(core, contains('parameter integer WORK_MODE = 0'));
      expect(core, contains('if (WORK_MODE == 0) begin : g_parallel'));
      expect(core, contains('end else begin : g_serial'));
      expect(
        tcl,
        contains(
          'value_validation_pairs [list "Color picker parallel operation" 0 "Color picker cascade operation" 1]',
        ),
      );
      expect(
        demoTcl,
        contains('set_property CONFIG.WORK_MODE {0} [get_ips ISP_IP_MBC_EQ]'),
      );
      expect(xgui, contains('Number Of Color Picker Channels'));
      expect(
        RegExp(r'proc update_MODELPARAM_VALUE\.').allMatches(xgui),
        hasLength(8),
      );
      expect(
        xgui,
        contains(
          'proc update_MODELPARAM_VALUE.WORK_MODE { MODELPARAM_VALUE.WORK_MODE PARAM_VALUE.WORK_MODE }',
        ),
      );
      expect(
        xgui,
        contains(
          'proc update_MODELPARAM_VALUE.NUM_BANDS { MODELPARAM_VALUE.NUM_BANDS PARAM_VALUE.NUM_BANDS }',
        ),
      );
      expect(
        xgui,
        contains(
          'set_property value [get_property value \${PARAM_VALUE.NUM_BANDS}] \${MODELPARAM_VALUE.NUM_BANDS}',
        ),
      );
      expect(xgui, isNot(contains('BYPASS_B')));
    });

    test('iverilog bypass：并联单段与全段直出（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return;
      final graph = fxGraph(twoBands);
      final bypassOne = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
        bypassMask: 1,
      );
      final expected = buildGroupIpFiles(
        fxGraph([twoBands[1]]),
        fxGraph([twoBands[1]]).groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      expect(bypassOne['golden_hash.txt'], expected['golden_hash.txt']);
      var result = await runIpSimulation(bypassOne);
      expect(result.passed, isTrue, reason: result.output);
      final allBypass = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
        bypassMask: 0xFFFF,
      );
      result = await runIpSimulation(allBypass);
      expect(result.passed, isTrue, reason: result.output);
    });

    test('iverilog bypass：串联屏蔽与 NUM_BANDS 截断（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return;
      final graph = fxGraph(threeBands, serial: true);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic, dspPipe: 2),
        numBands: 2,
        bypassMask: 2,
      );
      final expected = buildGroupIpFiles(
        fxGraph([threeBands[0]]),
        fxGraph([threeBands[0]]).groups.single,
        const IpGenOptions(vendor: IpVendor.generic, dspPipe: 2),
      );
      expect(files['golden_hash.txt'], expected['golden_hash.txt']);
      final result = await runIpSimulation(files);
      expect(result.passed, isTrue, reason: result.output);
    });

    test('iverilog NUM_BANDS=16：超出原段数保持恒等（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return;
      final graph = fxGraph(twoBands);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
        numBands: 16,
      );
      final result = await runIpSimulation(files);
      expect(result.passed, isTrue, reason: result.output);
    });

    test('段单元按 NUM_BANDS 裁剪：generate 条件 + 共享像素延迟线', () async {
      final graph = fxGraph(twoBands);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final core = files['ISP_IP_MBC_EQ_core.v']!;
      // 每段包在 if (NUM_BANDS > i) 条件块里（elaboration 期按参数裁剪）。
      for (var i = 0; i < 16; i++) {
        expect(core, contains('if (NUM_BANDS > $i) begin : g_b$i'),
            reason: 'band $i 未被 NUM_BANDS 裁剪');
      }
      expect(core, contains("assign b0_dh = 48'sd0"));
      // 像素直通延迟线全段共享一份（不再每段复制）。
      expect(core, contains('hv_d <= {hv_d['));
    });

    test('串联全流水同样按 NUM_BANDS 裁剪：未启用段走 11 拍直通补偿', () {
      final graph = fxGraph(threeBands, serial: true);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final core = files['ISP_IP_MBC_EQ_core.v']!;
      for (var i = 0; i < 16; i++) {
        expect(core, contains('if (NUM_BANDS > $i) begin : g_b$i'),
            reason: '串联 band $i 未被 NUM_BANDS 裁剪');
      }
      // 未启用段：pre/mid/post 不实例化，但段内延迟线与 post 的 11 拍延迟
      // 必须补齐（否则整链 LAT 变短、golden 错位）。
      expect(core, contains('else begin : g_b0_off'));
      expect(core, contains('hof0_11 <= hof0_10'));
      expect(core, contains('sacc1 <= sof0_11'));
      // 段内延迟线无条件发射（在 generate 条件块之外）。
      expect(core, contains('reg [1343:0] h_d0;'));
    });

    test('legacy 档（DSP_PIPE<3）同样按 NUM_BANDS 裁剪段单元', () {
      for (final pipe in [1, 2]) {
        final graph = fxGraph(twoBands);
        final files = buildGroupIpFiles(
          graph,
          graph.groups.single,
          IpGenOptions(vendor: IpVendor.generic, dspPipe: pipe),
        );
        final core = files['ISP_IP_MBC_EQ_core.v']!;
        for (var i = 0; i < 16; i++) {
          expect(core, contains('if (NUM_BANDS > $i) begin : g_pre$i'),
              reason: 'DSP_PIPE=$pipe 的 band $i pre 未被裁剪');
          expect(core, contains('if (NUM_BANDS > $i) begin : g_mid$i'),
              reason: 'DSP_PIPE=$pipe 的 band $i mid 未被裁剪');
          expect(core, contains('if (NUM_BANDS > $i) begin : g_post$i'),
              reason: 'DSP_PIPE=$pipe 的 band $i post 未被裁剪');
        }
        expect(core, contains("assign uc15 = 64'd0;"));
        expect(core, contains("assign b15_dh = 48'sd0;"));
      }
      // 串联 legacy 档（WORK_MODE=1 + DSP_PIPE<3）走直通补偿分支。
      final serGraph = fxGraph(threeBands, serial: true);
      final ser = buildGroupIpFiles(
        serGraph,
        serGraph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic, dspPipe: 2),
      );
      expect(ser['ISP_IP_MBC_EQ_core.v']!, contains('assign bw15_h = csel_h15;'));
    });

    test('iverilog 实仿：func_fixed 并联两段 PASS（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return;
      final graph = fxGraph(twoBands);
      final files = buildGroupIpFiles(
        graph,
        graph.groups.single,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final r = await runIpSimulation(files);
      expect(r.success, isTrue, reason: r.output);
      expect(r.passed, isTrue, reason: r.output);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      'iverilog 实仿：func_fixed 串联三段 + 握手压力 PASS（无 iverilog 自动 skip）',
      () async {
        if (detectIverilog() == null) return;
        final graph = fxGraph(threeBands, serial: true);
        const stim = IpSimStimulus(
          width: 16,
          height: 8,
          frames: 2,
          frameGapCycles: 10,
          inGapPct: 30,
          outStallPct: 40,
        );
        final files = buildGroupIpFiles(
          graph,
          graph.groups.single,
          const IpGenOptions(vendor: IpVendor.generic),
          stimulus: stim,
        );
        final r = await runIpSimulation(files);
        expect(r.success, isTrue, reason: r.output);
        expect(r.passed, isTrue, reason: r.output);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('DSP_PIPE=3 全流水延迟与 Vivado 配置', () {
      final parGraph = fxGraph(twoBands);
      final parPlan = planGroupIp(
        parGraph,
        parGraph.groups.single,
        const IpGenOptions(vendor: IpVendor.vivado, dspPipe: 3),
      );
      expect(parPlan.resources.latencyCycles, 89);
      final serGraph = fxGraph(threeBands, serial: true);
      final serPlan = planGroupIp(
        serGraph,
        serGraph.groups.single,
        const IpGenOptions(vendor: IpVendor.vivado, dspPipe: 3),
      );
      expect(serPlan.resources.latencyCycles, 889);
      for (final entry in [(parGraph, 7), (serGraph, 52)]) {
        final fallbackPlan = planGroupIp(
          entry.$1,
          entry.$1.groups.single,
          const IpGenOptions(vendor: IpVendor.vivado, gstrategy: 0, dspPipe: 3),
        );
        expect(fallbackPlan.resources.latencyCycles, entry.$2);
      }
      final files = buildGroupIpFiles(
        parGraph,
        parGraph.groups.single,
        const IpGenOptions(vendor: IpVendor.vivado, dspPipe: 3),
      );
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('DSP48E2 #('));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('.AREG(1)'));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('.BREG(1)'));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('.MREG(1)'));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('.PREG(1)'));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('.OPMODEREG(0)'));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains(".OPMODE(9'b000000101)"));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('g_b_unsigned_18'));
      expect(files['ISP_IP_MBC_EQ_core.v'], contains('a_wide << 18'));
      expect(files['ISP_IP_MBC_EQ_core.v'], isNot(contains('PW-18-AW')));
      expect(
        files['package_ip.tcl'],
        contains('Full internal DSP pipeline (highest Fmax)'),
      );
      expect(files['demo/tb_demo.v'], contains('drain_i < 893 * 40'));
    });

    for (final k in [1, 2, 3]) {
      test('iverilog 实仿：DSP_PIPE=$k 并联两段 PASS（选通结构 golden 不变）', () async {
        if (detectIverilog() == null) return;
        final graph = fxGraph(twoBands);
        final files = buildGroupIpFiles(
          graph,
          graph.groups.single,
          IpGenOptions(vendor: IpVendor.generic, dspPipe: k),
          stimulus: k == 3
              ? const IpSimStimulus(inGapPct: 25, outStallPct: 25)
              : null,
        );
        expect(
          files['ISP_IP_MBC_EQ_core.v']!,
          contains('parameter integer DSP_PIPE  = $k'),
        );
        final r = await runIpSimulation(files);
        expect(r.success, isTrue, reason: r.output);
        expect(r.passed, isTrue, reason: r.output);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('iverilog 实仿：DSP_PIPE=$k 串联三段 PASS（选通结构 golden 不变）', () async {
        if (detectIverilog() == null) return;
        final graph = fxGraph(threeBands, serial: true);
        final files = buildGroupIpFiles(
          graph,
          graph.groups.single,
          IpGenOptions(vendor: IpVendor.generic, dspPipe: k),
          stimulus: k == 3
              ? const IpSimStimulus(inGapPct: 25, outStallPct: 25)
              : null,
        );
        final r = await runIpSimulation(files);
        expect(r.success, isTrue, reason: r.output);
        expect(r.passed, isTrue, reason: r.output);
      }, timeout: const Timeout(Duration(minutes: 3)));
    }
  });
}
