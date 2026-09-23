/// Dart↔C 对拍：色彩组 1 —— white_balance_apply / white_balance_auto /
/// ccm / tonemap。
///
/// C 侧：test/c_ref/harness_color1.c ->
/// lib/modules/isp_studio/c_ref/isp_white_balance.c / isp_ccm.c / isp_gamma.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart
/// `autoWhiteBalanceGains` / `applyWhiteBalance` / `applyCcm` / `tonemapToRgba`
/// （+ 内部 `_tonemapLut`），均为 kernel 层函数，直接调用作基准。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_color1';

/// Dart 基准：applyWhiteBalance 原地修改，先复制输入。
Uint16List dartWbApply(Uint16List input, double rGain, double bGain,
    {int maxValue = 1023}) {
  final out = Uint16List.fromList(input);
  applyWhiteBalance(out, rGain: rGain, bGain: bGain, maxValue: maxValue);
  return out;
}

/// Dart 基准：applyCcm 原地修改，先复制输入。
Uint16List dartCcmApply(Uint16List input, List<double> matrix,
    {int maxValue = 1023}) {
  final out = Uint16List.fromList(input);
  applyCcm(out, matrix: matrix, maxValue: maxValue);
  return out;
}

/// wb apply 一条龙：写参/跑 C/与 Dart 基准逐位比对。
Future<void> checkWbApply(String context, Uint16List input, int w, int h,
    double rGain, double bGain,
    {int maxValue = 1023}) async {
  final c = await runCOp('white_balance_apply', params: {
    'width': w,
    'height': h,
    'rGain': rGain,
    'bGain': bGain,
    'max_value': maxValue,
  }, inputs: [
    input
  ], tag: _tag);
  expectFramesEqual(
      c.outputs[0], dartWbApply(input, rGain, bGain, maxValue: maxValue),
      context: context);
}

/// wb auto 一条龙：比对 scalars 的 rGain/bGain（double 精确相等：
/// 两边均为 int64 累加 + double 除法，公式一致，无 libm 参与）。
Future<void> checkWbAuto(String context, Uint16List input, int w, int h,
    int sampleStride) async {
  final c = await runCOp('white_balance_auto',
      params: {'width': w, 'height': h, 'sampleStride': sampleStride},
      inputs: [input],
      outputCount: 0,
      tag: _tag);
  final (rGain, bGain) =
      autoWhiteBalanceGains(input, sampleStride: sampleStride);
  expect(c.scalars['rGain'], rGain, reason: '$context: rGain');
  expect(c.scalars['bGain'], bGain, reason: '$context: bGain');
}

/// ccm 一条龙。
Future<void> checkCcm(String context, Uint16List input, int w, int h,
    List<double> matrix,
    {int maxValue = 1023}) async {
  final params = <String, Object?>{
    'width': w,
    'height': h,
    'max_value': maxValue,
  };
  for (var i = 0; i < 9; i++) {
    params['m$i'] = matrix[i];
  }
  final c = await runCOp('ccm', params: params, inputs: [input], tag: _tag);
  expectFramesEqual(
      c.outputs[0], dartCcmApply(input, matrix, maxValue: maxValue),
      context: context);
}

/// tonemap 一条龙：输出为 u8 RGBA 流（rawOutputCount=1 读回）。
/// [tol] 默认 0（逐位相等）；pow 经不同 libm 时允许调用方传 1 并注明理由。
Future<void> checkTonemap(String context, Uint16List input, int w, int h,
    double gamma, double brightness, double contrast,
    {int maxValue = 1023, int tol = 0}) async {
  final c = await runCOp('tonemap', params: {
    'width': w,
    'height': h,
    'max_value': maxValue,
    'gamma': gamma,
    'brightness': brightness,
    'contrast': contrast,
  }, inputs: [
    input
  ], outputCount: 0, rawOutputCount: 1, tag: _tag);
  expectFramesEqual(
      c.rawOutputs[0],
      tonemapToRgba(input,
          maxValue: maxValue,
          gamma: gamma,
          brightness: brightness,
          contrast: contrast),
      context: context,
      tol: tol);
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_color1: white_balance_apply C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    test('64x48 增益 r<1 b>1 组合（小数增益检验 round）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 11, maxValue: 1023);
      await checkWbApply('r0.83 b1.27', input, w, h, 0.83, 1.27);
    });

    test('64x48 增益 r>1 b<1 组合 + 上溢钳位', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 12, maxValue: 1023);
      await checkWbApply('r1.5 b0.6', input, w, h, 1.5, 0.6);
    });

    test('32x24 极端增益（r 上溢成片钳 max、b 下溢近零）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkWbApply('r9.9 b0.01', input, w, h, 9.9, 0.01);
    });

    test('增益恒等 (1.0, 1.0) 空操作分支', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 13, maxValue: 1023);
      await checkWbApply('r1.0 b1.0', input, w, h, 1.0, 1.0);
    });

    test('4x4 小图 + 0/max 角点', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkWbApply('4x4 r1.1 b0.9', input, w, h, 1.1, 0.9);
    });

    test('16x16 maxValue=65535（16 位量级）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 14, maxValue: 65535);
      await checkWbApply('65535 r1.3 b0.7', input, w, h, 1.3, 0.7,
          maxValue: 65535);
    });
  });

  group('isp_c_ref_compare_color1: white_balance_auto C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    test('64x48 默认 stride=16', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 21, maxValue: 1023);
      await checkWbAuto('stride16', input, w, h, 16);
    });

    test('64x48 stride=1（全采样）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 22, maxValue: 1023);
      await checkWbAuto('stride1', input, w, h, 1);
    });

    test('64x48 stride=7（非整除像素数，尾样本覆盖）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 23, maxValue: 1023);
      await checkWbAuto('stride7', input, w, h, 7);
    });

    test('stride 大于像素数（只采首个像素）', () async {
      const w = 8, h = 8;
      final input = lcgFrame(w, h, 3, 24, maxValue: 1023);
      await checkWbAuto('stride9999', input, w, h, 9999);
    });

    test('stride=0 按 1 处理（Dart stride<1 防御分支）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 25, maxValue: 1023);
      await checkWbAuto('stride0', input, w, h, 0);
    });

    test('纯色帧 meanR=0 兜底路径（rGain=1.0，bGain 正常）', () async {
      // R 通道全 0、G/B 非零：meanR=0 触发 rGain 取 1.0 的兜底。
      const w = 32, h = 32;
      final input = Uint16List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        input[i * 3] = 0;
        input[i * 3 + 1] = 500;
        input[i * 3 + 2] = 300;
      }
      await checkWbAuto('meanR=0', input, w, h, 4);
    });

    test('全零帧（meanR=meanB=0，双兜底 rGain=bGain=1.0）', () async {
      const w = 16, h = 16;
      final input = constantFrame(w, h, 3, 0);
      await checkWbAuto('全零帧', input, w, h, 8);
    });
  });

  group('isp_c_ref_compare_color1: ccm C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    test('64x48 恒等阵（定点判断为空操作）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 31, maxValue: 1023);
      await checkCcm('identity', input, w, h,
          [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
    });

    test('64x48 典型校正阵（行和≈1，含小数系数）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 32, maxValue: 1023);
      await checkCcm('典型校正阵', input, w, h, [
        1.35, -0.25, -0.10, //
        -0.15, 1.30, -0.15, //
        -0.05, -0.20, 1.25,
      ]);
    });

    test('32x24 含负系数阵（负中间值检验算术右移 + 下溢钳零）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkCcm('含负系数', input, w, h, [
        1.8, -0.9, 0.1, //
        -0.4, 1.2, 0.2, //
        0.3, -1.1, 1.8,
      ]);
    });

    test('4x4 小图 + 大系数上溢钳 max', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkCcm('4x4 大系数', input, w, h,
          [3.0, 0.5, 0.0, 0.0, 2.5, 0.5, 0.5, 0.0, 3.0]);
    });

    test('16x16 maxValue=65535 + 非二进制友好小数系数（检验定点 round）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 33, maxValue: 65535);
      await checkCcm('65535 小数系数', input, w, h, [
        1.0003, -0.0002, 0.0001, //
        0.0007, 0.9998, -0.0004, //
        -0.0005, 0.0006, 1.0001,
      ], maxValue: 65535);
    });
  });

  group('isp_c_ref_compare_color1: white_balance LUT 查表 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    /// LUT 模式一条龙：Dart 建表（whiteBalanceGainLut）→ 表经输入文件
    /// 传给 C 侧 isp_white_balance_lut_apply，与 Dart 查表基准逐位比对。
    Future<void> checkWbLut(String context, Uint16List input, int w, int h,
        double rGain, double bGain,
        {int maxValue = 1023}) async {
      final lutR = whiteBalanceGainLut(rGain, maxValue);
      final lutB = whiteBalanceGainLut(bGain, maxValue);
      final c = await runCOp('white_balance_lut_apply', params: {
        'width': w,
        'height': h,
        'max_value': maxValue,
      }, inputs: [
        input,
        lutR,
        lutB,
      ], tag: _tag);
      final expected = Uint16List.fromList(input);
      applyWhiteBalanceLut(expected, lutR, lutB);
      expectFramesEqual(c.outputs[0], expected, context: context);
    }

    test('64x48 小数增益（r0.83 b1.27）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 51, maxValue: 1023);
      await checkWbLut('r0.83 b1.27', input, w, h, 0.83, 1.27);
    });

    test('32x24 极端增益（上溢钳位 + 下溢近零）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkWbLut('r9.9 b0.01', input, w, h, 9.9, 0.01);
    });

    test('16x16 maxValue=65535（16 位域表）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 52, maxValue: 65535);
      await checkWbLut('65535 r1.3 b0.7', input, w, h, 1.3, 0.7,
          maxValue: 65535);
    });
  });

  group('isp_c_ref_compare_color1: tonemap C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    test('64x48 gamma=1.0（线性，brightness/contrast 默认）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 41, maxValue: 1023);
      await checkTonemap('gamma1.0', input, w, h, 1.0, 0.0, 1.0);
    });

    test('64x48 gamma=2.2（pow 重路径）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 42, maxValue: 1023);
      await checkTonemap('gamma2.2', input, w, h, 2.2, 0.0, 1.0);
    });

    test('64x48 gamma=0.45（反向伽马）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 43, maxValue: 1023);
      await checkTonemap('gamma0.45', input, w, h, 0.45, 0.0, 1.0);
    });

    test('64x48 brightness/contrast 组合（绕 0.5 对比度 + 钳位）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 44, maxValue: 1023);
      await checkTonemap('b0.1 c1.3 g2.2', input, w, h, 2.2, 0.1, 1.3);
    });

    test('32x24 负亮度 + 低对比度（成片钳 0/1 边界）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkTonemap('b-0.2 c0.5 g1.8', input, w, h, 1.8, -0.2, 0.5);
    });

    test('4x4 小图 + 0/max 角点', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkTonemap('4x4 g2.2', input, w, h, 2.2, 0.05, 1.1);
    });

    test('输入超 maxValue 的像素钳上界后查表', () async {
      // 手工构造含 > maxValue 像素的帧（lcgFrame 不会超出值域）。
      const w = 8, h = 8;
      final input = lcgFrame(w, h, 3, 45, maxValue: 1023);
      input[0] = 2000; // r 超界
      input[5] = 4095; // b 超界
      input[7] = 1024; // g 恰超 1
      await checkTonemap('超界钳位', input, w, h, 2.2, 0.0, 1.0);
    });

    test('8x8 maxValue=255（小 LUT）', () async {
      const w = 8, h = 8;
      final input = lcgFrame(w, h, 3, 46, maxValue: 255);
      await checkTonemap('max255', input, w, h, 2.2, 0.0, 1.0,
          maxValue: 255);
    });

    test('16x16 maxValue=65535（64KB LUT）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 47, maxValue: 65535);
      await checkTonemap('65535 g2.2', input, w, h, 2.2, 0.0, 1.0,
          maxValue: 65535);
    });
  });
}
