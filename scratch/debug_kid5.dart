import 'dart:io';
import 'dart:typed_data';

Float64List gramCross(Float32List x, int n1, Float32List y, int n2, int dim) {
  final g = Float64List(n1 * n2);
  for (var i = 0; i < n1; i++) {
    final xi = i * dim;
    for (var j = 0; j < n2; j++) {
      final yj = j * dim;
      var s = 0.0;
      for (var k = 0; k < dim; k++) {
        s += x[xi + k] * x[yj + k];
      }
      g[i * n2 + j] = s;
    }
  }
  return g;
}

void main() {
  const n = 10, d = 2048;
  final ref = File('scratch/dart_ref_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final tst = File('scratch/dart_test_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final g = gramCross(ref, n, tst, n, d);
  double k(double dot) { final v = dot / 2048 + 1.0; return v * v * v; }
  var s = 0.0;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      s += k(g[i * n + j]);
    }
  }
  print('kxy via gramCross = $s');
  print('g[85]=${g[85]}');
  var dot = 0.0;
  for (var kk = 0; kk < d; kk++) {
    dot += ref[8 * d + kk] * tst[5 * d + kk];
  }
  print('brute dot(8,5)=$dot');
}
