// 分解 FID 快/慢路径差异：a（均值项）、b（迹项）、c（特征值项）分别对比。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';

Float32List randFeats(int n, int dim, int seed, {double offset = 0}) {
  final rng = math.Random(seed);
  final out = Float32List(n * dim);
  for (var i = 0; i < out.length; i++) {
    out[i] = rng.nextDouble() + offset;
  }
  return out;
}

void main() {
  const dim = 64;
  const n = 12;
  final x = randFeats(n, dim, 42);
  final y = randFeats(n, dim, 43, offset: 0.3);

  final accX = FidAccumulator(dim)..addBatch(x, n);
  final accY = FidAccumulator(dim)..addBatch(y, n);
  final (mu1, s1) = accX.meanCov();
  final (mu2, s2) = accY.meanCov();

  // 慢路径 a/b。
  var aSlow = 0.0, bSlow = 0.0;
  for (var i = 0; i < dim; i++) {
    final d = mu1[i] - mu2[i];
    aSlow += d * d;
    bSlow += s1[i * dim + i] + s2[i * dim + i];
  }
  // 快路径 a/b（中心化直接算）。
  double trace(Float32List f) {
    final mu = List<double>.filled(dim, 0);
    for (var r = 0; r < n; r++) {
      for (var i = 0; i < dim; i++) {
        mu[i] += f[r * dim + i];
      }
    }
    var t = 0.0;
    for (var r = 0; r < n; r++) {
      for (var i = 0; i < dim; i++) {
        final v = f[r * dim + i] - mu[i] / n;
        t += v * v;
      }
    }
    return t / (n - 1);
  }

  final bFast = trace(x) + trace(y);

  // c：慢路径 64×64 特征值分解，观察小特征值的 Re(√λ) 贡献。
  final prod = Float64List(dim * dim);
  dgemmNn(s1, s2, prod, dim, dim, dim);
  final ev = eigvalsReal(prod, dim);
  var cAll = 0.0, cSmall = 0.0, cBig = 0.0;
  var nSmall = 0;
  final mags = ev.re.map((e) => e.abs()).toList()..sort();
  final maxMag = mags.last;
  for (var i = 0; i < dim; i++) {
    final re = ev.re[i], im = ev.im[i];
    final contrib = math.sqrt((math.sqrt(re * re + im * im) + re) / 2);
    cAll += contrib;
    if (re.abs() < maxMag * 1e-10) {
      cSmall += contrib;
      nSmall++;
    } else {
      cBig += contrib;
    }
  }
  final fast = fidScoreFromFeatures(x, n, y, n, dim: dim);
  final slow = fidCompute(accX, accY);
  print('max|λ| = $maxMag');
  print('小特征值个数（|λ| < max·1e-10）: $nSmall，其 Re(√λ) 贡献 = $cSmall');
  print('a 差 = ${(aSlow - (aSlow)).abs()}（同一实现，略）');
  print('b 差（xtx 口径 vs 中心化口径）= ${(bSlow - bFast).abs()}');
  print('fast=$fast slow=$slow 差=${(fast - slow).abs()}');
  print('cAll(慢) = $cAll，cBig = $cBig');
  print('推断：fast ≈ a+bSlow?−2·cBig → ${aSlow + bFast - 2 * cBig}');
  print('fast − (a+b−2·cBig) = ${fast - (aSlow + bFast - 2 * cBig)}');
}
