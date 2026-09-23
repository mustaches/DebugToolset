/// Dart↔C 对拍：去马赛克组 —— bilinear（Bayer）+ 4 种非 Bayer CFA。
///
/// C 侧：test/c_ref/harness_demosaic.c ->
/// lib/modules/isp_studio/c_ref/isp_demosaic.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart 的
/// demosaicBilinear / demosaicRccb / demosaicRccc / demosaicRyycy /
/// demosaicRgbIr（均返回新缓冲，直接调用即可）。
///
/// bilinear 的 Dart 内部像素走 _PxPlan 快速路径、边缘/小图走 _demosaicPixel
/// 通用路径，C 侧统一走通用路径（两者在内部像素上代数等价，见
/// isp_demosaic.c isp_demosaic_pixel 注释），因此对拍覆盖大图（两条 Dart
/// 路径都触发）与小图（纯通用路径）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_demosaic';

/// demosaic_bilinear 一次对拍：C 输出 vs Dart demosaicBilinear。
Future<void> checkBilinear(
    Uint16List input, int w, int h, BayerPattern pattern, String ctx) async {
  final c = await runCOp('demosaic_bilinear',
      params: {'width': w, 'height': h, 'pattern': pattern.name},
      inputs: [input],
      tag: _tag);
  expectFramesEqual(
      c.outputs[0], demosaicBilinear(input, width: w, height: h, pattern: pattern),
      context: ctx);
}

/// 非 Bayer CFA 一次对拍。
Future<void> checkCfa(String op, Uint16List input, int w, int h,
    Map<String, Object?> extraParams, Uint16List Function() dartFn,
    String ctx) async {
  final c = await runCOp(op,
      params: {'width': w, 'height': h, ...extraParams},
      inputs: [input],
      tag: _tag);
  expectFramesEqual(c.outputs[0], dartFn(), context: ctx);
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_demosaic: 去马赛克 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // -----------------------------------------------------------------
    // demosaic_bilinear：4 种 Bayer 图案 × 大图/小图/边界
    // -----------------------------------------------------------------
    test('64x48 RGGB LCG 帧', () async {
      const w = 64, h = 48;
      await checkBilinear(
          lcgFrame(w, h, 1, 11), w, h, BayerPattern.rggb, 'bilinear rggb 64x48');
    });

    test('64x48 BGGR 渐变帧（0/max 角点）', () async {
      const w = 64, h = 48;
      await checkBilinear(gradientFrame(w, h, 1), w, h, BayerPattern.bggr,
          'bilinear bggr 64x48');
    });

    test('32x24 GRBG LCG 帧', () async {
      const w = 32, h = 24;
      await checkBilinear(
          lcgFrame(w, h, 1, 13), w, h, BayerPattern.grbg, 'bilinear grbg 32x24');
    });

    test('48x36 GBRG 全 maxValue 常量帧', () async {
      const w = 48, h = 36;
      await checkBilinear(constantFrame(w, h, 1, 1023), w, h,
          BayerPattern.gbrg, 'bilinear gbrg 全 max');
    });

    test('32x32 RGGB 全 0 帧', () async {
      const w = 32, h = 32;
      await checkBilinear(
          constantFrame(w, h, 1, 0), w, h, BayerPattern.rggb, 'bilinear 全 0');
    });

    test('4x4 小图（无内部像素，纯通用路径）', () async {
      const w = 4, h = 4;
      await checkBilinear(
          gradientFrame(w, h, 1), w, h, BayerPattern.rggb, 'bilinear 4x4');
    });

    test('3x3 边界尺寸（width<3/height<3 分支）', () async {
      const w = 3, h = 3;
      await checkBilinear(
          lcgFrame(w, h, 1, 17), w, h, BayerPattern.gbrg, 'bilinear 3x3');
    });

    // -----------------------------------------------------------------
    // demosaic_rccb（rccg=0/1 复用 RCCG）
    // -----------------------------------------------------------------
    test('rccb 64x48 LCG 帧（RCCB 布局）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 21);
      await checkCfa('demosaic_rccb', input, w, h, {'rccg': 0, 'maxValue': 1023},
          () => demosaicRccb(input, width: w, height: h, maxValue: 1023),
          'rccb 64x48');
    });

    test('rccb rccg=1 32x32 渐变帧（RCCG 布局，B=C-R-G 截零/钳位）', () async {
      const w = 32, h = 32;
      final input = gradientFrame(w, h, 1);
      await checkCfa('demosaic_rccb', input, w, h, {'rccg': 1, 'maxValue': 1023},
          () => demosaicRccb(input,
              width: w, height: h, rccg: true, maxValue: 1023),
          'rccb rccg 32x32');
    });

    test('rccb 4x4 小图 + 全 maxValue（G=C-(R+B)/2 钳位上限）', () async {
      const w = 4, h = 4;
      final input = constantFrame(w, h, 1, 1023);
      await checkCfa('demosaic_rccb', input, w, h, {'rccg': 0, 'maxValue': 1023},
          () => demosaicRccb(input, width: w, height: h, maxValue: 1023),
          'rccb 4x4 全 max');
    });

    // -----------------------------------------------------------------
    // demosaic_rccc
    // -----------------------------------------------------------------
    test('rccc 64x48 LCG 帧', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 31);
      await checkCfa('demosaic_rccc', input, w, h, {'maxValue': 1023},
          () => demosaicRccc(input, width: w, height: h, maxValue: 1023),
          'rccc 64x48');
    });

    test('rccc 4x4 小图渐变帧（边缘邻域缩减）', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 1);
      await checkCfa('demosaic_rccc', input, w, h, {'maxValue': 1023},
          () => demosaicRccc(input, width: w, height: h, maxValue: 1023),
          'rccc 4x4');
    });

    // -----------------------------------------------------------------
    // demosaic_ryycy
    // -----------------------------------------------------------------
    test('ryycy 64x48 LCG 帧', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 41);
      await checkCfa('demosaic_ryycy', input, w, h, {'maxValue': 1023},
          () => demosaicRyycy(input, width: w, height: h, maxValue: 1023),
          'ryycy 64x48');
    });

    test('ryycy 3x3 边界尺寸（G=Y-R 大量截零）', () async {
      const w = 3, h = 3;
      final input = lcgFrame(w, h, 1, 43);
      await checkCfa('demosaic_ryycy', input, w, h, {'maxValue': 1023},
          () => demosaicRyycy(input, width: w, height: h, maxValue: 1023),
          'ryycy 3x3');
    });

    test('ryycy 16x16 全 0 帧', () async {
      const w = 16, h = 16;
      final input = constantFrame(w, h, 1, 0);
      await checkCfa('demosaic_ryycy', input, w, h, {'maxValue': 1023},
          () => demosaicRyycy(input, width: w, height: h, maxValue: 1023),
          'ryycy 全 0');
    });

    // -----------------------------------------------------------------
    // demosaic_rgbir（irSubtraction 变体）
    // -----------------------------------------------------------------
    test('rgbir 64x48 LCG 帧 irSubtraction=0.5（默认语义）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 51);
      await checkCfa(
          'demosaic_rgbir', input, w, h, {'maxValue': 1023, 'irSubtraction': 0.5},
          () => demosaicRgbIr(input,
              width: w, height: h, maxValue: 1023, irSubtraction: 0.5),
          'rgbir irSub=0.5');
    });

    test('rgbir 32x32 渐变帧 irSubtraction=0（不扣除）', () async {
      const w = 32, h = 32;
      final input = gradientFrame(w, h, 1);
      await checkCfa(
          'demosaic_rgbir', input, w, h, {'maxValue': 1023, 'irSubtraction': 0.0},
          () => demosaicRgbIr(input,
              width: w, height: h, maxValue: 1023, irSubtraction: 0.0),
          'rgbir irSub=0');
    });

    test('rgbir 16x16 LCG 帧 irSubtraction=1.0（全量扣除截零）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 1, 53);
      await checkCfa(
          'demosaic_rgbir', input, w, h, {'maxValue': 1023, 'irSubtraction': 1.0},
          () => demosaicRgbIr(input,
              width: w, height: h, maxValue: 1023, irSubtraction: 1.0),
          'rgbir irSub=1.0');
    });

    test('rgbir 16x16 LCG 帧 maxValue=65535（16 位量级）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 1, 57, maxValue: 65535);
      await checkCfa('demosaic_rgbir', input, w, h,
          {'maxValue': 65535, 'irSubtraction': 0.25},
          () => demosaicRgbIr(input,
              width: w, height: h, maxValue: 65535, irSubtraction: 0.25),
          'rgbir 16bit');
    });
  });
}
