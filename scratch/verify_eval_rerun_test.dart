// 验证指标结果缓存：同一流程连跑两次 runPreview，第二次应因输入
// 签名未变而跳过全部分析（秒级完成），且结果保持一致。临时验证用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  test('图像评价.ispflow 二次运行走缓存', () async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    await state.importGraphFromFile('IspFlow/图像评价.ispflow');

    final sw1 = Stopwatch()..start();
    await state.runPreview();
    sw1.stop();
    final first = Map.of(state.instrumentResults);
    print('[rerun] 首次: ${sw1.elapsedMilliseconds}ms, 结果数=${first.length}');

    final sw2 = Stopwatch()..start();
    await state.runPreview();
    sw2.stop();
    print('[rerun] 第二次: ${sw2.elapsedMilliseconds}ms, '
        '结果数=${state.instrumentResults.length}');

    expect(state.instrumentResults.length, first.length);
    for (final id in first.keys) {
      expect(state.instrumentResults[id].toString(), first[id].toString(),
          reason: '节点 $id 结果应一致');
    }
    // 第二次全命中签名缓存：不再重跑馈源链与指标，应在数秒内完成。
    expect(sw2.elapsedMilliseconds, lessThan(15000),
        reason: '第二次运行应全部命中缓存');
    exit(0);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
