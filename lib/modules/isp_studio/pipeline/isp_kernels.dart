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

/// 构建色调映射 LUT：normalize by [maxValue]、加 [brightness]、
/// 绕 0.5 施加 [contrast]、`pow(c, 1 / gamma)`、钳位后映射到 0..255。
Uint8List _tonemapLut(
    int maxValue, double gamma, double brightness, double contrast) {
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
  return lut;
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
  final lut = _tonemapLut(maxValue, gamma, brightness, contrast);
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

/// MONO 灰度（w*h 单通道，16 位量级）→ 8 位 RGBA：与 [tonemapToRgba]
/// 同一 LUT，单通道每像素一次查表，比「先扩展为三通道灰度再逐通道
/// 查表」少一趟全帧写读与两次查表。
Uint8List monoToRgba(
  Uint16List mono, {
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
  final lut = _tonemapLut(maxValue, gamma, brightness, contrast);
  final out = Uint8List(mono.length * 4);
  var j = 0;
  for (var i = 0; i < mono.length; i++, j += 4) {
    var v = mono[i];
    if (v > maxValue) v = maxValue;
    final t = lut[v];
    out[j] = t;
    out[j + 1] = t;
    out[j + 2] = t;
    out[j + 3] = 255;
  }
  return out;
}

/// 8 位 MONO 平面（视频 yuv444p 直出的 Y/U/V 平面视图）→ 8 位 RGBA：
/// 256 项 LUT 一趟查表，全分辨率视频分路预览的高速路径。
Uint8List mono8ToRgba(  Uint8List mono, {
  double gamma = 1.0,
  double brightness = 0.0,
  double contrast = 1.0,
}) {
  final lut = _tonemapLut(255, gamma, brightness, contrast);
  final out = Uint8List(mono.length * 4);
  var j = 0;
  for (var i = 0; i < mono.length; i++, j += 4) {
    final t = lut[mono[i]];
    out[j] = t;
    out[j + 1] = t;
    out[j + 2] = t;
    out[j + 3] = 255;
  }
  return out;
}

/// 平面 YUV444 8 位（三个 w*h 平面）→ 8 位 RGBA 一趟完成：定点
/// BT.601 全范围转换 + 色调 LUT，免去 16 位交织中间格式的全部
/// 写读（全分辨率视频 YUV 链末端的高速路径）。
Uint8List yuv444p8ToRgba(
  List<Uint8List> planes,
  int width,
  int height, {
  double gamma = 1.0,
  double brightness = 0.0,
  double contrast = 1.0,
}) {
  final lut = _tonemapLut(255, gamma, brightness, contrast);
  final yPlane = planes[0];
  final uPlane = planes[1];
  final vPlane = planes[2];
  const crV = 91881;  // 1.402 * 65536
  const cgU = -22553; // -0.344136 * 65536
  const cgV = -46801; // -0.714136 * 65536
  const cbU = 116130; // 1.772 * 65536
  final pixels = width * height;
  final out = Uint8List(pixels * 4);
  var j = 0;
  for (var i = 0; i < pixels; i++, j += 4) {
    final y = yPlane[i];
    final u = uPlane[i] - 128;
    final v = vPlane[i] - 128;
    var r = y + ((crV * v + 32768) >> 16);
    var g = y + ((cgU * u + cgV * v + 32768) >> 16);
    var b = y + ((cbU * u + 32768) >> 16);
    r = r < 0 ? 0 : (r > 255 ? 255 : r);
    g = g < 0 ? 0 : (g > 255 ? 255 : g);
    b = b < 0 ? 0 : (b > 255 ? 255 : b);
    out[j] = lut[r];
    out[j + 1] = lut[g];
    out[j + 2] = lut[b];
    out[j + 3] = 255;
  }
  return out;
}

/// limited(tv)→full(pc) 8 位范围扩展 LUT。[chroma] 为 true 时以 128
/// 为零点（U/V 平面），否则按亮度（Y 平面）扩展。
Uint8List limitedToFullLut8({bool chroma = false}) {
  final lut = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    final v = chroma
        ? ((i - 128) * 255 / 224 + 128).round()
        : ((i - 16) * 255 / 219).round();
    lut[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
  }
  return lut;
}

/// yuv420p 缓冲（Y 平面 w*h，U/V 平面各 (w/2)*(h/2) 顺序排列）→
/// 步长抽样的小尺寸 RGBA。仪器馈源用：统计类计算不需要全分辨率，
/// 读取量与输出尺寸成正比。[limited] 为 true 时做 tv→pc 范围扩展
/// （与 yuv_planes.frag 的显示一致）。
Uint8List yuv420p8ToRgbaStep(Uint8List src, int w, int h, int step,
    {bool limited = false}) {
  final outW = w ~/ step;
  final outH = h ~/ step;
  final cw = w >> 1;
  final uBase = w * h;
  final vBase = uBase + cw * (h >> 1);
  final yLut = limited ? limitedToFullLut8() : null;
  final cLut = limited ? limitedToFullLut8(chroma: true) : null;
  const crV = 91881;  // 1.402 * 65536
  const cgU = -22553; // -0.344136 * 65536
  const cgV = -46801; // -0.714136 * 65536
  const cbU = 116130; // 1.772 * 65536
  final out = Uint8List(outW * outH * 4);
  var j = 0;
  for (var y0 = 0; y0 < outH; y0++) {
    final sy = y0 * step;
    final yRow = sy * w;
    final cRow = (sy >> 1) * cw;
    for (var x0 = 0; x0 < outW; x0++, j += 4) {
      final sx = x0 * step;
      var y = src[yRow + sx];
      var u = src[uBase + cRow + (sx >> 1)];
      var v = src[vBase + cRow + (sx >> 1)];
      if (yLut != null) {
        y = yLut[y];
        u = cLut![u];
        v = cLut[v];
      }
      final uu = u - 128;
      final vv = v - 128;
      var r = y + ((crV * vv + 32768) >> 16);
      var g = y + ((cgU * uu + cgV * vv + 32768) >> 16);
      var b = y + ((cbU * uu + 32768) >> 16);
      out[j] = r < 0 ? 0 : (r > 255 ? 255 : r);
      out[j + 1] = g < 0 ? 0 : (g > 255 ? 255 : g);
      out[j + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
      out[j + 3] = 255;
    }
  }
  return out;
}

/// yuv420p 缓冲的 [planeIdx] 平面（0=Y, 1=U, 2=V；chroma 平面尺寸
/// 减半）→ 步长抽样的小尺寸灰度 RGBA（分路预览的仪器馈源）。
/// [limited] 为 true 时做 tv→pc 范围扩展。
Uint8List yuv420pPlaneToRgbaStep(
    Uint8List src, int w, int h, int planeIdx, int step,
    {bool limited = false}) {
  final isLuma = planeIdx == 0;
  final pw = isLuma ? w : w >> 1;
  final ph = isLuma ? h : h >> 1;
  final base = isLuma ? 0 : (w * h + (planeIdx - 1) * pw * ph);
  final outW = pw ~/ step;
  final outH = ph ~/ step;
  final lut = limited ? limitedToFullLut8(chroma: !isLuma) : null;
  final out = Uint8List(outW * outH * 4);
  var j = 0;
  for (var y0 = 0; y0 < outH; y0++) {
    var si = base + y0 * step * pw;
    for (var x0 = 0; x0 < outW; x0++, si += step, j += 4) {
      var v = src[si];
      if (lut != null) v = lut[v];
      out[j] = v;
      out[j + 1] = v;
      out[j + 2] = v;
      out[j + 3] = 255;
    }
  }
  return out;
}

/// YUV（16 位量级交织）→ 8 位 RGBA 一趟完成：定点 yuvToRgb + 色调
/// LUT，免去 [yuvToRgb] 与 [tonemapToRgba] 分趟时的中间 RGB 缓冲
/// 写读（链末端 YUV 输出的高速路径）。
Uint8List yuvToRgba(
  Uint16List yuv, {
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
  final lut = _tonemapLut(maxValue, gamma, brightness, contrast);
  final half = maxValue >> 1;
  const crV = 91881;  // 1.402 * 65536
  const cgU = -22553; // -0.344136 * 65536
  const cgV = -46801; // -0.714136 * 65536
  const cbU = 116130; // 1.772 * 65536
  final pixels = yuv.length ~/ 3;
  final out = Uint8List(pixels * 4);
  var i = 0, j = 0;
  for (var p = 0; p < pixels; p++, i += 3, j += 4) {
    final y = yuv[i];
    final u = yuv[i + 1] - half;
    final v = yuv[i + 2] - half;
    var r = y + ((crV * v + 32768) >> 16);
    var g = y + ((cgU * u + cgV * v + 32768) >> 16);
    var b = y + ((cbU * u + 32768) >> 16);
    r = r < 0 ? 0 : (r > maxValue ? maxValue : r);
    g = g < 0 ? 0 : (g > maxValue ? maxValue : g);
    b = b < 0 ? 0 : (b > maxValue ? maxValue : b);
    out[j] = lut[r];
    out[j + 1] = lut[g];
    out[j + 2] = lut[b];
    out[j + 3] = 255;
  }
  return out;
}

/// 连续播放高速预览降采样（2x）：将 8 位 RGBA (w x h) 快速降采样为 (w/2 x h/2)。
/// 算法为超高速步长采样，全帧 1080p 仅需 ~1.5 毫秒。
(Uint8List, int, int) downsampleRgba82x(Uint8List src, int w, int h) {
  final outW = w >> 1;
  final outH = h >> 1;
  final dst = Uint8List(outW * outH * 4);
  final srcStride2 = w * 8; // (w * 4) * 2
  var dstIdx = 0;
  var srcRow = 0;
  for (var y = 0; y < outH; y++, srcRow += srcStride2) {
    var srcIdx = srcRow;
    for (var x = 0; x < outW; x++, srcIdx += 8, dstIdx += 4) {
      dst[dstIdx] = src[srcIdx];
      dst[dstIdx + 1] = src[srcIdx + 1];
      dst[dstIdx + 2] = src[srcIdx + 2];
      dst[dstIdx + 3] = src[srcIdx + 3];
    }
  }
  return (dst, outW, outH);
}

/// 步长抽样降采样（RGBA8888）：一趟把 (w, h) 抽成 (w/step, h/step)。
/// 仪器分析输入用：多级 2x 降采样的第一级要读全帧（4K ≈ 33MB），
/// 改为按最终倍率点采样后，读取量与输出尺寸成正比。
(Uint8List, int, int) downsampleRgba8Step(
    Uint8List src, int w, int h, int step) {
  if (step <= 1) return (src, w, h);
  final outW = w ~/ step;
  final outH = h ~/ step;
  final dst = Uint8List(outW * outH * 4);
  final rowStride = w * 4;
  final colStep = step * 4;
  var dstIdx = 0;
  var srcRow = 0;
  for (var y = 0; y < outH; y++, srcRow += rowStride * step) {
    var srcIdx = srcRow;
    for (var x = 0; x < outW; x++, srcIdx += colStep, dstIdx += 4) {
      dst[dstIdx] = src[srcIdx];
      dst[dstIdx + 1] = src[srcIdx + 1];
      dst[dstIdx + 2] = src[srcIdx + 2];
      dst[dstIdx + 3] = src[srcIdx + 3];
    }
  }
  return (dst, outW, outH);
}

/// 连续播放高速预览降采样（2x）：平面 yuv444p（w*h*3，Y/U/V 三个 w*h
/// 平面顺序排列）快速降采样为 (w/2 x h/2)，与 [downsampleRgba82x]
/// 同为超高速步长采样。
(Uint8List, int, int) downsampleYuv444p2x(Uint8List src, int w, int h) {  final outW = w >> 1;
  final outH = h >> 1;
  final plane = w * h;
  final outPlane = outW * outH;
  final dst = Uint8List(outPlane * 3);
  final rowStep = w * 2;
  for (var p = 0; p < 3; p++) {
    final srcBase = p * plane;
    final dstBase = p * outPlane;
    var srcRow = 0;
    for (var y = 0; y < outH; y++, srcRow += rowStep) {
      var srcIdx = srcBase + srcRow;
      var dstIdx = dstBase + y * outW;
      for (var x = 0; x < outW; x++, srcIdx += 2, dstIdx++) {
        dst[dstIdx] = src[srcIdx];
      }
    }
  }
  return (dst, outW, outH);
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

/// 平面 YUV444 8 位（ffmpeg `-pix_fmt yuv444p` 直出，长度 w*h*3，
/// Y/U/V 三个 w*h 平面顺序排列）→ 16 位量级交织 YUV（w*h*3）。
/// 8 位样本按比例放大到 [maxValue]；maxValue==255（视频源默认
/// bitDepth=8）时为纯交织拷贝。视频流式播放时由该函数一跳完成
/// 「解码帧 → YUV 中间格式」，免去 RGBA→RGB16→YUV 两道全帧转换。
Uint16List yuv444p8ToYuv16(
    Uint8List planes, int width, int height, int maxValue) {
  final pixels = width * height;
  final out = Uint16List(pixels * 3);
  final uBase = pixels;
  final vBase = pixels * 2;
  if (maxValue == 255) {
    var j = 0;
    for (var i = 0; i < pixels; i++, j += 3) {
      out[j] = planes[i];
      out[j + 1] = planes[uBase + i];
      out[j + 2] = planes[vBase + i];
    }
  } else {
    final scale = maxValue / 255;
    var j = 0;
    for (var i = 0; i < pixels; i++, j += 3) {
      out[j] = (planes[i] * scale).round();
      out[j + 1] = (planes[uBase + i] * scale).round();
      out[j + 2] = (planes[vBase + i] * scale).round();
    }
  }
  return out;
}

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

/// ---------------------------------------------------------------------------
/// ICG 荧光内窥镜方案的 ISP 核（W06–W36 / N06–N40 / R01–R15 的简化实现，
/// 见 IspFlow/双传感器并行ICG荧光内窥镜ISP的FPGA实现方案.pdf）。
///
/// RAW 域算子同时支持两种输入：
/// - Bayer 马赛克：[pattern] 非空，邻域按同相位（±2 步进）取样；
/// - 16 位 MONO：[pattern] 为 null，邻域按全像素（±1 步进）取样。
/// ---------------------------------------------------------------------------

/// 收集 (x, y) 的处理邻域下标：mono（[pattern] 为 null）取 3x3 全像素
/// 8 邻域，Bayer 取同相位（±2 步进）最多 8 邻域。
List<int> _phaseNeighbors(
    int width, int height, int x, int y, BayerPattern? pattern) {
  final idx = <int>[];
  final step = pattern == null ? 1 : 2;
  for (var dy = -step; dy <= step; dy += step) {
    for (var dx = -step; dx <= step; dx += step) {
      if (dx == 0 && dy == 0) continue;
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
      idx.add(ny * width + nx);
    }
  }
  return idx;
}

List<int> _sortedValues(Uint16List buf, List<int> idx) {
  final vals = [for (final i in idx) buf[i]]..sort();
  return vals;
}

/// 坏点校正（W06/W07、N06–N09）：与同相位（mono 为全像素）3x3 邻域
/// 中位数比较，离群超过 [threshold]（满量程百分比）即判定为坏点。
/// [mode] 为 'median' 时用邻域中位数替换；为 'directional' 时沿梯度
/// 最小的方向取两点平均替换（保边更好）。
void applyDpc(
  Uint16List buf, {
  required int width,
  required int height,
  BayerPattern? pattern,
  double threshold = 5.0,
  String mode = 'median',
  int maxValue = 65535,
}) {
  final thr = threshold / 100 * maxValue;
  final directional = mode == 'directional';
  final step = pattern == null ? 1 : 2;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      final neigh = _phaseNeighbors(width, height, x, y, pattern);
      if (neigh.isEmpty) continue;
      final vals = _sortedValues(buf, neigh);
      final med = vals[vals.length ~/ 2];
      if ((buf[i] - med).abs() <= thr) continue;
      if (!directional) {
        buf[i] = med;
        continue;
      }
      // 方向插值：4 个方向各取一对对称点，选两点差最小（梯度最小）的。
      var best = -1;
      var bestDiff = 1 << 62;
      const dirs = [
        [1, 0], // 水平
        [0, 1], // 垂直
        [1, 1], // 主对角
        [1, -1], // 副对角
      ];
      for (final d in dirs) {
        final ax = x - d[0] * step, ay = y - d[1] * step;
        final bx = x + d[0] * step, by = y + d[1] * step;
        if (ax < 0 || ax >= width || ay < 0 || ay >= height) continue;
        if (bx < 0 || bx >= width || by < 0 || by >= height) continue;
        final va = buf[ay * width + ax];
        final vb = buf[by * width + bx];
        final diff = (va - vb).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          best = (va + vb + 1) >> 1;
        }
      }
      buf[i] = best >= 0 ? best : med;
    }
  }
}

int _medianOf(List<int> vals) {
  if (vals.isEmpty) return 0;
  vals.sort();
  return vals[vals.length ~/ 2];
}

/// FPN 校正（W08–W11、N10–N13）：行/列固定图案噪声的稳健估计与扣除。
///
/// 直接用"行/列中值 − 全图中值"会把图像内容（竖条/横条纹理）当成
/// FPN——整列暗条会被抬亮 maxCorr，画面发花。这里按文档要求做估计与
/// 施加分离、并加边缘掩膜：
/// 1. 低通分离内容：行偏移估计前先做垂直滑窗均值（竖条等列方向内容
///    结构保留在低频里，逐行 FPN 被平滑掉），残差 = 原图 − 低通；
/// 2. 残差行中位数即行偏移的稳健估计；
/// 3. 边缘掩膜：梯度超过 2*[maxCorr] 的像素邻域（按 [radius] 膨胀，
///    覆盖低通窗的污染范围）不参与统计，防止内容边缘被当作 FPN；
/// 4. 校正量限幅 ±[maxCorr]，扣除后截零。
/// 列方向同理（水平低通 + 水平梯度掩膜）。[pattern] 仅作文档化参数
/// （行/列统计不区分相位）。
void applyFpn(
  Uint16List buf, {
  required int width,
  required int height,
  BayerPattern? pattern,
  bool row = true,
  bool col = true,
  double maxCorr = 64,
  int radius = 8,
}) {
  if (!row && !col) return;
  double clampCorr(num c) =>
      c < -maxCorr ? -maxCorr : (c > maxCorr ? maxCorr : c).toDouble();
  final edgeThresh = 2 * maxCorr; // 超过它的梯度视为内容边缘而非 FPN
  final res = <int>[];
  if (row) {
    final low = _verticalBoxMean(buf, width, height, radius);
    // 水平边缘（垂直梯度）的垂直膨胀掩膜：这些像素的垂直低通被边缘
    // 污染，不参与行统计。
    final mask = _dilateMask(
        _gradientEdge(buf, width, height, edgeThresh, vertical: true),
        width, height, radius,
        vertical: true);
    for (var y = 0; y < height; y++) {
      res.clear();
      final base = y * width;
      for (var x = 0; x < width; x++) {
        if (mask[base + x] != 0) continue;
        res.add(buf[base + x] - low[base + x].round());
      }
      final corr = clampCorr(_medianOf(res));
      if (corr == 0) continue;
      for (var x = 0; x < width; x++) {
        final i = base + x;
        final v = buf[i] - corr;
        buf[i] = v <= 0 ? 0 : v.round();
      }
    }
  }
  if (col) {
    final low = _horizontalBoxMean(buf, width, height, radius);
    final mask = _dilateMask(
        _gradientEdge(buf, width, height, edgeThresh, vertical: false),
        width, height, radius,
        vertical: false);
    for (var x = 0; x < width; x++) {
      res.clear();
      for (var y = 0; y < height; y++) {
        if (mask[y * width + x] != 0) continue;
        res.add(buf[y * width + x] - low[y * width + x].round());
      }
      final corr = clampCorr(_medianOf(res));
      if (corr == 0) continue;
      for (var y = 0; y < height; y++) {
        final i = y * width + x;
        final v = buf[i] - corr;
        buf[i] = v <= 0 ? 0 : v.round();
      }
    }
  }
}

/// 梯度边缘图：vertical=true 检测水平边缘（垂直方向梯度超过 [thresh]）。
Uint8List _gradientEdge(Uint16List buf, int w, int h, double thresh,
    {required bool vertical}) {
  final out = Uint8List(w * h);
  if (vertical) {
    for (var y = 1; y < h - 1; y++) {
      final base = y * w;
      for (var x = 0; x < w; x++) {
        if ((buf[base + w + x] - buf[base - w + x]).abs() > thresh) {
          out[base + x] = 1;
        }
      }
    }
  } else {
    for (var y = 0; y < h; y++) {
      final base = y * w;
      for (var x = 1; x < w - 1; x++) {
        if ((buf[base + x + 1] - buf[base + x - 1]).abs() > thresh) {
          out[base + x] = 1;
        }
      }
    }
  }
  return out;
}

/// 边缘图按 [radius] 做滑窗膨胀（vertical=true 沿垂直方向）。
Uint8List _dilateMask(Uint8List edge, int w, int h, int radius,
    {required bool vertical}) {
  final out = Uint8List(w * h);
  if (vertical) {
    for (var x = 0; x < w; x++) {
      var cnt = 0;
      for (var y = 0; y <= radius && y < h; y++) {
        cnt += edge[y * w + x];
      }
      for (var y = 0; y < h; y++) {
        out[y * w + x] = cnt > 0 ? 1 : 0;
        final add = y + radius + 1;
        final del = y - radius;
        if (add < h) cnt += edge[add * w + x];
        if (del >= 0) cnt -= edge[del * w + x];
      }
    }
  } else {
    var rowBase = 0;
    for (var y = 0; y < h; y++, rowBase += w) {
      var cnt = 0;
      for (var x = 0; x <= radius && x < w; x++) {
        cnt += edge[rowBase + x];
      }
      for (var x = 0; x < w; x++) {
        out[rowBase + x] = cnt > 0 ? 1 : 0;
        final add = x + radius + 1;
        final del = x - radius;
        if (add < w) cnt += edge[rowBase + add];
        if (del >= 0) cnt -= edge[rowBase + del];
      }
    }
  }
  return out;
}

/// 垂直方向滑窗盒式均值（每列独立，窗口 [y-radius, y+radius] 截断）。
Float32List _verticalBoxMean(Uint16List buf, int w, int h, int radius) {
  final out = Float32List(w * h);
  for (var x = 0; x < w; x++) {
    var sum = 0, count = 0;
    for (var y = 0; y <= radius && y < h; y++) {
      sum += buf[y * w + x];
      count++;
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = sum / count;
      final add = y + radius + 1;
      final del = y - radius;
      if (add < h) {
        sum += buf[add * w + x];
        count++;
      }
      if (del >= 0) {
        sum -= buf[del * w + x];
        count--;
      }
    }
  }
  return out;
}

/// 水平方向滑窗盒式均值（每行独立，窗口 [x-radius, x+radius] 截断）。
Float32List _horizontalBoxMean(Uint16List buf, int w, int h, int radius) {
  final out = Float32List(w * h);
  var rowBase = 0;
  for (var y = 0; y < h; y++, rowBase += w) {
    var sum = 0, count = 0;
    for (var x = 0; x <= radius && x < w; x++) {
      sum += buf[rowBase + x];
      count++;
    }
    for (var x = 0; x < w; x++) {
      out[rowBase + x] = sum / count;
      final add = x + radius + 1;
      final del = x - radius;
      if (add < w) {
        sum += buf[rowBase + add];
        count++;
      }
      if (del >= 0) {
        sum -= buf[rowBase + del];
        count--;
      }
    }
  }
  return out;
}

/// 镜头阴影/平场校正（W12–W14、N14–N16）：以 ([centerX], [centerY])
/// （归一化 0..1）为中心的径向二次增益曲面，增益 = 1 + strength*(r/rmax)²，
/// 边缘亮中心暗，饱和截位到 [maxValue]。增益与相位无关，Bayer/mono 通用。
void applyLsc(
  Uint16List buf, {
  required int width,
  required int height,
  BayerPattern? pattern,
  double strength = 0.5,
  double centerX = 0.5,
  double centerY = 0.5,
  int maxValue = 65535,
}) {
  if (strength == 0) return;
  final cx = centerX * (width - 1);
  final cy = centerY * (height - 1);
  final ex = math.max(cx, width - 1 - cx);
  final ey = math.max(cy, height - 1 - cy);
  final rMax2 = ex * ex + ey * ey;
  if (rMax2 <= 0) return;
  var i = 0;
  for (var y = 0; y < height; y++) {
    final dy = y - cy;
    for (var x = 0; x < width; x++, i++) {
      final dx = x - cx;
      final gain = 1 + strength * (dx * dx + dy * dy) / rMax2;
      buf[i] = _clampTo(buf[i] * gain, maxValue);
    }
  }
}

/// Gr/Gb 均衡（W15）：统计两个绿色通道相位（Gr 与 R 同行、Gb 与 B
/// 同行）的全局均值，向两者中点按 [strength] 比例收敛，消除迷宫伪影。
void applyGrGbBalance(
  Uint16List buf, {
  required int width,
  required int height,
  required BayerPattern pattern,
  double strength = 1.0,
}) {
  if (strength <= 0) return;
  var sumGr = 0, cntGr = 0, sumGb = 0, cntGb = 0;
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i++) {
      if (pattern.colorAt(x, y) != 1) continue;
      if (pattern.colorAt(x ^ 1, y) == 0) {
        sumGr += buf[i];
        cntGr++;
      } else {
        sumGb += buf[i];
        cntGb++;
      }
    }
  }
  if (cntGr == 0 || cntGb == 0) return;
  final meanGr = sumGr / cntGr;
  final meanGb = sumGb / cntGb;
  if (meanGr <= 0 || meanGb <= 0) return;
  final target = (meanGr + meanGb) / 2;
  final gainGr = 1 + (target / meanGr - 1) * strength;
  final gainGb = 1 + (target / meanGb - 1) * strength;
  i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i++) {
      if (pattern.colorAt(x, y) != 1) continue;
      final gain = pattern.colorAt(x ^ 1, y) == 0 ? gainGr : gainGb;
      buf[i] = _clampTo(buf[i] * gain, 65535);
    }
  }
}

/// Bayer 降噪（W16/W17、N24/N25）：同相位 3x3 保边加权平均，权重
/// 1/(1+(Δ/σ)²)，σ 来自 σ²=aI+b 噪声模型（取 a=1、b=64，σ=√(I+64)），
/// [strength] 为 σ 的倍率（0 = 关闭）。mono（pattern 为 null）时全像素。
void applyBayerDenoise(
  Uint16List buf, {
  required int width,
  required int height,
  BayerPattern? pattern,
  double strength = 1.0,
}) {
  if (strength <= 0) return;
  final src = Uint16List.fromList(buf);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      final v = src[i];
      final sigma = strength * math.sqrt(v + 64);
      var sum = v.toDouble();
      var wsum = 1.0;
      for (final n in _phaseNeighbors(width, height, x, y, pattern)) {
        final d = src[n] - v;
        final w = 1 / (1 + (d / sigma) * (d / sigma));
        sum += w * src[n];
        wsum += w;
      }
      buf[i] = (sum / wsum).round();
    }
  }
}

/// 高光恢复（W18/W19）：
/// - 'recover'：达到膝点（[knee]×[maxValue]）的饱和像素用同相位未饱和
///   邻域均值重建（无可用邻域则保持原值）；
/// - 'clip'：膝点以上做软压缩，平滑收敛到 [maxValue]，避免硬切色块。
void applyHighlightRecovery(
  Uint16List buf, {
  required int width,
  required int height,
  BayerPattern? pattern,
  int maxValue = 65535,
  String mode = 'recover',
  double knee = 0.9,
}) {
  final kneePt = knee.clamp(0.0, 1.0) * maxValue;
  if (mode == 'clip') {
    final range = maxValue - kneePt;
    if (range <= 0) return;
    for (var i = 0; i < buf.length; i++) {
      final v = buf[i];
      if (v <= kneePt) continue;
      final d = v - kneePt;
      buf[i] = (kneePt + d * range / (range + d)).round();
    }
    return;
  }
  final src = Uint16List.fromList(buf);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (src[i] < kneePt) continue;
      var sum = 0, count = 0;
      for (final n in _phaseNeighbors(width, height, x, y, pattern)) {
        if (src[n] >= kneePt) continue;
        sum += src[n];
        count++;
      }
      if (count > 0) buf[i] = (sum + count ~/ 2) ~/ count;
    }
  }
}

/// RGB 降噪（W29–W31）：转 YUV 后亮度做 3x3 保边加权平均（权重同
/// [applyBayerDenoise] 的 σ 模型，[luma] 为倍率），色度做 3x3 盒式
/// 低通并按 [chroma]（0..1）混合，再转回 RGB 写回原缓冲。
void applyRgbDenoise(
  Uint16List rgb, {
  required int width,
  required int height,
  double luma = 1.0,
  double chroma = 0.5,
  int maxValue = 65535,
}) {
  if (luma <= 0 && chroma <= 0) return;
  final yuv = rgbToYuv(rgb, maxValue: maxValue);
  final pixels = width * height;
  if (luma > 0) {
    final ys = Uint16List(pixels);
    for (var p = 0; p < pixels; p++) {
      ys[p] = yuv[p * 3];
    }
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final p = y * width + x;
        final v = ys[p];
        final sigma = luma * math.sqrt(v + 64);
        var sum = v.toDouble();
        var wsum = 1.0;
        for (final n in _phaseNeighbors(width, height, x, y, null)) {
          final d = ys[n] - v;
          final w = 1 / (1 + (d / sigma) * (d / sigma));
          sum += w * ys[n];
          wsum += w;
        }
        yuv[p * 3] = _clampTo(sum / wsum, maxValue);
      }
    }
  }
  if (chroma > 0) {
    final blend = chroma.clamp(0.0, 1.0);
    final src = Uint16List.fromList(yuv);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final p = y * width + x;
        for (final c in [1, 2]) {
          var sum = 0, count = 0;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              final nx = x + dx, ny = y + dy;
              if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
              sum += src[(ny * width + nx) * 3 + c];
              count++;
            }
          }
          final avg = sum / count;
          yuv[p * 3 + c] =
              _clampTo(src[p * 3 + c] * (1 - blend) + avg * blend, maxValue);
        }
      }
    }
  }
  rgb.setAll(0, yuvToRgb(yuv, maxValue: maxValue));
}

/// 锐化（W32–W34）：亮度 unsharp mask——detail = Y − 3x3 盒式模糊，
/// |detail| < [threshold] 视为噪声置零，Y' = Y + amount×detail，
/// 三通道按 Y'/Y 等比缩放并截位到 [maxValue]。
void applySharpen(
  Uint16List rgb, {
  required int width,
  required int height,
  double amount = 0.5,
  double threshold = 4.0,
  int maxValue = 65535,
}) {
  if (amount == 0) return;
  final pixels = width * height;
  final ys = Uint16List(pixels);
  for (var p = 0; p < pixels; p++) {
    final i = p * 3;
    ys[p] = (19595 * rgb[i] + 38470 * rgb[i + 1] + 7471 * rgb[i + 2] + 32768) >>
        16;
  }
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      final v = ys[p];
      var sum = 0, count = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          sum += ys[ny * width + nx];
          count++;
        }
      }
      var detail = v - sum / count;
      if (detail.abs() < threshold) detail = 0;
      if (detail == 0 || v <= 0) continue;
      final y2 = (v + amount * detail).clamp(0.0, maxValue.toDouble());
      final scale = y2 / v;
      final i = p * 3;
      rgb[i] = _clampTo(rgb[i] * scale, maxValue);
      rgb[i + 1] = _clampTo(rgb[i + 1] * scale, maxValue);
      rgb[i + 2] = _clampTo(rgb[i + 2] * scale, maxValue);
    }
  }
}

/// RGB → YUV 色彩空间转换（W36）：[standard] 为 'bt601'/'bt709' 定点
/// 矩阵，[range] 为 'full'（全范围）/'limited'（tv 范围：Y 16..235、
/// C 16..240 按 255 标度折算到 [maxValue] 量级）。
Uint16List convertRgbToYuvCsc(
  Uint16List rgb, {
  required int width,
  required int height,
  String standard = 'bt601',
  String range = 'full',
  int maxValue = 65535,
}) {
  if (standard != 'bt709' && range == 'full') {
    return rgbToYuv(rgb, maxValue: maxValue);
  }
  // BT.601 全范围系数（与 rgbToYuv 一致）。
  var cyR = 19595, cyG = 38470, cyB = 7471;
  var cuR = -11058, cuG = -21710, cuB = 32768;
  var cvR = 32768, cvG = -27439, cvB = -5329;
  if (standard == 'bt709') {
    cyR = 13933; // 0.2126 * 65536
    cyG = 46871; // 0.7152 * 65536
    cyB = 4732;  // 0.0722 * 65536
    cuR = -7509;  // -0.1146 * 65536
    cuG = -25260; // -0.3854 * 65536
    cvG = -29759; // -0.4542 * 65536
    cvB = -3009;  // -0.0458 * 65536
  }
  final limited = range == 'limited';
  final half = maxValue >> 1;
  final offY = (maxValue * 16 + 127) ~/ 255;
  final out = Uint16List(rgb.length);
  for (var i = 0; i < rgb.length; i += 3) {
    final r = rgb[i];
    final g = rgb[i + 1];
    final b = rgb[i + 2];
    var y = (cyR * r + cyG * g + cyB * b + 32768) >> 16;
    var u = ((cuR * r + cuG * g + cuB * b + 32768) >> 16) + half;
    var v = ((cvR * r + cvG * g + cvB * b + 32768) >> 16) + half;
    if (limited) {
      y = offY + (y * 219 + 127) ~/ 255;
      final du = u - half;
      u = half + ((du * 224 + (du >= 0 ? 127 : -127)) ~/ 255);
      final dv = v - half;
      v = half + ((dv * 224 + (dv >= 0 ? 127 : -127)) ~/ 255);
    }
    out[i] = y < 0 ? 0 : (y > maxValue ? maxValue : y);
    out[i + 1] = u < 0 ? 0 : (u > maxValue ? maxValue : u);
    out[i + 2] = v < 0 ? 0 : (v > maxValue ? maxValue : v);
  }
  return out;
}

/// 激发泄漏扣除（N17/N18）：统一扣除泄漏电平 [level]，扣除量限幅
/// [maxSub]，结果钳位到 0。
void applyFluoroLeak(Uint16List mono, {double level = 0, double maxSub = 65535}) {
  final sub = level < maxSub ? level : maxSub;
  if (sub <= 0) return;
  for (var i = 0; i < mono.length; i++) {
    final v = mono[i] - sub;
    mono[i] = v <= 0 ? 0 : v.round();
  }
}

/// 自发荧光背景扣除（N19/N20）：按 [blockSize]×[blockSize] 块均值估计
/// 低频背景，按 [strength]（0..1）比例扣除，结果钳位到 0。
void applyFluoroBackground(
  Uint16List mono, {
  required int width,
  required int height,
  int blockSize = 16,
  double strength = 1.0,
}) {
  if (strength <= 0) return;
  final bs = blockSize < 2 ? 2 : blockSize;
  final bx = (width + bs - 1) ~/ bs;
  final by = (height + bs - 1) ~/ bs;
  final means = List<double>.filled(bx * by, 0);
  for (var byi = 0; byi < by; byi++) {
    for (var bxi = 0; bxi < bx; bxi++) {
      var sum = 0, count = 0;
      final y0 = byi * bs, y1 = math.min(y0 + bs, height);
      final x0 = bxi * bs, x1 = math.min(x0 + bs, width);
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          sum += mono[y * width + x];
          count++;
        }
      }
      means[byi * bx + bxi] = count > 0 ? sum / count : 0;
    }
  }
  final src = Uint16List.fromList(mono);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      final bg = means[(y ~/ bs) * bx + (x ~/ bs)];
      final v = src[i] - strength * bg;
      mono[i] = v <= 0 ? 0 : v.round();
    }
  }
}

/// 激发参考归一化（N21–N23）：以全帧均值作为激发强度估计，把画面
/// 增益拉到参考电平 [reference]：v' = v × reference / max(mean, [epsilon])。
void applyFluoroNormalize(
  Uint16List mono, {
  double reference = 0,
  double epsilon = 1,
  int maxValue = 65535,
}) {
  if (reference <= 0) return;
  var sum = 0;
  for (final v in mono) {
    sum += v;
  }
  if (mono.isEmpty) return;
  final mean = sum / mono.length;
  if (mean < epsilon) return;
  final gain = reference / mean;
  if (gain == 1.0) return;
  for (var i = 0; i < mono.length; i++) {
    mono[i] = _clampTo(mono[i] * gain, maxValue);
  }
}

/// 时域 IIR 降噪（N26–N28）：Y = αF + (1−α)Yprev。
/// [history] 为上一帧输出（无历史或尺寸不符时直通并把当前帧作为历史）。
/// [motionAdapt] 为 true 时帧差超过 maxValue/16 的像素判为运动，
/// 强制 α=1（用当前帧，避免拖影）。返回 (输出帧, 新历史帧)。
(Uint16List, Uint16List) applyTemporalIir(
  Uint16List mono, {
  Uint16List? history,
  required double alpha,
  bool motionAdapt = false,
  int maxValue = 65535,
}) {
  final out = Uint16List(mono.length);
  if (history == null || history.length != mono.length) {
    out.setAll(0, mono);
    return (out, Uint16List.fromList(mono));
  }
  final a = alpha.clamp(0.0, 1.0);
  final motionThr = maxValue / 16;
  for (var i = 0; i < mono.length; i++) {
    final f = mono[i];
    final prev = history[i];
    var aa = a;
    if (motionAdapt && (f - prev).abs() > motionThr) aa = 1.0;
    out[i] = (aa * f + (1 - aa) * prev).round();
  }
  return (out, Uint16List.fromList(out));
}

/// 伪彩映射（N33/N40）：mono 灰度按 [gain] 增益归一化后映射为伪彩
/// RGB（green / magenta / hot 三种色表），输出 16 位量级交织 RGB。
Uint16List monoPseudoColor(
  Uint16List mono, {
  required int width,
  required int height,
  String colormap = 'green',
  double gain = 1.0,
  int maxValue = 65535,
}) {
  final out = Uint16List(mono.length * 3);
  final inv = 1.0 / maxValue;
  var j = 0;
  for (var i = 0; i < mono.length; i++, j += 3) {
    var t = mono[i] * gain * inv;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    double r, g, b;
    switch (colormap) {
      case 'magenta':
        r = t;
        g = 0;
        b = t;
      case 'hot':
        // 黑 → 红 → 黄 → 白。
        r = math.min(3 * t, 1.0);
        g = (3 * t - 1).clamp(0.0, 1.0);
        b = (3 * t - 2).clamp(0.0, 1.0);
      default: // 'green'：ICG 荧光惯例的纯绿映射
        r = 0;
        g = t;
        b = 0;
    }
    out[j] = _clampTo(r * maxValue, maxValue);
    out[j + 1] = _clampTo(g * maxValue, maxValue);
    out[j + 2] = _clampTo(b * maxValue, maxValue);
  }
  return out;
}

/// 荧光融合（R09–R11、N38/N39）：白光 RGB 与荧光 mono 的融合出图。
/// 荧光图先按 ([offsetX], [offsetY]) 手动配准偏移做双线性重采样
/// （几何配准 R01–R07 的简化）；α 由荧光强度经 [threshold] 门限映射到
/// 0..[alphaMax]（SBR/SNR/置信度 N29/N30/N38 的简化折叠）。
/// [mode] 为 'alpha' 时 RGB_f=(1−α)·WL+α·pseudo(FL)；为 'contour' 时
/// 提取荧光 mask 的 3x3 轮廓，以伪彩全强度叠加。
Uint16List fuseFluorescence(
  Uint16List rgbWl,
  Uint16List monoFl, {
  required int width,
  required int height,
  String mode = 'alpha',
  double threshold = 0,
  double alphaMax = 0.8,
  String colormap = 'green',
  double offsetX = 0,
  double offsetY = 0,
  int maxValue = 65535,
}) {
  // 带偏移的荧光图双线性采样（边界钳位）。
  double sampleFl(double fx, double fy) {
    fx = fx.clamp(0.0, width - 1.0);
    fy = fy.clamp(0.0, height - 1.0);
    final x0 = fx.floor();
    final y0 = fy.floor();
    final x1 = x0 + 1 < width ? x0 + 1 : x0;
    final y1 = y0 + 1 < height ? y0 + 1 : y0;
    final tx = fx - x0;
    final ty = fy - y0;
    final v00 = monoFl[y0 * width + x0];
    final v10 = monoFl[y0 * width + x1];
    final v01 = monoFl[y1 * width + x0];
    final v11 = monoFl[y1 * width + x1];
    return (v00 * (1 - tx) + v10 * tx) * (1 - ty) +
        (v01 * (1 - tx) + v11 * tx) * ty;
  }

  final out = Uint16List(width * height * 3);
  final contour = mode == 'contour';
  final range = maxValue - threshold;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      final i = p * 3;
      final fl = sampleFl(x + offsetX, y + offsetY);
      // 伪彩（增益 1，融合内不再叠加增益）。
      final t = (fl / maxValue).clamp(0.0, 1.0);
      double pr, pg, pb;
      switch (colormap) {
        case 'magenta':
          pr = t;
          pg = 0;
          pb = t;
        case 'hot':
          pr = math.min(3 * t, 1.0);
          pg = (3 * t - 1).clamp(0.0, 1.0);
          pb = (3 * t - 2).clamp(0.0, 1.0);
        default:
          pr = 0;
          pg = t;
          pb = 0;
      }
      if (contour) {
        // 轮廓模式：mask 内像素若 3x3 邻域存在 mask 外点即为边缘。
        var edge = false;
        if (fl >= threshold) {
          for (var dy = -1; dy <= 1 && !edge; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              if (dx == 0 && dy == 0) continue;
              if (sampleFl(x + dx + offsetX, y + dy + offsetY) < threshold) {
                edge = true;
                break;
              }
            }
          }
        }
        if (edge) {
          out[i] = _clampTo(pr * maxValue, maxValue);
          out[i + 1] = _clampTo(pg * maxValue, maxValue);
          out[i + 2] = _clampTo(pb * maxValue, maxValue);
        } else {
          out[i] = rgbWl[i];
          out[i + 1] = rgbWl[i + 1];
          out[i + 2] = rgbWl[i + 2];
        }
        continue;
      }
      // alpha 模式：强度门限 → α 映射。
      var a = 0.0;
      if (range > 0 && fl > threshold) {
        a = alphaMax * ((fl - threshold) / range);
        if (a > alphaMax) a = alphaMax;
      }
      out[i] = _clampTo(rgbWl[i] * (1 - a) + pr * maxValue * a, maxValue);
      out[i + 1] = _clampTo(rgbWl[i + 1] * (1 - a) + pg * maxValue * a, maxValue);
      out[i + 2] = _clampTo(rgbWl[i + 2] * (1 - a) + pb * maxValue * a, maxValue);
    }
  }
  return out;
}
