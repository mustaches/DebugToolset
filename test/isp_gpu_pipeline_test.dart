// GPU 链执行器逐算子正确性测试：每个 shader 的输出与对应 CPU kernel
// 在小型伪随机帧上逐值对比。整数路径（去马赛克/抽取/合路/黑电平/
// GrGb）要求精确一致；浮点移植路径（CSC/CLAHE/色调映射）允许 ±2 LSB
// （CPU 为 double/定点，GPU 为 float32）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 16, h = 12, maxValue = 16383; // 14bit

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
    samplers.add(
        await GpuPipeline.uploadPacked(inputs[i], w, h, inputChannels[i]));
  }
  final outTexW = w * outChannels ~/ 2;
  final out =
      GpuPipeline.runPass(prog, uniforms, samplers, outTexW, h);
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
  var bad = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxDiff) maxDiff = d;
    if (d > tol && bad < 5) {
      bad++;
      // ignore: avoid_print
      print('$tag 首个超差 @$i: 实际 ${actual[i]} 期望 ${expected[i]}');
    }
  }
  // ignore: avoid_print
  print('$tag 最大差 $maxDiff（容差 $tol）');
  expect(maxDiff, lessThanOrEqualTo(tol), reason: tag);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GpuPipeline gpu;

  setUpAll(() async {
    final g = await GpuPipeline.tryCreate();
    expect(g, isNotNull, reason: 'shader 加载失败');
    gpu = g!;
  });

  ui.FragmentProgram prog(String name) => gpu.progForTest(name);

  final pattern = BayerPattern.rggb;
  final pc = [for (var ph = 0; ph < 4; ph++) pattern.colorAt(ph & 1, ph >> 1)];
  final pcD = pc.map((e) => e.toDouble()).toList();

  test('black_level（mosaic + mono）', () async {
    final src = randFrame(w * h, 1);
    // mosaic：与 applyBlackLevel 的相位偏移解析一致（RGGB: 0=R,1=Gr,2=Gb,3=B）
    final cpu = Uint16List.fromList(src);
    applyBlackLevel(cpu,
        width: w, height: h, pattern: pattern, r: 64, gr: 62, gb: 63, b: 61);
    final gpuOut = await runShader(
        prog('black_level'),
        [w / 2, h.toDouble(), w.toDouble(), 0, 64, 62, 63, 61],
        [src], [1], 1);
    expectClose(gpuOut, cpu, 0, 'black_level mosaic');
    // mono：统一偏移
    final cpuMono = Uint16List.fromList(src);
    for (var i = 0; i < cpuMono.length; i++) {
      final v = cpuMono[i] - 100.0;
      cpuMono[i] = v <= 0 ? 0 : v.round();
    }
    final gpuMono = await runShader(
        prog('black_level'),
        [w / 2, h.toDouble(), w.toDouble(), 1, 100, 100, 100, 100],
        [src], [1], 1);
    expectClose(gpuMono, cpuMono, 0, 'black_level mono');
  });

  test('grgb_balance', () async {
    final src = randFrame(w * h, 2);
    final cpu = Uint16List.fromList(src);
    applyGrGbBalance(cpu, width: w, height: h, pattern: pattern, strength: 1.0);
    // 与 CPU 核相同的全帧统计求增益（隔离 shader 正确性）。
    var sumGr = 0, cntGr = 0, sumGb = 0, cntGb = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (pattern.colorAt(x, y) != 1) continue;
        if (pattern.colorAt(x ^ 1, y) == 0) {
          sumGr += src[y * w + x];
          cntGr++;
        } else {
          sumGb += src[y * w + x];
          cntGb++;
        }
      }
    }
    final meanGr = sumGr / cntGr, meanGb = sumGb / cntGb;
    final target = (meanGr + meanGb) / 2;
    final gainGr = target / meanGr, gainGb = target / meanGb;
    final gpuOut = await runShader(
        prog('grgb_balance'),
        [w / 2, h.toDouble(), w.toDouble(), gainGr, gainGb, ...pcD],
        [src], [1], 1);
    expectClose(gpuOut, cpu, 1, 'grgb_balance');
  });

  test('demosaic bilinear', () async {
    final src = randFrame(w * h, 3);
    final cpu = demosaicBilinear(src, width: w, height: h, pattern: pattern);
    final gpuOut = await runShader(
        prog('demosaic'),
        [w / 2, h.toDouble(), w.toDouble(), h.toDouble(), w * 3 / 2, ...pcD],
        [src], [1], 3);
    expectClose(gpuOut, cpu, 0, 'demosaic');
  });

  test('apply_gains（白平衡施加 / RGB 调节器通道增益）', () async {
    final src = randFrame(w * h * 3, 4);
    final cpu = Uint16List.fromList(src);
    applyWhiteBalance(cpu, rGain: 1.37, bGain: 0.82, maxValue: maxValue);
    final gpuOut = await runShader(
        prog('apply_gains'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         1.37, 1.0, 0.82],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 1, 'apply_gains（白平衡 R/B）');
    // RGB 调节器：三通道独立增益。
    final cpu3 = adjustRgb(src,
        maxValue: maxValue, rGain: 1.2, gGain: 0.7, bGain: 1.5);
    final gpu3 = await runShader(
        prog('apply_gains'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         1.2, 0.7, 1.5],
        [src], [3], 3);
    expectClose(gpu3, cpu3, 1, 'apply_gains（RGB 调节器三通道）');
  });

  test('csc_rgb2hsl', () async {
    final src = randFrame(w * h * 3, 5);
    final cpu = rgbToHsl(src, maxValue: maxValue);
    final gpuOut = await runShader(
        prog('rgb2hsl'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble()],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 2, 'rgb2hsl');
  });

  test('hsl_adjust', () async {
    final src = randFrame(w * h * 3, 6);
    final cpu = adjustHsl(src,
        maxValue: maxValue, hShiftDeg: 37.0, sGain: 1.2, lGain: 5.0);
    final shift = (37.0 / 360 * maxValue).roundToDouble();
    final gpuOut = await runShader(
        prog('hsl_adjust'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         shift, 1.2, 5.0],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 1, 'hsl_adjust');
  });

  test('csc_hsl2yuv', () async {
    final src = randFrame(w * h * 3, 7);
    final cpu = hslToYuv(src, maxValue: maxValue);
    final gpuOut = await runShader(
        prog('hsl2yuv'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         (maxValue >> 1).toDouble()],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 2, 'hsl2yuv');
  });

  test('extract_channel（Y 抽取）', () async {
    final src = randFrame(w * h * 3, 8);
    final cpu = Uint16List(w * h);
    for (var i = 0; i < w * h; i++) {
      cpu[i] = src[i * 3];
    }
    final gpuOut = await runShader(
        prog('extract_channel'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), 0, w / 2],
        [src], [3], 1);
    expectClose(gpuOut, cpu, 0, 'extract_channel');
  });

  test('clahe_apply（mono）', () async {
    final src = randFrame(w * h, 9);
    final cpu = Uint16List.fromList(src);
    applyClaheMono(cpu,
        width: w, height: h,
        blockSize: 4, clipLimit: 2.0, strength: 1.0, maxValue: maxValue);
    // 与 runner 相同的 LUT 量化路径。
    final luts = claheTileLuts(src, w, h, 4, 2.0, maxValue);
    final lut16 = Uint16List(4 * 3 * 256); // tilesX=4, tilesY=3
    for (var i = 0; i < lut16.length; i++) {
      lut16[i] = luts[i].round().clamp(0, 65535);
    }
    // LUT 纹理：1024 纹素宽平铺（与 runner 一致），3072 值 = 1536 纹素
    // → 2 行（尾部补零）。
    const lutTexW = 1024;
    final lutTexH = (lut16.length ~/ 2 + lutTexW - 1) ~/ lutTexW;
    final lutPadded = Uint16List(lutTexH * lutTexW * 2);
    lutPadded.setRange(0, lut16.length, lut16);
    final monoTex = await GpuPipeline.uploadPacked(src, w, h, 1);
    final lutTex =
        await GpuPipeline.uploadPacked(lutPadded, lutTexW * 2, lutTexH, 1);
    final out = GpuPipeline.runPass(prog('clahe_apply'), [
      w / 2, h.toDouble(), w.toDouble(), h.toDouble(),
      4, 4, 3, 1.0, maxValue.toDouble(),
      lutTexW.toDouble(), lutTexH.toDouble(),
    ], [monoTex, lutTex], w ~/ 2, h);
    final bytes = await GpuPipeline.readbackBytes(out);
    monoTex.dispose();
    lutTex.dispose();
    out.dispose();
    expectClose(bytes.buffer.asUint16List(), cpu, 2, 'clahe_apply');
  });

  test('combine_3ch（YUV 合路：三路 mono 交织）', () async {
    final y = randFrame(w * h, 11);
    final u = randFrame(w * h, 12);
    final v = randFrame(w * h, 13);
    // CPU 语义：Y/U/V 各取 in_y/in_u/in_v 的 mono 平面。
    final cpu = Uint16List(w * h * 3);
    for (var i = 0; i < w * h; i++) {
      cpu[i * 3] = y[i];
      cpu[i * 3 + 1] = u[i];
      cpu[i * 3 + 2] = v[i];
    }
    final gpuOut = await runShader(
        prog('combine_3ch'),
        [w / 2, h.toDouble(), 1, 1, 1, 0, 0, 0, w * 3 / 2],
        [y, u, v], [1, 1, 1], 3);
    expectClose(gpuOut, cpu, 0, 'combine_3ch yuv 三路');
  });

  test('csc_yuv2rgb', () async {
    final src = randFrame(w * h * 3, 12);
    final cpu = yuvToRgb(src, maxValue: maxValue);
    final gpuOut = await runShader(
        prog('yuv2rgb'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         (maxValue >> 1).toDouble()],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 2, 'yuv2rgb');
  });

  test('tonemap（rgb / mono / yuv / hsl）', () async {
    Future<Uint8List> tonemap(List<double> uniforms, Uint16List src,
        int channels) async {
      final tex = await GpuPipeline.uploadPacked(src, w, h, channels);
      final out = GpuPipeline.runPass(prog('tonemap'), uniforms, [tex], w, h);
      final bytes = await GpuPipeline.readbackBytes(out);
      tex.dispose();
      out.dispose();
      return bytes;
    }

    void expectRgbaClose(Uint8List a, Uint8List b, String tag) {
      var maxDiff = 0;
      for (var i = 0; i < a.length; i++) {
        final d = (a[i] - b[i]).abs();
        if (d > maxDiff) maxDiff = d;
      }
      // ignore: avoid_print
      print('$tag 最大差 $maxDiff（容差 2）');
      expect(maxDiff, lessThanOrEqualTo(2), reason: tag);
    }

    const inv = 1 / 2.2;
    final half = (maxValue >> 1).toDouble();
    // rgb
    final rgb = randFrame(w * h * 3, 13);
    expectRgbaClose(
        await tonemap(
            [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
             0, inv, 0, 1, half], rgb, 3),
        tonemapToRgba(rgb, maxValue: maxValue, gamma: 2.2),
        'tonemap rgb');
    // mono
    final mono = randFrame(w * h, 14);
    expectRgbaClose(
        await tonemap(
            [w / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
             1, inv, 0, 1, half], mono, 1),
        monoToRgba(mono, maxValue: maxValue, gamma: 2.2),
        'tonemap mono');
    // yuv
    final yuv = randFrame(w * h * 3, 15);
    expectRgbaClose(
        await tonemap(
            [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
             2, inv, 0, 1, half], yuv, 3),
        yuvToRgba(yuv, maxValue: maxValue, gamma: 2.2),
        'tonemap yuv');
    // hsl
    final hsl = randFrame(w * h * 3, 16);
    expectRgbaClose(
        await tonemap(
            [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
             3, inv, 0, 1, half], hsl, 3),
        tonemapToRgba(hslToRgb(hsl, maxValue: maxValue),
            maxValue: maxValue, gamma: 2.2),
        'tonemap hsl');
  });

  test('isSupportedChain 判定', () {
    Map<String, Object?> src() => {
          'typeId': 'cis_bayer_rggb',
          'nodeId': 'n1',
          'params': {'width': 4096, 'height': 3072},
          'inputs': <String, Object?>{},
        };
    Map<String, Object?> op(String id, String type,
            [Map<String, Object?> inputs = const {},
            Map<String, Object?> params = const {}]) =>
        {'nodeId': id, 'typeId': type, 'params': params, 'inputs': inputs};
    final ok = [
      src(),
      op('n2', 'demosaic', {}, {'algorithm': 'bilinear'}),
      op('n3', 'preview'),
    ];
    expect(GpuPipeline.isSupportedChain(ok), isTrue);
    // 色温调节器（通道增益）支持
    final colorTemp = [
      src(),
      op('n2', 'demosaic'),
      op('n4', 'color_temp_adjuster', {}, {'temperature': 5000.0}),
      op('n3', 'preview'),
    ];
    expect(GpuPipeline.isSupportedChain(colorTemp), isTrue);
    // 高级去马赛克算法不支持
    final badAlgo = [
      src(),
      op('n2', 'demosaic', {}, {'algorithm': 'amaze'}),
      op('n3', 'preview'),
    ];
    expect(GpuPipeline.isSupportedChain(badAlgo), isFalse);
    // 奇数宽不支持
    final oddW = [
      {
        'typeId': 'cis_bayer_rggb', 'nodeId': 'n1',
        'params': {'width': 4095, 'height': 3072},
        'inputs': <String, Object?>{},
      },
      op('n3', 'preview'),
    ];
    expect(GpuPipeline.isSupportedChain(oddW), isFalse);
    // gamma 后只能跟汇点
    final afterGamma = [
      src(),
      op('n2', 'demosaic'),
      op('n6', 'gamma'),
      op('n7', 'csc_rgb2hsl'),
      op('n3', 'preview'),
    ];
    expect(GpuPipeline.isSupportedChain(afterGamma), isFalse);
    // AHE 无 in_mono 不支持
    final aheRgb = [
      src(),
      op('n2', 'demosaic'),
      op('n9', 'ahe', {}, {'blockSize': 32}),
      op('n3', 'preview'),
    ];
    expect(GpuPipeline.isSupportedChain(aheRgb), isFalse);
  });
}
