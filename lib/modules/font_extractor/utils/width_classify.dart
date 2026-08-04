/// Glyph width classification for font extraction.
///
/// Every code point falls into one of three classes:
/// - [GlyphWidthClass.half]: fixed narrow cell (Latin, halfwidth kana, ...).
/// - [GlyphWidthClass.full]: fixed square cell (CJK, kana, hangul, emoji, ...).
/// - [GlyphWidthClass.proportional]: scripts that are neither — Indic,
///   Arabic, Thai, Greek, Cyrillic, etc. Their width is measured from the
///   font's actual glyph advance instead of being forced into a fixed cell.
library;

/// Width class of a glyph.
enum GlyphWidthClass {
  /// Fixed half-width cell (`cellWidth x cellHeight`).
  half,

  /// Fixed full-width square cell (`cjkCellSize x cjkCellSize`).
  full,

  /// Width measured from the font's actual advance, height = `cellHeight`.
  proportional,
}

/// Classifies [cp] into half / full / proportional width.
///
/// Known fixed half-width ranges return [GlyphWidthClass.half], known
/// square-cell (CJK etc.) ranges return [GlyphWidthClass.full], everything
/// else returns [GlyphWidthClass.proportional] so its width is measured
/// from the font rather than guessed.
GlyphWidthClass classifyWidth(int cp) {
  // 1. Explicit Half-width Unicode ranges
  if (cp <= 0x02FF) {
    return GlyphWidthClass.half; // Basic Latin, Latin-1, Latin Ext A/B, IPA, Spacing Modifiers
  }
  if (cp >= 0xFF61 && cp <= 0xFFDF) {
    return GlyphWidthClass.half; // Halfwidth Katakana, Punctuation & Hangul
  }
  if (cp >= 0xFFE8 && cp <= 0xFFEE) {
    return GlyphWidthClass.half; // Halfwidth Forms & Arrows
  }

  // 2. Full-width Symbol & Graphic ranges
  if (cp >= 0x2000 && cp <= 0x206F) {
    // General Punctuation: CJK punctuation like em dash —, ellipsis …, quotes “” ‘’ are full-width
    if (cp == 0x2014 || cp == 0x2015 || cp == 0x2018 || cp == 0x2019 ||
        cp == 0x201C || cp == 0x201D || cp == 0x2022 || cp == 0x2025 ||
        cp == 0x2026 || cp == 0x2030 || cp == 0x2032 || cp == 0x2033 ||
        cp == 0x203B || cp == 0x203E) {
      return GlyphWidthClass.full;
    }
    return GlyphWidthClass.half; // spaces and control punctuation are half-width
  }
  if (cp >= 0x2100 && cp <= 0x214F) return GlyphWidthClass.full; // Letterlike Symbols (℃, ℉, №, ™, Ω)
  if (cp >= 0x2150 && cp <= 0x218F) return GlyphWidthClass.full; // Number Forms / Roman Numerals (Ⅰ..Ⅻ)
  if (cp >= 0x2190 && cp <= 0x21FF) return GlyphWidthClass.full; // Arrows (←, ↑, →, ↓, ↔, ↕)
  if (cp >= 0x2200 && cp <= 0x22FF) return GlyphWidthClass.full; // Math Operators (∀, ∂, ∃, ∅, ∇, ∈, ∑, ±, ×, ÷, √, ∞, ≠, ≤, ≥)
  if (cp >= 0x2300 && cp <= 0x245F) return GlyphWidthClass.full; // Technical, Control Pictures, OCR
  if (cp >= 0x2460 && cp <= 0x24FF) return GlyphWidthClass.full; // Enclosed Alphanumerics (①..⑩, ❶..❿, ⑴..⑽, ⓐ..ⓩ)
  if (cp >= 0x2500 && cp <= 0x257F) return GlyphWidthClass.full; // Box Drawing (─, │, ┌, ┐, └, ┘, ├, ┤, ┬, ┴, ┼, ═, ║)
  if (cp >= 0x2580 && cp <= 0x259F) return GlyphWidthClass.full; // Block Elements (▀, ▁, ▂, ▃, ▄, ▅, ▆, ▇, █, ▌, ▐)
  if (cp >= 0x25A0 && cp <= 0x25FF) return GlyphWidthClass.full; // Geometric Shapes (■, □, ▲, △, ▼, ▽, ◆, ◇, ○, ◎, ●, ★, ☆, ♠, ♣, ♥, ♦)
  if (cp >= 0x2600 && cp <= 0x26FF) return GlyphWidthClass.full; // Misc Symbols (☀, ☁, ☂, ☃, ☎, ☑, ☒, ♨, ♩, ♪, ♫, ♬)
  if (cp >= 0x2700 && cp <= 0x27BF) return GlyphWidthClass.full; // Dingbats (✂, ✈, ✉, ✌, ✍, ✏, ✒, ✔, ✖, ❌, ❎, ❓, ❕, ❖)
  if (cp == 0x20A9) {
    return GlyphWidthClass.half; // ₩ WON SIGN (EAW=Halfwidth; ￦ is FFE6)
  }
  if (cp >= 0x27E6 && cp <= 0x27ED) {
    return GlyphWidthClass.half; // math brackets ⟦..⟭ (EAW=Narrow)
  }
  if (cp >= 0x2985 && cp <= 0x2986) {
    return GlyphWidthClass.half; // ⦃ ⦄ (EAW=Narrow)
  }
  if (cp >= 0x2800 && cp <= 0x28FF) {
    // Braille Patterns: Unicode East_Asian_Width is Neutral (not Wide),
    // terminals count them as 1 column, and fonts (e.g. Unifont) draw
    // them with a half-width advance — two dot columns fit a narrow cell.
    return GlyphWidthClass.half;
  }
  if (cp >= 0x27C0 && cp <= 0x2BFF) return GlyphWidthClass.full; // Misc Math, Supplemental Arrows, Misc Symbols & Arrows

  // 3. CJK & East Asian Full-width Script ranges
  // (all verified against Unicode 16 EastAsianWidth.txt: every range here
  // is EAW Wide or Fullwidth, including ranges reserved for future CJK
  // assignments, which UAX#11 defaults to Wide)
  if (cp >= 0x1100 && cp <= 0x115F) return GlyphWidthClass.full; // Hangul Jamo (EAW=W)
  if (cp >= 0x2E80 && cp <= 0x2EFF) return GlyphWidthClass.full; // CJK Radicals Supplement
  if (cp >= 0x2F00 && cp <= 0x2FDF) return GlyphWidthClass.full; // Kangxi Radicals
  if (cp >= 0x2FF0 && cp <= 0x2FFF) return GlyphWidthClass.full; // Ideographic Description Characters
  if (cp >= 0x3000 && cp <= 0x303F) return GlyphWidthClass.full; // CJK Symbols & Punctuation
  if (cp >= 0x3040 && cp <= 0x309F) return GlyphWidthClass.full; // Hiragana
  if (cp >= 0x30A0 && cp <= 0x30FF) return GlyphWidthClass.full; // Katakana
  if (cp >= 0x3100 && cp <= 0x312F) return GlyphWidthClass.full; // Bopomofo
  if (cp >= 0x3130 && cp <= 0x318F) return GlyphWidthClass.full; // Hangul Compatibility Jamo
  if (cp >= 0x3190 && cp <= 0x319F) return GlyphWidthClass.full; // Kanbun
  if (cp >= 0x31A0 && cp <= 0x31BF) return GlyphWidthClass.full; // Bopomofo Extended
  if (cp >= 0x31C0 && cp <= 0x31EF) return GlyphWidthClass.full; // CJK Strokes
  if (cp >= 0x31F0 && cp <= 0x31FF) return GlyphWidthClass.full; // Katakana Phonetic Extensions
  if (cp >= 0x3200 && cp <= 0x32FF) return GlyphWidthClass.full; // Enclosed CJK Letters & Months
  if (cp >= 0x3300 && cp <= 0x33FF) return GlyphWidthClass.full; // CJK Compatibility
  if (cp >= 0x3400 && cp <= 0x4DBF) return GlyphWidthClass.full; // CJK Ext A
  if (cp >= 0x4DC0 && cp <= 0x4DFF) return GlyphWidthClass.full; // Yijing Hexagrams
  if (cp >= 0x4E00 && cp <= 0x9FFF) return GlyphWidthClass.full; // CJK Main Block
  if (cp >= 0xA000 && cp <= 0xA4CF) return GlyphWidthClass.full; // Yi Syllables & Radicals
  if (cp >= 0xA960 && cp <= 0xA97C) return GlyphWidthClass.full; // Hangul Jamo Extended-A (EAW=W)
  if (cp >= 0xAC00 && cp <= 0xD7AF) return GlyphWidthClass.full; // Hangul Syllables
  if (cp >= 0xE000 && cp <= 0xF8FF) return GlyphWidthClass.full; // BMP PUA
  if (cp >= 0xF900 && cp <= 0xFAFF) return GlyphWidthClass.full; // CJK Compatibility Ideographs
  if (cp >= 0xFE10 && cp <= 0xFE1F) return GlyphWidthClass.full; // Vertical Forms
  if (cp >= 0xFE30 && cp <= 0xFE4F) return GlyphWidthClass.full; // CJK Compatibility Forms
  if (cp >= 0xFE50 && cp <= 0xFE6B) return GlyphWidthClass.full; // Small Form Variants (EAW=W/F)
  if (cp >= 0xFF01 && cp <= 0xFF60) return GlyphWidthClass.full; // Fullwidth ASCII forms (！..～)
  if (cp >= 0xFFE0 && cp <= 0xFFE6) return GlyphWidthClass.full; // Fullwidth Currency & Symbols (￠, ￡, ￥, ￦)

  // 4. Plane 1 & Plane 2 CJK / Ancient / Symbol ranges
  if (cp >= 0x16FE0 && cp <= 0x16FF1) return GlyphWidthClass.full; // Khitan/Tangut marks & reserved (EAW=W)
  if (cp >= 0x17000 && cp <= 0x18D0F) return GlyphWidthClass.full; // Tangut & Khitan (西夏文、契丹小字)
  if (cp >= 0x1AFF0 && cp <= 0x1AFFE) return GlyphWidthClass.full; // Kana Extended-B (EAW=W)
  if (cp >= 0x1B000 && cp <= 0x1B167) return GlyphWidthClass.full; // Kana Supplement & reserved (EAW=W)
  if (cp >= 0x1B170 && cp <= 0x1B2FF) return GlyphWidthClass.full; // Nüshu (女书)
  if (cp >= 0x1D300 && cp <= 0x1D376) return GlyphWidthClass.full; // Tai Xuan Jing Symbols (EAW=W)
  if (cp >= 0x1F000 && cp <= 0x1FAFF) return GlyphWidthClass.full; // Emoji, Pictographs, Mahjong, Domino, Cards, Enclosed Supp
  if (cp >= 0x20000 && cp <= 0x3FFFD) return GlyphWidthClass.full; // CJK Ext B..I & Plane 3 reserved (EAW=W)

  // 5. Everything else — Indic (Devanagari U+0900..097F etc.), Arabic,
  // Thai, Tibetan, Mongolian, Ethiopic, Greek, Cyrillic, Hebrew, ... —
  // is neither half-width nor full-width. Measure the real glyph advance
  // from the font instead of forcing it into a fixed cell.
  return GlyphWidthClass.proportional;
}

/// Convenience check for call sites that only care about the square-cell
/// (CJK) class; proportional and half both return false here.
bool isFullWidthCodePoint(int cp) =>
    classifyWidth(cp) == GlyphWidthClass.full;
