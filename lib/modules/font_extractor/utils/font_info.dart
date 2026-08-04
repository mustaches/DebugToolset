import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Basic font metadata extracted from the TrueType/OpenType `name` table.
class FontNameInfo {
  /// Full font name (nameID 4), e.g. "Arial".
  final String? fontName;

  /// Version string (nameID 5), e.g. "Version 7.06".
  final String? version;

  /// Font family (nameID 1).
  final String? family;

  /// Font subfamily (nameID 2).
  final String? subfamily;

  const FontNameInfo({
    this.fontName,
    this.version,
    this.family,
    this.subfamily,
  });

  /// A readable display name, preferring the full font name.
  String? get displayName => fontName ?? family;

  const FontNameInfo.empty()
      : fontName = null,
        version = null,
        family = null,
        subfamily = null;
}

/// Common Windows `name` table language IDs keyed by locale tag.
const Map<String, List<int>> _windowsLanguageIds = {
  'zh': [0x0804, 0x0404, 0x0C04, 0x1404, 0x1004],
  'zh-CN': [0x0804],
  'zh-TW': [0x0404],
  'zh-HK': [0x0C04],
  'zh-MO': [0x1404],
  'zh-SG': [0x1004],
  'en': [0x0409, 0x0809, 0x0C09, 0x1009, 0x1409, 0x1809, 0x1C09],
  'en-US': [0x0409],
  'en-GB': [0x0809],
  'ja': [0x0411],
  'ko': [0x0412],
  'de': [0x0407, 0x0807, 0x0C07, 0x1007],
  'fr': [0x040C, 0x080C, 0x0C0C, 0x100C, 0x140C, 0x180C],
  'es': [0x0C0A, 0x040A, 0x080A, 0x100A, 0x140A, 0x180A, 0x1C0A, 0x200A, 0x240A, 0x280A, 0x2C0A, 0x300A, 0x340A, 0x380A, 0x3C0A, 0x400A, 0x440A, 0x480A, 0x4C0A, 0x500A],
  'ru': [0x0419],
  'pt': [0x0416, 0x0816],
  'it': [0x0410],
  'nl': [0x0413, 0x0813],
};

/// Returns the Windows language IDs that best match the current system locale,
/// falling back to English (US) if no mapping is found.
List<int> _systemLanguageIds() {
  final locale = Platform.localeName;
  if (locale.isEmpty) return const [0x0409];

  final parts = locale.split(RegExp(r'[-_]'));
  if (parts.isEmpty) return const [0x0409];

  final lang = parts[0].toLowerCase();
  final region = parts.length > 1 ? parts[1].toUpperCase() : '';
  final candidates = <int>[];

  // Exact region-specific match first.
  if (region.isNotEmpty) {
    final exact = _windowsLanguageIds['$lang-$region'];
    if (exact != null) candidates.addAll(exact);
  }

  // Language-wide matches next.
  final languageIds = _windowsLanguageIds[lang];
  if (languageIds != null) {
    for (final id in languageIds) {
      if (!candidates.contains(id)) candidates.add(id);
    }
  }

  // Final fallback: English (US).
  if (!candidates.contains(0x0409)) {
    candidates.add(0x0409);
  }
  return candidates;
}

/// Reads the `name` table of a TTF/OTF/TTC font file and returns the
/// font name, version, family and subfamily.
///
/// Name records are prioritized by the current system locale, matching how
/// Windows selects the localized font name shown in its font preview dialog.
///
/// Returns an empty [FontNameInfo] for unreadable or malformed files.
Future<FontNameInfo> readFontNameInfo(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();

    final head = await raf.read(16);
    if (head.length < 12) return const FontNameInfo.empty();
    int sfntOffset = 0;
    if (_tag(head, 0) == 'ttcf') {
      sfntOffset = ByteData.sublistView(head).getUint32(12, Endian.big);
    }

    await raf.setPosition(sfntOffset);
    final sfnt = await raf.read(12);
    if (sfnt.length < 12) return const FontNameInfo.empty();
    final numTables = ByteData.sublistView(sfnt).getUint16(4, Endian.big);
    if (numTables <= 0 || numTables > 256) return const FontNameInfo.empty();

    final dir = await raf.read(numTables * 16);
    if (dir.length < numTables * 16) return const FontNameInfo.empty();
    final dirData = ByteData.sublistView(dir);

    int? tableOffset;
    for (int i = 0; i < numTables; i++) {
      if (_tag(dir, i * 16) == 'name') {
        tableOffset = dirData.getUint32(i * 16 + 8, Endian.big);
        break;
      }
    }
    if (tableOffset == null) return const FontNameInfo.empty();

    // Table directory offsets are absolute from the start of the file,
    // including inside TTC collections.
    await raf.setPosition(tableOffset);
    final header = await raf.read(6);
    if (header.length < 6) return const FontNameInfo.empty();
    final headerData = ByteData.sublistView(header);
    final formatSelector = headerData.getUint16(0, Endian.big);
    final recordCount = headerData.getUint16(2, Endian.big);
    final storageOffset = headerData.getUint16(4, Endian.big);

    if (formatSelector != 0 || recordCount <= 0 || recordCount > 4096) {
      return const FontNameInfo.empty();
    }

    final records = await raf.read(recordCount * 12);
    if (records.length < recordCount * 12) return const FontNameInfo.empty();
    final recordsData = ByteData.sublistView(records);

    // Read the whole string storage in one go.
    final tableLength = await raf.length() - tableOffset;
    await raf.setPosition(tableOffset + storageOffset);
    final stringStorage = await raf.read(tableLength);

    final preferredLangIds = _systemLanguageIds();

    String? fontName;
    String? version;
    String? family;
    String? subfamily;

    final candidates = <_NameRecord>[];
    for (int i = 0; i < recordCount; i++) {
      final p = i * 12;
      final platformID = recordsData.getUint16(p, Endian.big);
      final encodingID = recordsData.getUint16(p + 2, Endian.big);
      final languageID = recordsData.getUint16(p + 4, Endian.big);
      final nameID = recordsData.getUint16(p + 6, Endian.big);
      final length = recordsData.getUint16(p + 8, Endian.big);
      final stringOffset = recordsData.getUint16(p + 10, Endian.big);

      if (nameID != 1 && nameID != 2 && nameID != 4 && nameID != 5) continue;
      if (stringOffset + length > stringStorage.length) continue;

      final bytes = Uint8List.sublistView(
          stringStorage, stringOffset, stringOffset + length);
      candidates.add(
          _NameRecord(platformID, encodingID, languageID, nameID, bytes));
    }

    candidates.sort((a, b) =>
        _score(b, preferredLangIds).compareTo(_score(a, preferredLangIds)));

    for (final rec in candidates) {
      final text = _decodeString(rec.platformID, rec.encodingID, rec.bytes);
      if (text == null || text.isEmpty) continue;
      switch (rec.nameID) {
        case 4:
          fontName ??= text;
        case 5:
          version ??= text;
        case 1:
          family ??= text;
        case 2:
          subfamily ??= text;
      }
      if (fontName != null &&
          version != null &&
          family != null &&
          subfamily != null) {
        break;
      }
    }

    return FontNameInfo(
      fontName: fontName,
      version: version,
      family: family,
      subfamily: subfamily,
    );
  } catch (_) {
    return const FontNameInfo.empty();
  } finally {
    await raf?.close();
  }
}

class _NameRecord {
  final int platformID;
  final int encodingID;
  final int languageID;
  final int nameID;
  final Uint8List bytes;

  _NameRecord(
      this.platformID, this.encodingID, this.languageID, this.nameID, this.bytes);
}

/// Higher score = better decoding candidate.
/// Windows Unicode in the current system language is preferred, matching the
/// behavior of the Windows font preview dialog.
int _score(_NameRecord rec, List<int> preferredLangIds) {
  int base;
  if (rec.platformID == 3 && rec.encodingID == 10) {
    base = 5; // Windows Unicode full
  } else if (rec.platformID == 3 && rec.encodingID == 1) {
    base = 4; // Windows Unicode BMP
  } else if (rec.platformID == 3 && rec.encodingID == 0) {
    base = 3; // Windows Symbol
  } else if (rec.platformID == 1 && rec.encodingID == 0) {
    base = 2; // Macintosh Roman
  } else if (rec.platformID == 0) {
    base = 1; // Unicode
  } else {
    base = 0;
  }

  // Strongly prefer the exact system locale's language record, then other
  // related/fallback locales (e.g. English).
  if (preferredLangIds.isNotEmpty && rec.languageID == preferredLangIds.first) {
    base += 1000;
  } else if (preferredLangIds.contains(rec.languageID)) {
    base += 10;
  }
  return base;
}

String? _decodeString(int platformID, int encodingID, Uint8List bytes) {
  if (platformID == 3 || platformID == 0) {
    // Windows / Unicode UTF-16BE.
    return _decodeUtf16Be(bytes);
  }
  if (platformID == 1 && encodingID == 0) {
    // Macintosh Roman. Font names are mostly ASCII; Latin-1 is a safe fallback.
    try {
      return latin1.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }
  // Fallback: try Latin-1.
  try {
    return latin1.decode(bytes);
  } catch (_) {
    return String.fromCharCodes(bytes);
  }
}

String _decodeUtf16Be(Uint8List bytes) {
  if (bytes.length % 2 != 0) {
    // Drop the trailing byte if the length is odd.
    bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
  }
  final codes = <int>[];
  for (int i = 0; i < bytes.length; i += 2) {
    codes.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(codes);
}

/// Reads the `post.isFixedPitch` flag of a TTF/OTF/TTC font file.
///
/// This is the authoritative monospace flag stored in the font itself, so
/// it is both fast (only a few small reads, no font-engine loading) and
/// accurate. Returns false for unreadable or malformed files.
Future<bool> isMonospaceFontFile(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();

    // Locate the sfnt header. TTC collections ('ttcf') store offsets to
    // each embedded font; we inspect the first one.
    final head = await raf.read(16);
    if (head.length < 12) return false;
    int sfntOffset = 0;
    if (_tag(head, 0) == 'ttcf') {
      sfntOffset = ByteData.sublistView(head).getUint32(12, Endian.big);
    }

    // Read the sfnt header to get the table count.
    await raf.setPosition(sfntOffset);
    final sfnt = await raf.read(12);
    if (sfnt.length < 12) return false;
    final numTables = ByteData.sublistView(sfnt).getUint16(4, Endian.big);
    if (numTables <= 0 || numTables > 256) return false;

    // Scan the table directory for the 'post' table.
    final dir = await raf.read(numTables * 16);
    if (dir.length < numTables * 16) return false;
    final dirData = ByteData.sublistView(dir);
    for (int i = 0; i < numTables; i++) {
      if (_tag(dir, i * 16) == 'post') {
        final tableOffset = dirData.getUint32(i * 16 + 8, Endian.big);
        // post.isFixedPitch is a u32 at byte offset 12 of the post table.
        await raf.setPosition(tableOffset + 12);
        final post = await raf.read(4);
        if (post.length < 4) return false;
        return ByteData.sublistView(post).getUint32(0, Endian.big) != 0;
      }
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await raf?.close();
  }
}

String _tag(List<int> bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));

/// SFNT table tags whose `bitmapSizeTable` records the pixel sizes (ppemY)
/// of embedded bitmap strikes: OpenType EBLC, color CBLC and Apple bloc.
const _bitmapSizeTableTags = {'EBLC', 'CBLC', 'bloc'};

/// Reads the pixel sizes (ppemY) of the embedded bitmap strikes of a
/// TTF/OTF/TTC font file, e.g. `[12, 16]`. Every member font of a TTC
/// collection is checked; sizes are merged, deduplicated and sorted.
///
/// Returns an empty list when the font has no embedded bitmap data or the
/// file is unreadable/malformed.
Future<List<int>> readEmbeddedBitmapSizes(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();

    final head = await raf.read(16);
    if (head.length < 12) return const [];

    final sfntOffsets = <int>[];
    if (_tag(head, 0) == 'ttcf') {
      final numFonts = ByteData.sublistView(head).getUint32(8, Endian.big);
      if (numFonts <= 0 || numFonts > 256) return const [];
      final offsetBytes = await raf.read(numFonts * 4);
      if (offsetBytes.length < numFonts * 4) return const [];
      final offsetData = ByteData.sublistView(offsetBytes);
      for (int i = 0; i < numFonts; i++) {
        sfntOffsets.add(offsetData.getUint32(i * 4, Endian.big));
      }
    } else {
      sfntOffsets.add(0);
    }

    final sizes = <int>{};
    for (final sfntOffset in sfntOffsets) {
      await raf.setPosition(sfntOffset);
      final sfnt = await raf.read(12);
      if (sfnt.length < 12) continue;
      final numTables = ByteData.sublistView(sfnt).getUint16(4, Endian.big);
      if (numTables <= 0 || numTables > 256) continue;

      final dir = await raf.read(numTables * 16);
      if (dir.length < numTables * 16) continue;
      final dirData = ByteData.sublistView(dir);

      for (int i = 0; i < numTables; i++) {
        if (!_bitmapSizeTableTags.contains(_tag(dir, i * 16))) continue;
        final tableOffset = dirData.getUint32(i * 16 + 8, Endian.big);

        // Table layout matches ebdt_parser.dart: numSizes is a u32 at
        // offset 4; each bitmapSizeTable record is 48 bytes starting at
        // offset 8, with ppemY a u8 at record offset 45.
        await raf.setPosition(tableOffset);
        final header = await raf.read(8);
        if (header.length < 8) continue;
        final numSizes =
            ByteData.sublistView(header).getUint32(4, Endian.big);
        if (numSizes <= 0 || numSizes > 100) continue;

        final records = await raf.read(numSizes * 48);
        if (records.length < numSizes * 48) continue;
        final recordsData = ByteData.sublistView(records);
        for (int s = 0; s < numSizes; s++) {
          final ppemY = recordsData.getUint8(s * 48 + 45);
          if (ppemY > 0) sizes.add(ppemY);
        }
      }
    }
    final result = sizes.toList()..sort();
    return result;
  } catch (_) {
    return const [];
  } finally {
    await raf?.close();
  }
}

/// SFNT table tags that indicate embedded bitmap (dot-matrix) glyph data.
const _bitmapTableTags = {
  'EBDT', 'EBLC', 'EBSC', // OpenType embedded bitmaps (typically 1-bit)
  'bdat', 'bloc', // Apple bitmap data
  'CBDT', 'CBLC', // color bitmaps (e.g. Noto Color Emoji)
  'sbix', // Apple PNG bitmaps
};

/// Returns true when the TTF/OTF/TTC file contains embedded bitmap glyph
/// data. Every member font of a TTC collection is checked; any bitmap
/// table in any member counts.
///
/// Only the table directory is read, so this is fast. Returns false for
/// unreadable or malformed files.
Future<bool> fontHasEmbeddedBitmap(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();

    final head = await raf.read(16);
    if (head.length < 12) return false;

    final sfntOffsets = <int>[];
    if (_tag(head, 0) == 'ttcf') {
      final numFonts = ByteData.sublistView(head).getUint32(8, Endian.big);
      if (numFonts <= 0 || numFonts > 256) return false;
      final offsetBytes = await raf.read(numFonts * 4);
      if (offsetBytes.length < numFonts * 4) return false;
      final offsetData = ByteData.sublistView(offsetBytes);
      for (int i = 0; i < numFonts; i++) {
        sfntOffsets.add(offsetData.getUint32(i * 4, Endian.big));
      }
    } else {
      sfntOffsets.add(0);
    }

    for (final sfntOffset in sfntOffsets) {
      await raf.setPosition(sfntOffset);
      final sfnt = await raf.read(12);
      if (sfnt.length < 12) continue;
      final numTables = ByteData.sublistView(sfnt).getUint16(4, Endian.big);
      if (numTables <= 0 || numTables > 256) continue;

      final dir = await raf.read(numTables * 16);
      if (dir.length < numTables * 16) continue;
      for (int i = 0; i < numTables; i++) {
        if (_bitmapTableTags.contains(_tag(dir, i * 16))) return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await raf?.close();
  }
}

/// Matches pixel-size hints like "16px" / "12 px" in font names and file
/// names (e.g. "Ark Pixel 16px", "VonwaonBitmap-16px", "fusion-pixel-12px").
final _pixelSizeHintRe = RegExp(r'(\d{1,2})\s*px', caseSensitive: false);

/// Detects the design pixel size(s) of a pixel (dot-matrix) font:
///
/// 1. Embedded bitmap strikes ([readEmbeddedBitmapSizes]) — authoritative
///    when the font ships EBLC/CBLC/bloc tables; returned as-is.
/// 2. Otherwise a `Npx` hint extracted from the font's display name and
///    the file name.
///
/// Returns an empty list when the design size is unknown (plain vector
/// fonts with no size hint in the name).
Future<List<int>> detectPixelFontDesignSizes(String path) async {
  final strikes = await readEmbeddedBitmapSizes(path);
  if (strikes.isNotEmpty) return strikes;

  final sizes = <int>{};
  void collect(String? text) {
    if (text == null) return;
    for (final m in _pixelSizeHintRe.allMatches(text)) {
      final v = int.tryParse(m.group(1)!);
      if (v != null && v > 0) sizes.add(v);
    }
  }

  final info = await readFontNameInfo(path);
  collect(info.displayName);
  collect(p.basename(path));

  final result = sizes.toList()..sort();
  return result;
}
