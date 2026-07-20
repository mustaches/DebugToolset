import 'dart:typed_data';

/// A glyph whose bitmap has already been packed into bytes.
class PackedGlyph {
  /// First code point of the grapheme (lookup key).
  final int codePoint;

  /// Cell width / height in pixels.
  final int width;
  final int height;

  /// Advance width in pixels.
  final int advance;

  /// Drawing offset inside the cell (0 for fixed-cell extraction).
  final int offsetX;
  final int offsetY;

  /// Packed bitmap bytes.
  final Uint8List data;

  const PackedGlyph({
    required this.codePoint,
    required this.width,
    required this.height,
    required this.advance,
    required this.offsetX,
    required this.offsetY,
    required this.data,
  });
}
