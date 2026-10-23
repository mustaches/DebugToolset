// lut_fixed 单节点黑盒「运行验证（原尺寸）」吞吐复现/测量（一次性脚本，
// 经 flutter test 运行：import 链带 Flutter 库，dart run 无法编译）。
// 构图：video_source(bitDepth=8, out_hsl) → multi_band_eq(lut_fixed) 单节点
// 编组 → 黑盒导出 → buildWinVerifyApp（hsl/hsl, MAXV=255）→ 批模式
// --frames N --dump-hash 跑 4K 视频，读 timing 行（read/pack/run/unpack）。
// 运行：flutter test scratch/eq_bb_perf_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export_bb.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';

void main() {
  test('lut_fixed 单节点黑盒 4K 批模式吞吐测量', () async {
    const video = '4k60VRec/Sony 4K60p SDR Demo Video.MP4';
    const frames = 60;

    final graph = IspGraph();
    final vs = graph.addNode('video_source', 0, 0);
    graph.nodes[vs]!.paramValues['bitDepth'] = '8';
    final eq = graph.addNode('multi_band_eq', 0, 0);
    graph.nodes[eq]!.name = 'mb';
    final p = graph.nodes[eq]!.paramValues;
    p['codegenMode'] = 'lut';
    p['band_count'] = 4;
    // 4 段非恒等带（典型使用形态）。
    p['b0_h'] = 15.0;
    p['b0_q'] = 3.0;
    p['b0_dh'] = 25.0;
    p['b0_s'] = 1.3;
    p['b0_l'] = 0.9;
    p['b1_h'] = 120.0;
    p['b1_q'] = 2.0;
    p['b1_dh'] = -40.0;
    p['b1_s'] = 0.8;
    p['b1_l'] = 1.1;
    p['b2_h'] = 210.0;
    p['b2_q'] = 4.0;
    p['b2_dh'] = 60.0;
    p['b2_s'] = 1.5;
    p['b2_l'] = 1.0;
    p['b3_h'] = 300.0;
    p['b3_q'] = 2.5;
    p['b3_dh'] = -15.0;
    p['b3_s'] = 1.1;
    p['b3_l'] = 0.85;
    expect(graph.connect(vs, 'out_hsl', eq, 'in'), isNull);
    graph.groups.add(IspNodeGroup('g1', {eq}, name: 'eqperf'));

    final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
        readFile: (path) => File(path).readAsString(), genTime: DateTime(2026, 1, 2, 3, 4, 5));
    const top = 'isp_pipe_eqperf_bb';
    expect(files.containsKey('$top.h'), isTrue,
        reason: files.keys.join(', '));
    final hasScratch = files['$top.h']!.contains('void *scratch');
    // ignore: avoid_print
    print('hasScratch=$hasScratch');

    final r = await buildWinVerifyApp(files,
        topName: top,
        inFormat: 'hsl',
        outFormat: 'hsl',
        hasScratch: hasScratch,
        maxValue: 255);
    // ignore: avoid_print
    print(r.output);
    expect(r.success, isTrue);

    final exe = r.artifactPath!;
    final ff = '${Directory.current.path}/tools/ffmpeg/ffmpeg.exe';
    final pr = await Process.run(exe,
        ['--video', video, '--ffmpeg', ff, '--frames', '$frames', '--dump-hash', '--swdec'],
        workingDirectory: r.workDir);
    final lines = (pr.stdout as String).split('\n');
    // ignore: avoid_print
    print(lines.length > 8 ? lines.sublist(lines.length - 8).join('\n') : pr.stdout);
    // ignore: avoid_print
    print('exit=${pr.exitCode} exe=$exe');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
