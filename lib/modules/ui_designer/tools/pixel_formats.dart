import 'dart:typed_data';

/// Pixel formats supported by the image converter and raw extractor.
enum PixelFormat {
  rgb565('RGB565', 2),
  rgb888('RGB888', 3),
  argb8888('ARGB8888', 4),
  gray8('灰度8bit', 1),
  mono1('单色1bpp', 0);

  const PixelFormat(this.label, this.bytesPerPixel);
  final String label;

  /// 0 for packed 1bpp.
  final int bytesPerPixel;
}

/// Converts packed RGBA8888 data (4 bytes per pixel, row major) into the
/// target [format]. When [columnMajor] is set, pixels are scanned column
/// by column instead of row by row.
Uint8List rgbaToRaw(
  Uint8List rgba,
  int width,
  int height,
  PixelFormat format, {
  bool columnMajor = false,
}) {
  final pixelCount = width * height;
  int pixelIndex(int i) {
    // i is the scan-order index; map it to a row-major pixel index.
    if (!columnMajor) return i;
    final col = i ~/ height;
    final row = i % height;
    return row * width + col;
  }

  switch (format) {
    case PixelFormat.rgb565:
      final out = Uint8List(pixelCount * 2);
      for (var i = 0; i < pixelCount; i++) {
        final p = pixelIndex(i) * 4;
        final v = ((rgba[p] >> 3) << 11) |
            ((rgba[p + 1] >> 2) << 5) |
            (rgba[p + 2] >> 3);
        out[i * 2] = (v >> 8) & 0xFF;
        out[i * 2 + 1] = v & 0xFF;
      }
      return out;
    case PixelFormat.rgb888:
      final out = Uint8List(pixelCount * 3);
      for (var i = 0; i < pixelCount; i++) {
        final p = pixelIndex(i) * 4;
        out[i * 3] = rgba[p];
        out[i * 3 + 1] = rgba[p + 1];
        out[i * 3 + 2] = rgba[p + 2];
      }
      return out;
    case PixelFormat.argb8888:
      final out = Uint8List(pixelCount * 4);
      for (var i = 0; i < pixelCount; i++) {
        final p = pixelIndex(i) * 4;
        out[i * 4] = rgba[p + 3];
        out[i * 4 + 1] = rgba[p];
        out[i * 4 + 2] = rgba[p + 1];
        out[i * 4 + 3] = rgba[p + 2];
      }
      return out;
    case PixelFormat.gray8:
      final out = Uint8List(pixelCount);
      for (var i = 0; i < pixelCount; i++) {
        final p = pixelIndex(i) * 4;
        out[i] = (rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/
            1000;
      }
      return out;
    case PixelFormat.mono1:
      final stride = (width + 7) ~/ 8;
      final out = Uint8List(columnMajor
          ? ((height + 7) ~/ 8) * width
          : stride * height);
      for (var i = 0; i < pixelCount; i++) {
        final src = pixelIndex(i) * 4;
        final lum = (rgba[src] * 299 +
                rgba[src + 1] * 587 +
                rgba[src + 2] * 114) ~/
            1000;
        if (lum >= 128) {
          if (columnMajor) {
            final col = i ~/ height;
            final row = i % height;
            out[col * ((height + 7) ~/ 8) + (row ~/ 8)] |=
                0x80 >> (row % 8);
          } else {
            final row = i ~/ width;
            final col = i % width;
            out[row * stride + (col ~/ 8)] |= 0x80 >> (col % 8);
          }
        }
      }
      return out;
  }
}

/// Decodes raw pixel bytes back into RGBA8888 for preview. Inverse of
/// [rgbaToRaw] (alpha is forced to opaque).
Uint8List rawToRgba(
  Uint8List raw,
  int width,
  int height,
  PixelFormat format, {
  bool columnMajor = false,
  int offset = 0,
  int stride = 0, // bytes per scan line/column; 0 = tightly packed
}) {
  final out = Uint8List(width * height * 4);
  final rowStride = stride > 0 ? stride : _packedStride(width, format);
  final colStride = stride > 0 ? stride : _packedStride(height, format);

  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      final base = columnMajor
          ? offset + col * colStride
          : offset + row * rowStride;
      final o = (row * width + col) * 4;
      out[o + 3] = 255;
      switch (format) {
        case PixelFormat.rgb565:
          final i = base + (columnMajor ? row : col) * 2;
          if (i + 1 >= raw.length) break;
          final v = (raw[i] << 8) | raw[i + 1];
          out[o] = (((v >> 11) & 0x1F) * 255) ~/ 31;
          out[o + 1] = (((v >> 5) & 0x3F) * 255) ~/ 63;
          out[o + 2] = ((v & 0x1F) * 255) ~/ 31;
        case PixelFormat.rgb888:
          final i = base + (columnMajor ? row : col) * 3;
          if (i + 2 >= raw.length) break;
          out[o] = raw[i];
          out[o + 1] = raw[i + 1];
          out[o + 2] = raw[i + 2];
        case PixelFormat.argb8888:
          final i = base + (columnMajor ? row : col) * 4;
          if (i + 3 >= raw.length) break;
          out[o + 3] = raw[i];
          out[o] = raw[i + 1];
          out[o + 1] = raw[i + 2];
          out[o + 2] = raw[i + 3];
        case PixelFormat.gray8:
          final i = base + (columnMajor ? row : col);
          if (i >= raw.length) break;
          out[o] = out[o + 1] = out[o + 2] = raw[i];
        case PixelFormat.mono1:
          final bitIndex = columnMajor ? row : col;
          final i = base + bitIndex ~/ 8;
          if (i >= raw.length) break;
          final bit = (raw[i] >> (7 - (bitIndex % 8))) & 1;
          final v = bit == 1 ? 255 : 0;
          out[o] = out[o + 1] = out[o + 2] = v;
      }
    }
  }
  return out;
}

int _packedStride(int pixels, PixelFormat format) {
  switch (format) {
    case PixelFormat.mono1:
      return (pixels + 7) ~/ 8;
    default:
      return pixels * format.bytesPerPixel;
  }
}

/// Renders raw bytes as a C array body (without the declaration).
String bytesToCArrayBody(List<int> bytes, {int perLine = 16}) {
  final sb = StringBuffer();
  for (var i = 0; i < bytes.length; i += perLine) {
    final end = i + perLine > bytes.length ? bytes.length : i + perLine;
    sb.writeln(
        '  ${bytes.sublist(i, end).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')},');
  }
  return sb.toString();
}
