// 一次性验证：生成 IP 包 → iverilog 实仿 → GTKWave 带 wave.gtkw 打开。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/iverilog_sim.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

Future<void> main() async {
  final tc = detectIverilog();
  final viewer = detectWaveViewer(tc);
  print('iverilog: ${tc?.iverilog}');
  print('viewer: ${viewer?.exe} (surfer=${viewer?.isSurfer})');
  final text = File('IspFlow/多段色彩均衡器.ispflow').readAsStringSync();
  final graph = IspGraph.fromJson(jsonDecode(text) as Map<String, Object?>);
  final files = buildGroupIpFiles(
      graph, graph.groups.single, const IpGenOptions(vendor: IpVendor.generic));
  final r = await runIpSimulation(files, openWaveform: true);
  print('success=${r.success} passed=${r.passed}');
  print(r.output.split('\n').where((l) => l.contains('PASS') || l.contains('FAIL') || l.contains('GTKWave')).join('\n'));
}
