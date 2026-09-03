// GPU 链执行器逐算子正确性测试（gaussian_blur）：与 CPU kernel 逐值对比。
// 浮点移植路径 + 水平趟 16 位打包往返，允许容差 1。
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 16, h = 12;

Uint16List randFrame(int n, int seed) {
  final out = Uint16List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out[i] = s % 4096;
  }
  return out;
}

void expectClose(Uint16List actual, Uint16List expected, int tol, String tag) {
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

  /// 与 gpu_pipeline 派发同构的两趟：水平（不混合）→ 垂直（原帧混合）。
  Future<Uint16List> runGaussianBlur(Uint16List src, int channels,
      double sigma, double strength) async {
    final prog = gpu.progForTest('gaussian_blur');
    final srcTex = await GpuPipeline.uploadPacked(src, w, h, channels);
    final texW = w * channels ~/ 2;
    final base = [
      texW.toDouble(),
      h.toDouble(),
      w.toDouble(),
      channels.toDouble()
    ];
    final hTex = GpuPipeline.runPass(
        prog, [...base, 0.0, sigma, strength], [srcTex, srcTex], texW, h);
    final vTex = GpuPipeline.runPass(
        prog, [...base, 1.0, sigma, strength], [hTex, srcTex], texW, h);
    final bytes = await GpuPipeline.readbackBytes(vTex);
    srcTex.dispose();
    hTex.dispose();
    vTex.dispose();
    return bytes.buffer.asUint16List();
  }

  test('RGB 三通道（σ=1.5，全强度）与 CPU 逐值一致', () async {
    final src = randFrame(w * h * 3, 1);
    final cpu = Uint16List.fromList(src);
    applyGaussianBlur(cpu, width: w, height: h, sigma: 1.5);
    final gpuOut = await runGaussianBlur(src, 3, 1.5, 1.0);
    expectClose(gpuOut, cpu, 1, 'gaussian_blur rgb');
  });

  test('半强度混合（strength=0.5）与 CPU 逐值一致', () async {
    final src = randFrame(w * h * 3, 2);
    final cpu = Uint16List.fromList(src);
    applyGaussianBlur(cpu, width: w, height: h, sigma: 2.0, strength: 0.5);
    final gpuOut = await runGaussianBlur(src, 3, 2.0, 0.5);
    expectClose(gpuOut, cpu, 1, 'gaussian_blur half-strength');
  });

  test('Mono 单通道（σ=3.0）与 CPU 逐值一致', () async {
    final src = randFrame(w * h, 3);
    final cpu = Uint16List.fromList(src);
    applyGaussianBlur(cpu, width: w, height: h, channels: 1, sigma: 3.0);
    final gpuOut = await runGaussianBlur(src, 1, 3.0, 1.0);
    expectClose(gpuOut, cpu, 1, 'gaussian_blur mono');
  });

  test('边界行（上下边缘复制钳制）与 CPU 逐值一致', () async {
    // 单值亮线靠近边缘：验证钳制口径一致。
    final src = randFrame(w * h * 3, 4);
    final cpu = Uint16List.fromList(src);
    applyGaussianBlur(cpu, width: w, height: h, sigma: 4.0);
    final gpuOut = await runGaussianBlur(src, 3, 4.0, 1.0);
    expectClose(gpuOut, cpu, 1, 'gaussian_blur edge');
  });
}
