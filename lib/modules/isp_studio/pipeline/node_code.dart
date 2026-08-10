/// ISP Studio 各节点类型的只读源码片段。
///
/// 内容摘录自 pipeline/ 下的实现文件（isp_kernels.dart、image_source.dart、
/// exporters.dart、pipeline_runner.dart），供节点上的「查看代码」按钮展示。
/// 修改实现文件时请同步更新这里的片段。
library;

import 'code_variables.dart';

/// Bayer 图案枚举（isp_kernels.dart）。
const String _bayerPatternCode = r'''
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
}
''';

/// RAW 解包核心：帧字节数 + unpackBayer（isp_kernels.dart），所有 RAW 源共用。
const String _rawUnpackCode = r'''
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
''';

/// RCCB/RCCG 相位表（isp_kernels.dart）。
const String _rccbTablesCode = r'''
/// RCCB 2x2 平铺：R C / C B。
int _rccbAt(int x, int y) => const [0, 3, 3, 2][((y & 1) << 1) | (x & 1)];

/// RCCG 2x2 平铺：R C / C G。
int _rccgAt(int x, int y) => const [0, 3, 3, 1][((y & 1) << 1) | (x & 1)];

// 通道 id：0=R 1=G 2=B 3=C(clear 全色)。
// 解包后由「去马赛克」节点调用 demosaicRccb() 完成插值。
''';

/// RCCC 相位表（isp_kernels.dart）。
const String _rcccTableCode = r'''
/// RCCC 2x2 平铺：R C / C C。
int _rcccAt(int x, int y) => (x & 1) == 0 && (y & 1) == 0 ? 0 : 3;

// 通道 id：0=R 3=C(clear 全色)。
// 解包后由「去马赛克」节点调用 demosaicRccc() 完成插值。
''';

/// RYYCy 相位表（isp_kernels.dart）。
const String _ryycyTableCode = r'''
/// RYYCy 2x2 平铺：R Y / Y Cy。
int _ryycyAt(int x, int y) => const [0, 4, 4, 5][((y & 1) << 1) | (x & 1)];

// 通道 id：0=R 4=Y(黄) 5=Cy(青)。
// 解包后由「去马赛克」节点调用 demosaicRyycy() 完成插值。
''';

/// RGB-IR 相位表（isp_kernels.dart）。
const String _rgbIrTableCode = r'''
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

// 通道 id：0=R 1=G 2=B 6=IR。
// 解包后由「去马赛克」节点调用 demosaicRgbIr() 完成插值。
''';

/// MONO 转 RGB（isp_kernels.dart）。
const String _monoCode = r'''
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
''';

/// 图片源解码（image_source.dart）。
const String _imageSourceCode = r'''
/// 解码图片文件为 16 位量级的交织 RGB（长度 w*h*3），返回 (数据, 宽, 高)。
///
/// 8 位样本按比例放大到 [maxValue]；高位深图片（如 16 位 PNG）
/// 先降为 8 位再放大。文件不存在或无法解码时抛 [StateError]。
Future<(Uint16List, int, int)> decodeImageFileToRgb16(
  String path, {
  required int maxValue,
}) async {
  final file = File(path);
  if (!await file.exists()) throw StateError('图片文件不存在: $path');
  final bytes = await file.readAsBytes();
  var image = img.decodeImage(bytes);
  if (image == null) {
    throw StateError('无法解码图片文件（支持 BMP/JPG/PNG/GIF）: $path');
  }
  if (image.format != img.Format.uint8) {
    image = image.convert(format: img.Format.uint8);
  }
  final w = image.width;
  final h = image.height;
  final out = Uint16List(w * h * 3);
  final scale = maxValue / 255;
  var i = 0;
  for (final px in image) {
    out[i++] = (px.r * scale).round();
    out[i++] = (px.g * scale).round();
    out[i++] = (px.b * scale).round();
  }
  return (out, w, h);
}

// 出边端口决定链格式：out_rgb 直接用上面的 RGB；
// out_yuv / out_hsl 再经 rgbToYuv() / rgbToHsl()（isp_kernels.dart）转换。
''';

/// 视频源解码（video_source.dart）：经 ffmpeg 逐帧抽取。
const String _videoSourceCode = r'''
/// 解码第 [frameIndex] 帧为 16 位量级的交织 RGB（长度 w*h*3），
/// 返回 (数据, 宽, 高)。8 位样本按比例放大到 [maxValue]。
Future<(Uint16List, int, int)> decodeVideoFrameToRgb16(
  String path,
  int frameIndex, {
  required int maxValue,
  String ffmpegPath = '',
}) async {
  // 元信息（尺寸/帧率/帧数）由 `ffmpeg -i` 的 stderr 解析并缓存。
  final info = await videoFileInfo(path, ffmpegPath: ffmpegPath);
  final ffmpeg = (await findFfmpeg(overridePath: ffmpegPath))!;
  final t = frameIndex / info.fps;
  // -ss 在 -i 前：跳到最近关键帧再精确解码到目标时刻
  // （accurate_seek），开销与关键帧间距成正比而非全片。
  final process = await Process.start(ffmpeg, [
    '-hide_banner', '-loglevel', 'error',
    '-ss', t.toStringAsFixed(6),
    '-i', path,
    '-frames:v', '1',
    '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1',
  ]);
  // stdout 收帧字节（stderr 排空防管道阻塞），再 RGBA → 16 位 RGB。
  ...
}

// 出边端口决定链格式：out_rgb 直接用上面的 RGB；
// out_yuv / out_hsl 再经 rgbToYuv() / rgbToHsl()（isp_kernels.dart）转换。
''';

/// 黑电平校正（isp_kernels.dart）。
const String _blackLevelCode = r'''
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
''';

/// 去马赛克：流水线分发（pipeline_runner.dart）。
const String _demosaicDispatchCode = r'''
// pipeline_runner.dart — 按源节点的 CFA 种类分发：
case 'demosaic':
  frame.requireMosaic('去马赛克');
  final w = frame.width;
  final h = frame.height;
  final max = frame.maxValue;
  final data = frame.data;
  frame = _Frame(
    data: switch (frame.cfa) {
      'bayer' => demosaicBilinear(data,
          width: w, height: h, pattern: frame.bayerPattern!),
      'rccb' => demosaicRccb(data, width: w, height: h, maxValue: max),
      'rccg' => demosaicRccb(data,
          width: w, height: h, rccg: true, maxValue: max),
      'rccc' => demosaicRccc(data, width: w, height: h, maxValue: max),
      'ryycy' =>
        demosaicRyycy(data, width: w, height: h, maxValue: max),
      'rgb_ir' => demosaicRgbIr(data,
          width: w,
          height: h,
          maxValue: max,
          irSubtraction: frame.irSubtraction),
      _ => throw StateError('未知 CFA 种类: ${frame.cfa}'),
    },
    format: 'rgb',
    width: w,
    height: h,
    maxValue: max,
  );
''';

/// 双线性去马赛克（isp_kernels.dart）。
const String _demosaicBilinearCode = r'''
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
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++, i += 3) {
      final own = pattern.colorAt(x, y);
      final self = bayer[y * width + x];
      for (var c = 0; c < 3; c++) {
        if (c == own) {
          rgb[i + c] = self;
        } else if (c == 1) {
          // Green at an R/B site: axial neighbors.
          rgb[i + c] =
              _avgNeighbors(bayer, width, height, x, y, pattern, c, _axial);
        } else if (own == 1) {
          // R or B at a G site: the two axial neighbors of that color.
          rgb[i + c] =
              _avgNeighbors(bayer, width, height, x, y, pattern, c, _axial);
        } else {
          // R at a B site or B at an R site: diagonal neighbors.
          rgb[i + c] =
              _avgNeighbors(bayer, width, height, x, y, pattern, c, _diagonal);
        }
      }
    }
  }
  return rgb;
}

// 非 Bayer CFA（RCCB/RCCG、RCCC、RYYCy、RGB-IR）的插值实现：
// demosaicRccb / demosaicRccc / demosaicRyycy / demosaicRgbIr，
// 见 lib/modules/isp_studio/pipeline/isp_kernels.dart。
''';

/// 白平衡（isp_kernels.dart）。
const String _whiteBalanceCode = r'''
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
void applyWhiteBalance(
  Uint16List rgb, {
  required double rGain,
  required double bGain,
  required int maxValue,
}) {
  for (var i = 0; i < rgb.length; i += 3) {
    var r = (rgb[i] * rGain).round();
    var b = (rgb[i + 2] * bGain).round();
    if (r < 0) r = 0;
    if (r > maxValue) r = maxValue;
    if (b < 0) b = 0;
    if (b > maxValue) b = maxValue;
    rgb[i] = r;
    rgb[i + 2] = b;
  }
}
''';

/// CCM（isp_kernels.dart）。
const String _ccmCode = r'''
/// Applies a 3x3 row-major color correction matrix in place,
/// clamping results to 0..[maxValue]. [matrix] must have 9 elements.
void applyCcm(
  Uint16List rgb, {
  required List<double> matrix,
  required int maxValue,
}) {
  if (matrix.length != 9) {
    throw ArgumentError.value(matrix.length, 'matrix', 'CCM must have 9 elements');
  }
  final m = matrix;
  for (var i = 0; i < rgb.length; i += 3) {
    final r = rgb[i].toDouble();
    final g = rgb[i + 1].toDouble();
    final b = rgb[i + 2].toDouble();
    rgb[i] = (m[0] * r + m[1] * g + m[2] * b).round().clamp(0, maxValue).toInt();
    rgb[i + 1] =
        (m[3] * r + m[4] * g + m[5] * b).round().clamp(0, maxValue).toInt();
    rgb[i + 2] =
        (m[6] * r + m[7] * g + m[8] * b).round().clamp(0, maxValue).toInt();
  }
}
''';

/// Gamma / 色调映射（isp_kernels.dart）。
const String _gammaCode = r'''
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
''';

/// 预览节点（pipeline_runner.dart + isp_studio_state.dart 说明）。
const String _previewCode = r'''
// pipeline_runner.dart — 预览是汇点，不改变数据：
case 'preview':
case 'image_output':
case 'video_output':
  // 透传 / 汇点，不改变数据。
  break;

// 链末端把最终帧色调映射为 RGBA8888（若链中没有 Gamma 节点，
// 按 gamma 2.2 做默认色调映射；YUV/HSL 链先转回 RGB）：
if (rgba != null) return rgba;
final max = frame.maxValue;
return switch (frame.format) {
  'rgb' => tonemapToRgba(frame.data, maxValue: max, gamma: 2.2),
  'yuv' =>
    tonemapToRgba(yuvToRgb(frame.data, maxValue: max), maxValue: max, gamma: 2.2),
  'hsl' =>
    tonemapToRgba(hslToRgb(frame.data, maxValue: max), maxValue: max, gamma: 2.2),
  _ => throw StateError('流水线末端不是图像数据（缺少去马赛克）'),
};

// isp_studio_state.dart — runPreview() 拿到 RGBA 后解码为 ui.Image 显示：
ui.decodeImageFromPixels(
    rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
''';

/// 图片输出（exporters.dart）。
const String _imageOutputCode = r'''
/// Encode an RGBA8888 buffer to PNG (lossless).
Uint8List encodePngRgba(Uint8List rgba, int width, int height) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodePng(image);
}

/// Encode an RGBA8888 buffer to JPEG. [quality] 1-100 (100 = best).
Uint8List encodeJpgRgba(Uint8List rgba, int width, int height, int quality) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(image,
      quality: quality.clamp(1, 100), chroma: img.JpegChroma.yuv444);
}

/// compute() 入口：在后台 isolate 中执行一帧并编码为 JPG/PNG。
Future<Uint8List> encodeFrameInIsolate(Map<String, Object?> msg) async {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  final frameIndex = msg['frameIndex'] as int;
  final format = msg['format'] as String? ?? 'jpg';
  final quality = msg['quality'] as int? ?? 100;
  final rgba = await runChainFrame(chain, frameIndex);
  final srcParams = chain.first['params'] as Map<String, Object?>;
  final (w, h) =
      await sourceDimensions(chain.first['typeId'] as String, srcParams);
  return format == 'png'
      ? encodePngRgba(rgba, w, h)
      : encodeJpgRgba(rgba, w, h, quality);
}
''';

/// 视频输出（exporters.dart）。
const String _videoOutputCode = r'''
/// Export a frame sequence to an H.264 MP4 by piping raw RGBA frames to
/// ffmpeg's stdin.
///
/// [frameProvider] is called with each frame index (0..frameCount-1) and must
/// return that frame as RGBA8888 bytes (width*height*4). Frames are pulled
/// one at a time so multi-frame 4K exports never reside in memory at once.
Future<void> exportMp4({
  required String ffmpegPath,
  required String outputPath,
  required int width,
  required int height,
  required int fps,
  required int crf,
  required int frameCount,
  required Future<Uint8List> Function(int frameIndex) frameProvider,
  void Function(int framesDone, int totalFrames)? onProgress,
}) async {
  final process = await Process.start(ffmpegPath, [
    '-y',
    '-f', 'rawvideo',
    '-pix_fmt', 'rgba',
    '-s', '${width}x$height',
    '-r', '$fps',
    '-i', '-',
    '-c:v', 'libx264',
    '-pix_fmt', 'yuv420p',
    '-crf', '${crf.clamp(0, 51)}',
    outputPath,
  ]);

  final stderrBuf = StringBuffer();
  final stderrDone = process.stderr
      .transform(const SystemEncoding().decoder)
      .listen(stderrBuf.write)
      .asFuture<void>();

  try {
    for (var i = 0; i < frameCount; i++) {
      final frame = await frameProvider(i);
      process.stdin.add(frame);
      await process.stdin.flush();
      onProgress?.call(i + 1, frameCount);
    }
    await process.stdin.close();
  } catch (e) {
    process.kill();
    rethrow;
  }

  final exitCode = await process.exitCode;
  await stderrDone;
  if (exitCode != 0) {
    throw StateError('ffmpeg 编码失败 (exit $exitCode):\n$stderrBuf');
  }
}
''';

/// 仪器节点共用的输入：链末端色调映射后的 RGBA8888 显示帧。
const String _instrumentCode = r'''
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

/// 亮度波形监视器：横轴为图像列（降采样到 maxCols），纵轴为亮度级
/// （BT.601 Y，0 在底）。计数表按 级*列数+列 排列。
(Uint32List, int) waveformLuma(Uint8List rgba, int width, int height,
    {int maxCols = 512}) {
  final cols = width < maxCols ? width : maxCols;
  final counts = Uint32List(cols * 256);
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
/// 的 2 倍超采样；中心 (256,256) 为无色），按 Cr*512+Cb 排列。
/// 按像素扫描顺序把相邻像素的色度点连成线（模拟示波器电子束的
/// 连续扫描轨迹）；连线做抗锯齿，按覆盖率把亮度分摊到相邻两格。
Uint32List vectorscope(Uint8List rgba) {
  final counts = Uint32List(512 * 512);
  var prevCb = -1;
  var prevCr = -1;
  for (var i = 0; i + 2 < rgba.length; i += 4) {
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    // BT.601 全范围：Cb/Cr 以 128 为中心；2 倍超采样（0..511，
    // 中心 256），右移 7 位保留半格精度（+64 为半格四舍五入）。
    final cb =
        (256 + ((-43 * r - 85 * g + 128 * b + 64) >> 7)).clamp(0, 511);
    final cr =
        (256 + ((128 * r - 107 * g - 21 * b + 64) >> 7)).clamp(0, 511);
    aaSegment(counts, prevCb, prevCr, cb, cr);
    prevCb = cb;
    prevCr = cr;
  }
  return counts;
}

/// 单格满权重（抗锯齿覆盖率的定点刻度）。
const int kAaFullWeight = 256;

/// 把 (x0,y0)→(x1,y1) 的线段按覆盖率累加进计数表（不含起点，
/// 起点已由上一段计入）。Xiaolin Wu 思路：沿主轴逐格推进，副轴
/// 位置的小数部分决定分摊到相邻两格的权重。
void aaSegment(Uint32List counts, int x0, int y0, int x1, int y1) {
  if (x0 < 0 || (x0 == x1 && y0 == y1)) {
    counts[y1 * 512 + x1] += kAaFullWeight;
    return;
  }
  final dx = x1 - x0;
  final dy = y1 - y0;
  // 快路径：8 连通相邻点（steps <= 1）只落终点一格，无覆盖率分摊。
  if (dx.abs() <= 1 && dy.abs() <= 1) {
    counts[y1 * 512 + x1] += kAaFullWeight;
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
    final w0 = kAaFullWeight - w1;
    final (x, y) = horizontal ? (major, base) : (base, major);
    counts[y * 512 + x] += w0;
    if (w1 > 0) {
      final (xb, yb) = horizontal ? (major, base + 1) : (base + 1, major);
      counts[yb * 512 + xb] += w1;
    }
  }
  // 终点恒满权重（定点累加的舍入误差不留到端点）。
  counts[y1 * 512 + x1] += kAaFullWeight;
}
''';

/// 音频输出（audio_player.dart — 视频预览的音轨回放；含音轨即自动
/// 回放，不依赖图上的连接，连接仅表达音频流向）。
const String _audioOutputCode = r'''
// isp_studio_state.dart — 播放循环在视频含音轨时自动回放：
final wav = await ensureAudioWav(videoPath, ffmpegPath: ffmpegPath);
audio.open(wav);              // MCI waveaudio 设备（winmm.dll）
audio.playFrom(frame / fps);  // 首帧上屏时起播，与视频起点对齐

// 漂移修正：每 20 帧对比 MCI 播放位置与当前帧时刻，超 120ms 重新 seek：
final pos = audio.positionSeconds(); // status <alias> position
if ((videoT - pos).abs() > 0.12) audio.playFrom(videoT);

// audio_player.dart — ffmpeg 抽取音轨为临时 WAV（pcm_s16le 44.1kHz 立体声）：
await Process.run(ffmpeg, [
  '-i', videoPath, '-vn',
  '-acodec', 'pcm_s16le', '-ar', '44100', '-ac', '2', wavPath,
]);
''';

/// 节点类型 id → 只读源码片段。注册表中的每种类型都必须有对应条目。
const Map<String, String> nodeSourceCode = {
  'bayer_source': _bayerPatternCode + _rawUnpackCode,
  'cis_bayer_rggb': _bayerPatternCode + _rawUnpackCode,
  'cis_rccb_rccg': _rccbTablesCode + _rawUnpackCode,
  'cis_rccc': _rcccTableCode + _rawUnpackCode,
  'cis_ryycy': _ryycyTableCode + _rawUnpackCode,
  'cis_rgb_ir': _rgbIrTableCode + _rawUnpackCode,
  'cis_mono': _monoCode + _rawUnpackCode,
  'image_source': _imageSourceCode,
  'video_source': _videoSourceCode,
  'black_level': _blackLevelCode,
  'demosaic': _demosaicDispatchCode + _demosaicBilinearCode,
  'white_balance': _whiteBalanceCode,
  'ccm': _ccmCode,
  'gamma': _gammaCode,
  'preview': _previewCode,
  'histogram': _instrumentCode,
  'waveform': _instrumentCode,
  'vectorscope': _instrumentCode,
  'image_output': _imageOutputCode,
  'video_output': _videoOutputCode,
  'audio_output': _audioOutputCode,
};

/// ---------------------------------------------------------------------------
/// 节点输入/输出变量描述（调试器视角：传入节点的变量 = Input，
/// 节点产出的变量 = Output，其余声明为 Inside 内部变量）。
/// ---------------------------------------------------------------------------

/// RAW 源节点共用输入（文件字节 + 解包参数）。
const List<CodeVariable> _rawSourceInputs = [
  CodeVariable(name: 'bytes', type: 'Uint8List', value: 'RAW 文件字节'),
  CodeVariable(name: 'width', type: 'int', value: '帧宽（节点参数）'),
  CodeVariable(name: 'height', type: 'int', value: '帧高（节点参数）'),
  CodeVariable(name: 'bitDepth', type: 'int', value: '位深 8/10/12/16'),
  CodeVariable(
      name: 'packing',
      type: 'BayerPacking',
      value: 'unpackedLsb / unpackedMsb / mipi'),
  CodeVariable(name: 'littleEndian', type: 'bool', value: '字节序（默认 true）'),
  CodeVariable(name: 'byteOffset', type: 'int', value: '帧起始偏移（默认 0）'),
];

/// RAW 源节点共用输出：解包后的马赛克帧。
const List<CodeVariable> _rawSourceOutputs = [
  CodeVariable(name: 'out', type: 'Uint16List', value: '马赛克帧（w*h）'),
];

/// 仪器节点共用输入（链末端显示帧 + 帧尺寸）。
const List<CodeVariable> _instrumentInputs = [
  CodeVariable(name: 'rgba', type: 'Uint8List', value: '链末端 RGBA8888 显示帧'),
  CodeVariable(name: 'width', type: 'int', value: '帧宽'),
  CodeVariable(name: 'height', type: 'int', value: '帧高'),
];

/// 节点类型 id → Input 变量（传入节点的数据与参数）。
const Map<String, List<CodeVariable>> nodeInputVars = {
  'bayer_source': _rawSourceInputs,
  'cis_bayer_rggb': _rawSourceInputs,
  'cis_rccb_rccg': _rawSourceInputs,
  'cis_rccc': _rawSourceInputs,
  'cis_ryycy': _rawSourceInputs,
  'cis_rgb_ir': _rawSourceInputs,
  'cis_mono': _rawSourceInputs,
  'image_source': [
    CodeVariable(name: 'path', type: 'String', value: '图片文件路径（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '16 位量级最大值'),
  ],
  'video_source': [
    CodeVariable(name: 'path', type: 'String', value: '视频文件路径（节点参数）'),
    CodeVariable(name: 'frameIndex', type: 'int', value: '帧序号（0 起）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '16 位量级最大值'),
    CodeVariable(
        name: 'ffmpegPath', type: 'String', value: 'ffmpeg 路径（节点参数）'),
  ],
  'black_level': [
    CodeVariable(name: 'bayer', type: 'Uint16List', value: '马赛克帧（w*h）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'pattern', type: 'BayerPattern', value: 'CFA 图案'),
    CodeVariable(name: 'r', type: 'double', value: 'R 相偏移（节点参数）'),
    CodeVariable(name: 'gr', type: 'double', value: 'Gr 相偏移（节点参数）'),
    CodeVariable(name: 'gb', type: 'double', value: 'Gb 相偏移（节点参数）'),
    CodeVariable(name: 'b', type: 'double', value: 'B 相偏移（节点参数）'),
  ],
  'demosaic': [
    CodeVariable(name: 'bayer', type: 'Uint16List', value: '马赛克帧（w*h）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(
        name: 'pattern', type: 'BayerPattern', value: 'CFA 图案（Bayer 时）'),
    CodeVariable(
        name: 'maxValue', type: 'int', value: '采样最大值（非 Bayer CFA）'),
    CodeVariable(
        name: 'irSubtraction', type: 'double', value: 'IR 扣除比例（RGB-IR）'),
  ],
  'white_balance': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'rGain', type: 'double', value: 'R 增益（节点参数）'),
    CodeVariable(name: 'bGain', type: 'double', value: 'B 增益（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
    CodeVariable(name: 'mode', type: 'String', value: 'manual / auto'),
  ],
  'ccm': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(
        name: 'matrix', type: 'List<double>', value: '3x3 校正矩阵（9 元素）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'gamma': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
    CodeVariable(name: 'gamma', type: 'double', value: '伽马值（节点参数）'),
    CodeVariable(name: 'brightness', type: 'double', value: '亮度（节点参数）'),
    CodeVariable(name: 'contrast', type: 'double', value: '对比度（节点参数）'),
  ],
  'preview': [
    CodeVariable(
        name: 'frame', type: 'Uint16List', value: '链末端帧数据（rgb/yuv/hsl）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'histogram': _instrumentInputs,
  'waveform': _instrumentInputs,
  'vectorscope': _instrumentInputs,
  'image_output': [
    CodeVariable(name: 'rgba', type: 'Uint8List', value: 'RGBA8888 帧（w*h*4）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'format', type: 'String', value: 'jpg / png（节点参数）'),
    CodeVariable(name: 'quality', type: 'int', value: 'JPG 质量 1-100'),
  ],
  'video_output': [
    CodeVariable(name: 'frame', type: 'Uint8List', value: '逐帧 RGBA8888 数据'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'fps', type: 'int', value: '帧率（节点参数）'),
    CodeVariable(name: 'crf', type: 'int', value: 'x264 质量 0-51'),
  ],
  'audio_output': [
    CodeVariable(name: 'wav', type: 'String', value: 'ffmpeg 抽取的临时 WAV 路径'),
    CodeVariable(
        name: 'videoT', type: 'double', value: '当前帧时刻（秒，帧号/帧率）'),
    CodeVariable(
        name: 'pos', type: 'double', value: 'MCI 播放位置（秒，漂移修正依据）'),
  ],
};

/// 节点类型 id → Output 变量（节点产出的数据）。
const Map<String, List<CodeVariable>> nodeOutputVars = {
  'bayer_source': _rawSourceOutputs,
  'cis_bayer_rggb': _rawSourceOutputs,
  'cis_rccb_rccg': _rawSourceOutputs,
  'cis_rccc': _rawSourceOutputs,
  'cis_ryycy': _rawSourceOutputs,
  'cis_rgb_ir': _rawSourceOutputs,
  'cis_mono': [
    CodeVariable(
        name: 'rgb', type: 'Uint16List', value: '灰度复制三通道（w*h*3）'),
  ],
  'image_source': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '交织 RGB（w*h*3，16 位量级）'),
    CodeVariable(name: 'w', type: 'int', value: '图片宽'),
    CodeVariable(name: 'h', type: 'int', value: '图片高'),
  ],
  'video_source': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '交织 RGB（w*h*3，16 位量级）'),
    CodeVariable(name: 'w', type: 'int', value: '视频帧宽'),
    CodeVariable(name: 'h', type: 'int', value: '视频帧高'),
  ],
  'black_level': [
    CodeVariable(
        name: 'bayer', type: 'Uint16List', value: '黑电平校正后（原地修改）'),
  ],
  'demosaic': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '插值 RGB（w*h*3）'),
  ],
  'white_balance': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '增益后（原地修改）'),
    CodeVariable(
        name: 'rGain', type: 'double', value: 'auto 模式的实际 R 增益'),
    CodeVariable(
        name: 'bGain', type: 'double', value: 'auto 模式的实际 B 增益'),
  ],
  'ccm': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '矩阵校正后（原地修改）'),
  ],
  'gamma': [
    CodeVariable(
        name: 'out', type: 'Uint8List', value: '色调映射 RGBA（w*h*4）'),
  ],
  'preview': [
    CodeVariable(name: 'rgba', type: 'Uint8List', value: 'RGBA8888 显示帧'),
  ],
  'histogram': [
    CodeVariable(name: 'r', type: 'Uint32List', value: 'R 直方图（256 桶）'),
    CodeVariable(name: 'g', type: 'Uint32List', value: 'G 直方图（256 桶）'),
    CodeVariable(name: 'b', type: 'Uint32List', value: 'B 直方图（256 桶）'),
  ],
  'waveform': [
    CodeVariable(
        name: 'counts', type: 'Uint32List', value: '亮度波形计数（级*列数+列）'),
    CodeVariable(name: 'columns', type: 'int', value: '降采样后的列数'),
  ],
  'vectorscope': [
    CodeVariable(
        name: 'counts', type: 'Uint32List', value: 'Cb/Cr 计数（256x256）'),
  ],
  'image_output': [
    CodeVariable(
        name: 'bytes', type: 'Uint8List', value: '编码后的 JPG/PNG 文件字节'),
  ],
  'video_output': [
    CodeVariable(
        name: 'outputPath', type: 'String', value: '写出的 MP4 文件'),
  ],
  'audio_output': [
    CodeVariable(name: 'playing', type: 'bool', value: '是否正在回放'),
  ],
};

/// 调试器视角的变量分组：Input（传入）、Output（产出）、Inside（内部）。
class NodeVariableGroups {
  final List<CodeVariable> inputs;
  final List<CodeVariable> outputs;
  final List<CodeVariable> inside;

  const NodeVariableGroups({
    required this.inputs,
    required this.outputs,
    required this.inside,
  });
}

/// 按 Input / Output / Inside 分组 [typeId] 节点代码 [code] 中的变量。
///
/// Input / Output 来自上面的静态描述；Inside 为代码片段中解析出的、
/// 不属于输入输出的其余变量声明。
NodeVariableGroups groupNodeVariables(String typeId, String code) {
  final inputs = nodeInputVars[typeId] ?? const <CodeVariable>[];
  final outputs = nodeOutputVars[typeId] ?? const <CodeVariable>[];
  final ioNames = <String>{
    for (final v in inputs) v.name,
    for (final v in outputs) v.name,
  };
  final inside = [
    for (final v in extractVariables(code))
      if (!ioNames.contains(v.name)) v,
  ];
  return NodeVariableGroups(inputs: inputs, outputs: outputs, inside: inside);
}
