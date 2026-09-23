/// Dart↔C 对拍：RAW 域组 1 —— dpc / lsc / grgb_balance。
///
/// C 侧：test/c_ref/harness_raw1.c `op_dpc` / `op_lsc` / `op_grgb_balance` ->
/// lib/modules/isp_studio/c_ref/isp_dpc.c / isp_lsc.c / isp_grgb_balance.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart
/// `applyDpc` / `applyLsc` / `applyGrGbBalance`（语义都在 kernel 层，
/// 直接调真实实现作基准）。
///
/// params 约定（与 harness_raw1.c 文件头一致）：pattern 为 int，
/// -1 = mono，0..3 = rggb/bggr/grbg/gbrg（与 BayerPattern 枚举序号一致）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const _tag = '_grp_raw1';

/// BayerPattern 枚举序号 -> 枚举值（与 params 的 0..3 对应）。
BayerPattern? _patternOf(int pat) => pat < 0 ? null : BayerPattern.values[pat];

/// Dart 侧 dpc 基准（原地修改，故先复制输入）。
Uint16List dartDpc(Uint16List input, int width, int height, int pattern,
    double threshold, String mode, int maxValue) {
  final out = Uint16List.fromList(input);
  applyDpc(out,
      width: width,
      height: height,
      pattern: _patternOf(pattern),
      threshold: threshold,
      mode: mode,
      maxValue: maxValue);
  return out;
}

/// Dart 侧 lsc 基准（applyLsc 的 pattern 形参未被函数体使用，直接透传）。
Uint16List dartLsc(Uint16List input, int width, int height, int pattern,
    double strength, double centerX, double centerY, int maxValue) {
  final out = Uint16List.fromList(input);
  applyLsc(out,
      width: width,
      height: height,
      pattern: _patternOf(pattern),
      strength: strength,
      centerX: centerX,
      centerY: centerY,
      maxValue: maxValue);
  return out;
}

/// Dart 侧 grgb_balance 基准（pattern 必选）。
Uint16List dartGrGbBalance(
    Uint16List input, int width, int height, int pattern, double strength) {
  final out = Uint16List.fromList(input);
  applyGrGbBalance(out,
      width: width,
      height: height,
      pattern: BayerPattern.values[pattern],
      strength: strength);
  return out;
}

/// 在 LCG 帧上打人造坏点：同相位网格内的若干位置打成 maxValue / 0 脉冲。
/// [step] 取 2（Bayer 同相位间距）保证坏点落在同一相位网格内可被邻域
/// 中位数检测；mono 用例同样适用（±1 邻域覆盖 ±2 距离）。
Uint16List frameWithDeadPixels(int width, int height, int seed,
    {int maxValue = 1023, int step = 2}) {
  final f = lcgFrame(width, height, 1, seed, maxValue: maxValue);
  final spots = <(int, int, int)>[
    (step * 3, step * 3, maxValue), // 亮点
    (step * 5, step * 2, 0), // 暗点
    (step * 2, step * 5, maxValue),
    (width - step * 2, height - step * 2, 0), // 靠近右下角
    (step * 4, step * 4, maxValue), // 与相邻坏点构成坏点簇
    (step * 4, step * 6, 0),
  ];
  for (final (x, y, v) in spots) {
    if (x < width && y < height) f[y * width + x] = v;
  }
  return f;
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_raw1: dpc / lsc / grgb_balance C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ---------------------------------------------------------------- dpc
    test('dpc 64x48 RGGB median 含人造坏点', () async {
      const w = 64, h = 48, pat = 0, maxV = 1023;
      final input = frameWithDeadPixels(w, h, 11, maxValue: maxV);
      final c = await runCOp('dpc', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'threshold': 5.0,
        'mode': 'median',
        'max_value': maxV,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartDpc(input, w, h, pat, 5.0, 'median', maxV),
          context: 'dpc rggb median');
    });

    test('dpc 64x48 RGGB directional 含人造坏点', () async {
      const w = 64, h = 48, pat = 0, maxV = 1023;
      final input = frameWithDeadPixels(w, h, 12, maxValue: maxV);
      final c = await runCOp('dpc', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'threshold': 5.0,
        'mode': 'directional',
        'max_value': maxV,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartDpc(input, w, h, pat, 5.0, 'directional', maxV),
          context: 'dpc rggb directional');
    });

    test('dpc 64x48 mono 两模式（pattern=-1，±1 邻域）', () async {
      const w = 64, h = 48, pat = -1, maxV = 1023;
      final input = frameWithDeadPixels(w, h, 13, maxValue: maxV);
      for (final mode in ['median', 'directional']) {
        final c = await runCOp('dpc', params: {
          'width': w,
          'height': h,
          'pattern': pat,
          'threshold': 8.0,
          'mode': mode,
          'max_value': maxV,
        }, inputs: [
          input
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0], dartDpc(input, w, h, pat, 8.0, mode, maxV),
            context: 'dpc mono $mode');
      }
    });

    test('dpc 32x24 GBRG threshold=0 全量替换 + directional 方向平局', () async {
      // threshold=0 -> thr=0，凡与邻域中位数不等的像素全部替换，
      // 高强度触发 directional 分支（含 (va+vb+1)>>1 半值向上）。
      const w = 32, h = 24, pat = 3, maxV = 1023;
      final input = lcgFrame(w, h, 1, 14, maxValue: maxV);
      for (final mode in ['median', 'directional']) {
        final c = await runCOp('dpc', params: {
          'width': w,
          'height': h,
          'pattern': pat,
          'threshold': 0.0,
          'mode': mode,
          'max_value': maxV,
        }, inputs: [
          input
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0], dartDpc(input, w, h, pat, 0.0, mode, maxV),
            context: 'dpc gbrg thr0 $mode');
      }
    });

    test('dpc 3x3 / 4x4 小图边界（角落坏点、邻域裁剪）', () async {
      const maxV = 1023;
      // 3x3 Bayer：同相位邻域仅剩角落裁剪后的少数点；中心 (1,1) 打坏点。
      final in3 = gradientFrame(3, 3, 1, maxValue: maxV);
      in3[1 * 3 + 1] = maxV;
      final c3 = await runCOp('dpc', params: {
        'width': 3,
        'height': 3,
        'pattern': 0,
        'threshold': 2.0,
        'mode': 'median',
        'max_value': maxV,
      }, inputs: [
        in3
      ], tag: _tag);
      expectFramesEqual(c3.outputs[0], dartDpc(in3, 3, 3, 0, 2.0, 'median', maxV),
          context: 'dpc 3x3 rggb');

      // 4x4 mono directional：角落像素两方向越界，检验方向枚举与回退 med。
      final in4 = gradientFrame(4, 4, 1, maxValue: maxV);
      in4[0] = 0; // 左上角已为 0；再制造离群
      in4[2 * 4 + 2] = maxV;
      final c4 = await runCOp('dpc', params: {
        'width': 4,
        'height': 4,
        'pattern': -1,
        'threshold': 1.0,
        'mode': 'directional',
        'max_value': maxV,
      }, inputs: [
        in4
      ], tag: _tag);
      expectFramesEqual(
          c4.outputs[0], dartDpc(in4, 4, 4, -1, 1.0, 'directional', maxV),
          context: 'dpc 4x4 mono directional');
    });

    test('dpc 64x48 BGGR 16 位量级（maxValue=65535）', () async {
      const w = 64, h = 48, pat = 1, maxV = 65535;
      final input = frameWithDeadPixels(w, h, 15, maxValue: maxV);
      final c = await runCOp('dpc', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'threshold': 3.0,
        'mode': 'directional',
        'max_value': maxV,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartDpc(input, w, h, pat, 3.0, 'directional', maxV),
          context: 'dpc bggr 65535');
    });

    // ---------------------------------------------------------------- lsc
    test('lsc 64x48 mono 居中 strength=0.5', () async {
      const w = 64, h = 48, maxV = 1023;
      final input = lcgFrame(w, h, 1, 21, maxValue: maxV);
      final c = await runCOp('lsc', params: {
        'width': w,
        'height': h,
        'pattern': -1,
        'strength': 0.5,
        'centerX': 0.5,
        'centerY': 0.5,
        'max_value': maxV,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartLsc(input, w, h, -1, 0.5, 0.5, 0.5, maxV),
          context: 'lsc mono 居中');
    });

    test('lsc 64x48 RGGB 偏心 (0.3, 0.7) strength=1.2 含饱和截位', () async {
      // gradientFrame 四角强制 0/maxValue，大 strength 下边缘增益
      // 1+1.2=2.2 倍，触发 maxValue 饱和截位。
      const w = 64, h = 48, maxV = 1023;
      final input = gradientFrame(w, h, 1, maxValue: maxV);
      final c = await runCOp('lsc', params: {
        'width': w,
        'height': h,
        'pattern': 0,
        'strength': 1.2,
        'centerX': 0.3,
        'centerY': 0.7,
        'max_value': maxV,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartLsc(input, w, h, 0, 1.2, 0.3, 0.7, maxV),
          context: 'lsc 偏心饱和');
    });

    test('lsc 32x24 负 strength 与越界中心', () async {
      // 负强度中心亮边缘暗；中心越界 (1.5, -0.2) Dart 未禁止，照常计算。
      const w = 32, h = 24, maxV = 1023;
      final input = lcgFrame(w, h, 1, 23, maxValue: maxV);
      for (final (s, cx, cy) in [(-0.3, 0.5, 0.5), (0.8, 1.5, -0.2)]) {
        final c = await runCOp('lsc', params: {
          'width': w,
          'height': h,
          'pattern': 2,
          'strength': s,
          'centerX': cx,
          'centerY': cy,
          'max_value': maxV,
        }, inputs: [
          input
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0], dartLsc(input, w, h, 2, s, cx, cy, maxV),
            context: 'lsc s=$s c=($cx,$cy)');
      }
    });

    test('lsc 小图边界 3x3 / 4x4 + strength=0 恒等 + 16 位量级', () async {
      // 3x3 角心：cx/cy 恰为整数像素坐标。
      const maxV = 1023;
      final in3 = gradientFrame(3, 3, 1, maxValue: maxV);
      final c3 = await runCOp('lsc', params: {
        'width': 3,
        'height': 3,
        'pattern': -1,
        'strength': 0.9,
        'centerX': 0.0,
        'centerY': 1.0,
        'max_value': maxV,
      }, inputs: [
        in3
      ], tag: _tag);
      expectFramesEqual(
          c3.outputs[0], dartLsc(in3, 3, 3, -1, 0.9, 0.0, 1.0, maxV),
          context: 'lsc 3x3 左下角心');

      // strength=0：C/Dart 均为精确 double 比较直接返回（恒等）。
      final in4 = lcgFrame(4, 4, 1, 24, maxValue: maxV);
      final c4 = await runCOp('lsc', params: {
        'width': 4,
        'height': 4,
        'pattern': 0,
        'strength': 0.0,
        'centerX': 0.5,
        'centerY': 0.5,
        'max_value': maxV,
      }, inputs: [
        in4
      ], tag: _tag);
      expectFramesEqual(
          c4.outputs[0], dartLsc(in4, 4, 4, 0, 0.0, 0.5, 0.5, maxV),
          context: 'lsc strength=0 恒等');

      // 16 位量级：增益路径纯 double 乘除，无 libm，应逐位一致。
      const maxV16 = 65535;
      final in16 = lcgFrame(16, 16, 1, 25, maxValue: maxV16);
      final c16 = await runCOp('lsc', params: {
        'width': 16,
        'height': 16,
        'pattern': -1,
        'strength': 0.7,
        'centerX': 0.25,
        'centerY': 0.75,
        'max_value': maxV16,
      }, inputs: [
        in16
      ], tag: _tag);
      expectFramesEqual(
          c16.outputs[0], dartLsc(in16, 16, 16, -1, 0.7, 0.25, 0.75, maxV16),
          context: 'lsc 16x16 65535');
    });

    // ------------------------------------------------------- grgb_balance
    test('grgb_balance 64x48 RGGB strength=1.0 完全收敛', () async {
      const w = 64, h = 48, pat = 0;
      final input = lcgFrame(w, h, 1, 31, maxValue: 1023);
      final c = await runCOp('grgb_balance', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'strength': 1.0,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartGrGbBalance(input, w, h, pat, 1.0),
          context: 'grgb rggb s=1.0');
    });

    test('grgb_balance 64x48 BGGR strength=0.5 部分收敛', () async {
      const w = 64, h = 48, pat = 1;
      final input = lcgFrame(w, h, 1, 32, maxValue: 1023);
      final c = await runCOp('grgb_balance', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'strength': 0.5,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartGrGbBalance(input, w, h, pat, 0.5),
          context: 'grgb bggr s=0.5');
    });

    test('grgb_balance strength 边界 0 / 负值恒等、>1 过冲', () async {
      const w = 32, h = 24, pat = 2; // grbg
      final input = lcgFrame(w, h, 1, 33, maxValue: 1023);
      for (final s in [0.0, -0.5, 1.5]) {
        final c = await runCOp('grgb_balance', params: {
          'width': w,
          'height': h,
          'pattern': pat,
          'strength': s,
        }, inputs: [
          input
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0], dartGrGbBalance(input, w, h, pat, s),
            context: 'grbg s=$s');
      }
    });

    test('grgb_balance 均值<=0 边界：全 0 帧 / 单相位全 0 帧不修改', () async {
      const w = 16, h = 16, pat = 0;
      // 全 0：meanGr/meanGb == 0，直接返回（不修改）。
      final zero = constantFrame(w, h, 1, 0);
      final cz = await runCOp('grgb_balance', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'strength': 1.0,
      }, inputs: [
        zero
      ], tag: _tag);
      expectFramesEqual(cz.outputs[0], dartGrGbBalance(zero, w, h, pat, 1.0),
          context: 'grgb 全 0');

      // 仅 Gb 相位全 0、其余正常：meanGb=0 -> 不修改。
      final half = lcgFrame(w, h, 1, 34, maxValue: 1023);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = BayerPattern.values[pat];
          if (p.colorAt(x, y) == 1 && p.colorAt(x ^ 1, y) != 0) {
            half[y * w + x] = 0; // Gb 相位清零
          }
        }
      }
      final ch = await runCOp('grgb_balance', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'strength': 1.0,
      }, inputs: [
        half
      ], tag: _tag);
      expectFramesEqual(ch.outputs[0], dartGrGbBalance(half, w, h, pat, 1.0),
          context: 'grgb Gb 全 0');
    });

    test('grgb_balance 小图边界 4x4 / 2x2 / 2x1（计数为 0 早退）', () async {
      // 4x4 gbrg：最小的双 G 相位完整图。
      final in4 = gradientFrame(4, 4, 1, maxValue: 1023);
      final c4 = await runCOp('grgb_balance', params: {
        'width': 4,
        'height': 4,
        'pattern': 3,
        'strength': 0.8,
      }, inputs: [
        in4
      ], tag: _tag);
      expectFramesEqual(c4.outputs[0], dartGrGbBalance(in4, 4, 4, 3, 0.8),
          context: 'grgb 4x4 gbrg');

      // 2x2 rggb：Gr/Gb 各 1 个样本，均值即样本值。
      final in2 = gradientFrame(2, 2, 1, maxValue: 1023);
      final c2 = await runCOp('grgb_balance', params: {
        'width': 2,
        'height': 2,
        'pattern': 0,
        'strength': 1.0,
      }, inputs: [
        in2
      ], tag: _tag);
      expectFramesEqual(c2.outputs[0], dartGrGbBalance(in2, 2, 2, 0, 1.0),
          context: 'grgb 2x2');

      // 2x1：单行只有一个 G 相位，cntGb=0 -> 不修改。
      final in21 = lcgFrame(2, 1, 1, 35, maxValue: 1023);
      final c21 = await runCOp('grgb_balance', params: {
        'width': 2,
        'height': 1,
        'pattern': 0,
        'strength': 1.0,
      }, inputs: [
        in21
      ], tag: _tag);
      expectFramesEqual(c21.outputs[0], dartGrGbBalance(in21, 2, 1, 0, 1.0),
          context: 'grgb 2x1 计数为 0');
    });

    test('grgb_balance 16 位量级 65535 饱和截位', () async {
      // strength=1.5 过冲 + 大值域，G 相位均值差异大时 v*gain 可超 65535，
      // 检验固定钳位 65535（Dart 固定值，不随 max_value）。
      const w = 32, h = 24, pat = 0;
      final input = lcgFrame(w, h, 1, 36, maxValue: 65535);
      // 拉大两 G 相位均值差：Gb 相位压到很小。
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = BayerPattern.values[pat];
          if (p.colorAt(x, y) == 1 && p.colorAt(x ^ 1, y) != 0) {
            input[y * w + x] = 1 + (input[y * w + x] & 0xFF);
          }
        }
      }
      final c = await runCOp('grgb_balance', params: {
        'width': w,
        'height': h,
        'pattern': pat,
        'strength': 1.5,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartGrGbBalance(input, w, h, pat, 1.5),
          context: 'grgb 65535 饱和');
    });
  });
}
