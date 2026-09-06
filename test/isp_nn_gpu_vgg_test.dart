// VGG16 GPU 纹理驻留链（metrics/vgg16_gpu.dart + shaders/nn 的
// relu/maxpool/l2pool/stitch shader）测试：
// - relu/maxpool2x2/l2pool 三个新 GPU 原语与 CPU ops 对拍；
// - Vgg16Gpu.forward 的 5 层切片特征 vs Vgg16Dart.forward 逐层
//   relToRms（maxpool 与 L2pooling 两变体，含奇数尺寸）；
// - 分块（banded）路径：强制小带预算（GpuNnBackend.debugMaxBandTexels）
//   使 64×48 级尺寸也切带，conv/relu/maxpool/l2pool 逐带与 stitch halo
//   拼接对拍 CPU ops（含奇数尺寸、末带高 1 空带丢弃），及
//   debugForceBanded 整链逐层切片对拍；
// - 端到端 LPIPS/DISTS GPU 路径分数 vs Python 桥接基线（busyFrame
//   64×48 干净/加噪对，口径同 test/isp_lpips_dists_dart_test.dart；
//   256×192 的对拍因 test 环境为软件光栅过慢，移至真机基准
//   scratch/nn_gpu_vgg_bench_main.dart 记录）；
// - 回退语义：超宽输入（分块规划也不可行）抛 UnsupportedError、整链
//   回退 CPU 池。
// 无 GPU 环境（shader 加载失败）或 .nnw 权重缺失时自动跳过。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/dists_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
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

/// busyFrame → LPIPS ScalingLayer 输出（常量同 lpips_dart.dart 头注释）。
NnTensor lpipsInput(Uint8List rgba, int width, int height) {
  const shift = [-0.030, -0.088, -0.188];
  const scale = [0.458, 0.448, 0.450];
  final s = width * height;
  final out = NnTensor.zeros([1, 3, height, width]);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    for (var i = 0, j = c; i < s; i++, j += 4) {
      out.data[base + i] = ((rgba[j] / 255.0) * 2.0 - 1.0 - shift[c]) / scale[c];
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GpuNnBackend? gpu;
  Vgg16Gpu? vggGpu;

  bool weightsExist() =>
      File(lpipsVggWeightsPath).existsSync() &&
      File(lpipsLinWeightsPath).existsSync() &&
      File(distsWeightsPath).existsSync();

  setUpAll(() async {
    gpu = await GpuNnBackend.tryCreate();
    if (gpu == null) {
      // ignore: avoid_print
      print('GpuNnBackend 初始化失败（无 GPU 环境），跳过全部用例');
      return;
    }
    if (File(lpipsVggWeightsPath).existsSync()) {
      vggGpu = await Vgg16Gpu.load(gpu!, lpipsVggWeightsPath);
    }
  });

  tearDownAll(() {
    vggGpu?.dispose();
    gpu?.dispose();
  });

  group('GPU 池化/激活原语 vs CPU ops', () {
    test('reluGpu', () async {
      final g = gpu;
      if (g == null) return;
      const c = 8, h = 13, w = 11;
      final x = NnTensor(randF32(c * h * w, 3), [1, c, h, w]);
      final xGpu = await g.uploadFeatureMap(x);
      final outGpu = g.reluGpu(xGpu);
      final out = await g.downloadFeatureMap(outGpu, channels: c);
      xGpu.dispose();
      outGpu.dispose();
      final cpu = ops.relu(x);
      final (_, rel) = errStats(out.data, cpu.data);
      // ignore: avoid_print
      print('reluGpu 13x11x$c: relToRms=$rel');
      expect(rel, lessThan(1e-3));
    });

    test('maxPool2x2Gpu（含奇数尺寸）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (w, h, c) in [(16, 16, 8), (15, 13, 4), (17, 9, 12)]) {
        final x = NnTensor(randF32(c * h * w, w * h + c), [1, c, h, w]);
        final xGpu = await g.uploadFeatureMap(x);
        final outGpu = g.maxPool2x2Gpu(xGpu);
        final out = await g.downloadFeatureMap(outGpu, channels: c);
        xGpu.dispose();
        outGpu.dispose();
        final cpu = ops.maxPool2d(x, 2, 2, 2, 2, 0, 0);
        expect(out.shape, cpu.shape, reason: '${w}x$h');
        final (_, rel) = errStats(out.data, cpu.data);
        // ignore: avoid_print
        print('maxPool2x2Gpu ${w}x$h x$c: relToRms=$rel');
        expect(rel, lessThan(1e-3), reason: '${w}x$h x$c');
      }
    });

    test('l2PoolDistsGpu（含奇数尺寸）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (w, h, c) in [(16, 16, 8), (15, 13, 4), (17, 9, 12)]) {
        final x = NnTensor(randF32(c * h * w, w + h + c), [1, c, h, w]);
        final xGpu = await g.uploadFeatureMap(x);
        final outGpu = g.l2PoolDistsGpu(xGpu);
        final out = await g.downloadFeatureMap(outGpu, channels: c);
        xGpu.dispose();
        outGpu.dispose();
        final cpu = ops.l2PoolingDists(x);
        expect(out.shape, cpu.shape, reason: '${w}x$h');
        final (maxAbs, rel) = errStats(out.data, cpu.data);
        // ignore: avoid_print
        print('l2PoolDistsGpu ${w}x$h x$c: maxAbs=$maxAbs relToRms=$rel');
        expect(rel, lessThan(1e-2), reason: '${w}x$h x$c');
      }
    });
  });

  group('分块（banded）原语 vs CPU ops（强制小带预算）', () {
    // debugMaxBandTexels=65536：64 通道在 W≈64 时带高被压到 16，
    // 65×49 → [16,16,16,1]，覆盖多带、halo、奇数尺寸、末带高 1。
    setUp(() => GpuNnBackend.debugMaxBandTexels = 65536);
    tearDown(() => GpuNnBackend.debugMaxBandTexels = 0);

    test('conv2dGpuBanded（含奇数尺寸与带边界 halo）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (w, h) in [(64, 48), (65, 49)]) {
        const cin = 64, cout = 64;
        final x = NnTensor(randF32(cin * h * w, w * h), [1, cin, h, w]);
        final wgt = NnTensor(
            randF32(cout * cin * 9, w + h, scale: 0.3), [cout, cin, 3, 3]);
        final bias = randF32(cout, w * 3 + h, scale: 0.5);
        final xGpu = await g.uploadFeatureMapBanded(x);
        expect(xGpu.bands.length, greaterThan(1), reason: '${w}x$h 须多分带');
        final wGpu = await g.uploadConvWeights(wgt, cin, bias: bias);
        final outGpu = g.conv2dGpuBanded(xGpu, wGpu);
        expect(outGpu.bands.length, greaterThan(1));
        final out = await g.downloadFeatureMapBanded(outGpu, channels: cout);
        xGpu.dispose();
        wGpu.dispose();
        outGpu.dispose();
        final cpu = ops.conv2d(x, wgt, bias: bias, padH: 1, padW: 1);
        expect(out.shape, cpu.shape, reason: '${w}x$h');
        final (maxAbs, rel) = errStats(out.data, cpu.data);
        // ignore: avoid_print
        print('conv2dGpuBanded ${w}x$h $cin->$cout '
            '(带高=${outGpu.bands.map((b) => b.shape[2]).toList()}): '
            'maxAbs=$maxAbs relToRms=$rel');
        expect(rel, lessThan(1e-2), reason: '${w}x$h');
      }
    });

    test('reluGpuBanded', () async {
      final g = gpu;
      if (g == null) return;
      const c = 64, h = 49, w = 65;
      final x = NnTensor(randF32(c * h * w, 5), [1, c, h, w]);
      final xGpu = await g.uploadFeatureMapBanded(x);
      expect(xGpu.bands.length, greaterThan(1));
      final outGpu = g.reluGpuBanded(xGpu);
      final out = await g.downloadFeatureMapBanded(outGpu, channels: c);
      xGpu.dispose();
      outGpu.dispose();
      final cpu = ops.relu(x);
      final (_, rel) = errStats(out.data, cpu.data);
      // ignore: avoid_print
      print('reluGpuBanded ${w}x$h x$c: relToRms=$rel');
      expect(rel, lessThan(1e-3));
    });

    test('maxPool2x2GpuBanded（含末带高 1 空带丢弃）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (w, h) in [(64, 48), (65, 49)]) {
        const c = 64;
        final x = NnTensor(randF32(c * h * w, w + h), [1, c, h, w]);
        final xGpu = await g.uploadFeatureMapBanded(x);
        expect(xGpu.bands.length, greaterThan(1));
        final outGpu = g.maxPool2x2GpuBanded(xGpu);
        final out = await g.downloadFeatureMapBanded(outGpu, channels: c);
        xGpu.dispose();
        outGpu.dispose();
        final cpu = ops.maxPool2d(x, 2, 2, 2, 2, 0, 0);
        expect(out.shape, cpu.shape, reason: '${w}x$h');
        final (_, rel) = errStats(out.data, cpu.data);
        // ignore: avoid_print
        print('maxPool2x2GpuBanded ${w}x$h x$c: relToRms=$rel');
        expect(rel, lessThan(1e-3), reason: '${w}x$h');
      }
    });

    test('l2PoolDistsGpuBanded（含奇数尺寸 halo）', () async {
      final g = gpu;
      if (g == null) return;
      for (final (w, h) in [(64, 48), (65, 49)]) {
        const c = 64;
        final x = NnTensor(randF32(c * h * w, w * 2 + h), [1, c, h, w]);
        final xGpu = await g.uploadFeatureMapBanded(x);
        expect(xGpu.bands.length, greaterThan(1));
        final outGpu = g.l2PoolDistsGpuBanded(xGpu);
        final out = await g.downloadFeatureMapBanded(outGpu, channels: c);
        xGpu.dispose();
        outGpu.dispose();
        final cpu = ops.l2PoolingDists(x);
        expect(out.shape, cpu.shape, reason: '${w}x$h');
        final (maxAbs, rel) = errStats(out.data, cpu.data);
        // ignore: avoid_print
        print('l2PoolDistsGpuBanded ${w}x$h x$c: maxAbs=$maxAbs relToRms=$rel');
        expect(rel, lessThan(1e-2), reason: '${w}x$h');
      }
    });
  });

  group('Vgg16Gpu 分块链（debugForceBanded + 小带预算）逐层切片 vs CPU', () {
    Future<void> checkBandedChain(int w, int h,
        {required bool useL2Pooling}) async {
      final vg = vggGpu;
      if (vg == null) return;
      GpuNnBackend.debugMaxBandTexels = 65536;
      Vgg16Gpu.debugForceBanded = true;
      try {
        final x = lpipsInput(busyFrame(w, h), w, h);
        final cpu = Vgg16Dart.load(lpipsVggWeightsPath)
            .forward(x, useL2Pooling: useL2Pooling);
        final feats = await vg.forward(x, useL2Pooling: useL2Pooling);
        expect(feats.length, 5);
        const names = ['relu1_2', 'relu2_2', 'relu3_3', 'relu4_3', 'relu5_3'];
        for (var k = 0; k < 5; k++) {
          expect(feats[k].shape, cpu[k].shape,
              reason: '${names[k]} ${w}x$h l2=$useL2Pooling');
          final (maxAbs, rel) = errStats(feats[k].data, cpu[k].data);
          // ignore: avoid_print
          print('forwardGpuBanded ${w}x$h l2=$useL2Pooling ${names[k]} '
              '(${feats[k].shape}): maxAbs=$maxAbs relToRms=$rel');
          expect(rel, lessThan(2e-2),
              reason: '${names[k]} ${w}x$h l2=$useL2Pooling');
        }
      } finally {
        GpuNnBackend.debugMaxBandTexels = 0;
        Vgg16Gpu.debugForceBanded = false;
      }
    }

    // 分块使 pass 数约为单纹理路径的 3 倍，软件光栅下沿用 64×48 级尺寸。
    test('maxpool 变体 65x49（奇数尺寸，末带高 1 空带丢弃）',
        () => checkBandedChain(65, 49, useL2Pooling: false),
        timeout: const Timeout(Duration(minutes: 10)));
    test('L2pooling 变体 64x48（conv2_1 stitch 覆盖 3 源带）',
        () => checkBandedChain(64, 48, useL2Pooling: true),
        timeout: const Timeout(Duration(minutes: 10)));
  });

  group('Vgg16Gpu.forward 逐层切片 vs CPU', () {
    Future<void> checkChain(int w, int h, {required bool useL2Pooling}) async {
      final vg = vggGpu;
      if (vg == null) return;
      final x = lpipsInput(busyFrame(w, h), w, h);
      final cpu = Vgg16Dart.load(lpipsVggWeightsPath)
          .forward(x, useL2Pooling: useL2Pooling);
      final feats = await vg.forward(x, useL2Pooling: useL2Pooling);
      expect(feats.length, 5);
      const names = ['relu1_2', 'relu2_2', 'relu3_3', 'relu4_3', 'relu5_3'];
      for (var k = 0; k < 5; k++) {
        expect(feats[k].shape, cpu[k].shape,
            reason: '${names[k]} ${w}x$h l2=$useL2Pooling');
        final (maxAbs, rel) = errStats(feats[k].data, cpu[k].data);
        // ignore: avoid_print
        print('forwardGpu ${w}x$h l2=$useL2Pooling ${names[k]} '
            '(${feats[k].shape}): maxAbs=$maxAbs relToRms=$rel');
        expect(rel, lessThan(2e-2),
            reason: '${names[k]} ${w}x$h l2=$useL2Pooling');
      }
    }

    // 注：flutter test 环境为软件光栅（SkVM），整链前向耗时随像素数
    // 线性增长——实测 128×96 单链 >5min，故 test 内逐层对拍用 64×48
    // 级尺寸；256×192 的逐层/端到端精度在真机 GPU 上由
    // scratch/nn_gpu_vgg_bench_main.dart 记录（见其中 NN_VGG_BENCH 输出）。
    test('maxpool 变体 64x48', () => checkChain(64, 48, useL2Pooling: false),
        timeout: const Timeout(Duration(minutes: 10)));
    test('L2pooling 变体 64x48', () => checkChain(64, 48, useL2Pooling: true),
        timeout: const Timeout(Duration(minutes: 10)));
    test('L2pooling 变体 奇数尺寸 65x49',
        () => checkChain(65, 49, useL2Pooling: true),
        timeout: const Timeout(Duration(minutes: 10)));

    // 生产编排（submit0→submit1→download0→download1，两份切片纹理
    // 同时驻留）与逐图 forward 的结果逐位一致——每图的 GPU 计算序列
    // 完全相同，只是时间轴重叠。软件光栅下每变体 4 条整链前向
    // （64×48 约 5min），故两种池化变体拆成两个用例以不超 10min 上限。
    Future<void> checkPipelineVsSerial(bool useL2Pooling) async {
      final vg = vggGpu;
      if (vg == null) return;
      final l2 = useL2Pooling;
      final x0 = lpipsInput(busyFrame(64, 48), 64, 48);
      final x1 = lpipsInput(busyFrame(64, 48, noisy: true), 64, 48);
      final d0 = await vg.forward(x0, useL2Pooling: l2);
      final d1 = await vg.forward(x1, useL2Pooling: l2);
      final h0 = await vg.forwardSubmit(x0, useL2Pooling: l2);
      final h1 = await vg.forwardSubmit(x1, useL2Pooling: l2);
      final p0 = await vg.forwardDownload(h0);
      final p1 = await vg.forwardDownload(h1);
      for (final (pipe, direct) in [(p0, d0), (p1, d1)]) {
        expect(pipe.length, direct.length);
        for (var k = 0; k < direct.length; k++) {
          expect(pipe[k].shape, direct[k].shape);
          var mismatch = 0;
          for (var i = 0; i < direct[k].numel; i++) {
            if (pipe[k].data[i] != direct[k].data[i]) mismatch++;
          }
          expect(mismatch, 0, reason: 'slice$k l2=$l2');
        }
      }
    }

    test('两阶段流水线与串行 forward 逐位一致（优化 11，maxpool 变体）',
        () => checkPipelineVsSerial(false),
        timeout: const Timeout(Duration(minutes: 10)));
    test('两阶段流水线与串行 forward 逐位一致（优化 11，L2pooling 变体）',
        () => checkPipelineVsSerial(true),
        timeout: const Timeout(Duration(minutes: 10)));

    test('超大输入整链回退（抛 UnsupportedError）', () async {
      final vg = vggGpu;
      if (vg == null) return;
      // 40000 宽：conv1_1 输出即使按带高 16 切分也超出单带预算
      // （2*16*40000*18 > 2^23）→ 分块预检拒绝，上传前抛错。
      expect(() => vg.forward(NnTensor.zeros([1, 3, 64, 40000])),
          throwsA(isA<UnsupportedError>()));
    });

    test('分块规划：1024×768 / 1688×3000 可行，超宽不可行（默认预算）', () {
      // 旧上限：conv1_1 输出 2*16*H*W < 2^24 → 约 512×384。
      // 分块路径按 2^23/带 预算沿 H 切带，1024×768（4 带）与
      // 1688×3000（21 带）的 conv1_x（64ch）均可行。
      expect(GpuNnBackend.planBandHeights(768, 1024, 64), isNotNull);
      expect(GpuNnBackend.planBandHeights(3000, 1688, 64), isNotNull);
      expect(GpuNnBackend.planBandHeights(768, 1024, 64)!.length, 4);
      expect(GpuNnBackend.planBandHeights(3000, 1688, 64)!.length, 21);
      // W 过宽：带高 16 也放不下 → null（调用方回退 CPU）。
      expect(GpuNnBackend.planBandHeights(64, 40000, 64), isNull);
      // maxpool 奇偶：非末带奇高拒绝；末带高 1 输出空带丢弃。
      expect(GpuNnBackend.poolBandsMax([16, 16, 16, 1]), [8, 8, 8]);
      expect(GpuNnBackend.poolBandsMax([15, 16]), isNull);
      expect(GpuNnBackend.poolBandsL2([16, 1]), [8, 1]);
    });
  });

  group('端到端分数对拍（GPU 路径 vs Python 基线）', () {
    /// 调 iqa_bridge.py 一次性模式取参考分（同
    /// test/isp_lpips_dists_dart_test.dart）。
    Future<double> pyRef(String metric, String aPath, String bPath) async {
      final res = await Process.run(
          pyIqaPythonPath,
          [pyIqaBridgePath, '--metric', metric, '--a', aPath, '--b', bPath],
          workingDirectory: Directory.current.path);
      for (final line in const LineSplitter().convert(res.stdout as String)) {
        final t = line.trimLeft();
        if (!t.startsWith('{')) continue;
        final obj = jsonDecode(t) as Map<String, Object?>;
        if (obj['ok'] == true) {
          return (obj['score'] as num).toDouble();
        }
        throw StateError('桥接一次性模式失败（$metric）: $t');
      }
      throw StateError('桥接一次性模式无 JSON 应答（$metric）: '
          'exit=${res.exitCode} stdout=${res.stdout} stderr=${res.stderr}');
    }

    void record(String what, double gpuV, double pyV, double cpuV) {
      final relPy = (gpuV - pyV).abs() / pyV.abs();
      final relCpu = (gpuV - cpuV).abs() / cpuV.abs();
      // ignore: avoid_print
      print('$what: gpu=$gpuV python=$pyV cpu=$cpuV '
          'relErrVsPython=$relPy relErrVsCpu=$relCpu');
      expect(relPy, lessThanOrEqualTo(2e-2), reason: what);
    }

    test('LPIPS 64×48 busyFrame 对', () async {
      final vg = vggGpu;
      if (vg == null || !PyIqaWorker.available || !weightsExist()) return;
      const w = 64, h = 48;
      final a = busyFrame(w, h);
      final b = busyFrame(w, h, noisy: true);
      final aPath = await pyIqaWriteTempPng(a, w, h);
      final bPath = await pyIqaWriteTempPng(b, w, h);
      final pyV = await pyRef('lpips', aPath, bPath);
      final gpuV =
          await lpipsScoreParallel(a, b, w, h, vggForward: vg, workers: 4);
      final cpuV = await lpipsScoreParallel(a, b, w, h, workers: 4);
      record('LPIPS 64x48 GPU路径', gpuV, pyV, cpuV);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('DISTS 64×48 busyFrame 对', () async {
      final vg = vggGpu;
      if (vg == null || !PyIqaWorker.available || !weightsExist()) return;
      const w = 64, h = 48;
      final a = busyFrame(w, h);
      final b = busyFrame(w, h, noisy: true);
      final aPath = await pyIqaWriteTempPng(a, w, h);
      final bPath = await pyIqaWriteTempPng(b, w, h);
      final pyV = await pyRef('dists', aPath, bPath);
      final gpuV =
          await distsScoreParallel(a, b, w, h, vggForward: vg, workers: 4);
      final cpuV = await distsScoreParallel(a, b, w, h, workers: 4);
      record('DISTS 64x48 GPU路径', gpuV, pyV, cpuV);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('enabled=false 时静态开关关断 GPU 路径', () async {
      final vg = vggGpu;
      if (vg == null || !weightsExist()) return;
      const w = 64, h = 48;
      final a = busyFrame(w, h);
      final b = busyFrame(w, h, noisy: true);
      Vgg16AsyncForward.enabled = false;
      try {
        final v = await lpipsScoreParallel(a, b, w, h,
            vggForward: vg, workers: 4);
        expect(v, await lpipsScoreParallel(a, b, w, h, workers: 4));
      } finally {
        Vgg16AsyncForward.enabled = true;
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
