// 一次性：验证修改后的 yuv_planes.frag 在测试环境可加载编译。
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('load yuv_planes.frag', () async {
    final prog =
        await ui.FragmentProgram.fromAsset('shaders/yuv_planes.frag');
    final shader = prog.fragmentShader();
    // ignore: avoid_print
    print('shader loaded: $shader');
  });
}
