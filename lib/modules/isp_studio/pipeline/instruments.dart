/// 仪器类节点（直方图/示波器/矢量示波器）的分析计算。
///
/// 全部输入为链末端色调映射后的 RGBA8888（与预览显示同一数据），
/// 纯 Dart + dart:typed_data，可在后台 isolate 中运行。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
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

/// 合并条带并行分析的分片结果：直方图与波形的计数表按行条带各自
/// 统计，逐元素相加即得全帧结果（各分片的 columns/桶数一致）。
/// 最值保持器的 min/max 标量分别取各分片最小/最大。
/// 矢量示波器是扫描轨迹连线、不可按条带拆分，不走这里。
Map<String, Object?> mergeInstrumentResults(
    List<Map<String, Object?>> parts) {
  if (parts.length == 1) return parts.first;
  final first = parts.first;
  for (var p = 1; p < parts.length; p++) {
    for (final key in ['r', 'g', 'b', 'y']) {
      final dst = first[key];
      final src = parts[p][key];
      if (dst is! Uint32List || src is! Uint32List) continue; // 类型守卫
      for (var i = 0; i < dst.length; i++) {
        dst[i] += src[i];
      }
    }
    // 最值保持器（minmax）的标量：max 取各片最大、min 取各片最小。
    final hi = parts[p]['max'];
    final lo = parts[p]['min'];
    final hi0 = first['max'];
    final lo0 = first['min'];
    if (hi is int && hi0 is int && hi > hi0) first['max'] = hi;
    if (lo is int && lo0 is int && lo < lo0) first['min'] = lo;
  }
  return first;
}

/// 矢量示波器网格边长（Cb/Cr 各 256 的 2 倍超采样，迹线更细）。
const int kVectorscopeSize = 512;

/// RGB+Y 直方图：返回 (R, G, B, Y) 四个 256 桶计数（Y 为 BT.601 亮度，
/// 与波形监视器同一定义）。
(Uint32List, Uint32List, Uint32List, Uint32List) histogramRgb(
    Uint8List rgba) {
  final r = Uint32List(256);
  final g = Uint32List(256);
  final b = Uint32List(256);
  final y = Uint32List(256);
  for (var i = 0; i + 2 < rgba.length; i += 4) {
    r[rgba[i]]++;
    g[rgba[i + 1]]++;
    b[rgba[i + 2]]++;
    y[(77 * rgba[i] + 150 * rgba[i + 1] + 29 * rgba[i + 2] + 128) >> 8]++;
  }
  return (r, g, b, y);
}

/// 波形竖向扫迹的权重刻度：驻留点每像素 +[_kSweepScale]，电子束在
/// 相邻像素间连续移动扫出的中间电平每级 +1。竖向迹线的亮度因此
/// 正比于电子束实际扫过该列该电平的频次——每行都扫过的硬边
/// （彩条）竖线约为主迹线一半亮度，只有少数行扫过的区域（白色
/// 字幕边缘）则显著更暗，不再是无差别的包络灰片。
const int _kSweepScale = 256;

/// 竖向扫迹的差分记录：span (from, to) 开区间每级 +1，O(1) 记两个
/// 端点，由 [_applySweepDiff] 统一前缀和回填。逐电平直接累加在
/// 噪声内容下是每像素几十次写（实测 4 通道 480p 近 70ms），差分
/// 记录使成本与内容无关。[stride] = 电平数 + 1。
void _recordSweep(Int32List diff, int stride, int col, int from, int to) {
  final lo = from < to ? from : to;
  final hi = from < to ? to : from;
  if (hi - lo <= 1) return;
  final base = col * stride;
  diff[base + lo + 1]++;
  diff[base + hi]--;
}

/// 差分表前缀和回填计数表（每列独立的扫描线覆盖计数）。
void _applySweepDiff(Uint32List counts, Int32List diff, int cols, int levels) {
  final stride = levels + 1;
  for (var col = 0; col < cols; col++) {
    final base = col * stride;
    var acc = 0;
    for (var lvl = 1; lvl < levels; lvl++) {
      acc += diff[base + lvl];
      if (acc != 0) counts[lvl * cols + col] += acc;
    }
  }
}

/// 亮度波形监视器：横轴为图像列（降采样到 [maxCols]），纵轴为亮度级
/// （BT.601 Y，0 在底）。返回 (计数表, 列数)，计数表按 级*列数+列 排列。
/// 逐行模拟电子束扫描：相邻像素电平差在中间电平留下扫迹权重
/// （见 [_kSweepScale]），硬边处呈现竖向迹线。
(Uint32List, int) waveformLuma(Uint8List rgba, int width, int height,
    {int maxCols = 512}) {
  final cols = width < maxCols ? width : maxCols;
  final counts = Uint32List(cols * kWaveformLevels);
  const stride = kWaveformLevels + 1;
  final diff = Int32List(cols * stride);
  final colLut = _columnLut(width, cols);
  for (var y = 0; y < height; y++) {
    var i = y * width * 4;
    var prev = -1; // 每行重置：行间是回扫（消隐），不连线
    for (var x = 0; x < width; x++, i += 4) {
      final luma =
          (77 * rgba[i] + 150 * rgba[i + 1] + 29 * rgba[i + 2] + 128) >> 8;
      final col = colLut[x];
      counts[luma * cols + col] += _kSweepScale;
      // 扫迹段归入新列（列映射降采样下的近似）。
      if (prev >= 0) _recordSweep(diff, stride, col, prev, luma);
      prev = luma;
    }
  }
  _applySweepDiff(counts, diff, cols, kWaveformLevels);
  return (counts, cols);
}

/// 列索引 LUT：x → 波形列，去除内层循环逐像素的乘除法。
Int32List _columnLut(int width, int cols) {
  final lut = Int32List(width);
  for (var x = 0; x < width; x++) {
    lut[x] = x * cols ~/ width;
  }
  return lut;
}

/// RGB+Y 波形监视器：横轴为图像列（降采样到 [maxCols]），纵轴为各
/// 通道级（Y 为 BT.601 亮度，0 在底）。返回 (R, G, B, Y, 列数)，
/// 计数表按 级*列数+列 排列。逐行电子束扫迹见 [_kSweepScale]。
(Uint32List, Uint32List, Uint32List, Uint32List, int) waveformRgb(
    Uint8List rgba, int width, int height,
    {int maxCols = 512}) {
  final cols = width < maxCols ? width : maxCols;
  final r = Uint32List(cols * kWaveformLevels);
  final g = Uint32List(cols * kWaveformLevels);
  final b = Uint32List(cols * kWaveformLevels);
  final y = Uint32List(cols * kWaveformLevels);
  final colLut = _columnLut(width, cols);
  const stride = kWaveformLevels + 1;
  final diffR = Int32List(cols * stride);
  final diffG = Int32List(cols * stride);
  final diffB = Int32List(cols * stride);
  final diffY = Int32List(cols * stride);
  for (var yy = 0; yy < height; yy++) {
    var i = yy * width * 4;
    var prevR = -1, prevG = -1, prevB = -1, prevY = -1;
    for (var x = 0; x < width; x++, i += 4) {
      final col = colLut[x];
      final rr = rgba[i];
      final gg = rgba[i + 1];
      final bb = rgba[i + 2];
      final luma = (77 * rr + 150 * gg + 29 * bb + 128) >> 8;
      r[rr * cols + col] += _kSweepScale;
      g[gg * cols + col] += _kSweepScale;
      b[bb * cols + col] += _kSweepScale;
      y[luma * cols + col] += _kSweepScale;
      if (prevR >= 0) {
        _recordSweep(diffR, stride, col, prevR, rr);
        _recordSweep(diffG, stride, col, prevG, gg);
        _recordSweep(diffB, stride, col, prevB, bb);
        _recordSweep(diffY, stride, col, prevY, luma);
      }
      prevR = rr;
      prevG = gg;
      prevB = bb;
      prevY = luma;
    }
  }
  _applySweepDiff(r, diffR, cols, kWaveformLevels);
  _applySweepDiff(g, diffG, cols, kWaveformLevels);
  _applySweepDiff(b, diffB, cols, kWaveformLevels);
  _applySweepDiff(y, diffY, cols, kWaveformLevels);
  return (r, g, b, y, cols);
}

/// 按需通道的波形监视器：只统计 [channels] 列出的通道（'r'/'g'/'b'/'y'），
/// 与 [waveformRgb] 同布局（含逐行电子束扫迹，见 [_kSweepScale]）。
/// 播放中示波器只显示部分通道时，避免为不可见通道白做 3/4 的统计。
/// 返回 (通道→计数表, 列数)。
(Map<String, Uint32List>, int) waveformSelective(
    Uint8List rgba, int width, int height, Set<String> channels,
    {int maxCols = 512}) {
  final cols = width < maxCols ? width : maxCols;
  final tables = <String, Uint32List>{
    for (final ch in channels)
      if (ch == 'r' || ch == 'g' || ch == 'b' || ch == 'y')
        ch: Uint32List(cols * kWaveformLevels),
  };
  if (tables.isEmpty) return (tables, cols);
  final r = tables['r'];
  final g = tables['g'];
  final b = tables['b'];
  final y = tables['y'];
  final colLut = _columnLut(width, cols);
  const stride = kWaveformLevels + 1;
  final diffR = r == null ? null : Int32List(cols * stride);
  final diffG = g == null ? null : Int32List(cols * stride);
  final diffB = b == null ? null : Int32List(cols * stride);
  final diffY = y == null ? null : Int32List(cols * stride);
  for (var yy = 0; yy < height; yy++) {
    var i = yy * width * 4;
    var prevR = -1, prevG = -1, prevB = -1, prevY = -1;
    for (var x = 0; x < width; x++, i += 4) {
      final col = colLut[x];
      final rr = rgba[i];
      final gg = rgba[i + 1];
      final bb = rgba[i + 2];
      if (r != null) r[rr * cols + col] += _kSweepScale;
      if (g != null) g[gg * cols + col] += _kSweepScale;
      if (b != null) b[bb * cols + col] += _kSweepScale;
      var luma = -1;
      if (y != null) {
        luma = (77 * rr + 150 * gg + 29 * bb + 128) >> 8;
        y[luma * cols + col] += _kSweepScale;
      }
      if (diffR != null && prevR >= 0) {
        _recordSweep(diffR, stride, col, prevR, rr);
      }
      if (diffG != null && prevG >= 0) {
        _recordSweep(diffG, stride, col, prevG, gg);
      }
      if (diffB != null && prevB >= 0) {
        _recordSweep(diffB, stride, col, prevB, bb);
      }
      if (diffY != null && prevY >= 0) {
        _recordSweep(diffY, stride, col, prevY, luma);
      }
      prevR = rr;
      prevG = gg;
      prevB = bb;
      prevY = luma;
    }
  }
  if (r != null) _applySweepDiff(r, diffR!, cols, kWaveformLevels);
  if (g != null) _applySweepDiff(g, diffG!, cols, kWaveformLevels);
  if (b != null) _applySweepDiff(b, diffB!, cols, kWaveformLevels);
  if (y != null) _applySweepDiff(y, diffY!, cols, kWaveformLevels);
  return (tables, cols);
}

/// 矢量示波器：BT.601 Cb/Cr 在 512x512 网格上的计数（Cb/Cr 各 256
/// 的 2 倍超采样；左下角为 (0,0)，中心 (256,256) 为无色）。按
/// Cr*512+Cb 排列。按像素扫描顺序把相邻像素的色度点连成线（模拟
/// 示波器电子束的连续扫描轨迹）；连线做抗锯齿，按覆盖率把亮度
/// 分摊到相邻两格。
///
/// [rowWidth] 非空时表示缓冲是按行拼接的隔行条带（多核并行用）：
/// 每行开头重置电子束起点——拼入的行在原图中并不相邻，跨行连线
/// 无意义；丢失的行间接线只占全帧线段的 1/行数，视觉不可见。
Uint32List vectorscope(Uint8List rgba, {int? rowWidth}) {
  final counts = Uint32List(kVectorscopeSize * kVectorscopeSize);
  var prevCb = -1;
  var prevCr = -1;
  var xInRow = 0;
  for (var i = 0; i + 2 < rgba.length; i += 4) {
    if (rowWidth != null) {
      if (xInRow == 0) {
        prevCb = -1;
        prevCr = -1;
        xInRow = rowWidth;
      }
      xInRow--;
    }
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    // BT.601 全范围：Cb/Cr 以 128 为中心；2 倍超采样（0..511，
    // 中心 256），右移 7 位保留半格精度（+64 为半格四舍五入）。
    // 分支钳制而非 clamp()：后者返回 num，逐像素隐式拆箱与类型
    // 检查是实测热点（平滑帧 6.2ms → 3.0ms）。
    var cb = 256 + ((-43 * r - 85 * g + 128 * b + 64) >> 7);
    var cr = 256 + ((128 * r - 107 * g - 21 * b + 64) >> 7);
    if (cb < 0) {
      cb = 0;
    } else if (cb > 511) {
      cb = 511;
    }
    if (cr < 0) {
      cr = 0;
    } else if (cr > 511) {
      cr = 511;
    }
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

/// 最值保持器（minmax）：Mono 单通道链末端色调映射帧的灰度最值
/// （mono 出图 R=G=B，扫 R 通道即可）。返回 (最小值, 最大值)，
/// 均为 0..255。空帧返回 (0, 0)。
(int, int) minmaxMono(Uint8List rgba) {
  if (rgba.length < 4) return (0, 0);
  var min = 255;
  var max = 0;
  for (var i = 0; i + 2 < rgba.length; i += 4) {
    final v = rgba[i];
    if (v < min) min = v;
    if (v > max) max = v;
  }
  return (min, max);
}

/// 从 RGBA8888 显示帧提取单通道灰度图（R=G=B=通道值，alpha=255）。
///
/// 播放/暂停时仪器馈源复用预览节点的色调映射帧（按预览节点 id 键控、
/// 无端口维度）：接在分路器通道输出（out_r/g/b、out_y/u/v、out_h/s/l）
/// 下的多台仪器会解析到同一帧，不做通道提取时读到完全相同的数值。
/// [channel] ∈ 'r'/'g'/'b'/'y'/'u'/'v'/'h'/'s'/'l'；YUV 为 BT.601
/// 全范围（U/V 以 128 为零点）、HSL 的 H/S/L 映射到 0..255，口径与
/// 16 位 CSC 核（rgbToYuv/rgbToHsl，isp_kernels.dart）一致。
/// 未知通道原样返回（调用侧保证只传上述通道）。
Uint8List extractChannelGray(Uint8List rgba, String channel) {
  final out = Uint8List(rgba.length);
  switch (channel) {
    case 'r' || 'g' || 'b':
      final off = channel == 'r' ? 0 : (channel == 'g' ? 1 : 2);
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        final v = rgba[i + off];
        out[i] = v;
        out[i + 1] = v;
        out[i + 2] = v;
        out[i + 3] = 255;
      }
    case 'y' || 'u' || 'v':
      // BT.601 全范围（同 rgbToYuv 的定点系数，8 位量级）。
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        final r = rgba[i];
        final g = rgba[i + 1];
        final b = rgba[i + 2];
        var v = switch (channel) {
          'y' => (19595 * r + 38470 * g + 7471 * b + 32768) >> 16,
          'u' => ((-11058 * r - 21710 * g + 32768 * b + 32768) >> 16) + 128,
          _ => ((32768 * r - 27439 * g - 5329 * b + 32768) >> 16) + 128,
        };
        if (v < 0) {
          v = 0;
        } else if (v > 255) {
          v = 255;
        }
        out[i] = v;
        out[i + 1] = v;
        out[i + 2] = v;
        out[i + 3] = 255;
      }
    case 'h' || 's' || 'l':
      // 标准 HSL（同 rgbToHsl）：H/S/L ∈ 0..1 映射到 0..255。
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        final r = rgba[i] / 255.0;
        final g = rgba[i + 1] / 255.0;
        final b = rgba[i + 2] / 255.0;
        final mx = math.max(r, math.max(g, b));
        final mn = math.min(r, math.min(g, b));
        final l = (mx + mn) / 2;
        var h = 0.0;
        var s = 0.0;
        final d = mx - mn;
        if (d > 0) {
          s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
          if (mx == r) {
            h = ((g - b) / d) % 6;
          } else if (mx == g) {
            h = (b - r) / d + 2;
          } else {
            h = (r - g) / d + 4;
          }
          h /= 6;
          if (h < 0) h += 1;
        }
        final t = channel == 'h' ? h : (channel == 's' ? s : l);
        final v = (t * 255).round().clamp(0, 255);
        out[i] = v;
        out[i + 1] = v;
        out[i + 2] = v;
        out[i + 3] = 255;
      }
    default:
      return rgba;
  }
  return out;
}

/// ---------------------------------------------------------------------------
/// 计数表 → 显示用 RGBA 亮度图（对数刻度）。
/// 纯 Dart，在仪器 worker isolate 侧渲染，UI 只做 decodeImageFromPixels。
/// ---------------------------------------------------------------------------

/// 对数亮度 LUT：c ∈ [0, maxCount] → 0..255。逐像素查表替代逐像素 log。
Uint8List _logLut(int maxCount) {
  final lut = Uint8List(maxCount + 1);
  final logMax = math.log(maxCount + 1);
  for (var c = 1; c <= maxCount; c++) {
    lut[c] = (math.log(c + 1) / logMax * 255).round();
  }
  return lut;
}

/// 计数表 → RGBA 亮度图（对数刻度；数据第 0 行在底部，图像第 0 行在顶部）。
Uint8List intensityRgba(
    Uint32List counts, int w, int h, int tintR, int tintG, int tintB) {
  final out = Uint8List(w * h * 4);
  var max = 0;
  for (final c in counts) {
    if (c > max) max = c;
  }
  if (max == 0) return out;
  final lut = _logLut(max);
  for (var ry = 0; ry < h; ry++) {
    final srcRow = h - 1 - ry;
    for (var x = 0; x < w; x++) {
      final c = counts[srcRow * w + x];
      if (c == 0) continue;
      final t = lut[c];
      final j = (ry * w + x) * 4;
      out[j] = tintR * t ~/ 255;
      out[j + 1] = tintG * t ~/ 255;
      out[j + 2] = tintB * t ~/ 255;
      out[j + 3] = 255;
    }
  }
  return out;
}

/// 波形监视器 RGBA 亮度图：按 [visible] 通道分别使用对应专属颜色绘制，
/// 不做色彩混叠（Y 为白色，R 为红色，G 为绿色，B 为蓝色）。
/// 竖向迹线已在分析层按电子束扫过频次累积（见 [_kSweepScale]），
/// 此处只按计数渲染。
Uint8List waveformIntensityRgba(
    Map<String, Object?> result, int w, int h, Set<String> visible) {
  final out = Uint8List(w * h * 4);
  if (visible.isEmpty) return out;

  if (visible.contains('y')) {
    final counts = (result['y'] ?? result['counts']) as Uint32List?;
    if (counts == null) return out;
    _drawChannelInto(out, counts, w, h, 255, 255, 255);
    return out;
  }

  for (final (ch, tintR, tintG, tintB) in [
    ('r', 255, 0, 0),
    ('g', 0, 255, 0),
    ('b', 0, 0, 255),
  ]) {
    if (!visible.contains(ch)) continue;
    final counts = result[ch] as Uint32List?;
    if (counts == null) continue;
    _drawChannelInto(out, counts, w, h, tintR, tintG, tintB);
  }

  return out;
}

void _drawChannelInto(
    Uint8List out, Uint32List counts, int w, int h, int tintR, int tintG, int tintB) {
  var max = 0;
  for (final c in counts) {
    if (c > max) max = c;
  }
  if (max == 0) return;
  final lut = _logLut(max);
  for (var ry = 0; ry < h; ry++) {
    final srcRow = h - 1 - ry;
    for (var x = 0; x < w; x++) {
      final c = counts[srcRow * w + x];
      if (c == 0) continue;
      final t = lut[c];
      final j = (ry * w + x) * 4;
      final cr = tintR * t ~/ 255;
      final cg = tintG * t ~/ 255;
      final cb = tintB * t ~/ 255;
      out[j] = math.min(255, out[j] + cr);
      out[j + 1] = math.min(255, out[j + 1] + cg);
      out[j + 2] = math.min(255, out[j + 2] + cb);
      out[j + 3] = math.max(out[j + 3], t);
    }
  }
}

/// PSNR（峰值信噪比）：两幅 RGBA8888 图（同尺寸，长度按短者截断）
/// RGB 三通道的均方误差 MSE 与 PSNR(dB) = 10·log10(255²/MSE)。
/// 两图完全相同（MSE=0）时 PSNR 为 [double.infinity]。
/// 用于评估图像噪声/处理保真度：数值越大越接近参考图。
(double mse, double psnr) psnrRgba(Uint8List a, Uint8List b) {
  final n = math.min(a.length, b.length) & ~3;
  final (sum, count) = _psnrBandSum(a, b, 0, n);
  if (count == 0) return (0.0, double.infinity);
  final mse = sum / count;
  if (mse == 0) return (0.0, double.infinity);
  return (mse, 10 * math.log(255 * 255 / mse) / math.ln10);
}

/// PSNR 行带部分和：[i0,i1) 字节区间（4 字节像素对齐）内 RGB 三通道
/// 的平方误差和与样本数；供 [psnrRgba] 整幅串行与并行分带复用。
(double, int) _psnrBandSum(Uint8List a, Uint8List b, int i0, int i1) {
  var sum = 0.0;
  var count = 0;
  for (var i = i0; i < i1; i += 4) {
    for (var c = 0; c < 3; c++) {
      final d = a[i + c] - b[i + c];
      sum += d * d;
      count++;
    }
  }
  return (sum, count);
}

/// SSIM 块边长（非重叠块 MSSIM 近似）。
const int _kSsimBlock = 8;

/// SSIM（结构相似度，Wang 04）：两幅 RGBA8888 图（同尺寸）按 R/G/B
/// 三通道分别在不重叠 8×8 块上计算块 SSIM（C1=(0.01·255)²，
/// C2=(0.03·255)²，总体方差），返回 (全部块与通道的均值, R 均值,
/// G 均值, B 均值)。两图完全相同为 1.0；宽高不足一个块时整幅为单块。
/// 用于评估图像噪声/压缩损伤的结构保真度：数值越大越接近参考图。
(double, double, double, double) ssimRgba(
    Uint8List a, Uint8List b, int width, int height) {
  final bw = width < _kSsimBlock ? width : _kSsimBlock;
  final bh = height < _kSsimBlock ? height : _kSsimBlock;
  if (bw <= 0 || bh <= 0) return (1.0, 1.0, 1.0, 1.0);
  final (sum, cnt) = _ssimBandSum(a, b, width, bw, bh, 0, height);
  if (cnt == 0) return (1.0, 1.0, 1.0, 1.0);
  final sr = sum[0] / cnt;
  final sg = sum[1] / cnt;
  final sb = sum[2] / cnt;
  return ((sr + sg + sb) / 3, sr, sg, sb);
}

/// SSIM 块行带部分和：[by0,by1) 像素行区间（按 bh 对齐切带）内全部
/// 不重叠块的 R/G/B 块 SSIM 和（返回长度 3 的数组）与块数；块统计
/// 口径与遍历顺序同 [ssimRgba] 原串行实现，供串行整幅与并行分带
/// 复用（C1=(0.01·255)²，C2=(0.03·255)²，总体方差）。
(Float64List, int) _ssimBandSum(Uint8List a, Uint8List b, int width, int bw,
    int bh, int by0, int by1) {
  const c1 = 6.5025; // (0.01·255)²
  const c2 = 58.5225; // (0.03·255)²
  final sum = Float64List(3);
  var cnt = 0;
  for (var by = by0; by + bh <= by1; by += bh) {
    for (var bx = 0; bx + bw <= width; bx += bw) {
      final n = bw * bh;
      for (var c = 0; c < 3; c++) {
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
        for (var y = by; y < by + bh; y++) {
          var i = (y * width + bx) * 4 + c;
          for (var x = 0; x < bw; x++, i += 4) {
            final va = a[i];
            final vb = b[i];
            sa += va;
            sb += vb;
            saa += va * va;
            sbb += vb * vb;
            sab += va * vb;
          }
        }
        final ma = sa / n;
        final mb = sb / n;
        final va = saa / n - ma * ma;
        final vb = sbb / n - mb * mb;
        final cov = sab / n - ma * mb;
        final ssim = ((2 * ma * mb + c1) * (2 * cov + c2)) /
            ((ma * ma + mb * mb + c1) * (va + vb + c2));
        sum[c] += ssim;
      }
      cnt++;
    }
  }
  return (sum, cnt);
}

/// MS-SSIM 各尺度权重（Wang 03，5 尺度）；尺度不足时截断并归一化。
const _msssimWeights = [0.0448, 0.2856, 0.3001, 0.2363, 0.1333];

/// 单通道平面 2×2 均值降采样（宽高减半，奇数边裁掉）。
Uint8List _downsample2xPlane(Uint8List p, int w, int h) {
  final w2 = w ~/ 2;
  final h2 = h ~/ 2;
  final out = Uint8List(w2 * h2);
  for (var y = 0; y < h2; y++) {
    var i = y * 2 * w;
    for (var x = 0; x < w2; x++, i += 2) {
      out[y * w2 + x] = (p[i] + p[i + 1] + p[i + w] + p[i + w + 1] + 2) >> 2;
    }
  }
  return out;
}

/// 单尺度单通道（w*h 平面）：8×8 非重叠块的平均亮度项 l 与平均
/// 对比度-结构项 cs（与 [ssimRgba] 同块统计口径）。
(double, double) _ssimBlockTerms(Uint8List a, Uint8List b, int w, int h) {
  const c1 = 6.5025; // (0.01·255)²
  const c2 = 58.5225; // (0.03·255)²
  var lSum = 0.0, csSum = 0.0;
  var cnt = 0;
  for (var by = 0; by + _kSsimBlock <= h; by += _kSsimBlock) {
    for (var bx = 0; bx + _kSsimBlock <= w; bx += _kSsimBlock) {
      const n = _kSsimBlock * _kSsimBlock;
      var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;
      for (var y = by; y < by + _kSsimBlock; y++) {
        var i = y * w + bx;
        for (var x = 0; x < _kSsimBlock; x++, i++) {
          final va = a[i];
          final vb = b[i];
          sa += va;
          sb += vb;
          saa += va * va;
          sbb += vb * vb;
          sab += va * vb;
        }
      }
      final ma = sa / n;
      final mb = sb / n;
      final va = saa / n - ma * ma;
      final vb = sbb / n - mb * mb;
      final cov = sab / n - ma * mb;
      lSum += (2 * ma * mb + c1) / (ma * ma + mb * mb + c1);
      csSum += (2 * cov + c2) / (va + vb + c2);
      cnt++;
    }
  }
  if (cnt == 0) return (1.0, 1.0);
  return (lSum / cnt, csSum / cnt);
}

/// MS-SSIM（多尺度结构相似度，Wang 03）：两幅 RGBA8888 图（同尺寸）
/// 按 R/G/B 三通道分别在逐级 2× 降采样的多尺度上计算——每尺度的
/// 对比度-结构项 cs 按权重累乘，亮度项 l 只取最粗尺度
/// （MS-SSIM = Π cs_j^wj · l_M^wM）；尺度数上限 5（图像太小放不下
/// 8×8 块时提前停止），权重截断归一化。返回 (总体, R, G, B)；
/// 完全相同为 1.0。比单尺度 SSIM 更适合多分辨率/不同观看距离下的
/// 结构信息评估。
(double, double, double, double) msssimRgba(
    Uint8List a, Uint8List b, int width, int height) {
  if (width < _kSsimBlock || height < _kSsimBlock) {
    // 不足一个块：退化为单尺度 SSIM。
    return ssimRgba(a, b, width, height);
  }
  final sr = _msssimChannel(a, b, width, height, 0);
  final sg = _msssimChannel(a, b, width, height, 1);
  final sb = _msssimChannel(a, b, width, height, 2);
  return ((sr + sg + sb) / 3, sr, sg, sb);
}

/// MS-SSIM 单通道值：[msssimRgba] 的 per-channel 主体（通道平面提取、
/// 逐尺度 cs 按权重累乘、亮度项取最粗尺度），供串行整幅与并行按通道
/// 复用。
double _msssimChannel(
    Uint8List a, Uint8List b, int width, int height, int c) {
  var pa = Uint8List(width * height);
  var pb = Uint8List(width * height);
  for (var i = 0, j = c; i < pa.length; i++, j += 4) {
    pa[i] = a[j];
    pb[i] = b[j];
  }
  // 逐尺度统计（亮度项只保留当级值，循环结束即最粗尺度）。
  final csList = <double>[];
  var lLast = 1.0;
  var cw = width, ch = height;
  while (cw >= _kSsimBlock &&
      ch >= _kSsimBlock &&
      csList.length < _msssimWeights.length) {
    final (l, cs) = _ssimBlockTerms(pa, pb, cw, ch);
    csList.add(cs.clamp(0.0, 1.0));
    lLast = l.clamp(0.0, 1.0);
    if (csList.length == _msssimWeights.length) break;
    pa = _downsample2xPlane(pa, cw, ch);
    pb = _downsample2xPlane(pb, cw, ch);
    cw ~/= 2;
    ch ~/= 2;
  }
  // 权重截断归一化后累乘：cs 每尺度都参与，l 只取最粗尺度。
  var wSum = 0.0;
  for (var j = 0; j < csList.length; j++) {
    wSum += _msssimWeights[j];
  }
  var msssim = 1.0;
  for (var j = 0; j < csList.length; j++) {
    final wj = _msssimWeights[j] / wSum;
    msssim *= math.pow(csList[j], wj);
  }
  msssim *= math.pow(lLast, _msssimWeights[csList.length - 1] / wSum);
  return msssim.toDouble();
}

/// ---------------------------------------------------------------------------
/// FSIM（特征相似度，Zhang 11 结构的实用简化版）：相位一致性（PC）用
/// 空间域双尺度正交对近似（奇=Scharr 梯度幅度、偶=|Laplacian| 的局部
/// 能量/幅度比），梯度幅度（GM）用 /16 归一化 Scharr。
/// ---------------------------------------------------------------------------

/// FSIM 常量（Zhang 11）：T1 为 PC 项常数，T2 为梯度项常数。
const double _kFsimT1 = 0.85;
const double _kFsimT2 = 160.0;

/// 3×3 盒式模糊写入 [out]，[tmp] 为水平趟缓冲。
/// 边界为窗截断（仅平均图内像素，与 `lib` 原 2-D 实现口径一致）。
/// 盒式核可分离：水平均值 + 垂直均值，与 2-D 逐点均值数学等价
/// （每像素约 4 次加法代替 9 次）。
void _boxBlur3Into(
    Float64List p, int w, int h, Float64List out, Float64List tmp) {
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final x0 = x > 0 ? x - 1 : 0;
      final x1 = x < w - 1 ? x + 1 : w - 1;
      var s = p[row + x];
      if (x0 != x) s += p[row + x0];
      if (x1 != x) s += p[row + x1];
      tmp[row + x] = s / (x1 - x0 + 1);
    }
  }
  for (var y = 0; y < h; y++) {
    final y0 = y > 0 ? y - 1 : 0;
    final y1 = y < h - 1 ? y + 1 : h - 1;
    final r0 = y0 * w, r1 = y * w, r2 = y1 * w;
    final n = y1 - y0 + 1;
    for (var x = 0; x < w; x++) {
      var s = tmp[r1 + x];
      if (y0 != y) s += tmp[r0 + x];
      if (y1 != y) s += tmp[r2 + x];
      out[r1 + x] = s / n;
    }
  }
}

/// Scharr 梯度幅度（/16 归一化）与 |4 邻域 Laplacian|（均边界复制）
/// 单趟同算：两者邻域相同，合并省一趟索引计算。
void _scharrAndLap(
    Float64List p, int w, int h, Float64List mag, Float64List lap) {
  for (var y = 0; y < h; y++) {
    final y0 = (y > 0 ? y - 1 : 0) * w;
    final y1 = y * w;
    final y2 = (y < h - 1 ? y + 1 : h - 1) * w;
    for (var x = 0; x < w; x++) {
      final x0 = x > 0 ? x - 1 : 0;
      final x1 = x < w - 1 ? x + 1 : w - 1;
      final gx = (3 * p[y0 + x1] + 10 * p[y1 + x1] + 3 * p[y2 + x1]) -
          (3 * p[y0 + x0] + 10 * p[y1 + x0] + 3 * p[y2 + x0]);
      final gy = (3 * p[y2 + x0] + 10 * p[y2 + x] + 3 * p[y2 + x1]) -
          (3 * p[y0 + x0] + 10 * p[y0 + x] + 3 * p[y0 + x1]);
      final i = y1 + x;
      mag[i] = math.sqrt(gx * gx + gy * gy) / 16;
      lap[i] =
          (4 * p[i] - p[y1 + x0] - p[y1 + x1] - p[y0 + x] - p[y2 + x]).abs();
    }
  }
}

/// 简化相位一致性（Kovesi 局部能量形式的双尺度空间域近似）：
/// 正交对取 奇=Scharr 梯度幅度、偶=|Laplacian|，细尺度（原图）+
/// 粗尺度（3×3 模糊后）；PC = ΣE / (ΣA + ε)，E 为正交对能量、
/// A 为其幅度和。PC ∈ [0,1]，对比度缩放不变，边缘/线条/角点处高。
/// PC 写入 [pcOut]，细尺度梯度幅度写入 [gmOut]（GM 供 FSIM 的梯度项
/// 复用）；[s1]/[s2]/[s3] 为调用侧跨通道复用的工作平面。
void _pcAndGm(Float64List p, int w, int h, Float64List pcOut,
    Float64List gmOut, Float64List s1, Float64List s2, Float64List s3) {
  // gmOut = odd1（细尺度梯度幅度），s1 = even1（细尺度 |Laplacian|）。
  _scharrAndLap(p, w, h, gmOut, s1);
  // s2 = 3×3 模糊图（s3 为水平趟缓冲）。
  _boxBlur3Into(p, w, h, s2, s3);
  // pcOut 暂存 odd2，s3 转作 even2（粗尺度正交对）。
  _scharrAndLap(s2, w, h, pcOut, s3);
  for (var i = 0; i < pcOut.length; i++) {
    final e = math.sqrt(gmOut[i] * gmOut[i] + s1[i] * s1[i]) +
        math.sqrt(pcOut[i] * pcOut[i] + s3[i] * s3[i]);
    final a = gmOut[i] + s1[i] + pcOut[i] + s3[i];
    pcOut[i] = e / (a + 1e-4);
  }
}

/// 单通道 FSIM：S_L = S_PC·S_G 逐像素相乘，以 PCm = max(PC1, PC2)
/// 为权重做加权平均。两图均无特征（平坦）时分母为 0——结构项全为
/// 1，按定义返回 1.0（FSIM 对纯亮度差异不敏感，与论文行为一致）。
/// 工作平面由 [fsimRgba] 统一分配并跨通道复用（大帧下避免每通道
/// 十余个全帧平面的反复分配）。
double _fsimChannel(Float64List pa, Float64List pb, int w, int h,
    Float64List pc1, Float64List g1, Float64List pc2, Float64List g2,
    Float64List s1, Float64List s2, Float64List s3) {
  _pcAndGm(pa, w, h, pc1, g1, s1, s2, s3);
  _pcAndGm(pb, w, h, pc2, g2, s1, s2, s3);
  var num = 0.0, den = 0.0;
  for (var i = 0; i < pa.length; i++) {
    final spc = (2 * pc1[i] * pc2[i] + _kFsimT1) /
        (pc1[i] * pc1[i] + pc2[i] * pc2[i] + _kFsimT1);
    final sg = (2 * g1[i] * g2[i] + _kFsimT2) /
        (g1[i] * g1[i] + g2[i] * g2[i] + _kFsimT2);
    final pcm = math.max(pc1[i], pc2[i]);
    num += spc * sg * pcm;
    den += pcm;
  }
  return den <= 0 ? 1.0 : num / den;
}

/// FSIM（特征相似度）：两幅 RGBA8888 图（同尺寸）按 R/G/B 三通道
/// 分别计算并返回 (总体, R, G, B)；完全相同为 1.0。相位一致性 +
/// 梯度幅度对边缘与细节敏感，适合纹理丰富图像的质量评估。
/// PC 为空间域简化实现（见 [_pcAndGm]），与频域 log-Gabor 版本在
/// 边缘排序上一致、绝对值口径不同。
(double, double, double, double) fsimRgba(
    Uint8List a, Uint8List b, int width, int height) {
  if (width <= 0 || height <= 0 || a.isEmpty || b.isEmpty) {
    return (1.0, 1.0, 1.0, 1.0);
  }
  // 工作平面一次分配、跨通道复用（9 个全帧平面；此前每对通道分配 14 个全帧平面，大帧下分配/GC 开销显著）。
  final n = width * height;
  final pa = Float64List(n);
  final pb = Float64List(n);
  final pc1 = Float64List(n);
  final g1 = Float64List(n);
  final pc2 = Float64List(n);
  final g2 = Float64List(n);
  final s1 = Float64List(n);
  final s2 = Float64List(n);
  final s3 = Float64List(n);
  final perChannel = <double>[];
  for (var c = 0; c < 3; c++) {
    for (var i = 0, j = c; i < n; i++, j += 4) {
      pa[i] = a[j].toDouble();
      pb[i] = b[j].toDouble();
    }
    perChannel.add(
        _fsimChannel(pa, pb, width, height, pc1, g1, pc2, g2, s1, s2, s3));
  }
  final sr = perChannel[0];
  final sg = perChannel[1];
  final sb = perChannel[2];
  return ((sr + sg + sb) / 3, sr, sg, sb);
}

/// FSIM 单通道值（[dualMetricInIsolate] 并行路径用：子 isolate 各自
/// 提取通道平面并分配工作平面，不复用）。数值与 [fsimRgba] 的
/// per-channel 计算逐位一致（同一 _pcAndGm/_fsimChannel 调用序列）。
double _fsimChannelValue(Uint8List a, Uint8List b, int w, int h, int c) {
  final n = w * h;
  final pa = Float64List(n);
  final pb = Float64List(n);
  for (var i = 0, j = c; i < n; i++, j += 4) {
    pa[i] = a[j].toDouble();
    pb[i] = b[j].toDouble();
  }
  return _fsimChannel(pa, pb, w, h, Float64List(n), Float64List(n),
      Float64List(n), Float64List(n), Float64List(n), Float64List(n),
      Float64List(n));
}

/// 节点内并行阈值：宽×高 ≥ 1M 像素时 [dualMetricInIsolate] 在自身
/// isolate 内再起子 isolate 并行；小图走原串行路径，避免 spawn 开销
/// 超过收益。
const int _kDualMetricParallelPixels = 1 << 20;

/// 并行子 isolate 数（与 inceptionPatchFeaturesParallel 同口径：
/// 留 2 核给系统/调用侧，再限幅 8）：heavyCpuLock=2 下两路重 CPU
/// 指标各自嵌套 14 子 isolate 会在开局窗口超订 CPU（优化 7 实测
/// 教训）；PSNR/SSIM 部分和是内存带宽型任务，8 路足够吃满。
int get _dualMetricWorkers =>
    math.min(8, math.max(2, Platform.numberOfProcessors - 2));

/// PSNR 并行路径：按行带切分为多路 Isolate.run 部分和，按带序确定性
/// 合并（与串行仅浮点求和顺序不同，差异 ~1e-13 相对量级）。
Future<(double, double)> _psnrRgbaParallel(
    Uint8List a, Uint8List b, int w, int h) async {
  final nw = math.min(_dualMetricWorkers, h);
  final tasks = <Future<(double, int)>>[];
  for (var t = 0; t < nw; t++) {
    final y0 = h * t ~/ nw, y1 = h * (t + 1) ~/ nw;
    if (y0 >= y1) continue;
    tasks.add(
        Isolate.run(() => _psnrBandSum(a, b, y0 * w * 4, y1 * w * 4)));
  }
  var sum = 0.0;
  var count = 0;
  for (final (s, c) in await Future.wait(tasks)) {
    sum += s;
    count += c;
  }
  if (count == 0) return (0.0, double.infinity);
  final mse = sum / count;
  if (mse == 0) return (0.0, double.infinity);
  return (mse, 10 * math.log(255 * 255 / mse) / math.ln10);
}

/// SSIM 并行路径：按 8×8 块行带切分（块高边界对齐）多路 Isolate.run
/// 部分和，按带序确定性合并（口径与 [ssimRgba] 一致）。
Future<(double, double, double, double)> _ssimRgbaParallel(
    Uint8List a, Uint8List b, int w, int h) async {
  if (h < _kSsimBlock) return ssimRgba(a, b, w, h);
  const bh = _kSsimBlock;
  final bw = w < _kSsimBlock ? w : _kSsimBlock;
  final nb = h ~/ bh; // 块行数
  final nw = math.min(_dualMetricWorkers, nb);
  if (nw <= 1) return ssimRgba(a, b, w, h);
  final tasks = <Future<(Float64List, int)>>[];
  for (var t = 0; t < nw; t++) {
    final r0 = nb * t ~/ nw, r1 = nb * (t + 1) ~/ nw;
    if (r0 >= r1) continue;
    tasks.add(
        Isolate.run(() => _ssimBandSum(a, b, w, bw, bh, r0 * bh, r1 * bh)));
  }
  final sum = Float64List(3);
  var cnt = 0;
  for (final (s, c) in await Future.wait(tasks)) {
    sum[0] += s[0];
    sum[1] += s[1];
    sum[2] += s[2];
    cnt += c;
  }
  if (cnt == 0) return (1.0, 1.0, 1.0, 1.0);
  final sr = sum[0] / cnt;
  final sg = sum[1] / cnt;
  final sb = sum[2] / cnt;
  return ((sr + sg + sb) / 3, sr, sg, sb);
}

/// MS-SSIM 并行路径：按 R/G/B 通道三路 Isolate.run 并行，按通道序合并
/// （每通道计算与 [_msssimChannel] 串行调用逐位一致）。
Future<(double, double, double, double)> _msssimRgbaParallel(
    Uint8List a, Uint8List b, int w, int h) async {
  if (w < _kSsimBlock || h < _kSsimBlock) {
    // 与 msssimRgba 同退化口径。
    return ssimRgba(a, b, w, h);
  }
  final v = await Future.wait([
    for (var c = 0; c < 3; c++)
      Isolate.run(() => _msssimChannel(a, b, w, h, c)),
  ]);
  final sr = v[0], sg = v[1], sb = v[2];
  return ((sr + sg + sb) / 3, sr, sg, sb);
}

/// FSIM 并行路径：按 R/G/B 通道三路 Isolate.run 并行（各自分配工作
/// 平面），按通道序合并（与 [fsimRgba] 逐位一致）。
Future<(double, double, double, double)> _fsimRgbaParallel(
    Uint8List a, Uint8List b, int w, int h) async {
  final v = await Future.wait([
    for (var c = 0; c < 3; c++)
      Isolate.run(() => _fsimChannelValue(a, b, w, h, c)),
  ]);
  final sr = v[0], sg = v[1], sb = v[2];
  return ((sr + sg + sb) / 3, sr, sg, sb);
}

/// compute() 入口：双输入评价指标（PSNR/SSIM/MS-SSIM/FSIM）在后台
/// isolate 计算，避免大帧指标阻塞 UI isolate。宽×高 ≥ 1M 像素且缓冲
/// 恰为 w×h×4 时，在本 isolate 内再嵌套并行（PSNR 按行带、SSIM 按
/// 块行带、MS-SSIM/FSIM 按通道三路 Isolate.run，部分和按带/通道序
/// 确定性合并，与直接函数仅浮点求和顺序差异 ~1e-13 相对量级）；
/// 否则走原串行路径。
/// [msg] = `{'kind': 'psnr'|'ssim'|'msssim'|'fsim', 'ref': Uint8List,
/// 'test': Uint8List, 'width': int, 'height': int}`（ref/test 同尺寸，
/// 调用侧已完成降采样与尺寸校验）；返回 `{'kind': kind, ...指标}`，
/// 结果键与各指标直接调用时一致。
@pragma('vm:entry-point')
Future<Map<String, Object?>> dualMetricInIsolate(
    Map<String, Object?> msg) async {
  final kind = msg['kind'] as String;
  final ra = msg['ref'] as Uint8List;
  final ta = msg['test'] as Uint8List;
  final w = msg['width'] as int;
  final h = msg['height'] as int;
  // 并行前提：缓冲恰为 w×h×4（psnrRgba 对不等长缓冲按短者截断，并行
  // 路径只按 w×h 切带，长度不符时回退串行保证口径一致）。
  final parallel = w * h >= _kDualMetricParallelPixels &&
      ra.length == w * h * 4 &&
      ta.length == w * h * 4;
  if (kind == 'psnr') {
    final (mse, psnr) = parallel
        ? await _psnrRgbaParallel(ra, ta, w, h)
        : psnrRgba(ra, ta);
    return {'kind': kind, 'psnr': psnr, 'mse': mse};
  }
  if (kind == 'fsim') {
    final (v, fr, fg, fb) = parallel
        ? await _fsimRgbaParallel(ra, ta, w, h)
        : fsimRgba(ra, ta, w, h);
    return {'kind': kind, 'fsim': v, 'fsimR': fr, 'fsimG': fg, 'fsimB': fb};
  }
  // SSIM/MS-SSIM 共用结果键（ssim/ssimR/ssimG/ssimB）。
  final (v, sr, sg, sb) = kind == 'msssim'
      ? (parallel
          ? await _msssimRgbaParallel(ra, ta, w, h)
          : msssimRgba(ra, ta, w, h))
      : (parallel
          ? await _ssimRgbaParallel(ra, ta, w, h)
          : ssimRgba(ra, ta, w, h));
  return {'kind': kind, 'ssim': v, 'ssimR': sr, 'ssimG': sg, 'ssimB': sb};
}
