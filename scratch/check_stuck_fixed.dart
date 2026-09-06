import 'dart:io';
import 'dart:math' as math;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';

void main() {
  const n = 2048;
  final a = File('scratch/eig_stuck.f64').readAsBytesSync().buffer.asFloat64List();
  final sw = Stopwatch()..start();
  final ev = eigvalsReal(a, n);
  print('eig 耗时 ${sw.elapsed}');
  var c = 0.0, maxIm = 0.0, tr = 0.0, sr = 0.0;
  for (var i = 0; i < n; i++) {
    tr += a[i * n + i];
    sr += ev.re[i];
    if (ev.im[i].abs() > maxIm) maxIm = ev.im[i].abs();
    final re = ev.re[i], im = ev.im[i];
    c += math.sqrt((math.sqrt(re * re + im * im) + re) / 2);
  }
  print('traceErr=${(tr - sr).abs().toStringAsExponential(2)} maxIm=${maxIm.toStringAsExponential(2)}');
  print('c (ΣRe√λ) = $c');
}
