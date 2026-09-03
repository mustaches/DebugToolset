/// NIQE（自然图像质量评价器，Mittal 13）：无参考质量评价——提取 MSCN
/// 系数的 NSS 特征（2 尺度 × 18 维：MSCN 的 GGD 形状/方差 + 4 方向
/// 邻积的 AGGD 形状/均值/左右方差），与官方 pristine 自然图像语料
/// 预训练多元高斯模型（niqe_model.dart）计算马氏距离，越大越差。
///
/// 与官方 MATLAB 实现对齐的复刻（同 BasicSR niqe.py）；已知口径差异：
/// 亮度为 BT.601 全范围（官方为 MATLAB YCbCr 的 Y），尺度间降采样为
/// 2×2 盒式均值（官方为抗锯齿 imresize）；图像不足 96×96 时整幅
/// 单块兜底（官方实现无法计算）。
///
/// 纯 Dart + dart:typed_data，可在后台 isolate 中运行。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'niqe_model.dart';

/// Gamma 函数（Lanczos 近似，g=7）。
double _gamma(double z) {
  const p = [
    0.99999999999980993, 676.5203681218851, -1259.1392167224028,
    771.32342877765313, -176.61502916214059, 12.507343278686905,
    -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7,
  ];
  if (z < 0.5) {
    return math.pi / (math.sin(math.pi * z) * _gamma(1 - z));
  }
  final zz = z - 1;
  var x = p[0];
  for (var i = 1; i < 9; i++) {
    x += p[i] / (zz + i);
  }
  final t = zz + 7.5;
  return math.sqrt(2 * math.pi) *
      math.pow(t, zz + 0.5) *
      math.exp(-t) *
      x;
}

/// AGGD 形状参数查找表：gam = 0.2..10（步长 0.001），
/// rGam[i] = Γ(2/α)² / (Γ(1/α)·Γ(3/α))。懒构建一次。
List<double>? _rGam;

void _ensureGamTable() {
  if (_rGam != null) return;
  final table = <double>[];
  for (var i = 0; i <= 9800; i++) {
    final alpha = 0.2 + i * 0.001;
    final g2 = _gamma(2 / alpha);
    table.add(g2 * g2 / (_gamma(1 / alpha) * _gamma(3 / alpha)));
  }
  _rGam = table;
}

/// AGGD 参数估计（论文式 7）：返回 (α, β_l, β_r)。
/// 数据全零或单侧为空时返回 NaN（调用侧按 NaN 剔除，同官方实现）。
(double, double, double) _estimateAggd(Float64List data) {
  final (alpha, leftStd, rightStd) = nssEstimateAggdRaw(data);
  if (alpha.isNaN) return (double.nan, double.nan, double.nan);
  final betaScale = math.sqrt(_gamma(1 / alpha) / _gamma(3 / alpha));
  return (alpha, leftStd * betaScale, rightStd * betaScale);
}

/// ---------------------------------------------------------------------------
/// NSS 工具函数：NIQE 与 BRISQUE（brisque.dart）共用。
/// ---------------------------------------------------------------------------

/// Gamma 函数（见 _gamma）。
double nssGamma(double z) => _gamma(z);

/// AGGD 原始参数估计：返回 (α, 左标准差, 右标准差)（未经 gamma 缩放；
/// NIQE 的 β 由调用侧乘 sqrt(Γ(1/α)/Γ(3/α))，BRISQUE 直接用 σ 与 σ²）。
/// [rightIncludesZero] 为 true 时零值计入右侧（BRISQUE 官方实现口径，
/// NIQE 官方为 v>0）。数据全零或单侧为空时返回 (NaN, NaN, NaN)。
(double, double, double) nssEstimateAggdRaw(Float64List data,
    {bool rightIncludesZero = false}) {
  _ensureGamTable();
  var lSum = 0.0, rSum = 0.0, absSum = 0.0, sqSum = 0.0;
  var lCnt = 0, rCnt = 0;
  for (final v in data) {
    absSum += v.abs();
    sqSum += v * v;
    if (v < 0) {
      lSum += v * v;
      lCnt++;
    } else if (rightIncludesZero ? v >= 0 : v > 0) {
      rSum += v * v;
      rCnt++;
    }
  }
  if (lCnt == 0 || rCnt == 0 || sqSum == 0) {
    return (double.nan, double.nan, double.nan);
  }
  final leftStd = math.sqrt(lSum / lCnt);
  final rightStd = math.sqrt(rSum / rCnt);
  final gammahat = leftStd / rightStd;
  final n = data.length;
  final rhat = (absSum / n) * (absSum / n) / (sqSum / n);
  final g2 = gammahat * gammahat;
  final rhatnorm = (rhat * (g2 * gammahat + 1) * (gammahat + 1)) /
      ((g2 + 1) * (g2 + 1));
  final table = _rGam!;
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < table.length; i++) {
    final d = (table[i] - rhatnorm).abs();
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return (0.2 + best * 0.001, leftStd, rightStd);
}

/// AGGD 参数估计（NIQE 口径：β 经 sqrt(Γ(1/α)/Γ(3/α)) 缩放，
/// 零值不计入任一侧；见 _estimateAggd）。ILNIQE（ilniqe.dart）共用。
(double, double, double) nssEstimateAggd(Float64List data) =>
    _estimateAggd(data);

/// 7×7 高斯窗卷积（见 _convolveGauss；NIQE/BRISQUE 的窗相同：
/// 7×7、σ=7/6、归一化）。
Float64List nssConvolveGauss(Float64List img, int w, int h) =>
    _convolveGauss(img, w, h);

/// 2×2 盒式均值降采样（见 _downsample2x）。
Float64List nssDownsample2x(Float64List p, int w, int h) =>
    _downsample2x(p, w, h);

/// 单块 18 维 NSS 特征：MSCN 系数的 AGGD (α, (β_l+β_r)/2)，
/// 加 4 个方向（水平/垂直/主对角/副对角）邻积的 AGGD
/// (α, 均值, β_l, β_r)（论文式 8）。邻积平移按环绕（np.roll 同义）。
List<double> _computeFeatures(Float64List block, int bw, int bh) {
  final feat = <double>[];
  final (alpha, betaL, betaR) = _estimateAggd(block);
  feat.add(alpha);
  feat.add((betaL + betaR) / 2);
  const shifts = [
    [0, 1],
    [1, 0],
    [1, 1],
    [1, -1],
  ];
  for (final s in shifts) {
    final prod = Float64List(block.length);
    for (var y = 0; y < bh; y++) {
      final sy = (y + s[0]) % bh;
      for (var x = 0; x < bw; x++) {
        final sx = (x + s[1] + bw) % bw;
        prod[y * bw + x] = block[y * bw + x] * block[sy * bw + sx];
      }
    }
    final (a, bl, br) = _estimateAggd(prod);
    final mean = (br - bl) * (_gamma(2 / a) / _gamma(1 / a));
    feat.addAll([a, mean, bl, br]);
  }
  return feat;
}

/// 1-D 高斯核（懒构建一次）：7×7 窗可分离（W[i][j]=k[i]·k[j]，实测
/// 残差 ~3e-18），k[j] = W[3][j]/√W[3][3]。
final List<double> _gaussKernel1d = () {
  const w7 = niqeGaussianWindow;
  final s = math.sqrt(w7[3 * 7 + 3]);
  return [for (var j = 0; j < 7; j++) w7[3 * 7 + j] / s];
}();

/// 7×7 高斯窗卷积（边界复制，scipy mode='nearest' 同义）。
/// 窗可分离（见 [_gaussKernel1d]），按水平+垂直两趟 1-D 卷积实现：
/// 每像素 14 次乘加代替 49 次（NIQE/BRISQUE/PIQE 的 MSCN 主耗时项）。
Float64List _convolveGauss(Float64List img, int w, int h) {
  final k = _gaussKernel1d;
  // 水平趟。
  final tmp = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var kx = 0; kx < 7; kx++) {
        var xx = x + kx - 3;
        if (xx < 0) {
          xx = 0;
        } else if (xx >= w) {
          xx = w - 1;
        }
        s += img[row + xx] * k[kx];
      }
      tmp[row + x] = s;
    }
  }
  // 垂直趟。
  final out = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var s = 0.0;
      for (var ky = 0; ky < 7; ky++) {
        var yy = y + ky - 3;
        if (yy < 0) {
          yy = 0;
        } else if (yy >= h) {
          yy = h - 1;
        }
        s += tmp[yy * w + x] * k[ky];
      }
      out[row + x] = s;
    }
  }
  return out;
}

/// 2×2 盒式均值降采样（宽高减半，奇数边裁掉）。
Float64List _downsample2x(Float64List p, int w, int h) {
  final w2 = w ~/ 2;
  final h2 = h ~/ 2;
  final out = Float64List(w2 * h2);
  for (var y = 0; y < h2; y++) {
    var i = y * 2 * w;
    for (var x = 0; x < w2; x++, i += 2) {
      out[y * w2 + x] = (p[i] + p[i + 1] + p[i + w] + p[i + w + 1]) / 4;
    }
  }
  return out;
}

/// 36×36 矩阵求逆：Gauss-Jordan 部分主元；奇异时逐级加大对角岭
/// （1e-6 起 ×10）重试，仍失败返回单位阵兜底（畸变特征协方差在
/// 有效块数极少时奇异）。
Float64List _invert36(Float64List m) {
  const n = 36;
  var ridge = 0.0;
  for (var attempt = 0; attempt < 4; attempt++) {
    final a = Float64List.fromList(m);
    if (ridge > 0) {
      for (var i = 0; i < n; i++) {
        a[i * n + i] += ridge;
      }
    }
    final inv = Float64List(n * n);
    for (var i = 0; i < n; i++) {
      inv[i * n + i] = 1.0;
    }
    var ok = true;
    for (var col = 0; col < n && ok; col++) {
      var piv = col;
      var pivAbs = a[col * n + col].abs();
      for (var r = col + 1; r < n; r++) {
        final v = a[r * n + col].abs();
        if (v > pivAbs) {
          pivAbs = v;
          piv = r;
        }
      }
      if (pivAbs < 1e-12) {
        ok = false;
        break;
      }
      if (piv != col) {
        for (var j = 0; j < n; j++) {
          final t1 = a[col * n + j];
          a[col * n + j] = a[piv * n + j];
          a[piv * n + j] = t1;
          final t2 = inv[col * n + j];
          inv[col * n + j] = inv[piv * n + j];
          inv[piv * n + j] = t2;
        }
      }
      final d = a[col * n + col];
      for (var j = 0; j < n; j++) {
        a[col * n + j] /= d;
        inv[col * n + j] /= d;
      }
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final f = a[r * n + col];
        if (f == 0) continue;
        for (var j = 0; j < n; j++) {
          a[r * n + j] -= f * a[col * n + j];
          inv[r * n + j] -= f * inv[col * n + j];
        }
      }
    }
    if (ok) return inv;
    ridge = ridge == 0 ? 1e-6 : ridge * 10;
  }
  // 兜底：单位阵（马氏距离退化为欧氏距离）。
  final inv = Float64List(n * n);
  for (var i = 0; i < n; i++) {
    inv[i * n + i] = 1.0;
  }
  return inv;
}

/// NIQE 质量分（无参考，越大越差）：RGBA8888 帧 → BT.601 亮度 →
/// 2 尺度 NSS 特征（36 维）→ 与 pristine 模型的马氏距离。
/// 宽或高 < 4 时返回 NaN（调用侧按无法计算处理）。
double niqeScore(Uint8List rgba, int width, int height) {
  if (width < 4 || height < 4 || rgba.length < width * height * 4) {
    return double.nan;
  }
  // BT.601 全范围亮度（与本工具仪器同口径）。
  var w = width, h = height;
  var gray = Float64List(w * h);
  for (var i = 0, j = 0; i < gray.length; i++, j += 4) {
    gray[i] =
        ((77 * rgba[j] + 150 * rgba[j + 1] + 29 * rgba[j + 2] + 128) >> 8)
            .toDouble();
  }
  // 官方推荐 96×96 分块；不足一块时整幅单块（非标准，仅兜底）。
  final bh = h < 96 ? h : 96;
  final bw = w < 96 ? w : 96;
  final nbh = h ~/ bh;
  final nbw = w ~/ bw;

  // 逐尺度提取各块的 18 维特征（每尺度一个列表，最后按块拼接成
  // 36 维——同官方实现 np.concatenate(distparam, axis=1)）。
  final scaleRows = <List<List<double>>>[];
  for (var scale = 1; scale <= 2; scale++) {
    final mu = _convolveGauss(gray, w, h);
    final norm = Float64List(w * h);
    for (var i = 0; i < norm.length; i++) {
      final v = gray[i];
      norm[i] = v - mu[i];
    }
    final sq = Float64List(w * h);
    for (var i = 0; i < norm.length; i++) {
      sq[i] = gray[i] * gray[i];
    }
    final sigmaSq = _convolveGauss(sq, w, h);
    for (var i = 0; i < norm.length; i++) {
      final s2 = (sigmaSq[i] - mu[i] * mu[i]).abs();
      norm[i] = norm[i] / (math.sqrt(s2) + 1);
    }
    final bsh = bh ~/ scale;
    final bsw = bw ~/ scale;
    final rows = <List<double>>[];
    for (var by = 0; by < nbh; by++) {
      for (var bx = 0; bx < nbw; bx++) {
        final block = Float64List(bsh * bsw);
        for (var y = 0; y < bsh; y++) {
          for (var x = 0; x < bsw; x++) {
            block[y * bsw + x] = norm[(by * bsh + y) * w + (bx * bsw + x)];
          }
        }
        rows.add(_computeFeatures(block, bsw, bsh));
      }
    }
    scaleRows.add(rows);
    if (scale == 1) {
      gray = _downsample2x(gray, w, h);
      w ~/= 2;
      h ~/= 2;
    }
  }
  // 块 i 在两个尺度的特征拼接为 36 维行。
  final rows = <List<double>>[
    for (var i = 0; i < scaleRows[0].length; i++)
      [...scaleRows[0][i], ...scaleRows[1][i]],
  ];

  // 36 维特征的均值（NaN 剔除）与协方差（含 NaN 的行整行剔除）。
  const dim = 36;
  final muDist = Float64List(dim);
  final counts = List<int>.filled(dim, 0);
  for (final row in rows) {
    for (var j = 0; j < dim; j++) {
      final v = row[j];
      if (!v.isNaN) {
        muDist[j] += v;
        counts[j]++;
      }
    }
  }
  for (var j = 0; j < dim; j++) {
    muDist[j] = counts[j] > 0 ? muDist[j] / counts[j] : double.nan;
  }
  final validRows = [
    for (final row in rows)
      if (!row.any((v) => v.isNaN)) row,
  ];
  final covDist = Float64List(dim * dim);
  if (validRows.length >= 2) {
    final n = validRows.length;
    final means = Float64List(dim);
    for (final row in validRows) {
      for (var j = 0; j < dim; j++) {
        means[j] += row[j];
      }
    }
    for (var j = 0; j < dim; j++) {
      means[j] /= n;
    }
    for (final row in validRows) {
      for (var i = 0; i < dim; i++) {
        final di = row[i] - means[i];
        for (var j = 0; j < dim; j++) {
          covDist[i * dim + j] += di * (row[j] - means[j]);
        }
      }
    }
    for (var i = 0; i < dim * dim; i++) {
      covDist[i] /= (n - 1);
    }
  }

  // 马氏距离（论文式 10）：sqrt((μp-μd)' · inv((Σp+Σd)/2) · (μp-μd))。
  final avgCov = Float64List(dim * dim);
  for (var i = 0; i < dim * dim; i++) {
    avgCov[i] = (niqeCovPris[i] + covDist[i]) / 2;
  }
  final invCov = _invert36(avgCov);
  final diff = Float64List(dim);
  for (var j = 0; j < dim; j++) {
    diff[j] = niqeMuPris[j] - muDist[j];
    if (diff[j].isNaN) return double.nan;
  }
  var q = 0.0;
  for (var i = 0; i < dim; i++) {
    var acc = 0.0;
    for (var j = 0; j < dim; j++) {
      acc += invCov[i * dim + j] * diff[j];
    }
    q += diff[i] * acc;
  }
  return math.sqrt(q < 0 ? 0 : q);
}
