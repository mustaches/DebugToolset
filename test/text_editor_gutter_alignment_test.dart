import 'package:debug_tool_set/modules/text_editor/text_editor_view.dart';
import 'package:debug_tool_set/providers/text_editor_state.dart';
import 'package:debug_tool_set/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Regression test: the line-number gutter must stay vertically aligned with
// the editor content. Both are now rendered as Text widgets with the same
// style and strut, so their per-line heights and baselines match exactly.
void main() {
  testWidgets('gutter line numbers align with editor lines', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = TextEditorState();
    state.setOriginalContent('alpha\nbeta\ngamma\ndelta');

    await tester.pumpWidget(
      ChangeNotifierProvider<TextEditorState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: TextEditorView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const gutterText = '1\n2\n3\n4';
    expect(find.text(gutterText), findsOneWidget);

    RenderParagraph findParagraph(String text) {
      RenderParagraph? paragraph;
      void visitor(Element e) {
        final ro = e.renderObject;
        if (ro is RenderParagraph && ro.text.toPlainText() == text) {
          paragraph = ro;
        }
        e.visitChildren(visitor);
      }
      tester.binding.rootElement?.visitChildren(visitor);
      return paragraph!;
    }

    final gutterPara = findParagraph(gutterText);
    final editorPara = findParagraph('alpha\nbeta\ngamma\ndelta');
    final gutterOrigin = gutterPara.localToGlobal(Offset.zero);
    final editorOrigin = editorPara.localToGlobal(Offset.zero);

    // Compare the top of each line. Editor line starts are at offsets
    // 0, 6, 11, 17 for 'alpha\nbeta\ngamma\ndelta'.
    const editorOffsets = [0, 6, 11, 17];
    const gutterOffsets = [0, 2, 4, 6];
    for (var i = 0; i < editorOffsets.length; i++) {
      final editorTop = editorOrigin.dy +
          editorPara.getOffsetForCaret(TextPosition(offset: editorOffsets[i]), Rect.zero).dy;
      final gutterTop = gutterOrigin.dy +
          gutterPara.getOffsetForCaret(TextPosition(offset: gutterOffsets[i]), Rect.zero).dy;
      expect(
        (gutterTop - editorTop).abs(),
        lessThan(0.5),
        reason: 'line ${i + 1}: gutter top $gutterTop vs editor top $editorTop',
      );
    }
  });
}
