import 'package:flutter/material.dart';

class AnsiParser {
  // 匹配更广泛的 ANSI/VT100 序列，包括颜色(m)、光标移动(H)、设备状态(n)、保存恢复光标(7/8)等
  static const String ansiEscapePattern = r'\x1B(?:\[[0-9;?]*[a-zA-Z]|[0-9A-Za-z])';

  static TextSpan parse(String text, TextStyle defaultStyle) {
    final RegExp regExp = RegExp(ansiEscapePattern);
    final Iterable<RegExpMatch> matches = regExp.allMatches(text);

    if (matches.isEmpty) {
      return TextSpan(children: _highlightKeywords(text, defaultStyle));
    }

    final List<TextSpan> spans = [];
    int currentIndex = 0;
    
    // Current state
    Color? currentForegroundColor;
    Color? currentBackgroundColor;
    FontWeight currentFontWeight = defaultStyle.fontWeight ?? FontWeight.normal;
    FontStyle currentFontStyle = defaultStyle.fontStyle ?? FontStyle.normal;
    TextDecoration currentDecoration = defaultStyle.decoration ?? TextDecoration.none;

    for (final RegExpMatch match in matches) {
      // Add text before the ansi code
      if (match.start > currentIndex) {
        spans.addAll(_highlightKeywords(
          text.substring(currentIndex, match.start),
          defaultStyle.copyWith(
            color: currentForegroundColor,
            backgroundColor: currentBackgroundColor,
            fontWeight: currentFontWeight,
            fontStyle: currentFontStyle,
            decoration: currentDecoration,
          ),
        ));
      }

      // Parse the ansi code
      final String ansiCode = match.group(0)!;
      
      // 如果不是颜色/样式转义序列（以 'm' 结尾），则直接跳过，达到过滤隐藏的效果
      if (!ansiCode.endsWith('m')) {
        currentIndex = match.end;
        continue;
      }

      final String codeStr = ansiCode.substring(2, ansiCode.length - 1);
      final List<String> codes = codeStr.isEmpty ? ['0'] : codeStr.split(';');

      for (String code in codes) {
        int? c = int.tryParse(code);
        if (c == null) continue;

        if (c == 0) {
          // Reset
          currentForegroundColor = null;
          currentBackgroundColor = null;
          currentFontWeight = defaultStyle.fontWeight ?? FontWeight.normal;
          currentFontStyle = defaultStyle.fontStyle ?? FontStyle.normal;
          currentDecoration = defaultStyle.decoration ?? TextDecoration.none;
        } else if (c == 1) {
          currentFontWeight = FontWeight.bold;
        } else if (c == 2) {
          currentForegroundColor = (currentForegroundColor ?? defaultStyle.color)?.withValues(alpha: 0.5);
        } else if (c == 3) {
          currentFontStyle = FontStyle.italic;
        } else if (c == 4) {
          currentDecoration = TextDecoration.underline;
        } else if (c >= 30 && c <= 37) {
          currentForegroundColor = _getStandardColor(c - 30);
        } else if (c >= 40 && c <= 47) {
          currentBackgroundColor = _getStandardColor(c - 40);
        } else if (c >= 90 && c <= 97) {
          currentForegroundColor = _getBrightColor(c - 90);
        } else if (c >= 100 && c <= 107) {
          currentBackgroundColor = _getBrightColor(c - 100);
        }
      }

      currentIndex = match.end;
    }

    // Add remaining text
    if (currentIndex < text.length) {
      spans.addAll(_highlightKeywords(
        text.substring(currentIndex),
        defaultStyle.copyWith(
          color: currentForegroundColor,
          backgroundColor: currentBackgroundColor,
          fontWeight: currentFontWeight,
          fontStyle: currentFontStyle,
          decoration: currentDecoration,
        ),
      ));
    }

    return TextSpan(children: spans);
  }

  // --- Linux/Embedded Log Keyword Highlighter ---
  static final RegExp _keywordRegExp = RegExp(
    r'\b(ERROR|FAIL|FAILED|FATAL|PANIC|EXCEPTION)\b|\[\s*FAILED\s*\]|'
    r'\b(WARNING|WARN)\b|'
    r'\b(INFO|SUCCESS|OK)\b|\[\s*OK\s*\]|'
    r'\b(?:\d{1,3}\.){3}\d{1,3}\b|' // IPv4
    r'(?:/dev/[a-zA-Z0-9_]+)|' // Linux device paths
    r'(?:[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', // MAC Address
    caseSensitive: false,
  );

  static List<TextSpan> _highlightKeywords(String text, TextStyle baseStyle) {
    if (text.isEmpty) return [];
    
    final matches = _keywordRegExp.allMatches(text);
    if (matches.isEmpty) {
      return [TextSpan(text: text, style: baseStyle)];
    }

    final List<TextSpan> result = [];
    int currentIndex = 0;

    for (final match in matches) {
      if (match.start > currentIndex) {
        result.add(TextSpan(text: text.substring(currentIndex, match.start), style: baseStyle));
      }

      final word = match.group(0)!;
      final upperWord = word.toUpperCase();
      Color? color;
      FontWeight? weight = FontWeight.bold;

      if (upperWord.contains('ERROR') || upperWord.contains('FAIL') || upperWord.contains('FATAL') || upperWord.contains('PANIC') || upperWord.contains('EXCEPTION')) {
        color = const Color(0xFFF14C4C); // Bright Red
      } else if (upperWord.contains('WARN')) {
        color = const Color(0xFFF5F543); // Bright Yellow
      } else if (upperWord.contains('INFO') || upperWord.contains('SUCCESS') || upperWord.contains('OK')) {
        color = const Color(0xFF23D18B); // Bright Green
      } else if (word.startsWith('/dev/') || word.contains(':') || word.contains('.')) {
        color = const Color(0xFF29B8DB); // Bright Cyan (Paths, IP, MAC)
        weight = FontWeight.normal;
      }

      // If text already has a custom color (from ANSI), we might not want to override it,
      // but usually keywords should pop out regardless.
      result.add(TextSpan(
        text: word,
        style: baseStyle.copyWith(color: color ?? baseStyle.color, fontWeight: weight),
      ));

      currentIndex = match.end;
    }

    if (currentIndex < text.length) {
      result.add(TextSpan(text: text.substring(currentIndex), style: baseStyle));
    }

    return result;
  }

  static Color _getStandardColor(int index) {
    const colors = [
      Colors.black,
      Color(0xFFCD3131), // Red
      Color(0xFF0DBC79), // Green
      Color(0xFFE5E510), // Yellow
      Color(0xFF2472C8), // Blue
      Color(0xFFBC3FBC), // Magenta
      Color(0xFF11A8CD), // Cyan
      Color(0xFFE5E5E5), // White
    ];
    if (index >= 0 && index < colors.length) return colors[index];
    return Colors.white;
  }

  static Color _getBrightColor(int index) {
    const colors = [
      Color(0xFF666666), // Bright Black (Gray)
      Color(0xFFF14C4C), // Bright Red
      Color(0xFF23D18B), // Bright Green
      Color(0xFFF5F543), // Bright Yellow
      Color(0xFF3B8EEA), // Bright Blue
      Color(0xFFD670D6), // Bright Magenta
      Color(0xFF29B8DB), // Bright Cyan
      Color(0xFFE5E5E5), // Bright White
    ];
    if (index >= 0 && index < colors.length) return colors[index];
    return Colors.white;
  }
}
