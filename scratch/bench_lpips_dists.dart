// 临时基准：LPIPS/DISTS Dart 实现的耗时与自洽性检查（不进版本库维护）。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/dists_dart.dart';

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

Future<void> main() async {
  const w = 256, h = 192;
  final a = busyFrame(w, h);
  final b = busyFrame(w, h, noisy: true);

  var sw = Stopwatch()..start();
  final lp = lpipsScore(a, b, w, h);
  sw.stop();
  print('LPIPS  sync  = $lp  (${sw.elapsedMilliseconds} ms)');

  sw = Stopwatch()..start();
  final lpp = await lpipsScoreParallel(a, b, w, h);
  sw.stop();
  print('LPIPS  pool  = $lpp  (${sw.elapsedMilliseconds} ms)  diff=${(lpp - lp).abs()}');

  sw = Stopwatch()..start();
  final ds = distsScore(a, b, w, h);
  sw.stop();
  print('DISTS  sync  = $ds  (${sw.elapsedMilliseconds} ms)');

  sw = Stopwatch()..start();
  final dsp = await distsScoreParallel(a, b, w, h);
  sw.stop();
  print('DISTS  pool  = $dsp  (${sw.elapsedMilliseconds} ms)  diff=${(dsp - ds).abs()}');

  // 奇数尺寸（L2pooling 输出 floor((H+1)/2) 与 maxpool 不同）。
  const w2 = 301, h2 = 199;
  final a2 = busyFrame(w2, h2);
  final b2 = busyFrame(w2, h2, noisy: true);
  sw = Stopwatch()..start();
  final lp2 = await lpipsScoreParallel(a2, b2, w2, h2);
  final ds2 = await distsScoreParallel(a2, b2, w2, h2);
  sw.stop();
  print('301x199 pool: LPIPS=$lp2  DISTS=$ds2  (${sw.elapsedMilliseconds} ms)');

  // 自比对：应≈0。
  print('self: LPIPS=${lpipsScore(a, a, w, h)}  DISTS=${distsScore(a, a, w, h)}');
}
