import 'package:debug_tool_set/modules/text_editor/widgets/folder_tree_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Smoke test for the regedit-style FolderTreePanel: renders nested rows,
// pumpAndSettle settles (no perpetual frames from the guide-line painter),
// and tapping a directory collapses/expands its subtree.
void main() {
  testWidgets('tree renders, settles, and collapses', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: FolderTreePanel(
              title: '原文件夹',
              rootDir: '/tmp/root',
              files: ['a/b/c.txt', 'a/d.txt', 'e.txt'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // All rows visible: dirs a, b and files c.txt, d.txt, e.txt.
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('c.txt'), findsOneWidget);
    expect(find.text('d.txt'), findsOneWidget);
    expect(find.text('e.txt'), findsOneWidget);

    // Collapse 'a': its subtree disappears.
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    expect(find.text('c.txt'), findsNothing);
    expect(find.text('d.txt'), findsNothing);
    expect(find.text('e.txt'), findsOneWidget);

    // Expand again: everything is back.
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    expect(find.text('c.txt'), findsOneWidget);
  });
}
