/// 仪器类节点（直方图/示波器/矢量示波器）的分析计算。
///
/// 全部输入为链末端色调映射后的 RGBA8888（与预览显示同一数据），
/// 纯 Dart + dart:typed_data，可在后台 isolate 中运行。
library;

import 'dart:typed_data';

/// 波形图纵轴级数（8 位亮度）。
const int kWaveformLevels = 256;

/// 2x2 最近邻降采样（RGBA8888）：仪器分析用的统计类计算（直方图/
/// 波形/矢量示波器）降采样后视觉等效，数据量与耗时降为 1/4。
/// 宽高不足 2 时原样返回。
Uint8List downsample2x2(Uint8List rgba, int width, int height) {
  final w2 = width ~/ 2;
  final h2 = height ~/ 2;
  if (w2 <= 0 || h2 <= 0) return rgba;
  final out = Uint8List(w2 * h2 * 4);
  var j = 0;
  for (var y = 0; y < h2; y++) {
    var i = y * 2 * width * 4;
    for (var x = 0; x < w2; x++, i += 8, j += 4) {
      out[j] = rgba[i];
      out[j + 1] = rgba[i + 1];
      out[j + 2] = rgba[i + 2];
      out[j + 3] = rgba[i + 3];
    }
  }
  return out;
}

/// 矢量示波器网格边长（Cb/Cr 各 256 的 2 倍超采样，迹线更细）。
const int kVectorscopeSize = 512;

/// RGB 直方图：返回 (R, G, B) 三个 256 桶计数。
(Uint32List, Uint32List, Uint32List) histogramRgb(Uint8List rgba) {
  final r = Uint32List(256);
  final g = Uint32List(256);
  final b = Uint32List(256);
  for (var i = 0; i + 2 < rgba.length; i += 4) {
    r[rgba[i]]++;
    g[rgba[i + 1]]++;
    b[rgba[i + 2]]++;
  }
  return (r, g, b);
}

/// 亮度波形监视器：横轴为图像列（降采样到 [maxCols]），纵轴为亮度级
/// （BT.601 Y，0 在底）。返回 (计数表, 列数)，计数表按 级*列数+列 排列。
(Uint32List, int) waveformLuma(Uint8List rgba, int width, int height,
    {int maxCols = 512}) {
  final cols = width < maxCols ? width : maxCols;
  final counts = Uint32List(cols * kWaveformLevels);
  for (var y = 0; y < height; y++) {
    var i = y * width * 4;
    for (var x = 0; x < width; x++, i += 4) {
      final luma =
          (77 * rgba[i] + 150 * rgba[i + 1] + 29 * rgba[i + 2] + 128) >> 8;
      final col = x * cols ~/ width;
      counts[luma * cols + col]++;
    }
  }
  return (counts, cols);
}

/// 矢量示波器：BT.601 Cb/Cr 在 512x512 网格上的计数（Cb/Cr 各 256
/// 的 2 倍超采样；左下角为 (0,0)，中心 (256,256) 为无色）。按
/// Cr*512+Cb 排列。按像素扫描顺序把相邻像素的色度点连成线（模拟
/// 示波器电子束的连续扫描轨迹）；连线做抗锯齿，按覆盖率把亮度
/// 分摊到相邻两格。
Uint32List vectorscope(Uint8List rgba) {
  final counts = Uint32List(kVectorscopeSize * kVectorscopeSize);
  var prevCb = -1;
  var prevCr = -1;
  for (var i = 0; i + 2 < rgba.length; i += 4) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    // BT.601 全范围：Cb/Cr 以 128 为中心；2 倍超采样（0..511，
    // 中心 256），右移 7 位保留半格精度（+64 为半格四舍五入）。
    final cb =
        (256 + ((-43 * r - 85 * g + 128 * b + 64) >> 7)).clamp(0, 511);
    final cr =
        (256 + ((128 * r - 107 * g - 21 * b + 64) >> 7)).clamp(0, 511);
    _aaSegment(counts, prevCb, prevCr, cb, cr);
    prevCb = cb;
    prevCr = cr;
  }
  return counts;
}

/// 单格满权重（抗锯齿覆盖率的定点刻度）。
const int _kAaFullWeight = 256;

/// 把 (x0,y0)→(x1,y1) 的线段按覆盖率累加进计数表（不含起点，
/// 起点已由上一段计入）。Xiaolin Wu 思路：沿主轴逐格推进，副轴
/// 位置的小数部分决定分摊到相邻两格的权重。
void _aaSegment(Uint32List counts, int x0, int y0, int x1, int y1) {
  if (x0 < 0 || (x0 == x1 && y0 == y1)) {
    counts[y1 * kVectorscopeSize + x1] += _kAaFullWeight;
    return;
  }
  final dx = x1 - x0;
  final dy = y1 - y0;
  // 快路径：8 连通相邻点（steps <= 1）只落终点一格，无覆盖率分摊。
  // 真实视频相邻像素色度大多渐变，绝大多数段走这里。
  if (dx.abs() <= 1 && dy.abs() <= 1) {
    counts[y1 * kVectorscopeSize + x1] += _kAaFullWeight;
    return;
  }
  final horizontal = dx.abs() >= dy.abs();
  final steps = horizontal ? dx.abs() : dy.abs();
  final sign = horizontal ? dx.sign : dy.sign;
  final major0 = horizontal ? x0 : y0;
  final minor0 = horizontal ? y0 : x0;
  final dMinor = horizontal ? dy : dx;
  // 副轴位置用 16.16 定点累加（增量一次除法并四舍五入），循环内
  // 全整数运算；>>/& 对负数即向下取整 + 正余数，负斜率同样适用。
  final absInc = ((dMinor.abs() << 16) + (steps >> 1)) ~/ steps;
  final inc = dMinor < 0 ? -absInc : absInc;
  var acc = minor0 << 16;
  for (var s = 1; s < steps; s++) {
    final major = major0 + s * sign;
    acc += inc;
    final base = acc >> 16;
    final w1 = (acc & 0xFFFF) >> 8; // 0..255：副轴下一格分到的权重
    final w0 = _kAaFullWeight - w1;
    final (x, y) = horizontal ? (major, base) : (base, major);
    counts[y * kVectorscopeSize + x] += w0;
    if (w1 > 0) {
      final (xb, yb) = horizontal ? (major, base + 1) : (base + 1, major);
      counts[yb * kVectorscopeSize + xb] += w1;
    }
  }
  // 终点恒满权重（定点累加的舍入误差不留到端点）。
  counts[y1 * kVectorscopeSize + x1] += _kAaFullWeight;
}
