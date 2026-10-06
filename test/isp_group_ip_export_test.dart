// ISP Studio IP Generator（编组 → FPGA Verilog IP 包）测试。
// 围绕「多段色彩均衡器.ispflow」验证校验/规划/Verilog 发射/golden/仿真。
// iverilog 不在场时仿真用例自动 skip（仿黑盒测试的 MSVC skip 模式）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_gen_plan.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_validate.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/iverilog_sim.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

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
            'wave.gtkw',
            'wave.sucl',
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
      expect(tb, contains('\$dumpvars')); // 波形转储供 GTKWave 打开
      // GTKWave 保存文件：自动加入时钟与 IP I/O 信号。
      final gtkw = files['wave.gtkw']!;
      expect(gtkw, contains('tb_isp_ip_multi_band_eq.clk'));
      expect(gtkw, contains('tb_isp_ip_multi_band_eq.in_valid'));
      expect(gtkw, contains('tb_isp_ip_multi_band_eq.out_data[23:0]'));
      // Surfer 启动命令文件：自动加入时钟与 IP I/O 信号。
      final sucl = files['wave.sucl']!;
      expect(sucl, contains('variable_add tb_isp_ip_multi_band_eq.clk'));
      expect(sucl, contains('variable_add tb_isp_ip_multi_band_eq.out_data'));
      expect(sucl, contains('zoom_fit'));
      // golden_in.hex 帧尺寸 = 64×48 行。
      final inLines = files['golden_in.hex']!.trim().split('\n');
      expect(inLines.length, kIpSimW * kIpSimH);
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

    test('Libero 目标附 libero 封装', () {
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.libero));
      expect(files.keys, contains('isp_ip_multi_band_eq_libero.v'));
    });
  });

  group('一键仿真', () {
    test('iverilog 实仿（无 iverilog 自动 skip）', () async {
      if (detectIverilog() == null) return; // 无 iverilog 跳过
      final graph = loadSample();
      final files = buildGroupIpFiles(graph, sampleGroup(graph),
          const IpGenOptions(vendor: IpVendor.generic));
      final r = await runIpSimulation(files, openWaveform: false);
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
