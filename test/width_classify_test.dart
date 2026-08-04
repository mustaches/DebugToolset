import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/font_extractor/utils/width_classify.dart';

void main() {
  group('classifyWidth - half', () {
    test('Latin letters and digits are half-width', () {
      expect(classifyWidth(0x41), GlyphWidthClass.half); // A
      expect(classifyWidth(0x61), GlyphWidthClass.half); // a
      expect(classifyWidth(0x30), GlyphWidthClass.half); // 0
      expect(classifyWidth(0x20), GlyphWidthClass.half); // space
    });

    test('Latin Extended / IPA are half-width', () {
      expect(classifyWidth(0x00E9), GlyphWidthClass.half); // é
      expect(classifyWidth(0x0259), GlyphWidthClass.half); // ə
    });

    test('halfwidth katakana and halfwidth forms are half-width', () {
      expect(classifyWidth(0xFF71), GlyphWidthClass.half); // ｱ
      expect(classifyWidth(0xFFE8), GlyphWidthClass.half); // halfwidth arrow
    });

    test('General Punctuation non-CJK marks are half-width', () {
      expect(classifyWidth(0x2009), GlyphWidthClass.half); // thin space
      expect(classifyWidth(0x2013), GlyphWidthClass.half); // en dash
    });

    test('Braille Patterns are half-width (EAW Neutral)', () {
      expect(classifyWidth(0x2800), GlyphWidthClass.half); // braille blank
      expect(classifyWidth(0x2823), GlyphWidthClass.half);
      expect(classifyWidth(0x28FF), GlyphWidthClass.half); // dots-12345678
      // Neighbouring symbol ranges stay full-width.
      expect(classifyWidth(0x27C0), GlyphWidthClass.full);
      expect(classifyWidth(0x2900), GlyphWidthClass.full);
      expect(classifyWidth(0x2BFF), GlyphWidthClass.full);
    });

    test('narrow brackets and halfwidth won are half-width (EAW H/Na)', () {
      expect(classifyWidth(0x20A9), GlyphWidthClass.half); // ₩ WON SIGN (H)
      expect(classifyWidth(0x27E6), GlyphWidthClass.half); // ⟦ (Na)
      expect(classifyWidth(0x27ED), GlyphWidthClass.half); // ⟭ (Na)
      expect(classifyWidth(0x2985), GlyphWidthClass.half); // ⦃ (Na)
      expect(classifyWidth(0x2986), GlyphWidthClass.half); // ⦄ (Na)
      expect(classifyWidth(0x27EE), GlyphWidthClass.full); // ⟮ stays full
      expect(classifyWidth(0x2987), GlyphWidthClass.full); // ⧇ stays full
    });
  });

  group('classifyWidth - full', () {
    test('CJK ideographs are full-width', () {
      expect(classifyWidth(0x4E2D), GlyphWidthClass.full); // 中
      expect(classifyWidth(0x3400), GlyphWidthClass.full); // CJK Ext A
      expect(classifyWidth(0x20000), GlyphWidthClass.full); // CJK Ext B
    });

    test('kana, hangul and fullwidth forms are full-width', () {
      expect(classifyWidth(0x3042), GlyphWidthClass.full); // あ
      expect(classifyWidth(0x30A2), GlyphWidthClass.full); // ア
      expect(classifyWidth(0xAC00), GlyphWidthClass.full); // 가
      expect(classifyWidth(0xFF01), GlyphWidthClass.full); // ！
    });

    test('CJK punctuation in General Punctuation is full-width', () {
      expect(classifyWidth(0x2014), GlyphWidthClass.full); // em dash —
      expect(classifyWidth(0x201C), GlyphWidthClass.full); // “
      expect(classifyWidth(0x2026), GlyphWidthClass.full); // …
    });

    test('symbol blocks are full-width', () {
      expect(classifyWidth(0x2192), GlyphWidthClass.full); // →
      expect(classifyWidth(0x2211), GlyphWidthClass.full); // ∑
      expect(classifyWidth(0x2500), GlyphWidthClass.full); // ─
      expect(classifyWidth(0x25A0), GlyphWidthClass.full); // ■
    });

    test('emoji and PUA are full-width', () {
      expect(classifyWidth(0x1F600), GlyphWidthClass.full); // 😀
      expect(classifyWidth(0xE000), GlyphWidthClass.full); // PUA
    });

    test('EAW Wide ranges verified against Unicode 16 are full-width', () {
      expect(classifyWidth(0x1100), GlyphWidthClass.full); // Hangul Jamo
      expect(classifyWidth(0xA960), GlyphWidthClass.full); // Jamo Ext-A
      expect(classifyWidth(0xFE50), GlyphWidthClass.full); // Small Form Variants
      expect(classifyWidth(0xFE6B), GlyphWidthClass.full);
      expect(classifyWidth(0x16FE0), GlyphWidthClass.full); // Khitan marks
      expect(classifyWidth(0x1AFF0), GlyphWidthClass.full); // Kana Ext-B
      expect(classifyWidth(0x1B000), GlyphWidthClass.full); // Kana Supplement
      expect(classifyWidth(0x1B167), GlyphWidthClass.full); // reserved (W)
      expect(classifyWidth(0x1D300), GlyphWidthClass.full); // Tai Xuan Jing
      expect(classifyWidth(0x323B0), GlyphWidthClass.full); // Plane 3 reserved
      expect(classifyWidth(0x3FFFD), GlyphWidthClass.full);
    });
  });

  group('classifyWidth - proportional', () {
    test('Indic scripts are proportional (neither half nor full)', () {
      expect(classifyWidth(0x0905), GlyphWidthClass.proportional); // अ Devanagari
      expect(classifyWidth(0x097F), GlyphWidthClass.proportional); // Devanagari end
      expect(classifyWidth(0x0985), GlyphWidthClass.proportional); // Bengali
      expect(classifyWidth(0x0B85), GlyphWidthClass.proportional); // Tamil
    });

    test('Arabic and Hebrew are proportional', () {
      expect(classifyWidth(0x0627), GlyphWidthClass.proportional); // ا
      expect(classifyWidth(0x05D0), GlyphWidthClass.proportional); // א
    });

    test('Southeast Asian scripts are proportional', () {
      expect(classifyWidth(0x0E01), GlyphWidthClass.proportional); // ก Thai
      expect(classifyWidth(0x1000), GlyphWidthClass.proportional); // Myanmar
      expect(classifyWidth(0x1780), GlyphWidthClass.proportional); // Khmer
      expect(classifyWidth(0x0F00), GlyphWidthClass.proportional); // Tibetan
    });

    test('Greek and Cyrillic are proportional', () {
      expect(classifyWidth(0x03B1), GlyphWidthClass.proportional); // α
      expect(classifyWidth(0x0416), GlyphWidthClass.proportional); // Ж
    });

    test('combining marks are proportional', () {
      expect(classifyWidth(0x0301), GlyphWidthClass.proportional);
    });

    test('isFullWidthCodePoint only matches full', () {
      expect(isFullWidthCodePoint(0x4E2D), isTrue);
      expect(isFullWidthCodePoint(0x41), isFalse);
      expect(isFullWidthCodePoint(0x0905), isFalse);
    });
  });
}
