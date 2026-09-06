// kidCompute 的逐字复制 + 打印
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int fidFeatureDim = 2048;

Float64List _gramSelf(Float32List x, int n, int dim) {
  final g = Float64List(n * n);
  for (var i = 0; i < n; i++) {
    final xi = i * dim;
    for (var j = i; j < n; j++) {
      final xj = j * dim;
      var s = 0.0;
      for (var k = 0; k < dim; k++) {
        s += x[xi + k] * x[xj + k];
      }
      g[i * n + j] = s;
      g[j * n + i] = s;
    }
  }
  return g;
}

Float64List _gramCross(Float32List x, int n1, Float32List y, int n2, int dim) {
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

double _polyK(double dot) {
  final v = dot / fidFeatureDim + 1.0;
  return v * v * v;
}

List<int> _sampleSubset(math.Random rng, int n, int m) {
  final idx = List<int>.generate(n, (i) => i);
  for (var i = n - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = idx[i];
    idx[i] = idx[j];
    idx[j] = tmp;
  }
  return idx.sublist(0, m);
}

double kidComputeDbg(Float32List refFeatures, int nRef, Float32List testFeatures, int nTest,
    {int seed = 0}) {
  const dim = fidFeatureDim;
  final m = math.min(1000, math.min(nRef, nTest));
  final subsets = m >= 50 ? 50 : 10;
  final gxx = _gramSelf(refFeatures, nRef, dim);
  final gyy = _gramSelf(testFeatures, nTest, dim);
  final gxy = _gramCross(refFeatures, nRef, testFeatures, nTest, dim);
  final rng = math.Random(seed);
  var total = 0.0;
  final mm1 = m * (m - 1);
  final mm = m * m;
  for (var s = 0; s < subsets; s++) {
    final idxR = _sampleSubset(rng, nRef, m);
    final idxT = _sampleSubset(rng, nTest, m);
    var kxx = 0.0, kyy = 0.0, kxy = 0.0;
    for (var i = 0; i < m; i++) {
      final ri = idxR[i], ti = idxT[i];
      final gxRow = ri * nRef, gyRow = ti * nTest, gxyRow = ri * nTest;
      for (var j = 0; j < m; j++) {
        if (i != j) {
          kxx += _polyK(gxx[gxRow + idxR[j]]);
          kyy += _polyK(gyy[gyRow + idxT[j]]);
        }
        kxy += _polyK(gxy[gxyRow + idxT[j]]);
      }
    }
    if (s == 0) {
      print('idxR=$idxR');
      print('idxT=$idxT');
      var raw = 0.0;
      for (var ii = 0; ii < 10; ii++) {
        for (var jj = 0; jj < 10; jj++) {
          raw += _polyK(gxy[idxR[ii] * 10 + idxT[jj]]);
        }
      }
      print('subset0: kxx=$kxx kyy=$kyy kxy=$kxy rawRecompute=$raw');
    }
    total += (kxx + kyy) / mm1 - 2 * kxy / mm;
  }
  return total / subsets;
}

void main() {
  const n = 10;
  final ref = File('scratch/dart_ref_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final tst = File('scratch/dart_test_feats.f32').readAsBytesSync().buffer.asFloat32List();
  print('kidDbg = ${kidComputeDbg(ref, n, tst, n)}');
}
