/// Pure-Dart ISP (image signal processor) math kernels:
/// Bayer / 非 Bayer CFA（RCCB/RCCG、RCCC、RYYCy、RGB-IR）/ MONO
/// RAW 帧到 RGB 图像的转换，以及 YUV/HSL 色彩空间转换。
///
/// Everything in this file is top-level and depends only on `dart:math` and
/// `dart:typed_data`, so it can run inside background isolates.
///
/// Buffer conventions:
/// - Bayer frames: `Uint16List` of length `width * height`, row-major.
/// - Intermediate RGB: `Uint16List` of length `width * height * 3`,
///   R,G,B interleaved per pixel.
/// - Final output: `Uint8List` of length `width * height * 4`, RGBA, alpha 255.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Bayer color filter array pattern (2x2 tiling).
enum BayerPattern {
  /// (0,0)=R (1,0)=G / (0,1)=G (1,1)=B
  rggb,

  /// (0,0)=B (1,0)=G / (0,1)=G (1,1)=R
  bggr,

  /// (0,0)=G (1,0)=R / (0,1)=B (1,1)=G
  grbg,

  /// (0,0)=G (1,0)=B / (0,1)=R (1,1)=G
  gbrg;

  /// Channel index at pixel (x, y): 0 = R, 1 = G, 2 = B.
  int colorAt(int x, int y) {
    final phase = ((y & 1) << 1) | (x & 1);
    switch (this) {
      case BayerPattern.rggb:
        return const [0, 1, 1, 2][phase];
      case BayerPattern.bggr:
        return const [2, 1, 1, 0][phase];
      case BayerPattern.grbg:
        return const [1, 0, 2, 1][phase];
      case BayerPattern.gbrg:
        return const [1, 2, 0, 1][phase];
    }
  }

  /// Parses a pattern name such as 'RGGB' (case-insensitive).
  /// Throws [ArgumentError] on unknown names.
  static BayerPattern fromName(String name) {
    switch (name.trim().toUpperCase()) {
      case 'RGGB':
        return BayerPattern.rggb;
      case 'BGGR':
        return BayerPattern.bggr;
      case 'GRBG':
        return BayerPattern.grbg;
      case 'GBRG':
        return BayerPattern.gbrg;
      default:
        throw ArgumentError.value(name, 'name', 'Unknown Bayer pattern');
    }
  }
}

/// How raw bytes are packed into the file buffer.
enum BayerPacking {
  /// One pixel per 16-bit word (or per byte when bitDepth == 8),
  /// data right-aligned (LSB-aligned): value = raw & mask.
  unpackedLsb,

  /// One pixel per 16-bit word, data left-aligned (MSB-aligned):
  /// value = raw >> (16 - bitDepth).
  unpackedMsb,

  /// MIPI CSI-2 packing: 10-bit -> 4 pixels per 5 bytes,
  /// 12-bit -> 2 pixels per 3 bytes.
  mipi,
}

/// Maximum sample value for a given bit depth.
int bayerMaxValue(int bitDepth) => (1 << bitDepth) - 1;

/// Number of bytes one frame occupies for the given format.
/// Used for slicing multi-frame files.
int frameByteSize({
  required int width,
  required int height,
  required int bitDepth,
  required BayerPacking packing,
}) {
  final pixels = width * height;
  switch (packing) {
    case BayerPacking.unpackedLsb:
    case BayerPacking.unpackedMsb:
      return bitDepth == 8 ? pixels : pixels * 2;
    case BayerPacking.mipi:
      if (bitDepth == 10) return (pixels * 5 + 3) ~/ 4;
      if (bitDepth == 12) return (pixels * 3 + 1) ~/ 2;
      throw ArgumentError.value(
          bitDepth, 'bitDepth', 'MIPI packing supports only 10 or 12 bits');
  }
}

/// Decodes one Bayer frame from [bytes] into a `Uint16List` of
/// length `width * height`.
///
/// Throws [ArgumentError] if the buffer region starting at [byteOffset]
/// is too small for one frame, or if the format combination is unsupported.
Uint16List unpackBayer(
  Uint8List bytes, {
  required int width,
  required int height,
  required int bitDepth,
  required BayerPacking packing,
  bool littleEndian = true,
  int byteOffset = 0,
}) {
  if (bitDepth < 1 || bitDepth > 16) {
    throw ArgumentError.value(bitDepth, 'bitDepth', 'Must be in 1..16');
  }
  final pixels = width * height;
  final needed = frameByteSize(
      width: width, height: height, bitDepth: bitDepth, packing: packing);
  if (byteOffset < 0 || bytes.length - byteOffset < needed) {
    throw ArgumentError.value(
      bytes.length - byteOffset,
      'bytes',
      'Buffer too small: need $needed bytes from offset $byteOffset '
          'for a ${width}x$height ${bitDepth}bit $packing frame',
    );
  }

  final out = Uint16List(pixels);
  switch (packing) {
    case BayerPacking.unpackedLsb:
    case BayerPacking.unpackedMsb:
      final isLsb = packing == BayerPacking.unpackedLsb;
      if (bitDepth == 8) {
        for (var i = 0; i < pixels; i++) {
          out[i] = bytes[byteOffset + i];
        }
      } else {
        final mask = bayerMaxValue(bitDepth);
        final shift = 16 - bitDepth;
        var p = byteOffset;
        for (var i = 0; i < pixels; i++, p += 2) {
          final raw = littleEndian
              ? bytes[p] | (bytes[p + 1] << 8)
              : (bytes[p] << 8) | bytes[p + 1];
          out[i] = isLsb ? raw & mask : raw >> shift;
        }
      }
    case BayerPacking.mipi:
      if (bitDepth == 10) {
        // 4 pixels per 5 bytes: 4 MSB bytes, then 1 byte holding
        // the 2 LSBs of each pixel (pixel i in bits [2i, 2i+1]).
        final groups = pixels ~/ 4;
        var p = byteOffset;
        var o = 0;
        for (var g = 0; g < groups; g++, p += 5) {
          final lsb = bytes[p + 4];
          for (var i = 0; i < 4; i++) {
            out[o++] = (bytes[p + i] << 2) | ((lsb >> (2 * i)) & 0x3);
          }
        }
        // Trailing pixels outside full groups are not expected for
        // standard sensor widths; treat as an error if present.
        if (pixels % 4 != 0) {
          throw ArgumentError.value(
              width, 'width', 'MIPI 10-bit requires width*height % 4 == 0');
        }
      } else if (bitDepth == 12) {
        // 2 pixels per 3 bytes: p0 = b0:b2[3:0], p1 = b1:b2[7:4].
        final groups = pixels ~/ 2;
        var p = byteOffset;
        var o = 0;
        for (var g = 0; g < groups; g++, p += 3) {
          out[o++] = (bytes[p] << 4) | (bytes[p + 2] & 0xF);
          out[o++] = (bytes[p + 1] << 4) | (bytes[p + 2] >> 4);
        }
        if (pixels % 2 != 0) {
          throw ArgumentError.value(
              width, 'width', 'MIPI 12-bit requires width*height % 2 == 0');
        }
      } else {
        throw ArgumentError.value(
            bitDepth, 'bitDepth', 'MIPI packing supports only 10 or 12 bits');
      }
  }
  return out;
}

/// Subtracts per-phase black level offsets in place, clamping at 0.
///
/// [r], [gr], [gb], [b] are the offsets for the four 2x2 phases:
/// R, green-on-red-row, green-on-blue-row, B.
void applyBlackLevel(
  Uint16List bayer, {
  required int width,
  required int height,
  required BayerPattern pattern,
  required double r,
  required double gr,
  required double gb,
  required double b,
}) {
  // Resolve the offset for each of the 4 phases of the 2x2 tile.
  final offsets = List<double>.filled(4, 0);
  for (var py = 0; py < 2; py++) {
    for (var px = 0; px < 2; px++) {
      final phase = (py << 1) | px;
      final color = pattern.colorAt(px, py);
      if (color == 0) {
        offsets[phase] = r;
      } else if (color == 2) {
        offsets[phase] = b;
      } else {
        // Green: gr shares its row with R, gb shares its row with B.
        offsets[phase] = pattern.colorAt(px ^ 1, py) == 0 ? gr : gb;
      }
    }
  }
  var i = 0;
  for (var y = 0; y < height; y++) {
    final rowPhase = (y & 1) << 1;
    for (var x = 0; x < width; x++, i++) {
      final v = bayer[i] - offsets[rowPhase | (x & 1)];
      bayer[i] = v <= 0 ? 0 : v.round();
    }
  }
}

/// Averages the values of neighbors of pixel (x, y) that carry channel
/// [color], considering only the given [offsets] (dx, dy pairs).
/// Falls back to the pixel's own value if no valid neighbor exists.
int _avgNeighbors(Uint16List bayer, int width, int height, int x, int y,
    BayerPattern pattern, int color, List<List<int>> offsets) {
  var sum = 0;
  var count = 0;
  for (final o in offsets) {
    final nx = x + o[0];
    final ny = y + o[1];
    if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
    if (pattern.colorAt(nx, ny) != color) continue;
    sum += bayer[ny * width + nx];
    count++;
  }
  if (count == 0) return bayer[y * width + x];
  return (sum + count ~/ 2) ~/ count;
}

const _axial = [
  [-1, 0],
  [1, 0],
  [0, -1],
  [0, 1],
];
const _diagonal = [
  [-1, -1],
  [1, -1],
  [-1, 1],
  [1, 1],
];

/// 去马赛克单通道取数计划：平均 [n] 个邻居（相对当前像素的下标增量）。
class _ChPlan {
  final int ch;
  final int n;
  final int a;
  final int b;
  final int c;
  final int d;
  const _ChPlan(this.ch, this.n, this.a, this.b, [this.c = 0, this.d = 0]);
}

/// 一个 2x2 相位的取数计划：自身通道 [own] + 两个缺失通道的邻居计划。
class _PxPlan {
  final int own;
  final _ChPlan m1;
  final _ChPlan m2;
  const _PxPlan(this.own, this.m1, this.m2);
}

/// Bilinear demosaicing of a Bayer frame into an interleaved RGB buffer
/// of length `width * height * 3`.
///
/// Each output pixel keeps the true value of its own channel; G at R/B
/// sites is the average of axial neighbors; R/B at G sites is the average
/// of the axial neighbors carrying that color; R/B at opposite (R<->B)
/// sites is the average of diagonal neighbors. Edge pixels use whatever
/// neighbors exist.
Uint16List demosaicBilinear(
  Uint16List bayer, {
  required int width,
  required int height,
  required BayerPattern pattern,
}) {
  final rgb = Uint16List(width * height * 3);
  if (width < 3 || height < 3) {
    // 没有内部像素的小图：全部走通用邻域平均。
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        _demosaicPixel(bayer, rgb, width, height, x, y, pattern);
      }
    }
    return rgb;
  }

  // 为 4 个相位预计算取数计划：内部像素无需边界检查和模式判断。
  final plans = List<_PxPlan>.generate(4, (phase) {
    final px = phase & 1;
    final py = phase >> 1;
    final own = pattern.colorAt(px, py);
    final missing = <_ChPlan>[];
    for (var c = 0; c < 3; c++) {
      if (c == own) continue;
      if (c == 1) {
        // R/B 站点缺 G：上下左右 4 邻居。
        missing.add(_ChPlan(c, 4, -1, 1, -width, width));
      } else if (own == 1) {
        // G 站点缺 R/B：该颜色的两个轴向邻居（横向或纵向）。
        missing.add(pattern.colorAt(px ^ 1, py) == c
            ? _ChPlan(c, 2, -1, 1)
            : _ChPlan(c, 2, -width, width));
      } else {
        // R 站点缺 B（或反之）：4 个对角邻居。
        missing.add(
            _ChPlan(c, 4, -width - 1, -width + 1, width - 1, width + 1));
      }
    }
    return _PxPlan(own, missing[0], missing[1]);
  });

  // 内部像素快速路径。
  for (var y = 1; y < height - 1; y++) {
    var p = y * width + 1;
    var i = p * 3;
    final rowPhase = (y & 1) << 1;
    for (var x = 1; x < width - 1; x++, p++, i += 3) {
      final plan = plans[rowPhase | (x & 1)];
      final m1 = plan.m1;
      final m2 = plan.m2;
      rgb[i + plan.own] = bayer[p];
      rgb[i + m1.ch] = m1.n == 2
          ? (bayer[p + m1.a] + bayer[p + m1.b] + 1) >> 1
          : (bayer[p + m1.a] +
                  bayer[p + m1.b] +
                  bayer[p + m1.c] +
                  bayer[p + m1.d] +
                  2) >>
              2;
      rgb[i + m2.ch] = m2.n == 2
          ? (bayer[p + m2.a] + bayer[p + m2.b] + 1) >> 1
          : (bayer[p + m2.a] +
                  bayer[p + m2.b] +
                  bayer[p + m2.c] +
                  bayer[p + m2.d] +
                  2) >>
              2;
    }
  }

  // 边缘像素（数量极少）：通用邻域平均。
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (x > 0 && x < width - 1 && y > 0 && y < height - 1) continue;
      _demosaicPixel(bayer, rgb, width, height, x, y, pattern);
    }
  }
  return rgb;
}

/// 通用路径：按邻域搜索为 (x, y) 计算三个通道（用于边缘与小图）。
void _demosaicPixel(Uint16List bayer, Uint16List rgb, int width, int height,
    int x, int y, BayerPattern pattern) {
  final i = (y * width + x) * 3;
  final own = pattern.colorAt(x, y);
  final self = bayer[y * width + x];
  for (var c = 0; c < 3; c++) {
    if (c == own) {
      rgb[i + c] = self;
    } else if (c == 1) {
      // Green at an R/B site: axial neighbors.
      rgb[i + c] = _avgNeighbors(bayer, width, height, x, y, pattern, c, _axial);
    } else if (own == 1) {
      // R or B at a G site: the two axial neighbors of that color.
      rgb[i + c] = _avgNeighbors(bayer, width, height, x, y, pattern, c, _axial);
    } else {
      // R at a B site or B at an R site: diagonal neighbors.
      rgb[i + c] =
          _avgNeighbors(bayer, width, height, x, y, pattern, c, _diagonal);
    }
  }
}

/// Gray-world auto white balance. Samples every [sampleStride] pixels and
/// returns (rGain, bGain) such that scaling R and B by those gains makes
/// their means equal the green mean.
(double, double) autoWhiteBalanceGains(Uint16List rgb, {int sampleStride = 16}) {
  final pixels = rgb.length ~/ 3;
  if (pixels == 0) return (1.0, 1.0);
  final stride = sampleStride < 1 ? 1 : sampleStride;
  var sumR = 0, sumG = 0, sumB = 0, count = 0;
  for (var p = 0; p < pixels; p += stride) {
    final i = p * 3;
    sumR += rgb[i];
    sumG += rgb[i + 1];
    sumB += rgb[i + 2];
    count++;
  }
  if (count == 0) return (1.0, 1.0);
  final meanR = sumR / count;
  final meanG = sumG / count;
  final meanB = sumB / count;
  final rGain = meanR > 0 ? meanG / meanR : 1.0;
  final bGain = meanB > 0 ? meanG / meanB : 1.0;
  return (rGain, bGain);
}

/// Applies white balance gains in place, clamping to [maxValue].
/// 实现为每通道一张 LUT（大小 maxValue+1），增益为 1 时直接跳过。
void applyWhiteBalance(
  Uint16List rgb, {
  required double rGain,
  required double bGain,
  required int maxValue,
}) {
  if (rGain == 1.0 && bGain == 1.0) return;
  Uint16List buildLut(double gain) {
    final lut = Uint16List(maxValue + 1);
    for (var v = 0; v <= maxValue; v++) {
      final x = (v * gain).round();
      lut[v] = x < 0 ? 0 : (x > maxValue ? maxValue : x);
    }
    return lut;
  }

  final lutR = buildLut(rGain);
  final lutB = buildLut(bGain);
  for (var i = 0; i < rgb.length; i += 3) {
    rgb[i] = lutR[rgb[i]];
    rgb[i + 2] = lutB[rgb[i + 2]];
  }
}

/// Applies a 3x3 row-major color correction matrix in place,
/// clamping results to 0..[maxValue]. [matrix] must have 9 elements.
/// 实现为 2^20 定点数乘法（64 位整数，不溢出）；单位矩阵直接跳过。
void applyCcm(
  Uint16List rgb, {
  required List<double> matrix,
  required int maxValue,
}) {
  if (matrix.length != 9) {
    throw ArgumentError.value(matrix.length, 'matrix', 'CCM must have 9 elements');
  }
  const scale = 1 << 20;
  const half = scale >> 1;
  final m = [for (final x in matrix) (x * scale).round()];
  // 单位矩阵（定点表示下精确判断）：无操作。
  var isIdentity = true;
  for (var i = 0; i < 9; i++) {
    if (m[i] != (i % 4 == 0 ? scale : 0)) {
      isIdentity = false;
      break;
    }
  }
  if (isIdentity) return;
  for (var i = 0; i < rgb.length; i += 3) {
    final r = rgb[i];
    final g = rgb[i + 1];
    final b = rgb[i + 2];
    var nr = (m[0] * r + m[1] * g + m[2] * b + half) >> 20;
    var ng = (m[3] * r + m[4] * g + m[5] * b + half) >> 20;
    var nb = (m[6] * r + m[7] * g + m[8] * b + half) >> 20;
    rgb[i] = nr < 0 ? 0 : (nr > maxValue ? maxValue : nr);
    rgb[i + 1] = ng < 0 ? 0 : (ng > maxValue ? maxValue : ng);
    rgb[i + 2] = nb < 0 ? 0 : (nb > maxValue ? maxValue : nb);
  }
}

/// Converts a 16-bit interleaved RGB buffer to 8-bit RGBA (alpha 255).
///
/// Per channel: normalize by [maxValue], add [brightness], apply
/// [contrast] around 0.5, gamma-encode with `pow(c, 1 / gamma)`,
/// clamp, scale to 0..255. Uses a lookup table of size [maxValue] + 1.
Uint8List tonemapToRgba(
  Uint16List rgb, {
  required int maxValue,
  required double gamma,
  double brightness = 0.0,
  double contrast = 1.0,
}) {
  if (maxValue < 1) {
    throw ArgumentError.value(maxValue, 'maxValue', 'Must be >= 1');
  }
  if (gamma <= 0) {
    throw ArgumentError.value(gamma, 'gamma', 'Must be > 0');
  }
  final lut = Uint8List(maxValue + 1);
  final invGamma = 1.0 / gamma;
  for (var v = 0; v <= maxValue; v++) {
    var c = v / maxValue;
    c += brightness;
    c = (c - 0.5) * contrast + 0.5;
    if (c < 0) c = 0;
    if (c > 1) c = 1;
    c = math.pow(c, invGamma).toDouble();
    if (c < 0) c = 0;
    if (c > 1) c = 1;
    lut[v] = (c * 255).round();
  }
  final pixels = rgb.length ~/ 3;
  final out = Uint8List(pixels * 4);
  var j = 0;
  for (var i = 0; i < rgb.length; i += 3, j += 4) {
    var r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
    if (r > maxValue) r = maxValue;
    if (g > maxValue) g = maxValue;
    if (b > maxValue) b = maxValue;
    out[j] = lut[r];
    out[j + 1] = lut[g];
    out[j + 2] = lut[b];
    out[j + 3] = 255;
  }
  return out;
}

/// ---------------------------------------------------------------------------
/// 非 Bayer CFA（RCCB/RCCG、RCCC、RYYCy、RGB-IR）与 MONO 的专用 demosaic。
///
/// 通道 id：0=R 1=G 2=B 3=C(clear 全色) 4=Y(黄) 5=Cy(青) 6=IR。
/// C ≈ R+G+B，Y ≈ R+G，Cy ≈ G+B，据此从 Clear/黄/青样本推算缺失颜色；
/// 这些推算是工程近似，不是传感器厂商的原厂算法。
/// ---------------------------------------------------------------------------

int _clampTo(num v, int maxValue) =>
    v < 0 ? 0 : (v > maxValue ? maxValue : v.round());

/// RCCB 2x2 平铺：R C / C B。
int _rccbAt(int x, int y) => const [0, 3, 3, 2][((y & 1) << 1) | (x & 1)];

/// RCCG 2x2 平铺：R C / C G。
int _rccgAt(int x, int y) => const [0, 3, 3, 1][((y & 1) << 1) | (x & 1)];

/// RCCC 2x2 平铺：R C / C C。
int _rcccAt(int x, int y) => (x & 1) == 0 && (y & 1) == 0 ? 0 : 3;

/// RYYCy 2x2 平铺：R Y / Y Cy。
int _ryycyAt(int x, int y) => const [0, 4, 4, 5][((y & 1) << 1) | (x & 1)];

/// RGB-IR 4x4 平铺（常见布局之一）：
/// ```
/// R  G  IR G
/// G  B  G  IR
/// IR G  R  G
/// G  IR G  B
/// ```
int _rgbIrAt(int x, int y) {
  const t = [
    0, 1, 6, 1, //
    1, 2, 1, 6, //
    6, 1, 0, 1, //
    1, 6, 1, 2, //
  ];
  return t[(y & 3) * 4 + (x & 3)];
}

/// 通用通道插值：平均 3x3 邻域内属于通道 [ch] 的样本，
/// 找不到时扩大到 5x5，仍没有则返回像素自身值。
int _interpChannel(Uint16List mosaic, int width, int height, int x, int y,
    int ch, int Function(int, int) channelAt) {
  for (final radius in [1, 2]) {
    var sum = 0;
    var count = 0;
    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
        if (channelAt(nx, ny) != ch) continue;
        sum += mosaic[ny * width + nx];
        count++;
      }
    }
    if (count > 0) return (sum + count ~/ 2) ~/ count;
  }
  return mosaic[y * width + x];
}

/// 取像素 (x, y) 上通道 [ch] 的值：自身携带则用真值，否则邻域插值。
int _channelAt(Uint16List mosaic, int width, int height, int x, int y,
    int ch, int Function(int, int) channelAt) {
  return channelAt(x, y) == ch
      ? mosaic[y * width + x]
      : _interpChannel(mosaic, width, height, x, y, ch, channelAt);
}

/// RCCB / RCCG demosaic。
///
/// RCCB：R、B 直接插值，G ≈ C − (R+B)/2。
/// RCCG：R、G 直接插值，B ≈ C − R − G。
Uint16List demosaicRccb(
  Uint16List mosaic, {
  required int width,
  required int height,
  bool rccg = false,
  int maxValue = 65535,
}) {
  final at = rccg ? _rccgAt : _rccbAt;
  final rgb = Uint16List(width * height * 3);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i += 3) {
      final r = _channelAt(mosaic, width, height, x, y, 0, at);
      final c = _channelAt(mosaic, width, height, x, y, 3, at);
      if (rccg) {
        final g = _channelAt(mosaic, width, height, x, y, 1, at);
        rgb[i] = r;
        rgb[i + 1] = g;
        rgb[i + 2] = _clampTo(c - r - g, maxValue);
      } else {
        final b = _channelAt(mosaic, width, height, x, y, 2, at);
        rgb[i] = r;
        rgb[i + 1] = _clampTo(c - (r + b) / 2, maxValue);
        rgb[i + 2] = b;
      }
    }
  }
  return rgb;
}

/// RCCC demosaic：只有 R 与 Clear 样本。
/// C ≈ R+G+B，在无其他信息时设 G ≈ B → G = B = (C − R)/2。
Uint16List demosaicRccc(
  Uint16List mosaic, {
  required int width,
  required int height,
  int maxValue = 65535,
}) {
  final rgb = Uint16List(width * height * 3);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i += 3) {
      final r = _channelAt(mosaic, width, height, x, y, 0, _rcccAt);
      final c = _channelAt(mosaic, width, height, x, y, 3, _rcccAt);
      final gb = _clampTo((c - r) / 2, maxValue);
      rgb[i] = r;
      rgb[i + 1] = gb;
      rgb[i + 2] = gb;
    }
  }
  return rgb;
}

/// RYYCy demosaic：Y ≈ R+G，Cy ≈ G+B。
/// G = Y − R，B = Cy − G。
Uint16List demosaicRyycy(
  Uint16List mosaic, {
  required int width,
  required int height,
  int maxValue = 65535,
}) {
  final rgb = Uint16List(width * height * 3);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i += 3) {
      final r = _channelAt(mosaic, width, height, x, y, 0, _ryycyAt);
      final yv = _channelAt(mosaic, width, height, x, y, 4, _ryycyAt);
      final cy = _channelAt(mosaic, width, height, x, y, 5, _ryycyAt);
      final g = _clampTo(yv - r, maxValue);
      rgb[i] = r;
      rgb[i + 1] = g;
      rgb[i + 2] = _clampTo(cy - g, maxValue);
    }
  }
  return rgb;
}

/// RGB-IR demosaic：R/G/B 各自从 4x4 中的采样点插值，
/// 再按 [irSubtraction]（0..1）扣除插值出的 IR 分量（近似去红外）。
Uint16List demosaicRgbIr(
  Uint16List mosaic, {
  required int width,
  required int height,
  int maxValue = 65535,
  double irSubtraction = 0.5,
}) {
  final rgb = Uint16List(width * height * 3);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i += 3) {
      final ir = _channelAt(mosaic, width, height, x, y, 6, _rgbIrAt);
      final sub = ir * irSubtraction;
      rgb[i] = _clampTo(
          _channelAt(mosaic, width, height, x, y, 0, _rgbIrAt) - sub, maxValue);
      rgb[i + 1] = _clampTo(
          _channelAt(mosaic, width, height, x, y, 1, _rgbIrAt) - sub, maxValue);
      rgb[i + 2] = _clampTo(
          _channelAt(mosaic, width, height, x, y, 2, _rgbIrAt) - sub, maxValue);
    }
  }
  return rgb;
}

/// MONO（无 CFA 黑白传感器）：单通道直接复制为 RGB 三通道。
Uint16List monoToRgb(Uint16List mosaic) {
  final rgb = Uint16List(mosaic.length * 3);
  var j = 0;
  for (var i = 0; i < mosaic.length; i++, j += 3) {
    rgb[j] = mosaic[i];
    rgb[j + 1] = mosaic[i];
    rgb[j + 2] = mosaic[i];
  }
  return rgb;
}

/// ---------------------------------------------------------------------------
/// YUV / HSL 色彩空间转换（16 位量级，与 RGB 中间格式同为三通道交织）。
/// ---------------------------------------------------------------------------

/// RGB → YUV（BT.601 全范围，16 位定点整数移位加速）：Y∈[0,maxValue]，U/V 以 maxValue/2 为零点。
Uint16List rgbToYuv(Uint16List rgb, {required int maxValue}) {
  final out = Uint16List(rgb.length);
  final half = maxValue >> 1;
  const cyR = 19595; // 0.299 * 65536
  const cyG = 38470; // 0.587 * 65536
  const cyB = 7471;  // 0.114 * 65536

  const cuR = -11058; // -0.168736 * 65536
  const cuG = -21710; // -0.331264 * 65536
  const cuB = 32768;  // 0.5 * 65536

  const cvR = 32768;  // 0.5 * 65536
  const cvG = -27439; // -0.418688 * 65536
  const cvB = -5329;  // -0.081312 * 65536

  for (var i = 0; i < rgb.length; i += 3) {
    final r = rgb[i];
    final g = rgb[i + 1];
    final b = rgb[i + 2];

    final y = (cyR * r + cyG * g + cyB * b + 32768) >> 16;
    final u = ((cuR * r + cuG * g + cuB * b + 32768) >> 16) + half;
    final v = ((cvR * r + cvG * g + cvB * b + 32768) >> 16) + half;

    out[i] = y < 0 ? 0 : (y > maxValue ? maxValue : y);
    out[i + 1] = u < 0 ? 0 : (u > maxValue ? maxValue : u);
    out[i + 2] = v < 0 ? 0 : (v > maxValue ? maxValue : v);
  }
  return out;
}

/// YUV → RGB（[rgbToYuv] 的逆变换，16 位定点整数移位加速）。
Uint16List yuvToRgb(Uint16List yuv, {required int maxValue}) {
  final out = Uint16List(yuv.length);
  final half = maxValue >> 1;
  const crV = 91881;  // 1.402 * 65536
  const cgU = -22553; // -0.344136 * 65536
  const cgV = -46801; // -0.714136 * 65536
  const cbU = 116130; // 1.772 * 65536

  for (var i = 0; i < yuv.length; i += 3) {
    final y = yuv[i];
    final u = yuv[i + 1] - half;
    final v = yuv[i + 2] - half;

    final r = y + ((crV * v + 32768) >> 16);
    final g = y + ((cgU * u + cgV * v + 32768) >> 16);
    final b = y + ((cbU * u + 32768) >> 16);

    out[i] = r < 0 ? 0 : (r > maxValue ? maxValue : r);
    out[i + 1] = g < 0 ? 0 : (g > maxValue ? maxValue : g);
    out[i + 2] = b < 0 ? 0 : (b > maxValue ? maxValue : b);
  }
  return out;
}

/// RGB → HSL：H 按 0..360° 映射到 0..maxValue，S/L 映射到 0..maxValue。
Uint16List rgbToHsl(Uint16List rgb, {required int maxValue}) {
  final out = Uint16List(rgb.length);
  final inv = 1.0 / maxValue;
  for (var i = 0; i < rgb.length; i += 3) {
    final r = rgb[i] * inv;
    final g = rgb[i + 1] * inv;
    final b = rgb[i + 2] * inv;
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
    out[i] = _clampTo(h * maxValue, maxValue);
    out[i + 1] = _clampTo(s * maxValue, maxValue);
    out[i + 2] = _clampTo(l * maxValue, maxValue);
  }
  return out;
}

double _hueToRgb(double p, double q, double t) {
  var tt = t;
  if (tt < 0) tt += 1;
  if (tt > 1) tt -= 1;
  if (tt < 1 / 6) return p + (q - p) * 6 * tt;
  if (tt < 1 / 2) return q;
  if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
  return p;
}

/// HSL → RGB（[rgbToHsl] 的逆变换）。
Uint16List hslToRgb(Uint16List hsl, {required int maxValue}) {
  final out = Uint16List(hsl.length);
  final inv = 1.0 / maxValue;
  for (var i = 0; i < hsl.length; i += 3) {
    final h = (hsl[i] * inv) % 1.0;
    final s = hsl[i + 1] * inv;
    final l = hsl[i + 2] * inv;
    double r, g, b;
    if (s == 0) {
      r = g = b = l;
    } else {
      final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      final p = 2 * l - q;
      r = _hueToRgb(p, q, h + 1 / 3);
      g = _hueToRgb(p, q, h);
      b = _hueToRgb(p, q, h - 1 / 3);
    }
    out[i] = _clampTo(r * maxValue, maxValue);
    out[i + 1] = _clampTo(g * maxValue, maxValue);
    out[i + 2] = _clampTo(b * maxValue, maxValue);
  }
  return out;
}
