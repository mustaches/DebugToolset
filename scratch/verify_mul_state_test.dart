// 一次性验证脚本：以用户实际操作路径（状态层 importGraphFromFile +
// runPreview）验证乘法器测试流程的预览#1 出图。
import 'dart:ui' as ui;

import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('状态层运行乘法器测试流程：预览#1（n4）出灰度调制图', () async {    final state = IspStudioState();
    addTearDown(state.dispose);
    await state
        .importGraphFromFile('G:/DebugToolSet/IspFlow/乘法器测试流程.ispflow');
    expect(state.statusMessage, contains('已打开流程'),
        reason: state.statusMessage);

    await state.runPreview();
    expect(state.statusMessage, isNot(contains('失败')),
        reason: state.statusMessage);

    final img = state.previewImages['n4'];
    expect(img, isNotNull,
        reason: '预览#1 应出图；status=${state.statusMessage}');
    final bd =
        await img!.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = bd!.buffer.asUint8List();
    var nonBlack = 0;
    for (var i = 0; i < px.length; i += 4) {
      if (px[i] != px[i + 1] || px[i + 1] != px[i + 2]) {
        fail('mono 出图应灰度：像素 $i = '
            '(${px[i]},${px[i + 1]},${px[i + 2]})');
      }
      if (px[i] > 0) nonBlack++;
    }
    expect(nonBlack, greaterThan(0), reason: '边缘×亮度调制结果不应全黑');
    // ignore: avoid_print
    print('预览#1：${img.width}x${img.height}，非黑像素 $nonBlack，'
        '预览#2(n13) ${state.previewImages.containsKey('n13') ? "已出图" : "无图"}');
  }, timeout: const Timeout.factor(20));
}
