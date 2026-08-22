/// 高级 Bayer 去马赛克算法：MHC / AAHD / AMaZE / LMMSE / IGV。
///
/// 从 isp_kernels.dart 独立出来的大代码量算法集（避免其继续膨胀）。
/// 统一约定：
/// - 输入 16 位 w*h Bayer 马赛克，输出交织 RGB（w*h*3，Uint16List）；
/// - 边界若干像素环与过小的图回退 [demosaicBilinear]（先用它铺底，
///   再覆写内部像素），输出钳位到 0..maxValue；
/// - 全部为教学/调试向的**简化实现**，忠实于原论文核心思想但做了
///   明确标注的简化（方向数、窗口、后处理等），非逐行移植。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'isp_kernels.dart';

int _clamp16(num v, int maxValue) =>
    v < 0 ? 0 : (v > maxValue ? maxValue : v.round());

/// 写出内部像素（钳位到 0..maxValue）。
void _emit(Uint16List rgb, int p, num r, num g, num b, int maxValue) {
  final i = p * 3;
  rgb[i] = _clamp16(r, maxValue);
  rgb[i + 1] = _clamp16(g, maxValue);
  rgb[i + 2] = _clamp16(b, maxValue);
}

/// ---------------------------------------------------------------------------
/// 公共件
/// ---------------------------------------------------------------------------

/// 方向性 G 估计（梯度校正）：R/B 站点沿水平方向，
/// g = (G_W+G_E)/2 + (2C − C_W2 − C_E2)/4（AHD 系论文的通用形式）。
double _gHorz(Uint16List bayer, int width, int p) =>
    (bayer[p - 1] + bayer[p + 1]) / 2 +
    (2.0 * bayer[p] - bayer[p - 2] - bayer[p + 2]) / 4;

/// 方向性 G 估计：垂直方向（同 [_gHorz]，步进换行宽）。
double _gVert(Uint16List bayer, int width, int p) =>
    (bayer[p - width] + bayer[p + width]) / 2 +
    (2.0 * bayer[p] - bayer[p - 2 * width] - bayer[p + 2 * width]) / 4;

/// 色差平滑插值：在已知 G 平面 [g] 上重建通道 [color]（0=R / 2=B）。
/// 同色站点取真值；其余像素用 ±2 邻域内同色站点的 (C−G) 均值加回 G。
/// [g] 仅在 [border] 环以内有效，邻域触及无效区的采样点直接跳过。
void _fillChrominance(Float64List ch, Float64List g, Uint16List bayer,
    int color, int width, int height, BayerPattern pattern, int border) {
  for (var y = border; y < height - border; y++) {
    for (var x = border; x < width - border; x++) {
      final p = y * width + x;
      if (pattern.colorAt(x, y) == color) {
        ch[p] = bayer[p].toDouble();
        continue;
      }
      var sum = 0.0;
      var count = 0;
      for (var dy = -2; dy <= 2; dy++) {
        final ny = y + dy;
        if (ny < border || ny >= height - border) continue;
        for (var dx = -2; dx <= 2; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx;
          if (nx < border || nx >= width - border) continue;
          if (pattern.colorAt(nx, ny) != color) continue;
          final q = ny * width + nx;
          sum += bayer[q] - g[q];
          count++;
        }
      }
      ch[p] = g[p] + (count > 0 ? sum / count : 0);
    }
  }
}

/// 3x3 中值（AMaZE 色差平面去拉链用）。
double _median9(Float64List plane, int width, int x, int y) {
  final v = <double>[
    for (var dy = -1; dy <= 1; dy++)
      for (var dx = -1; dx <= 1; dx++) plane[(y + dy) * width + x + dx],
  ]..sort();
  return v[4];
}

/// ---------------------------------------------------------------------------
/// MHC（Malvar, He, Cutler 2004）
/// ---------------------------------------------------------------------------

// Malvar 2004 的 5x5 线性核（×2 整数化，/16 归一化）：
// "High-quality linear interpolation for demosaicing of Bayer-patterned
// color images", ICASSP 2004。
/// G @ R/B 站点。
const _kGatC = [
  [0, 0, -2, 0, 0],
  [0, 0, 4, 0, 0],
  [-2, 4, 8, 4, -2],
  [0, 0, 4, 0, 0],
  [0, 0, -2, 0, 0],
];

/// R/B @ 同色横行的 G 站点。
const _kCatGRow = [
  [0, 0, 1, 0, 0],
  [0, -2, 0, -2, 0],
  [-2, 8, 10, 8, -2],
  [0, -2, 0, -2, 0],
  [0, 0, 1, 0, 0],
];

/// R/B @ 同色竖列的 G 站点（[_kCatGRow] 的转置）。
const _kCatGCol = [
  [0, 0, -2, 0, 0],
  [0, -2, 8, -2, 0],
  [1, 0, 10, 0, 1],
  [0, -2, 8, -2, 0],
  [0, 0, -2, 0, 0],
];

/// R @ B 站点 / B @ R 站点（对角方向）。
const _kCatOpp = [
  [0, 0, -3, 0, 0],
  [0, 4, 0, 4, 0],
  [-3, 0, 12, 0, -3],
  [0, 4, 0, 4, 0],
  [0, 0, -3, 0, 0],
];

/// 5x5 整数卷积（核系数和为 16，+8 四舍五入后右移 4 位）。
/// 调用方保证 (x, y) 距边界 ≥2 像素。
int _conv5(Uint16List bayer, int width, int p, List<List<int>> k) {
  var acc = 0;
  for (var dy = -2; dy <= 2; dy++) {
    final row = k[dy + 2];
    final q = p + dy * width;
    for (var dx = -2; dx <= 2; dx++) {
      final c = row[dx + 2];
      if (c != 0) acc += c * bayer[q + dx];
    }
  }
  return (acc + 8) >> 4;
}

/// MHC 梯度校正线性插值（Malvar, He, Cutler, ICASSP 2004）。
///
/// G 通道用含亮度梯度校正项的 5x5 FIR；R/B 在对方相位与 G 相位分别有
/// 固定卷积核（见上方四个核常量）。纯线性、无方向选择，是高质量线性
/// 去马赛克的事实标准（dcraw 的 "linear" 档）。边界 2 像素环回退双线性。
Uint16List demosaicMhc(Uint16List bayer,
    {required int width,
    required int height,
    required BayerPattern pattern,
    int maxValue = 65535}) {
  final rgb = demosaicBilinear(
      bayer, width: width, height: height, pattern: pattern);
  if (width < 5 || height < 5) return rgb;
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final p = y * width + x;
      final i = p * 3;
      final own = pattern.colorAt(x, y);
      rgb[i + own] = bayer[p];
      if (own == 1) {
        // G 站点：横向邻居是 R 则 R 用横行核、B 用竖列核，反之亦然。
        final rRow = pattern.colorAt(x + 1, y) == 0;
        rgb[i] = _clamp16(
            _conv5(bayer, width, p, rRow ? _kCatGRow : _kCatGCol), maxValue);
        rgb[i + 2] = _clamp16(
            _conv5(bayer, width, p, rRow ? _kCatGCol : _kCatGRow), maxValue);
      } else {
        rgb[i + 1] = _clamp16(_conv5(bayer, width, p, _kGatC), maxValue);
        final opp = own == 0 ? 2 : 0;
        rgb[i + opp] =
            _clamp16(_conv5(bayer, width, p, _kCatOpp), maxValue);
      }
    }
  }
  return rgb;
}

/// ---------------------------------------------------------------------------
/// AAHD / AHD（Hirakawa & Parks 2005）
/// ---------------------------------------------------------------------------

/// 简化 sRGB → CIELab（D65）。输入归一化 0..1 的线性化前 RGB。
(double, double, double) _rgbToLab(double r, double g, double b) {
  double lin(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  final rl = lin(r), gl = lin(g), bl = lin(b);
  final x = (0.4124 * rl + 0.3576 * gl + 0.1805 * bl) / 0.95047;
  final y = 0.2126 * rl + 0.7152 * gl + 0.0722 * bl;
  final z = (0.0193 * rl + 0.1192 * gl + 0.9505 * bl) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  final fx = f(x), fy = f(y), fz = f(z);
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

/// AAHD 自适应同质性定向去马赛克（Hirakawa & Parks, "Adaptive
/// homogeneity-directed demosaicing algorithm", IEEE TIP 2005）。
///
/// 简化实现：水平/垂直两个方向各生成一幅候选图（G 沿方向做梯度校正
/// 插值，R/B 经色差平滑 [_fillChrominance]），两候选图转 CIELab
/// （简化 sRGB 流程），逐像素按 3x3 邻域同质性（Lab 距离小于阈值
/// [_epsL]/[_epsAB] 的邻居数）投票选方向。原论文的色差方向性插值与
/// 迭代选向未实现，注释标注为简化。边界 3 像素环回退双线性。
Uint16List demosaicAahd(Uint16List bayer,
    {required int width,
    required int height,
    required BayerPattern pattern,
    int maxValue = 65535}) {
  final rgb = demosaicBilinear(
      bayer, width: width, height: height, pattern: pattern);
  const border = 3;
  if (width < 2 * border + 1 || height < 2 * border + 1) return rgb;
  final pixels = width * height;
  final inv = 1.0 / maxValue;

  // 1. 两方向候选图（G 沿方向，R/B 色差平滑）。
  final gH = Float64List(pixels), gV = Float64List(pixels);
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final p = y * width + x;
      if (pattern.colorAt(x, y) == 1) {
        gH[p] = bayer[p].toDouble();
        gV[p] = gH[p];
      } else {
        gH[p] = _gHorz(bayer, width, p);
        gV[p] = _gVert(bayer, width, p);
      }
    }
  }
  final rH = Float64List(pixels), bH = Float64List(pixels);
  final rV = Float64List(pixels), bV = Float64List(pixels);
  _fillChrominance(rH, gH, bayer, 0, width, height, pattern, 2);
  _fillChrominance(bH, gH, bayer, 2, width, height, pattern, 2);
  _fillChrominance(rV, gV, bayer, 0, width, height, pattern, 2);
  _fillChrominance(bV, gV, bayer, 2, width, height, pattern, 2);

  // 2. 两候选图转 Lab，逐像素 3x3 邻域同质性计数。
  final lH = Float64List(pixels), aH = Float64List(pixels),
      bH2 = Float64List(pixels);
  final lV = Float64List(pixels), aV = Float64List(pixels),
      bV2 = Float64List(pixels);
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final p = y * width + x;
      final lh = _rgbToLab(rH[p] * inv, gH[p] * inv, bH[p] * inv);
      lH[p] = lh.$1;
      aH[p] = lh.$2;
      bH2[p] = lh.$3;
      final lv = _rgbToLab(rV[p] * inv, gV[p] * inv, bV[p] * inv);
      lV[p] = lv.$1;
      aV[p] = lv.$2;
      bV2[p] = lv.$3;
    }
  }
  const epsL = 2.0, epsAB = 4.0; // 同质性阈值（Lab 单位，经验值）
  final homH = Int32List(pixels), homV = Int32List(pixels);
  for (var y = border; y < height - border; y++) {
    for (var x = border; x < width - border; x++) {
      final p = y * width + x;
      var ch = 0, cv = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final q = (y + dy) * width + x + dx;
          if ((lH[p] - lH[q]).abs() <= epsL &&
              (aH[p] - aH[q]).abs() <= epsAB &&
              (bH2[p] - bH2[q]).abs() <= epsAB) {
            ch++;
          }
          if ((lV[p] - lV[q]).abs() <= epsL &&
              (aV[p] - aV[q]).abs() <= epsAB &&
              (bV2[p] - bV2[q]).abs() <= epsAB) {
            cv++;
          }
        }
      }
      homH[p] = ch;
      homV[p] = cv;
    }
  }

  // 3. 逐像素选向（简化：直接比同质性计数，未做原论文的邻域迭代聚合）。
  for (var y = border; y < height - border; y++) {
    for (var x = border; x < width - border; x++) {
      final p = y * width + x;
      if (homH[p] >= homV[p]) {
        _emit(rgb, p, rH[p], gH[p], bH[p], maxValue);
      } else {
        _emit(rgb, p, rV[p], gV[p], bV[p], maxValue);
      }
    }
  }
  return rgb;
}

/// ---------------------------------------------------------------------------
/// AMaZE（Zhang & Wu 2005 方向滤波融合路线）
/// ---------------------------------------------------------------------------

/// AMaZE 方向性去马赛克（Zhang & Wu, "Color demosaicking via directional
/// linear minimum mean square-error estimation", IEEE TIP 2005 及其
/// 方向滤波融合姊妹篇）。
///
/// 简化实现：G 在 R/B 站点按 H/V 两方向（原论文为四方向，含两对角，
/// 此处简化为两方向并注释说明）梯度做反梯度加权融合；R/B 经色差平滑
/// [_fillChrominance]；最后对 R−G / B−G 色差平面做 3x3 中值滤波去
/// 拉链（AMaZE 的后处理思想）。边界 3 像素环回退双线性。
Uint16List demosaicAmaze(Uint16List bayer,
    {required int width,
    required int height,
    required BayerPattern pattern,
    int maxValue = 65535}) {
  final rgb = demosaicBilinear(
      bayer, width: width, height: height, pattern: pattern);
  const border = 3;
  if (width < 2 * border + 1 || height < 2 * border + 1) return rgb;
  final pixels = width * height;
  final g = Float64List(pixels);
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final p = y * width + x;
      if (pattern.colorAt(x, y) == 1) {
        g[p] = bayer[p].toDouble();
        continue;
      }
      final gh = _gHorz(bayer, width, p);
      final gv = _gVert(bayer, width, p);
      // 方向梯度：一阶差 + 亮度二阶差（沿该方向越大越不可信）。
      final dh = (bayer[p - 1] - bayer[p + 1]).abs() +
          (2 * bayer[p] - bayer[p - 2] - bayer[p + 2]).abs();
      final dv = (bayer[p - width] - bayer[p + width]).abs() +
          (2 * bayer[p] - bayer[p - 2 * width] - bayer[p + 2 * width]).abs();
      final wh = 1.0 / (1.0 + dh);
      final wv = 1.0 / (1.0 + dv);
      g[p] = (wh * gh + wv * gv) / (wh + wv);
    }
  }
  final r = Float64List(pixels), b = Float64List(pixels);
  _fillChrominance(r, g, bayer, 0, width, height, pattern, 2);
  _fillChrominance(b, g, bayer, 2, width, height, pattern, 2);
  // 3x3 中值滤波去拉链（对色差平面，不动 G 本身）。
  final dr = Float64List(pixels), db = Float64List(pixels);
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final p = y * width + x;
      dr[p] = r[p] - g[p];
      db[p] = b[p] - g[p];
    }
  }
  for (var y = border; y < height - border; y++) {
    for (var x = border; x < width - border; x++) {
      final p = y * width + x;
      _emit(rgb, p, g[p] + _median9(dr, width, x, y), g[p],
          g[p] + _median9(db, width, x, y), maxValue);
    }
  }
  return rgb;
}

/// ---------------------------------------------------------------------------
/// LMMSE（Zhang & Wu 2005）
/// ---------------------------------------------------------------------------

/// LMMSE 去马赛克（Zhang & Wu, "Color demosaicking via directional
/// linear minimum mean square-error estimation", IEEE TIP 2005）。
///
/// 简化实现：R/B 站点沿 H/V 两方向各做梯度校正 G 估计，方向能量用
/// 3x3 窗口内亮度二阶差分绝对值之和（替代原论文的方向梯度分类 +
/// 维纳滤波权重推导），按逆能量加权融合；R/B 经色差平滑插值
/// （省略原论文的二阶 Laplacian 迭代校正，注释标注为简化）。
/// 边界 3 像素环回退双线性。
Uint16List demosaicLmmse(Uint16List bayer,
    {required int width,
    required int height,
    required BayerPattern pattern,
    int maxValue = 65535}) {
  final rgb = demosaicBilinear(
      bayer, width: width, height: height, pattern: pattern);
  const border = 3;
  if (width < 2 * border + 1 || height < 2 * border + 1) return rgb;
  final pixels = width * height;
  final eps = maxValue * 1e-3; // 能量下限（平坦区两方向等权）
  final g = Float64List(pixels);
  for (var y = border; y < height - border; y++) {
    for (var x = border; x < width - border; x++) {
      final p = y * width + x;
      if (pattern.colorAt(x, y) == 1) {
        g[p] = bayer[p].toDouble();
        continue;
      }
      final gh = _gHorz(bayer, width, p);
      final gv = _gVert(bayer, width, p);
      // 方向能量：3x3 窗口内各点沿 H/V 的亮度二阶差分绝对值之和。
      var eH = 0.0, eV = 0.0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final q = (y + dy) * width + x + dx;
          eH += (2 * bayer[q] - bayer[q - 2] - bayer[q + 2]).abs();
          eV += (2 * bayer[q] - bayer[q - 2 * width] - bayer[q + 2 * width])
              .abs();
        }
      }
      final wh = 1.0 / (eH + eps);
      final wv = 1.0 / (eV + eps);
      g[p] = (wh * gh + wv * gv) / (wh + wv);
    }
  }
  final r = Float64List(pixels), b = Float64List(pixels);
  _fillChrominance(r, g, bayer, 0, width, height, pattern, border);
  _fillChrominance(b, g, bayer, 2, width, height, pattern, border);
  for (var y = border; y < height - border; y++) {
    for (var x = border; x < width - border; x++) {
      final p = y * width + x;
      _emit(rgb, p, r[p], g[p], b[p], maxValue);
    }
  }
  return rgb;
}

/// ---------------------------------------------------------------------------
/// IGV（Pekkucuksen & Altunbasak 2010 风格）
/// ---------------------------------------------------------------------------

/// IGV 无阈值方向去马赛克（Pekkucuksen & Altunbasak, "Gradient based
/// threshold free color filter array interpolation", ICIP 2010）。
///
/// **等价思想实现**（未查到论文逐行配方，参考 darktable/RawTherapee 中
/// IGV 的思路）：先用 MHC 式 5x5 核得到 G 初值 [_kGatC]；R/B 站点再按
/// H/V 两个 5 样本窗口内马赛克值的**方差**（而非硬阈值）做无阈值加权
/// 融合修正 G；R/B 经色差平滑 [_fillChrominance]。边界 2 像素环回退
/// 双线性。
Uint16List demosaicIgv(Uint16List bayer,
    {required int width,
    required int height,
    required BayerPattern pattern,
    int maxValue = 65535}) {
  final rgb = demosaicBilinear(
      bayer, width: width, height: height, pattern: pattern);
  if (width < 5 || height < 5) return rgb;
  final pixels = width * height;
  final eps = maxValue * maxValue * 1e-6; // 方差下限（平坦区两方向等权）
  final g = Float64List(pixels);
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final p = y * width + x;
      if (pattern.colorAt(x, y) == 1) {
        g[p] = bayer[p].toDouble();
        continue;
      }
      // 方向性估计（MHC 式梯度校正）。
      final gh = _gHorz(bayer, width, p);
      final gv = _gVert(bayer, width, p);
      // 无阈值方向权重：H/V 各取 5 样本窗口的方差，方差小者权重大。
      double variance5(int q0, int step) {
        var s = 0.0, s2 = 0.0;
        for (var k = -2; k <= 2; k++) {
          final v = bayer[q0 + k * step].toDouble();
          s += v;
          s2 += v * v;
        }
        return s2 / 5 - (s / 5) * (s / 5);
      }

      final varH = variance5(p, 1);
      final varV = variance5(p, width);
      final wh = 1.0 / (varH + eps);
      final wv = 1.0 / (varV + eps);
      g[p] = (wh * gh + wv * gv) / (wh + wv);
    }
  }
  final r = Float64List(pixels), b = Float64List(pixels);
  _fillChrominance(r, g, bayer, 0, width, height, pattern, 2);
  _fillChrominance(b, g, bayer, 2, width, height, pattern, 2);
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final p = y * width + x;
      _emit(rgb, p, r[p], g[p], b[p], maxValue);
    }
  }
  return rgb;
}
