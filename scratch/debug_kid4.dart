import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void main() {
  const n = 10, d = 2048;
  final ref = File('scratch/dart_ref_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final tst = File('scratch/dart_test_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final g = Float64List(n * n);
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      var s = 0.0;
      for (var k = 0; k < d; k++) {
        s += ref[i * d + k] * tst[j * d + k];
      }
      g[i * n + j] = s;
    }
  }
  double k(double dot) { final v = dot / 2048 + 1.0; return v * v * v; }

  final rng = math.Random(0);
  List<int> sample(int nn, int m) {
    final idx = List<int>.generate(nn, (i) => i);
    for (var i = nn - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final t = idx[i]; idx[i] = idx[j]; idx[j] = t;
    }
    return idx.sublist(0, m);
  }

  final idxR = sample(10, 10);
  final idxT = sample(10, 10);
  print('idxR=$idxR');
  print('idxT=$idxT');
  var kxyIdx = 0.0, kxyAll = 0.0;
  for (var i = 0; i < 10; i++) {
    for (var j = 0; j < 10; j++) {
      kxyIdx += k(g[idxR[i] * 10 + idxT[j]]);
      kxyAll += k(g[i * 10 + j]);
    }
  }
  print('kxyIdx=$kxyIdx kxyAll=$kxyAll');
}
