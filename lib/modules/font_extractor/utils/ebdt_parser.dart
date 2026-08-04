import 'dart:io';
import 'dart:typed_data';

/// Extracts native 1-bit embedded bitmap strikes (EBLC/EBDT tables)
/// directly from TrueType/OpenType/TTC font files (e.g. SimSun, MingLiU, NSimSun).
///
/// Returns null if the font file lacks EBLC/EBDT tables or if the requested
/// glyph does not have an embedded bitmap strike.
class EmbeddedBitmapParser {
  /// Decoded indexFormat-5 glyphIdArrays (glyphId → array index), keyed by
  /// font path + subtable position. Fonts don't change while the app runs.
  static final Map<String, Map<int, int>> _fmt5GlyphArrayCache = {};

  /// Reads a native 1-bit embedded bitmap for [codePoint] at [targetSize] px
  /// from [path] and returns a [cellWidth]x[cellHeight] grayscale (0 or 255) Uint8List.
  static Future<Uint8List?> readNativeBitmap({
    required String path,
    required int codePoint,
    required int targetSize,
    required int cellWidth,
    required int cellHeight,
  }) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final length = await raf.length();
      if (length < 32) return null;

      final head = await raf.read(16);
      if (head.length < 12) return null;
      int sfntOffset = 0;
      if (_tag(head, 0) == 'ttcf') {
        sfntOffset = ByteData.sublistView(head).getUint32(12, Endian.big);
      }

      await raf.setPosition(sfntOffset);
      final sfnt = await raf.read(12);
      if (sfnt.length < 12) return null;
      final numTables = ByteData.sublistView(sfnt).getUint16(4, Endian.big);
      if (numTables <= 0 || numTables > 256) return null;

      final dir = await raf.read(numTables * 16);
      if (dir.length < numTables * 16) return null;
      final dirData = ByteData.sublistView(dir);

      int? cmapOffset, cmapLen;
      int? eblcOffset, eblcLen;
      int? ebdtOffset, ebdtLen;

      for (int i = 0; i < numTables; i++) {
        final tagStr = _tag(dir, i * 16);
        final off = dirData.getUint32(i * 16 + 8, Endian.big);
        final len = dirData.getUint32(i * 16 + 12, Endian.big);

        if (tagStr == 'cmap') {
          cmapOffset = off;
          cmapLen = len;
        } else if (tagStr == 'EBLC' ||
            tagStr == 'eblc' ||
            tagStr == 'CBLC' ||
            tagStr == 'cblc' ||
            tagStr == 'bloc') {
          eblcOffset = off;
          eblcLen = len;
        } else if (tagStr == 'EBDT' ||
            tagStr == 'ebdt' ||
            tagStr == 'CBDT' ||
            tagStr == 'cbdt' ||
            tagStr == 'bdat') {
          ebdtOffset = off;
          ebdtLen = len;
        }
      }

      if (cmapOffset == null ||
          eblcOffset == null ||
          ebdtOffset == null ||
          cmapLen == null ||
          eblcLen == null ||
          ebdtLen == null) {
        return null; // Font has no native embedded bitmap tables
      }

      // 1. Read cmap to get Glyph ID
      await raf.setPosition(cmapOffset);
      final cmapBytes = await raf.read(cmapLen);
      if (cmapBytes.length < cmapLen) return null;
      final cmapData = ByteData.sublistView(cmapBytes);
      final glyphId = _getGlyphId(cmapData, cmapLen, codePoint);
      if (glyphId == null || glyphId == 0) return null;

      // 2. Read EBLC table
      await raf.setPosition(eblcOffset);
      final eblcBytes = await raf.read(eblcLen);
      if (eblcBytes.length < eblcLen) return null;
      final eblcData = ByteData.sublistView(eblcBytes);

      final numSizes = eblcData.getUint32(4, Endian.big);
      if (numSizes <= 0 || numSizes > 100) return null;

      // Find candidate bitmap size tables (sorted by proximity to targetSize ppemY)
      final sizeIndexes = List<int>.generate(numSizes, (i) => i);
      sizeIndexes.sort((a, b) {
        final ppemYA = eblcData.getUint8(8 + a * 48 + 45);
        final ppemYB = eblcData.getUint8(8 + b * 48 + 45);
        return (ppemYA - targetSize).abs().compareTo((ppemYB - targetSize).abs());
      });

      int subTablePos = -1;
      int matchedFirstG = -1;

      for (final sizeIdx in sizeIndexes) {
        final pSize = 8 + sizeIdx * 48;
        if (pSize + 48 > eblcLen) continue;
        final ppemY = eblcData.getUint8(pSize + 45);
        if ((ppemY - targetSize).abs() > 8) continue;

        final indexSubTableArrayOffset = eblcData.getUint32(pSize, Endian.big);
        final numberOfIndexSubTables = eblcData.getUint32(pSize + 8, Endian.big);

        for (int i = 0; i < numberOfIndexSubTables; i++) {
          final p = indexSubTableArrayOffset + i * 8;
          if (p + 8 > eblcLen) break;
          final firstG = eblcData.getUint16(p, Endian.big);
          final lastG = eblcData.getUint16(p + 2, Endian.big);
          if (glyphId >= firstG && glyphId <= lastG) {
            final addOff = eblcData.getUint32(p + 4, Endian.big);
            subTablePos = indexSubTableArrayOffset + addOff;
            matchedFirstG = firstG;
            break;
          }
        }
        if (subTablePos >= 0) break;
      }

      if (subTablePos < 0 || subTablePos + 8 > eblcLen || matchedFirstG < 0) {
        return null;
      }

      final indexFormat = eblcData.getUint16(subTablePos, Endian.big);
      final imageFormat = eblcData.getUint16(subTablePos + 2, Endian.big);
      final imageDataOffset = eblcData.getUint32(subTablePos + 4, Endian.big);

      // bigGlyphMetrics live in the index subtable header for index formats
      // 2 and 5 (used by imageFormat 5 glyphs, which carry no per-glyph
      // metrics): height u8 @+12, width u8 @+13.
      int bigHeight = 0, bigWidth = 0;
      if ((indexFormat == 2 || indexFormat == 5) &&
          subTablePos + 14 <= eblcLen) {
        bigHeight = eblcData.getUint8(subTablePos + 12);
        bigWidth = eblcData.getUint8(subTablePos + 13);
      }

      int glyphEbdtOffset = -1;
      int glyphEbdtLen = 0;

      if (indexFormat == 1) {
        final idx = glyphId - matchedFirstG;
        final p = subTablePos + 8 + idx * 4;
        if (p + 8 <= eblcLen) {
          glyphEbdtOffset = imageDataOffset + eblcData.getUint32(p, Endian.big);
          final nextOff = imageDataOffset + eblcData.getUint32(p + 4, Endian.big);
          glyphEbdtLen = nextOff - glyphEbdtOffset;
        }
      } else if (indexFormat == 2) {
        final imageSize = eblcData.getUint32(subTablePos + 8, Endian.big);
        glyphEbdtOffset = imageDataOffset + (glyphId - matchedFirstG) * imageSize;
        glyphEbdtLen = imageSize;
      } else if (indexFormat == 3) {
        final idx = glyphId - matchedFirstG;
        final p = subTablePos + 8 + idx * 2;
        if (p + 4 <= eblcLen) {
          glyphEbdtOffset =
              imageDataOffset + eblcData.getUint16(p, Endian.big);
          final nextOff =
              imageDataOffset + eblcData.getUint16(p + 2, Endian.big);
          glyphEbdtLen = nextOff - glyphEbdtOffset;
        }
      } else if (indexFormat == 5) {
        // Constant image size with an explicit glyphIdArray — used e.g. by
        // MS Gothic/MS Mincho for their CJK strikes. Layout: imageSize u32
        // @+8, bigGlyphMetrics 8B @+12, numGlyphs u32 @+20, then
        // uint16 glyphIdArray[numGlyphs] @+24. (The numGlyphs field is
        // easy to miss; without it the two header words 0/numGlyphs get
        // misread as array entries and shift every index, producing
        // garbage bitmaps.) The decoded map is cached per subtable because
        // CJK subtables hold thousands of entries.
        final imageSize = eblcData.getUint32(subTablePos + 8, Endian.big);
        final numGlyphs = subTablePos + 24 <= eblcLen
            ? eblcData.getUint32(subTablePos + 20, Endian.big)
            : 0;
        final cacheKey = '$path|$targetSize|$subTablePos';
        var gidMap = _fmt5GlyphArrayCache[cacheKey];
        if (gidMap == null) {
          gidMap = <int, int>{};
          var p = subTablePos + 24;
          for (var i = 0; i < numGlyphs && p + 2 <= eblcLen; i++, p += 2) {
            gidMap.putIfAbsent(
                eblcData.getUint16(p, Endian.big), () => i);
          }
          _fmt5GlyphArrayCache[cacheKey] = gidMap;
        }
        final arrayIndex = gidMap[glyphId];
        if (arrayIndex != null) {
          glyphEbdtOffset = imageDataOffset + arrayIndex * imageSize;
          glyphEbdtLen = imageSize;
        }
      }

      if (glyphEbdtOffset < 0 || glyphEbdtLen <= 0) return null;

      // 3. Read EBDT image data
      final absEbdtPos = ebdtOffset + glyphEbdtOffset;
      if (absEbdtPos + glyphEbdtLen > length) return null;

      await raf.setPosition(absEbdtPos);
      final imgBytes = await raf.read(glyphEbdtLen);
      if (imgBytes.length < glyphEbdtLen) return null;
      final imgData = ByteData.sublistView(imgBytes);

      int width = 0, height = 0;
      int dataStart = 0;

      if (imageFormat == 1 || imageFormat == 2) {
        height = imgData.getUint8(0);
        width = imgData.getUint8(1);
        dataStart = 5;
      } else if (imageFormat == 5) {
        // No per-glyph metrics: the dimensions come from the index
        // subtable's bigGlyphMetrics (e.g. 8x16 for half-width glyphs in
        // a 16px strike), not from the target size.
        height = bigHeight > 0 ? bigHeight : targetSize;
        width = bigWidth > 0 ? bigWidth : targetSize;
        dataStart = 0;
      } else if (imageFormat == 6 || imageFormat == 7) {
        height = imgData.getUint8(0);
        width = imgData.getUint8(1);
        dataStart = 8;
      } else {
        return null;
      }

      if (width <= 0 || height <= 0 || width > 128 || height > 128) return null;

      // Decode 1-bit packed MSB pixels into cellWidth x cellHeight Uint8List
      final pixels = Uint8List(cellWidth * cellHeight);
      final rawBits = imgBytes.sublist(dataStart);
      final rowBytes = (width + 7) ~/ 8;

      final startX = ((cellWidth - width) ~/ 2).clamp(0, cellWidth - 1);
      final startY = ((cellHeight - height) ~/ 2).clamp(0, cellHeight - 1);

      for (int y = 0; y < height; y++) {
        final rowByteOffset = y * rowBytes;
        for (int x = 0; x < width; x++) {
          final byteIdx = rowByteOffset + (x ~/ 8);
          final bitShift = 7 - (x % 8);
          if (byteIdx < rawBits.length) {
            final bit = (rawBits[byteIdx] >> bitShift) & 1;
            if (bit == 1) {
              final px = startX + x;
              final py = startY + y;
              if (px >= 0 && px < cellWidth && py >= 0 && py < cellHeight) {
                pixels[py * cellWidth + px] = 255;
              }
            }
          }
        }
      }

      return pixels;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  static int? _getGlyphId(ByteData data, int tableLen, int codePoint) {
    final numSubtables = data.getUint16(2, Endian.big);
    if (numSubtables <= 0) return null;

    final subtables = <(int format, int offset, int score)>[];
    for (int i = 0; i < numSubtables; i++) {
      final p = 4 + i * 8;
      if (p + 8 > tableLen) break;
      final platformID = data.getUint16(p, Endian.big);
      final encodingID = data.getUint16(p + 2, Endian.big);
      final subOffset = data.getUint32(p + 4, Endian.big);
      if (subOffset + 4 > tableLen) continue;

      final format = data.getUint16(subOffset, Endian.big);
      int score = 0;
      if (format == 4) {
        score = codePoint > 0xFFFF ? 10 : 100;
      } else if (format == 12) {
        score = codePoint > 0xFFFF ? 120 : 90;
      } else {
        continue;
      }

      if (platformID == 3) score += 10;
      if (platformID == 3 && encodingID == 1) score += 5;

      subtables.add((format, subOffset, score));
    }

    subtables.sort((a, b) => b.$3.compareTo(a.$3));

    for (final sub in subtables) {
      final gid = _lookupInSubtable(data, tableLen, sub.$1, sub.$2, codePoint);
      if (gid != null && gid > 0) return gid;
    }
    return null;
  }

  static int? _lookupInSubtable(
      ByteData data, int tableLen, int format, int bestOffset, int codePoint) {
    if (format == 4) {
      final segCount = data.getUint16(bestOffset + 6, Endian.big) ~/ 2;
      final endBase = bestOffset + 14;
      final startBase = endBase + segCount * 2 + 2;
      final deltaBase = startBase + segCount * 2;
      final rangeOffsetBase = deltaBase + segCount * 2;

      int segIndex = -1;
      for (int i = 0; i < segCount; i++) {
        final endCode = data.getUint16(endBase + i * 2, Endian.big);
        if (codePoint <= endCode) {
          final startCode = data.getUint16(startBase + i * 2, Endian.big);
          if (codePoint >= startCode) {
            segIndex = i;
          }
          break;
        }
      }
      if (segIndex < 0) return null;

      final idDelta = data.getInt16(deltaBase + segIndex * 2, Endian.big);
      final idRangeOffset =
          data.getUint16(rangeOffsetBase + segIndex * 2, Endian.big);

      if (idRangeOffset == 0) {
        return (codePoint + idDelta) & 0xFFFF;
      } else {
        final ptr = (rangeOffsetBase + segIndex * 2) +
            idRangeOffset +
            (codePoint - data.getUint16(startBase + segIndex * 2, Endian.big)) *
                2;
        if (ptr + 2 > tableLen) return null;
        final g = data.getUint16(ptr, Endian.big);
        if (g == 0) return 0;
        return (g + idDelta) & 0xFFFF;
      }
    } else if (format == 12) {
      final nGroups = data.getUint32(bestOffset + 12, Endian.big);
      for (int i = 0; i < nGroups; i++) {
        final p = bestOffset + 16 + i * 12;
        if (p + 12 > tableLen) break;
        final start = data.getUint32(p, Endian.big);
        final end = data.getUint32(p + 4, Endian.big);
        if (codePoint >= start && codePoint <= end) {
          final startGlyph = data.getUint32(p + 8, Endian.big);
          return startGlyph + (codePoint - start);
        }
      }
    }
    return null;
  }

  static String _tag(List<int> bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
}
