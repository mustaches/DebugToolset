import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/run_progress_dialog.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  testWidgets('进度窗口：显示、进度刷新、结束后自动关闭', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 窗口只读 isProcessing/progressTick/statusMessage，直接驱动即可，
    // 不需要真实运行（compute/文件 IO 与 widget 测试的假异步区不兼容）。
    final state = IspStudioState();
    state.isProcessing = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => RunPreviewProgressDialog(state: state),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('预览准备中'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);

    // 进度推进 → 百分比刷新。
    state.progressTick.value = 0.42;
    await tester.pump();
    expect(find.text('42%'), findsOneWidget);

    // 运行结束（isProcessing 落地）→ 窗口自动关闭。
    state.isProcessing = false;
    state.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('没有预览节点时点运行预览不弹进度窗口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState(); // 空图：没有预览节点
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('运行预览'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Dialog), findsNothing);
    expect(state.statusMessage, contains('没有预览节点'));
  });
}
