/// 仪器类节点（直方图/示波器/矢量示波器）的分析计算。
///
/// 全部输入为链末端色调映射后的 RGBA8888（与预览显示同一数据），
/// 纯 Dart + dart:typed_data，可在后台 isolate 中运行。
library;

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

/// 亮度波形监视器：横轴为图像列（降采样到 [maxCols]），纵轴为亮度级
/// （BT.601 Y，0 在底）。返回 (计数表, 列数)，计数表按 级*列数+列 排列。
(Uint32List, int) waveformLuma(Uint8List rgba, int width, int height,
    {int maxCols = 512}) {
  final cols = width < maxCols ? width : maxCols;
  final counts = Uint32List(cols * kWaveformLevels);
  final colLut = _columnLut(width, cols);
  for (var y = 0; y < height; y++) {
    var i = y * width * 4;
    for (var x = 0; x < width; x++, i += 4) {
      final luma =
          (77 * rgba[i] + 150 * rgba[i + 1] + 29 * rgba[i + 2] + 128) >> 8;
      counts[luma * cols + colLut[x]]++;
    }
  }
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
/// 计数表按 级*列数+列 排列。
(Uint32List, Uint32List, Uint32List, Uint32List, int) waveformRgb(
    Uint8List rgba, int width, int height,
    {int maxCols = 512}) {
  final cols = width < maxCols ? width : maxCols;
  final r = Uint32List(cols * kWaveformLevels);
  final g = Uint32List(cols * kWaveformLevels);
  final b = Uint32List(cols * kWaveformLevels);
  final y = Uint32List(cols * kWaveformLevels);
  final colLut = _columnLut(width, cols);
  for (var yy = 0; yy < height; yy++) {
    var i = yy * width * 4;
    for (var x = 0; x < width; x++, i += 4) {
      final col = colLut[x];
      r[rgba[i] * cols + col]++;
      g[rgba[i + 1] * cols + col]++;
      b[rgba[i + 2] * cols + col]++;
      final luma =
          (77 * rgba[i] + 150 * rgba[i + 1] + 29 * rgba[i + 2] + 128) >> 8;
      y[luma * cols + col]++;
    }
  }
  return (r, g, b, y, cols);
}

/// 按需通道的波形监视器：只统计 [channels] 列出的通道（'r'/'g'/'b'/'y'），
/// 与 [waveformRgb] 同布局。播放中示波器只显示部分通道时，避免为不可见
/// 通道白做 3/4 的统计。返回 (通道→计数表, 列数)。
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
  for (var yy = 0; yy < height; yy++) {
    var i = yy * width * 4;
    for (var x = 0; x < width; x++, i += 4) {
      final col = colLut[x];
      if (r != null) r[rgba[i] * cols + col]++;
      if (g != null) g[rgba[i + 1] * cols + col]++;
      if (b != null) b[rgba[i + 2] * cols + col]++;
      if (y != null) {
        final luma =
            (77 * rgba[i] + 150 * rgba[i + 1] + 29 * rgba[i + 2] + 128) >> 8;
        y[luma * cols + col]++;
      }
    }
  }
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
/// 逐列包络（竖向迹线）在 [_drawChannelInto] 中绘制。
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
  // 竖向迹线（逐列包络）：真实示波器的电子束在相邻像素间连续移动，
  // 硬边处会扫过两列电平之间的所有中间电平；计数表只含逐像素驻留
  // 点，这里把每列与左右相邻列的最低/最高非零电平之间的空档用暗于
  // 主迹线的固定亮度（峰值的 1/32，对数刻度下约主迹线一半）填满。
  final colLo = Int32List(w);
  final colHi = Int32List(w);
  for (var x = 0; x < w; x++) {
    var lo = -1, hi = -1;
    for (var lvl = 0; lvl < h; lvl++) {
      if (counts[lvl * w + x] > 0) {
        if (lo < 0) lo = lvl;
        hi = lvl;
      }
    }
    colLo[x] = lo;
    colHi[x] = hi;
  }
  // 电子束从左邻列扫入、向右邻列扫出：列 x 的包络取自身与左右
  // 相邻列电平范围的并集（水平硬边因此在边界两列都出竖线）。
  final envLo = Int32List(w);
  final envHi = Int32List(w);
  for (var x = 0; x < w; x++) {
    var lo = colLo[x], hi = colHi[x];
    for (final nx in [x - 1, x + 1]) {
      if (nx < 0 || nx >= w || colLo[nx] < 0) continue;
      if (lo < 0 || colLo[nx] < lo) lo = colLo[nx];
      if (colHi[nx] > hi) hi = colHi[nx];
    }
    envLo[x] = lo;
    envHi[x] = hi;
  }
  final envT = lut[max > 31 ? max >> 5 : 1];
  for (var ry = 0; ry < h; ry++) {
    final srcRow = h - 1 - ry;
    for (var x = 0; x < w; x++) {
      final c = counts[srcRow * w + x];
      final int t;
      if (c == 0) {
        // 包络填充：仅 (envLo, envHi) 开区间，端点已有驻留计数。
        if (srcRow <= envLo[x] || srcRow >= envHi[x]) continue;
        t = envT;
      } else {
        t = lut[c];
      }
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
