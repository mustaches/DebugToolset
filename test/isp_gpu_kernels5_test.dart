// GPU 链执行器逐算子正确性测试（荧光链：fluoro_leak / fluoro_background /
// fluoro_normalize / fluoro_temporal / pseudo_color / fluoro_fusion +
// 双源链 e2e）：与 CPU kernel 逐值对比。浮点移植路径允许小容差。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 16, h = 12, maxValue = 255; // 8bit 口径

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
  List<(int, int)> inputDims, // 每路输入的 (宽, 高)
  int outChannels,
) async {
  final samplers = <ui.Image>[];
  for (var i = 0; i < inputs.length; i++) {
    final (iw, ih) = inputDims[i];
    final channels = inputs[i].length ~/ (iw * ih);
    samplers.add(await GpuPipeline.uploadPacked(inputs[i], iw, ih, channels));
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
  var bad = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxDiff) maxDiff = d;
    if (d > tol && bad < 5) {
      bad++;
      // ignore: avoid_print
      print('$tag 超差 @$i: 实际 ${actual[i]} 期望 ${expected[i]}');
    }
  }
  // ignore: avoid_print
  print('$tag 最大差 $maxDiff（容差 $tol）');
  expect(maxDiff, lessThanOrEqualTo(tol), reason: tag);
}

void expectRgbaClose(Uint8List actual, Uint8List expected, int tol, String tag) {
  expect(actual.length, expected.length, reason: tag);
  var maxDiff = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxDiff) maxDiff = d;
  }
  // ignore: avoid_print
  print('$tag 最大差 $maxDiff（容差 $tol）');
  expect(maxDiff, lessThanOrEqualTo(tol), reason: tag);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GpuPipeline gpu;

  setUpAll(() async {
    gpu = (await GpuPipeline.tryCreate())!;
  });

  test('fluoro_leak（限幅扣除）', () async {
    final src = randFrame(w * h, 1);
    final cpu = Uint16List.fromList(src);
    applyFluoroLeak(cpu, level: 100, maxSub: 50); // sub 收敛到 50
    final gpuOut = await runShader(gpu.progForTest('fluoro_leak'),
        [w / 2, h.toDouble(), 50], [src], [(w, h)], 1);
    expectClose(gpuOut, cpu, 0, 'fluoro_leak');
  });

  test('fluoro_gain（归一化增益施加）', () async {
    final src = randFrame(w * h, 2);
    var sum = 0;
    for (final v in src) {
      sum += v;
    }
    final mean = sum / src.length;
    final cpu = Uint16List.fromList(src);
    applyFluoroNormalize(cpu,
        reference: mean * 1.7, epsilon: 1, maxValue: maxValue);
    final gpuOut = await runShader(gpu.progForTest('fluoro_gain'),
        [w / 2, h.toDouble(), 1.7, maxValue.toDouble()], [src], [(w, h)], 1);
    expectClose(gpuOut, cpu, 1, 'fluoro_gain');
  });

  test('fluoro_bg_sub（块均值扣除）', () async {
    // 低频背景 + 高频细节：块均值非平凡。
    final src = randFrame(w * h, 3);
    const bs = 4;
    const strength = 0.5;
    final cpu = Uint16List.fromList(src);
    applyFluoroBackground(cpu,
        width: w, height: h, blockSize: bs, strength: strength);
    // 与 runner 相同的 CPU 桥接：块均值量化 16 位打包上传。
    const bx = (w + bs - 1) ~/ bs, by = (h + bs - 1) ~/ bs;
    final means = Uint16List(bx * by);
    for (var byi = 0; byi < by; byi++) {
      for (var bxi = 0; bxi < bx; bxi++) {
        var sum = 0, count = 0;
        for (var yy = byi * bs; yy < byi * bs + bs && yy < h; yy++) {
          for (var xx = bxi * bs; xx < bxi * bs + bs && xx < w; xx++) {
            sum += src[yy * w + xx];
            count++;
          }
        }
        means[byi * bx + bxi] = (sum / count).round();
      }
    }
    final gpuOut = await runShader(
        gpu.progForTest('fluoro_bg_sub'),
        [
          w / 2, h.toDouble(), w.toDouble(), bs.toDouble(), bx.toDouble(),
          strength, bx / 2, by.toDouble(),
        ],
        [src, means], [(w, h), (bx, by)], 1);
    expectClose(gpuOut, cpu, 2, 'fluoro_bg_sub');
  });

  test('fluoro_temporal（IIR + 运动自适应）', () async {
    final f = randFrame(w * h, 4);
    final hist = randFrame(w * h, 5);
    final (cpu, _) = applyTemporalIir(f,
        history: hist, alpha: 0.5, motionAdapt: true, maxValue: maxValue);
    final gpuOut = await runShader(
        gpu.progForTest('fluoro_temporal'),
        [w / 2, h.toDouble(), 0.5, maxValue / 16],
        [f, hist], [(w, h), (w, h)], 1);
    expectClose(gpuOut, cpu, 1, 'fluoro_temporal 运动自适应');

    final (cpuOff, _) = applyTemporalIir(f,
        history: hist, alpha: 0.3, motionAdapt: false, maxValue: maxValue);
    final gpuOff = await runShader(gpu.progForTest('fluoro_temporal'),
        [w / 2, h.toDouble(), 0.3, 1e9], [f, hist], [(w, h), (w, h)], 1);
    expectClose(gpuOff, cpuOff, 1, 'fluoro_temporal 固定 α');
  });

  test('pseudo_color（三种色表）', () async {
    final src = randFrame(w * h, 6);
    for (final (cmap, code) in [('green', 0.0), ('magenta', 1.0), ('hot', 2.0)]) {
      final cpu = monoPseudoColor(src,
          width: w, height: h, colormap: cmap, gain: 1.2, maxValue: maxValue);
      final gpuOut = await runShader(
          gpu.progForTest('pseudo_color'),
          [
            w / 2, h.toDouble(), w.toDouble(), code, 1.2,
            maxValue.toDouble(), w * 3 / 2,
          ],
          [src], [(w, h)], 3);
      expectClose(gpuOut, cpu, 1, 'pseudo_color $cmap');
    }
  });

  test('fluoro_fusion（alpha / contour × 偏移）', () async {
    final rgb = randFrame(w * h * 3, 7);
    final fl = randFrame(w * h, 8);
    List<double> uniforms(double mode, String cmap,
            {double offX = 0, double offY = 0}) =>
        [
          w * 3 / 2, h.toDouble(), w.toDouble(), h.toDouble(), w / 2,
          mode, 32, 0.8, cmap == 'hot' ? 2.0 : 0.0, offX, offY,
          maxValue.toDouble(),
        ];
    final cpuAlpha = fuseFluorescence(rgb, fl,
        width: w, height: h,
        mode: 'alpha', threshold: 32, alphaMax: 0.8,
        colormap: 'green', offsetX: 0.5, offsetY: -0.3, maxValue: maxValue);
    final gpuAlpha = await runShader(gpu.progForTest('fluoro_fusion'),
        uniforms(0, 'green', offX: 0.5, offY: -0.3), [rgb, fl], [(w, h), (w, h)], 3);
    expectClose(gpuAlpha, cpuAlpha, 2, 'fluoro_fusion alpha');

    final cpuContour = fuseFluorescence(rgb, fl,
        width: w, height: h,
        mode: 'contour', threshold: 32, alphaMax: 0.8,
        colormap: 'hot', maxValue: maxValue);
    final gpuContour = await runShader(gpu.progForTest('fluoro_fusion'),
        uniforms(1, 'hot'), [rgb, fl], [(w, h), (w, h)], 3);
    expectClose(gpuContour, cpuContour, 2, 'fluoro_fusion contour');
  });

  group('双源荧光链 e2e（复刻 ICG荧光融合ISP流程 形态）', () {
    /// 8bit unpacked RAW：每像素一个 16 位小端字。
    List<int> raw8Le(Iterable<int> px) => [
          for (final v in px) ...[v & 0xFF, (v >> 8) & 0xFF],
        ];

    Map<String, Object?> op(String id, String type,
            [Map<String, Object?> inputs = const {},
            Map<String, Object?> params = const {}]) =>
        {'nodeId': id, 'typeId': type, 'params': params, 'inputs': inputs};

    Map<String, Object?> portOf(String nodeId, String port) =>
        {'fromNodeId': nodeId, 'fromPort': port};

    test('GPU 双源链与 CPU 出图一致', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_fl_gpu_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i * 3 % 251)));
      try {
        final rawParams = {
          'filePath': tmp.path,
          'width': w,
          'height': h,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
          'bayerPattern': 'RGGB',
          'littleEndian': true,
          'frameIndex': 0,
        };
        final chain = <Map<String, Object?>>[
          op('srcWl', 'cis_bayer_rggb', {}, rawParams),
          op('dm', 'demosaic', {'in': portOf('srcWl', 'out')},
              {'algorithm': 'bilinear'}),
          op('srcFl', 'cis_mono', {}, rawParams),
          op('leak', 'fluoro_leak', {'in_mono': portOf('srcFl', 'out')},
              {'level': 16.0, 'maxSub': 64.0}),
          op('norm', 'fluoro_normalize', {'in_mono': portOf('leak', 'out_mono')},
              {'reference': 100.0, 'epsilon': 1.0}),
          op('temp', 'fluoro_temporal', {'in_mono': portOf('norm', 'out_mono')},
              {'alpha': 0.5, 'motionAdapt': true}),
          op('fus', 'fluoro_fusion', {
            'in': portOf('dm', 'out'),
            'in_fluoro': portOf('temp', 'out_mono'),
          }, {
            'mode': 'alpha',
            'threshold': 32.0,
            'alphaMax': 0.8,
            'colormap': 'green',
            'offsetX': 0.0,
            'offsetY': 0.0,
          }),
          op('pv', 'preview', {'in': portOf('fus', 'out')}),
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0);
        final gpuRgba = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        expect(result.captures['srcFl']?['format'], 'mono');
        expect(result.captures['fus']?['format'], 'rgb');
        final cpuRgba = await runChainFrame(chain, 0);
        expectRgbaClose(gpuRgba, cpuRgba, 8, '双源荧光链 e2e');
      } finally {
        await tmp.delete();
      }
    });

    test('fluoro_temporal 跨帧历史（双帧连续运行）', () async {
      // 两帧 RAW：帧1 在帧0 基础上整体 +20（含局部大跳变触发运动判定）。
      final tmp = File(
          '${Directory.systemTemp.path}/isp_temporal_${DateTime.now().microsecondsSinceEpoch}.raw');
      final px = List<int>.generate(w * h * 2, (i) {
        final f = i ~/ (w * h);
        final p = i % (w * h);
        var v = (p * 3) % 200 + f * 20;
        if (f == 1 && p % 37 == 0) v += 100; // 运动点（帧差 > maxValue/16）
        return v > 255 ? 255 : v;
      });
      await tmp.writeAsBytes(raw8Le(px));
      try {
        final chain = <Map<String, Object?>>[
          op('srcT', 'cis_mono', {}, {
            'filePath': tmp.path,
            'width': w,
            'height': h,
            'bitDepth': '8',
            'packing': 'unpacked_lsb',
            'littleEndian': true,
          }),
          op('tempT', 'fluoro_temporal', {'in_mono': portOf('srcT', 'out')},
              {'alpha': 0.5, 'motionAdapt': true}),
          op('pv', 'preview', {'in_mono': portOf('tempT', 'out_mono')}),
        ];
        // 帧0：无历史直通；帧1：GPU 复用上帧历史纹理走 IIR。
        final r0 = await gpu.run(chain, 0);
        final gpu0 = await GpuPipeline.readbackBytes(r0.image);
        r0.image.dispose();
        final r1 = await gpu.run(chain, 1);
        final gpu1 = await GpuPipeline.readbackBytes(r1.image);
        r1.image.dispose();
        final cpu0 = await runChainFrame(chain, 0);
        final cpu1 = await runChainFrame(chain, 1);
        expectRgbaClose(gpu0, cpu0, 2, 'temporal 帧0（无历史直通）');
        expectRgbaClose(gpu1, cpu1, 2, 'temporal 帧1（IIR 历史）');
      } finally {
        await tmp.delete();
      }
    });

    test('cis_mono 首源荧光 mono 链 → 伪彩预览（n24 链形态）', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_mono_fl_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i * 3 % 251)));
      try {
        final chain = <Map<String, Object?>>[
          op('srcFl', 'cis_mono', {}, {
            'filePath': tmp.path,
            'width': w,
            'height': h,
            'bitDepth': '8',
            'packing': 'unpacked_lsb',
            'littleEndian': true,
            'frameIndex': 0,
          }),
          op('bl', 'black_level', {'in_mono': portOf('srcFl', 'out')},
              {'r': 8.0, 'gr': 8.0, 'gb': 8.0, 'b': 8.0}),
          op('leak', 'fluoro_leak', {'in_mono': portOf('bl', 'out_mono')},
              {'level': 16.0, 'maxSub': 64.0}),
          op('bg', 'fluoro_background', {'in_mono': portOf('leak', 'out_mono')},
              {'blockSize': 4, 'strength': 0.3}),
          op('norm', 'fluoro_normalize', {'in_mono': portOf('bg', 'out_mono')},
              {'reference': 100.0, 'epsilon': 1.0}),
          op('pc', 'pseudo_color', {'in_mono': portOf('norm', 'out_mono')},
              {'colormap': 'green', 'gain': 1.0}),
          op('pv', 'preview', {'in': portOf('pc', 'out')}),
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0);
        final gpuRgba = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        expect(result.captures['pc']?['format'], 'rgb');
        final cpuRgba = await runChainFrame(chain, 0);
        expectRgbaClose(gpuRgba, cpuRgba, 8, 'cis_mono 首源伪彩链 e2e');
      } finally {
        await tmp.delete();
      }
    });

    test('双源交错拓扑序：mono 支路不错拿白光分支帧', () async {
      // 复刻真实 ICG 流程的 Kahn 交错序：白光链与荧光链节点交替出现。
      // bl（mono 旧算子）只显式登记 out；dm（rgb）插在 bl 与 leak 之间——
      // 无通用 out_mono 别名登记时，leak 取帧回退「继承上一节点帧」，
      // 错拿 dm 的 RGB 帧而抛异常回退 CPU。
      final tmp = File(
          '${Directory.systemTemp.path}/isp_interleave_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i * 3 % 251)));
      try {
        final rawParams = {
          'filePath': tmp.path,
          'width': w,
          'height': h,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
          'bayerPattern': 'RGGB',
          'littleEndian': true,
          'frameIndex': 0,
        };
        final chain = <Map<String, Object?>>[
          op('srcWl', 'cis_bayer_rggb', {}, rawParams),
          op('srcFl', 'cis_mono', {}, rawParams),
          op('bl', 'black_level', {'in_mono': portOf('srcFl', 'out')},
              {'r': 8.0, 'gr': 8.0, 'gb': 8.0, 'b': 8.0}),
          // 白光分支节点交错插入 mono 支路中间。
          op('dm', 'demosaic', {'in': portOf('srcWl', 'out')},
              {'algorithm': 'bilinear'}),
          op('leak', 'fluoro_leak', {'in_mono': portOf('bl', 'out_mono')},
              {'level': 16.0, 'maxSub': 64.0}),
          op('norm', 'fluoro_normalize', {'in_mono': portOf('leak', 'out_mono')},
              {'reference': 100.0, 'epsilon': 1.0}),
          op('fus', 'fluoro_fusion', {
            'in': portOf('dm', 'out'),
            'in_fluoro': portOf('norm', 'out_mono'),
          }, {
            'mode': 'alpha',
            'threshold': 32.0,
            'alphaMax': 0.8,
            'colormap': 'green',
            'offsetX': 0.0,
            'offsetY': 0.0,
          }),
          op('pv', 'preview', {'in': portOf('fus', 'out')}),
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0);
        final gpuRgba = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        expect(result.captures['leak']?['format'], 'mono');
        final cpuRgba = await runChainFrame(chain, 0);
        expectRgbaClose(gpuRgba, cpuRgba, 8, '交错拓扑序双源链 e2e');
      } finally {
        await tmp.delete();
      }
    });
  });
}
