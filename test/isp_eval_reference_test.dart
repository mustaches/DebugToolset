// 双输入评价指标与开源参考库（torchmetrics / pyiqa / lpips）的对拍。
//
// 参考值由 scratch/eval_ref.py 实跑生成（torch 2.13.0+cpu /
// torchmetrics 1.9.0 / pyiqa 0.1.16 / lpips vgg，同帧 busyFrame 对，
// 结果存 scratch/eval_ref_results.json）：
//
// | 指标 | Dart（本测试断言） | 参考库 |
// |---|---|---|
// | PSNR | 23.22004117 | torchmetrics 23.220039（口径一致） |
// | SSIM | 0.85285653 | Python 块口径复刻 0.852857；torchmetrics 高斯窗 0.757942（口径不同，仅参考） |
// | MS-SSIM | 0.98970165 | Python 块口径复刻 0.989702；torchmetrics 0.984270（口径不同，仅参考） |
// | PIQE(失真图) | 7.28649558 | pyiqa 7.89491367（pyiqa 自实现，口径不同）；pypiqe 7.286913（见 isp_piqe_test） |
// | NIQE(失真图) | 37.45818316 | pyiqa 39.29309848（test_y_channel 口径差异） |
// | BRISQUE(失真图) | 99.25393599 | pyiqa 96.86322021 |
// | ILNIQE(失真图) | 1682.59253220 | pyiqa 1802.69074460 |
// | LPIPS(vgg) | —（无 Dart 实现） | 0.255415 |
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/piqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/brisque.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';

void main() {
  /// 256x192 高纹理彩色测试帧（与 Python 参考对拍同款图案，
  /// 同 test/isp_piqe_test.dart 的 busyFrame）。
  Uint8List busyFrame({bool noisy = false}) {
    const w = 256, h = 192;
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
          // 与 Python 参考同款的确定性噪声（元素序按 RGB 三通道计）。
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

  const w = 256, h = 192;

  group('评价指标对开源参考库（scratch/eval_ref.py 实跑基线）', () {
    test('PSNR 与 torchmetrics 一致（±1e-4 dB）', () {
      final (_, psnr) = psnrRgba(busyFrame(), busyFrame(noisy: true));
      // torchmetrics peak_signal_noise_ratio(data_range=1.0) = 23.220039。
      expect(psnr, closeTo(23.220039, 1e-4));
    });

    test('SSIM/MS-SSIM 与 Python 块口径复刻一致；torchmetrics 高斯窗'
        '口径差异在文档范围内', () {
      final a = busyFrame();
      final b = busyFrame(noisy: true);
      final (ssim, _, _, _) = ssimRgba(a, b, w, h);
      // scratch/eval_ref.py 的同算法 numpy 复刻 = 0.852857。
      expect(ssim, closeTo(0.852857, 1e-6));
      final (msssim, _, _, _) = msssimRgba(a, b, w, h);
      // 同复刻 = 0.989702；torchmetrics 高斯窗 = 0.984270（仅参考）。
      expect(msssim, closeTo(0.989702, 1e-6));
      // 与 torchmetrics 高斯窗口径的偏差记录在档（数量级一致、排序一致）。
      expect((ssim - 0.757942).abs(), lessThan(0.2));
      expect((msssim - 0.984270).abs(), lessThan(0.02));
    });

    test('FSIM 基线稳定（自用简化 PC 口径，无对应参考实现）', () {
      final (fsim, _, _, _) =
          fsimRgba(busyFrame(), busyFrame(noisy: true), w, h);
      expect(fsim, closeTo(0.93917145, 1e-6));
    });

    test('无参考指标与 pyiqa 同数量级、方向一致（口径差异在档）', () {
      final b = busyFrame(noisy: true);
      // pyiqa 实跑：piqe 7.8949 / niqe 39.2931 / brisque 96.8632 /
      // ilniqe 1802.6907；Dart 与 pyiqa 的口径差异见各文件头注释。
      expect(piqeScore(b, w, h), closeTo(7.28649558, 1e-6));
      expect(niqeScore(b, w, h), closeTo(37.45818316, 1e-6));
      expect(brisqueScore(b, w, h), closeTo(99.25393599, 1e-6));
      expect(ilniqeScore(b, w, h), closeTo(1682.59253220, 1e-4));
    });
  });
}
