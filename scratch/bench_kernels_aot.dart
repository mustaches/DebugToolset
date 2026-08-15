// AOT 内核吞吐基准：dart compile exe 后运行，测全分辨率视频流程的
// 逐像素内核耗时（JIT 数字不代表 release 表现）。
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';

void main() {
  for (final (w, h) in [(1920, 1080), (3840, 2160)]) {
    final px = w * h;
    final src = Uint8List(px * 3);
    final planes = [
      Uint8List.sublistView(src, 0, px),
      Uint8List.sublistView(src, px, px * 2),
      Uint8List.sublistView(src, px * 2, px * 3),
    ];
    // 预热
    mono8ToRgba(planes[0]);
    yuv444p8ToRgba(planes, w, h);

    var sw = Stopwatch()..start();
    const rounds = 20;
    for (var i = 0; i < rounds; i++) {
      mono8ToRgba(planes[0]);
      mono8ToRgba(planes[1]);
      mono8ToRgba(planes[2]);
      yuv444p8ToRgba(planes, w, h);
    }
    final us = sw.elapsedMicroseconds / rounds;
    // ignore: avoid_print
    print('${w}x$h 主链(3×mono8 + yuv→rgba): ${(us / 1000).toStringAsFixed(1)}ms'
        ' → 含全图预览双链约 ${(us * 1.5 / 1000).toStringAsFixed(1)}ms/帧');

    // TTD 等价拷贝开销：输出 4×(w*h*4) 的 memcpy 估计
    sw.reset();
    for (var i = 0; i < rounds; i++) {
      final a = Uint8List(px * 4);
      final b = Uint8List.fromList(a);
      b[0] = 1;
    }
    // ignore: avoid_print
    print('${w}x$h 33MB 拷贝: '
        '${(sw.elapsedMicroseconds / rounds / 1000).toStringAsFixed(1)}ms/次');
  }
}
