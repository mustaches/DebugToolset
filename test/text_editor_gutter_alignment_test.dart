import 'package:debug_tool_set/modules/text_editor/text_editor_view.dart';
import 'package:debug_tool_set/providers/text_editor_state.dart';
import 'package:debug_tool_set/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Regression test: the line-number gutter must stay vertically aligned with
// the editor content. Line numbers and code are rendered in the same row of
// a fixed-extent ListView (per-row `Text('${index + 1}')` + `Text.rich`), so
// alignment follows from the layout; this test verifies it on screen.
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

    const lines = ['alpha', 'beta', 'gamma', 'delta'];
    for (var i = 0; i < lines.length; i++) {
      // 右侧（修改后）窗格内容为空也会渲染一行空行，所以行号 '1' 有两个；
      // .first 均为左侧原文件窗格（树序在前）。
      final gutterFinder = find.text('${i + 1}');
      final contentFinder = find.text(lines[i], findRichText: true);
      expect(gutterFinder, i == 0 ? findsNWidgets(2) : findsOneWidget);
      expect(contentFinder, findsOneWidget);
      final gutterRect = tester.getRect(gutterFinder.first);
      final contentRect = tester.getRect(contentFinder);
      expect(
        (gutterRect.center.dy - contentRect.center.dy).abs(),
        lessThan(0.5),
        reason: 'line ${i + 1}: gutter center ${gutterRect.center.dy} vs '
            'content center ${contentRect.center.dy}',
      );
    }
  });
}
