import 'dart:io';
import 'dart:typed_data';

void main() {
  const n = 10, d = 2048;
  final ref = File('scratch/dart_ref_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final tst = File('scratch/dart_test_feats.f32').readAsBytesSync().buffer.asFloat32List();
  // 逐对对比：内联 gram vs 直接点积
  final g = Float64List(n * n);
  for (var i = 0; i < n; i++) {
    final xi = i * d;
    for (var j = 0; j < n; j++) {
      final yj = j * d;
      var s = 0.0;
      for (var k = 0; k < d; k++) {
        s += ref[xi + k] * tst[yj + k];
      }
      g[i * n + j] = s;
    }
  }
  var bad = 0;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      var dot = 0.0;
      for (var k = 0; k < d; k++) {
        dot += ref[i * d + k] * tst[j * d + k];
      }
      if ((g[i * n + j] - dot).abs() > 1e-6) {
        if (bad < 5) print('mismatch ($i,$j): gram=${g[i*n+j]} brute=$dot');
        bad++;
      }
    }
  }
  print('bad pairs: $bad / ${n * n}');
}
