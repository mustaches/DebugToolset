// RN50 GPU 纹理驻留链（metrics/clip_rn50_gpu.dart + shaders/nn 的
// avgpool2x2/addrelu shader 与 conv shader 的 uStride 扩展）测试：
// - avgPool2x2/addRelu/conv-s2 三个新 GPU 原语与 CPU ops 对拍（含奇数
//   尺寸）；
// - 分块（banded）变体：强制小带预算（GpuNnBackend.debugMaxBandTexels）
//   使小尺寸也切带，conv-s2 带间 halo（2th+2 行 padded 带）、avgpool
//   奇偶约束（末带高 1 空带丢弃）、addRelu 同分块校验、conv 的
//   forceOutHeights 残差分块对齐对拍 CPU ops；
// - ClipRn50Gpu.forwardTrunk 整链（单纹理 96×72 与 debugForceBanded
//   强制分块 256×48 多带缝合）+ CPU 池并行 attention vs
//   ClipRn50Dart.forward 同步版特征对拍；
// - 端到端 CLIPIQA GPU 路径分数 vs CPU 池 / Python 桥接基线（64×48
//   busyFrame，口径同 test/isp_clipiqa_dart_test.dart；更大尺寸的精度
//   对拍在真机基准 scratch/nn_gpu_rn50_bench_main.dart 记录）；
// - 回退语义：enabled=false 关断、超宽输入（分块规划也不可行）抛
//   UnsupportedError 整链回退 CPU 池。
// 无 GPU 环境（shader 加载失败）或 .nnw 权重缺失时自动跳过。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clip_rn50_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clip_rn50_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clipiqa_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart'
    as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';
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
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
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
  ClipRn50Gpu? rn50Gpu;

  bool weightsExist() => File(clipiqaWeightsPath).existsSync();

  setUpAll(() async {
    gpu = await GpuNnBackend.tryCreate();
    if (gpu == null) {
      // ignore: avoid_print
      print('GpuNnBackend 初始化失败（无 GPU 环境），跳过全部用例');
      return;
    }
    if (weightsExist()) {
      rn50Gpu = await ClipRn50Gpu.load(gpu!, clipiqaWeightsPath);
    }
  });

  tearDownAll(() {
    rn50Gpu?.dispose();
    gpu?.dispose();
  });

  group('GPU 新原语 vs CPU ops', () {
    test('avgPool2x2Gpu（含奇数尺寸）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (c, h, w) in [(8, 16, 16), (12, 15, 17), (5, 7, 9)]) {
        final x = NnTensor(randF32(c * h * w, 42 + c), [1, c, h, w]);
        final ref = ops.avgPool2d(x, 2, 2, 2, 2, 0, 0);
        final xg = await g.uploadFeatureMap(x);
        final out = await g.downloadFeatureMap(g.avgPool2x2Gpu(xg),
            channels: c);
        xg.dispose();
        expect(out.shape, ref.shape, reason: '$c ch ${h}x$w');
        final (maxAbs, rel) = errStats(out.data, ref.data);
        // ignore: avoid_print
        print('avgPool2x2Gpu $c ch ${h}x$w: maxAbs=$maxAbs relToRms=$rel');
        expect(rel, lessThan(2e-2), reason: '$c ch ${h}x$w');
      }
    });

    test('addReluGpu（含正负混合）', () async {
      final g = gpu;
      if (g == null) return;
      const c = 8, h = 12, w = 10;
      final a = NnTensor(randF32(c * h * w, 7), [1, c, h, w]);
      final b = NnTensor(randF32(c * h * w, 8), [1, c, h, w]);
      final ref = ops.relu(NnTensor(
          Float32List.fromList(
              [for (var i = 0; i < a.numel; i++) a.data[i] + b.data[i]]),
          [1, c, h, w]));
      final ag = await g.uploadFeatureMap(a);
      final bg = await g.uploadFeatureMap(b);
      final out = await g.downloadFeatureMap(g.addReluGpu(ag, bg),
          channels: c);
      ag.dispose();
      bg.dispose();
      final (maxAbs, rel) = errStats(out.data, ref.data);
      // ignore: avoid_print
      print('addReluGpu: maxAbs=$maxAbs relToRms=$rel');
      expect(rel, lessThan(2e-2));
    });

    test('conv3x3 stride2 与 CPU 对拍（多形状）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (cin, cout, h, w) in [
        (3, 32, 48, 36),
        (8, 16, 17, 15),
        (32, 64, 24, 33),
      ]) {
        final x = NnTensor(randF32(cin * h * w, 1 + cin), [1, cin, h, w]);
        final wgt =
            NnTensor(randF32(cout * cin * 9, 2 + cout, scale: 0.2),
                [cout, cin, 3, 3]);
        final bias = randF32(cout, 3, scale: 0.1);
        final ref = ops.conv2d(x, wgt,
            bias: bias, strideH: 2, strideW: 2, padH: 1, padW: 1);
        final out = await g.conv2dAsync(x, wgt,
            bias: bias, strideH: 2, strideW: 2, padH: 1, padW: 1);
        expect(out.shape, ref.shape, reason: '$cin→$cout ${h}x$w s2');
        final (maxAbs, rel) = errStats(out.data, ref.data);
        // ignore: avoid_print
        print('conv2dAsync s2 $cin→$cout ${h}x$w: maxAbs=$maxAbs '
            'relToRms=$rel');
        expect(rel, lessThan(2e-2), reason: '$cin→$cout ${h}x$w s2');
      }
    });
  });

  group('分块（banded）新原语 vs CPU ops（强制小带预算）', () {
    // debugMaxBandTexels=65536：64 通道在 W=48 时带高被压到 32，
    // 65 高切成 [32,32,1]，覆盖带边界 halo 与末带高 1 的空带丢弃。
    setUp(() => GpuNnBackend.debugMaxBandTexels = 65536);
    tearDown(() => GpuNnBackend.debugMaxBandTexels = 0);

    test('conv2dGpuBanded stride2（奇数尺寸，多带缝合）', () async {
      final g = gpu;
      if (g == null) return;
      const cin = 64, cout = 64, h = 65, w = 48;
      final x = NnTensor(randF32(cin * h * w, 11), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 9, 12, scale: 0.1),
          [cout, cin, 3, 3]);
      final bias = randF32(cout, 13, scale: 0.1);
      final ref = ops.conv2d(x, wgt,
          bias: bias, strideH: 2, strideW: 2, padH: 1, padW: 1);
      final xg = await g.uploadFeatureMapBanded(x);
      expect(xg.bandHeights, [32, 32, 1]);
      final wg = await g.uploadConvWeights(wgt, cin, bias: bias);
      final outB = g.conv2dGpuBanded(xg, wg, stride: 2);
      expect(outB.height, 33);
      expect(outB.width, 24);
      final out = await g.downloadFeatureMapBanded(outB, channels: cout);
      xg.dispose();
      wg.dispose();
      outB.dispose();
      expect(out.shape, ref.shape);
      final (maxAbs, rel) = errStats(out.data, ref.data);
      // ignore: avoid_print
      print('conv2dGpuBanded s2 ${cin}ch ${h}x$w 带=${outB.bandHeights}: '
          'maxAbs=$maxAbs relToRms=$rel');
      expect(rel, lessThan(2e-2));
    });

    test('avgPool2x2GpuBanded（末带高 1 空带丢弃）', () async {
      final g = gpu;
      if (g == null) return;
      const c = 64, h = 65, w = 48;
      final x = NnTensor(randF32(c * h * w, 21), [1, c, h, w]);
      final ref = ops.avgPool2d(x, 2, 2, 2, 2, 0, 0);
      final xg = await g.uploadFeatureMapBanded(x);
      final outB = g.avgPool2x2GpuBanded(xg);
      expect(outB.bandHeights, [16, 16]);
      final out = await g.downloadFeatureMapBanded(outB, channels: c);
      xg.dispose();
      outB.dispose();
      expect(out.shape, ref.shape);
      final (maxAbs, rel) = errStats(out.data, ref.data);
      // ignore: avoid_print
      print('avgPool2x2GpuBanded ${c}ch ${h}x$w: maxAbs=$maxAbs '
          'relToRms=$rel');
      expect(rel, lessThan(2e-2));
    });

    test('addReluGpuBanded（同分块两输入）', () async {
      final g = gpu;
      if (g == null) return;
      const c = 64, h = 65, w = 48;
      final a = NnTensor(randF32(c * h * w, 31), [1, c, h, w]);
      final b = NnTensor(randF32(c * h * w, 32), [1, c, h, w]);
      final ref = ops.relu(NnTensor(
          Float32List.fromList(
              [for (var i = 0; i < a.numel; i++) a.data[i] + b.data[i]]),
          [1, c, h, w]));
      final ag = await g.uploadFeatureMapBanded(a);
      final bg = await g.uploadFeatureMapBanded(b);
      final outB = g.addReluGpuBanded(ag, bg);
      final out = await g.downloadFeatureMapBanded(outB, channels: c);
      ag.dispose();
      bg.dispose();
      outB.dispose();
      final (maxAbs, rel) = errStats(out.data, ref.data);
      // ignore: avoid_print
      print('addReluGpuBanded ${c}ch ${h}x$w: maxAbs=$maxAbs relToRms=$rel');
      expect(rel, lessThan(2e-2));
    });

    test('conv2dGpuBanded forceOutHeights（残差分块对齐）', () async {
      final g = gpu;
      if (g == null) return;
      const cin = 64, cout = 128, h = 65, w = 48;
      final x = NnTensor(randF32(cin * h * w, 41), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 9, 42, scale: 0.1),
          [cout, cin, 3, 3]);
      final ref = ops.conv2d(x, wgt, padH: 1, padW: 1);
      final xg = await g.uploadFeatureMapBanded(x);
      expect(xg.bandHeights, [32, 32, 1]);
      final wg = await g.uploadConvWeights(wgt, cin);
      // 强制更细的输出分块（模拟对齐 128ch identity 分块）。
      const forced = [16, 16, 16, 16, 1];
      final outB = g.conv2dGpuBanded(xg, wg, forceOutHeights: forced);
      expect(outB.bandHeights, forced);
      // 分块不一致的 addRelu 拒绝（调用方回退 CPU 的语义）：64ch 输入的
      // 带高 [32,32,1] 与 forced [16,16,16,16,1] 不同。
      final other = await g.uploadFeatureMapBanded(x);
      expect(() => g.addReluGpuBanded(outB, other),
          throwsA(isA<UnsupportedError>()));
      other.dispose();
      final out = await g.downloadFeatureMapBanded(outB, channels: cout);
      xg.dispose();
      wg.dispose();
      outB.dispose();
      expect(out.shape, ref.shape);
      final (maxAbs, rel) = errStats(out.data, ref.data);
      // ignore: avoid_print
      print('conv2dGpuBanded forced $cin→$cout ${h}x$w: maxAbs=$maxAbs '
          'relToRms=$rel');
      expect(rel, lessThan(2e-2));
    });
  });

  group('ClipRn50Gpu 主干 + 并行 attention vs 同步 CPU', () {
    /// GPU 主干 → NnPool 并行 attention 的特征 vs ClipRn50Dart.forward。
    Future<void> checkChain(int w, int h, {required bool banded}) async {
      final rg = rn50Gpu;
      if (rg == null) return;
      final pool = NnPool();
      await pool.start(4);
      if (banded) {
        GpuNnBackend.debugMaxBandTexels = 65536;
        ClipRn50Gpu.debugForceBanded = true;
      }
      try {
        final x = clipiqaInput(busyFrame(w, h), w, h);
        final ref = ClipRn50Dart.load(clipiqaWeightsPath).forward(x);
        final rn50 = ClipRn50Dart.load(clipiqaWeightsPath);
        final trunk = await rg.forwardTrunk(x);
        final feat = await rn50.attnPoolForwardParallel(trunk, pool);
        expect(feat.length, 1024);
        final (maxAbs, rel) = errStats(feat, ref);
        final cos = cosine(feat, ref);
        // ignore: avoid_print
        print('rn50GpuTrunk ${w}x$h banded=$banded 特征: maxAbs=$maxAbs '
            'relToRms=$rel cosine=$cos');
        expect(rel, lessThan(2e-2), reason: '${w}x$h banded=$banded');
        expect(cos, greaterThan(0.9999), reason: '${w}x$h banded=$banded');
      } finally {
        if (banded) {
          GpuNnBackend.debugMaxBandTexels = 0;
          ClipRn50Gpu.debugForceBanded = false;
        }
        pool.dispose();
      }
    }

    // 注：flutter test 环境为软件光栅（SkVM），RN50 有 53 个 conv——
    // 整链前向耗时随像素数增长，故 test 内用 ≤256×48 级尺寸；更大尺寸
    // 的精度/性能由真机基准 scratch/nn_gpu_rn50_bench_main.dart 记录。
    test('单纹理路径 96x72', () => checkChain(96, 72, banded: false),
        timeout: const Timeout(Duration(minutes: 10)));

    // 256 高 48 宽 + 小带预算：layer1 起 256ch 带高被压到 32，多带缝合
    // （stem conv1 s2 的 2th+2 padded 带、avgpool 奇偶、conv3 残差
    // forceOutHeights 对齐均被覆盖）。
    test('分块路径 256x48（强制多带）', () => checkChain(48, 256, banded: true),
        timeout: const Timeout(Duration(minutes: 10)));
  });

  group('端到端分数对拍（GPU 路径 vs CPU 池 / Python 基线）', () {
    /// 调 iqa_bridge.py 一次性模式取参考分（同
    /// test/isp_clipiqa_dart_test.dart）。
    Future<double> pyRef(String aPath) async {
      final res = await Process.run(
          pyIqaPythonPath,
          [pyIqaBridgePath, '--metric', 'clipiqa', '--a', aPath],
          workingDirectory: Directory.current.path);
      for (final line in const LineSplitter().convert(res.stdout as String)) {
        final t = line.trimLeft();
        if (!t.startsWith('{')) continue;
        final obj = jsonDecode(t) as Map<String, Object?>;
        if (obj['ok'] == true) {
          return (obj['score'] as num).toDouble();
        }
        throw StateError('桥接一次性模式失败（clipiqa）: $t');
      }
      throw StateError('桥接一次性模式无 JSON 应答（clipiqa）: '
          'exit=${res.exitCode} stdout=${res.stdout} stderr=${res.stderr}');
    }

    test('CLIPIQA 64×48 busyFrame（GPU 路径）', () async {
      final rg = rn50Gpu;
      if (rg == null || !weightsExist()) return;
      const w = 64, h = 48;
      final a = busyFrame(w, h, noisy: true, noiseSeed: 3);
      var usedGpu = false;
      final pool = NnPool();
      await pool.start(4);
      try {
        final gpuV = await clipiqaScoreParallel(a, w, h,
            pool: pool, gpuTrunk: rg, onBackend: (g) => usedGpu = g);
        expect(usedGpu, isTrue, reason: 'GPU 路径应被采用');
        final cpuV = await clipiqaScoreParallel(a, w, h, pool: pool);
        final relCpu = (gpuV - cpuV).abs() / cpuV.abs();
        if (PyIqaWorker.available) {
          final aPath = await pyIqaWriteTempPng(a, w, h);
          final pyV = await pyRef(aPath);
          final relPy = (gpuV - pyV).abs() / pyV.abs();
          // ignore: avoid_print
          print('CLIPIQA 64x48 GPU路径: gpu=$gpuV cpu=$cpuV python=$pyV '
              'relErrVsCpu=$relCpu relErrVsPython=$relPy');
          expect(relPy, lessThanOrEqualTo(2e-2));
        } else {
          // ignore: avoid_print
          print('CLIPIQA 64x48 GPU路径: gpu=$gpuV cpu=$cpuV '
              'relErrVsCpu=$relCpu（无 Python 环境，跳过一次对拍）');
        }
        expect(relCpu, lessThanOrEqualTo(2e-2));
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('enabled=false 时静态开关关断 GPU 路径', () async {
      final rg = rn50Gpu;
      if (rg == null || !weightsExist()) return;
      const w = 64, h = 48;
      final a = busyFrame(w, h);
      ClipRn50Gpu.enabled = false;
      try {
        var usedGpu = true;
        final v = await clipiqaScoreParallel(a, w, h,
            gpuTrunk: rg, workers: 4, onBackend: (g) => usedGpu = g);
        expect(usedGpu, isFalse);
        expect(v, await clipiqaScoreParallel(a, w, h, workers: 4));
      } finally {
        ClipRn50Gpu.enabled = true;
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('超大输入整链回退（抛 UnsupportedError）', () async {
      final rg = rn50Gpu;
      if (rg == null) return;
      // 40000 宽：stem conv1 输出即使按带高 16 切分也超出单带预算
      // （2*8*20000*18 > 2^23）→ 分块预检拒绝，上传前抛错。
      expect(() => rg.forwardTrunk(NnTensor.zeros([1, 3, 64, 40000])),
          throwsA(isA<UnsupportedError>()));
    });
  });
}
