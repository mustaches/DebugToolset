// 临时基准：Win32 验证程序（黑盒均衡器编组）4K 视频批模式吞吐实测。
// 批模式不走定时器/显示，测的是 ffmpeg 管道解码 + 管线处理的上限帧率。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export_bb.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

void main() {
  test('4K 视频批模式吞吐（管道缓冲修复后）', timeout: const Timeout(Duration(minutes: 5)),
      () async {
    if (detectMsvc() == null) return;
    const video = '4k60VRec/4k30RecV1.mp4';
    if (!File(video).existsSync()) return;
    final graph = IspGraph();
    final eq = graph.addNode('multi_band_eq', 0, 0);
    graph.nodes[eq]!.name = 'mb';
    graph.nodes[eq]!.paramValues['b0_dh'] = 30.0;
    graph.groups.add(IspNodeGroup('g1', {eq}, name: 'n1'));
    final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
        readFile: (p) => File(p).readAsString(),
        genTime: DateTime(2026, 1, 2, 3, 4, 5));
    final topName = groupBlackBoxTopName(graph.groups.single);
    final hasScratch =
        (files['$topName.h'] ?? '').contains('void *scratch');
    final result = await buildWinVerifyApp(files,
        topName: topName, inFormat: 'hsl', outFormat: 'hsl',
        hasScratch: hasScratch);
    expect(result.success, isTrue, reason: result.output);

    final ffmpeg = File('tools/ffmpeg/ffmpeg.exe').absolute.path;
    // 批模式无定时节拍，跑 120 帧测纯吞吐（4K→960x540 缩放档）。
    final sw = Stopwatch()..start();
    final run = await Process.run(result.artifactPath!, [
      '--video', File(video).absolute.path, '--ffmpeg', ffmpeg,
      '--scale', '960x540',
      '--frames', '120', '--dump-hash',
    ]);
    sw.stop();
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    final lines = '${run.stdout}'.trim().split('\n');
    final n = lines.where((l) => l.startsWith('frame ')).length;
    // ignore: avoid_print
    print('批模式吞吐: $n 帧 / ${sw.elapsedMilliseconds}ms = '
        '${(n * 1000 / sw.elapsedMilliseconds).toStringAsFixed(1)} fps '
        '(4K 解码+管线，无显示)');
    // ignore: avoid_print
    if (lines.isNotEmpty) print(lines.last);
  });
}
