/// Dart↔C 对拍：增强组 —— rgb_dnr / sharpen / edge_extract / gaussian_blur /
/// morphology。
///
/// C 侧：test/c_ref/harness_enhance.c ->
/// lib/modules/isp_studio/c_ref/isp_rgb_dnr.c / isp_sharpen.c /
/// isp_edge_extract.c / isp_gaussian_blur.c / isp_morphology.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart 的
/// applyRgbDenoise / applySharpen / extractHighFreq / applyGaussianBlur /
/// applyMorphology。五个 op 的语义全部在 kernel 层（pipeline_runner 只做
/// format 分派与通道数选择，mono 即 channels=1），测试直接调 kernel 作基准。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_enhance';

// ---------------------------------------------------------------------------
// Dart 基准包装（原地修改类 kernel 先复制输入）
// ---------------------------------------------------------------------------

Uint16List dartRgbDnr(Uint16List input, int w, int h, double luma,
    double chroma, int maxValue) {
  final out = Uint16List.fromList(input);
  applyRgbDenoise(out,
      width: w, height: h, luma: luma, chroma: chroma, maxValue: maxValue);
  return out;
}

Uint16List dartSharpen(Uint16List input, int w, int h, double amount,
    double threshold, int maxValue) {
  final out = Uint16List.fromList(input);
  applySharpen(out,
      width: w, height: h, amount: amount, threshold: threshold,
      maxValue: maxValue);
  return out;
}

Uint16List dartGaussianBlur(
    Uint16List input, int w, int h, int channels, double sigma, double strength) {
  final out = Uint16List.fromList(input);
  applyGaussianBlur(out,
      width: w, height: h, channels: channels, sigma: sigma,
      strength: strength);
  return out;
}

Uint16List dartMorphology(
    Uint16List input, int w, int h, int channels, bool erode, int radius) {
  final out = Uint16List.fromList(input);
  applyMorphology(out,
      width: w, height: h, channels: channels, erode: erode, radius: radius);
  return out;
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_enhance: 增强组 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ------------------------------------------------------------------
    // rgb_dnr
    // ------------------------------------------------------------------
    test('rgb_dnr 64x48 luma+chroma 同开', () async {
      const w = 64, h = 48, maxV = 1023;
      const luma = 1.0, chroma = 0.5;
      final input = lcgFrame(w, h, 3, 11, maxValue: maxV);
      final c = await runCOp('rgb_dnr', params: {
        'width': w, 'height': h, 'luma': luma, 'chroma': chroma,
        'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartRgbDnr(input, w, h, luma, chroma, maxV),
          context: 'rgb_dnr luma+chroma');
    });

    test('rgb_dnr 32x24 仅亮度降噪（chroma=0）', () async {
      const w = 32, h = 24, maxV = 1023;
      const luma = 1.5, chroma = 0.0;
      final input = lcgFrame(w, h, 3, 12, maxValue: maxV);
      final c = await runCOp('rgb_dnr', params: {
        'width': w, 'height': h, 'luma': luma, 'chroma': chroma,
        'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartRgbDnr(input, w, h, luma, chroma, maxV),
          context: 'rgb_dnr 仅 luma');
    });

    test('rgb_dnr 8x6 小图仅色度降噪（luma=0，渐变帧 0/max 角点）', () async {
      const w = 8, h = 6, maxV = 1023;
      const luma = 0.0, chroma = 1.0;
      final input = gradientFrame(w, h, 3, maxValue: maxV);
      final c = await runCOp('rgb_dnr', params: {
        'width': w, 'height': h, 'luma': luma, 'chroma': chroma,
        'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartRgbDnr(input, w, h, luma, chroma, maxV),
          context: 'rgb_dnr 仅 chroma 小图');
    });

    // ------------------------------------------------------------------
    // sharpen
    // ------------------------------------------------------------------
    test('sharpen 64x48 amount=0.5 threshold=4', () async {
      const w = 64, h = 48, maxV = 1023;
      const amount = 0.5, threshold = 4.0;
      final input = lcgFrame(w, h, 3, 21, maxValue: maxV);
      final c = await runCOp('sharpen', params: {
        'width': w, 'height': h, 'amount': amount, 'threshold': threshold,
        'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartSharpen(input, w, h, amount, threshold, maxV),
          context: 'sharpen 基本');
    });

    test('sharpen 32x24 threshold=0（无噪声门限，渐变帧含 0/max 角点）', () async {
      const w = 32, h = 24, maxV = 1023;
      const amount = 1.5, threshold = 0.0;
      final input = gradientFrame(w, h, 3, maxValue: maxV);
      final c = await runCOp('sharpen', params: {
        'width': w, 'height': h, 'amount': amount, 'threshold': threshold,
        'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartSharpen(input, w, h, amount, threshold, maxV),
          context: 'sharpen threshold=0');
    });

    test('sharpen 16x12 maxValue=65535 大强度截位', () async {
      const w = 16, h = 12, maxV = 65535;
      const amount = 2.0, threshold = 8.0;
      final input = lcgFrame(w, h, 3, 23, maxValue: maxV);
      final c = await runCOp('sharpen', params: {
        'width': w, 'height': h, 'amount': amount, 'threshold': threshold,
        'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartSharpen(input, w, h, amount, threshold, maxV),
          context: 'sharpen 16bit 截位');
    });

    // ------------------------------------------------------------------
    // edge_extract（yuv/hsl 输入由 Dart 侧 rgbToYuv/rgbToHsl 从同一 RGB
    // 帧生成，C 侧吃同一输入文件，色彩转换本身不在本组对拍范围）
    // ------------------------------------------------------------------
    test('edge_extract 64x48 rgb 域', () async {
      const w = 64, h = 48, maxV = 1023;
      const gain = 1.0, threshold = 4.0;
      final input = lcgFrame(w, h, 3, 31, maxValue: maxV);
      final c = await runCOp('edge_extract', params: {
        'width': w, 'height': h, 'format': 'rgb', 'gain': gain,
        'threshold': threshold, 'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          extractHighFreq(input,
              width: w, height: h, format: 'rgb', gain: gain,
              threshold: threshold, maxValue: maxV),
          context: 'edge_extract rgb');
    });

    test('edge_extract 32x24 yuv 域（输入经 rgbToYuv 生成）', () async {
      const w = 32, h = 24, maxV = 1023;
      const gain = 2.0, threshold = 8.0;
      final rgb = lcgFrame(w, h, 3, 32, maxValue: maxV);
      final input = rgbToYuv(rgb, maxValue: maxV);
      final c = await runCOp('edge_extract', params: {
        'width': w, 'height': h, 'format': 'yuv', 'gain': gain,
        'threshold': threshold, 'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          extractHighFreq(input,
              width: w, height: h, format: 'yuv', gain: gain,
              threshold: threshold, maxValue: maxV),
          context: 'edge_extract yuv');
    });

    test('edge_extract 16x16 hsl 域（输入经 rgbToHsl 生成，渐变帧角点）', () async {
      const w = 16, h = 16, maxV = 1023;
      const gain = 1.0, threshold = 2.0;
      final rgb = gradientFrame(w, h, 3, maxValue: maxV);
      final input = rgbToHsl(rgb, maxValue: maxV);
      final c = await runCOp('edge_extract', params: {
        'width': w, 'height': h, 'format': 'hsl', 'gain': gain,
        'threshold': threshold, 'max_value': maxV,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          extractHighFreq(input,
              width: w, height: h, format: 'hsl', gain: gain,
              threshold: threshold, maxValue: maxV),
          context: 'edge_extract hsl');
    });

    // ------------------------------------------------------------------
    // gaussian_blur
    // ------------------------------------------------------------------
    test('gaussian_blur 64x48 3ch sigma=1.0 strength=1.0', () async {
      const w = 64, h = 48;
      const sigma = 1.0, strength = 1.0;
      final input = lcgFrame(w, h, 3, 41, maxValue: 1023);
      final c = await runCOp('gaussian_blur', params: {
        'width': w, 'height': h, 'channels': 3, 'sigma': sigma,
        'strength': strength,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartGaussianBlur(input, w, h, 3, sigma, strength),
          context: 'gaussian_blur sigma=1.0');
    });

    test('gaussian_blur 32x24 3ch sigma=2.0 strength=0.5（强度混合）', () async {
      const w = 32, h = 24;
      const sigma = 2.0, strength = 0.5;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      final c = await runCOp('gaussian_blur', params: {
        'width': w, 'height': h, 'channels': 3, 'sigma': sigma,
        'strength': strength,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartGaussianBlur(input, w, h, 3, sigma, strength),
          context: 'gaussian_blur sigma=2.0 半强度');
    });

    test('gaussian_blur 32x24 mono sigma=0.5（radius=2 单通道）', () async {
      const w = 32, h = 24;
      const sigma = 0.5, strength = 1.0;
      final input = lcgFrame(w, h, 1, 43, maxValue: 1023);
      final c = await runCOp('gaussian_blur', params: {
        'width': w, 'height': h, 'channels': 1, 'sigma': sigma,
        'strength': strength,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartGaussianBlur(input, w, h, 1, sigma, strength),
          context: 'gaussian_blur mono sigma=0.5');
    });

    test('gaussian_blur 8x6 mono sigma=2.0（radius=6 远超半幅，边界复制压力）',
        () async {
      const w = 8, h = 6;
      const sigma = 2.0, strength = 0.8;
      final input = lcgFrame(w, h, 1, 44, maxValue: 65535);
      final c = await runCOp('gaussian_blur', params: {
        'width': w, 'height': h, 'channels': 1, 'sigma': sigma,
        'strength': strength,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartGaussianBlur(input, w, h, 1, sigma, strength),
          context: 'gaussian_blur 小图大半径');
    });

    // ------------------------------------------------------------------
    // morphology
    // ------------------------------------------------------------------
    test('morphology 64x48 3ch 腐蚀 radius=1', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 3, 51, maxValue: 1023);
      final c = await runCOp('morphology', params: {
        'width': w, 'height': h, 'channels': 3, 'erode': 1, 'radius': 1,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartMorphology(input, w, h, 3, true, 1),
          context: 'morphology 腐蚀 r1');
    });

    test('morphology 32x24 3ch 膨胀 radius=2（渐变帧 0/max 角点）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 3, maxValue: 1023);
      final c = await runCOp('morphology', params: {
        'width': w, 'height': h, 'channels': 3, 'erode': 0, 'radius': 2,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartMorphology(input, w, h, 3, false, 2),
          context: 'morphology 膨胀 r2');
    });

    test('morphology 32x24 mono 腐蚀 radius=2', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 53, maxValue: 1023);
      final c = await runCOp('morphology', params: {
        'width': w, 'height': h, 'channels': 1, 'erode': 1, 'radius': 2,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartMorphology(input, w, h, 1, true, 2),
          context: 'morphology mono 腐蚀 r2');
    });

    test('morphology 8x6 mono 膨胀 radius=1 全 0 帧（极值常量）', () async {
      const w = 8, h = 6;
      final input = constantFrame(w, h, 1, 0);
      final c = await runCOp('morphology', params: {
        'width': w, 'height': h, 'channels': 1, 'erode': 0, 'radius': 1,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartMorphology(input, w, h, 1, false, 1),
          context: 'morphology 全 0 膨胀');
    });

    test('morphology 8x6 mono 腐蚀 radius=1 全 max 帧（极值常量）', () async {
      const w = 8, h = 6;
      final input = constantFrame(w, h, 1, 1023);
      final c = await runCOp('morphology', params: {
        'width': w, 'height': h, 'channels': 1, 'erode': 1, 'radius': 1,
      }, inputs: [input], tag: _tag);
      expectFramesEqual(
          c.outputs[0], dartMorphology(input, w, h, 1, true, 1),
          context: 'morphology 全 max 腐蚀');
    });
  });
}
