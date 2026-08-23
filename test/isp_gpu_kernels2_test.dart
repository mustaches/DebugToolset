// GPU 链执行器逐算子正确性测试（白光流程新增算子）：dpc/fpn/lsc/
// bayer_dnr/highlight/ccm/rgb_dnr/sharpen 与 CPU kernel 逐值对比。
// 整数路径要求精确一致；浮点移植路径允许小容差。
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
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxDiff) maxDiff = d;
    if (d > tol) {
      // ignore: avoid_print
      print('$tag 首个超差 @$i: 实际 ${actual[i]} 期望 ${expected[i]}');
      break;
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
    gpu = (await GpuPipeline.tryCreate())!;
  });

  ui.FragmentProgram prog(String name) => gpu.progForTest(name);

  const pattern = BayerPattern.rggb;

  // csc_rgb2yuv 的浮点系数（与 runner._rgb2yuvCscUniforms 同源）。
  List<double> cscUniforms(String standard, String range) {
    const q = 1.0 / 65536;
    var cyR = 19595 * q, cyG = 38470 * q, cyB = 7471 * q;
    var cuR = -11058 * q, cuG = -21710 * q, cvG = -27439 * q, cvB = -5329 * q;
    if (standard == 'bt709') {
      cyR = 13933 * q;
      cyG = 46871 * q;
      cyB = 4732 * q;
      cuR = -7509 * q;
      cuG = -25260 * q;
      cvG = -29759 * q;
      cvB = -3009 * q;
    }
    final offY = ((maxValue * 16 + 127) ~/ 255).toDouble();
    return [
      (maxValue >> 1).toDouble(),
      cyR, cyG, cyB, cuR, cuG, cvG, cvB,
      offY, range == 'limited' ? 1.0 : 0.0,
    ];
  }

  test('dpc（median，稀疏坏点）', () async {
    // 平滑基底 + 稀疏孤立坏点（同相位 3x3 内无第二个坏点，
    // CPU 原地顺序与 GPU 快照语义一致）。
    final src = Uint16List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        src[y * w + x] = 2000 + (x + y) % 7;
      }
    }
    for (var y = 2; y < h; y += 5) {
      for (var x = 5; x < w; x += 11) {
        src[y * w + x] = 12000; // 坏点
      }
    }
    final cpu = Uint16List.fromList(src);
    applyDpc(cpu,
        width: w, height: h,
        pattern: pattern, threshold: 5.0, mode: 'median', maxValue: maxValue);
    final gpuOut = await runShader(
        prog('dpc'),
        [w / 2, h.toDouble(), w.toDouble(), h.toDouble(), 2,
         5.0 / 100 * maxValue],
        [src], [1], 1);
    expectClose(gpuOut, cpu, 0, 'dpc');
  });

  test('fpn（桶计数中位数与排序参考实现等价）', () {
    // applyFpn 的中位数已改桶计数；这里用「排序取中位」的直白参考实现
    //（逐字对齐 CPU 语义：截断盒式均值 + 膨胀梯度掩膜 + 行/列中位数
    // 限幅扣除）在合成帧上验证最终结果逐点一致。
    Uint16List fpnSortRef(Uint16List src, int w, int h,
        {double maxCorr = 64, int radius = 8}) {
      final buf = Uint16List.fromList(src);
      double clampCorr(num c) =>
          c < -maxCorr ? -maxCorr : (c > maxCorr ? maxCorr : c).toDouble();
      final thr = 2 * maxCorr;
      for (var axis = 0; axis < 2; axis++) {
        final vertical = axis == 0; // 行统计：垂直低通 + 垂直梯度
        final low = List<double>.filled(w * h, 0);
        final mask = Uint8List(w * h);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            var sum = 0, cnt = 0;
            var masked = false;
            for (var d = -radius; d <= radius; d++) {
              final nx = vertical ? x : x + d, ny = vertical ? y + d : y;
              if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
              sum += buf[ny * w + nx];
              cnt++;
              final ax = vertical ? x : nx - 1, ay = vertical ? ny - 1 : y;
              final bx = vertical ? x : nx + 1, by = vertical ? ny + 1 : y;
              if (ax < 0 || ax >= w || ay < 0 || ay >= h) continue;
              if (bx < 0 || bx >= w || by < 0 || by >= h) continue;
              if ((buf[ay * w + ax] - buf[by * w + bx]).abs() > thr) {
                masked = true;
              }
            }
            low[y * w + x] = sum / cnt;
            mask[y * w + x] = masked ? 1 : 0;
          }
        }
        final lines = vertical ? h : w, lineLen = vertical ? w : h;
        final res = <int>[];
        for (var ln = 0; ln < lines; ln++) {
          res.clear();
          for (var t = 0; t < lineLen; t++) {
            final i = vertical ? ln * w + t : t * w + ln;
            if (mask[i] != 0) continue;
            res.add(buf[i] - low[i].round());
          }
          res.sort();
          final corr = res.isEmpty ? 0.0 : clampCorr(res[res.length ~/ 2]);
          if (corr == 0) continue;
          for (var t = 0; t < lineLen; t++) {
            final i = vertical ? ln * w + t : t * w + ln;
            final v = buf[i] - corr;
            buf[i] = v <= 0 ? 0 : v.round();
          }
        }
      }
      return buf;
    }

    // 带行/列偏移 + 一处内容边缘（触发掩膜）的合成帧。
    final src = Uint16List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        src[y * w + x] = (3000 +
                (x * 3 + y * 5) % 50 +
                (y.isOdd ? 30 : 0) +
                (x % 5 == 0 ? 20 : 0) +
                (x >= w ~/ 2 ? 500 : 0))
            .clamp(0, maxValue);
      }
    }
    final cpu = Uint16List.fromList(src);
    applyFpn(cpu,
        width: w, height: h, pattern: pattern, row: true, col: true,
        maxCorr: 64);
    final ref = fpnSortRef(src, w, h);
    expectClose(cpu, ref, 0, 'fpn 桶计数中位数等价性');
  });

  test('lsc', () async {
    final src = randFrame(w * h, 21);
    final cpu = Uint16List.fromList(src);
    applyLsc(cpu,
        width: w, height: h,
        pattern: pattern, strength: 0.5, centerX: 0.5, centerY: 0.5,
        maxValue: maxValue);
    const cx = 0.5 * (w - 1), cy = 0.5 * (h - 1);
    final ex = cx > w - 1 - cx ? cx : w - 1 - cx;
    final ey = cy > h - 1 - cy ? cy : h - 1 - cy;
    final gpuOut = await runShader(
        prog('lsc'),
        [w / 2, h.toDouble(), w.toDouble(), h.toDouble(), cx, cy,
         ex * ex + ey * ey, 0.5, maxValue.toDouble()],
        [src], [1], 1);
    expectClose(gpuOut, cpu, 1, 'lsc');
  });

  test('bayer_dnr', () async {
    final src = randFrame(w * h, 22);
    final cpu = Uint16List.fromList(src);
    applyBayerDenoise(cpu,
        width: w, height: h, pattern: pattern, strength: 1.0);
    final gpuOut = await runShader(
        prog('bayer_dnr'),
        [w / 2, h.toDouble(), w.toDouble(), h.toDouble(), 2, 1.0],
        [src], [1], 1);
    expectClose(gpuOut, cpu, 1, 'bayer_dnr');
  });

  test('highlight（recover + clip）', () async {
    final src = randFrame(w * h, 23);
    final cpu = Uint16List.fromList(src);
    applyHighlightRecovery(cpu,
        width: w, height: h,
        pattern: pattern, maxValue: maxValue, mode: 'recover', knee: 0.9);
    final gpuOut = await runShader(
        prog('highlight'),
        [w / 2, h.toDouble(), w.toDouble(), h.toDouble(), 2, 0,
         0.9 * maxValue, maxValue.toDouble()],
        [src], [1], 1);
    expectClose(gpuOut, cpu, 0, 'highlight recover');

    final cpuClip = Uint16List.fromList(src);
    applyHighlightRecovery(cpuClip,
        width: w, height: h,
        pattern: pattern, maxValue: maxValue, mode: 'clip', knee: 0.9);
    final gpuClip = await runShader(
        prog('highlight'),
        [w / 2, h.toDouble(), w.toDouble(), h.toDouble(), 2, 1,
         0.9 * maxValue, maxValue.toDouble()],
        [src], [1], 1);
    expectClose(gpuClip, cpuClip, 1, 'highlight clip');
  });

  test('ccm（非单位矩阵）', () async {
    final src = randFrame(w * h * 3, 24);
    const m = [1.2, 0.1, -0.1, 0.05, 1.1, -0.05, -0.02, 0.03, 1.05];
    final cpu = Uint16List.fromList(src);
    applyCcm(cpu, matrix: m, maxValue: maxValue);
    final gpuOut = await runShader(
        prog('ccm'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(), ...m],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 1, 'ccm');
  });

  test('rgb_dnr（luma 1.0 + chroma 0.5，四段联跑）', () async {
    final src = randFrame(w * h * 3, 25);
    final cpu = Uint16List.fromList(src);
    applyRgbDenoise(cpu,
        width: w, height: h, luma: 1.0, chroma: 0.5, maxValue: maxValue);
    // rgb→yuv → luma → chroma → yuv→rgb。
    var yuv = await runShader(
        prog('rgb2yuv'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         ...cscUniforms('bt601', 'full')],
        [src], [3], 3);
    yuv = await runShader(
        prog('rgb_dnr_luma'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), h.toDouble(), 1.0,
         maxValue.toDouble()],
        [yuv], [3], 3);
    yuv = await runShader(
        prog('rgb_dnr_chroma'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), h.toDouble(), 0.5,
         maxValue.toDouble()],
        [yuv], [3], 3);
    final gpuOut = await runShader(
        prog('yuv2rgb'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         (maxValue >> 1).toDouble()],
        [yuv], [3], 3);
    expectClose(gpuOut, cpu, 3, 'rgb_dnr');
  });

  test('sharpen（luma_extract + sharpen_apply）', () async {
    final src = randFrame(w * h * 3, 26);
    final cpu = Uint16List.fromList(src);
    applySharpen(cpu,
        width: w, height: h, amount: 0.5, threshold: 4.0, maxValue: maxValue);
    final yPlane = await runShader(
        prog('luma_extract'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), w / 2],
        [src], [3], 1);
    final rgbTex = await GpuPipeline.uploadPacked(src, w, h, 3);
    final yTex = await GpuPipeline.uploadPacked(yPlane, w, h, 1);
    final out = GpuPipeline.runPass(prog('sharpen_apply'), [
      w * 3 / 2, h.toDouble(), w / 2, h.toDouble(),
      w.toDouble(), h.toDouble(), 0.5, 4.0, maxValue.toDouble(),
    ], [rgbTex, yTex], w * 3 ~/ 2, h);
    final bytes = await GpuPipeline.readbackBytes(out);
    rgbTex.dispose();
    yTex.dispose();
    out.dispose();
    expectClose(bytes.buffer.asUint16List(), cpu, 4, 'sharpen');
  });

  test('csc_rgb2yuv（bt601/bt709 × full/limited）', () async {
    final src = randFrame(w * h * 3, 27);
    for (final standard in ['bt601', 'bt709']) {
      for (final range in ['full', 'limited']) {
        final cpu = convertRgbToYuvCsc(src,
            width: w, height: h,
            standard: standard, range: range, maxValue: maxValue);
        final gpuOut = await runShader(
            prog('rgb2yuv'),
            [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
             ...cscUniforms(standard, range)],
            [src], [3], 3);
        expectClose(gpuOut, cpu, 2, 'rgb2yuv $standard/$range');
      }
    }
  });

  test('csc_yuv2hsl', () async {
    final src = randFrame(w * h * 3, 28);
    final cpu = yuvToHsl(src, maxValue: maxValue);
    final gpuOut = await runShader(
        prog('yuv2hsl'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble(),
         (maxValue >> 1).toDouble()],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 2, 'yuv2hsl');
  });

  test('csc_hsl2rgb', () async {
    final src = randFrame(w * h * 3, 29);
    final cpu = hslToRgb(src, maxValue: maxValue);
    final gpuOut = await runShader(
        prog('hsl2rgb'),
        [w * 3 / 2, h.toDouble(), w.toDouble(), maxValue.toDouble()],
        [src], [3], 3);
    expectClose(gpuOut, cpu, 2, 'hsl2rgb');
  });
}
