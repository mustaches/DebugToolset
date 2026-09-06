import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';

void main() {
  const n = 10, d = 2048;
  final ref = File('scratch/dart_ref_feats.f32').readAsBytesSync().buffer.asFloat32List();
  final tst = File('scratch/dart_test_feats.f32').readAsBytesSync().buffer.asFloat32List();

  double K(Float32List a, int ia, Float32List b, int ib) {
    var dot = 0.0;
    for (var k = 0; k < d; k++) {
      dot += a[ia * d + k] * b[ib * d + k];
    }
    final v = dot / d + 1.0;
    return v * v * v;
  }

  var kxx = 0.0, kyy = 0.0, kxy = 0.0;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (i != j) {
        kxx += K(ref, i, ref, j);
        kyy += K(tst, i, tst, j);
      }
      kxy += K(ref, i, tst, j);
    }
  }
  final brute = (kxx + kyy) / (n * (n - 1)) - 2 * kxy / (n * n);
  print('brute force MMD = $brute');
  print('kidCompute      = ${kidCompute(ref, n, tst, n)}');
}
