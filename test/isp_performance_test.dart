import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

void main() {
  group('ISP Performance Optimization Tests', () {
    test('downsampleRgba82x 2x fast downsampling reduces 1080p frame size by 75%', () {
      const w = 1920;
      const h = 1080;
      final src = Uint8List(w * h * 4);
      // Fill with test values
      for (var i = 0; i < src.length; i += 4) {
        src[i] = 120;     // R
        src[i + 1] = 200; // G
        src[i + 2] = 80;  // B
        src[i + 3] = 255; // A
      }

      final (dst, outW, outH) = downsampleRgba82x(src, w, h);

      expect(outW, 960);
      expect(outH, 540);
      expect(dst.length, 960 * 540 * 4);
      expect(dst[0], 120);
      expect(dst[1], 200);
      expect(dst[2], 80);
      expect(dst[3], 255);
    });
  });
}
