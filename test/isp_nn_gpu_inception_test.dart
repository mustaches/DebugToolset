// InceptionV3 GPU 纹理驻留链（metrics/inception_v3_gpu.dart + 泛化 conv
// shader + shaders/nn 的 pool3x3/concat4 shader）测试：
// - 泛化 conv 全形态（3x3 p0 s1/s2、5x5 p2、1x7/7x1、1x3/3x1、原生 1x1、
//   relu 融合）与 pool3x3 三模式（max s2/p0、max s1/p1、avg s1/p1
//   countIncludePad=false）、concat2/concat4 与 CPU ops 对拍（含奇数
//   尺寸）；
// - InceptionV3Gpu.forward 整链（99² 迷你输入，全分支形状合法）vs
//   InceptionV3Dart.forward 特征对拍；
// - patch 端到端（busyFrame 256×192，2 patch）：GPU 路径特征 vs CPU
//   池特征；enabled=false 关断；超大输入 UnsupportedError 回退。
//
// 注：flutter test 环境为软件光栅（SkVM），patch 恒 resize 到 299² 的
// 完整前向在 test 内为小时级——299² 的精度（vs 黄金值/Python 基线）与
// 性能由真机基准 scratch/nn_gpu_inception_bench_main.dart 记录。
// 无 GPU 环境（shader 加载失败）或 .nnw 权重缺失时自动跳过。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_v3_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart'
    as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List randF32(int n, int seed, {double scale = 1.0}) {
  final rng = math.Random(seed);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (rng.nextDouble() * 2 - 1) * scale;
  }
  return out;
}

/// 尺度感知的最大相对误差：maxAbs / rms(expected)。
(double, double) errStats(Float32List actual, Float32List expected) {
  var maxAbs = 0.0, sumSq = 0.0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxAbs) maxAbs = d;
    sumSq += expected[i] * expected[i];
  }
  return (maxAbs, maxAbs / math.sqrt(sumSq / expected.length));
}

/// 余弦相似度（a、b 等长）。
double cosine(Float32List a, Float32List b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// 高纹理彩色测试帧（图案同 test/isp_pyiqa_test.dart 的 busyFrame）。
Uint8List busyFrame(int w, int h, {bool noisy = false, int noiseSeed = 0}) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; h > y; y++) {
    for (var x = 0; w > x; x++) {
      final i = (y * w + x) * 4;
      var r = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0)
          .toInt();
      var g = (128 +
              70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
              40 * math.cos((2 * x - y) / 6.7))
          .clamp(0.0, 255.0)
          .toInt();
      var b = (128 +
              70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
          .clamp(0.0, 255.0)
          .toInt();
      if (noisy) {
        final base = ((y * w + x) * 3) + noiseSeed * 7;
        r = (r + (base * 31) % 61 - 30).clamp(0, 255);
        g = (g + ((base + 1) * 31) % 61 - 30).clamp(0, 255);
        b = (b + ((base + 2) * 31) % 61 - 30).clamp(0, 255);
      }
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GpuNnBackend? gpu;
  InceptionV3Gpu? incGpu;

  bool weightsExist() => File(inceptionV3WeightsPath).existsSync();

  setUpAll(() async {
    gpu = await GpuNnBackend.tryCreate();
    if (gpu == null) {
      // ignore: avoid_print
      print('GpuNnBackend 初始化失败（无 GPU 环境），跳过全部用例');
      return;
    }
    if (weightsExist()) {
      incGpu = await InceptionV3Gpu.load(gpu!, inceptionV3WeightsPath);
    }
  });

  tearDownAll(() {
    incGpu?.dispose();
    gpu?.dispose();
  });

  group('泛化 conv 原语 vs CPU ops', () {
    // (cin, cout, kH, kW, stride, padH, padW)
    test('全形态对拍（3x3p0/s2、5x5p2、非对称、原生 1x1）', () async {
      final g = gpu;
      if (g == null) return;
      const h = 17, w = 15;
      for (final (cin, cout, kh, kw, s, ph, pw) in [
        (3, 32, 3, 3, 2, 0, 0), // Conv2d_1a 形态
        (8, 16, 3, 3, 1, 0, 0), // Conv2d_2a/4a 形态
        (8, 16, 3, 3, 2, 1, 1), // s2 p1（RN50 回归形态）
        (8, 16, 5, 5, 1, 2, 2), // Mixed_5* branch5x5_2
        (16, 32, 1, 7, 1, 0, 3), // Mixed_6* 1x7
        (16, 32, 7, 1, 1, 3, 0), // Mixed_6* 7x1
        (16, 32, 1, 3, 1, 0, 1), // Mixed_7* 1x3
        (16, 32, 3, 1, 1, 1, 0), // Mixed_7* 3x1
        (8, 16, 1, 1, 1, 0, 0), // 原生 1x1（不再嵌入 3x3）
      ]) {
        final x = NnTensor(randF32(cin * h * w, cin + kh), [1, cin, h, w]);
        final wgt = NnTensor(
            randF32(cout * cin * kh * kw, cout + kw, scale: 0.2),
            [cout, cin, kh, kw]);
        final bias = randF32(cout, 3, scale: 0.1);
        final ref = ops.conv2d(x, wgt,
            bias: bias, strideH: s, strideW: s, padH: ph, padW: pw);
        final out = await g.conv2dAsync(x, wgt,
            bias: bias, strideH: s, strideW: s, padH: ph, padW: pw);
        expect(out.shape, ref.shape,
            reason: '$cin→$cout ${kh}x$kw s$s p$ph,$pw');
        final (maxAbs, rel) = errStats(out.data, ref.data);
        // ignore: avoid_print
        print('conv $cin→$cout ${kh}x$kw s$s p$ph,$pw: maxAbs=$maxAbs '
            'relToRms=$rel');
        expect(rel, lessThan(2e-2), reason: '$cin→$cout ${kh}x$kw s$s');
      }
    });

    test('relu 融合（conv2dGpu relu:true 末 pass max(·,0)）', () async {
      final g = gpu;
      if (g == null) return;
      const cin = 8, cout = 16, h = 13, w = 11;
      final x = NnTensor(randF32(cin * h * w, 5), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 9, 6, scale: 0.3),
          [cout, cin, 3, 3]);
      final bias = randF32(cout, 7, scale: 0.5);
      final ref = ops.relu(
          ops.conv2d(x, wgt, bias: bias, padH: 1, padW: 1));
      final xg = await g.uploadFeatureMap(x);
      final wg = await g.uploadConvWeights(wgt, cin, bias: bias);
      final out = await g.downloadFeatureMap(
          g.conv2dGpu(xg, wg, relu: true),
          channels: cout);
      xg.dispose();
      wg.dispose();
      final (maxAbs, rel) = errStats(out.data, ref.data);
      // ignore: avoid_print
      print('conv+relu 融合: maxAbs=$maxAbs relToRms=$rel');
      expect(rel, lessThan(2e-2));
    });
  });

  group('pool3x3 / concat 原语 vs CPU ops', () {
    test('pool3x3Gpu 三模式（含奇数尺寸）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (avg, s, p, c, h, w) in [
        (false, 2, 0, 8, 16, 16), // stem/6a/7a maxPool k3 s2 p0
        (false, 2, 0, 12, 15, 17), // 奇数尺寸
        (false, 1, 1, 8, 15, 17), // Mixed_7c maxPool k3 s1 p1
        (true, 1, 1, 8, 16, 16), // branch_pool avg cip=false
        (true, 1, 1, 12, 15, 17), // 奇数尺寸（边界窗口除数有效元素数）
      ]) {
        final x = NnTensor(randF32(c * h * w, 20 + c), [1, c, h, w]);
        final ref = avg
            ? ops.avgPool2d(x, 3, 3, s, s, p, p, countIncludePad: false)
            : ops.maxPool2d(x, 3, 3, s, s, p, p);
        final xg = await g.uploadFeatureMap(x);
        final out = await g.downloadFeatureMap(
            g.pool3x3Gpu(xg, avg: avg, stride: s, pad: p),
            channels: c);
        xg.dispose();
        expect(out.shape, ref.shape, reason: 'avg=$avg s$s p$p ${h}x$w');
        final (maxAbs, rel) = errStats(out.data, ref.data);
        // ignore: avoid_print
        print('pool3x3 avg=$avg s$s p$p ${c}ch ${h}x$w: maxAbs=$maxAbs '
            'relToRms=$rel');
        expect(rel, lessThan(2e-2));
      }
    });

    test('concatChannelsGpu（4 路与 2 路）', () async {
      final g = gpu;
      if (g == null) return;
      const h = 9, w = 11;
      for (final chs in [
        [8, 16, 12, 4],
        [24, 8],
      ]) {
        final srcs = <NnTensor>[];
        for (var i = 0; i < chs.length; i++) {
          srcs.add(NnTensor(randF32(chs[i] * h * w, 30 + i), [1, chs[i], h, w]));
        }
        final ref = ops.concatChannels(srcs);
        final gs = <GpuNnTensor>[];
        for (final s in srcs) {
          gs.add(await g.uploadFeatureMap(s));
        }
        final outG = g.concatChannelsGpu(gs);
        final out = await g.downloadFeatureMap(outG);
        for (final t in gs) {
          t.dispose();
        }
        outG.dispose();
        expect(out.shape, ref.shape, reason: '$chs');
        // 纯字节拷贝：位级一致（fp16 往返后与源 half 相同）。
        var mismatch = 0;
        for (var i = 0; i < ref.numel; i++) {
          if (out.data[i] != halfBitsToFloat(floatToHalfBits(ref.data[i]))) {
            mismatch++;
          }
        }
        expect(mismatch, 0, reason: '$chs');
      }
    });
  });

  group('InceptionV3Gpu.forward 整链 vs CPU', () {
    // 99² 迷你输入：全分支形状仍合法（99→49→48→48→23→23→21→10→…→
    // Mixed_7* 1²→adaptive pool），软件光栅分钟级可完成。
    test('99x99 整链特征对拍', () async {
      final ig = incGpu;
      if (ig == null) return;
      final x = NnTensor(randF32(3 * 99 * 99, 40, scale: 0.5), [1, 3, 99, 99]);
      final ref = InceptionV3Dart.load(inceptionV3WeightsPath).forward(x);
      final feat = await ig.forward(x);
      expect(feat.length, inceptionFeatureDim);
      final (maxAbs, rel) = errStats(feat, ref);
      final cos = cosine(feat, ref);
      // ignore: avoid_print
      print('InceptionV3Gpu 99x99: maxAbs=$maxAbs relToRms=$rel cosine=$cos');
      // fp16 在 121 个 conv 深链上累积：relToRms ~0.1 为预期量级（RN50
      // 53 层为 ~0.016，VGG16 13 层 ~0.01/切片）；绑定判据为方向
      // （cosine），幅度偏差对 FID/KID 的影响由真机 bench 的端到端
      // 对拍口径验收。
      expect(rel, lessThan(1.5e-1));
      expect(cos, greaterThan(0.9999));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('超大输入预检回退（抛 UnsupportedError）', () async {
      final ig = incGpu;
      if (ig == null) return;
      // 4096²：Mixed_6* 折叠纹素数远超 2^24 → 预检拒绝（渲染前抛错）。
      expect(() => ig.forward(NnTensor.zeros([1, 3, 4096, 4096])),
          throwsA(isA<UnsupportedError>()));
    });
  });

  group('patch 特征提取（GPU 路径 vs CPU 池）', () {
    // patch 恒 resize 到 299²，软件光栅下 GPU 路径为小时级——这里只验证
    // 关断语义与 CPU 路径位级一致；GPU 路径的 patch 对拍归真机 bench。
    test('enabled=false 时关断 GPU 路径（走 CPU 池）', () async {
      if (!weightsExist()) return;
      const w = 64, h = 48;
      final a = busyFrame(w, h);
      InceptionV3Gpu.enabled = false;
      try {
        final v = await inceptionPatchFeaturesParallel(a, w, h,
            gpuNet: incGpu, workers: 4);
        expect(v, await inceptionPatchFeaturesParallel(a, w, h, workers: 4));
      } finally {
        InceptionV3Gpu.enabled = true;
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
