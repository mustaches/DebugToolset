/// Dart↔C 对拍：CLAHE 组 —— clahe_rgb / clahe_mono（自适应直方图均衡）。
///
/// C 侧：test/c_ref/harness_clahe.c `op_clahe_rgb` / `op_clahe_mono` ->
/// lib/modules/isp_studio/c_ref/isp_clahe.c。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart
/// `applyClahe` / `applyClaheMono`（语义完整在 kernel 层；
/// pipeline_runner.dart `case 'ahe'` 只是拷贝入帧后直调这两个函数，
/// 无额外数值语义）。
///
/// 用例维度：blockSize 16/32 × clipLimit 1.0/2.0/4.0 × strength 0/0.5/1.0
/// 挑代表组合；尺寸覆盖 64x48（整块）、48x32（非整块，tile 尾块裁剪路径）、
/// 8x8（单 tile）；帧型覆盖 LCG 随机、渐变（0/max 角点）、亮度平坦、
/// 半黑半白强反差；另有 strength=0 直通与 maxValue=65535 用例。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_clahe';

/// Dart 侧 RGB 基准：applyClahe 原地修改，故先复制输入。
Uint16List dartClaheRgb(Uint16List input, int width, int height, int blockSize,
    double clipLimit, double strength, int maxValue) {
  final out = Uint16List.fromList(input);
  applyClahe(out,
      width: width,
      height: height,
      blockSize: blockSize,
      clipLimit: clipLimit,
      strength: strength,
      maxValue: maxValue);
  return out;
}

/// Dart 侧 mono 基准：applyClaheMono 原地修改，故先复制输入。
Uint16List dartClaheMono(Uint16List input, int width, int height, int blockSize,
    double clipLimit, double strength, int maxValue) {
  final out = Uint16List.fromList(input);
  applyClaheMono(out,
      width: width,
      height: height,
      blockSize: blockSize,
      clipLimit: clipLimit,
      strength: strength,
      maxValue: maxValue);
  return out;
}

/// 强反差帧：左半全 0、右半全 maxValue（直方图极端双峰，裁剪再分配路径
/// 的极端形态）。
Uint16List contrastFrame(int width, int height, int channels, int maxValue) {
  final out = Uint16List(width * height * channels);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = x < width ~/ 2 ? 0 : maxValue;
      for (var c = 0; c < channels; c++) {
        out[(y * width + x) * channels + c] = v;
      }
    }
  }
  return out;
}

Future<COpResult> _run(String op, int w, int h, Uint16List input,
    {int blockSize = 32,
    double clipLimit = 2.0,
    double strength = 1.0,
    int maxValue = 1023}) {
  return runCOp(op, params: {
    'width': w,
    'height': h,
    'blockSize': blockSize,
    'clipLimit': clipLimit,
    'strength': strength,
    'max_value': maxValue,
  }, inputs: [
    input
  ], tag: _tag);
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_clahe: CLAHE C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    group('clahe_rgb', () {
      test('64x48 bs16 clip2.0 st1.0 LCG', () async {
        const w = 64, h = 48;
        final input = lcgFrame(w, h, 3, 11, maxValue: 1023);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 16, 2.0, 1.0, 1023),
            context: 'rgb 64x48 bs16');
      });

      test('64x48 bs32 clip1.0 st0.5 渐变帧', () async {
        const w = 64, h = 48;
        final input = gradientFrame(w, h, 3, maxValue: 1023);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 32, clipLimit: 1.0, strength: 0.5);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 32, 1.0, 0.5, 1023),
            context: 'rgb 64x48 bs32 渐变');
      });

      test('48x32 bs16 clip4.0 st1.0 非整块（tile 尾块裁剪）', () async {
        const w = 48, h = 32;
        final input = lcgFrame(w, h, 3, 12, maxValue: 1023);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 16, clipLimit: 4.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 16, 4.0, 1.0, 1023),
            context: 'rgb 48x32 非整块');
      });

      test('48x32 bs32 clip2.0 st0.5 非整块 2x1 tile 网格', () async {
        const w = 48, h = 32;
        final input = gradientFrame(w, h, 3, maxValue: 1023);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 32, clipLimit: 2.0, strength: 0.5);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 32, 2.0, 0.5, 1023),
            context: 'rgb 48x32 bs32');
      });

      test('8x8 bs16 单 tile 小图', () async {
        const w = 8, h = 8;
        final input = lcgFrame(w, h, 3, 13, maxValue: 1023);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 16, 2.0, 1.0, 1023),
            context: 'rgb 8x8 单 tile');
      });

      test('64x48 亮度平坦帧（单 bin 集中，裁剪再分配极端）', () async {
        const w = 64, h = 48;
        final input = constantFrame(w, h, 3, 400);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 16, 2.0, 1.0, 1023),
            context: 'rgb 平坦帧');
      });

      test('64x48 半黑半白强反差帧（含 v<=0 黑像素保持路径）', () async {
        const w = 64, h = 48;
        final input = contrastFrame(w, h, 3, 1023);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 16, 2.0, 1.0, 1023),
            context: 'rgb 强反差帧');
      });

      test('48x32 strength=0 直通（空操作，输出等于输入）', () async {
        const w = 48, h = 32;
        final input = gradientFrame(w, h, 3, maxValue: 1023);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 0.0);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 16, 2.0, 0.0, 1023),
            context: 'rgb strength=0 直通');
      });

      test('64x48 bs16 maxValue=65535（16 位量级）', () async {
        const w = 64, h = 48;
        final input = lcgFrame(w, h, 3, 14, maxValue: 65535);
        final c = await _run('clahe_rgb', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0, maxValue: 65535);
        expectFramesEqual(
            c.outputs[0], dartClaheRgb(input, w, h, 16, 2.0, 1.0, 65535),
            context: 'rgb 65535');
      });
    });

    group('clahe_mono', () {
      test('64x48 bs16 clip2.0 st1.0 LCG', () async {
        const w = 64, h = 48;
        final input = lcgFrame(w, h, 1, 21, maxValue: 1023);
        final c = await _run('clahe_mono', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheMono(input, w, h, 16, 2.0, 1.0, 1023),
            context: 'mono 64x48 bs16');
      });

      test('48x32 bs32 clip4.0 st0.5 渐变帧（非整块）', () async {
        const w = 48, h = 32;
        final input = gradientFrame(w, h, 1, maxValue: 1023);
        final c = await _run('clahe_mono', w, h, input,
            blockSize: 32, clipLimit: 4.0, strength: 0.5);
        expectFramesEqual(
            c.outputs[0], dartClaheMono(input, w, h, 32, 4.0, 0.5, 1023),
            context: 'mono 48x32 非整块');
      });

      test('8x8 bs16 clip1.0 单 tile 小图', () async {
        const w = 8, h = 8;
        final input = lcgFrame(w, h, 1, 22, maxValue: 1023);
        final c = await _run('clahe_mono', w, h, input,
            blockSize: 16, clipLimit: 1.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheMono(input, w, h, 16, 1.0, 1.0, 1023),
            context: 'mono 8x8 单 tile');
      });

      test('64x48 亮度平坦帧（单 bin 集中）', () async {
        const w = 64, h = 48;
        final input = constantFrame(w, h, 1, 512);
        final c = await _run('clahe_mono', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheMono(input, w, h, 16, 2.0, 1.0, 1023),
            context: 'mono 平坦帧');
      });

      test('64x48 半黑半白强反差帧（黑像素保持路径）', () async {
        const w = 64, h = 48;
        final input = contrastFrame(w, h, 1, 1023);
        final c = await _run('clahe_mono', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 1.0);
        expectFramesEqual(
            c.outputs[0], dartClaheMono(input, w, h, 16, 2.0, 1.0, 1023),
            context: 'mono 强反差帧');
      });

      test('48x32 strength=0 直通（空操作，输出等于输入）', () async {
        const w = 48, h = 32;
        final input = lcgFrame(w, h, 1, 23, maxValue: 1023);
        final c = await _run('clahe_mono', w, h, input,
            blockSize: 16, clipLimit: 2.0, strength: 0.0);
        expectFramesEqual(
            c.outputs[0], dartClaheMono(input, w, h, 16, 2.0, 0.0, 1023),
            context: 'mono strength=0 直通');
      });

      test('64x48 bs16 clip4.0 maxValue=65535（16 位量级）', () async {
        const w = 64, h = 48;
        final input = lcgFrame(w, h, 1, 24, maxValue: 65535);
        final c = await _run('clahe_mono', w, h, input,
            blockSize: 16, clipLimit: 4.0, strength: 1.0, maxValue: 65535);
        expectFramesEqual(
            c.outputs[0], dartClaheMono(input, w, h, 16, 4.0, 1.0, 65535),
            context: 'mono 65535');
      });
    });
  });
}
