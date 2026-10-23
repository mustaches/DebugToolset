// 一次性：跑仿真并转储 wave.vcd 头部/尾部供解析器开发参考。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/iverilog_sim.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

Future<void> main() async {
  final text = File('IspFlow/多段色彩均衡器.ispflow').readAsStringSync();
  final graph = IspGraph.fromJson(jsonDecode(text) as Map<String, Object?>);
  final files = buildGroupIpFiles(
      graph, graph.groups.single, const IpGenOptions(vendor: IpVendor.generic));
  final r = await runIpSimulation(files, openWaveform: false);
  final vcd = r.vcdData!;
  await File('scratch/wave_sample.vcd').writeAsBytes(vcd);
  print('vcd bytes: ${vcd.length}');
}
