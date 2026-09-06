import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

Float64List gramSelf(Float32List x, int n, int dim) {
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

void main() { main2(); return;
  const n = 10, d = 2048;
  final ref = File('scratch/dart_ref_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final tst = File('scratch/dart_test_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final gxx = gramSelf(ref, n, d);
  final gyy = gramSelf(tst, n, d);

  double k(double dot) {
    final v = dot / 2048 + 1.0;
    return v * v * v;
  }

  var kxx = 0.0, kyy = 0.0;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (i != j) {
        kxx += k(gxx[i * n + j]);
        kyy += k(gyy[i * n + j]);
      }
    }
  }
  print('kxx=$kxx kyy=$kyy');
  // brute 对照
  var bxx = 0.0, byy = 0.0;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (i == j) continue;
      var dx = 0.0, dy = 0.0;
      for (var kk = 0; kk < d; kk++) {
        dx += ref[i * d + kk] * ref[j * d + kk];
        dy += tst[i * d + kk] * tst[j * d + kk];
      }
      bxx += k(dx);
      byy += k(dy);
    }
  }
  print('bxx=$bxx byy=$byy');
}

// 追加：验证 gramCross
void main2() {
  const n = 10, d = 2048;
  final ref = File('scratch/dart_ref_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final tst = File('scratch/dart_test_feats.f32').readAsBytesSync().buffer.asFloat32List();
  // _gramCross 同款
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
  double k(double dot) { final v = dot / 2048 + 1.0; return v * v * v; }
  var kg = 0.0, kb = 0.0;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      kg += k(g[i * n + j]);
      var dot = 0.0;
      for (var kk = 0; kk < d; kk++) {
        dot += ref[i * d + kk] * tst[j * d + kk];
      }
      kb += k(dot);
    }
  }
  print('kxy gram=$kg brute=$kb');
}
