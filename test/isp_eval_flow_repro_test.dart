// 复现「图像评价.ispflow 运行预览卡死」：加载真实流程跑 runPreview，
// 周期打印状态栏与已完成仪器，定位卡点。临时诊断用。
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_dart.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  // flutter_tester 为软件光栅：关闭 VGG16 GPU 驻留链走 CPU 池。
  Vgg16AsyncForward.enabled = false;
  test('图像评价.ispflow runPreview 全流程计时', () async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    await state.importGraphFromFile('IspFlow/图像评价.ispflow');
    print('[repro] 节点数: ${state.graph.nodes.length}');

    final sw = Stopwatch()..start();
    final done = <String>{};
    final timer = Timer.periodic(const Duration(seconds: 2), (_) {
      final results = state.instrumentResults.keys
          .where((k) => !done.contains(k))
          .toList();
      done.addAll(results);
      print('[repro] ${sw.elapsedMilliseconds}ms 状态="${state.statusMessage}" '
          '已完成=${state.instrumentResults.length} 新完成=$results');
    });
    addTearDown(timer.cancel);

    await state.runPreview();
    timer.cancel();
    print('[repro] runPreview 完成: ${sw.elapsedMilliseconds}ms, '
        '结果数=${state.instrumentResults.length}');
    for (final e in state.instrumentResults.entries) {
      print('[repro]   ${e.key}: ${e.value}');
    }
    // 给常驻子进程/worker 一点退出时间
    await Future.delayed(const Duration(seconds: 1));
    // 全量回归中跳过：20MP 大图 + 14 指标的纯 Dart 深度评价约 45 分钟，
    // 属手动诊断用例（需要时去掉 skip 单独跑）。
  },
      skip: '手动诊断用例（全流程约 45 分钟）',
      timeout: const Timeout(Duration(minutes: 90)));
}
