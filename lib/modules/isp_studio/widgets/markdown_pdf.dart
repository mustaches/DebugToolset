import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pdf;

List<pdf.Widget> buildMarkdownPdfWidgets(
  String content, {
  required double fontSize,
  required pdf.Font bodyFont,
  required pdf.Font boldFont,
  required pdf.Font codeFont,
  required List<pdf.Font> fallbackFonts,
}) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(content);
  return _MarkdownPdfBuilder(
    fontSize: fontSize,
    bodyFont: bodyFont,
    boldFont: boldFont,
    codeFont: codeFont,
    fallbackFonts: fallbackFonts,
  ).buildBlocks(nodes);
}

class _MarkdownPdfBuilder {
  final double fontSize;
  final pdf.Font bodyFont;
  final pdf.Font boldFont;
  final pdf.Font codeFont;
  final List<pdf.Font> fallbackFonts;

  _MarkdownPdfBuilder({
    required this.fontSize,
    required this.bodyFont,
    required this.boldFont,
    required this.codeFont,
    required this.fallbackFonts,
  });

  pdf.TextStyle get _bodyStyle => pdf.TextStyle(
    font: bodyFont,
    fontSize: fontSize,
    height: 1.35,
    fontFallback: fallbackFonts,
  );

  pdf.TextStyle get _codeStyle => pdf.TextStyle(
    font: codeFont,
    fontSize: fontSize * 0.9,
    height: 1.25,
    fontFallback: fallbackFonts,
  );

  List<pdf.Widget> buildBlocks(List<md.Node> nodes) {
    final widgets = <pdf.Widget>[];
    for (final node in nodes) {
      if (node is md.Text) {
        if (node.text.trim().isNotEmpty) {
          widgets.add(_paragraph([node], _bodyStyle));
        }
        continue;
      }
      if (node is! md.Element) continue;
      final children = node.children ?? const <md.Node>[];
      switch (node.tag) {
        case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
          final level = int.parse(node.tag.substring(1));
          final factors = [1.8, 1.5, 1.3, 1.15, 1.05, 1.0];
          widgets.add(
            pdf.Padding(
              padding: pdf.EdgeInsets.only(top: level <= 2 ? 8 : 5, bottom: 5),
              child: pdf.RichText(
                text: pdf.TextSpan(
                  children: _inline(
                    children,
                    _bodyStyle.copyWith(
                      font: boldFont,
                      fontSize: fontSize * factors[level - 1],
                      fontWeight: pdf.FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          );
        case 'p':
          widgets.add(_paragraph(children, _bodyStyle));
        case 'pre':
          widgets.add(
            pdf.Container(
              width: double.infinity,
              margin: const pdf.EdgeInsets.only(bottom: 7),
              padding: const pdf.EdgeInsets.all(7),
              decoration: pdf.BoxDecoration(
                color: const PdfColor(0.95, 0.95, 0.95),
                border: pdf.Border.all(color: const PdfColor(0.8, 0.8, 0.8)),
              ),
              child: pdf.RichText(
                text: pdf.TextSpan(text: node.textContent, style: _codeStyle),
              ),
            ),
          );
        case 'blockquote':
          widgets.add(
            pdf.Container(
              margin: const pdf.EdgeInsets.only(bottom: 7),
              padding: const pdf.EdgeInsets.symmetric(
                horizontal: 9,
                vertical: 3,
              ),
              decoration: const pdf.BoxDecoration(
                color: PdfColor(0.96, 0.96, 0.96),
                border: pdf.Border(
                  left: pdf.BorderSide(
                    color: PdfColor(0.15, 0.35, 0.55),
                    width: 3,
                  ),
                ),
              ),
              child: pdf.Column(
                crossAxisAlignment: pdf.CrossAxisAlignment.start,
                children: buildBlocks(children),
              ),
            ),
          );
        case 'ul' || 'ol':
          var itemNumber = 1;
          for (final item in children.whereType<md.Element>()) {
            if (item.tag != 'li') continue;
            widgets.add(
              pdf.Padding(
                padding: const pdf.EdgeInsets.only(bottom: 3),
                child: pdf.Row(
                  crossAxisAlignment: pdf.CrossAxisAlignment.start,
                  children: [
                    pdf.SizedBox(
                      width: 18,
                      child: pdf.RichText(
                        text: pdf.TextSpan(
                          text: node.tag == 'ol' ? '$itemNumber.' : '•',
                          style: _bodyStyle,
                        ),
                      ),
                    ),
                    pdf.Expanded(
                      child: pdf.Column(
                        crossAxisAlignment: pdf.CrossAxisAlignment.start,
                        children: _listItemBlocks(item.children ?? const []),
                      ),
                    ),
                  ],
                ),
              ),
            );
            itemNumber++;
          }
        case 'table':
          widgets.add(_table(node));
        case 'hr':
          widgets.add(
            pdf.Padding(
              padding: const pdf.EdgeInsets.symmetric(vertical: 6),
              child: pdf.Divider(color: const PdfColor(0.65, 0.65, 0.65)),
            ),
          );
        default:
          widgets.addAll(buildBlocks(children));
      }
    }
    return widgets;
  }

  List<pdf.Widget> _listItemBlocks(List<md.Node> nodes) {
    const blockTags = {
      'p',
      'pre',
      'blockquote',
      'ul',
      'ol',
      'table',
      'hr',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
    };
    final widgets = <pdf.Widget>[];
    var inlineNodes = <md.Node>[];
    void flushInline() {
      if (inlineNodes.isEmpty) return;
      widgets.add(_paragraph(inlineNodes, _bodyStyle));
      inlineNodes = <md.Node>[];
    }

    for (final node in nodes) {
      if (node is md.Text ||
          (node is md.Element && !blockTags.contains(node.tag))) {
        inlineNodes.add(node);
      } else {
        flushInline();
        widgets.addAll(buildBlocks([node]));
      }
    }
    flushInline();
    return widgets;
  }

  pdf.Widget _paragraph(List<md.Node> nodes, pdf.TextStyle style) {
    return pdf.Padding(
      padding: const pdf.EdgeInsets.only(bottom: 5),
      child: pdf.RichText(text: pdf.TextSpan(children: _inline(nodes, style))),
    );
  }

  pdf.Widget _table(md.Element table) {
    final rows = <pdf.TableRow>[];
    for (final section
        in table.children?.whereType<md.Element>() ?? const <md.Element>[]) {
      for (final row
          in section.children?.whereType<md.Element>() ??
              const <md.Element>[]) {
        if (row.tag != 'tr') continue;
        rows.add(
          pdf.TableRow(
            children: [
              for (final cell
                  in row.children?.whereType<md.Element>() ??
                      const <md.Element>[])
                pdf.Padding(
                  padding: const pdf.EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 4,
                  ),
                  child: pdf.RichText(
                    text: pdf.TextSpan(
                      children: _inline(
                        cell.children ?? const [],
                        cell.tag == 'th'
                            ? _bodyStyle.copyWith(
                                font: boldFont,
                                fontWeight: pdf.FontWeight.bold,
                              )
                            : _bodyStyle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }
    }
    return pdf.Padding(
      padding: const pdf.EdgeInsets.only(bottom: 7),
      child: pdf.Table(
        border: pdf.TableBorder.all(color: const PdfColor(0.65, 0.65, 0.65)),
        defaultVerticalAlignment: pdf.TableCellVerticalAlignment.top,
        children: rows,
      ),
    );
  }

  List<pdf.InlineSpan> _inline(List<md.Node> nodes, pdf.TextStyle style) {
    final spans = <pdf.InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        spans.add(pdf.TextSpan(text: node.text, style: style));
        continue;
      }
      if (node is! md.Element) continue;
      final children = node.children ?? const <md.Node>[];
      switch (node.tag) {
        case 'strong' || 'b':
          spans.add(
            pdf.TextSpan(
              children: _inline(
                children,
                style.copyWith(font: boldFont, fontWeight: pdf.FontWeight.bold),
              ),
            ),
          );
        case 'em' || 'i':
          spans.add(
            pdf.TextSpan(
              children: _inline(
                children,
                style.copyWith(fontStyle: pdf.FontStyle.italic),
              ),
            ),
          );
        case 'code':
          spans.add(
            pdf.TextSpan(
              text: node.textContent,
              style: _codeStyle.copyWith(
                fontSize: style.fontSize,
                background: const pdf.BoxDecoration(
                  color: PdfColor(0.92, 0.92, 0.92),
                ),
              ),
            ),
          );
        case 'del':
          spans.add(
            pdf.TextSpan(
              children: _inline(
                children,
                style.copyWith(decoration: pdf.TextDecoration.lineThrough),
              ),
            ),
          );
        case 'a':
          spans.add(
            pdf.TextSpan(
              children: _inline(
                children,
                style.copyWith(
                  color: const PdfColor(0.05, 0.25, 0.55),
                  decoration: pdf.TextDecoration.underline,
                ),
              ),
            ),
          );
        case 'br':
          spans.add(pdf.TextSpan(text: '\n', style: style));
        case 'img':
          spans.add(
            pdf.TextSpan(
              text: node.attributes['alt'] ?? '',
              style: style.copyWith(fontStyle: pdf.FontStyle.italic),
            ),
          );
        default:
          spans.addAll(_inline(children, style));
      }
    }
    return spans;
  }
}
