// 步进耗时定位：真实 4K 视频上测 顺序流取帧 / 单次 seek 解码 / 链原语耗时。
// 用法：flutter test scratch/step_timing_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';

void main() {
  const candidates = [
    '4k60VRec/record-2024-09-26-12-03-24.mp4',
    '4k60VRec/record-2025-12-03-11-49-45.mp4',
    '4k60VRec/Sony 4K60p HDR Demo Video.MP4',
  ];

  test('step path timing', () async {
    final path = candidates.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => '',
    );
    if (path.isEmpty) return;
    final sw = Stopwatch()..start();
    final info = await videoFileInfo(path);
    print('[timing] probe=${sw.elapsedMilliseconds}ms '
        '${info.width}x${info.height}@${info.fps} frames=${info.frameCount} '
        'hdr=${info.isHdr}');

    // 1) 单次 seek 解码（旧路径）
    sw.reset();
    await decodeVideoFrameToRgb16(path, 100, maxValue: 255);
    print('[timing] single seek decode frame100 = ${sw.elapsedMilliseconds}ms');

    // 2) 顺序流：start + 连续 next ×4（新步进路径）
    sw.reset();
    final stream = await VideoFrameStream.start(path, 100,
        pixelFormat: 'rgba', hwaccel: '');
    print('[timing] stream start = ${sw.elapsedMilliseconds}ms');
    for (var i = 0; i < 4; i++) {
      sw.reset();
      final f = await stream.next();
      print('[timing] stream.next[$i] = ${sw.elapsedMilliseconds}ms '
          '(got=${f != null})');
      if (f != null) stream.recycle(f);
    }
    await stream.dispose();

    // 3) 链原语（4K 全帧 Dart 转换）
    final frame = await decodeVideoFrameToRgb16(path, 100, maxValue: 255);
    final rgba = await File(path).existsSync()
        ? await _grabRgba(path, 100)
        : null;
    if (rgba != null) {
      sw.reset();
      final rgb = rgba8ToRgb16(rgba, info.width, info.height, 255);
      print('[timing] rgba8ToRgb16 4K = ${sw.elapsedMilliseconds}ms');
      sw.reset();
      final hsl = rgbToHsl(rgb.$1, maxValue: 255);
      print('[timing] rgbToHsl 4K = ${sw.elapsedMilliseconds}ms');
      sw.reset();
      final back = hslToRgb(hsl, maxValue: 255);
      print('[timing] hslToRgb 4K = ${sw.elapsedMilliseconds}ms ${back.length}');
    }
    expect(frame.$2, info.width);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<Uint8List?> _grabRgba(String path, int frame) async {
  final s = await VideoFrameStream.start(path, frame,
      pixelFormat: 'rgba', hwaccel: '');
  final f = await s.next();
  await s.dispose();
  return f;
}
