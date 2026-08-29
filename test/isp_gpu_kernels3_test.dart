// GPU 链执行器逐算子正确性测试（edge_extract / multiplier）：
// 与 CPU kernel 逐值对比。浮点移植路径（相对对比度 + √rel）允许小容差。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 16, h = 12, maxValue = 255; // 8bit 图片源口径

Uint16List randFrame(int n, int seed) {
  final out = Uint16List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out[i] = s % (maxValue + 1);
  }
  return out;
}

Future<Uint16List> runShader(
  ui.FragmentProgram prog,
  List<double> uniforms,
  List<Uint16List> inputs,
  List<int> inputChannels,
  int outChannels,
) async {
  final samplers = <ui.Image>[];
  for (var i = 0; i < inputs.length; i++) {
    samplers
        .add(await GpuPipeline.uploadPacked(inputs[i], w, h, inputChannels[i]));
  }
  final outTexW = w * outChannels ~/ 2;
  final out = GpuPipeline.runPass(prog, uniforms, samplers, outTexW, h);
  final bytes = await GpuPipeline.readbackBytes(out);
  for (final s in samplers) {
    s.dispose();
  }
  out.dispose();
  return bytes.buffer.asUint16List();
}

void expectClose(Uint16List actual, Uint16List expected, int tol, String tag) {
  expect(actual.length, expected.length, reason: tag);
  var maxDiff = 0;
  var diffCount = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > 0) diffCount++;
    if (d > maxDiff) maxDiff = d;
  }
  // ignore: avoid_print
  print('$tag 最大差 $maxDiff（容差 $tol），不同值 $diffCount/${actual.length}');
  expect(maxDiff, lessThanOrEqualTo(tol), reason: tag);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GpuPipeline gpu;

  setUpAll(() async {
    gpu = (await GpuPipeline.tryCreate())!;
  });

  group('edge_extract GPU vs CPU', () {
    // 三域各自的亮度通道随机帧（threshold 0 避免门限边界的 0/1 翻转）。
    for (final (fmt, code) in [('rgb', 0.0), ('yuv', 1.0), ('hsl', 2.0)]) {
      test('$fmt 域黑底白线', () async {
        final src = randFrame(w * h * 3, 42);
        const gain = 2.0;
        final expected = extractHighFreq(src,
            width: w,
            height: h,
            format: fmt,
            gain: gain,
            threshold: 0,
            maxValue: maxValue);
        final actual = await runShader(
          gpu.progForTest('edge_extract'),
          [
            (w * 3 / 2).toDouble(), h.toDouble(), w.toDouble(),
            code, gain, 0.0, maxValue.toDouble(),
          ],
          [src], [3], 3,
        );
        expectClose(actual, expected, 8, 'edge_extract $fmt');
      });
    }

    test('门限把弱边缘全部置零', () async {
      final src = randFrame(w * h * 3, 7);
      final expected = extractHighFreq(src,
          width: w, height: h, format: 'rgb', threshold: 50, maxValue: maxValue);
      final actual = await runShader(
        gpu.progForTest('edge_extract'),
        [
          (w * 3 / 2).toDouble(), h.toDouble(), w.toDouble(),
          0.0, 1.0, 50.0 / maxValue, maxValue.toDouble(),
        ],
        [src], [3], 3,
      );
      // 随机数据 rel 普遍超门限，这里只验证两路输出一致（门限语义同源）。
      expectClose(actual, expected, 8, 'edge_extract 门限');
    });

    test('平坦图像输出纯黑', () async {
      final src = Uint16List(w * h * 3)..fillRange(0, w * h * 3, 100);
      final actual = await runShader(
        gpu.progForTest('edge_extract'),
        [
          (w * 3 / 2).toDouble(), h.toDouble(), w.toDouble(),
          0.0, 1.0, 0.0, maxValue.toDouble(),
        ],
        [src], [3], 3,
      );
      for (final v in actual) {
        expect(v, 0);
      }
    });
  });

  group('multiplier GPU vs CPU', () {
    test('归一化相乘 + 双偏移', () async {
      final a = randFrame(w * h, 11);
      final b = randFrame(w * h, 22);
      const off1 = 30.0, off2 = -15.0;
      final expected =
          multiplyMono(a, b, offset1: off1, offset2: off2, maxValue: maxValue);
      final actual = await runShader(
        gpu.progForTest('multiply_mono'),
        [
          (w / 2).toDouble(), h.toDouble(),
          off1, off2, maxValue.toDouble(),
        ],
        [a, b], [1, 1], 1,
      );
      expectClose(actual, expected, 2, 'multiplier');
    });

    test('满量程截位', () async {
      final a = Uint16List(w * h)..fillRange(0, w * h, maxValue);
      final b = Uint16List(w * h)..fillRange(0, w * h, maxValue);
      final actual = await runShader(
        gpu.progForTest('multiply_mono'),
        [(w / 2).toDouble(), h.toDouble(), 0.0, 0.0, maxValue.toDouble()],
        [a, b], [1, 1], 1,
      );
      for (final v in actual) {
        expect(v, maxValue);
      }
    });
  });

  group('adder GPU vs CPU', () {
    test('平衡加权混合（多个 balance）', () async {
      final a = randFrame(w * h, 33);
      final b = randFrame(w * h, 44);
      for (final balance in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final expected = blendMono(a, b, balance: balance, maxValue: maxValue);
        final actual = await runShader(
          gpu.progForTest('blend_mono'),
          [(w / 2).toDouble(), h.toDouble(), balance, maxValue.toDouble()],
          [a, b], [1, 1], 1,
        );
        expectClose(actual, expected, 2, 'adder balance=$balance');
      }
    });

    test('balance 为 0/1 时退化为单路直通', () async {
      final a = randFrame(w * h, 55);
      final b = randFrame(w * h, 66);
      for (final (balance, src) in [(1.0, a), (0.0, b)]) {
        final actual = await runShader(
          gpu.progForTest('blend_mono'),
          [(w / 2).toDouble(), h.toDouble(), balance, maxValue.toDouble()],
          [a, b], [1, 1], 1,
        );
        expectClose(actual, src, 1, 'adder balance=$balance 直通');
      }
    });
  });

  group('blender GPU vs CPU（正常模式）', () {
    // uniforms：baseTexW, blendTexW, maskTexW, texH, width,
    // baseChs, blendChs, format, strength, maxValue。
    Future<Uint16List> blendGpu(Uint16List base, Uint16List blend,
        Uint16List mask, int baseChs, int blendChs, int fmtCode,
        double strength) {
      return runShader(
        gpu.progForTest('blender'),
        [
          (w * baseChs / 2).toDouble(),
          (w * blendChs / 2).toDouble(),
          (w / 2).toDouble(),
          h.toDouble(),
          w.toDouble(),
          baseChs.toDouble(),
          blendChs.toDouble(),
          fmtCode.toDouble(),
          strength,
          maxValue.toDouble(),
        ],
        [base, blend, mask],
        [baseChs, blendChs, 1],
        baseChs,
      );
    }

    test('mono 混叠图：按基图格式选目标通道', () async {
      final blend = randFrame(w * h, 71);
      final mask = randFrame(w * h, 72);
      const fmts = [('rgb', 0), ('yuv', 1), ('hsl', 2), ('mono', 3)];
      for (final (fmt, code) in fmts) {
        final baseChs = fmt == 'mono' ? 1 : 3;
        final base = randFrame(w * h * baseChs, 70 + code);
        final expected = blendMaskMono(base, blend, mask,
            format: fmt, strength: 1.2, maxValue: maxValue);
        final actual = await blendGpu(
            base, blend, mask, baseChs, 1, code, 1.2);
        expectClose(actual, expected, 2, 'blender $fmt + mono 混叠图');
      }
    });

    test('三通道混叠图：逐通道对应叠加', () async {
      final base = randFrame(w * h * 3, 80);
      final blend3 = randFrame(w * h * 3, 81);
      final mask = randFrame(w * h, 82);
      final expected = blendMaskMono(base, blend3, mask,
          format: 'yuv', blendChannels: 3, strength: 0.8, maxValue: maxValue);
      final actual =
          await blendGpu(base, blend3, mask, 3, 3, 1, 0.8);
      expectClose(actual, expected, 2, 'blender yuv + 三通道混叠图');
    });
  });

  group('bright_contrast GPU vs CPU', () {
    // uniforms：uTexW, uTexH, uWidth, uChannels, uFormat,
    // uBrightScale, uBase, uGainScale, uMaxValue。
    List<double> bcUniforms(int channels, double fmtCode,
        {double bright = 100, double baseline = 50, double gain = 100}) =>
      [
        (w * channels / 2).toDouble(), h.toDouble(), w.toDouble(),
        channels.toDouble(), fmtCode,
        bright / 100, baseline / 100 * maxValue, gain / 100,
        maxValue.toDouble(),
      ];

    test('mono 域：逐值调节', () async {
      final src = randFrame(w * h, 33);
      final expected = adjustBrightContrast(src,
          format: 'mono',
          maxValue: maxValue,
          brightPct: 150,
          baselinePct: 50,
          gainPct: 120);
      final actual = await runShader(
        gpu.progForTest('bright_contrast'),
        bcUniforms(1, 0, bright: 150, gain: 120),
        [src], [1], 1,
      );
      expectClose(actual, expected, 2, 'bright_contrast mono');
    });

    test('yuv 域：只调 Y，U/V 不变', () async {
      final src = randFrame(w * h * 3, 44);
      final expected = adjustBrightContrast(src,
          format: 'yuv', maxValue: maxValue, brightPct: 200);
      final actual = await runShader(
        gpu.progForTest('bright_contrast'),
        bcUniforms(3, 1, bright: 200),
        [src], [3], 3,
      );
      expectClose(actual, expected, 2, 'bright_contrast yuv');
    });

    test('hsl 域：只调 L', () async {
      final src = randFrame(w * h * 3, 55);
      final expected = adjustBrightContrast(src,
          format: 'hsl', maxValue: maxValue, gainPct: 150);
      final actual = await runShader(
        gpu.progForTest('bright_contrast'),
        bcUniforms(3, 2, gain: 150),
        [src], [3], 3,
      );
      expectClose(actual, expected, 2, 'bright_contrast hsl');
    });

    test('rgb 域：按亮度比例缩放三通道', () async {
      final src = randFrame(w * h * 3, 66);
      final expected = adjustBrightContrast(src,
          format: 'rgb',
          maxValue: maxValue,
          brightPct: 200,
          baselinePct: 0);
      final actual = await runShader(
        gpu.progForTest('bright_contrast'),
        bcUniforms(3, 0, bright: 200, baseline: 0),
        [src], [3], 3,
      );
      expectClose(actual, expected, 4, 'bright_contrast rgb');
    });
  });
}

