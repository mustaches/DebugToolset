/// 仪器分析各阶段耗时基准：波形/矢量示波器在典型播放馈源尺寸下的
/// 分析、渲染耗时。JIT (dart run) 与 AOT (compile exe) 各跑一遍对比。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';

Uint8List makeFrame(int w, int h, int seed, {bool noise = true}) {
  final rnd = math.Random(seed);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final n = noise ? rnd.nextInt(24) : 0;
      out[i] = (x * 255 ~/ w + n) & 0xFF;
      out[i + 1] = (y * 255 ~/ h + n) & 0xFF;
      out[i + 2] = ((x + y) * 128 ~/ (w + h) + n) & 0xFF;
      out[i + 3] = 255;
    }
  }
  return out;
}

/// 修复版 vectorscope：int 分支钳制替代 num clamp，测试收益。
Uint32List vectorscopeFixed(Uint8List rgba) {
  final counts = Uint32List(kVectorscopeSize * kVectorscopeSize);
  var prevCb = -1;
  var prevCr = -1;
  for (var i = 0; i + 2 < rgba.length; i += 4) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    var cb = 256 + ((-43 * r - 85 * g + 128 * b + 64) >> 7);
    var cr = 256 + ((128 * r - 107 * g - 21 * b + 64) >> 7);
    if (cb < 0) {
      cb = 0;
    } else if (cb > 511) {
      cb = 511;
    }
    if (cr < 0) {
      cr = 0;
    } else if (cr > 511) {
      cr = 511;
    }
    // 与 _aaSegment 相同的内联快路径统计，仅为测上限。
    if (prevCb < 0 || ((cb - prevCb).abs() <= 1 && (cr - prevCr).abs() <= 1)) {
      counts[cr * kVectorscopeSize + cb] += 256;
    } else {
      counts[cr * kVectorscopeSize + cb] += 256; // 近似：慢路径也按一点计
    }
    prevCb = cb;
    prevCr = cr;
  }
  return counts;
}

void bench(String name, void Function() fn, {int warmup = 3, int iters = 20}) {
  for (var i = 0; i < warmup; i++) {
    fn();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    fn();
  }
  sw.stop();
  print('$name: ${(sw.elapsedMicroseconds / iters / 1000).toStringAsFixed(2)} ms');
}

void main() {
  for (final (w, h) in [(640, 360), (864, 480)]) {
    final frame = makeFrame(w, h, 42);
    final smooth = makeFrame(w, h, 42, noise: false);
    print('--- ${w}x$h ---');
    bench('waveformRgb(全4通道, 强噪声)', () => waveformRgb(frame, w, h));
    bench('waveformLuma(仅Y, 强噪声)', () => waveformLuma(frame, w, h));
    bench('waveformRgb(全4通道, 平滑)', () => waveformRgb(smooth, w, h));
    bench('waveformLuma(仅Y, 平滑)', () => waveformLuma(smooth, w, h));
    bench('vectorscope(含噪声)', () => vectorscope(frame));
    bench('vectorscope(平滑图)', () => vectorscope(smooth));
    bench('vectorscopeFixed(含噪声)', () => vectorscopeFixed(frame));
    bench('vectorscopeFixed(平滑图)', () => vectorscopeFixed(smooth));
    final (r, g, b, y, cols) = waveformRgb(frame, w, h);
    final result = {'r': r, 'g': g, 'b': b, 'y': y};
    bench('waveform渲染(Y)', () => waveformIntensityRgba(result, cols, 256, {'y'}));
    bench('waveform渲染(RGB)', () => waveformIntensityRgba(result, cols, 256, {'r', 'g', 'b'}));
    final counts = vectorscope(frame);
    bench('vectorscope渲染', () => intensityRgba(counts, 512, 512, 70, 235, 70));
  }
}
