import 'dart:io';

import 'package:debug_tool_set/modules/text_editor/text_editor_view.dart';
import 'package:debug_tool_set/modules/text_editor/widgets/diff_view.dart';
import 'package:debug_tool_set/modules/text_editor/widgets/folder_compare_view.dart';
import 'package:debug_tool_set/providers/text_editor_state.dart';
import 'package:debug_tool_set/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

// Covers the folder comparison layout: tapping a file in either explorer
// tree opens it in both frames, and the two diff panes scroll in sync.
void main() {
  late Directory tempRoot;
  late String dirA;
  late String dirB;

  const fileName = 'big.txt';
  final linesA =
      List.generate(400, (i) => 'line ${(i + 1).toString().padLeft(4, '0')}');
  final linesB = List.of(linesA)..[199] = 'line 0200 MODIFIED';

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('folder_compare_view_test');
    dirA = p.join(tempRoot.path, 'a');
    dirB = p.join(tempRoot.path, 'b');
    Directory(dirA).createSync(recursive: true);
    Directory(dirB).createSync(recursive: true);
    File(p.join(dirA, fileName)).writeAsStringSync(linesA.join('\n'));
    File(p.join(dirB, fileName)).writeAsStringSync(linesB.join('\n'));
  });

  tearDown(() {
    // Windows 上假异步区里卡住的 readAsBytes 仍占用文件句柄，删除可能失败。
    try {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // 忽略清理失败（残留目录很小，系统临时目录会自行清理）。
    }
  });

  Future<TextEditorState> pumpView(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = TextEditorState();
    // Flutter 3.47 起 testWidgets 的假异步区内真实 isolate（compute）
    // 结果不再自动完成，须在 runAsync（真实事件循环）中等待。
    await tester.runAsync(() async {
      await state.loadOriginalFolder(dirA);
      await state.loadModifiedFolder(dirB);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<TextEditorState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: FolderCompareView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return state;
  }

  /// The left and right diff-pane ListViews, identified by their on-screen
  /// position (the explorer trees are only 200 wide; diff panes are wider).
  (Element, Element) findDiffPanes(WidgetTester tester) {
    Element? left;
    Element? right;
    for (final e in tester.elementList(find.byType(ListView))) {
      final rect = tester.getRect(find.byWidget(e.widget));
      if (rect.width <= 250) continue; // tree panel
      if (rect.center.dx < 700) {
        left = e;
      } else {
        right = e;
      }
    }
    expect(left, isNotNull, reason: 'left diff pane not found');
    expect(right, isNotNull, reason: 'right diff pane not found');
    return (left!, right!);
  }

  ScrollableState scrollableOf(WidgetTester tester, Element listViewElement) {
    final finder = find.descendant(
      of: find.byWidget(listViewElement.widget),
      matching: find.byType(Scrollable),
    );
    return tester.state<ScrollableState>(finder);
  }

  testWidgets('tapping a tree file opens it in both frames', (tester) async {
    final state = await pumpView(tester);

    // The file appears once per tree; tapping either copy selects it.
    expect(find.text(fileName), findsNWidgets(2));
    await tester.tap(find.text(fileName).first);
    expect(state.selectedFolderFile, fileName);

    // 点击在假异步区内发起的打开会被真实 IO 卡住（3.47 起 fake zone 不再
    // 完成真实异步，等它只会 10 分钟超时）；在 runAsync 的真实事件循环里
    // 关闭后重新打开，让读取与 diff 真正完成。
    await tester.runAsync(() async {
      await state.openFolderFile(fileName); // 关闭卡住的打开（切换语义）
      await state.openFolderFile(fileName); // 重新打开并完成
    });
    await tester.pumpAndSettle();

    // Both frames show the file as a side-by-side diff pane.
    expect(find.byType(DiffView), findsNWidgets(2));
    // 首行在视口内，两侧都渲染；被修改的第 200 行在视口外（懒构建不生成
    // widget），改从状态里的 diff 校验。
    expect(find.text('line 0001', findRichText: true), findsNWidgets(2));
    expect(
      state.folderFileDiff.any((l) => l.isInsert && l.text == 'line 0200 MODIFIED'),
      isTrue,
    );
  });

  testWidgets('diff panes scroll in sync', (tester) async {
    final state = await pumpView(tester);
    await tester.runAsync(() => state.openFolderFile(fileName));
    await tester.pumpAndSettle();

    final (leftPane, rightPane) = findDiffPanes(tester);
    final leftScroll = scrollableOf(tester, leftPane);
    final rightScroll = scrollableOf(tester, rightPane);

    // Programmatic scroll on the left pane syncs the right one.
    leftScroll.position.jumpTo(500);
    await tester.pump();
    expect(rightScroll.position.pixels, moreOrLessEquals(500, epsilon: 1));

    // Dragging the left pane also drags the right one along.
    await tester.drag(find.byWidget(leftPane.widget), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(leftScroll.position.pixels, greaterThan(500));
    expect(rightScroll.position.pixels,
        moreOrLessEquals(leftScroll.position.pixels, epsilon: 2));

    // Scrolling the right pane syncs the left one, too.
    rightScroll.position.jumpTo(1000);
    await tester.pump();
    expect(leftScroll.position.pixels, moreOrLessEquals(1000, epsilon: 1));
  });

  /// The left and right explorer-tree ListViews (200 wide), identified by
  /// their on-screen position.
  (Element, Element) findTreePanes(WidgetTester tester) {
    Element? left;
    Element? right;
    for (final e in tester.elementList(find.byType(ListView))) {
      final rect = tester.getRect(find.byWidget(e.widget));
      if (rect.width > 250) continue; // diff pane
      if (rect.center.dx < 700) {
        left = e;
      } else {
        right = e;
      }
    }
    expect(left, isNotNull, reason: 'left tree not found');
    expect(right, isNotNull, reason: 'right tree not found');
    return (left!, right!);
  }

  testWidgets('folder trees scroll and collapse in sync', (tester) async {
    // A subdirectory with enough files to make both trees scrollable.
    for (final dir in [dirA, dirB]) {
      Directory(p.join(dir, 'sub')).createSync();
      for (var i = 0; i < 100; i++) {
        File(p.join(dir, 'sub', 'f${i.toString().padLeft(3, '0')}.txt'))
            .writeAsStringSync('x');
      }
    }
    await pumpView(tester);

    final (leftTree, rightTree) = findTreePanes(tester);
    final leftScroll = scrollableOf(tester, leftTree);
    final rightScroll = scrollableOf(tester, rightTree);

    // 折叠断言先做一次：树是懒构建 ListView，滚动后 f000.txt 会移出视口。
    // Collapsing 'sub' in the left tree collapses it in the right tree too.
    expect(find.text('f000.txt'), findsNWidgets(2));
    await tester.tap(find.text('sub').first);
    await tester.pumpAndSettle();
    expect(find.text('f000.txt'), findsNothing);

    // Expanding it again from the right tree expands both sides.
    await tester.tap(find.text('sub').last);
    await tester.pumpAndSettle();
    expect(find.text('f000.txt'), findsNWidgets(2));

    // Scrolling the left tree syncs the right one.
    leftScroll.position.jumpTo(300);
    await tester.pump();
    expect(rightScroll.position.pixels, moreOrLessEquals(300, epsilon: 1));
  });

  testWidgets('compare shows a progress dialog, then the button becomes '
      '放弃差异 and discards the result', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = TextEditorState();

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

    // Switch to folder mode first: setMode 会 clearFolder()，之后再加载
    // 文件夹（3.47 起假异步区内 compute 需 runAsync 等待，同 pumpView）。
    await tester.tap(find.text('文件夹'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await state.loadOriginalFolder(dirA);
      await state.loadModifiedFolder(dirB);
    });
    await tester.pumpAndSettle();

    // Start the comparison: the progress dialog appears.
    await tester.tap(find.text('比较差异'));
    await tester.pump();
    expect(find.text('正在比较文件夹差异'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // 点击触发的比较同样卡在假异步区（Isolate.spawn 不完成）；在 runAsync
    // 的真实事件循环里再跑一次比较，使其真正完成，随后对话框自动关闭、
    // 按钮变为 放弃差异。
    await tester.runAsync(() => state.compareFolders());
    await tester.pumpAndSettle();
    expect(find.text('正在比较文件夹差异'), findsNothing);
    expect(state.folderCompared, isTrue);
    expect(find.text('放弃差异'), findsOneWidget);

    // 放弃差异 discards the result and restores the 比较差异 button.
    await tester.tap(find.text('放弃差异'));
    await tester.pumpAndSettle();
    expect(state.folderCompared, isFalse);
    expect(find.text('比较差异'), findsOneWidget);
  });
}
