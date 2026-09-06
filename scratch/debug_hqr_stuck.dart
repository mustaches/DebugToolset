// 调试：对 scratch/eig_stuck.f64（真实 σ1σ2，2048²）跑插桩版
// Hessenberg + Francis QR，打印每次 deflate 的迭代数与窗口变化，
// 定位 30 次不收敛的原因。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void main() {
  const n = 2048;
  final bytes = File('scratch/eig_stuck.f64').readAsBytesSync();
  final a = bytes.buffer.asFloat64List();
  print('矩阵范数信息：maxAbs=${a.map((v) => v.abs()).reduce(math.max)}');

  // ---- Hessenberg（与 nn/eig.dart 相同的实现，复制以便插桩）----
  final sw = Stopwatch()..start();
  final v = Float64List(n), sv = Float64List(n), tv = Float64List(n);
  for (var k = 0; k < n - 2; k++) {
    final m = n - k - 1;
    var sigma = 0.0;
    for (var i = 0; i < m; i++) {
      final x = a[(k + 1 + i) * n + k];
      sigma += x * x;
    }
    sigma = math.sqrt(sigma);
    if (sigma == 0.0) continue;
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
    for (var j = k; j < n; j++) {
      sv[j] = 0.0;
    }
    for (var i = 0; i < m; i++) {
      final row = (k + 1 + i) * n;
      final vi = v[i];
      for (var j = k; j < n; j++) {
        sv[j] += vi * a[row + j];
      }
    }
    for (var i = 0; i < m; i++) {
      final row = (k + 1 + i) * n;
      final tvi = tau * v[i];
      for (var j = k; j < n; j++) {
        a[row + j] -= tvi * sv[j];
      }
    }
    for (var i = 0; i < n; i++) {
      final row = i * n + k + 1;
      var sum = 0.0;
      for (var j = 0; j < m; j++) {
        sum += a[row + j] * v[j];
      }
      tv[i] = sum;
    }
    for (var i = 0; i < n; i++) {
      final row = i * n + k + 1;
      final tti = tau * tv[i];
      for (var j = 0; j < m; j++) {
        a[row + j] -= tti * v[j];
      }
    }
    a[(k + 1) * n + k] = x0 >= 0 ? -sigma : sigma;
    for (var i = k + 2; i < n; i++) {
      a[i * n + k] = 0.0;
    }
  }
  print('Hessenberg 耗时 ${sw.elapsed}');
  var maxSub = 0.0;
  for (var i = 1; i < n; i++) {
    if (a[i * n + i - 1].abs() > maxSub) maxSub = a[i * n + i - 1].abs();
  }
  print('Hessenberg 次对角 maxAbs=$maxSub, 对角范围: '
      'min=${List.generate(n, (i) => a[i * n + i]).reduce(math.min)} '
      'max=${List.generate(n, (i) => a[i * n + i]).reduce(math.max)}');

  // ---- 插桩 hqr ----
  var anorm = 0.0;
  for (var i = 0; i < n; i++) {
    final j0 = i > 0 ? i - 1 : 0;
    for (var j = j0; j < n; j++) {
      anorm += a[i * n + j].abs();
    }
  }
  print('anorm=$anorm');
  var nn = n - 1;
  var t = 0.0;
  var totalIts = 0;
  final wr = Float64List(n), wi = Float64List(n);
  sw.reset();
  while (nn >= 0) {
    var its = 0;
    int l;
    double x, y, w;
    for (;;) {
      for (l = nn; l >= 1; l--) {
        var sc = a[(l - 1) * n + l - 1].abs() + a[l * n + l].abs();
        if (sc == 0.0) sc = anorm;
        if (a[l * n + l - 1].abs() + sc == sc) {
          a[l * n + l - 1] = 0.0;
          break;
        }
      }
      x = a[nn * n + nn];
      if (l == nn) {
        wr[nn] = x + t;
        wi[nn] = 0.0;
        if (its > 4 || nn > n - 5 || nn % 100 == 0) {
          print('deflate 1x1 nn=$nn its=$its λ=${x + t}');
        }
        nn--;
        break;
      }
      y = a[(nn - 1) * n + nn - 1];
      w = a[nn * n + nn - 1] * a[(nn - 1) * n + nn];
      if (l == nn - 1) {
        final p = 0.5 * (y - x);
        final q = p * p + w;
        var z = math.sqrt(q.abs());
        x += t;
        if (q >= 0.0) {
          z = p + (p >= 0 ? z : -z);
          wr[nn - 1] = x + z;
          wr[nn] = x + z;
          if (z != 0.0) wr[nn] = x - w / z;
          wi[nn - 1] = wi[nn] = 0.0;
        } else {
          wr[nn - 1] = x + p;
          wr[nn] = x + p;
          wi[nn - 1] = z;
          wi[nn] = -z;
        }
        if (its > 4 || nn % 100 < 2) {
          print('deflate 2x2 nn=$nn its=$its λ=(${wr[nn]},${wi[nn]}),'
              '(${wr[nn - 1]},${wi[nn - 1]})');
        }
        nn -= 2;
        break;
      }
      if (its == 30) {
        print('!! 不收敛: nn=$nn, l=$l, |a[nn][nn-1]|=${a[nn * n + nn - 1].abs()},'
            ' |a[nn-1][nn-2]|=${a[(nn - 1) * n + nn - 2].abs()},'
            ' diag尾=${a[nn * n + nn]},${a[(nn - 1) * n + nn - 1]}');
        return;
      }
      if (its == 10 || its == 20) {
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
      totalIts++;
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
        if (m == l) break;
        final u = a[m * n + m - 1].abs() * (q.abs() + r.abs());
        final vv2 = p.abs() *
            (a[(m - 1) * n + m - 1].abs() +
                z.abs() +
                a[(m + 1) * n + m + 1].abs());
        if (u + vv2 == vv2) break;
      }
      for (var i = m + 2; i <= nn; i++) {
        a[i * n + i - 2] = 0.0;
        if (i != m + 2) a[i * n + i - 3] = 0.0;
      }
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
        if (p < 0) s = -s;
        if (s == 0.0) continue;
        if (k == m) {
          if (l != m) a[k * n + k - 1] = -a[k * n + k - 1];
        } else {
          a[k * n + k - 1] = -s * xn;
        }
        p += s;
        final xs = p / s, ys = q / s, zs = r / s;
        final qs = q / p, rs = r / p;
        for (var j = k; j <= nn; j++) {
          var pj = a[k * n + j] + qs * a[(k + 1) * n + j];
          if (k != nn - 1) {
            pj += rs * a[(k + 2) * n + j];
            a[(k + 2) * n + j] -= pj * zs;
          }
          a[(k + 1) * n + j] -= pj * ys;
          a[k * n + j] -= pj * xs;
        }
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
  print('QR 完成，总迭代 $totalIts，耗时 ${sw.elapsed}');
  var tr = 0.0, sr = 0.0;
  for (var i = 0; i < n; i++) {
    tr += a[i * n + i];
    sr += wr[i];
  }
  // trace 已被异常 shift 改写，用保存的原始对角无法比；只打印 Σλ。
  print('Σλ=$sr（trace 已被 shift 改写不可直接对比）');
}
