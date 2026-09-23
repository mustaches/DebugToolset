/// Dart↔C 对拍：RAW 域组 2 —— fpn / bayer_dnr / highlight。
///
/// C 侧：test/c_ref/harness_raw2.c ->
/// lib/modules/isp_studio/c_ref/isp_fpn.c / isp_bayer_dnr.c / isp_highlight.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart 的
/// `applyFpn` / `applyBayerDenoise` / `applyHighlightRecovery`——
/// pipeline_runner.dart 的 `case 'fpn'` / `case 'bayer_dnr'` /
/// `case 'highlight'` 均为直通 kernel（mono 即 pattern: null），无额外
/// runner 语义，故基准直接调 kernel。
///
/// 比对口径：tol=0 逐位相等。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_raw2';

// ---------------------------------------------------------------------------
// Dart 基准（原地修改，故先复制输入）
// ---------------------------------------------------------------------------

Uint16List dartFpn(Uint16List input, int w, int h,
    {BayerPattern? pattern,
    bool row = true,
    bool col = true,
    double maxCorr = 64,
    int radius = 8}) {
  final out = Uint16List.fromList(input);
  applyFpn(out,
      width: w,
      height: h,
      pattern: pattern,
      row: row,
      col: col,
      maxCorr: maxCorr,
      radius: radius);
  return out;
}

Uint16List dartBayerDnr(Uint16List input, int w, int h,
    {BayerPattern? pattern, double strength = 1.0}) {
  final out = Uint16List.fromList(input);
  applyBayerDenoise(out,
      width: w, height: h, pattern: pattern, strength: strength);
  return out;
}

Uint16List dartHighlight(Uint16List input, int w, int h,
    {BayerPattern? pattern,
    int maxValue = 1023,
    String mode = 'recover',
    double knee = 0.9}) {
  final out = Uint16List.fromList(input);
  applyHighlightRecovery(out,
      width: w,
      height: h,
      pattern: pattern,
      maxValue: maxValue,
      mode: mode,
      knee: knee);
  return out;
}

// ---------------------------------------------------------------------------
// 专用构造帧
// ---------------------------------------------------------------------------

/// 含人造行/列偏置条纹的帧：LCG 噪声底叠加逐行偏置（-25/0/+25 循环）
/// 与逐列偏置（-15/0/+15/+30 循环），均在默认 maxCorr=64 限幅范围内。
Uint16List stripedFrame(int width, int height,
    {int maxValue = 1023, bool rowStripe = true, bool colStripe = true}) {
  final out = lcgFrame(width, height, 1, 7, maxValue: maxValue);
  for (var y = 0; y < height; y++) {
    final ro = rowStripe ? (y % 3 - 1) * 25 : 0;
    for (var x = 0; x < width; x++) {
      final co = colStripe ? (x % 4 - 1) * 15 : 0;
      out[y * width + x] =
          (out[y * width + x] + ro + co).clamp(0, maxValue);
    }
  }
  return out;
}

/// 含饱和像素簇的帧：渐变底（四角强制 0/maxValue）上叠加从偶数坐标
/// (bx, by) 开始的 bw×bh 全饱和块。
/// - bw=bh=4：块内每个像素的同相位（±2）邻域都有块外未饱和像素可用
///   （recover 路径「可用」形态）；
/// - bw=bh=8：内部 4x4 像素的同相位 8 邻域全部落在块内（饱和），
///   count==0 保持原值（「不可用」形态），边缘像素仍可恢复——一帧
///   同时覆盖两种形态。
Uint16List highlightFrame(int width, int height,
    {int maxValue = 1023, int bx = 8, int by = 8, int bw = 4, int bh = 4}) {
  final out = gradientFrame(width, height, 1, maxValue: maxValue);
  for (var y = by; y < by + bh && y < height; y++) {
    for (var x = bx; x < bx + bw && x < width; x++) {
      out[y * width + x] = maxValue;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_raw2: fpn/bayer_dnr/highlight C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ======================== fpn ========================
    group('fpn', () {
      test('64x48 RGGB 行+列条纹（默认 maxCorr=64 radius=8）', () async {
        const w = 64, h = 48;
        final input = stripedFrame(w, h);
        final c = await runCOp('fpn', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'rggb',
          'row': true,
          'col': true,
          'maxCorr': 64.0,
          'radius': 8,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartFpn(input, w, h, pattern: BayerPattern.rggb),
            context: 'fpn 行+列条纹');
      });

      test('64x48 BGGR 仅行校正', () async {
        const w = 64, h = 48;
        final input = stripedFrame(w, h, colStripe: false);
        final c = await runCOp('fpn', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'bggr',
          'row': true,
          'col': false,
          'maxCorr': 64.0,
          'radius': 8,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartFpn(input, w, h, pattern: BayerPattern.bggr, col: false),
            context: 'fpn 仅行');
      });

      test('64x48 mono 仅列校正（pattern 不参与统计）', () async {
        const w = 64, h = 48;
        final input = stripedFrame(w, h, rowStripe: false);
        final c = await runCOp('fpn', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'mono',
          'row': false,
          'col': true,
          'maxCorr': 64.0,
          'radius': 8,
        }, inputs: [
          input
        ]);
        expectFramesEqual(c.outputs[0],
            dartFpn(input, w, h, pattern: null, row: false),
            context: 'fpn mono 仅列');
      });

      test('64x48 GBRG 行+列，radius=3 + 小数 maxCorr=32.5', () async {
        const w = 64, h = 48;
        final input = stripedFrame(w, h);
        final c = await runCOp('fpn', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'gbrg',
          'row': true,
          'col': true,
          'maxCorr': 32.5,
          'radius': 3,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartFpn(input, w, h,
                pattern: BayerPattern.gbrg, maxCorr: 32.5, radius: 3),
            context: 'fpn radius=3 maxCorr=32.5');
      });

      test('8x6 小图（radius 大于帧尺寸，滑窗全程截断）行+列条纹', () async {
        const w = 8, h = 6;
        final input = stripedFrame(w, h);
        final c = await runCOp('fpn', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'rggb',
          'row': true,
          'col': true,
          'maxCorr': 64.0,
          'radius': 8,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartFpn(input, w, h, pattern: BayerPattern.rggb),
            context: 'fpn 8x6 小图');
      });

      test('32x24 极值帧：全 0 与全 maxValue（corr=0 跳过/截零路径）',
          () async {
        const w = 32, h = 24;
        for (final v in [0, 1023]) {
          final input = constantFrame(w, h, 1, v);
          final c = await runCOp('fpn', tag: _tag, params: {
            'width': w,
            'height': h,
            'pattern': 'rggb',
            'row': true,
            'col': true,
            'maxCorr': 64.0,
            'radius': 8,
          }, inputs: [
            input
          ]);
          expectFramesEqual(
              c.outputs[0],
              dartFpn(input, w, h, pattern: BayerPattern.rggb),
              context: 'fpn 常量帧 v=$v');
        }
      });

      test('32x24 渐变帧（0/max 角点）行+列', () async {
        const w = 32, h = 24;
        final input = gradientFrame(w, h, 1, maxValue: 1023);
        final c = await runCOp('fpn', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'grbg',
          'row': true,
          'col': true,
          'maxCorr': 64.0,
          'radius': 8,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartFpn(input, w, h, pattern: BayerPattern.grbg),
            context: 'fpn 渐变帧');
      });
    });

    // ======================== bayer_dnr ========================
    group('bayer_dnr', () {
      for (final strength in [0.5, 1.0, 2.0]) {
        test('64x48 RGGB strength=$strength', () async {
          const w = 64, h = 48;
          final input = lcgFrame(w, h, 1, 11, maxValue: 1023);
          final c = await runCOp('bayer_dnr', tag: _tag, params: {
            'width': w,
            'height': h,
            'pattern': 'rggb',
            'strength': strength,
          }, inputs: [
            input
          ]);
          expectFramesEqual(
              c.outputs[0],
              dartBayerDnr(input, w, h,
                  pattern: BayerPattern.rggb, strength: strength),
              context: 'bayer_dnr rggb s=$strength');
        });
      }

      test('64x48 mono strength=1.0（全像素 3x3）', () async {
        const w = 64, h = 48;
        final input = lcgFrame(w, h, 1, 12, maxValue: 1023);
        final c = await runCOp('bayer_dnr', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'mono',
          'strength': 1.0,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0], dartBayerDnr(input, w, h, pattern: null),
            context: 'bayer_dnr mono');
      });

      test('64x48 GRBG strength=2.0 渐变帧（0/max 角点）', () async {
        const w = 64, h = 48;
        final input = gradientFrame(w, h, 1, maxValue: 1023);
        final c = await runCOp('bayer_dnr', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'grbg',
          'strength': 2.0,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartBayerDnr(input, w, h,
                pattern: BayerPattern.grbg, strength: 2.0),
            context: 'bayer_dnr 渐变帧');
      });

      test('4x4 / 2x2 小图边界（邻域裁剪到 3 样本）', () async {
        for (final (w, h, pat, dartPat) in [
          (4, 4, 'rggb', BayerPattern.rggb),
          (2, 2, 'mono', null),
        ]) {
          final input = lcgFrame(w, h, 1, 13, maxValue: 1023);
          final c = await runCOp('bayer_dnr', tag: _tag, params: {
            'width': w,
            'height': h,
            'pattern': pat,
            'strength': 1.0,
          }, inputs: [
            input
          ]);
          expectFramesEqual(c.outputs[0],
              dartBayerDnr(input, w, h, pattern: dartPat),
              context: 'bayer_dnr ${w}x$h $pat');
        }
      });

      test('32x24 极值帧：全 0 与全 1023', () async {
        const w = 32, h = 24;
        for (final v in [0, 1023]) {
          final input = constantFrame(w, h, 1, v);
          final c = await runCOp('bayer_dnr', tag: _tag, params: {
            'width': w,
            'height': h,
            'pattern': 'bggr',
            'strength': 1.0,
          }, inputs: [
            input
          ]);
          expectFramesEqual(
              c.outputs[0],
              dartBayerDnr(input, w, h, pattern: BayerPattern.bggr),
              context: 'bayer_dnr 常量帧 v=$v');
        }
      });

      test('32x24 RGGB maxValue=65535（16 位量级）strength=1.0', () async {
        const w = 32, h = 24;
        final input = lcgFrame(w, h, 1, 14, maxValue: 65535);
        final c = await runCOp('bayer_dnr', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'rggb',
          'strength': 1.0,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartBayerDnr(input, w, h, pattern: BayerPattern.rggb),
            context: 'bayer_dnr 65535');
      });

      test('32x24 strength=0 空操作（输出恒等输入）', () async {
        const w = 32, h = 24;
        final input = lcgFrame(w, h, 1, 15, maxValue: 1023);
        final c = await runCOp('bayer_dnr', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'rggb',
          'strength': 0.0,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartBayerDnr(input, w, h,
                pattern: BayerPattern.rggb, strength: 0.0),
            context: 'bayer_dnr strength=0');
      });
    });

    // ======================== highlight ========================
    group('highlight', () {
      test('64x48 RGGB recover knee=0.9，4x4 饱和簇（同相位邻域可用）',
          () async {
        const w = 64, h = 48;
        final input = highlightFrame(w, h, bw: 4, bh: 4);
        final c = await runCOp('highlight', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'rggb',
          'maxValue': 1023,
          'mode': 'recover',
          'knee': 0.9,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartHighlight(input, w, h, pattern: BayerPattern.rggb),
            context: 'highlight recover 可恢复簇');
      });

      test('64x48 RGGB recover knee=0.9，8x8 饱和簇（内部同相位邻域全饱和'
          ' count==0 保持原值，边缘可恢复——一帧覆盖两种形态）', () async {
        const w = 64, h = 48;
        final input = highlightFrame(w, h, bw: 8, bh: 8);
        final c = await runCOp('highlight', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'rggb',
          'maxValue': 1023,
          'mode': 'recover',
          'knee': 0.9,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartHighlight(input, w, h, pattern: BayerPattern.rggb),
            context: 'highlight recover 混合簇');
      });

      test('64x48 mono recover knee=0.95（kneePt=972.45 非整数，'
          '检验 int->double 浮点饱和判定）', () async {
        const w = 64, h = 48;
        final input = highlightFrame(w, h, bw: 8, bh: 8);
        final c = await runCOp('highlight', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'mono',
          'maxValue': 1023,
          'mode': 'recover',
          'knee': 0.95,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartHighlight(input, w, h, pattern: null, knee: 0.95),
            context: 'highlight mono recover knee=0.95');
      });

      test('64x48 RGGB clip knee=0.9（含饱和簇与 0/max 角点）', () async {
        const w = 64, h = 48;
        final input = highlightFrame(w, h, bw: 8, bh: 8);
        final c = await runCOp('highlight', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'rggb',
          'maxValue': 1023,
          'mode': 'clip',
          'knee': 0.9,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartHighlight(input, w, h,
                pattern: BayerPattern.rggb, mode: 'clip'),
            context: 'highlight clip knee=0.9');
      });

      test('64x48 BGGR clip knee=0.75 LCG 帧', () async {
        const w = 64, h = 48;
        final input = lcgFrame(w, h, 1, 21, maxValue: 1023);
        final c = await runCOp('highlight', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'bggr',
          'maxValue': 1023,
          'mode': 'clip',
          'knee': 0.75,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartHighlight(input, w, h,
                pattern: BayerPattern.bggr, mode: 'clip', knee: 0.75),
            context: 'highlight clip knee=0.75');
      });

      test('64x48 mono clip knee=0.8 maxValue=65535（16 位量级）', () async {
        const w = 64, h = 48;
        final input = lcgFrame(w, h, 1, 22, maxValue: 65535);
        final c = await runCOp('highlight', tag: _tag, params: {
          'width': w,
          'height': h,
          'pattern': 'mono',
          'maxValue': 65535,
          'mode': 'clip',
          'knee': 0.8,
        }, inputs: [
          input
        ]);
        expectFramesEqual(
            c.outputs[0],
            dartHighlight(input, w, h,
                pattern: null, maxValue: 65535, mode: 'clip', knee: 0.8),
            context: 'highlight mono clip 65535');
      });

      test('6x4 小图 recover + clip（饱和像素贴边/角点邻域裁剪）', () async {
        const w = 6, h = 4;
        final input = gradientFrame(w, h, 1, maxValue: 1023);
        // 角块饱和（贴帧边缘，邻域裁剪路径）
        input[0] = 1023;
        input[1] = 1023;
        input[w] = 1023;
        for (final mode in ['recover', 'clip']) {
          final c = await runCOp('highlight', tag: _tag, params: {
            'width': w,
            'height': h,
            'pattern': 'rggb',
            'maxValue': 1023,
            'mode': mode,
            'knee': 0.9,
          }, inputs: [
            input
          ]);
          expectFramesEqual(
              c.outputs[0],
              dartHighlight(input, w, h,
                  pattern: BayerPattern.rggb, mode: mode),
              context: 'highlight 6x4 $mode');
        }
      });

      test('32x24 极值帧：全 0 / 全 1023 × recover/clip', () async {
        const w = 32, h = 24;
        for (final v in [0, 1023]) {
          for (final mode in ['recover', 'clip']) {
            final input = constantFrame(w, h, 1, v);
            final c = await runCOp('highlight', tag: _tag, params: {
              'width': w,
              'height': h,
              'pattern': 'rggb',
              'maxValue': 1023,
              'mode': mode,
              'knee': 0.9,
            }, inputs: [
              input
            ]);
            expectFramesEqual(
                c.outputs[0],
                dartHighlight(input, w, h,
                    pattern: BayerPattern.rggb, mode: mode),
                context: 'highlight 常量帧 v=$v $mode');
          }
        }
      });

      test('32x24 clip knee=1.0（range=0 空操作）+ recover knee=1.0'
          '（kneePt=1023 整数值恰好饱和）', () async {
        const w = 32, h = 24;
        final input = highlightFrame(w, h, bx: 4, by: 4, bw: 4, bh: 4);
        for (final mode in ['clip', 'recover']) {
          final c = await runCOp('highlight', tag: _tag, params: {
            'width': w,
            'height': h,
            'pattern': 'grbg',
            'maxValue': 1023,
            'mode': mode,
            'knee': 1.0,
          }, inputs: [
            input
          ]);
          expectFramesEqual(
              c.outputs[0],
              dartHighlight(input, w, h,
                  pattern: BayerPattern.grbg, mode: mode, knee: 1.0),
              context: 'highlight knee=1.0 $mode');
        }
      });
    });
  });

  group('isp_c_ref_compare_raw2: 高光 clip LUT 查表 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    /// LUT 模式一条龙：Dart highlightClipLut 建表 → 表经输入文件传给 C
    /// 侧 isp_highlight_clip_lut_apply，与 Dart 查表基准逐位比对。
    Future<void> checkClipLut(String context, Uint16List input, int w, int h,
        double knee,
        {int maxValue = 1023}) async {
      final lut = highlightClipLut(knee, maxValue);
      final c = await runCOp('highlight_clip_lut', params: {
        'width': w,
        'height': h,
        'max_value': maxValue,
      }, inputs: [
        input,
        lut,
      ], tag: _tag);
      final expected = Uint16List.fromList(input);
      applyHighlightClipLut(expected, lut);
      expectFramesEqual(c.outputs[0], expected, context: context);
    }

    test('64x48 knee=0.9 默认（膝点以上软压缩）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 81, maxValue: 1023);
      await checkClipLut('knee0.9', input, w, h, 0.9);
    });

    test('32x24 knee=0.5（大范围压缩段）', () async {
      const w = 32, h = 24;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      await checkClipLut('knee0.5', input, w, h, 0.5);
    });

    test('16x16 knee=1.0（range=0 全恒等分支）', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 1, 82, maxValue: 1023);
      await checkClipLut('knee1.0', input, w, h, 1.0);
    });

    test('16x16 maxValue=65535 knee=0.75', () async {
      const w = 16, h = 16;
      final input = lcgFrame(w, h, 1, 83, maxValue: 65535);
      await checkClipLut('65535 knee0.75', input, w, h, 0.75,
          maxValue: 65535);
    });
  });
}
