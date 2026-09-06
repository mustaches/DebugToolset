// 一次性验证 nn/eig.dart：小矩阵已知特征值 + 随机矩阵残差检验。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';

void main() {
  // 2x2：[[0,1],[-2,-3]] → -1, -2
  var r = eigvalsReal(Float64List.fromList([0, 1, -2, -3]), 2);
  print('case1 re=${r.re} im=${r.im}');
  // 旋转 [[0,-1],[1,0]] → ±i
  r = eigvalsReal(Float64List.fromList([0, -1, 1, 0]), 2);
  print('case2 re=${r.re} im=${r.im}');
  // 上三角：对角即特征值
  r = eigvalsReal(Float64List.fromList([1, 2, 3, 0, 4, 5, 0, 0, 6]), 3);
  print('case3 re=${r.re}');

  // 随机非对称矩阵：残差 ||Av - λv|| 检验（用逆幂迭代求特征向量太麻烦，
  // 改用特征多项式之外的不变量：trace(A) = Σλ，trace(A²) = Σλ²，
  // trace(A³) = Σλ³，det 用 Πλ 检验）。
  final rng = math.Random(42);
  for (final n in [4, 8, 16, 33]) {
    final a = Float64List(n * n);
    for (var i = 0; i < a.length; i++) {
      a[i] = rng.nextDouble() * 4 - 2;
    }
    final ev = eigvalsReal(a, n);
    double s1 = 0, s2 = 0, s3 = 0;
    for (var i = 0; i < n; i++) {
      final re = ev.re[i], im = ev.im[i];
      s1 += re;
      // λ² 实部
      s2 += re * re - im * im;
      s3 += re * re * re - 3 * re * im * im;
    }
    double t1 = 0;
    for (var i = 0; i < n; i++) {
      t1 += a[i * n + i];
    }
    final a2 = Float64List(n * n);
    dgemmNn(a, a, a2, n, n, n);
    double t2 = 0;
    for (var i = 0; i < n; i++) {
      t2 += a2[i * n + i];
    }
    final a3 = Float64List(n * n);
    dgemmNn(a2, a3.isEmpty ? a2 : a2, a3, n, n, n); // a3 = a2*a2? no
    // 修正：a3 = a2 * a
    dgemmNn(a2, a, a3, n, n, n);
    double t3 = 0;
    for (var i = 0; i < n; i++) {
      t3 += a3[i * n + i];
    }
    print('n=$n  trA=${t1.toStringAsExponential(3)} sumλ=${s1.toStringAsExponential(3)}'
        ' err1=${(s1 - t1).abs().toStringAsExponential(2)}'
        ' err2=${(s2 - t2).abs().toStringAsExponential(2)}'
        ' err3=${(s3 - t3).abs().toStringAsExponential(2)}');
  }

  // 半正定积（FID 口径）：σ1σ2，特征值应实非负。
  const n = 16;
  final rng2 = math.Random(7);
  Float64List randCov() {
    final x = Float64List(8 * n);
    for (var i = 0; i < x.length; i++) {
      x[i] = rng2.nextDouble() * 2 - 1;
    }
    final xx = Float64List(n * n);
    dgemmNn(Float64List(n * 8), x, Float64List(0), 0, 0, 0); // noop
    // xx = XᵀX / 7 + 0.1 I
    final out = Float64List(n * n);
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        var s = 0.0;
        for (var k = 0; k < 8; k++) {
          s += x[k * n + i] * x[k * n + j];
        }
        out[i * n + j] = s / 7 + (i == j ? 0.1 : 0.0);
      }
    }
    return out;
  }

  final s1m = randCov(), s2m = randCov();
  final prod = Float64List(n * n);
  dgemmNn(s1m, s2m, prod, n, n, n);
  final ev = eigvalsReal(prod, n);
  var maxIm = 0.0, minRe = double.infinity;
  for (var i = 0; i < n; i++) {
    if (ev.im[i].abs() > maxIm) maxIm = ev.im[i].abs();
    if (ev.re[i] < minRe) minRe = ev.re[i];
  }
  print('psd_prod: maxIm=${maxIm.toStringAsExponential(2)} '
      'minRe=${minRe.toStringAsExponential(3)}');

  // 2048 规模耗时（随机对称积，模拟 FID 规模）。
  const big = 2048;
  print('生成 ${big}² 随机矩阵…');
  final sw = Stopwatch()..start();
  final bm = Float64List(big * big);
  final rb = math.Random(1);
  for (var i = 0; i < big; i++) {
    for (var j = i; j < big; j++) {
      final v = rb.nextDouble();
      bm[i * big + j] = v;
      bm[j * big + i] = v;
    }
  }
  print('生成耗时 ${sw.elapsed}');
  sw.reset();
  final evBig = eigvalsReal(bm, big);
  print('eig $big 耗时 ${sw.elapsed}');
  double tr = 0, sr = 0;
  for (var i = 0; i < big; i++) {
    tr += bm[i * big + i];
    sr += evBig.re[i];
  }
  print('trace 不变量误差 ${(tr - sr).abs().toStringAsExponential(2)}');
}
