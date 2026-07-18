import 'package:flutter/material.dart';
import 'syntax_highlighter.dart';

/// A [TextEditingController] that returns syntax-highlighted [TextSpan]s.
class HighlightTextEditingController extends TextEditingController {
  /// The language identifier used to select a highlighting mode. This is
  /// usually the file extension without the dot (e.g. "dart", "py", "c").
  String? language;

  /// Default style applied to the text. This is merged with the [TextField]'s
  /// own style when the field is built.
  final TextStyle style;

  HighlightTextEditingController({
    super.text,
    this.language,
    required this.style,
  });

  /// Update the language and trigger a rebuild of the highlighted text.
  void setLanguage(String? value) {
    if (language != value) {
      language = value;
      notifyListeners();
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? this.style;

    if (!value.composing.isValid || !withComposing) {
      return TextSpan(
        style: baseStyle,
        children: SyntaxHighlighter.highlightText(
          text,
          language,
          baseStyle: baseStyle,
        ),
      );
    }

    final composingStyle = baseStyle.merge(
      const TextStyle(decoration: TextDecoration.underline),
    );
    return TextSpan(
      style: baseStyle,
      children: [
        ...SyntaxHighlighter.highlightText(
          value.composing.textBefore(value.text),
          language,
          baseStyle: baseStyle,
        ),
        TextSpan(
          style: composingStyle,
          text: value.composing.textInside(value.text),
        ),
        ...SyntaxHighlighter.highlightText(
          value.composing.textAfter(value.text),
          language,
          baseStyle: baseStyle,
        ),
      ],
    );
  }
}
