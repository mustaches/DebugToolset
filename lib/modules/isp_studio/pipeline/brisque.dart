/// BRISQUE（空间域盲质量评价器，Mittal 12，无参考）：MSCN 系数的
/// NSS 特征（2 尺度 × 18 维：MSCN 的 AGGD 形状/方差 + 4 方向邻积的
/// AGGD 形状/均值/左右方差），归一化到 [-1,1] 后由官方预训练
/// epsilon-SVR（RBF 核，brisque_model.dart）回归出质量分
/// （0..100，越小越好）。
///
/// 与 rehanguha/brisque（PyPI brisque 包，官方 LIVE 实现的复刻）
/// 对齐；已知口径差异：尺度间降采样为 2×2 盒式均值（参考实现为
/// 双三次 INTER_CUBIC）。AGGD 拟合的右侧含零值（z>=0，同参考实现；
/// 与 NIQE 的 v>0 口径不同）。
///
/// 纯 Dart + dart:typed_data，可在后台 isolate 中运行。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'brisque_model.dart';
import 'niqe.dart';

/// 单尺度 18 维 BRISQUE 特征：MSCN 的 AGGD (α, (σ_l²+σ_r²)/2)，
/// 加 4 个方向邻积（裁边无环绕）的 AGGD (α, 均值, σ_l², σ_r²)。
List<double> _brisqueFeatures(Float64List img, int w, int h) {
  // MSCN：C = 1/255（参考实现输入为 0..1 灰度）。
  const c = 1 / 255;
  final mu = nssConvolveGauss(img, w, h);
  final sq = Float64List(w * h);
  for (var i = 0; i < sq.length; i++) {
    sq[i] = img[i] * img[i];
  }
  final sigmaSq = nssConvolveGauss(sq, w, h);
  final mscn = Float64List(w * h);
  for (var i = 0; i < mscn.length; i++) {
    final s2 = (mu[i] * mu[i] - sigmaSq[i]).abs();
    mscn[i] = (img[i] - mu[i]) / (math.sqrt(s2) + c);
  }

  final feat = <double>[];
  final (alpha, sl, sr) = nssEstimateAggdRaw(mscn, rightIncludesZero: true);
  feat.add(alpha);
  feat.add((sl * sl + sr * sr) / 2);

  // 邻积方向：水平/垂直/主对角/副对角（裁边，无环绕）。
  final prods = <Float64List>[
    for (final _ in Iterable.generate(4)) Float64List((w - 1) * (h - 1)),
  ];
  for (var y = 0; y < h - 1; y++) {
    for (var x = 0; x < w - 1; x++) {
      final i = y * (w - 1) + x;
      final v = mscn[y * w + x];
      prods[0][i] = v * mscn[y * w + x + 1]; // 水平
      prods[1][i] = v * mscn[(y + 1) * w + x]; // 垂直
      prods[2][i] = v * mscn[(y + 1) * w + x + 1]; // 主对角
      prods[3][i] = mscn[(y + 1) * w + x] * mscn[y * w + x + 1]; // 副对角
    }
  }
  for (final p in prods) {
    final (a, pl, pr) = nssEstimateAggdRaw(p, rightIncludesZero: true);
    final mean = a.isNaN
        ? double.nan
        : (pr - pl) *
            math.sqrt(nssGamma(1 / a) / nssGamma(3 / a)) *
            (nssGamma(2 / a) / nssGamma(1 / a));
    feat.addAll([a, mean, pl * pl, pr * pr]);
  }
  return feat;
}

/// BRISQUE 质量分（无参考，0..100 越小越好）：RGBA8888 帧 → 灰度
/// （skimage rgb2gray 同权重，0..1）→ 2 尺度 NSS 特征（36 维）→
/// [-1,1] 归一化 → epsilon-SVR 回归。宽或高 < 4 或特征退化（NaN）
/// 时返回 NaN。
double brisqueScore(Uint8List rgba, int width, int height) {
  if (width < 4 || height < 4 || rgba.length < width * height * 4) {
    return double.nan;
  }
  // skimage.color.rgb2gray 同权重（0.2125/0.7154/0.0721），0..1。
  var w = width, h = height;
  var gray = Float64List(w * h);
  for (var i = 0, j = 0; i < gray.length; i++, j += 4) {
    gray[i] =
        (0.2125 * rgba[j] + 0.7154 * rgba[j + 1] + 0.0721 * rgba[j + 2]) / 255;
  }
  final feat = _brisqueFeatures(gray, w, h);
  gray = nssDownsample2x(gray, w, h);
  w ~/= 2;
  h ~/= 2;
  feat.addAll(_brisqueFeatures(gray, w, h));
  if (feat.any((v) => v.isNaN)) return double.nan;

  // 归一化到 [-1,1]（官方 allrange 同款 min/max）。
  final scaled = Float64List(36);
  for (var j = 0; j < 36; j++) {
    scaled[j] = -1 +
        2.0 /
            (brisqueFeatureMax[j] - brisqueFeatureMin[j]) *
            (feat[j] - brisqueFeatureMin[j]);
  }

  // epsilon-SVR（RBF 核）回归：score = Σ coef·exp(-γ‖x-sv‖²) - ρ。
  final svs = brisqueSupportVectors;
  final coef = brisqueSvCoef;
  var sum = 0.0;
  for (var i = 0; i < brisqueSvCount; i++) {
    final base = i * 36;
    var d2 = 0.0;
    for (var j = 0; j < 36; j++) {
      final d = scaled[j] - svs[base + j];
      d2 += d * d;
    }
    sum += coef[i] * math.exp(-brisqueSvmGamma * d2);
  }
  return sum - brisqueSvmRho;
}
