/// 仪器并行链路的端到端基准：InstrumentAnalyzer 常驻 worker 池 +
/// 端口收发 + worker 侧渲染的完整往返耗时（模拟播放馈源尺寸）。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/instrument_worker.dart';

Uint8List makeFrame(int w, int h, int seed, {int noise = 24}) {
  final rnd = math.Random(seed);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      out[i] = (x * 255 ~/ w + rnd.nextInt(noise)) & 0xFF;
      out[i + 1] = (y * 255 ~/ h + rnd.nextInt(noise)) & 0xFF;
      out[i + 2] = ((x + y) * 128 ~/ (w + h) + rnd.nextInt(noise)) & 0xFF;
      out[i + 3] = 255;
    }
  }
  return out;
}

Future<void> main() async {
  final analyzer = InstrumentAnalyzer();
  // 波形馈源 ~480p（854x480），矢量馈源 ~240p（854x480）。
  final waveFrame = makeFrame(854, 480, 1);
  final vecFrame = makeFrame(427, 240, 2);
  final vecFrameMild = makeFrame(427, 240, 2, noise: 6);
  final vecFrameSmooth = makeFrame(427, 240, 2, noise: 1);

  Future<void> bench(String name, Future<Object?> Function() fn,
      {int warmup = 5, int iters = 30}) async {
    for (var i = 0; i < warmup; i++) {
      await fn();
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < iters; i++) {
      await fn();
    }
    sw.stop();
    print('$name: ${(sw.elapsedMicroseconds / iters / 1000).toStringAsFixed(2)} ms/帧');
  }

  await bench('waveform(仅Y, 854x480)', () => analyzer.analyzeDedicated(
      waveFrame, 854, 480, 'waveform', visible: {'y'}));
  await bench('waveform(RGB, 854x480)', () => analyzer.analyzeDedicated(
      waveFrame, 854, 480, 'waveform', visible: {'r', 'g', 'b'}));
  await bench('vectorscope(并行连线, 427x240, 强噪声)',
      () => analyzer.analyzeVectorscopeParallel(vecFrame, 427, 240));
  await bench('vectorscope(并行连线, 427x240, 轻噪声)',
      () => analyzer.analyzeVectorscopeParallel(vecFrameMild, 427, 240));
  await bench('vectorscope(并行连线, 427x240, 无噪声)',
      () => analyzer.analyzeVectorscopeParallel(vecFrameSmooth, 427, 240));
  await bench('vectorscope(连线单worker对照, 427x240, 无噪声)', () =>
      analyzer.analyzeDedicated(vecFrameSmooth, 427, 240, 'vectorscope'));
  await bench('histogram(单worker往返探针, 854x480)', () =>
      analyzer.analyzeDedicated(vecFrameSmooth, 427, 240, 'histogram'));
  await bench('waveformY + vectorscope 并发', () => Future.wait([
        analyzer.analyzeDedicated(waveFrame, 854, 480, 'waveform',
            visible: {'y'}),
        analyzer.analyzeVectorscopeParallel(vecFrame, 427, 240),
      ]));

  analyzer.dispose();
}
