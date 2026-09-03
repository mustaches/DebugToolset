/// 一般实矩阵（可非对称）特征值求解（纯 Dart，无 Flutter 依赖），fp64。
///
/// 流程：Householder 相似变换约化到上 Hessenberg 形，再做 Francis
/// 双移位 QR 迭代（EISPACK hqr / Numerical Recipes 口径：次对角
/// deflate 判据 `|a[l][l-1]| + s == s`，每 10/20 次迭代一次异常
/// shift，单特征值 30 次迭代不收敛抛错）。
///
/// 主要用途是 FID 的 tr((σ1σ2)^{1/2})：两半正定协方差之积 σ1σ2 为
/// 非对称实矩阵（特征值实非负），2048² 规模单次求解为分钟级。
///
/// 对拍黄金值：test/golden/eig_golden.json（tools/iqa/dump_golden.py
/// 用 numpy.linalg.eigvals 生成），测试见 test/isp_fid_kid_dart_test.dart。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// double 机器精度（2^-52）。
const double _eps = 2.220446049250313e-16;

/// fp64 分块 GEMM：C[M,N] = A[M,K] × B[K,N]（行主序，C 全覆盖写）。
/// 结构与 gemm.dart 的流式内核一致（A 行广播 × B 行顺序扫描）。
void dgemmNn(Float64List a, Float64List b, Float64List c, int m, int n, int k,
    {int blockM = 32, int blockN = 64, int blockK = 32}) {
  for (var i0 = 0; i0 < m; i0 += blockM) {
    final iEnd = math.min(i0 + blockM, m);
    for (var j0 = 0; j0 < n; j0 += blockN) {
      final jEnd = math.min(j0 + blockN, n);
      for (var i = i0; i < iEnd; i++) {
        var ci = i * n + j0;
        final ciEnd = i * n + jEnd;
        for (; ci < ciEnd; ci++) {
          c[ci] = 0.0;
        }
      }
      for (var k0 = 0; k0 < k; k0 += blockK) {
        final kEnd = math.min(k0 + blockK, k);
        for (var i = i0; i < iEnd; i++) {
          final aRow = i * k;
          final cRow = i * n;
          for (var kk = k0; kk < kEnd; kk++) {
            final aik = a[aRow + kk];
            var bi = kk * n + j0;
            var ci = cRow + j0;
            final ciEnd = cRow + jEnd;
            for (; ci < ciEnd; ci++, bi++) {
              c[ci] += aik * b[bi];
            }
          }
        }
      }
    }
  }
}

/// Householder 约化到上 Hessenberg 形（原地，[a] 被改写）。
/// 对每个 k：v = x + sign(x0)·‖x‖·e1（x 为第 k 列对角以下部分），
/// A ← H A H，H = I − τ v vᵀ，τ = 2/(vᵀv)。
void _toHessenberg(Float64List a, int n, Float64List v, Float64List s,
    Float64List t) {
  for (var k = 0; k < n - 2; k++) {
    final m = n - k - 1;
    var sigma = 0.0;
    for (var i = 0; i < m; i++) {
      final x = a[(k + 1 + i) * n + k];
      sigma += x * x;
    }
    sigma = math.sqrt(sigma);
    if (sigma == 0.0) {
      continue;
    }
    final x0 = a[(k + 1) * n + k];
    v[0] = x0 + (x0 >= 0 ? sigma : -sigma);
    for (var i = 1; i < m; i++) {
      v[i] = a[(k + 1 + i) * n + k];
    }
    var vv = 0.0;
    for (var i = 0; i < m; i++) {
      vv += v[i] * v[i];
    }
    final tau = 2.0 / vv;
    // 左乘 H：A[k+1:, k:] -= τ·v·(vᵀA)。s[j] = Σ_i v[i]·a[k+1+i][j]，
    // 行序累加（cache 友好）。
    for (var j = k; j < n; j++) {
      s[j] = 0.0;
    }
    for (var i = 0; i < m; i++) {
      final row = (k + 1 + i) * n;
      final vi = v[i];
      for (var j = k; j < n; j++) {
        s[j] += vi * a[row + j];
      }
    }
    for (var i = 0; i < m; i++) {
      final row = (k + 1 + i) * n;
      final tvi = tau * v[i];
      for (var j = k; j < n; j++) {
        a[row + j] -= tvi * s[j];
      }
    }
    // 右乘 H：A[:, k+1:] -= τ·(A v)·vᵀ。
    for (var i = 0; i < n; i++) {
      final row = i * n + k + 1;
      var sum = 0.0;
      for (var j = 0; j < m; j++) {
        sum += a[row + j] * v[j];
      }
      t[i] = sum;
    }
    for (var i = 0; i < n; i++) {
      final row = i * n + k + 1;
      final tti = tau * t[i];
      for (var j = 0; j < m; j++) {
        a[row + j] -= tti * v[j];
      }
    }
    // H x = −sign(x0)·σ·e1。
    a[(k + 1) * n + k] = x0 >= 0 ? -sigma : sigma;
    for (var i = k + 2; i < n; i++) {
      a[i * n + k] = 0.0;
    }
  }
}

/// Francis 双移位 QR（特征值版，不求特征向量）。输入上 Hessenberg
/// 矩阵 [a]（原地改写），特征值写入 [wr]/[wi]（实部/虚部）。
void _hqr(Float64List a, int n, Float64List wr, Float64List wi) {
  var anorm = 0.0;
  for (var i = 0; i < n; i++) {
    final j0 = i > 0 ? i - 1 : 0;
    for (var j = j0; j < n; j++) {
      anorm += a[i * n + j].abs();
    }
  }
  var nn = n - 1;
  var t = 0.0;
  // 绝对 deflate 下限：次对角元低于 eps·anorm 时继续迭代的收益已在
  // 舍入噪声内（对深度秩亏矩阵——如 FID 小样本的 σ1σ2，零特征值
  // 区域整体向 0 二次塌缩、局部相对判据永不触发——必不可少）。
  final absFloor = _eps * anorm;
  while (nn >= 0) {
    var its = 0;
    int l;
    double x, y, w;
    for (;;) {
      // 找可忽略的单个次对角元（deflate 判据：局部相对 + 全局绝对）。
      for (l = nn; l >= 1; l--) {
        var sc = a[(l - 1) * n + l - 1].abs() + a[l * n + l].abs();
        if (sc == 0.0) {
          sc = anorm;
        }
        final sub = a[l * n + l - 1].abs();
        if (sub + sc == sc || sub <= absFloor) {
          a[l * n + l - 1] = 0.0;
          break;
        }
      }
      x = a[nn * n + nn];
      if (l == nn) {
        // 1×1：一个实特征值。
        wr[nn] = x + t;
        wi[nn] = 0.0;
        nn--;
        break;
      }
      y = a[(nn - 1) * n + nn - 1];
      w = a[nn * n + nn - 1] * a[(nn - 1) * n + nn];
      if (l == nn - 1) {
        // 2×2：一对特征值。
        final p = 0.5 * (y - x);
        final q = p * p + w;
        var z = math.sqrt(q.abs());
        x += t;
        if (q >= 0.0) {
          z = p + (p >= 0 ? z : -z);
          wr[nn - 1] = x + z;
          wr[nn] = x + z;
          if (z != 0.0) {
            wr[nn] = x - w / z;
          }
          wi[nn - 1] = wi[nn] = 0.0;
        } else {
          wr[nn - 1] = x + p;
          wr[nn] = x + p;
          wi[nn - 1] = z;
          wi[nn] = -z;
        }
        nn -= 2;
        break;
      }
      if (its == 60) {
        throw StateError('eigvalsReal: QR 迭代 60 次未 deflate'
            '（剩余窗口 $nn）');
      }
      if (its % 10 == 0) {
        // 异常 shift：打破罕见的不收敛循环。
        t += x;
        for (var i = 0; i <= nn; i++) {
          a[i * n + i] -= x;
        }
        final sc =
            a[nn * n + nn - 1].abs() + a[(nn - 1) * n + nn - 2].abs();
        y = 0.75 * sc;
        x = 0.75 * sc;
        w = -0.4375 * sc * sc;
      }
      its++;
      // 双移位 QR 步的起始行 m（允许连续两个小次对角元）。
      int m;
      var p = 0.0, q = 0.0, r = 0.0;
      for (m = nn - 2; m >= l; m--) {
        final z = a[m * n + m];
        final rr0 = x - z;
        final ss0 = y - z;
        p = (rr0 * ss0 - w) / a[(m + 1) * n + m] + a[m * n + m + 1];
        q = a[(m + 1) * n + m + 1] - z - rr0 - ss0;
        r = a[(m + 2) * n + m + 1];
        final sc = p.abs() + q.abs() + r.abs();
        p /= sc;
        q /= sc;
        r /= sc;
        if (m == l) {
          break;
        }
        final u = a[m * n + m - 1].abs() * (q.abs() + r.abs());
        final v = p.abs() *
            (a[(m - 1) * n + m - 1].abs() +
                z.abs() +
                a[(m + 1) * n + m + 1].abs());
        if (u + v == v) {
          break;
        }
      }
      for (var i = m + 2; i <= nn; i++) {
        a[i * n + i - 2] = 0.0;
        if (i != m + 2) {
          a[i * n + i - 3] = 0.0;
        }
      }
      // bulge chase：对 k = m..nn-1 做 3×3 Householder 相似变换。
      for (var k = m; k <= nn - 1; k++) {
        var xn = 0.0;
        if (k != m) {
          p = a[k * n + k - 1];
          q = a[(k + 1) * n + k - 1];
          r = k != nn - 1 ? a[(k + 2) * n + k - 1] : 0.0;
          xn = p.abs() + q.abs() + r.abs();
          if (xn != 0.0) {
            p /= xn;
            q /= xn;
            r /= xn;
          }
        }
        var s = math.sqrt(p * p + q * q + r * r);
        if (p < 0) {
          s = -s;
        }
        if (s == 0.0) {
          continue;
        }
        if (k == m) {
          if (l != m) {
            a[k * n + k - 1] = -a[k * n + k - 1];
          }
        } else {
          a[k * n + k - 1] = -s * xn;
        }
        p += s;
        final xs = p / s, ys = q / s, zs = r / s;
        final qs = q / p, rs = r / p;
        // 行变换（左乘 H）。
        for (var j = k; j <= nn; j++) {
          var pj = a[k * n + j] + qs * a[(k + 1) * n + j];
          if (k != nn - 1) {
            pj += rs * a[(k + 2) * n + j];
            a[(k + 2) * n + j] -= pj * zs;
          }
          a[(k + 1) * n + j] -= pj * ys;
          a[k * n + j] -= pj * xs;
        }
        // 列变换（右乘 H）。
        final mmin = math.min(nn, k + 3);
        for (var i = l; i <= mmin; i++) {
          var pi = xs * a[i * n + k] + ys * a[i * n + k + 1];
          if (k != nn - 1) {
            pi += zs * a[i * n + k + 2];
            a[i * n + k + 2] -= pi * rs;
          }
          a[i * n + k + 1] -= pi * qs;
          a[i * n + k] -= pi;
        }
      }
    }
  }
}

/// 求实方阵 [a]（[n]×[n]，行主序）的全部特征值，返回 (实部, 虚部)。
/// 输入不被修改。时间为 O(n³)，2048² 约分钟级。
({Float64List re, Float64List im}) eigvalsReal(Float64List a, int n) {
  if (n < 1 || a.length != n * n) {
    throw ArgumentError('eigvalsReal: 需要 n×n 方阵（n=$n, '
        '长度 ${a.length}）');
  }
  final h = Float64List.fromList(a);
  final wr = Float64List(n);
  final wi = Float64List(n);
  if (n == 1) {
    wr[0] = h[0];
    return (re: wr, im: wi);
  }
  _toHessenberg(h, n, Float64List(n), Float64List(n), Float64List(n));
  _hqr(h, n, wr, wi);
  return (re: wr, im: wi);
}
