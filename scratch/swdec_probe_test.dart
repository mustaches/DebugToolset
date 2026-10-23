import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';

void main() {
  test('swdec 探针：4:2:2 片源硬解失败应回退软解并置标志', () async {
    const f = r'H:\Surgery_video\record-2024-09-26-12-03-24.mp4';
    if (!File(f).existsSync()) return;
    final s = await VideoFrameStream.start(f, 0,
        pixelFormat: 'yuv420p',
        passthrough: true,
        maxWorkingHeight: 540);
    final sw = Stopwatch()..start();
    while (!s.usedSoftwareDecode &&
        s.bufferedCount == 0 &&
        !s.isDrained &&
        sw.elapsedMilliseconds < 10000) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // ignore: avoid_print
    print('swdec=${s.usedSoftwareDecode} buffered=${s.bufferedCount} '
        'drained=${s.isDrained} t=${sw.elapsedMilliseconds}ms');
    await s.dispose();
    expect(s.usedSoftwareDecode, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
