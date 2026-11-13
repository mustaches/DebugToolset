import 'package:debug_tool_set/modules/isp_studio/widgets/markdown_pagination.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/verilog_print_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';

void main() {
  test('paginates rendered markdown into multiple non-empty pages', () {
    final content = List.generate(
      40,
      (index) =>
          '## Section $index\n\nParagraph with **bold text** and `inline_code`.\n\n- first `code` item\n- second item',
    ).join('\n\n');
    final pages = paginateMarkdownForPrint(content, PdfPageFormat.a4, 6.5);

    expect(pages.length, greaterThan(1));
    expect(pages.every((page) => page.trim().isNotEmpty), isTrue);
    expect(pages.first, contains('Section 0'));
    expect(pages.last, contains('Section 39'));
  });

  test('recomputes pagination for landscape and margins', () {
    final content = List.generate(
      30,
      (index) => 'Paragraph $index with enough text to wrap onto a new line.',
    ).join('\n\n');
    final portrait = paginateMarkdownForPrint(content, PdfPageFormat.a4, 6.5);
    final landscape = paginateMarkdownForPrint(
      content,
      PdfPageFormat.a4.landscape,
      6.5,
    );

    expect(landscape.length, greaterThan(1));
    expect(landscape.length, isNot(portrait.length));
  });

  testWidgets('scrolls to the second markdown preview page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final content = List.generate(
      40,
      (index) =>
          '## Section $index\n\nParagraph with **bold text** and `inline_code`.\n\n- first `code` item\n- second item',
    ).join('\n\n');
    await tester.pumpWidget(
      MaterialApp(
        home: VerilogPrintPreview(fileName: 'demo.md', content: content),
      ),
    );
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(1200);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('verilog-preview-page-1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
