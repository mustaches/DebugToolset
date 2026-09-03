/// FID / KID 分布级指标的进程内 Dart 实现（纯 Dart，无 Flutter 依赖），
/// 语义忠实于 torchmetrics（scratch/eval_venv/Lib/site-packages/
/// torchmetrics/image/fid.py、kid.py）+ iqa_bridge.py 的 _DistMetric：
///
///   FID：双侧各自累计 sum / xtx / n（float64），出分时
///     μ = sum/n，σ = (xtx − n·μ·μᵀ)/(n−1)（无偏协方差）；
///     a = Σ(μ1−μ2)²，b = trσ1 + trσ2，
///     λ = σ1σ2 的非对称实矩阵特征值（nn/eig.dart），
///     c = Σ Re(√λ)；FID = a + b − 2c。
///     两侧各 <2 个样本时抛错（协方差无定义）。
///
///   KID：特征全部驻留 [N,2048]；subset_size = min(1000, 两侧样本数)，
///     subsets = subset_size ≥ 50 ? 50 : 10（iqa_bridge 小样本口径）；
///     每子集 Fisher–Yates 无放回抽样（固定种子 Random(0)，可复现）；
///     多项式核 K(X,Y) = (X·Yᵀ/2048 + 1)³；无偏 MMD：
///     MMD² = (Σ_{i≠j}Kxx + Σ_{i≠j}Kyy)/(m(m−1)) − 2·ΣKxy/m²；
///     返回各子集均值。Gram 矩阵一次性预计算（torchmetrics 每子集
///     重算点积，数学上等价），抽样子集只查表求和。
///
/// 特征由 metrics/inception_dart.dart 提供（patch 口径，见该文件）。
/// [fidScoreInIsolate] / [kidScoreInIsolate] 为 compute() 入口。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../nn/eig.dart';

/// FID/KID 的特征维度（InceptionV3 pool3）。
const int fidFeatureDim = 2048;

/// FID 双侧统计量累计器（torchmetrics 的 real/fake_features_sum +
/// cov_sum + num_samples，float64）。
class FidAccumulator {
  FidAccumulator([this.dim = fidFeatureDim])
      : sum = Float64List(dim),
        xtx = Float64List(dim * dim);

  final int dim;

  /// 特征列和 Σx（torchmetrics `*_features_sum`）。
  final Float64List sum;

  /// 特征二阶矩 XᵀX（torchmetrics `*_features_cov_sum`）。
  final Float64List xtx;

  /// 已累计样本数。
  var n = 0;

  /// 累计一批特征：[features] 为 [count, dim] 连续排布 fp32
  /// （torchmetrics 在 update 里 .double()，此处同样升 fp64 累计）。
  void addBatch(Float32List features, int count) {
    if (features.length < count * dim) {
      throw ArgumentError('FidAccumulator.addBatch: 特征长度 '
          '${features.length} < $count×$dim');
    }
    for (var r = 0; r < count; r++) {
      final base = r * dim;
      for (var i = 0; i < dim; i++) {
        sum[i] += features[base + i];
      }
      for (var i = 0; i < dim; i++) {
        final vi = features[base + i];
        if (vi == 0.0) {
          continue;
        }
        var idx = i * dim;
        for (var j = 0; j < dim; j++, idx++) {
          xtx[idx] += vi * features[base + j];
        }
      }
    }
    n += count;
  }

  /// 出统计量：μ = sum/n，σ = (xtx − n·μ·μᵀ)/(n−1)（无偏）。
  /// n < 2 抛错（torchmetrics compute 的 RuntimeError 口径）。
  (Float64List, Float64List) meanCov() {
    if (n < 2) {
      throw StateError('FID/KID 需要两侧各 ≥2 个样本（当前侧 $n 个）');
    }
    final mu = Float64List(dim);
    for (var i = 0; i < dim; i++) {
      mu[i] = sum[i] / n;
    }
    final sigma = Float64List(dim * dim);
    final invN1 = 1.0 / (n - 1);
    for (var i = 0; i < dim; i++) {
      final mui = mu[i];
      final row = i * dim;
      for (var j = 0; j < dim; j++) {
        sigma[row + j] = (xtx[row + j] - n * mui * mu[j]) * invN1;
      }
    }
    return (mu, sigma);
  }
}

/// FID 分值（torchmetrics `_compute_fid` 口径）：
/// a + b − 2c，c = Σ Re(√λ)，λ 为 σ1σ2（非对称实矩阵）的特征值。
/// 2048² 规模时矩阵乘与特征值求解为分钟级，只应在出分时调用一次。
double fidCompute(FidAccumulator ref, FidAccumulator test) {
  if (ref.dim != test.dim) {
    throw ArgumentError('fidCompute: 两侧特征维度不一致 '
        '(${ref.dim} vs ${test.dim})');
  }
  final d = ref.dim;
  final (mu1, sigma1) = ref.meanCov();
  final (mu2, sigma2) = test.meanCov();
  var a = 0.0;
  for (var i = 0; i < d; i++) {
    final diff = mu1[i] - mu2[i];
    a += diff * diff;
  }
  var b = 0.0;
  for (var i = 0; i < d; i++) {
    b += sigma1[i * d + i] + sigma2[i * d + i];
  }
  final prod = Float64List(d * d);
  dgemmNn(sigma1, sigma2, prod, d, d, d);
  final ev = eigvalsReal(prod, d);
  var c = 0.0;
  for (var i = 0; i < d; i++) {
    final re = ev.re[i], im = ev.im[i];
    // Re(√λ) = sqrt((|λ| + Re λ)/2)（负实 λ 的实部为 0，同 torch
    // complex sqrt 后取 real）。
    c += math.sqrt((math.sqrt(re * re + im * im) + re) / 2);
  }
  return a + b - 2 * c;
}

/// 由两侧特征（[n,2048] fp32 连续排布）直接出 FID 分。
double fidScoreFromFeatures(
    Float32List refFeatures, int nRef, Float32List testFeatures, int nTest,
    {int dim = fidFeatureDim}) {
  final accRef = FidAccumulator(dim)..addBatch(refFeatures, nRef);
  final accTest = FidAccumulator(dim)..addBatch(testFeatures, nTest);
  return fidCompute(accRef, accTest);
}

/// X·Xᵀ 的 Gram 矩阵（fp64；只算上三角再镜像）。
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

/// X·Yᵀ 的 Gram 矩阵（fp64，[n1,n2]）。
Float64List _gramCross(Float32List x, int n1, Float32List y, int n2, int dim) {
  final g = Float64List(n1 * n2);
  for (var i = 0; i < n1; i++) {
    final xi = i * dim;
    for (var j = 0; j < n2; j++) {
      final yj = j * dim;
      var s = 0.0;
      for (var k = 0; k < dim; k++) {
        s += x[xi + k] * y[yj + k];
      }
      g[i * n2 + j] = s;
    }
  }
  return g;
}

/// 多项式核 (dot/2048 + 1)³（torchmetrics poly_kernel：gamma=None →
/// 1/num_features，coef=1.0，degree=3）。
double _polyK(double dot) {
  final v = dot / fidFeatureDim + 1.0;
  return v * v * v;
}

/// Fisher–Yates 无放回抽样：从 0..n-1 抽 m 个下标（顺序无关，求和用）。
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

/// KID 分值（torchmetrics KernelInceptionDistance 的无偏 MMD 口径，
/// iqa_bridge 的小样本自适应：subset_size=min(1000, 两侧样本数)，
/// subsets=50（size≥50）或 10）。抽样用固定种子 [seed]（缺省 0）
/// 保证可复现；与 torch 的 randperm 序列不同，分值只同量级。
double kidCompute(Float32List refFeatures, int nRef, Float32List testFeatures,
    int nTest,
    {int seed = 0}) {
  const dim = fidFeatureDim;
  if (refFeatures.length < nRef * dim || testFeatures.length < nTest * dim) {
    throw ArgumentError('kidCompute: 特征长度与样本数不符');
  }
  final m = math.min(1000, math.min(nRef, nTest));
  if (m < 2) {
    throw StateError('FID/KID 需要两侧各 ≥2 个样本（ref=$nRef, '
        'test=$nTest）');
  }
  final subsets = m >= 50 ? 50 : 10;
  // Gram 矩阵一次性预计算（与 torchmetrics 每子集重算数学等价）。
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
    total += (kxx + kyy) / mm1 - 2 * kxy / mm;
  }
  return total / subsets;
}

/// compute() 入口：`{'ref': Float32List, 'nRef': int, 'test': Float32List,
/// 'nTest': int}`（两侧 patch 特征 [n,2048] 连续排布）→ FID 分值。
@pragma('vm:entry-point')
double fidScoreInIsolate(Map<String, Object?> msg) => fidScoreFromFeatures(
      msg['ref'] as Float32List,
      msg['nRef'] as int,
      msg['test'] as Float32List,
      msg['nTest'] as int,
    );

/// compute() 入口：消息同 [fidScoreInIsolate] → KID 分值。
@pragma('vm:entry-point')
double kidScoreInIsolate(Map<String, Object?> msg) => kidCompute(
      msg['ref'] as Float32List,
      msg['nRef'] as int,
      msg['test'] as Float32List,
      msg['nTest'] as int,
    );
