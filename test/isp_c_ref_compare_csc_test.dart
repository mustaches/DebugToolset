/// Dart↔C 对拍：色彩空间转换组（csc）—— rgb/yuv/hsl 六向互换。
///
/// C 侧：test/c_ref/harness_csc.c -> lib/modules/isp_studio/c_ref/isp_csc_*.c
///（isp_csc 全家桶已按变体拆分，共享部分在 isp_csc_common.h）。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart 的
/// convertRgbToYuvCsc / rgbToHsl / yuvToRgb / yuvToHsl / hslToRgb / hslToYuv
/// （均为 kernel 层函数，直接调用即可，无语义在 runner 的分支）。
///
/// 注意：对拍是 C 输出 vs Dart 输出逐位比对（tol=0），不是数学往返一致性；
/// 往返链路（rgb→yuv→rgb）误差有界不构成本组的对拍依据。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const tag = '_grp_csc';
const mainW = 64, mainH = 48;
const mainMax = 1023;

/// 一次 csc op 对拍：跑 C harness，与 Dart 基准逐位比对。
Future<void> compareCsc(String op, Uint16List input,
    {required int width,
    required int height,
    int maxValue = mainMax,
    Map<String, Object?> extraParams = const {},
    required Uint16List Function() dartBaseline,
    required String context}) async {
  final c = await runCOp(op, tag: tag, params: {
    'width': width,
    'height': height,
    'max_value': maxValue,
    ...extraParams,
  }, inputs: [
    input
  ]);
  expectFramesEqual(c.outputs[0], dartBaseline(), context: context);
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: tag);

  group('isp_c_ref_compare_csc: 色彩空间转换 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ---------------------------------------------------------------------
    // csc_rgb2yuv：standard（bt601/bt709）× range（full/limited）四组合
    // ---------------------------------------------------------------------
    group('csc_rgb2yuv', () {
      for (final standard in ['bt601', 'bt709']) {
        for (final range in ['full', 'limited']) {
          test('64x48 LCG $standard/$range', () async {
            final input = lcgFrame(mainW, mainH, 3, 11, maxValue: mainMax);
            await compareCsc('csc_rgb2yuv', input,
                width: mainW,
                height: mainH,
                extraParams: {'standard': standard, 'range': range},
                dartBaseline: () => convertRgbToYuvCsc(input,
                    width: mainW,
                    height: mainH,
                    standard: standard,
                    range: range,
                    maxValue: mainMax),
                context: 'rgb2yuv $standard/$range lcg');
          });
        }
      }

      test('64x48 渐变帧（含 0/max 角点）bt601/limited', () async {
        final input = gradientFrame(mainW, mainH, 3, maxValue: mainMax);
        await compareCsc('csc_rgb2yuv', input,
            width: mainW,
            height: mainH,
            extraParams: {'standard': 'bt601', 'range': 'limited'},
            dartBaseline: () => convertRgbToYuvCsc(input,
                width: mainW,
                height: mainH,
                standard: 'bt601',
                range: 'limited',
                maxValue: mainMax),
            context: 'rgb2yuv bt601/limited gradient');
      });

      test('极值帧 全 0 / 全 max（bt709/full）', () async {
        for (final v in [0, mainMax]) {
          final input = constantFrame(mainW, mainH, 3, v);
          await compareCsc('csc_rgb2yuv', input,
              width: mainW,
              height: mainH,
              extraParams: {'standard': 'bt709', 'range': 'full'},
              dartBaseline: () => convertRgbToYuvCsc(input,
                  width: mainW,
                  height: mainH,
                  standard: 'bt709',
                  range: 'full',
                  maxValue: mainMax),
              context: 'rgb2yuv bt709/full const=$v');
        }
      });

      test('4x4 小图 bt709/limited', () async {
        const w = 4, h = 4;
        final input = lcgFrame(w, h, 3, 12, maxValue: mainMax);
        await compareCsc('csc_rgb2yuv', input,
            width: w,
            height: h,
            extraParams: {'standard': 'bt709', 'range': 'limited'},
            dartBaseline: () => convertRgbToYuvCsc(input,
                width: w,
                height: h,
                standard: 'bt709',
                range: 'limited',
                maxValue: mainMax),
            context: 'rgb2yuv 4x4');
      });

      test('32x24 maxValue=65535 bt601/limited', () async {
        const w = 32, h = 24, mv = 65535;
        final input = lcgFrame(w, h, 3, 13, maxValue: mv);
        await compareCsc('csc_rgb2yuv', input,
            width: w,
            height: h,
            maxValue: mv,
            extraParams: {'standard': 'bt601', 'range': 'limited'},
            dartBaseline: () => convertRgbToYuvCsc(input,
                width: w,
                height: h,
                standard: 'bt601',
                range: 'limited',
                maxValue: mv),
            context: 'rgb2yuv 65535 limited');
      });
    });

    // ---------------------------------------------------------------------
    // csc_rgb2hsl
    // ---------------------------------------------------------------------
    group('csc_rgb2hsl', () {
      test('64x48 LCG', () async {
        final input = lcgFrame(mainW, mainH, 3, 21, maxValue: mainMax);
        await compareCsc('csc_rgb2hsl', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => rgbToHsl(input, maxValue: mainMax),
            context: 'rgb2hsl lcg');
      });

      test('64x48 渐变帧（含 0/max 角点）', () async {
        final input = gradientFrame(mainW, mainH, 3, maxValue: mainMax);
        await compareCsc('csc_rgb2hsl', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => rgbToHsl(input, maxValue: mainMax),
            context: 'rgb2hsl gradient');
      });

      test('极值帧 全 0 / 全 max（灰像素 H=S=0 分支）', () async {
        for (final v in [0, mainMax]) {
          final input = constantFrame(mainW, mainH, 3, v);
          await compareCsc('csc_rgb2hsl', input,
              width: mainW,
              height: mainH,
              dartBaseline: () => rgbToHsl(input, maxValue: mainMax),
              context: 'rgb2hsl const=$v');
        }
      });

      test('4x4 小图', () async {
        const w = 4, h = 4;
        final input = lcgFrame(w, h, 3, 22, maxValue: mainMax);
        await compareCsc('csc_rgb2hsl', input,
            width: w,
            height: h,
            dartBaseline: () => rgbToHsl(input, maxValue: mainMax),
            context: 'rgb2hsl 4x4');
      });

      test('32x24 maxValue=65535', () async {
        const w = 32, h = 24, mv = 65535;
        final input = lcgFrame(w, h, 3, 23, maxValue: mv);
        await compareCsc('csc_rgb2hsl', input,
            width: w,
            height: h,
            maxValue: mv,
            dartBaseline: () => rgbToHsl(input, maxValue: mv),
            context: 'rgb2hsl 65535');
      });
    });

    // ---------------------------------------------------------------------
    // csc_yuv2rgb
    // ---------------------------------------------------------------------
    group('csc_yuv2rgb', () {
      test('64x48 LCG', () async {
        final input = lcgFrame(mainW, mainH, 3, 31, maxValue: mainMax);
        await compareCsc('csc_yuv2rgb', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => yuvToRgb(input, maxValue: mainMax),
            context: 'yuv2rgb lcg');
      });

      test('64x48 渐变帧（含 0/max 角点）', () async {
        final input = gradientFrame(mainW, mainH, 3, maxValue: mainMax);
        await compareCsc('csc_yuv2rgb', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => yuvToRgb(input, maxValue: mainMax),
            context: 'yuv2rgb gradient');
      });

      test('极值帧 全 0 / 全 max（溢出钳位路径）', () async {
        for (final v in [0, mainMax]) {
          final input = constantFrame(mainW, mainH, 3, v);
          await compareCsc('csc_yuv2rgb', input,
              width: mainW,
              height: mainH,
              dartBaseline: () => yuvToRgb(input, maxValue: mainMax),
              context: 'yuv2rgb const=$v');
        }
      });

      test('4x4 小图', () async {
        const w = 4, h = 4;
        final input = lcgFrame(w, h, 3, 32, maxValue: mainMax);
        await compareCsc('csc_yuv2rgb', input,
            width: w,
            height: h,
            dartBaseline: () => yuvToRgb(input, maxValue: mainMax),
            context: 'yuv2rgb 4x4');
      });

      test('32x24 maxValue=65535', () async {
        const w = 32, h = 24, mv = 65535;
        final input = lcgFrame(w, h, 3, 33, maxValue: mv);
        await compareCsc('csc_yuv2rgb', input,
            width: w,
            height: h,
            maxValue: mv,
            dartBaseline: () => yuvToRgb(input, maxValue: mv),
            context: 'yuv2rgb 65535');
      });
    });

    // ---------------------------------------------------------------------
    // csc_yuv2hsl（单遍融合：yuvToRgb 定点中间值 + rgbToHsl 逻辑）
    // ---------------------------------------------------------------------
    group('csc_yuv2hsl', () {
      test('64x48 LCG', () async {
        final input = lcgFrame(mainW, mainH, 3, 41, maxValue: mainMax);
        await compareCsc('csc_yuv2hsl', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => yuvToHsl(input, maxValue: mainMax),
            context: 'yuv2hsl lcg');
      });

      test('64x48 渐变帧（含 0/max 角点）', () async {
        final input = gradientFrame(mainW, mainH, 3, maxValue: mainMax);
        await compareCsc('csc_yuv2hsl', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => yuvToHsl(input, maxValue: mainMax),
            context: 'yuv2hsl gradient');
      });

      test('极值帧 全 0 / 全 max', () async {
        for (final v in [0, mainMax]) {
          final input = constantFrame(mainW, mainH, 3, v);
          await compareCsc('csc_yuv2hsl', input,
              width: mainW,
              height: mainH,
              dartBaseline: () => yuvToHsl(input, maxValue: mainMax),
              context: 'yuv2hsl const=$v');
        }
      });

      test('4x4 小图', () async {
        const w = 4, h = 4;
        final input = lcgFrame(w, h, 3, 42, maxValue: mainMax);
        await compareCsc('csc_yuv2hsl', input,
            width: w,
            height: h,
            dartBaseline: () => yuvToHsl(input, maxValue: mainMax),
            context: 'yuv2hsl 4x4');
      });

      test('32x24 maxValue=65535', () async {
        const w = 32, h = 24, mv = 65535;
        final input = lcgFrame(w, h, 3, 43, maxValue: mv);
        await compareCsc('csc_yuv2hsl', input,
            width: w,
            height: h,
            maxValue: mv,
            dartBaseline: () => yuvToHsl(input, maxValue: mv),
            context: 'yuv2hsl 65535');
      });
    });

    // ---------------------------------------------------------------------
    // csc_hsl2rgb
    // ---------------------------------------------------------------------
    group('csc_hsl2rgb', () {
      test('64x48 LCG', () async {
        final input = lcgFrame(mainW, mainH, 3, 51, maxValue: mainMax);
        await compareCsc('csc_hsl2rgb', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => hslToRgb(input, maxValue: mainMax),
            context: 'hsl2rgb lcg');
      });

      test('64x48 渐变帧（含 0/max 角点）', () async {
        final input = gradientFrame(mainW, mainH, 3, maxValue: mainMax);
        await compareCsc('csc_hsl2rgb', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => hslToRgb(input, maxValue: mainMax),
            context: 'hsl2rgb gradient');
      });

      test('极值帧 全 0 / 全 max（S=0 灰分支 + H=max 色环绕回）', () async {
        for (final v in [0, mainMax]) {
          final input = constantFrame(mainW, mainH, 3, v);
          await compareCsc('csc_hsl2rgb', input,
              width: mainW,
              height: mainH,
              dartBaseline: () => hslToRgb(input, maxValue: mainMax),
              context: 'hsl2rgb const=$v');
        }
      });

      test('H=max 环绕 + S=max 饱和（hueToRgb 分段全命中）', () async {
        // H=max_value 时 (h*inv)%1.0=0.0 绕回 0°；S=max 走 q/p 分支；
        // 横扫 H 覆盖 hueToRgb 的 1/6、1/2、2/3 各分段。
        final input = Uint16List(mainW * mainH * 3);
        for (var y = 0; y < mainH; y++) {
          for (var x = 0; x < mainW; x++) {
            final i = (y * mainW + x) * 3;
            input[i] = (x * mainMax) ~/ (mainW - 1); // H 0..max
            input[i + 1] = mainMax; // S=max
            input[i + 2] = (y * mainMax) ~/ (mainH - 1); // L 0..max
          }
        }
        await compareCsc('csc_hsl2rgb', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => hslToRgb(input, maxValue: mainMax),
            context: 'hsl2rgb H 全扫 S=max');
      });

      test('4x4 小图', () async {
        const w = 4, h = 4;
        final input = lcgFrame(w, h, 3, 52, maxValue: mainMax);
        await compareCsc('csc_hsl2rgb', input,
            width: w,
            height: h,
            dartBaseline: () => hslToRgb(input, maxValue: mainMax),
            context: 'hsl2rgb 4x4');
      });

      test('32x24 maxValue=65535', () async {
        const w = 32, h = 24, mv = 65535;
        final input = lcgFrame(w, h, 3, 53, maxValue: mv);
        await compareCsc('csc_hsl2rgb', input,
            width: w,
            height: h,
            maxValue: mv,
            dartBaseline: () => hslToRgb(input, maxValue: mv),
            context: 'hsl2rgb 65535');
      });
    });

    // ---------------------------------------------------------------------
    // csc_hsl2yuv（单遍融合：hslToRgb 逻辑 + rgbToYuv 定点公式）
    // ---------------------------------------------------------------------
    group('csc_hsl2yuv', () {
      test('64x48 LCG', () async {
        final input = lcgFrame(mainW, mainH, 3, 61, maxValue: mainMax);
        await compareCsc('csc_hsl2yuv', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => hslToYuv(input, maxValue: mainMax),
            context: 'hsl2yuv lcg');
      });

      test('64x48 渐变帧（含 0/max 角点）', () async {
        final input = gradientFrame(mainW, mainH, 3, maxValue: mainMax);
        await compareCsc('csc_hsl2yuv', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => hslToYuv(input, maxValue: mainMax),
            context: 'hsl2yuv gradient');
      });

      test('极值帧 全 0 / 全 max（S=0 灰分支 + H=max 环绕）', () async {
        for (final v in [0, mainMax]) {
          final input = constantFrame(mainW, mainH, 3, v);
          await compareCsc('csc_hsl2yuv', input,
              width: mainW,
              height: mainH,
              dartBaseline: () => hslToYuv(input, maxValue: mainMax),
              context: 'hsl2yuv const=$v');
        }
      });

      test('H 全扫 + S/L 交叉（hueToRgb 分段全命中）', () async {
        final input = Uint16List(mainW * mainH * 3);
        for (var y = 0; y < mainH; y++) {
          for (var x = 0; x < mainW; x++) {
            final i = (y * mainW + x) * 3;
            input[i] = (x * mainMax) ~/ (mainW - 1); // H 0..max
            input[i + 1] = (y * mainMax) ~/ (mainH - 1); // S 0..max
            input[i + 2] = ((x + y) * mainMax) ~/ (mainW + mainH - 2); // L
          }
        }
        await compareCsc('csc_hsl2yuv', input,
            width: mainW,
            height: mainH,
            dartBaseline: () => hslToYuv(input, maxValue: mainMax),
            context: 'hsl2yuv H/S/L 交叉');
      });

      test('4x4 小图', () async {
        const w = 4, h = 4;
        final input = lcgFrame(w, h, 3, 62, maxValue: mainMax);
        await compareCsc('csc_hsl2yuv', input,
            width: w,
            height: h,
            dartBaseline: () => hslToYuv(input, maxValue: mainMax),
            context: 'hsl2yuv 4x4');
      });

      test('32x24 maxValue=65535', () async {
        const w = 32, h = 24, mv = 65535;
        final input = lcgFrame(w, h, 3, 63, maxValue: mv);
        await compareCsc('csc_hsl2yuv', input,
            width: w,
            height: h,
            maxValue: mv,
            dartBaseline: () => hslToYuv(input, maxValue: mv),
            context: 'hsl2yuv 65535');
      });
    });
  });
}
