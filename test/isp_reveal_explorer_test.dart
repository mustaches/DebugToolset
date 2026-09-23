import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/models/explorer_reveal.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_property_panel.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('explorerRevealLaunch 参数组装', () {
    bool noFile(String _) => false;
    bool noDir(String _) => false;

    test('空白路径返回 null（调用方禁用按钮）', () {
      expect(explorerRevealLaunch(''), isNull);
      expect(explorerRevealLaunch('   '), isNull);
    });

    test('文件存在 → /select 选中文件（绝对路径、无引号裸传）', () {
      final abs = p.normalize(p.absolute('IspFlow/VideoOut/output.mp4'));
      final l = explorerRevealLaunch('IspFlow/VideoOut/output.mp4',
          fileExists: (s) => s == abs, dirExists: noDir);
      expect(l!.exe, 'explorer.exe');
      expect(l.args, ['/select,$abs']);
    });

    test('路径本身是已存在目录 → 直接打开该目录', () {
      final abs = p.normalize(p.absolute('IspFlow/VideoOut'));
      final l = explorerRevealLaunch('IspFlow/VideoOut',
          fileExists: noFile, dirExists: (s) => s == abs);
      expect(l!.exe, 'explorer.exe');
      expect(l.args, [abs]);
    });

    test('文件不存在但所在目录存在 → 打开所在目录', () {
      final abs = p.normalize(p.absolute('IspFlow/VideoOut/output.mp4'));
      final parent = p.dirname(abs);
      final l = explorerRevealLaunch('IspFlow/VideoOut/output.mp4',
          fileExists: noFile, dirExists: (s) => s == parent);
      expect(l!.exe, 'explorer.exe');
      expect(l.args, [parent]);
    });

    test('文件与所在目录都不存在 → null（调用方提示）', () {
      expect(
          explorerRevealLaunch('no/such/dir/output.mp4',
              fileExists: noFile, dirExists: noDir),
          isNull);
    });

    test('相对路径按工作目录归一化为绝对路径（Windows 反斜杠）', () {
      String? captured;
      explorerRevealLaunch('a\\b/../c.mp4',
          fileExists: (s) {
            captured = s;
            return true;
          },
          dirExists: noDir);
      expect(captured, p.normalize(p.absolute('a/c.mp4')));
      expect(p.isAbsolute(captured!), isTrue);
    });

    test('含空格路径经 cmd /c 包装（/select 路径带引号）', () {
      final abs = p.normalize(p.absolute('IspFlow/Image out/a b.mp4'));
      final l = explorerRevealLaunch('IspFlow/Image out/a b.mp4',
          fileExists: (s) => s == abs, dirExists: noDir);
      expect(l!.exe, 'cmd.exe');
      expect(l.args, ['/c', 'explorer.exe', '/select,"$abs"']);
    });

    test('含空格目录经 cmd /c 包装（目录带引号）', () {
      final abs = p.normalize(p.absolute('IspFlow/Image out'));
      final l = explorerRevealLaunch('IspFlow/Image out',
          fileExists: noFile, dirExists: (s) => s == abs);
      expect(l!.exe, 'cmd.exe');
      expect(l.args, ['/c', 'explorer.exe', '"$abs"']);
    });
  });

  group('NodePropertyPanel 打开目录按钮', () {
    Future<IspStudioState> pumpPanel(WidgetTester tester) async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final id = state.graph.addNode('video_output', 0, 0);
      state.selectNode(id);
      await tester.pumpWidget(MaterialApp(
        home: ChangeNotifierProvider.value(
          value: state,
          child: const Scaffold(body: NodePropertyPanel()),
        ),
      ));
      return state;
    }

    TextButton openDirButton(WidgetTester tester) => tester
        .widget<TextButton>(find.widgetWithText(TextButton, '打开目录'));

    testWidgets('video_output 参数区显示「打开目录」按钮，filePath 非空时可用',
        (tester) async {
      final state = await pumpPanel(tester);
      final id = state.selectedNodeId!;
      // 默认输出文件非空（IspFlow/VideoOut/output.mp4）→ 按钮可用。
      expect(state.graph.nodes[id]!.paramValues['filePath'], isNotEmpty);
      expect(find.text('浏览…'), findsOneWidget);
      expect(find.text('打开目录'), findsOneWidget);
      expect(openDirButton(tester).onPressed, isNotNull);
    });

    testWidgets('filePath 为空时按钮禁用', (tester) async {
      final state = await pumpPanel(tester);
      state.setParam(state.selectedNodeId!, 'filePath', '');
      await tester.pump();
      expect(openDirButton(tester).onPressed, isNull);
    });

    testWidgets('路径不存在（含父目录）时点击弹出提示，不启动资源管理器',
        (tester) async {
      final state = await pumpPanel(tester);
      state.setParam(
          state.selectedNodeId!, 'filePath', 'Z:/no_such_dir_9x7/out.mp4');
      await tester.pump();
      await tester.tap(find.text('打开目录'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('路径不存在'), findsOneWidget);
    });
  });
}
