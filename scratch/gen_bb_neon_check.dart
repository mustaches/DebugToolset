// 一次性脚本：生成 lut_fixed 单节点黑盒编组 C 代码到 scratch/bb_neon_check/，
// 供 WSL 交叉 gcc 语法检查（验证 -Wpointer-sign / -Wunused-variable 修复）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export_bb.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

void main() {
  test('gen bb lut_fixed neon check sources', () async {
    Future<String> readDisk(String path) => File(path).readAsString();
    final graph = IspGraph();
    final eq = graph.addNode('multi_band_eq', 0, 0);
    graph.nodes[eq]!.name = 'mb';
    graph.nodes[eq]!.paramValues['codegenMode'] = 'lut_fixed';
    graph.nodes[eq]!.paramValues['b0_dh'] = 30.0;
    graph.groups.add(IspNodeGroup('g1', {eq}, name: 'n1'));
    final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
        readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
    final dir = Directory('scratch/bb_neon_check')..createSync(recursive: true);
    for (final e in files.entries) {
      File('${dir.path}/${e.key}').writeAsStringSync(e.value);
    }
    // ignore: avoid_print
    print('written: ${files.keys.join(', ')}');
  });
}
