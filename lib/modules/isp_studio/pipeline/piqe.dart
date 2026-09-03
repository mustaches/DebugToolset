/// PIQE（感知质量评价器，Venkatanath 15，无参考、无需模型）：MATLAB
/// piqe 的 Dart 移植（对齐 michael-rutherford/pypiqe 的逐行复刻）。
///
/// 流程：灰度（cv2 BGR2GRAY 同权重）→ 按图最大值归一化到 0..255 →
/// 对称填充到 16 的整数倍 → 7×7 高斯窗 MSCN 归一化 → 16×16 分块：
/// 方差超阈值的活跃块按「块效应（边缘段标准差）」与「高斯噪声
/// （中心- surround 标准差比）」两条判据分类失真，按块方差加权
/// 汇总；Score = (distorted + 1) / (NHSA + 1) × 100（0..100，
/// 越小越好；平坦图按定义得 100）。
///
/// 已知口径差异：灰度权重 0.299/0.587/0.114（PIQE 参考实现为
/// cv2 BGR2GRAY；与本工具其他仪器的 BT.601 全范围 (77,150,29)>>8
/// 在第三位小数上有差异）。
///
/// 纯 Dart + dart:typed_data，可在后台 isolate 中运行。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'niqe.dart';

const int _kPiqeBlock = 16;
const double _kPiqeActivityThreshold = 0.1;
const double _kPiqeImpairedThreshold = 0.1;
const int _kPiqeWindow = 6;

/// 对称填充索引（np.pad mode='symmetric' 的右/下侧镜像）。
int _mirrorIndex(int i, int n) {
  while (i < 0 || i >= n) {
    if (i < 0) {
      i = -i - 1;
    } else {
      i = 2 * n - 1 - i;
    }
  }
  return i;
}

/// ddof=1 的方差。
double _variance(List<double> v) {
  if (v.length < 2) return 0.0;
  var mean = 0.0;
  for (final x in v) {
    mean += x;
  }
  mean /= v.length;
  var s = 0.0;
  for (final x in v) {
    s += (x - mean) * (x - mean);
  }
  return s / (v.length - 1);
}

/// 块效应判据（noticeDistCriterion）：块的四条边各取 11 段 6 像素
/// 滑动窗口，任一段标准差 < 阈值即判为受损块。
bool _piqeBlockImpaired(Float64List block) {
  const n = _kPiqeBlock;
  const nSeg = n - _kPiqeWindow + 1;
  // 四条边（行优先展开）：上 = 行 0，右 = 列 15，下 = 行 15，左 = 列 0。
  final edges = <Float64List>[
    Float64List.fromList([for (var x = 0; x < n; x++) block[x]]), // 上
    Float64List.fromList([for (var y = 0; y < n; y++) block[y * n + n - 1]]), // 右
    Float64List.fromList([for (var x = 0; x < n; x++) block[(n - 1) * n + x]]), // 下
    Float64List.fromList([for (var y = 0; y < n; y++) block[y * n]]), // 左
  ];
  for (final edge in edges) {
    for (var i = 0; i < nSeg; i++) {
      final seg = edge.sublist(i, i + _kPiqeWindow);
      if (math.sqrt(_variance(seg)) < _kPiqeImpairedThreshold) {
        return true;
      }
    }
  }
  return false;
}

/// 中心-surround 标准差比（centerSurDev）：中心为第 7、8 列；
/// surround 为连续两次 np.delete（先删列 7 再删结果列 8 = 原列 9）
/// 的剩余列——参考实现的删列下标漂移按原样保留（bug-for-bug）。
double _piqeCenterSurDev(Float64List block) {
  const n = _kPiqeBlock;
  final center = <double>[
    for (var y = 0; y < n; y++) block[y * n + 7],
    for (var y = 0; y < n; y++) block[y * n + 8],
  ];
  final surround = <double>[
    for (var y = 0; y < n; y++)
      for (var x = 0; x < n; x++)
        if (x != 7 && x != 9) block[y * n + x],
  ];
  final centerStd = math.sqrt(_variance(center));
  final surroundStd = math.sqrt(_variance(surround));
  final dev = centerStd / surroundStd;
  return dev.isNaN ? 0 : dev;
}

/// PIQE 质量分（无参考，0..100 越小越好）。宽或高 < 1 时返回 NaN；
/// 全零图（最大值为 0）按均匀图口径返回 100。
double piqeScore(Uint8List rgba, int width, int height) {
  if (width < 1 || height < 1 || rgba.length < width * height * 4) {
    return double.nan;
  }
  // 对称填充到 16 的整数倍。
  final pw = width % _kPiqeBlock == 0
      ? width
      : width + _kPiqeBlock - width % _kPiqeBlock;
  final ph = height % _kPiqeBlock == 0
      ? height
      : height + _kPiqeBlock - height % _kPiqeBlock;
  // 灰度（cv2 BGR2GRAY 同权重，四舍五入）+ 按图最大值归一化到 0..255。
  final gray = Float64List(pw * ph);
  var maxV = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final j = (y * width + x) * 4;
      final v = (299 * rgba[j] + 587 * rgba[j + 1] + 114 * rgba[j + 2] + 500) ~/
          1000;
      if (v > maxV) maxV = v;
      gray[y * pw + x] = v.toDouble();
    }
  }
  if (maxV == 0) return 100.0; // 全零图：均匀图口径
  for (var y = height; y < ph; y++) {
    final sy = _mirrorIndex(y, height);
    for (var x = 0; x < width; x++) {
      gray[y * pw + x] = gray[sy * pw + x];
    }
  }
  for (var y = 0; y < ph; y++) {
    for (var x = width; x < pw; x++) {
      gray[y * pw + x] = gray[y * pw + _mirrorIndex(x, width)];
    }
  }
  for (var i = 0; i < gray.length; i++) {
    gray[i] = (255 * gray[i] / maxV).roundToDouble();
  }

  // MSCN：7×7 高斯窗（σ=7/6，边界复制）。
  final mu = nssConvolveGauss(gray, pw, ph);
  final sq = Float64List(gray.length);
  for (var i = 0; i < sq.length; i++) {
    sq[i] = gray[i] * gray[i];
  }
  final sigmaSq = nssConvolveGauss(sq, pw, ph);
  final norm = Float64List(gray.length);
  for (var i = 0; i < norm.length; i++) {
    final s2 = (sigmaSq[i] - mu[i] * mu[i]).abs();
    norm[i] = (gray[i] - mu[i]) / (math.sqrt(s2) + 1);
  }

  // 16×16 分块：活跃块按块效应/高斯噪声判据分类，按块方差加权汇总。
  var distBlockScores = 0.0;
  var nhsa = 0;
  for (var by = 0; by < ph; by += _kPiqeBlock) {
    for (var bx = 0; bx < pw; bx += _kPiqeBlock) {
      final block = Float64List(_kPiqeBlock * _kPiqeBlock);
      for (var y = 0; y < _kPiqeBlock; y++) {
        for (var x = 0; x < _kPiqeBlock; x++) {
          block[y * _kPiqeBlock + x] = norm[(by + y) * pw + bx + x];
        }
      }
      final blockVar = _variance(block);
      if (blockVar <= _kPiqeActivityThreshold) continue;
      nhsa++;
      final wndc = _piqeBlockImpaired(block) ? 1 : 0;
      final blockSigma = math.sqrt(blockVar);
      final cenSurDev = _piqeCenterSurDev(block);
      final blockBeta =
          (blockSigma - cenSurDev).abs() / math.max(blockSigma, cenSurDev);
      final wnc = blockSigma > 2 * blockBeta ? 1 : 0;
      distBlockScores += wndc * (1 - blockVar) + wnc * blockVar;
    }
  }
  return ((distBlockScores + 1) / (1 + nhsa)) * 100;
}
