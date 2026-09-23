/// Dart↔C 对拍：荧光组 —— fluoro_leak / fluoro_background /
/// fluoro_normalize / fluoro_temporal / pseudo_color / fluoro_fusion。
///
/// C 侧：test/c_ref/harness_fluoro.c ->
/// lib/modules/isp_studio/c_ref/isp_fluoro.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart 的
/// applyFluoroLeak / applyFluoroBackground / applyFluoroNormalize /
/// applyTemporalIir / monoPseudoColor / fuseFluorescence（kernel 层函数，
/// 语义齐备，测试里直接调用；原地修改类先复制输入）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const _tag = '_grp_fluoro';

/// fluoro_leak Dart 基准（原地修改，先复制）。
Uint16List dartFluoroLeak(Uint16List input, double level, double maxSub) {
  final out = Uint16List.fromList(input);
  applyFluoroLeak(out, level: level, maxSub: maxSub);
  return out;
}

/// fluoro_background Dart 基准。
Uint16List dartFluoroBackground(
    Uint16List input, int w, int h, int blockSize, double strength) {
  final out = Uint16List.fromList(input);
  applyFluoroBackground(out,
      width: w, height: h, blockSize: blockSize, strength: strength);
  return out;
}

/// fluoro_normalize Dart 基准。
Uint16List dartFluoroNormalize(Uint16List input, double reference,
    double epsilon, int maxValue) {
  final out = Uint16List.fromList(input);
  applyFluoroNormalize(out,
      reference: reference, epsilon: epsilon, maxValue: maxValue);
  return out;
}

/// fluoro_temporal Dart 基准：返回 (输出帧, 新历史帧)。
(Uint16List, Uint16List) dartTemporalIir(Uint16List mono, Uint16List? history,
    double alpha, bool motionAdapt, int maxValue) {
  return applyTemporalIir(mono,
      history: history, alpha: alpha, motionAdapt: motionAdapt,
      maxValue: maxValue);
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_fluoro: 荧光组 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ------------------------------------------------------------------
    // fluoro_leak
    // ------------------------------------------------------------------
    test('fluoro_leak 64x48 level 被 maxSub 限幅（含小数检验 round）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 11, maxValue: 1023);
      const level = 100.5, maxSub = 80.0;
      final c = await runCOp('fluoro_leak', params: {
        'width': w,
        'height': h,
        'level': level,
        'maxSub': maxSub,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], dartFluoroLeak(input, level, maxSub),
          context: 'leak 限幅');
    });

    test('fluoro_leak 4x4 小图 + 0/max 角点，无限幅小数扣除', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      const level = 64.25, maxSub = 65535.0;
      final c = await runCOp('fluoro_leak', params: {
        'width': w,
        'height': h,
        'level': level,
        'maxSub': maxSub,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], dartFluoroLeak(input, level, maxSub),
          context: 'leak 4x4');
    });

    test('fluoro_leak 16x16 大扣除全截零', () async {
      const w = 16, h = 16;
      final input = constantFrame(w, h, 1, 50);
      const level = 200.0, maxSub = 65535.0;
      final c = await runCOp('fluoro_leak', params: {
        'width': w,
        'height': h,
        'level': level,
        'maxSub': maxSub,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], dartFluoroLeak(input, level, maxSub),
          context: 'leak 全截零');
    });

    test('fluoro_leak 32x24 负 level 直通（sub<=0 不动帧）', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 12, maxValue: 1023);
      final c = await runCOp('fluoro_leak', params: {
        'width': w,
        'height': h,
        'level': -5.0,
        'maxSub': 100.0,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(c.outputs[0], dartFluoroLeak(input, -5.0, 100.0),
          context: 'leak 负 level 直通');
    });

    // ------------------------------------------------------------------
    // fluoro_background
    // ------------------------------------------------------------------
    test('fluoro_background 64x48 块16 strength=0.8', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 21, maxValue: 1023);
      const bs = 16, strength = 0.8;
      final c = await runCOp('fluoro_background', params: {
        'width': w,
        'height': h,
        'blockSize': bs,
        'strength': strength,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroBackground(input, w, h, bs, strength),
          context: 'background 64x48');
    });

    test('fluoro_background 33x17 奇尺寸边缘截短块 strength=1.0', () async {
      const w = 33, h = 17;
      final input = lcgFrame(w, h, 1, 22, maxValue: 1023);
      const bs = 8, strength = 1.0;
      final c = await runCOp('fluoro_background', params: {
        'width': w,
        'height': h,
        'blockSize': bs,
        'strength': strength,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroBackground(input, w, h, bs, strength),
          context: 'background 33x17 边缘块');
    });

    test('fluoro_background 8x6 小图 blockSize=1 钳位到 2', () async {
      const w = 8, h = 6;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      const bs = 1, strength = 0.5;
      final c = await runCOp('fluoro_background', params: {
        'width': w,
        'height': h,
        'blockSize': bs,
        'strength': strength,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroBackground(input, w, h, bs, strength),
          context: 'background bs 钳位');
    });

    test('fluoro_background 32x24 maxValue=65535 strength>1', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 23, maxValue: 65535);
      const bs = 16, strength = 1.5;
      final c = await runCOp('fluoro_background', params: {
        'width': w,
        'height': h,
        'blockSize': bs,
        'strength': strength,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroBackground(input, w, h, bs, strength),
          context: 'background 65535 strength>1');
    });

    // ------------------------------------------------------------------
    // fluoro_normalize
    // ------------------------------------------------------------------
    test('fluoro_normalize 64x48 上拉增益', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 31, maxValue: 1023);
      const reference = 512.0, epsilon = 1.0, maxValue = 1023;
      final c = await runCOp('fluoro_normalize', params: {
        'width': w,
        'height': h,
        'reference': reference,
        'epsilon': epsilon,
        'maxValue': maxValue,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroNormalize(input, reference, epsilon, maxValue),
          context: 'normalize 上拉');
    });

    test('fluoro_normalize 16x16 全零帧 mean<epsilon 不动帧', () async {
      const w = 16, h = 16;
      final input = constantFrame(w, h, 1, 0);
      const reference = 100.0, epsilon = 1.0, maxValue = 1023;
      final c = await runCOp('fluoro_normalize', params: {
        'width': w,
        'height': h,
        'reference': reference,
        'epsilon': epsilon,
        'maxValue': maxValue,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroNormalize(input, reference, epsilon, maxValue),
          context: 'normalize 全零');
    });

    test('fluoro_normalize 8x8 常量帧 gain==1.0 精确短路', () async {
      const w = 8, h = 8;
      final input = constantFrame(w, h, 1, 300);
      const reference = 300.0, epsilon = 1.0, maxValue = 1023;
      final c = await runCOp('fluoro_normalize', params: {
        'width': w,
        'height': h,
        'reference': reference,
        'epsilon': epsilon,
        'maxValue': maxValue,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroNormalize(input, reference, epsilon, maxValue),
          context: 'normalize gain==1');
    });

    test('fluoro_normalize 32x24 maxValue=65535 大增益钳上限', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 32, maxValue: 65535);
      const reference = 60000.0, epsilon = 0.5, maxValue = 65535;
      final c = await runCOp('fluoro_normalize', params: {
        'width': w,
        'height': h,
        'reference': reference,
        'epsilon': epsilon,
        'maxValue': maxValue,
      }, inputs: [
        input
      ], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartFluoroNormalize(input, reference, epsilon, maxValue),
          context: 'normalize 65535');
    });

    // ------------------------------------------------------------------
    // fluoro_temporal（out0=输出帧，out1=新历史帧，两路都比对）
    // ------------------------------------------------------------------
    test('fluoro_temporal 64x48 无历史直通（out==in，历史初始化为当前帧）',
        () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 41, maxValue: 1023);
      final c = await runCOp('fluoro_temporal', params: {
        'width': w,
        'height': h,
        'alpha': 0.5,
        'motionAdapt': 0,
        'maxValue': 1023,
        'has_history': 0,
      }, inputs: [
        input
      ], outputCount: 2, tag: _tag);
      final (dOut, dHist) = dartTemporalIir(input, null, 0.5, false, 1023);
      expectFramesEqual(c.outputs[0], dOut, context: 'temporal 直通 out');
      expectFramesEqual(c.outputs[1], dHist, context: 'temporal 直通 hist');
    });

    test('fluoro_temporal 64x48 有历史 alpha=0.3 无运动自适应', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 42, maxValue: 1023);
      final hist = lcgFrame(w, h, 1, 43, maxValue: 1023);
      final c = await runCOp('fluoro_temporal', params: {
        'width': w,
        'height': h,
        'alpha': 0.3,
        'motionAdapt': 0,
        'maxValue': 1023,
        'has_history': 1,
      }, inputs: [
        input,
        hist
      ], outputCount: 2, tag: _tag);
      final (dOut, dHist) = dartTemporalIir(input, hist, 0.3, false, 1023);
      expectFramesEqual(c.outputs[0], dOut, context: 'temporal IIR out');
      expectFramesEqual(c.outputs[1], dHist, context: 'temporal IIR hist');
    });

    test('fluoro_temporal 64x48 运动像素强制 alpha=1（历史全零大帧差）',
        () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 44, maxValue: 1023);
      final hist = constantFrame(w, h, 1, 0);
      final c = await runCOp('fluoro_temporal', params: {
        'width': w,
        'height': h,
        'alpha': 0.5,
        'motionAdapt': 1,
        'maxValue': 1023,
        'has_history': 1,
      }, inputs: [
        input,
        hist
      ], outputCount: 2, tag: _tag);
      final (dOut, dHist) = dartTemporalIir(input, hist, 0.5, true, 1023);
      expectFramesEqual(c.outputs[0], dOut, context: 'temporal 运动 out');
      expectFramesEqual(c.outputs[1], dHist, context: 'temporal 运动 hist');
    });

    test('fluoro_temporal 4x4 小图 alpha>1 钳位到 1（out==当前帧）', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      final hist = lcgFrame(w, h, 1, 45, maxValue: 1023);
      final c = await runCOp('fluoro_temporal', params: {
        'width': w,
        'height': h,
        'alpha': 1.5,
        'motionAdapt': 0,
        'maxValue': 1023,
        'has_history': 1,
      }, inputs: [
        input,
        hist
      ], outputCount: 2, tag: _tag);
      final (dOut, dHist) = dartTemporalIir(input, hist, 1.5, false, 1023);
      expectFramesEqual(c.outputs[0], dOut, context: 'temporal alpha钳位 out');
      expectFramesEqual(c.outputs[1], dHist, context: 'temporal alpha钳位 hist');
    });

    test('fluoro_temporal 32x24 maxValue=65535 运动阈值边界', () async {
      const w = 32, h = 24;
      // 构造帧差恰好跨 maxValue/16 = 4095.9375 阈值的像素。
      final input = constantFrame(w, h, 1, 4096);
      final hist = constantFrame(w, h, 1, 0);
      // 一半像素差 4096（>4095.9375 运动），另一半差 4095（静止）。
      for (var i = 0; i < input.length; i += 2) {
        input[i] = 4095;
      }
      final c = await runCOp('fluoro_temporal', params: {
        'width': w,
        'height': h,
        'alpha': 0.25,
        'motionAdapt': 1,
        'maxValue': 65535,
        'has_history': 1,
      }, inputs: [
        input,
        hist
      ], outputCount: 2, tag: _tag);
      final (dOut, dHist) = dartTemporalIir(input, hist, 0.25, true, 65535);
      expectFramesEqual(c.outputs[0], dOut, context: 'temporal 阈值边界 out');
      expectFramesEqual(c.outputs[1], dHist, context: 'temporal 阈值边界 hist');
    });

    // ------------------------------------------------------------------
    // pseudo_color
    // ------------------------------------------------------------------
    test('pseudo_color 64x48 green gain=1.0', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 51, maxValue: 1023);
      final c = await runCOp('pseudo_color', params: {
        'width': w,
        'height': h,
        'colormap': 'green',
        'gain': 1.0,
        'maxValue': 1023,
      }, inputs: [
        input
      ], tag: _tag);
      final d = monoPseudoColor(input,
          width: w, height: h, colormap: 'green', gain: 1.0, maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'pseudo green');
    });

    test('pseudo_color 64x48 magenta gain=2.0（t 钳位到 1）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 52, maxValue: 1023);
      final c = await runCOp('pseudo_color', params: {
        'width': w,
        'height': h,
        'colormap': 'magenta',
        'gain': 2.0,
        'maxValue': 1023,
      }, inputs: [
        input
      ], tag: _tag);
      final d = monoPseudoColor(input,
          width: w, height: h, colormap: 'magenta', gain: 2.0, maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'pseudo magenta');
    });

    test('pseudo_color 32x24 hot gain=0.5 maxValue=65535', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 53, maxValue: 65535);
      final c = await runCOp('pseudo_color', params: {
        'width': w,
        'height': h,
        'colormap': 'hot',
        'gain': 0.5,
        'maxValue': 65535,
      }, inputs: [
        input
      ], tag: _tag);
      final d = monoPseudoColor(input,
          width: w, height: h, colormap: 'hot', gain: 0.5, maxValue: 65535);
      expectFramesEqual(c.outputs[0], d, context: 'pseudo hot 65535');
    });

    test('pseudo_color 4x4 渐变 hot（覆盖 0/1/3 段与角点 0/max）', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      final c = await runCOp('pseudo_color', params: {
        'width': w,
        'height': h,
        'colormap': 'hot',
        'gain': 1.0,
        'maxValue': 1023,
      }, inputs: [
        input
      ], tag: _tag);
      final d = monoPseudoColor(input,
          width: w, height: h, colormap: 'hot', gain: 1.0, maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'pseudo hot 4x4');
    });

    // ------------------------------------------------------------------
    // pseudo_color LUT 查表（LUT 模式）
    // ------------------------------------------------------------------
    /// LUT 模式一条龙：Dart pseudoColorLuts 建表 → 表经输入文件传给 C
    /// 侧 isp_fluoro_pseudo_color_lut_apply，与 Dart 查表基准逐位比对。
    Future<void> checkPseudoLut(String context, Uint16List input, int w,
        int h, String colormap, double gain,
        {int maxValue = 1023}) async {
      final (lutR, lutG, lutB) = pseudoColorLuts(colormap, gain, maxValue);
      final c = await runCOp('pseudo_color_lut_apply', params: {
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
          c.outputs[0], applyPseudoColorLut(input, lutR, lutG, lutB),
          context: context);
    }

    test('pseudo_color LUT 64x48 green gain=1.0', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 71, maxValue: 1023);
      await checkPseudoLut('green g1.0', input, w, h, 'green', 1.0);
    });

    test('pseudo_color LUT 64x48 magenta gain=1.7', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 72, maxValue: 1023);
      await checkPseudoLut('magenta g1.7', input, w, h, 'magenta', 1.7);
    });

    test('pseudo_color LUT 64x48 hot gain=2.5（t 钳 1 覆盖全色段）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 73, maxValue: 1023);
      await checkPseudoLut('hot g2.5', input, w, h, 'hot', 2.5);
    });

    test('pseudo_color LUT 16x16 maxValue=65535', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 1, 74, maxValue: 65535);
      await checkPseudoLut('65535 hot g0.8', input, w, h, 'hot', 0.8,
          maxValue: 65535);
    });

    // ------------------------------------------------------------------
    // fluoro_fusion（in0=白光 RGB，in1=荧光 mono）
    // ------------------------------------------------------------------
    test('fluoro_fusion 64x48 alpha 模式零偏移 green', () async {
      const w = 64, h = 48;
      final wl = lcgFrame(w, h, 3, 61, maxValue: 1023);
      final fl = lcgFrame(w, h, 1, 62, maxValue: 1023);
      final c = await runCOp('fluoro_fusion', params: {
        'width': w,
        'height': h,
        'mode': 'alpha',
        'threshold': 200.0,
        'alphaMax': 0.8,
        'colormap': 'green',
        'offsetX': 0.0,
        'offsetY': 0.0,
        'maxValue': 1023,
      }, inputs: [
        wl,
        fl
      ], tag: _tag);
      final d = fuseFluorescence(wl, fl,
          width: w,
          height: h,
          mode: 'alpha',
          threshold: 200.0,
          alphaMax: 0.8,
          colormap: 'green',
          maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'fusion alpha 零偏移');
    });

    test('fluoro_fusion 64x48 alpha 模式非整偏移 magenta（双线性重采样）',
        () async {
      const w = 64, h = 48;
      final wl = lcgFrame(w, h, 3, 63, maxValue: 1023);
      final fl = lcgFrame(w, h, 1, 64, maxValue: 1023);
      final c = await runCOp('fluoro_fusion', params: {
        'width': w,
        'height': h,
        'mode': 'alpha',
        'threshold': 100.5,
        'alphaMax': 0.7,
        'colormap': 'magenta',
        'offsetX': 0.5,
        'offsetY': -0.25,
        'maxValue': 1023,
      }, inputs: [
        wl,
        fl
      ], tag: _tag);
      final d = fuseFluorescence(wl, fl,
          width: w,
          height: h,
          mode: 'alpha',
          threshold: 100.5,
          alphaMax: 0.7,
          colormap: 'magenta',
          offsetX: 0.5,
          offsetY: -0.25,
          maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'fusion alpha 非整偏移');
    });

    test('fluoro_fusion 64x48 contour 模式零偏移 hot', () async {
      const w = 64, h = 48;
      final wl = lcgFrame(w, h, 3, 65, maxValue: 1023);
      final fl = lcgFrame(w, h, 1, 66, maxValue: 1023);
      final c = await runCOp('fluoro_fusion', params: {
        'width': w,
        'height': h,
        'mode': 'contour',
        'threshold': 300.0,
        'alphaMax': 0.8,
        'colormap': 'hot',
        'offsetX': 0.0,
        'offsetY': 0.0,
        'maxValue': 1023,
      }, inputs: [
        wl,
        fl
      ], tag: _tag);
      final d = fuseFluorescence(wl, fl,
          width: w,
          height: h,
          mode: 'contour',
          threshold: 300.0,
          colormap: 'hot',
          maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'fusion contour 零偏移');
    });

    test('fluoro_fusion 32x24 contour 模式非整偏移 green', () async {
      const w = 32, h = 24;
      final wl = lcgFrame(w, h, 3, 67, maxValue: 1023);
      final fl = lcgFrame(w, h, 1, 68, maxValue: 1023);
      final c = await runCOp('fluoro_fusion', params: {
        'width': w,
        'height': h,
        'mode': 'contour',
        'threshold': 250.5,
        'alphaMax': 0.8,
        'colormap': 'green',
        'offsetX': 1.75,
        'offsetY': 0.5,
        'maxValue': 1023,
      }, inputs: [
        wl,
        fl
      ], tag: _tag);
      final d = fuseFluorescence(wl, fl,
          width: w,
          height: h,
          mode: 'contour',
          threshold: 250.5,
          colormap: 'green',
          offsetX: 1.75,
          offsetY: 0.5,
          maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'fusion contour 非整偏移');
    });

    test('fluoro_fusion 4x4 小图 alpha 模式负偏移钳位 maxValue=65535',
        () async {
      const w = 4, h = 4;
      final wl = gradientFrame(w, h, 3, maxValue: 65535);
      final fl = gradientFrame(w, h, 1, maxValue: 65535);
      final c = await runCOp('fluoro_fusion', params: {
        'width': w,
        'height': h,
        'mode': 'alpha',
        'threshold': 10000.0,
        'alphaMax': 0.9,
        'colormap': 'hot',
        'offsetX': -2.0,
        'offsetY': 10.0,
        'maxValue': 65535,
      }, inputs: [
        wl,
        fl
      ], tag: _tag);
      final d = fuseFluorescence(wl, fl,
          width: w,
          height: h,
          mode: 'alpha',
          threshold: 10000.0,
          alphaMax: 0.9,
          colormap: 'hot',
          offsetX: -2.0,
          offsetY: 10.0,
          maxValue: 65535);
      expectFramesEqual(c.outputs[0], d, context: 'fusion 4x4 偏移钳位');
    });

    test('fluoro_fusion 16x16 alpha 模式 threshold=maxValue（range=0 透传白光）',
        () async {
      const w = 16, h = 16;
      final wl = lcgFrame(w, h, 3, 69, maxValue: 1023);
      final fl = lcgFrame(w, h, 1, 70, maxValue: 1023);
      final c = await runCOp('fluoro_fusion', params: {
        'width': w,
        'height': h,
        'mode': 'alpha',
        'threshold': 1023.0,
        'alphaMax': 0.8,
        'colormap': 'green',
        'offsetX': 0.0,
        'offsetY': 0.0,
        'maxValue': 1023,
      }, inputs: [
        wl,
        fl
      ], tag: _tag);
      final d = fuseFluorescence(wl, fl,
          width: w,
          height: h,
          mode: 'alpha',
          threshold: 1023.0,
          colormap: 'green',
          maxValue: 1023);
      expectFramesEqual(c.outputs[0], d, context: 'fusion range=0 透传');
    });
  });
}
