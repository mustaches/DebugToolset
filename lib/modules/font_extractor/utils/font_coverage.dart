/// Character-coverage analysis for the font extractor module.
///
/// This file is pure Dart (no Flutter imports) so it can be unit tested
/// without a widget binding.
library;

import 'dart:io';
import 'dart:typed_data';

import '../models/lang_binding.dart';

/// A sorted, merged, inclusive code-point range list as stored in a font's
/// `cmap` table.
typedef CodePointRanges = List<({int start, int end})>;

/// A named group of scripts offered as quick target-language choices in the
/// font picker.
class ScriptGroup {
  /// Display name, e.g. "🇨🇳 中国 (简体中文 (CJK))".
  final String name;

  /// Flag/icon emoji tag shown on font rows, e.g. "🇨🇳".
  final String tag;

  /// Code-point ranges that make up this script group.
  final CodePointRanges ranges;

  /// Sample text rendered with the candidate font in the picker preview.
  final String sample;

  /// Optional dynamic preview text builder based on monospace flag.
  final String Function(bool isMono)? sampleBuilder;

  /// Continent category tag (e.g. "亚洲", "欧洲", "非洲", "美洲", "大洋洲", "符号与UI图形").
  final String continent;

  /// Region category tag (e.g. "东亚", "东南亚", "南亚", "中亚", "西亚", "北欧", "西欧", ...).
  final String region;

  /// Country or territorial region tag (e.g. "中国", "日本", "韩国/朝鲜", "英国", ...).
  final String country;

  /// The writing-system (charset) category (e.g. "汉字", "假名", "谚文", "拉丁文", "西里尔文", "阿拉伯文").
  final String script;

  const ScriptGroup({
    required this.name,
    required this.tag,
    required this.ranges,
    required this.sample,
    this.sampleBuilder,
    required this.continent,
    required this.region,
    required this.country,
    required this.script,
  });

  /// Builds preview text for this target script/language, e.g.:
  /// "中国，简体中文，等宽字体" or "日本、日本語、プロポーショナルフォント"
  String buildPreviewText(bool isMono) {
    if (sampleBuilder != null) {
      return sampleBuilder!(isMono);
    }
    return sample;
  }
}

/// Target-language groups used to filter and badge fonts in the picker,
/// classified as: 大洲 (continent) → 地区 (region) → 国家/语言 (country) → 文字 (script).
/// Fully synchronized with the complete Multi-Language Binding preset database [LangBinding.defaultPresets()].
final List<ScriptGroup> kScriptGroups = LangBinding.defaultPresets().map((b) {
  return ScriptGroup(
    name: '${b.flag} ${b.countryTag} (${b.name})',
    tag: b.flag,
    ranges: b.blocks.map((blk) => (start: blk.start, end: blk.end)).toList(),
    sample: b.sampleText,
    sampleBuilder: (isMono) => b.buildLocalizedPreviewText(isMono: isMono),
    continent: b.continentTag,
    region: b.regionTag,
    country: b.countryTag,
    script: b.scriptTag,
  );
}).toList();

/// Fraction (0.0–1.0) of the inclusive code-point range [start, end] that is
/// covered by [cmapRanges] (sorted, merged, inclusive).
double coverageOf(CodePointRanges cmapRanges, int start, int end) {
  if (start > end) return 0;
  int covered = 0;
  for (final r in cmapRanges) {
    if (r.end < start) continue;
    if (r.start > end) break;
    final s = r.start > start ? r.start : start;
    final e = r.end < end ? r.end : end;
    covered += e - s + 1;
  }
  return covered / (end - start + 1);
}

/// Fraction (0.0–1.0) of all code points in [query] covered by [cmapRanges].
double coverageOfRanges(CodePointRanges cmapRanges, CodePointRanges query) {
  int total = 0;
  double coveredSum = 0;
  for (final q in query) {
    final len = q.end - q.start + 1;
    total += len;
    coveredSum += coverageOf(cmapRanges, q.start, q.end) * len;
  }
  return total == 0 ? 0 : coveredSum / total;
}

/// Reads the `cmap` table of a TTF/OTF/TTC font file and returns the sorted,
/// merged list of supported code-point ranges.
///
/// Format 12 subtables (full Unicode) are preferred over format 4 (BMP only).
/// TTC collections are inspected at their first embedded font, matching the
/// behavior of the other parsers in this module.
///
/// Returns null for unreadable or malformed files.
Future<CodePointRanges?> readFontCmap(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();

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

    int? cmapOffset;
    int? cmapLength;
    for (int i = 0; i < numTables; i++) {
      if (_tag(dir, i * 16) == 'cmap') {
        cmapOffset = dirData.getUint32(i * 16 + 8, Endian.big);
        cmapLength = dirData.getUint32(i * 16 + 12, Endian.big);
        break;
      }
    }
    if (cmapOffset == null || cmapLength == null || cmapLength < 4) {
      return null;
    }

    // Table directory offsets are absolute from the start of the file,
    // including inside TTC collections.
    await raf.setPosition(cmapOffset);
    final cmap = await raf.read(cmapLength);
    if (cmap.length < cmapLength) return null;
    final cmapData = ByteData.sublistView(cmap);

    final numSubtables = cmapData.getUint16(2, Endian.big);
    if (numSubtables <= 0 || 4 + numSubtables * 8 > cmap.length) return null;

    // Pick the best subtable: format 12 over format 4, Windows platform
    // preferred within the same format.
    int bestScore = -1;
    int bestOffset = -1;
    for (int i = 0; i < numSubtables; i++) {
      final p = 4 + i * 8;
      final platformID = cmapData.getUint16(p, Endian.big);
      final encodingID = cmapData.getUint16(p + 2, Endian.big);
      final subOffset = cmapData.getUint32(p + 4, Endian.big);
      if (subOffset + 2 > cmap.length) continue;
      final format = cmapData.getUint16(subOffset, Endian.big);
      int score;
      if (format == 12) {
        score = 100;
      } else if (format == 4) {
        score = 50;
      } else {
        continue;
      }
      if (platformID == 3) score += 10;
      if (platformID == 3 && encodingID == 10) score += 2;
      if (platformID == 3 && encodingID == 1) score += 1;
      if (score > bestScore) {
        bestScore = score;
        bestOffset = subOffset;
      }
    }
    if (bestOffset < 0) return null;

    final format = cmapData.getUint16(bestOffset, Endian.big);
    final raw = format == 12
        ? _parseFormat12(cmapData, cmap.length, bestOffset)
        : _parseFormat4(cmapData, cmap.length, bestOffset);
    if (raw == null) return null;
    return _mergeRanges(raw);
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// Parses a cmap format 4 (BMP) subtable. Only the segment start/end codes
/// are needed for coverage; glyph mapping is irrelevant here.
CodePointRanges? _parseFormat4(ByteData data, int tableLength, int offset) {
  if (offset + 16 > tableLength) return null;
  final length = data.getUint16(offset + 2, Endian.big);
  if (length < 16 || offset + length > tableLength) return null;
  final segCount = data.getUint16(offset + 6, Endian.big) ~/ 2;
  if (segCount <= 0 || 16 + segCount * 8 > length) return null;

  final endBase = offset + 14;
  final startBase = endBase + segCount * 2 + 2; // skip reservedPad
  final ranges = <({int start, int end})>[];
  for (int i = 0; i < segCount; i++) {
    final endCode = data.getUint16(endBase + i * 2, Endian.big);
    final startCode = data.getUint16(startBase + i * 2, Endian.big);
    if (startCode == 0xFFFF && endCode == 0xFFFF) continue; // sentinel
    if (startCode > endCode) continue;
    ranges.add((start: startCode, end: endCode));
  }
  return ranges;
}

/// Parses a cmap format 12 (full Unicode) subtable.
CodePointRanges? _parseFormat12(ByteData data, int tableLength, int offset) {
  if (offset + 16 > tableLength) return null;
  final length = data.getUint32(offset + 4, Endian.big);
  if (length < 16 || offset + length > tableLength) return null;
  final nGroups = data.getUint32(offset + 12, Endian.big);
  if (nGroups <= 0 || 16 + nGroups * 12 > length) return null;

  final ranges = <({int start, int end})>[];
  for (int i = 0; i < nGroups; i++) {
    final p = offset + 16 + i * 12;
    final start = data.getUint32(p, Endian.big);
    final end = data.getUint32(p + 4, Endian.big);
    if (start > end || end > 0x10FFFF) continue;
    ranges.add((start: start, end: end));
  }
  return ranges;
}

/// Sorts ranges and merges overlapping or adjacent ones.
CodePointRanges _mergeRanges(CodePointRanges ranges) {
  if (ranges.isEmpty) return ranges;
  final sorted = List<({int start, int end})>.from(ranges)
    ..sort((a, b) => a.start.compareTo(b.start));
  final merged = <({int start, int end})>[sorted.first];
  for (int i = 1; i < sorted.length; i++) {
    final last = merged.last;
    final r = sorted[i];
    if (r.start <= last.end + 1) {
      if (r.end > last.end) {
        merged[merged.length - 1] = (start: last.start, end: r.end);
      }
    } else {
      merged.add(r);
    }
  }
  return merged;
}

String _tag(List<int> bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));
