/// 临时（验证后删除）：从 IspFlow/多段色彩均衡器.ispflow 生成黑盒 C 代码并
/// 构建 Win32 运行验证程序，端到端验证 isp_csc_sse.h 快路径。
library;

import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export_bb.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_plan.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> main() async {
  test('生成 多段色彩均衡器.ispflow 黑盒验证程序', () async {
    final json = jsonDecode(
        await File('IspFlow/多段色彩均衡器.ispflow').readAsString());
    final graph = IspGraph.fromJson(json as Map<String, Object?>);
    final group = graph.groups.first;
    final files = await buildGroupBlackBoxCFiles(graph, group,
        readFile: (p) => File(p).readAsString());
    final topName = groupBlackBoxTopName(group);
    final plan = planGroupC(graph, group);
    final hasScratch =
        (files['$topName.h'] ?? '').contains('void *scratch');
    final node = graph.nodes[group.nodeIds.first]!;
    final result = await buildWinVerifyApp(files,
        topName: topName,
        inFormat: plan.extInputParams.single.format,
        outFormat: plan.extOutputParams.single.format,
        hasScratch: hasScratch,
        maxValue: lutDomainMaxOf(graph, node));
    // ignore: avoid_print
    print(result.output);
    expect(result.success, isTrue,
        reason: '构建失败：${result.commandLine}\n${result.output}');
    // ignore: avoid_print
    print('ARTIFACT=${result.artifactPath}');
  });
}
