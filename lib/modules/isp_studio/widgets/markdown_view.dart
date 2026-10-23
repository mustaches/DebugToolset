/// Markdown 文档查看组件（ISP Studio 代码页/IP 页共用）。
///
/// 默认以预览模式渲染（暗色 MarkdownStyleSheet，可选中复制）；右上角
/// 悬浮按钮切换到源码视图（复用代码浏览器的行号 + markup 语法高亮），
/// 再点切回预览。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart'
    hide SyntaxHighlighter;

import '../../text_editor/utils/syntax_highlighter.dart';
import 'code_browser.dart';

class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.text});

  /// Markdown 源文本。
  final String text;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  bool _preview = true;

  static const _textColor = Color(0xFFD4D4D4);
  static const _codeStyle = TextStyle(
    fontFamily: 'Consolas',
    fontFamilyFallback: ['Courier New', 'monospace'],
    fontSize: 12,
    height: 1.45,
    color: Color(0xFFCE9178),
    backgroundColor: Color(0xFF2D2D2D),
  );

  MarkdownStyleSheet get _styleSheet => MarkdownStyleSheet(
        a: const TextStyle(
          color: Color(0xFF4EA1E4),
          decoration: TextDecoration.underline,
        ),
        p: const TextStyle(color: _textColor, fontSize: 13, height: 1.5),
        h1: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          height: 1.6,
        ),
        h2: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.bold,
          height: 1.6,
        ),
        h3: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.bold,
          height: 1.5,
        ),
        h4: const TextStyle(
          color: Colors.white70,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
        h5: const TextStyle(color: Colors.white70, fontSize: 13),
        h6: const TextStyle(color: Colors.white60, fontSize: 13),
        em: const TextStyle(
          color: _textColor,
          fontStyle: FontStyle.italic,
        ),
        strong: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
        del: const TextStyle(
          color: Colors.white54,
          decoration: TextDecoration.lineThrough,
        ),
        code: _codeStyle,
        codeblockPadding: const EdgeInsets.all(8),
        codeblockDecoration: BoxDecoration(
          color: const Color(0xFF252526),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF3C3C3C)),
        ),
        blockquote: const TextStyle(color: Colors.white60, fontSize: 13),
        blockquotePadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 4,
        ),
        blockquoteDecoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: Color(0xFF4EC9B0), width: 3),
          ),
        ),
        listBullet: const TextStyle(color: _textColor, fontSize: 13),
        tableHead: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
        tableBody: const TextStyle(color: _textColor, fontSize: 12),
        tableBorder: TableBorder.all(
          color: const Color(0xFF3C3C3C),
        ),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 4,
        ),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Color(0xFF3C3C3C), width: 2),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final body = _preview
        ? Markdown(
            data: widget.text,
            selectable: true,
            styleSheet: _styleSheet,
            padding: const EdgeInsets.all(12),
          )
        : CodeArea(
            spans: SyntaxHighlighter.highlightText(
              widget.text,
              'md',
              baseStyle: kCodeBrowserStyle,
            ),
          );
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          top: 6,
          right: 10,
          child: Tooltip(
            message: _preview ? '查看源码' : '预览',
            child: InkWell(
              onTap: () => setState(() => _preview = !_preview),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xCC2D2D2D),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF3C3C3C)),
                ),
                child: Icon(
                  _preview ? Icons.code : Icons.visibility,
                  size: 14,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
