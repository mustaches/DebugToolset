// 评价函数（PSNR/SSIM/MS-SSIM/FSIM/PIQE/NIQE/BRISQUE）性能基准。
// 运行：dart run scratch/bench_eval.dart
// 帧图案与 test/isp_piqe_test.dart 的 busyFrame 同款（确定性）。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/piqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/brisque.dart';

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

/// 跑 [fn] 至少 [minMs] 毫秒，返回单次平均耗时（毫秒）。
double bench(String name, void Function() fn, {int minMs = 2000}) {
  fn(); // 预热
  var runs = 0;
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < minMs) {
    fn();
    runs++;
  }
  sw.stop();
  final ms = sw.elapsedMicroseconds / 1000.0 / runs;
  return ms;
}

void main(List<String> args) {
  // 尺寸取双输入仪器的典型口径：1080p 源 2x 降采样后的 960x540。
  const w = 960, h = 540;
  final a = busyFrame(w, h);
  final b = busyFrame(w, h, noisy: true);
  final quick = args.contains('--quick');
  final minMs = quick ? 300 : 2000;

  print('帧尺寸 ${w}x$h（busyFrame + 确定性噪声对）');
  final rows = <String, double>{};
  rows['psnrRgba   '] = bench('psnr', () => psnrRgba(a, b), minMs: minMs);
  rows['ssimRgba   '] =
      bench('ssim', () => ssimRgba(a, b, w, h), minMs: minMs);
  rows['msssimRgba '] =
      bench('msssim', () => msssimRgba(a, b, w, h), minMs: minMs);
  rows['fsimRgba   '] =
      bench('fsim', () => fsimRgba(a, b, w, h), minMs: minMs);
  rows['piqeScore  '] = bench('piqe', () => piqeScore(a, w, h), minMs: minMs);
  rows['niqeScore  '] = bench('niqe', () => niqeScore(a, w, h), minMs: minMs);
  rows['brisqueScor'] =
      bench('brisque', () => brisqueScore(a, w, h), minMs: minMs);

  print('函数          平均耗时(ms/次)');
  for (final e in rows.entries) {
    print('${e.key}  ${e.value.toStringAsFixed(2)}');
  }
  // 打印一次结果值，防止优化把循环删掉，也便于核对数值不变。
  final (mse, psnr) = psnrRgba(a, b);
  final ssim = ssimRgba(a, b, w, h);
  final msssim = msssimRgba(a, b, w, h);
  final fsim = fsimRgba(a, b, w, h);
  print('psnr=$psnr mse=$mse');
  print('ssim=${ssim.$1} msssim=${msssim.$1} fsim=${fsim.$1}');
  print('piqe=${piqeScore(a, w, h)} niqe=${niqeScore(a, w, h)} '
      'brisque=${brisqueScore(a, w, h)}');
}
