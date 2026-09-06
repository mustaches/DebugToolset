// 调试：秩亏 PSD 协方差积（FID 出分场景）上 eigvalsReal 的收敛性。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';

void testCase(int n, int samples, int seed) {
  final rng = math.Random(seed);
  Float32List feats(int count) {
    final f = Float32List(count * n);
    for (var i = 0; i < f.length; i++) {
      f[i] = rng.nextDouble() * 2;
    }
    return f;
  }

  Float64List cov(Float32List x, int count) {
    final mu = Float64List(n);
    for (var r = 0; r < count; r++) {
      for (var i = 0; i < n; i++) {
        mu[i] += x[r * n + i];
      }
    }
    for (var i = 0; i < n; i++) {
      mu[i] /= count;
    }
    final c = Float64List(n * n);
    for (var r = 0; r < count; r++) {
      for (var i = 0; i < n; i++) {
        final di = x[r * n + i] - mu[i];
        for (var j = 0; j < n; j++) {
          c[i * n + j] += di * (x[r * n + j] - mu[j]);
        }
      }
    }
    for (var i = 0; i < c.length; i++) {
      c[i] /= count - 1;
    }
    return c;
  }

  final s1 = cov(feats(samples), samples);
  final s2 = cov(feats(samples), samples);
  final prod = Float64List(n * n);
  dgemmNn(s1, s2, prod, n, n, n);
  final sw = Stopwatch()..start();
  try {
    final ev = eigvalsReal(prod, n);
    var tr = 0.0, sr = 0.0, maxIm = 0.0;
    for (var i = 0; i < n; i++) {
      tr += prod[i * n + i];
      sr += ev.re[i];
      if (ev.im[i].abs() > maxIm) {
        maxIm = ev.im[i].abs();
      }
    }
    print('n=$n samples=$samples: OK ${sw.elapsed} '
        'traceErr=${(tr - sr).abs().toStringAsExponential(2)} '
        'maxIm=${maxIm.toStringAsExponential(2)}');
  } catch (e) {
    print('n=$n samples=$samples: FAIL ${sw.elapsed} $e');
  }
}

void main() {
  for (final n in [32, 64, 128, 256]) {
    testCase(n, 10, 0);
  }
  testCase(64, 70, 1); // 样本数 > n/2 但 < n
  testCase(128, 200, 2); // 满秩附近
}
