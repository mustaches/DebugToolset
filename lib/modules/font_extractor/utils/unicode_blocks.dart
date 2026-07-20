/// Unicode block definitions and character-set range helpers for the
/// font extractor module.
///
/// This file is pure Dart (no Flutter imports) so it can be unit tested
/// without a widget binding.
library;

/// Text direction of a Unicode block. RTL blocks (Arabic, Hebrew, ...)
/// are marked so the extractor can record direction metadata and the
/// preview can hint rendering order.
enum TextDir { ltr, rtl }

/// A named Unicode block with an inclusive code point range.
class UnicodeBlock {
  final String name;
  final int start;
  final int end;
  final TextDir direction;

  const UnicodeBlock(
    this.name,
    this.start,
    this.end, {
    this.direction = TextDir.ltr,
  });

  int get length => end - start + 1;
}

/// Common Unicode blocks offered as quick character-set choices.
const List<UnicodeBlock> kUnicodeBlocks = [
  UnicodeBlock('Basic Latin 基本拉丁', 0x0000, 0x007F),
  UnicodeBlock('Latin-1 Supplement 拉丁补充', 0x0080, 0x00FF),
  UnicodeBlock('Latin Extended-A 拉丁扩展A', 0x0100, 0x017F),
  UnicodeBlock('Latin Extended-B 拉丁扩展B', 0x0180, 0x024F),
  UnicodeBlock('IPA Extensions 国际音标', 0x0250, 0x02AF),
  UnicodeBlock('Combining Diacritical Marks 组合附标', 0x0300, 0x036F),
  UnicodeBlock('Greek and Coptic 希腊文', 0x0370, 0x03FF),
  UnicodeBlock('Cyrillic 西里尔文', 0x0400, 0x04FF),
  UnicodeBlock('Cyrillic Supplement 西里尔补充', 0x0500, 0x052F),
  UnicodeBlock('Armenian 亚美尼亚文', 0x0530, 0x058F),
  UnicodeBlock('Hebrew 希伯来文', 0x0590, 0x05FF, direction: TextDir.rtl),
  UnicodeBlock('Arabic 阿拉伯文', 0x0600, 0x06FF, direction: TextDir.rtl),
  UnicodeBlock('Arabic Supplement 阿拉伯补充', 0x0750, 0x077F, direction: TextDir.rtl),
  UnicodeBlock('Devanagari 天城文', 0x0900, 0x097F),
  UnicodeBlock('Bengali 孟加拉文', 0x0980, 0x09FF),
  UnicodeBlock('Tamil 泰米尔文', 0x0B80, 0x0BFF),
  UnicodeBlock('Thai 泰文', 0x0E00, 0x0E7F),
  UnicodeBlock('Georgian 格鲁吉亚文', 0x10A0, 0x10FF),
  UnicodeBlock('Hangul Jamo 韩文字母', 0x1100, 0x11FF),
  UnicodeBlock('Latin Extended Additional 越南文扩展', 0x1E00, 0x1EFF),
  UnicodeBlock('General Punctuation 常用标点', 0x2000, 0x206F),
  UnicodeBlock('Currency Symbols 货币符号', 0x20A0, 0x20CF),
  UnicodeBlock('Arrows 箭头', 0x2190, 0x21FF),
  UnicodeBlock('Mathematical Operators 数学运算符', 0x2200, 0x22FF),
  UnicodeBlock('Box Drawing 制表符', 0x2500, 0x257F),
  UnicodeBlock('Block Elements 方块元素', 0x2580, 0x259F),
  UnicodeBlock('Geometric Shapes 几何图形', 0x25A0, 0x25FF),
  UnicodeBlock('Miscellaneous Symbols 杂项符号', 0x2600, 0x26FF),
  UnicodeBlock('CJK Symbols and Punctuation CJK符号', 0x3000, 0x303F),
  UnicodeBlock('Hiragana 平假名', 0x3040, 0x309F),
  UnicodeBlock('Katakana 片假名', 0x30A0, 0x30FF),
  UnicodeBlock('Bopomofo 注音符号', 0x3100, 0x312F),
  UnicodeBlock('CJK Unified Ideographs 中日韩统一表意文字', 0x4E00, 0x9FFF),
  UnicodeBlock('Hangul Syllables 韩文音节', 0xAC00, 0xD7AF),
  UnicodeBlock('Arabic Presentation Forms-B 阿拉伯表现形式B', 0xFE70, 0xFEFF, direction: TextDir.rtl),
  UnicodeBlock('Halfwidth and Fullwidth Forms 半角全角', 0xFF00, 0xFFEF),
];

/// Parses a free-form range input such as
/// `0x20-0x7E, 0x4E00-0x9FFF, U+0600, 32-126`
/// into a list of inclusive (start, end) pairs.
///
/// Throws [FormatException] with a human-readable message on bad input.
List<({int start, int end})> parseRangeInput(String input) {
  final result = <({int start, int end})>[];
  final parts = input.split(RegExp(r'[,;，；\s]+'));
  for (final raw in parts) {
    final part = raw.trim();
    if (part.isEmpty) continue;

    // Split a single range "A-B" but tolerate a lone value "A".
    final dash = part.indexOf('-');
    final startStr = dash == -1 ? part : part.substring(0, dash);
    final endStr = dash == -1 ? part : part.substring(dash + 1);

    final start = _parseCodePoint(startStr);
    final end = _parseCodePoint(endStr);
    if (start == null || end == null) {
      throw FormatException('无法解析的码点: "$part"');
    }
    if (start > end) {
      throw FormatException('范围起点大于终点: "$part"');
    }
    if (end > 0x10FFFF) {
      throw FormatException('码点超出 Unicode 范围: "$part"');
    }
    result.add((start: start, end: end));
  }
  return result;
}

int? _parseCodePoint(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  if (t.toUpperCase().startsWith('U+')) {
    t = t.substring(2);
    return int.tryParse(t, radix: 16);
  }
  if (t.toLowerCase().startsWith('0x')) {
    return int.tryParse(t.substring(2), radix: 16);
  }
  // Plain hex (contains A-F) or plain decimal.
  if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(t) &&
      RegExp(r'[a-fA-F]').hasMatch(t)) {
    return int.tryParse(t, radix: 16);
  }
  return int.tryParse(t);
}

/// Expands block selections and custom ranges into a sorted, de-duplicated
/// list of code points.
///
/// [blocks] are quick-pick blocks; [customRanges] are inclusive ranges as
/// produced by [parseRangeInput].
List<int> expandToCodePoints({
  Iterable<UnicodeBlock> blocks = const [],
  Iterable<({int start, int end})> customRanges = const [],
}) {
  final set = <int>{};
  for (final b in blocks) {
    for (int cp = b.start; cp <= b.end; cp++) {
      set.add(cp);
    }
  }
  for (final r in customRanges) {
    for (int cp = r.start; cp <= r.end; cp++) {
      set.add(cp);
    }
  }
  final list = set.toList()..sort();
  return list;
}
