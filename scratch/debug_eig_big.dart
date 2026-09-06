import 'dart:math' as math;
import 'dart:typed_data';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';

void testCase(int n, int samples) {
  final rng = math.Random(0);
  final x = Float32List(samples * n);
  final y = Float32List(samples * n);
  for (var i = 0; i < x.length; i++) { x[i] = rng.nextDouble() * 2; y[i] = rng.nextDouble() * 2; }
  Float64List cov(Float32List f) {
    final mu = Float64List(n);
    for (var r = 0; r < samples; r++) for (var i = 0; i < n; i++) mu[i] += f[r * n + i];
    for (var i = 0; i < n; i++) mu[i] /= samples;
    final c = Float64List(n * n);
    for (var r = 0; r < samples; r++) {
      for (var i = 0; i < n; i++) {
        final di = f[r * n + i] - mu[i];
        for (var j = 0; j < n; j++) c[i * n + j] += di * (f[r * n + j] - mu[j]);
      }
    }
    for (var i = 0; i < c.length; i++) c[i] /= samples - 1;
    return c;
  }
  final s1 = cov(x), s2 = cov(y);
  final prod = Float64List(n * n);
  dgemmNn(s1, s2, prod, n, n, n);
  final sw = Stopwatch()..start();
  try {
    final ev = eigvalsReal(prod, n);
    var tr = 0.0, sr = 0.0, maxIm = 0.0;
    for (var i = 0; i < n; i++) { tr += prod[i*n+i]; sr += ev.re[i]; if (ev.im[i].abs() > maxIm) maxIm = ev.im[i].abs(); }
    print('n=$n: OK ${sw.elapsed} traceErr=${(tr-sr).abs().toStringAsExponential(2)} maxIm=${maxIm.toStringAsExponential(2)}');
  } catch (e) { print('n=$n: FAIL ${sw.elapsed} $e'); }
}

void main() {
  testCase(512, 10);
  testCase(1024, 10);
  testCase(2048, 10);
}
