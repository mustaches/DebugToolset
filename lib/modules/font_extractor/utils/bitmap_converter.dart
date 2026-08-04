import 'dart:typed_data';

/// Bit depth of the packed glyph bitmap.
enum BitmapBitDepth {
  /// 1 bit per pixel (monochrome), packed 8 pixels per byte.
  one,

  /// 8 bits per pixel (grayscale), one byte per pixel.
  eight,
}

/// How pixels are packed into bytes.
enum BitmapScanMode {
  /// Row-major: for 1bpp each row is ceil(width/8) bytes, MSB first;
  /// for 8bpp pixels are emitted left-to-right, top-to-bottom.
  rowMajor,

  /// Column-major (SSD1306 style): for 1bpp each byte covers an
  /// 8-pixel vertical strip, LSB first (bit 0 = top pixel);
  /// for 8bpp pixels are emitted top-to-bottom, left-to-right.
  columnMajor,
}

/// Packs a grayscale pixel matrix into bytes.
///
/// [pixels] is a list of grayscale values (0-255) with length
/// width*height, ordered left-to-right, top-to-bottom.
/// Pixels with value >= [threshold] count as "on" for 1bpp.
Uint8List packBitmap({
  required List<int> pixels,
  required int width,
  required int height,
  required BitmapBitDepth depth,
  required BitmapScanMode scan,
  int threshold = 128,
}) {
  if (pixels.length != width * height) {
    throw ArgumentError(
      'pixels length ${pixels.length} != $width*$height',
    );
  }
  if (depth == BitmapBitDepth.one) {
    return scan == BitmapScanMode.rowMajor
        ? _pack1bppRowMajor(pixels, width, height, threshold)
        : _pack1bppColumnMajor(pixels, width, height, threshold);
  }
  return scan == BitmapScanMode.rowMajor
      ? _pack8bppRowMajor(pixels, width, height)
      : _pack8bppColumnMajor(pixels, width, height);
}

Uint8List _pack1bppRowMajor(
  List<int> pixels,
  int width,
  int height,
  int threshold,
) {
  final bytesPerRow = (width + 7) >> 3;
  final out = Uint8List(bytesPerRow * height);
  int byteIndex = 0;
  for (int y = 0; y < height; y++) {
    int current = 0;
    int bit = 7;
    for (int x = 0; x < width; x++) {
      if (pixels[y * width + x] >= threshold) {
        current |= 1 << bit;
      }
      bit--;
      if (bit < 0) {
        out[byteIndex++] = current;
        current = 0;
        bit = 7;
      }
    }
    if (bit != 7) {
      out[byteIndex++] = current;
    }
  }
  return out;
}

Uint8List _pack1bppColumnMajor(
  List<int> pixels,
  int width,
  int height,
  int threshold,
) {
  final pages = (height + 7) >> 3;
  final out = Uint8List(pages * width);
  int byteIndex = 0;
  for (int page = 0; page < pages; page++) {
    for (int x = 0; x < width; x++) {
      int current = 0;
      for (int bit = 0; bit < 8; bit++) {
        final y = page * 8 + bit;
        if (y < height && pixels[y * width + x] >= threshold) {
          current |= 1 << bit;
        }
      }
      out[byteIndex++] = current;
    }
  }
  return out;
}

Uint8List _pack8bppRowMajor(List<int> pixels, int width, int height) {
  return Uint8List.fromList(pixels);
}

Uint8List _pack8bppColumnMajor(List<int> pixels, int width, int height) {
  final out = Uint8List(width * height);
  int i = 0;
  for (int x = 0; x < width; x++) {
    for (int y = 0; y < height; y++) {
      out[i++] = pixels[y * width + x];
    }
  }
  return out;
}

/// Number of bytes [packBitmap] will produce for the given parameters.
int packedByteLength({
  required int width,
  required int height,
  required BitmapBitDepth depth,
  required BitmapScanMode scan,
}) {
  if (depth == BitmapBitDepth.eight) return width * height;
  return scan == BitmapScanMode.rowMajor
      ? ((width + 7) >> 3) * height
      : width * ((height + 7) >> 3);
}

/// Inverse of [packBitmap]: decodes packed bytes back into a grayscale
/// pixel matrix (length width*height, left-to-right, top-to-bottom).
/// 1bpp pixels come out as 0 or 255.
///
/// Throws [FormatException] when [bytes] is shorter than expected.
Uint8List unpackBitmap({
  required List<int> bytes,
  required int width,
  required int height,
  required BitmapBitDepth depth,
  required BitmapScanMode scan,
}) {
  final expected = packedByteLength(
    width: width,
    height: height,
    depth: depth,
    scan: scan,
  );
  if (bytes.length < expected) {
    throw FormatException(
      'bitmap data too short: ${bytes.length} < $expected bytes',
    );
  }
  final out = Uint8List(width * height);
  if (depth == BitmapBitDepth.eight) {
    if (scan == BitmapScanMode.rowMajor) {
      out.setRange(0, width * height, bytes);
    } else {
      int i = 0;
      for (int x = 0; x < width; x++) {
        for (int y = 0; y < height; y++) {
          out[y * width + x] = bytes[i++];
        }
      }
    }
    return out;
  }
  if (scan == BitmapScanMode.rowMajor) {
    final bytesPerRow = (width + 7) >> 3;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (bytes[y * bytesPerRow + (x >> 3)] & (0x80 >> (x & 7)) != 0) {
          out[y * width + x] = 255;
        }
      }
    }
  } else {
    final pages = (height + 7) >> 3;
    for (int page = 0; page < pages; page++) {
      for (int x = 0; x < width; x++) {
        final b = bytes[page * width + x];
        for (int bit = 0; bit < 8; bit++) {
          final y = page * 8 + bit;
          if (y < height && b & (1 << bit) != 0) {
            out[y * width + x] = 255;
          }
        }
      }
    }
  }
  return out;
}
