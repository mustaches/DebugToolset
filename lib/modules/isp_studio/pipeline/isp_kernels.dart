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

import 'levels_curve.dart';

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
  /// One pixel per 16-bit word (fixed 2 bytes per pixel, any bit depth),
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
      // 固定每像素 2 字节（16 位字），与位深无关。
      return pixels * 2;
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
      // 固定每像素 2 字节（16 位字）：8/10/12/14/16 位深同样按字读取。
      final isLsb = packing == BayerPacking.unpackedLsb;
      final mask = bayerMaxValue(bitDepth);
      final shift = 16 - bitDepth;
      var p = byteOffset;
      for (var i = 0; i < pixels; i++, p += 2) {
        final raw = littleEndian
            ? bytes[p] | (bytes[p + 1] << 8)
            : (bytes[p] << 8) | bytes[p + 1];
        out[i] = isLsb ? raw & mask : raw >> shift;
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

/// HSL 调整（HSL 调节器节点）：H 在 0..360° 色环上循环偏移 [hShiftDeg]
/// 度，S/L 分别乘增益 [sGain]/[lGain] 后钳位到 0..maxValue。
/// 三个参数均为恒等值时直接返回原数据（不拷贝）。
Uint16List adjustHsl(Uint16List hsl,
    {required int maxValue,
    double hShiftDeg = 0,
    double sGain = 1.0,
    double lGain = 1.0}) {
  if (hShiftDeg == 0 && sGain == 1.0 && lGain == 1.0) return hsl;
  final out = Uint16List(hsl.length);
  final m = maxValue + 1; // 色环模数：H 在 0..maxValue 上循环
  final shift = (hShiftDeg / 360 * maxValue).round();
  for (var i = 0; i < hsl.length; i += 3) {
    // Dart 的 % 对负数返回负值，用 ((x % m) + m) % m 修正环绕。
    out[i] = ((hsl[i] + shift) % m + m) % m;
    out[i + 1] = _clampTo(hsl[i + 1] * sGain, maxValue);
    out[i + 2] = _clampTo(hsl[i + 2] * lGain, maxValue);
  }
  return out;
}

/// RGB 调节器（RGB 域调参节点）：R/G/B 三通道分别乘增益后钳位到
/// 0..maxValue。三个增益均为恒等 1 时直接返回原数据（不拷贝）。
Uint16List adjustRgb(Uint16List rgb,
    {required int maxValue,
    double rGain = 1.0,
    double gGain = 1.0,
    double bGain = 1.0}) {
  if (rGain == 1.0 && gGain == 1.0 && bGain == 1.0) return rgb;
  final out = Uint16List(rgb.length);
  for (var i = 0; i < rgb.length; i += 3) {
    out[i] = _clampTo(rgb[i] * rGain, maxValue);
    out[i + 1] = _clampTo(rgb[i + 1] * gGain, maxValue);
    out[i + 2] = _clampTo(rgb[i + 2] * bGain, maxValue);
  }
  return out;
}

/// 曲线调节器（levels_curves）：RGB 帧逐通道过传递函数 LUT（4096 级，
/// 定义域 0..4095）。帧值先按 maxValue 线性缩放到 LUT 域查表，结果再
/// 缩放回 0..maxValue；maxValue == 4095 时直通查表。恒等 LUT 由调用方
/// 判定并跳过本核（不拷贝）。
Uint16List applyLevelsCurve(Uint16List rgb, Uint16List lut,
    {required int maxValue}) {
  final out = Uint16List(rgb.length);
  if (maxValue == kLevelsMax) {
    for (var i = 0; i < rgb.length; i++) {
      out[i] = lut[rgb[i]];
    }
    return out;
  }
  for (var i = 0; i < rgb.length; i++) {
    final idx = (rgb[i] * kLevelsMax + (maxValue >> 1)) ~/ maxValue;
    out[i] = (lut[idx] * maxValue + (kLevelsMax >> 1)) ~/ kLevelsMax;
  }
  return out;
}

/// 色彩平衡（color_balance）：RGB/YUV/HSL 三域中间调色彩偏移，输出保持
/// 输入格式。三个滑杆值 [-100, 100] 分别对应 青↔红、洋红↔绿、黄↔蓝：
/// 正值向后二（红/绿/蓝）偏移，负值向前一。偏移按 BT.601 亮度的中间调
/// 权重 w = 1 − |2Y−1| 加权（中间调最强，纯黑/纯白不受影响），结果钳位
/// 到 0..maxValue。三值全 0 时直通不拷贝。
///
/// 各域实现：
/// - RGB：偏移量 = 值/100 × maxValue，直接加到 R/G/B 通道；
/// - YUV：青↔红即 V 轴（V ≈ R−Y）、黄↔蓝即 U 轴（U ≈ B−Y），洋红↔绿
///   为 U/V 对角（绿 = −U−V，洋红 = +U+V）；色度偏移量 = 值/100 ×
///   maxValue/2（色度全量程为 ±maxValue/2），Y 通道不变，中间调权重
///   直接取 Y 通道；
/// - HSL：无直接的通道对应关系，经 hslToRgb/rgbToHsl 往返转换施加
///   RGB 域偏移（语义与 RGB 输入一致）。
Uint16List applyColorBalance(Uint16List data,
    {required String format,
    required int maxValue,
    double cyanRed = 0,
    double magentaGreen = 0,
    double yellowBlue = 0}) {
  if (cyanRed == 0 && magentaGreen == 0 && yellowBlue == 0) return data;
  switch (format) {
    case 'rgb':
      return _colorBalanceRgb(data, maxValue, cyanRed, magentaGreen,
          yellowBlue);
    case 'yuv':
      return _colorBalanceYuv(data, maxValue, cyanRed, magentaGreen,
          yellowBlue);
    case 'hsl':
      final rgb = hslToRgb(data, maxValue: maxValue);
      return rgbToHsl(
          _colorBalanceRgb(rgb, maxValue, cyanRed, magentaGreen, yellowBlue),
          maxValue: maxValue);
    default:
      throw StateError('色彩平衡需要 RGB/YUV/HSL 输入（当前 $format）');
  }
}

/// RGB 域：按通道加性偏移（中间调权重按 BT.601 亮度计算）。
Uint16List _colorBalanceRgb(Uint16List rgb, int maxValue, double cyanRed,
    double magentaGreen, double yellowBlue) {
  final dr = cyanRed / 100 * maxValue;
  final dg = magentaGreen / 100 * maxValue;
  final db = yellowBlue / 100 * maxValue;
  final out = Uint16List(rgb.length);
  for (var i = 0; i < rgb.length; i += 3) {
    final r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
    final y = (0.299 * r + 0.587 * g + 0.114 * b) / maxValue;
    final w = 1 - (2 * y - 1).abs();
    out[i] = _clampTo(r + dr * w, maxValue);
    out[i + 1] = _clampTo(g + dg * w, maxValue);
    out[i + 2] = _clampTo(b + db * w, maxValue);
  }
  return out;
}

/// YUV 域：青↔红 → V 轴、黄↔蓝 → U 轴、洋红↔绿 → U/V 对角；Y 不变。
Uint16List _colorBalanceYuv(Uint16List yuv, int maxValue, double cyanRed,
    double magentaGreen, double yellowBlue) {
  final k = maxValue / 2 / 100; // 色度偏移系数（值 100 = 半量程）
  final du = yellowBlue * k; // U：正值偏蓝
  final dv = cyanRed * k; // V：正值偏红
  final dg = magentaGreen * k; // 洋红↔绿：绿 = −U−V
  final out = Uint16List(yuv.length);
  for (var i = 0; i < yuv.length; i += 3) {
    final y = yuv[i];
    final w = 1 - (2 * y / maxValue - 1).abs();
    out[i] = y;
    out[i + 1] = _clampTo(yuv[i + 1] + (du - dg) * w, maxValue);
    out[i + 2] = _clampTo(yuv[i + 2] + (dv - dg) * w, maxValue);
  }
  return out;
}

/// YUV 调节器（YUV 域调参节点）：Y 乘增益；U/V 围绕中点（maxValue>>1）
/// 缩放（色度增益不改变中性色点），钳位到 0..maxValue。
/// 三个增益均为恒等 1 时直接返回原数据（不拷贝）。
Uint16List adjustYuv(Uint16List yuv,
    {required int maxValue,
    double yGain = 1.0,
    double uGain = 1.0,
    double vGain = 1.0}) {
  if (yGain == 1.0 && uGain == 1.0 && vGain == 1.0) return yuv;
  final half = maxValue >> 1;
  final out = Uint16List(yuv.length);
  for (var i = 0; i < yuv.length; i += 3) {
    out[i] = _clampTo(yuv[i] * yGain, maxValue);
    out[i + 1] = _clampTo(half + (yuv[i + 1] - half) * uGain, maxValue);
    out[i + 2] = _clampTo(half + (yuv[i + 2] - half) * vGain, maxValue);
  }
  return out;
}

/// 色饱和度/亮度调节器：按输入帧所在色彩域（[format] = 'rgb'/'yuv'/
/// 'hsl'）施加色饱和度增益 [satGain] 与亮度增益 [brightGain]，输出保持
/// 原格式（不跨域转换）。两个增益均为恒等 1 时直接返回原数据（不拷贝）。
///
/// - RGB 域：先做保亮度饱和度混合 c' = Y + (c - Y) * satGain
///   （Y 为 BT.601 亮度），再整体乘 brightGain；
/// - YUV 域：Y 乘 brightGain；U/V 围绕中点（maxValue>>1）乘 satGain
///   （色度增益不改变中性色点）；
/// - HSL 域：S 乘 satGain；L 乘 brightGain。
/// 均四舍五入后钳位到 0..maxValue。
Uint16List adjustSatBright(Uint16List data,
    {required String format,
    required int maxValue,
    double satGain = 1.0,
    double brightGain = 1.0}) {
  if (satGain == 1.0 && brightGain == 1.0 &&
      (format == 'rgb' || format == 'yuv' || format == 'hsl')) {
    return data;
  }
  final out = Uint16List(data.length);
  switch (format) {
    case 'rgb':
      for (var i = 0; i < data.length; i += 3) {
        final r = data[i], g = data[i + 1], b = data[i + 2];
        // BT.601 全范围亮度（与 rgbToYuv 的 Y 一致）。
        final y = 0.299 * r + 0.587 * g + 0.114 * b;
        out[i] = _clampTo((y + (r - y) * satGain) * brightGain, maxValue);
        out[i + 1] = _clampTo((y + (g - y) * satGain) * brightGain, maxValue);
        out[i + 2] = _clampTo((y + (b - y) * satGain) * brightGain, maxValue);
      }
    case 'yuv':
      final half = maxValue >> 1;
      for (var i = 0; i < data.length; i += 3) {
        out[i] = _clampTo(data[i] * brightGain, maxValue);
        out[i + 1] =
            _clampTo(half + (data[i + 1] - half) * satGain, maxValue);
        out[i + 2] =
            _clampTo(half + (data[i + 2] - half) * satGain, maxValue);
      }
    case 'hsl':
      for (var i = 0; i < data.length; i += 3) {
        out[i] = data[i]; // H 不变
        out[i + 1] = _clampTo(data[i + 1] * satGain, maxValue);
        out[i + 2] = _clampTo(data[i + 2] * brightGain, maxValue);
      }
    default:
      throw ArgumentError('色饱和度/亮度调节器需要 RGB/YUV/HSL 输入，实际: $format');
  }
  return out;
}

/// 亮度/对比度调节器：按输入帧所在色彩域（[format] = 'rgb'/'yuv'/'hsl'/
/// 'mono'）对亮度施加调节，输出保持原格式（不跨域转换）。
///
/// 公式（[baselinePct] 为满量程百分比）：base = baselinePct/100 × maxValue；
/// Y' = ((Y × brightPct/100) − base) × gainPct/100 + base，钳位 0..maxValue。
/// - RGB 域：逐像素求 BT.601 亮度 Y，按 Y'/Y 等比缩放 R/G/B（Y=0 的纯黑
///   像素无亮度比例可言，保持 0）；
/// - YUV 域：直接作用于 Y 通道；
/// - HSL 域：作用于 L 通道；
/// - Mono 域：直接作用于单通道亮度（数据长度 w*h）。
/// brightPct=100 且 gainPct=100 时为恒等（与基线无关），直接返回原数据
/// （不拷贝）。
Uint16List adjustBrightContrast(Uint16List data,
    {required String format,
    required int maxValue,
    double brightPct = 100,
    double baselinePct = 50,
    double gainPct = 100}) {
  if (brightPct == 100 && gainPct == 100 &&
      (format == 'rgb' || format == 'yuv' || format == 'hsl' ||
          format == 'mono')) {
    return data;
  }
  final base = baselinePct / 100 * maxValue;
  final bs = brightPct / 100;
  final gs = gainPct / 100;
  int adjust(int y) => _clampTo(((y * bs) - base) * gs + base, maxValue);
  final out = Uint16List(data.length);
  switch (format) {
    case 'rgb':
      for (var i = 0; i < data.length; i += 3) {
        final r = data[i], g = data[i + 1], b = data[i + 2];
        // BT.601 全范围亮度（与 rgbToYuv 的 Y 一致）。
        final y = 0.299 * r + 0.587 * g + 0.114 * b;
        if (y <= 0) continue; // 纯黑像素保持 0
        final ratio = adjust(y.round()) / y;
        out[i] = _clampTo(r * ratio, maxValue);
        out[i + 1] = _clampTo(g * ratio, maxValue);
        out[i + 2] = _clampTo(b * ratio, maxValue);
      }
    case 'yuv':
      for (var i = 0; i < data.length; i += 3) {
        out[i] = adjust(data[i]);
        out[i + 1] = data[i + 1];
        out[i + 2] = data[i + 2];
      }
    case 'hsl':
      for (var i = 0; i < data.length; i += 3) {
        out[i] = data[i];
        out[i + 1] = data[i + 1];
        out[i + 2] = adjust(data[i + 2]);
      }
    case 'mono':
      for (var i = 0; i < data.length; i++) {
        out[i] = adjust(data[i]);
      }
    default:
      throw ArgumentError('亮度/对比度调节器需要 RGB/YUV/HSL/Mono 输入，实际: $format');
  }
  return out;
}

/// YUV → HSL：单遍融合实现——循环内先按 [yuvToRgb] 的定点公式算出 RGB
/// 中间值（含钳位，不分配中间缓冲），再按 [rgbToHsl] 的逻辑求 H/S/L。
/// 数学上等价于 YUV→RGB→HSL 两段中转，数值结果与之逐点一致。
Uint16List yuvToHsl(Uint16List yuv, {required int maxValue}) {
  final out = Uint16List(yuv.length);
  final half = maxValue >> 1;
  final inv = 1.0 / maxValue;
  const crV = 91881;  // 1.402 * 65536
  const cgU = -22553; // -0.344136 * 65536
  const cgV = -46801; // -0.714136 * 65536
  const cbU = 116130; // 1.772 * 65536

  for (var i = 0; i < yuv.length; i += 3) {
    final y = yuv[i];
    final u = yuv[i + 1] - half;
    final v = yuv[i + 2] - half;

    // RGB 中间值：与 yuvToRgb 完全一致的定点计算与钳位。
    var ri = y + ((crV * v + 32768) >> 16);
    var gi = y + ((cgU * u + cgV * v + 32768) >> 16);
    var bi = y + ((cbU * u + 32768) >> 16);
    ri = ri < 0 ? 0 : (ri > maxValue ? maxValue : ri);
    gi = gi < 0 ? 0 : (gi > maxValue ? maxValue : gi);
    bi = bi < 0 ? 0 : (bi > maxValue ? maxValue : bi);

    // HSL 部分：与 rgbToHsl 完全一致。
    final r = ri * inv;
    final g = gi * inv;
    final b = bi * inv;
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

/// HSL → YUV：单遍融合实现——循环内先按 [hslToRgb] 的逻辑算出 RGB
/// 中间值（含钳位，不分配中间缓冲），再按 [rgbToYuv] 的定点公式求 Y/U/V。
/// 数学上等价于 HSL→RGB→YUV 两段中转，数值结果与之逐点一致。
Uint16List hslToYuv(Uint16List hsl, {required int maxValue}) {
  final out = Uint16List(hsl.length);
  final half = maxValue >> 1;
  final inv = 1.0 / maxValue;
  const cyR = 19595; // 0.299 * 65536
  const cyG = 38470; // 0.587 * 65536
  const cyB = 7471;  // 0.114 * 65536

  const cuR = -11058; // -0.168736 * 65536
  const cuG = -21710; // -0.331264 * 65536
  const cuB = 32768;  // 0.5 * 65536

  const cvR = 32768;  // 0.5 * 65536
  const cvG = -27439; // -0.418688 * 65536
  const cvB = -5329;  // -0.081312 * 65536

  for (var i = 0; i < hsl.length; i += 3) {
    // RGB 中间值：与 hslToRgb 完全一致。
    final h = (hsl[i] * inv) % 1.0;
    final s = hsl[i + 1] * inv;
    final l = hsl[i + 2] * inv;
    double rd, gd, bd;
    if (s == 0) {
      rd = gd = bd = l;
    } else {
      final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      final p = 2 * l - q;
      rd = _hueToRgb(p, q, h + 1 / 3);
      gd = _hueToRgb(p, q, h);
      bd = _hueToRgb(p, q, h - 1 / 3);
    }
    final r = _clampTo(rd * maxValue, maxValue);
    final g = _clampTo(gd * maxValue, maxValue);
    final b = _clampTo(bd * maxValue, maxValue);

    // YUV 部分：与 rgbToYuv 完全一致的定点计算与钳位。
    final yi = (cyR * r + cyG * g + cyB * b + 32768) >> 16;
    final ui = ((cuR * r + cuG * g + cuB * b + 32768) >> 16) + half;
    final vi = ((cvR * r + cvG * g + cvB * b + 32768) >> 16) + half;

    out[i] = yi < 0 ? 0 : (yi > maxValue ? maxValue : yi);
    out[i + 1] = ui < 0 ? 0 : (ui > maxValue ? maxValue : ui);
    out[i + 2] = vi < 0 ? 0 : (vi > maxValue ? maxValue : vi);
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

/// 残差中位数的桶计数实现：corr 最终限幅 ±maxCorr，故只需精确分辨
/// [-maxCorr, maxCorr] 内的中位数——桶 0 收下溢、末桶收上溢、中间每
/// 整数值一桶，累计定位第 n~/2 项。O(n) 无排序，且行优先缓存友好。
/// [count] 回调由调用方逐桶填入计数。
double _clampedMedian(int n, int ceilM, Int32List buckets) {
  if (n == 0) return 0;
  final k = n >> 1;
  var cum = 0;
  for (var b = 0; b < buckets.length; b++) {
    cum += buckets[b];
    if (cum > k) {
      if (b == 0) return -ceilM.toDouble() - 1; // 下溢（调用方限幅）
      if (b == buckets.length - 1) return ceilM.toDouble() + 1; // 上溢
      return (b - ceilM - 1).toDouble();
    }
  }
  return 0;
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
  // 桶计数中位数用的分桶：桶 0 收下溢、末桶收上溢、中间每整数一桶
  //（corr 限幅 ±maxCorr，超出部分无需精确分辨）。
  final ceilM = maxCorr.ceil();
  final nb = 2 * ceilM + 3;
  int bucketOf(int r) =>
      r < -maxCorr ? 0 : (r > maxCorr ? nb - 1 : r + ceilM + 1);
  if (row) {
    final low = _verticalBoxMean(buf, width, height, radius);
    // 水平边缘（垂直梯度）的垂直膨胀掩膜：这些像素的垂直低通被边缘
    // 污染，不参与行统计。
    final mask = _dilateMask(
        _gradientEdge(buf, width, height, edgeThresh, vertical: true),
        width, height, radius,
        vertical: true);
    final buckets = Int32List(nb);
    for (var y = 0; y < height; y++) {
      buckets.fillRange(0, nb, 0);
      var n = 0;
      final base = y * width;
      for (var x = 0; x < width; x++) {
        if (mask[base + x] != 0) continue;
        buckets[bucketOf(buf[base + x] - low[base + x].round())]++;
        n++;
      }
      final corr = clampCorr(_clampedMedian(n, ceilM, buckets));
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
    // 分块列统计：按 64 列一块、行优先对各列残差做桶计数（逐列跨步
    // 收集在 12MP 下缓存不命中是大头），统计与施加逐块完成。
    const tile = 64;
    final counts = Int32List(tile);
    var buckets = Int32List(tile * nb);
    for (var x0 = 0; x0 < width; x0 += tile) {
      final x1 = x0 + tile < width ? x0 + tile : width;
      final tw = x1 - x0;
      if (buckets.length < tw * nb) buckets = Int32List(tw * nb);
      counts.fillRange(0, tw, 0);
      buckets.fillRange(0, tw * nb, 0);
      for (var y = 0; y < height; y++) {
        final base = y * width;
        for (var x = x0; x < x1; x++) {
          if (mask[base + x] != 0) continue;
          final cx = x - x0;
          buckets[cx * nb + bucketOf(buf[base + x] - low[base + x].round())]++;
          counts[cx]++;
        }
      }
      for (var cx = 0; cx < tw; cx++) {
        final corr = clampCorr(_clampedMedian(counts[cx], ceilM,
            Int32List.sublistView(buckets, cx * nb, (cx + 1) * nb)));
        if (corr == 0) continue;
        final x = x0 + cx;
        for (var y = 0; y < height; y++) {
          final i = y * width + x;
          final v = buf[i] - corr;
          buf[i] = v <= 0 ? 0 : v.round();
        }
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
/// 垂直方向用逐列计数数组 + 行优先遍历（列优先在 12MP 下缓存不命中
/// 是主要耗时）。
Uint8List _dilateMask(Uint8List edge, int w, int h, int radius,
    {required bool vertical}) {
  final out = Uint8List(w * h);
  if (vertical) {
    final colCnt = Int32List(w);
    for (var y = 0; y <= radius && y < h; y++) {
      final base = y * w;
      for (var x = 0; x < w; x++) {
        colCnt[x] += edge[base + x];
      }
    }
    for (var y = 0; y < h; y++) {
      final base = y * w;
      for (var x = 0; x < w; x++) {
        out[base + x] = colCnt[x] > 0 ? 1 : 0;
      }
      final add = y + radius + 1;
      final del = y - radius;
      if (add < h) {
        final ab = add * w;
        for (var x = 0; x < w; x++) {
          colCnt[x] += edge[ab + x];
        }
      }
      if (del >= 0) {
        final db = del * w;
        for (var x = 0; x < w; x++) {
          colCnt[x] -= edge[db + x];
        }
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
/// 逐列和数组 + 行优先遍历（语义与逐列滑动完全一致，缓存友好）。
Float32List _verticalBoxMean(Uint16List buf, int w, int h, int radius) {
  final out = Float32List(w * h);
  final colSum = Int32List(w);
  var count = 0;
  for (var y = 0; y <= radius && y < h; y++) {
    final base = y * w;
    for (var x = 0; x < w; x++) {
      colSum[x] += buf[base + x];
    }
    count++;
  }
  for (var y = 0; y < h; y++) {
    final base = y * w;
    for (var x = 0; x < w; x++) {
      out[base + x] = colSum[x] / count;
    }
    final add = y + radius + 1;
    final del = y - radius;
    if (add < h) {
      final ab = add * w;
      for (var x = 0; x < w; x++) {
        colSum[x] += buf[ab + x];
      }
      count++;
    }
    if (del >= 0) {
      final db = del * w;
      for (var x = 0; x < w; x++) {
        colSum[x] -= buf[db + x];
      }
      count--;
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

/// 形态学腐蚀/膨胀（morphology）：方形结构元 (2×radius+1)² 的逐通道
/// 极小（腐蚀）/极大（膨胀）滤波，对交织多通道数据逐通道独立处理
/// （RGB 三通道独立 → 亮色/暗色区域整体收缩/扩张；Mono 单通道即灰度
/// 形态学）。可分离两趟实现（水平 + 垂直），结果与直接二维窗口完全一致；
/// 边界按可用邻域取极值（同 _dilateMask）。极值取自原数据，无需钳位。
void applyMorphology(
  Uint16List data, {
  required int width,
  required int height,
  int channels = 1,
  bool erode = true,
  int radius = 1,
}) {
  if (radius <= 0) return;
  final tmp = Uint16List(data.length);
  // 水平趟：每行按 [x-radius, x+radius]（裁剪到图内）取极值。
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final x0 = x - radius < 0 ? 0 : x - radius;
      final x1 = x + radius >= width ? width - 1 : x + radius;
      for (var c = 0; c < channels; c++) {
        var v = data[(row + x0) * channels + c];
        for (var nx = x0 + 1; nx <= x1; nx++) {
          final u = data[(row + nx) * channels + c];
          if (erode ? u < v : u > v) v = u;
        }
        tmp[(row + x) * channels + c] = v;
      }
    }
  }
  // 垂直趟：对水平趟结果按列取极值，写回原缓冲。
  for (var y = 0; y < height; y++) {
    final y0 = y - radius < 0 ? 0 : y - radius;
    final y1 = y + radius >= height ? height - 1 : y + radius;
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < channels; c++) {
        var v = tmp[(y0 * width + x) * channels + c];
        for (var ny = y0 + 1; ny <= y1; ny++) {
          final u = tmp[(ny * width + x) * channels + c];
          if (erode ? u < v : u > v) v = u;
        }
        data[(y * width + x) * channels + c] = v;
      }
    }
  }
}

/// 高频边缘提取（edge_extract）：亮度高通输出黑底白线边缘图——
/// detail = Y − 3x3 盒式模糊（与 [applySharpen] 同一 detail 定义），
/// 归一化为相对对比度 rel = |detail|/邻域均值；rel < threshold/maxValue
/// 视为噪声置零（相对门限，[threshold] 仍为满量程码值量纲）；输出 =
/// gain×√rel×maxValue，截位到 [maxValue]：平坦区为黑、边缘（无论亮边
/// 暗边）为亮线。边界按可用邻域平均（同 sharpen）。
///
/// 两个显示向设计：
/// - **相对对比度归一化**：同样相对反差的边缘在暗区与亮区输出同样
///   亮度，暗区边缘不再因绝对码值小而消失；门限也按相对口径判定，
///   否则暗区/柔和小 detail 边缘会被绝对门限整体吞掉。均值下限取
///   maxValue/128，防止近黑区域除零爆增益。
/// - **√rel 显示压缩**：弱边缘显著提亮（rel=0.01 → 0.1×满量程）、
///   强边缘饱和，避免弱反差边缘虽过门限却暗得看不见。
///
/// 按输入帧所在色彩域（[format] = 'rgb'/'yuv'/'hsl'）取亮度通道：
/// RGB 域求 BT.601 定点亮度，YUV 域取 Y 通道，HSL 域取 L 通道；输出
/// 保持原格式的黑底白线图（RGB 三通道同值 / YUV 的 U=V=中灰 /
/// HSL 的 H=0、S=0）。
Uint16List extractHighFreq(Uint16List data,
    {required int width,
    required int height,
    String format = 'rgb',
    double gain = 1.0,
    double threshold = 4.0,
    int maxValue = 65535}) {
  final pixels = width * height;
  final ys = Uint16List(pixels);
  switch (format) {
    case 'rgb':
      for (var p = 0; p < pixels; p++) {
        final i = p * 3;
        ys[p] =
            (19595 * data[i] + 38470 * data[i + 1] + 7471 * data[i + 2] + 32768) >>
                16;
      }
    case 'yuv':
      for (var p = 0; p < pixels; p++) {
        ys[p] = data[p * 3];
      }
    case 'hsl':
      for (var p = 0; p < pixels; p++) {
        ys[p] = data[p * 3 + 2];
      }
    default:
      throw ArgumentError('高频边缘提取需要 RGB/YUV/HSL 输入，实际: $format');
  }
  final midI = maxValue >> 1;
  final meanFloor = maxValue / 128;
  final relThreshold = threshold / maxValue;
  final out = Uint16List(pixels * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      var sum = 0, count = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          sum += ys[ny * width + nx];
          count++;
        }
      }
      final detail = ys[p] - sum / count;
      // 相对对比度：除邻域均值（均值下限防除零）。
      final mean = sum / count;
      var rel = detail.abs() / (mean < meanFloor ? meanFloor : mean);
      // 相对门限：与归一化同口径，避免暗区/柔和小 detail 边缘被吞。
      if (rel < relThreshold) rel = 0;
      // 黑底白线 + √rel 显示压缩：弱边缘提亮、强边缘饱和，平坦区为黑、
      // 亮边暗边均为亮线，同反差边缘与亮度无关。
      final v = _clampTo(gain * math.sqrt(rel) * maxValue, maxValue);
      final i = p * 3;
      switch (format) {
        case 'rgb':
          out[i] = v;
          out[i + 1] = v;
          out[i + 2] = v;
        case 'yuv':
          out[i] = v;
          out[i + 1] = midI;
          out[i + 2] = midI;
        case 'hsl':
          out[i] = 0; // H 无意义（S=0）
          out[i + 1] = 0;
          out[i + 2] = v;
      }
    }
  }
  return out;
}

/// CLAHE 直方图 bin 数（亮度按 maxValue 等比落入 256 bin）。
const int _claheBins = 256;

/// CLAHE 分块 LUT 构建：对单通道亮度平面 [ys]（w*h）按 blockSize×blockSize
/// 分 tile 统计 256 bin 直方图，按 [clipLimit]（tile 内平均计数的倍数）
/// 裁剪、超出量均匀再分配，再由累积分布（CDF）得各 tile 的均衡 LUT
/// （bin → 均衡亮度，0..maxValue）。返回长度 tilesX*tilesY*256 的表，
/// tile 网格尺寸为 (width+blockSize-1)~/blockSize × (height+blockSize-1)~/blockSize。
Float64List _claheTileLuts(Uint16List ys, int width, int height, int blockSize,
    double clipLimit, int maxValue) {
  final tilesX = (width + blockSize - 1) ~/ blockSize;
  final tilesY = (height + blockSize - 1) ~/ blockSize;
  final luts = Float64List(tilesX * tilesY * _claheBins);
  final hist = Float64List(_claheBins);
  for (var ty = 0; ty < tilesY; ty++) {
    for (var tx = 0; tx < tilesX; tx++) {
      hist.fillRange(0, _claheBins, 0);
      final x0 = tx * blockSize, y0 = ty * blockSize;
      final x1 = math.min(x0 + blockSize, width);
      final y1 = math.min(y0 + blockSize, height);
      final count = (x1 - x0) * (y1 - y0);
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          hist[ys[y * width + x] * _claheBins ~/ (maxValue + 1)]++;
        }
      }
      // 裁剪：阈值为平均计数（count/bins）的 clipLimit 倍，
      // 超出量均匀再分配到全部 bin。
      final limit = clipLimit * count / _claheBins;
      var excess = 0.0;
      for (var b = 0; b < _claheBins; b++) {
        if (hist[b] > limit) {
          excess += hist[b] - limit;
          hist[b] = limit;
        }
      }
      final per = excess / _claheBins;
      final lutBase = (ty * tilesX + tx) * _claheBins;
      var cdf = 0.0;
      for (var b = 0; b < _claheBins; b++) {
        cdf += hist[b] + per;
        luts[lutBase + b] = cdf / count * maxValue;
      }
    }
  }
  return luts;
}

/// CLAHE 双线性插值：像素 (x, y) 的均衡亮度由周围 4 个 tile 中心的 LUT
/// 插值得到（tile 中心位于各 tile 中点，边缘像素钳到最近 tile），
/// 避免块效应。[v] 为该像素亮度。
double _claheBilinear(Float64List luts, int tilesX, int tilesY, int blockSize,
    int x, int y, int v, int maxValue) {
  final fy = (y + 0.5) / blockSize - 0.5;
  var ty0 = fy.floor();
  var wy = fy - ty0;
  if (ty0 < 0) {
    ty0 = 0;
    wy = 0.0;
  } else if (ty0 >= tilesY - 1) {
    ty0 = tilesY - 1;
    wy = 0.0;
  }
  final ty1 = ty0 + 1 < tilesY ? ty0 + 1 : ty0;
  final fx = (x + 0.5) / blockSize - 0.5;
  var tx0 = fx.floor();
  var wx = fx - tx0;
  if (tx0 < 0) {
    tx0 = 0;
    wx = 0.0;
  } else if (tx0 >= tilesX - 1) {
    tx0 = tilesX - 1;
    wx = 0.0;
  }
  final tx1 = tx0 + 1 < tilesX ? tx0 + 1 : tx0;
  final bin = v * _claheBins ~/ (maxValue + 1);
  final l00 = luts[(ty0 * tilesX + tx0) * _claheBins + bin];
  final l01 = luts[(ty0 * tilesX + tx1) * _claheBins + bin];
  final l10 = luts[(ty1 * tilesX + tx0) * _claheBins + bin];
  final l11 = luts[(ty1 * tilesX + tx1) * _claheBins + bin];
  final top = l00 + (l01 - l00) * wx;
  final bottom = l10 + (l11 - l10) * wx;
  return top + (bottom - top) * wy;
}

/// CLAHE 分块 LUT 的公开入口（GPU 链执行器复用：tile 直方图统计/CDF
/// 仍在 CPU 计算，逐像素双线性插值放 shader）。bin 数恒为 256，
/// 返回长度 tilesX*tilesY*256，布局见 [_claheTileLuts]。
Float64List claheTileLuts(Uint16List ys, int width, int height,
        int blockSize, double clipLimit, int maxValue) =>
    _claheTileLuts(ys, width, height, blockSize, clipLimit, maxValue);

/// 自适应直方图均衡（CLAHE，对比度受限）：对亮度做分块直方图均衡，
/// 三通道按亮度缩放比例等比缩放（保持 hue/sat 不变），原地修改。
///
/// 算法步骤：
/// 1. 逐像素求亮度 Y（BT.601 定点加权和，与 [applySharpen] 一致）；
/// 2. 分 tile 统计直方图 → 裁剪再分配 → CDF 得 LUT（[_claheTileLuts]）；
/// 3. 每像素的均衡亮度由周围 4 个 tile 中心的 LUT 双线性插值得到
///    （[_claheBilinear]，标准 CLAHE 做法，避免块效应）；
/// 4. 三通道按 Y'/Y 等比缩放；[strength] 为均衡亮度与原亮度的混合比
///    （0 = 原图直通，直接跳过）。
void applyClahe(
  Uint16List rgb, {
  required int width,
  required int height,
  int blockSize = 32,
  double clipLimit = 2.0,
  double strength = 1.0,
  int maxValue = 65535,
}) {
  if (strength <= 0) return;
  if (blockSize < 2) blockSize = 32;
  if (clipLimit <= 0) clipLimit = 1.0;
  final pixels = width * height;
  // 1. 亮度平面。
  final ys = Uint16List(pixels);
  for (var p = 0; p < pixels; p++) {
    final i = p * 3;
    ys[p] =
        (19595 * rgb[i] + 38470 * rgb[i + 1] + 7471 * rgb[i + 2] + 32768) >> 16;
  }
  final tilesX = (width + blockSize - 1) ~/ blockSize;
  final tilesY = (height + blockSize - 1) ~/ blockSize;
  final luts = _claheTileLuts(ys, width, height, blockSize, clipLimit, maxValue);
  // 2/3. 逐像素插值均衡亮度，按亮度比例缩放三通道。
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      final v = ys[p];
      if (v <= 0) continue; // 黑像素无亮度比例可言，保持不动
      final le = _claheBilinear(luts, tilesX, tilesY, blockSize, x, y, v, maxValue);
      // strength 混合在亮度域进行，再折算为通道缩放比。
      final scale = (v + (le - v) * strength) / v;
      final i = p * 3;
      rgb[i] = _clampTo(rgb[i] * scale, maxValue);
      rgb[i + 1] = _clampTo(rgb[i + 1] * scale, maxValue);
      rgb[i + 2] = _clampTo(rgb[i + 2] * scale, maxValue);
    }
  }
}

/// Mono 单通道 CLAHE（[applyClahe] 的单通道版）：16 位 w*h 单通道帧
/// 直接作为亮度平面做分块直方图均衡，无需亮度提取与色度缩放，
/// 单通道即亮度本身。用于单通道视频信号（如荧光 Mono 链）。原地修改。
void applyClaheMono(
  Uint16List mono, {
  required int width,
  required int height,
  int blockSize = 32,
  double clipLimit = 2.0,
  double strength = 1.0,
  int maxValue = 65535,
}) {
  if (strength <= 0) return;
  if (blockSize < 2) blockSize = 32;
  if (clipLimit <= 0) clipLimit = 1.0;
  final tilesX = (width + blockSize - 1) ~/ blockSize;
  final tilesY = (height + blockSize - 1) ~/ blockSize;
  final luts =
      _claheTileLuts(mono, width, height, blockSize, clipLimit, maxValue);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = y * width + x;
      final v = mono[p];
      if (v <= 0) continue; // 与 RGB 版一致：纯黑保持不动
      final le =
          _claheBilinear(luts, tilesX, tilesY, blockSize, x, y, v, maxValue);
      mono[p] = _clampTo(v + (le - v) * strength, maxValue);
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

/// 乘法器（multiplier）：两路 Mono 帧逐像素归一化相乘——
/// out = (a+offset1)×(b+offset2)/maxValue，截位到 0..[maxValue]
/// （归一化使输出仍在原量程内；offset 可用于黑电平抬升/符号偏移，
/// 避免零值像素把另一路整体清零）。两路长度必须一致（分辨率一致性
/// 的校验在 pipeline_runner 的节点分支完成，此处按短者兜底截断）。
Uint16List multiplyMono(List<int> a, List<int> b,
    {double offset1 = 0, double offset2 = 0, int maxValue = 65535}) {
  final n = math.min(a.length, b.length);
  final out = Uint16List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _clampTo(
        (a[i] + offset1) * (b[i] + offset2) / maxValue, maxValue);
  }
  return out;
}

/// 加法器（adder）：两路 mono 平衡加权混合——
/// out = round(a×balance + b×(1−balance))，两路增益总和恒为 1
/// （balance 即源1 增益，源2 增益 = 1−balance），截位到 [maxValue]；
/// 长度不一致按短者截断（同 [multiplyMono]）。
Uint16List blendMono(List<int> a, List<int> b,
    {double balance = 0.5, int maxValue = 65535}) {
  final n = math.min(a.length, b.length);
  final out = Uint16List(n);
  final wb = 1 - balance;
  for (var i = 0; i < n; i++) {
    out[i] = _clampTo(a[i] * balance + b[i] * wb, maxValue);
  }
  return out;
}

/// 混叠器（blender）正常模式：out = 基图 + 混叠图×蒙版/maxValue×strength
/// ——混叠图与蒙版归一化相乘（同 [multiplyMono] 口径：蒙版取满量程时
/// 混叠图全量通过），乘混叠强度后逐像素叠加到基图，截位到 [maxValue]。
/// 叠加目标通道按基图 [format]：YUV 只加 Y（U/V 不变，锐化不产生
/// 色偏）、HSL 只加 L、RGB 三通道同加（等效亮度叠加，同 unsharp
/// mask 的通道无关增量）、Mono 单通道。基图为交织数据（RGB/YUV/HSL
/// = w*h*3，Mono = w*h），蒙版为单通道（w*h）；混叠图为单通道
/// （[blendChannels]=1，默认）或三通道交织（[blendChannels]=3，
/// 逐通道对应叠加：Y 加到 Y、U 加到 U……），返回新缓冲
/// （基图不被修改）。
Uint16List blendMaskMono(List<int> base, List<int> blend, List<int> mask,
    {String format = 'rgb',
    int blendChannels = 1,
    double strength = 1.0,
    int maxValue = 65535}) {
  final out = Uint16List.fromList(base);
  if (strength == 0) return out;
  final channels = format == 'mono' ? 1 : 3;
  final pixels = math.min(out.length ~/ channels,
      math.min(blend.length ~/ blendChannels, mask.length));
  final k = strength / maxValue;
  for (var p = 0; p < pixels; p++) {
    final i = p * channels;
    if (blendChannels == 3) {
      // 三通道混叠图：逐通道对应叠加（Y 加到 Y、U 加到 U……）。
      for (var c = 0; c < channels; c++) {
        final delta = blend[p * 3 + c] * mask[p] * k;
        if (delta <= 0) continue;
        out[i + c] = _clampTo(base[i + c] + delta, maxValue);
      }
      continue;
    }
    final delta = blend[p] * mask[p] * k;
    if (delta <= 0) continue;
    switch (format) {
      case 'rgb':
        // 三通道同加：等效亮度增量（不改变量比，不产生色偏）。
        for (var c = 0; c < 3; c++) {
          out[i + c] = _clampTo(base[i + c] + delta, maxValue);
        }
      case 'yuv':
        out[i] = _clampTo(base[i] + delta, maxValue);
      case 'hsl':
        out[i + 2] = _clampTo(base[i + 2] + delta, maxValue);
      default: // mono
        out[i] = _clampTo(base[i] + delta, maxValue);
    }
  }
  return out;
}
