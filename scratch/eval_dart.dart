// Dart 评价函数在 256×192 busyFrame 对上的数值（与 scratch/eval_ref.py 同帧对拍）。
// 运行：dart run scratch/eval_dart.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/piqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/brisque.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';

Uint8List busyFrame(int w, int h, {bool noisy = false}) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      var r = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0)
          .toInt();
      var g = (128 +
              70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
              40 * math.cos((2 * x - y) / 6.7))
          .clamp(0.0, 255.0)
          .toInt();
      var b = (128 +
              70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
          .clamp(0.0, 255.0)
          .toInt();
      if (noisy) {
        final base = (y * w + x) * 3;
        r = (r + (base * 31) % 61 - 30).clamp(0, 255);
        g = (g + ((base + 1) * 31) % 61 - 30).clamp(0, 255);
        b = (b + ((base + 2) * 31) % 61 - 30).clamp(0, 255);
      }
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

void main() {
  const w = 256, h = 192;
  final a = busyFrame(w, h); // 干净（参考）
  final b = busyFrame(w, h, noisy: true); // 加噪（失真）

  final (mse, psnr) = psnrRgba(a, b);
  final ssim = ssimRgba(a, b, w, h);
  final msssim = msssimRgba(a, b, w, h);
  final fsim = fsimRgba(a, b, w, h);
  print('psnr   = $psnr  (mse=$mse)');
  print('ssim   = ${ssim.$1}  (R=${ssim.$2} G=${ssim.$3} B=${ssim.$4})');
  print('msssim = ${msssim.$1}');
  print('fsim   = ${fsim.$1}');
  print('piqe(b)   = ${piqeScore(b, w, h)}');
  print('niqe(b)   = ${niqeScore(b, w, h)}');
  print('brisque(b)= ${brisqueScore(b, w, h)}');
  print('ilniqe(b) = ${ilniqeScore(b, w, h)}');
}
