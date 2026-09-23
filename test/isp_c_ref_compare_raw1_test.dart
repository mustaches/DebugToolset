/// Dart↔C 对拍：RAW 域组 1 端到端样例 —— black_level（黑电平校正）。
///
/// C 侧：test/c_ref/harness_raw1.c `op_black_level` ->
/// lib/modules/isp_studio/c_ref/isp_black_level.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart
/// `applyBlackLevel`（mosaic）；mono 形态复刻 pipeline_runner.dart
/// `case 'black_level'` 的 mono 分支（语义在 runner 而非 kernel，见下注）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

/// Dart 侧 mosaic 基准：直接调 applyBlackLevel（原地修改，故先复制输入）。
Uint16List dartBlackLevelMosaic(Uint16List input, int width, int height,
    BayerPattern pattern, double r, double gr, double gb, double b) {
  final out = Uint16List.fromList(input);
  applyBlackLevel(out,
      width: width, height: height, pattern: pattern, r: r, gr: gr, gb: gb, b: b);
  return out;
}

/// Dart 侧 mono 基准：mono 语义在 pipeline_runner.dart `case 'black_level'`
/// 的 mono 分支（frame.format == 'mono' 时用 r 参数统一扣除，截零、round），
/// kernel 层无对应函数，这里逐行复刻该分支逻辑（off != 0 的跳过为恒等优化，
/// 不影响数值结果）。
Uint16List dartBlackLevelMono(Uint16List input, double offset) {
  final out = Uint16List.fromList(input);
  if (offset != 0) {
    for (var i = 0; i < out.length; i++) {
      final v = out[i] - offset;
      out[i] = v <= 0 ? 0 : v.round();
    }
  }
  return out;
}

Future<void> main() async {
  final built = await ensureHarnessBuilt();

  group('isp_c_ref_compare_raw1: black_level C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    test('64x48 RGGB 四相位不同偏移（含小数检验 round）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 1, maxValue: 1023);
      const r = 64.5, gr = 32.25, gb = 16.75, b = 8.125;
      final c = await runCOp('black_level', params: {
        'width': w,
        'height': h,
        'pattern': 'rggb',
        'r': r,
        'gr': gr,
        'gb': gb,
        'b': b,
      }, inputs: [
        input
      ]);
      expectFramesEqual(
          c.outputs[0], dartBlackLevelMosaic(input, w, h, BayerPattern.rggb, r, gr, gb, b),
          context: 'rggb 四相位');
    });

    test('64x48 mono 统一偏移（复刻 runner mono 分支）', () async {
      const w = 64, h = 48;
      final input = lcgFrame(w, h, 1, 2, maxValue: 1023);
      const off = 48.5;
      final c = await runCOp('black_level', params: {
        'width': w,
        'height': h,
        'pattern': 'mono',
        'r': off,
      }, inputs: [
        input
      ]);
      expectFramesEqual(c.outputs[0], dartBlackLevelMono(input, off),
          context: 'mono 统一偏移');
    });

    test('32x32 RGGB 大偏移截零（多数像素 v<=0 归零）', () async {
      const w = 32, h = 32;
      final input = lcgFrame(w, h, 1, 3, maxValue: 1023);
      const r = 2000.0, gr = 1500.0, gb = 1200.0, b = 900.0;
      final c = await runCOp('black_level', params: {
        'width': w,
        'height': h,
        'pattern': 'rggb',
        'r': r,
        'gr': gr,
        'gb': gb,
        'b': b,
      }, inputs: [
        input
      ]);
      expectFramesEqual(
          c.outputs[0], dartBlackLevelMosaic(input, w, h, BayerPattern.rggb, r, gr, gb, b),
          context: '大偏移截零');
    });

    test('4x4 小图边界 + 0/max 角点', () async {
      const w = 4, h = 4;
      final input = gradientFrame(w, h, 1, maxValue: 1023);
      const r = 1.5, gr = 0.5, gb = 2.5, b = 3.5;
      final c = await runCOp('black_level', params: {
        'width': w,
        'height': h,
        'pattern': 'rggb',
        'r': r,
        'gr': gr,
        'gb': gb,
        'b': b,
      }, inputs: [
        input
      ]);
      expectFramesEqual(
          c.outputs[0], dartBlackLevelMosaic(input, w, h, BayerPattern.rggb, r, gr, gb, b),
          context: '4x4 小图');
    });

    test('32x24 BGGR 图案（相位归属换序）', () async {
      const w = 32, h = 24;
      final input = lcgFrame(w, h, 1, 5, maxValue: 65535);
      const r = 100.4, gr = 200.6, gb = 300.2, b = 400.8;
      final c = await runCOp('black_level', params: {
        'width': w,
        'height': h,
        'pattern': 'bggr',
        'r': r,
        'gr': gr,
        'gb': gb,
        'b': b,
      }, inputs: [
        input
      ]);
      expectFramesEqual(
          c.outputs[0], dartBlackLevelMosaic(input, w, h, BayerPattern.bggr, r, gr, gb, b),
          context: 'bggr');
    });
  });
}
