import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/demosaic_advanced.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';

/// 高级去马赛克算法统一签名（与 5 个 demosaicXxx 的 tear-off 匹配）。
typedef _DemosaicFn = Uint16List Function(Uint16List,
    {required int width,
    required int height,
    required BayerPattern pattern,
    int maxValue});

const _algos = <String, _DemosaicFn>{
  'mhc': demosaicMhc,
  'aahd': demosaicAahd,
  'amaze': demosaicAmaze,
  'lmmse': demosaicLmmse,
  'igv': demosaicIgv,
};

/// 按真值函数 [truth]（返回 [r, g, b]）采样 w*h Bayer 马赛克。
Uint16List mosaic(int width, int height, BayerPattern pattern,
    List<int> Function(int x, int y) truth) {
  final b = Uint16List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      b[y * width + x] = truth(x, y)[pattern.colorAt(x, y)];
    }
  }
  return b;
}

void main() {
  group('高级去马赛克算法', () {
    for (final entry in _algos.entries) {
      group(entry.key, () {
        for (final pattern in [BayerPattern.rggb, BayerPattern.bggr]) {
          test('纯色帧输出严格等于原色（${pattern.name}）', () {
            // 强不变量：恒定色场任何插值都必须原样还原。
            const truth = [200, 100, 50];
            final b = mosaic(16, 16, pattern, (x, y) => truth);
            final rgb = entry.value(b,
                width: 16, height: 16, pattern: pattern, maxValue: 255);
            for (var p = 0; p < 16 * 16; p++) {
              expect(
                  [rgb[p * 3], rgb[p * 3 + 1], rgb[p * 3 + 2]], truth,
                  reason: 'pixel $p');
            }
          });
        }

        test('平滑水平渐变（灰度二次曲面）内部误差 ≤4', () {
          // v = 20 + 0.9x²（20..223）：含曲率的平滑渐变。
          // 只断言 3 环以内（高级算法有效区）：梯度校正类算法内部最大
          // 理论误差约 1~2 码值，容差取 4；边界环回退双线性，在陡渐变
          // 的右/下边缘存在固有的截断误差（缺失外侧邻居），不在此断言。
          int v(int x) => (20 + x * x * 0.9).round();
          final b = mosaic(
              16, 16, BayerPattern.rggb, (x, y) => [v(x), v(x), v(x)]);
          final rgb = entry.value(b,
              width: 16,
              height: 16,
              pattern: BayerPattern.rggb,
              maxValue: 255);
          for (var y = 3; y < 13; y++) {
            for (var x = 3; x < 13; x++) {
              final i = (y * 16 + x) * 3;
              for (var c = 0; c < 3; c++) {
                expect((rgb[i + c] - v(x)).abs(), lessThanOrEqualTo(4),
                    reason: '($x,$y) ch$c');
              }
            }
          }
        });

        test('高频竖条纹：输出不越界（0..maxValue）', () {
          // 30/225 交替列是奈奎斯特极限的高频输入，只要求不崩、不越界。
          final b = mosaic(16, 16, BayerPattern.rggb,
              (x, y) => x.isEven ? [30, 30, 30] : [225, 225, 225]);
          final rgb = entry.value(b,
              width: 16,
              height: 16,
              pattern: BayerPattern.rggb,
              maxValue: 255);
          expect(rgb, hasLength(16 * 16 * 3));
          for (final v in rgb) {
            expect(v, inInclusiveRange(0, 255));
          }
        });
      });
    }
  });
}
