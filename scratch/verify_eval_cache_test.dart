// 验证馈源去重 + 指标签名缓存（纯 Dart 指标，无 torch 环境依赖）：
// 同一流程连跑两次 runPreview，第一次完整计算，第二次应全部命中
// 签名缓存秒级完成且结果一致。临时验证用。
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  test('纯Dart指标流程：二次运行走缓存', () async {
    final state = IspStudioState();
    addTearDown(state.dispose);
    await state.importGraphFromFile('scratch/eval_dart_only.ispflow');

    final sw1 = Stopwatch()..start();
    await state.runPreview();
    sw1.stop();
    final first = Map.of(state.instrumentResults);
    print('[cache] 首次: ${sw1.elapsedMilliseconds}ms, 结果数=${first.length}');
    expect(first.length, 7, reason: '7 个 Dart 指标应全部出分');

    final sw2 = Stopwatch()..start();
    await state.runPreview();
    sw2.stop();
    print('[cache] 第二次: ${sw2.elapsedMilliseconds}ms, '
        '结果数=${state.instrumentResults.length}');

    expect(state.instrumentResults.length, first.length);
    for (final id in first.keys) {
      expect(state.instrumentResults[id].toString(), first[id].toString(),
          reason: '节点 $id 结果应一致');
    }
    // 第二次全命中签名缓存：不再重跑馈源链与指标。
    expect(sw2.elapsedMilliseconds, lessThan(10000),
        reason: '第二次运行应全部命中缓存');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
