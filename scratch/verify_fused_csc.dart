// 一次性校验：单遍融合版 yuvToHsl/hslToYuv 与两段中转实现逐点一致。
import 'dart:math';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';

void main() {
  final rng = Random(42);
  for (final maxValue in [255, 1023, 4095, 65535]) {
    final n = 100000 * 3;
    final yuv = Uint16List(n);
    final hsl = Uint16List(n);
    for (var i = 0; i < n; i++) {
      yuv[i] = rng.nextInt(maxValue + 1);
      hsl[i] = rng.nextInt(maxValue + 1);
    }
    final a = yuvToHsl(yuv, maxValue: maxValue);
    final b = rgbToHsl(yuvToRgb(yuv, maxValue: maxValue), maxValue: maxValue);
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) {
        print('yuvToHsl mismatch maxValue=$maxValue @$i: ${a[i]} vs ${b[i]}');
        return;
      }
    }
    final c = hslToYuv(hsl, maxValue: maxValue);
    final d = rgbToYuv(hslToRgb(hsl, maxValue: maxValue), maxValue: maxValue);
    for (var i = 0; i < n; i++) {
      if (c[i] != d[i]) {
        print('hslToYuv mismatch maxValue=$maxValue @$i: ${c[i]} vs ${d[i]}');
        return;
      }
    }
    print('maxValue=$maxValue: 10 万像素逐点一致');
  }
  print('OK：融合实现与两段中转实现完全等价');
}
