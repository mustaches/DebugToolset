/// Dart↔C 对拍：高级去马赛克组 —— mhc / aahd / amaze / lmmse / igv。
///
/// C 侧：test/c_ref/harness_demosaic_adv.c ->
/// lib/modules/isp_studio/c_ref/isp_demosaic_adv.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/demosaic_advanced.dart 的
/// demosaicMhc / demosaicAahd / demosaicAmaze / demosaicLmmse / demosaicIgv
/// （边界环与小图回退共用 isp_kernels.dart 的 demosaicBilinear 铺底）。
///
/// 重计算算法，帧控制在 48x36 以内；每组覆盖 RGGB+BGGR 两种图案、
/// LCG 帧与渐变帧、小图回退双线性路径（MHC/IGV 阈 5，AAHD/AMaZE/LMMSE 阈 7）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/demosaic_advanced.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

/// 对拍标签（并行分组构建自己的 harness exe）。
const String kTag = '_grp_demosaic_adv';

/// 一次对拍：C 侧跑 [op]，与 Dart 基准 [dartFn] 的输出逐位比对。
Future<void> compareOp(
  String op,
  Uint16List Function(Uint16List bayer) dartFn,
  Uint16List input,
  int w,
  int h,
  BayerPattern pattern, {
  int maxValue = 1023,
  int tol = 0,
  String context = '',
}) async {
  final c = await runCOp(op, params: {
    'width': w,
    'height': h,
    'pattern': pattern.name,
    'max_value': maxValue,
  }, inputs: [
    input
  ], tag: kTag);
  expectFramesEqual(c.outputs[0], dartFn(input),
      context: '$op $context', tol: tol);
}

Uint16List mhc(Uint16List b, int w, int h, BayerPattern p, int maxValue) =>
    demosaicMhc(b, width: w, height: h, pattern: p, maxValue: maxValue);
Uint16List aahd(Uint16List b, int w, int h, BayerPattern p, int maxValue) =>
    demosaicAahd(b, width: w, height: h, pattern: p, maxValue: maxValue);
Uint16List amaze(Uint16List b, int w, int h, BayerPattern p, int maxValue) =>
    demosaicAmaze(b, width: w, height: h, pattern: p, maxValue: maxValue);
Uint16List lmmse(Uint16List b, int w, int h, BayerPattern p, int maxValue) =>
    demosaicLmmse(b, width: w, height: h, pattern: p, maxValue: maxValue);
Uint16List igv(Uint16List b, int w, int h, BayerPattern p, int maxValue) =>
    demosaicIgv(b, width: w, height: h, pattern: p, maxValue: maxValue);

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: kTag);

  group('isp_c_ref_compare_demosaic_adv: 高级去马赛克 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ------------------------------------------------------------------
    // MHC（纯整数卷积路径，tol=0 必然成立）
    // ------------------------------------------------------------------
    test('mhc 48x36 RGGB LCG', () async {
      const w = 48, h = 36;
      final input = lcgFrame(w, h, 1, 11, maxValue: 1023);
      await compareOp('demosaic_mhc', (b) => mhc(b, w, h, BayerPattern.rggb, 1023),
          input, w, h, BayerPattern.rggb, context: '48x36 rggb lcg');
    });

    test('mhc 32x24 BGGR 渐变帧（含 0/max 角点）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await compareOp('demosaic_mhc', (b) => mhc(b, w, h, BayerPattern.bggr, 1023),
          input, w, h, BayerPattern.bggr, context: '32x24 bggr gradient');
    });

    test('mhc 8x6 RGGB 小图（非回退，2 像素边界环占比大）', () async {
      const w = 8, h = 6;
      final input = lcgFrame(w, h, 1, 12, maxValue: 1023);
      await compareOp('demosaic_mhc', (b) => mhc(b, w, h, BayerPattern.rggb, 1023),
          input, w, h, BayerPattern.rggb, context: '8x6 rggb');
    });

    test('mhc 4x4 BGGR 极小图（触发双线性回退）', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await compareOp('demosaic_mhc', (b) => mhc(b, w, h, BayerPattern.bggr, 1023),
          input, w, h, BayerPattern.bggr, context: '4x4 回退');
    });

    test('mhc 32x24 RGGB 全 maxValue 常量帧（核系数溢出钳位路径）', () async {
      const w = 32, h = 24;
      final input = constantFrame(w, h, 1, 1023);
      await compareOp('demosaic_mhc', (b) => mhc(b, w, h, BayerPattern.rggb, 1023),
          input, w, h, BayerPattern.rggb, context: '常量 maxValue');
    });

    // ------------------------------------------------------------------
    // AAHD（含 sRGB→Lab 的 pow()，MSVC 与 Dart libm 公式一致；
    // 若出现孤立 ±1 末位差异再评估 tol）
    // ------------------------------------------------------------------
    test('aahd 32x24 RGGB LCG', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 21, maxValue: 1023);
      await compareOp('demosaic_aahd', (b) => aahd(b, w, h, BayerPattern.rggb, 1023),
          input, w, h, BayerPattern.rggb, context: '32x24 rggb lcg');
    });

    test('aahd 48x36 BGGR 渐变帧（含 0/max 角点）', () async {
      const w = 48, h = 36;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await compareOp('demosaic_aahd', (b) => aahd(b, w, h, BayerPattern.bggr, 1023),
          input, w, h, BayerPattern.bggr, context: '48x36 bggr gradient');
    });

    test('aahd 8x6 RGGB 小图（触发双线性回退，w/h<7）', () async {
      const w = 8, h = 6;
      final input = lcgFrame(w, h, 1, 22, maxValue: 1023);
      await compareOp('demosaic_aahd', (b) => aahd(b, w, h, BayerPattern.rggb, 1023),
          input, w, h, BayerPattern.rggb, context: '8x6 回退');
    });

    test('aahd 24x18 GBRG LCG maxValue=65535（Lab 归一化大值域）', () async {
      const w = 24, h = 18;
      final input = lcgFrame(w, h, 1, 23, maxValue: 65535);
      await compareOp('demosaic_aahd',
          (b) => aahd(b, w, h, BayerPattern.gbrg, 65535), input, w, h,
          BayerPattern.gbrg, maxValue: 65535, context: 'gbrg 65535');
    });

    // ------------------------------------------------------------------
    // AMaZE（浮点加权融合 + 3x3 中值）
    // ------------------------------------------------------------------
    test('amaze 48x36 RGGB LCG', () async {
      const w = 48, h = 36;
      final input = lcgFrame(w, h, 1, 31, maxValue: 1023);
      await compareOp('demosaic_amaze',
          (b) => amaze(b, w, h, BayerPattern.rggb, 1023), input, w, h,
          BayerPattern.rggb, context: '48x36 rggb lcg');
    });

    test('amaze 32x24 BGGR 渐变帧（含 0/max 角点）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await compareOp('demosaic_amaze',
          (b) => amaze(b, w, h, BayerPattern.bggr, 1023), input, w, h,
          BayerPattern.bggr, context: '32x24 bggr gradient');
    });

    test('amaze 8x6 RGGB 小图（触发双线性回退）', () async {
      const w = 8, h = 6;
      final input = lcgFrame(w, h, 1, 32, maxValue: 1023);
      await compareOp('demosaic_amaze',
          (b) => amaze(b, w, h, BayerPattern.rggb, 1023), input, w, h,
          BayerPattern.rggb, context: '8x6 回退');
    });

    test('amaze 32x24 RGGB 全 0 帧（wh=wv=1/2 等权融合路径）', () async {
      const w = 32, h = 24;
      final input = constantFrame(w, h, 1, 0);
      await compareOp('demosaic_amaze',
          (b) => amaze(b, w, h, BayerPattern.rggb, 1023), input, w, h,
          BayerPattern.rggb, context: '全 0 常量');
    });

    // ------------------------------------------------------------------
    // LMMSE（3x3 窗口逆能量加权）
    // ------------------------------------------------------------------
    test('lmmse 48x36 RGGB 渐变帧（含 0/max 角点）', () async {
      const w = 48, h = 36;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await compareOp('demosaic_lmmse',
          (b) => lmmse(b, w, h, BayerPattern.rggb, 1023), input, w, h,
          BayerPattern.rggb, context: '48x36 rggb gradient');
    });

    test('lmmse 32x24 BGGR LCG', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 41, maxValue: 1023);
      await compareOp('demosaic_lmmse',
          (b) => lmmse(b, w, h, BayerPattern.bggr, 1023), input, w, h,
          BayerPattern.bggr, context: '32x24 bggr lcg');
    });

    test('lmmse 8x6 RGGB 小图（触发双线性回退）', () async {
      const w = 8, h = 6;
      final input = lcgFrame(w, h, 1, 42, maxValue: 1023);
      await compareOp('demosaic_lmmse',
          (b) => lmmse(b, w, h, BayerPattern.rggb, 1023), input, w, h,
          BayerPattern.rggb, context: '8x6 回退');
    });

    test('lmmse 24x18 GRBG LCG（平坦+纹理混合，eps 分支）', () async {
      const w = 24, h = 18;
      // 半幅常量（触发 eps 主导等权）半幅 LCG。
      final input = lcgFrame(w, h, 1, 43, maxValue: 1023);
      for (var y = 0; y < h ~/ 2; y++) {
        for (var x = 0; x < w; x++) {
          input[y * w + x] = 512;
        }
      }
      await compareOp('demosaic_lmmse',
          (b) => lmmse(b, w, h, BayerPattern.grbg, 1023), input, w, h,
          BayerPattern.grbg, context: '24x18 grbg 半常量');
    });

    // ------------------------------------------------------------------
    // IGV（方差无阈值加权，eps = maxValue^2 * 1e-6）
    // ------------------------------------------------------------------
    test('igv 48x36 RGGB LCG', () async {
      const w = 48, h = 36;
      final input = lcgFrame(w, h, 1, 51, maxValue: 1023);
      await compareOp('demosaic_igv', (b) => igv(b, w, h, BayerPattern.rggb, 1023),
          input, w, h, BayerPattern.rggb, context: '48x36 rggb lcg');
    });

    test('igv 32x24 BGGR 渐变帧（含 0/max 角点）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await compareOp('demosaic_igv', (b) => igv(b, w, h, BayerPattern.bggr, 1023),
          input, w, h, BayerPattern.bggr, context: '32x24 bggr gradient');
    });

    test('igv 8x6 RGGB 小图（非回退，阈 5）', () async {
      const w = 8, h = 6;
      final input = lcgFrame(w, h, 1, 52, maxValue: 1023);
      await compareOp('demosaic_igv', (b) => igv(b, w, h, BayerPattern.rggb, 1023),
          input, w, h, BayerPattern.rggb, context: '8x6 rggb');
    });

    test('igv 4x4 BGGR 极小图（触发双线性回退）', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await compareOp('demosaic_igv', (b) => igv(b, w, h, BayerPattern.bggr, 1023),
          input, w, h, BayerPattern.bggr, context: '4x4 回退');
    });

    test('igv 24x18 RGGB LCG maxValue=65535（eps 大值域，验证 int 溢出规避）',
        () async {
      const w = 24, h = 18;
      final input = lcgFrame(w, h, 1, 53, maxValue: 65535);
      await compareOp('demosaic_igv', (b) => igv(b, w, h, BayerPattern.rggb, 65535),
          input, w, h, BayerPattern.rggb,
          maxValue: 65535, context: 'rggb 65535');
    });
  });
}
