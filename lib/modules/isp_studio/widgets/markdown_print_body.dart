import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

class MarkdownPrintBody extends StatelessWidget {
  final String text;
  final double fontSize;

  const MarkdownPrintBody({
    super.key,
    required this.text,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final body = TextStyle(
      fontFamily: 'Microsoft YaHei',
      fontSize: fontSize,
      height: 1.35,
      color: Colors.black,
    );
    final bold = body.copyWith(fontWeight: FontWeight.bold);
    final code = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Courier New', 'monospace'],
      fontSize: fontSize * 0.9,
      height: 1.25,
      color: const Color(0xFF333333),
      backgroundColor: const Color(0xFFF0F0F0),
    );
    return MarkdownBody(
      data: text,
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet(
        p: body,
        h1: bold.copyWith(fontSize: fontSize * 1.8),
        h2: bold.copyWith(fontSize: fontSize * 1.5),
        h3: bold.copyWith(fontSize: fontSize * 1.3),
        h4: bold.copyWith(fontSize: fontSize * 1.15),
        h5: bold.copyWith(fontSize: fontSize * 1.05),
        h6: bold,
        h1Padding: const EdgeInsets.only(top: 8, bottom: 5),
        h2Padding: const EdgeInsets.only(top: 8, bottom: 5),
        h3Padding: const EdgeInsets.only(top: 5, bottom: 5),
        h4Padding: const EdgeInsets.only(top: 5, bottom: 5),
        h5Padding: const EdgeInsets.only(top: 5, bottom: 5),
        h6Padding: const EdgeInsets.only(top: 5, bottom: 5),
        pPadding: const EdgeInsets.only(bottom: 5),
        strong: bold,
        em: body.copyWith(fontStyle: FontStyle.italic),
        del: body.copyWith(decoration: TextDecoration.lineThrough),
        a: body.copyWith(
          color: const Color(0xFF0D408C),
          decoration: TextDecoration.underline,
        ),
        code: code,
        codeblockPadding: const EdgeInsets.all(7),
        codeblockDecoration: BoxDecoration(
          color: const Color(0xFFF2F2F2),
          border: Border.all(color: const Color(0xFFCCCCCC)),
        ),
        blockquote: body,
        blockquotePadding: const EdgeInsets.symmetric(
          horizontal: 9,
          vertical: 3,
        ),
        blockquoteDecoration: const BoxDecoration(
          color: Color(0xFFF5F5F5),
          border: Border(left: BorderSide(color: Color(0xFF26598C), width: 3)),
        ),
        listBullet: body,
        listIndent: 18,
        tableHead: bold,
        tableBody: body,
        tableBorder: TableBorder.all(color: const Color(0xFFA6A6A6)),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 5,
          vertical: 4,
        ),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFA6A6A6))),
        ),
      ),
    );
  }
}
