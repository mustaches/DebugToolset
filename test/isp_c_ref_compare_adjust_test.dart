/// Dart↔C 对拍：调节器组 —— adjust_hsl / adjust_rgb / adjust_yuv /
/// adjust_satbright / adjust_brightcontrast / adjust_colorbalance /
/// color_controller。
///
/// C 侧：test/c_ref/harness_adjust.c -> lib/modules/isp_studio/c_ref/
/// isp_adjust.c 与 isp_color_controller.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart 的
/// adjustHsl / adjustRgb / adjustYuv / adjustSatBright /
/// adjustBrightContrast / applyColorBalance / adjustHslBand。
///
/// 说明：
/// - YUV/HSL 输入帧由 Dart 侧从同一 RGB 帧经 rgbToYuv / rgbToHsl 生成，
///   保证 C/Dart 两侧输入逐位一致（转换核本身由 csc 组对拍覆盖）。
/// - brightcontrast 的 mono 语义就在 kernel adjustBrightContrast 的
///   'mono' 分支内（pipeline_runner.dart case 'bright_contrast_adjuster'
///   只做 mono8 轨道物化，不改变数值语义），故基准直接调 kernel。
/// - color_controller 的 C 实现原用 181 项整数度高斯 LUT + 线性插值，
///   对拍发现插值误差成片（q=8 时约 2% 元素差 ±1/±2），已将 C 侧修为
///   逐像素直接计算 exp（与 Dart adjustHslBandRows 同一表达式），
///   全部用例 tol=0 逐位一致（见 isp_color_controller.c 文件头注释）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_adjust';
const int _max = 1023;

/// 从同一 RGB 帧派生 HSL 输入帧。
Uint16List hslFromRgb(Uint16List rgb, int maxValue) =>
    rgbToHsl(rgb, maxValue: maxValue);

/// 从同一 RGB 帧派生 YUV 输入帧。
Uint16List yuvFromRgb(Uint16List rgb, int maxValue) =>
    rgbToYuv(rgb, maxValue: maxValue);

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_adjust: 增益 LUT 查表 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    /// LUT 模式一条龙：Dart adjustGainLut 建表 → 表经输入文件传给 C 侧
    /// isp_adjust_lut3_apply，与 Dart applyAdjustLut3 基准逐位比对。
    Future<void> checkLut3(String context, Uint16List input, int w, int h,
        double rGain, double gGain, double bGain,
        {int maxValue = 1023}) async {
      final lutR = adjustGainLut(rGain, maxValue);
      final lutG = adjustGainLut(gGain, maxValue);
      final lutB = adjustGainLut(bGain, maxValue);
      final c = await runCOp('adjust_lut3_apply', params: {
        'width': w,
        'height': h,
        'max_value': maxValue,
      }, inputs: [
        input,
        lutR,
        lutG,
        lutB,
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], applyAdjustLut3(input, lutR, lutG, lutB),
          context: context);
    }

    test('64x48 三通道不同小数增益', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 61, maxValue: 1023);
      await checkLut3('r1.2 g0.9 b1.05', input, w, h, 1.2, 0.9, 1.05);
    });

    test('32x24 上溢钳位（r3.0 g2.5 b0.1）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkLut3('r3.0 g2.5 b0.1', input, w, h, 3.0, 2.5, 0.1);
    });

    test('16x16 maxValue=65535（16 位域表）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 62, maxValue: 65535);
      await checkLut3('65535 r0.8 g1.1 b1.3', input, w, h, 0.8, 1.1, 1.3,
          maxValue: 65535);
    });
  });

  group('isp_c_ref_compare_adjust: 调节器组 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ------------------------------------------------------------------
    // adjust_hsl
    // ------------------------------------------------------------------
    test('adjust_hsl 64x48 正向偏移+增益', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 11, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const hShift = 30.0, sGain = 1.25, lGain = 0.8;
      final c = await runCOp('adjust_hsl', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'hShiftDeg': hShift,
        'sGain': sGain,
        'lGain': lGain,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustHsl(hsl,
              maxValue: _max, hShiftDeg: hShift, sGain: sGain, lGain: lGain),
          context: 'adjust_hsl 正向');
    });

    test('adjust_hsl 64x48 负偏移验证色环环绕', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 12, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const hShift = -120.0, sGain = 0.5, lGain = 1.5;
      final c = await runCOp('adjust_hsl', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'hShiftDeg': hShift,
        'sGain': sGain,
        'lGain': lGain,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustHsl(hsl,
              maxValue: _max, hShiftDeg: hShift, sGain: sGain, lGain: lGain),
          context: 'adjust_hsl 负偏移环绕');
    });

    test('adjust_hsl 恒等参数直通', () async {
      const w = 32, h = 24;
      final rgb = lcgFrame(w, h, 3, 13, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      final c = await runCOp('adjust_hsl', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'hShiftDeg': 0.0,
        'sGain': 1.0,
        'lGain': 1.0,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], hsl, context: 'adjust_hsl 恒等直通');
    });

    test('adjust_hsl 4x4 小图边界 + 大负偏移 16bit 量级', () async {
      const w = 4, h = 4, mv = 65535;
      final rgb = gradientFrame(w, h, 3, maxValue: mv);
      final hsl = hslFromRgb(rgb, mv);
      const hShift = -700.0, sGain = 2.0, lGain = 0.25;
      final c = await runCOp('adjust_hsl', params: {
        'width': w,
        'height': h,
        'max_value': mv,
        'hShiftDeg': hShift,
        'sGain': sGain,
        'lGain': lGain,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustHsl(hsl,
              maxValue: mv, hShiftDeg: hShift, sGain: sGain, lGain: lGain),
          context: 'adjust_hsl 4x4 16bit');
    });

    // ------------------------------------------------------------------
    // adjust_rgb
    // ------------------------------------------------------------------
    test('adjust_rgb 64x48 三通道不同增益', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 21, maxValue: _max);
      const rG = 1.2, gG = 0.8, bG = 1.5;
      final c = await runCOp('adjust_rgb', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'rGain': rG,
        'gGain': gG,
        'bGain': bG,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustRgb(rgb, maxValue: _max, rGain: rG, gGain: gG, bGain: bG),
          context: 'adjust_rgb 三增益');
    });

    test('adjust_rgb 64x48 过增益钳顶 + 零增益清零', () async {
      const w = 64, h = 48;
      final rgb = gradientFrame(w, h, 3, maxValue: _max);
      const rG = 3.0, gG = 0.0, bG = 0.5;
      final c = await runCOp('adjust_rgb', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'rGain': rG,
        'gGain': gG,
        'bGain': bG,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustRgb(rgb, maxValue: _max, rGain: rG, gGain: gG, bGain: bG),
          context: 'adjust_rgb 钳顶/清零');
    });

    test('adjust_rgb 恒等参数直通', () async {
      const w = 16, h = 16;
      final rgb = lcgFrame(w, h, 3, 23, maxValue: _max);
      final c = await runCOp('adjust_rgb', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'rGain': 1.0,
        'gGain': 1.0,
        'bGain': 1.0,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], rgb, context: 'adjust_rgb 恒等直通');
    });

    test('adjust_rgb 8x8 小图 16bit 量级', () async {
      const w = 8, h = 8, mv = 65535;
      final rgb = lcgFrame(w, h, 3, 24, maxValue: mv);
      const rG = 0.333, gG = 1.75, bG = 2.5;
      final c = await runCOp('adjust_rgb', params: {
        'width': w,
        'height': h,
        'max_value': mv,
        'rGain': rG,
        'gGain': gG,
        'bGain': bG,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustRgb(rgb, maxValue: mv, rGain: rG, gGain: gG, bGain: bG),
          context: 'adjust_rgb 16bit');
    });

    // ------------------------------------------------------------------
    // adjust_yuv
    // ------------------------------------------------------------------
    test('adjust_yuv 64x48 三增益（色度绕中点）', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 31, maxValue: _max);
      final yuv = yuvFromRgb(rgb, _max);
      const yG = 1.2, uG = 0.5, vG = 1.5;
      final c = await runCOp('adjust_yuv', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'yGain': yG,
        'uGain': uG,
        'vGain': vG,
      }, inputs: [
        yuv
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustYuv(yuv, maxValue: _max, yGain: yG, uGain: uG, vGain: vG),
          context: 'adjust_yuv 三增益');
    });

    test('adjust_yuv 64x48 负色度增益（绕中点翻转）', () async {
      const w = 64, h = 48;
      final rgb = gradientFrame(w, h, 3, maxValue: _max);
      final yuv = yuvFromRgb(rgb, _max);
      const yG = 0.7, uG = -0.5, vG = 2.0;
      final c = await runCOp('adjust_yuv', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'yGain': yG,
        'uGain': uG,
        'vGain': vG,
      }, inputs: [
        yuv
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustYuv(yuv, maxValue: _max, yGain: yG, uGain: uG, vGain: vG),
          context: 'adjust_yuv 负色度增益');
    });

    test('adjust_yuv 恒等参数直通', () async {
      const w = 16, h = 16;
      final rgb = lcgFrame(w, h, 3, 33, maxValue: _max);
      final yuv = yuvFromRgb(rgb, _max);
      final c = await runCOp('adjust_yuv', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'yGain': 1.0,
        'uGain': 1.0,
        'vGain': 1.0,
      }, inputs: [
        yuv
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], yuv, context: 'adjust_yuv 恒等直通');
    });

    // ------------------------------------------------------------------
    // adjust_satbright
    // ------------------------------------------------------------------
    test('adjust_satbright rgb 64x48 饱和度+亮度', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 41, maxValue: _max);
      const sat = 1.5, bright = 0.9;
      final c = await runCOp('adjust_satbright', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'satGain': sat,
        'brightGain': bright,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustSatBright(rgb,
              format: 'rgb', maxValue: _max, satGain: sat, brightGain: bright),
          context: 'satbright rgb');
    });

    test('adjust_satbright rgb 64x48 去饱和（sat=0）', () async {
      const w = 64, h = 48;
      final rgb = gradientFrame(w, h, 3, maxValue: _max);
      const sat = 0.0, bright = 1.2;
      final c = await runCOp('adjust_satbright', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'satGain': sat,
        'brightGain': bright,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustSatBright(rgb,
              format: 'rgb', maxValue: _max, satGain: sat, brightGain: bright),
          context: 'satbright rgb sat=0');
    });

    test('adjust_satbright yuv 64x48', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 43, maxValue: _max);
      final yuv = yuvFromRgb(rgb, _max);
      const sat = 0.4, bright = 1.3;
      final c = await runCOp('adjust_satbright', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'yuv',
        'satGain': sat,
        'brightGain': bright,
      }, inputs: [
        yuv
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustSatBright(yuv,
              format: 'yuv', maxValue: _max, satGain: sat, brightGain: bright),
          context: 'satbright yuv');
    });

    test('adjust_satbright hsl 64x48', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 44, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const sat = 2.0, bright = 0.6;
      final c = await runCOp('adjust_satbright', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'hsl',
        'satGain': sat,
        'brightGain': bright,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustSatBright(hsl,
              format: 'hsl', maxValue: _max, satGain: sat, brightGain: bright),
          context: 'satbright hsl');
    });

    test('adjust_satbright 恒等参数直通（rgb）', () async {
      const w = 16, h = 16;
      final rgb = lcgFrame(w, h, 3, 45, maxValue: _max);
      final c = await runCOp('adjust_satbright', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'satGain': 1.0,
        'brightGain': 1.0,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], rgb, context: 'satbright 恒等直通');
    });

    // ------------------------------------------------------------------
    // adjust_brightcontrast
    // ------------------------------------------------------------------
    test('adjust_brightcontrast rgb 64x48（含纯黑像素保持）', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 51, maxValue: _max);
      // 强制若干纯黑像素覆盖 y<=0 保持分支。
      rgb[0] = 0;
      rgb[1] = 0;
      rgb[2] = 0;
      const bp = 120.0, base = 50.0, gp = 140.0;
      final c = await runCOp('adjust_brightcontrast', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'brightPct': bp,
        'baselinePct': base,
        'gainPct': gp,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustBrightContrast(rgb,
              format: 'rgb',
              maxValue: _max,
              brightPct: bp,
              baselinePct: base,
              gainPct: gp),
          context: 'brightcontrast rgb');
    });

    test('adjust_brightcontrast yuv 64x48（负向亮度+高对比钳位）', () async {
      const w = 64, h = 48;
      final rgb = gradientFrame(w, h, 3, maxValue: _max);
      final yuv = yuvFromRgb(rgb, _max);
      const bp = 80.0, base = 30.0, gp = 160.0;
      final c = await runCOp('adjust_brightcontrast', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'yuv',
        'brightPct': bp,
        'baselinePct': base,
        'gainPct': gp,
      }, inputs: [
        yuv
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustBrightContrast(yuv,
              format: 'yuv',
              maxValue: _max,
              brightPct: bp,
              baselinePct: base,
              gainPct: gp),
          context: 'brightcontrast yuv');
    });

    test('adjust_brightcontrast hsl 32x24（作用于 L 通道）', () async {
      const w = 32, h = 24;
      final rgb = lcgFrame(w, h, 3, 53, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const bp = 110.0, base = 60.0, gp = 80.0;
      final c = await runCOp('adjust_brightcontrast', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'hsl',
        'brightPct': bp,
        'baselinePct': base,
        'gainPct': gp,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustBrightContrast(hsl,
              format: 'hsl',
              maxValue: _max,
              brightPct: bp,
              baselinePct: base,
              gainPct: gp),
          context: 'brightcontrast hsl');
    });

    test('adjust_brightcontrast mono 64x48（单通道，帧长 w*h）', () async {
      const w = 64, h = 48;
      final mono = lcgFrame(w, h, 1, 54, maxValue: _max);
      const bp = 90.0, base = 40.0, gp = 200.0;
      final c = await runCOp('adjust_brightcontrast', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'mono',
        'brightPct': bp,
        'baselinePct': base,
        'gainPct': gp,
      }, inputs: [
        mono
      ], tag: _tag);
      // mono 语义在 kernel adjustBrightContrast 的 'mono' 分支内（非 runner），
      // 直接调 kernel 作基准。
      expectFramesEqual(
          c.outputs[0],
          adjustBrightContrast(mono,
              format: 'mono',
              maxValue: _max,
              brightPct: bp,
              baselinePct: base,
              gainPct: gp),
          context: 'brightcontrast mono');
    });

    test('adjust_brightcontrast 恒等参数直通（rgb，100/50/100）', () async {
      const w = 16, h = 16;
      final rgb = lcgFrame(w, h, 3, 55, maxValue: _max);
      final c = await runCOp('adjust_brightcontrast', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'brightPct': 100.0,
        'baselinePct': 50.0,
        'gainPct': 100.0,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], rgb, context: 'brightcontrast 恒等直通');
    });

    // ------------------------------------------------------------------
    // adjust_colorbalance
    // ------------------------------------------------------------------
    test('adjust_colorbalance rgb 64x48 三滑杆混合', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 61, maxValue: _max);
      const cr = 30.0, mg = -20.0, yb = 50.0;
      final c = await runCOp('adjust_colorbalance', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'cyanRed': cr,
        'magentaGreen': mg,
        'yellowBlue': yb,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          applyColorBalance(rgb,
              format: 'rgb',
              maxValue: _max,
              cyanRed: cr,
              magentaGreen: mg,
              yellowBlue: yb),
          context: 'colorbalance rgb');
    });

    test('adjust_colorbalance rgb 64x48 ±100 极值（渐变帧含 0/max 角点）',
        () async {
      const w = 64, h = 48;
      final rgb = gradientFrame(w, h, 3, maxValue: _max);
      const cr = 100.0, mg = -100.0, yb = 100.0;
      final c = await runCOp('adjust_colorbalance', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'cyanRed': cr,
        'magentaGreen': mg,
        'yellowBlue': yb,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          applyColorBalance(rgb,
              format: 'rgb',
              maxValue: _max,
              cyanRed: cr,
              magentaGreen: mg,
              yellowBlue: yb),
          context: 'colorbalance rgb ±100');
    });

    test('adjust_colorbalance yuv 64x48 ±100 极值', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 63, maxValue: _max);
      final yuv = yuvFromRgb(rgb, _max);
      const cr = -100.0, mg = 100.0, yb = -50.0;
      final c = await runCOp('adjust_colorbalance', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'yuv',
        'cyanRed': cr,
        'magentaGreen': mg,
        'yellowBlue': yb,
      }, inputs: [
        yuv
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          applyColorBalance(yuv,
              format: 'yuv',
              maxValue: _max,
              cyanRed: cr,
              magentaGreen: mg,
              yellowBlue: yb),
          context: 'colorbalance yuv ±100');
    });

    test('adjust_colorbalance hsl 64x48（HSL→RGB→偏移→HSL 往返）', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 64, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const cr = 60.0, mg = 40.0, yb = -80.0;
      final c = await runCOp('adjust_colorbalance', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'hsl',
        'cyanRed': cr,
        'magentaGreen': mg,
        'yellowBlue': yb,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          applyColorBalance(hsl,
              format: 'hsl',
              maxValue: _max,
              cyanRed: cr,
              magentaGreen: mg,
              yellowBlue: yb),
          context: 'colorbalance hsl 往返');
    });

    test('adjust_colorbalance 恒等参数直通（rgb，三值全 0）', () async {
      const w = 16, h = 16;
      final rgb = lcgFrame(w, h, 3, 65, maxValue: _max);
      final c = await runCOp('adjust_colorbalance', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'format': 'rgb',
        'cyanRed': 0.0,
        'magentaGreen': 0.0,
        'yellowBlue': 0.0,
      }, inputs: [
        rgb
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], rgb, context: 'colorbalance 恒等直通');
    });

    // ------------------------------------------------------------------
    // color_controller
    // ------------------------------------------------------------------
    test('color_controller 64x48 中带 q=2', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 71, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const center = 120.0, q = 2.0, hShift = 30.0, sG = 1.5, lG = 0.8;
      final c = await runCOp('color_controller', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'hCenterDeg': center,
        'q': q,
        'hShiftDeg': hShift,
        'sGain': sG,
        'lGain': lG,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustHslBand(hsl,
              maxValue: _max,
              hCenterDeg: center,
              q: q,
              hShiftDeg: hShift,
              sGain: sG,
              lGain: lG),
          context: 'color_controller q=2');
    });

    test('color_controller 64x48 窄带 q=8 + 负中心（带外像素恒等）', () async {
      const w = 64, h = 48;
      final rgb = lcgFrame(w, h, 3, 72, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const center = -60.0, q = 8.0, hShift = -90.0, sG = 0.5, lG = 1.2;
      final c = await runCOp('color_controller', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'hCenterDeg': center,
        'q': q,
        'hShiftDeg': hShift,
        'sGain': sG,
        'lGain': lG,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustHslBand(hsl,
              maxValue: _max,
              hCenterDeg: center,
              q: q,
              hShiftDeg: hShift,
              sGain: sG,
              lGain: lG),
          context: 'color_controller q=8 负中心');
    });

    test('color_controller 64x48 宽带 q=0.5 + 环绕边界中心 350°', () async {
      const w = 64, h = 48;
      final rgb = gradientFrame(w, h, 3, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      const center = 350.0, q = 0.5, hShift = 45.0, sG = 2.0, lG = 0.5;
      final c = await runCOp('color_controller', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'hCenterDeg': center,
        'q': q,
        'hShiftDeg': hShift,
        'sGain': sG,
        'lGain': lG,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          adjustHslBand(hsl,
              maxValue: _max,
              hCenterDeg: center,
              q: q,
              hShiftDeg: hShift,
              sGain: sG,
              lGain: lG),
          context: 'color_controller q=0.5 环绕');
    });

    test('color_controller 恒等参数直通（拷贝语义）', () async {
      const w = 16, h = 16;
      final rgb = lcgFrame(w, h, 3, 74, maxValue: _max);
      final hsl = hslFromRgb(rgb, _max);
      final c = await runCOp('color_controller', params: {
        'width': w,
        'height': h,
        'max_value': _max,
        'hCenterDeg': 100.0,
        'q': 2.0,
        'hShiftDeg': 0.0,
        'sGain': 1.0,
        'lGain': 1.0,
      }, inputs: [
        hsl
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], hsl, context: 'color_controller 恒等直通');
    });
  });

  group('isp_c_ref_compare_adjust: multi_band_eq 多段合成 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    /// C 侧 isp_multi_band_eq_build_luts + lut_apply 全路径，Dart 基准为
    /// multiBandLuts + applyHslBandLuts（同 runner 路径），tol=0 逐位一致。
    Future<void> checkMb(String context, Uint16List hsl, int w, int h,
        List<({double h, double q, double dh, double s, double l})> bands,
        {bool serial = false, int maxValue = _max}) async {
      final (shift, sMul, lMul) =
          multiBandLuts(bands, serial: serial, maxValue: maxValue);
      final expected = applyHslBandLuts(hsl, 0, hsl.length ~/ 3,
          maxValue: maxValue,
          shiftLut: shift, sMulLut: sMul, lMulLut: lMul);
      final params = <String, Object?>{
        'width': w,
        'height': h,
        'max_value': maxValue,
        'serial': serial ? 1 : 0,
        'band_count': bands.length,
      };
      for (var i = 0; i < bands.length; i++) {
        params['b${i}_h'] = bands[i].h;
        params['b${i}_q'] = bands[i].q;
        params['b${i}_dh'] = bands[i].dh;
        params['b${i}_s'] = bands[i].s;
        params['b${i}_l'] = bands[i].l;
      }
      final c = await runCOp('multi_band_eq',
          params: params, inputs: [hsl], tag: _tag);
      expectFramesEqual(c.outputs[0], expected, context: context);
    }

    test('并联两段 64x48（中带 q=2 + 邻带 S 增益）', () async {
      const w = 64, h = 48;
      final hsl = hslFromRgb(lcgFrame(w, h, 3, 81, maxValue: _max), _max);
      await checkMb('并联两段', hsl, w, h, [
        (h: 120.0, q: 2.0, dh: 30.0, s: 1.5, l: 0.8),
        (h: 200.0, q: 4.0, dh: -20.0, s: 0.7, l: 1.2),
      ]);
    });

    test('串联两段 64x48（顺序依赖 + 乘性增益）', () async {
      const w = 64, h = 48;
      final hsl = hslFromRgb(lcgFrame(w, h, 3, 82, maxValue: _max), _max);
      await checkMb('串联两段', hsl, w, h, [
        (h: 0.0, q: 2.0, dh: 90.0, s: 1.0, l: 1.0),
        (h: 90.0, q: 2.0, dh: 90.0, s: 2.0, l: 0.9),
      ], serial: true);
    });

    test('单段退化（并联/串联均同色彩控制器公式）', () async {
      const w = 32, h = 24;
      final hsl = hslFromRgb(lcgFrame(w, h, 3, 83, maxValue: _max), _max);
      const one = [(h: 37.5, q: 7.3, dh: -42.5, s: 1.8, l: 0.6)];
      await checkMb('单段并联', hsl, w, h, one);
      await checkMb('单段串联', hsl, w, h, one, serial: true);
    });

    test('串联环绕边界（中心 350° 负偏移 + 恒等段）', () async {
      const w = 64, h = 48;
      final hsl = hslFromRgb(gradientFrame(w, h, 3, maxValue: _max), _max);
      await checkMb('串联环绕+恒等段', hsl, w, h, [
        (h: 350.0, q: 2.0, dh: -60.0, s: 1.0, l: 1.0),
        (h: 100.0, q: 2.0, dh: 0.0, s: 1.0, l: 1.0),
      ], serial: true);
    });

    test('并联 clamp（同中心 dh 180+180 → ±180°；s 5+5 → ×5）', () async {
      const w = 32, h = 24;
      final hsl = hslFromRgb(lcgFrame(w, h, 3, 85, maxValue: _max), _max);
      await checkMb('并联 clamp', hsl, w, h, [
        (h: 60.0, q: 0.8, dh: 180.0, s: 5.0, l: 5.0),
        (h: 60.0, q: 1.6, dh: 180.0, s: 5.0, l: 0.0),
      ]);
    });

    test('宽带三段串联 64x48（q=0.5 全域覆盖）', () async {
      const w = 64, h = 48;
      final hsl = hslFromRgb(gradientFrame(w, h, 3, maxValue: _max), _max);
      await checkMb('三段串联宽带', hsl, w, h, [
        (h: 30.0, q: 0.5, dh: 45.0, s: 1.3, l: 1.1),
        (h: 150.0, q: 0.6, dh: -70.0, s: 0.8, l: 1.0),
        (h: 270.0, q: 0.7, dh: 25.0, s: 1.1, l: 0.9),
      ], serial: true);
    });
  });

  group('isp_c_ref_compare_adjust: 亮度/对比度 LUT 查表 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    /// LUT 模式一条龙：Dart brightContrastAdjustLut/RatioLut 建表 →
    /// adjust 表经 in1、ratio 表（rgb 域）经 inRaw0 传给 C 侧
    /// isp_adjust_bc_lut_apply，与 Dart 查表基准逐位比对。
    Future<void> checkBcLut(String context, Uint16List input, int w, int h,
        String format, double bright, double baseline, double gain,
        {int maxValue = 1023}) async {
      final adjLut = brightContrastAdjustLut(
          maxValue: maxValue,
          brightPct: bright,
          baselinePct: baseline,
          gainPct: gain);
      final c = await runCOp('adjust_bc_lut_apply', params: {
        'width': w,
        'height': h,
        'format': format,
        'max_value': maxValue,
      }, inputs: [
        input,
        adjLut,
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          applyBrightContrastLut(input,
              format: format, maxValue: maxValue, adjustLut: adjLut),
          context: context);
    }

    test('rgb 64x48 提亮+对比（ratio 表路径）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 91, maxValue: 1023);
      await checkBcLut('rgb b110 g130', input, w, h, 'rgb', 110, 50, 130);
    });

    test('rgb 32x24 压暗+基线偏移（含纯黑像素跳过分支）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkBcLut('rgb b70 base30 g80', input, w, h, 'rgb', 70, 30, 80);
    });

    test('yuv 64x48（Y 通道 1D 表，U/V 不变）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 92, maxValue: 1023);
      await checkBcLut('yuv b120 g90', input, w, h, 'yuv', 120, 50, 90);
    });

    test('hsl 64x48（L 通道 1D 表）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 93, maxValue: 1023);
      await checkBcLut('hsl b85 g110', input, w, h, 'hsl', 85, 50, 110);
    });

    test('mono 64x48（全帧 1D 表）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 94, maxValue: 1023);
      await checkBcLut('mono b105 g120', input, w, h, 'mono', 105, 50, 120);
    });

    test('rgb 16x16 maxValue=65535（16 位域表）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 95, maxValue: 65535);
      await checkBcLut('65535 rgb b115 g125', input, w, h, 'rgb', 115, 50,
          125, maxValue: 65535);
    });
  });

  group('isp_c_ref_compare_adjust: 色彩控制器 LUT 查表 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    /// LUT 模式一条龙：Dart hslBandLuts 建表 → 三表打包经 inRaw0 传给
    /// C 侧 isp_color_controller_lut_apply，与 Dart 查表基准逐位比对。
    Future<void> checkCcLut(String context, Uint16List input, int w, int h,
        double hCenter, double q, double hShift, double sGain, double lGain,
        {int maxValue = 1023}) async {
      final (shiftLut, sMulLut, lMulLut) = hslBandLuts(
          maxValue: maxValue,
          hCenterDeg: hCenter,
          q: q,
          hShiftDeg: hShift,
          sGain: sGain,
          lGain: lGain);
      // 打包：shift int32[N] + sMul double[N] + lMul double[N]。
      final packed = BytesBuilder()
        ..add(shiftLut.buffer.asUint8List())
        ..add(sMulLut.buffer.asUint8List())
        ..add(lMulLut.buffer.asUint8List());
      final c = await runCOp('color_controller_lut_apply', params: {
        'width': w,
        'height': h,
        'max_value': maxValue,
      }, inputs: [
        input,
      ], inRaw: packed.toBytes(), tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          applyHslBandLuts(input, 0, input.length ~/ 3,
              maxValue: maxValue,
              shiftLut: shiftLut,
              sMulLut: sMulLut,
              lMulLut: lMulLut),
          context: context);
    }

    test('64x48 典型带宽 q=2 + 色相偏移/饱和/亮度组合', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 101, maxValue: 1023);
      await checkCcLut(
          'c120 q2 hs30 s0.8 l1.1', input, w, h, 120, 2.0, 30, 0.8, 1.1);
    });

    test('64x48 环绕边界中心 350° + 负色相偏移（shift 负值覆盖）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 102, maxValue: 1023);
      await checkCcLut(
          'c350 q1 hs-40 s1.2 l0.9', input, w, h, 350, 1.0, -40, 1.2, 0.9);
    });

    test('32x24 窄带 q=8（σ 小、权重急降）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      await checkCcLut('c60 q8 hs15 s0.5 l1.3', input, w, h, 60, 8.0, 15, 0.5, 1.3);
    });

    test('16x16 maxValue=65535（16 位 H 域表）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 3, 103, maxValue: 65535);
      await checkCcLut('65535 c200 q2 hs10 s0.9 l1.05', input, w, h, 200,
          2.0, 10, 0.9, 1.05, maxValue: 65535);
    });
  });
}
