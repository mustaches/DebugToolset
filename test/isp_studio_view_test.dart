import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/connection_painter.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_canvas.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_palette.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('ISP Studio 视图可渲染且包含默认节点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => IspStudioState(),
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    // 工具栏按钮
    expect(find.text('运行预览'), findsOneWidget);
    expect(find.text('重置视图'), findsOneWidget);
    // 属性面板空选中提示
    expect(find.text('点击节点查看参数'), findsOneWidget);
    // 默认图节点标题（至少能看到 Bayer RAW 源 / 预览 / 图片输出）
    expect(find.text('Bayer RAW 源'), findsWidgets);
    expect(find.text('预览'), findsWidgets);
    expect(find.text('图片输出'), findsWidgets);
  });

  testWidgets('点击节点后属性面板显示参数', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    // 选中 Gamma 节点（默认图里有），属性面板应出现 Gamma 参数。
    final gammaId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'gamma')
        .key;
    state.selectNode(gammaId);
    await tester.pumpAndSettle();

    expect(find.text('亮度'), findsOneWidget);
    expect(find.text('对比度'), findsOneWidget);
  });

  testWidgets('点击节点卡片任意位置可选中节点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final canvasTopLeft = tester.getTopLeft(find.byType(IspNodeCanvas));
    // 默认图第一个节点 bayer_source 位于 (100, 100)，
    // 点击标题栏以外的端口行区域（节点卡片中部）也应选中。
    final srcId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'bayer_source')
        .key;
    await tester.tapAt(canvasTopLeft + const Offset(195, 150));
    await tester.pumpAndSettle();
    expect(state.selectedNodeId, srcId);
  });

  testWidgets('点击连线选中，再点中点控制点删除连线', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final canvasTopLeft = tester.getTopLeft(find.byType(IspNodeCanvas));
    // 第一条连线：bayer_source → black_level，位于两节点之间的空隙。
    final conn = state.graph.connections.first;
    final geo = resolveWireGeometry(state.graph, conn)!;
    final mid = wireMidpoint(geo.start, geo.end);

    // 点击连线 → 选中连线，并取消节点选中。
    await tester.tapAt(canvasTopLeft + mid);
    await tester.pumpAndSettle();
    expect(state.selectedConnectionId, conn.id);
    expect(state.selectedNodeId, isNull);

    // 再点中点控制点 → 删除该连线。
    await tester.tapAt(canvasTopLeft + mid);
    await tester.pumpAndSettle();
    expect(state.graph.connections.any((c) => c.id == conn.id), isFalse);
    expect(state.selectedConnectionId, isNull);
  });

  testWidgets('预览节点屏幕可通过手柄拖动调整高度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final previewId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'preview')
        .key;
    // 预览节点默认在视口之外且与其他节点相邻，
    // 先移到空旷的可视区域，避免重叠节点挡住手柄。
    final node = state.graph.nodes[previewId]!;
    state.moveNode(previewId, Offset(400 - node.x, 400 - node.y));
    await tester.pumpAndSettle();

    final before = state.previewExtraHeight(previewId);
    await tester.drag(find.byIcon(Icons.drag_handle), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(state.previewExtraHeight(previewId), before + 60);

    // 向上拖出最小值边界后应被钳制，不会变成负数/零。
    await tester.drag(find.byIcon(Icons.drag_handle), const Offset(0, -10000));
    await tester.pumpAndSettle();
    expect(state.previewExtraHeight(previewId),
        IspStudioState.kMinPreviewExtraHeight);
  });

  testWidgets('预览节点右下角控制点可双向调整屏幕尺寸', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final previewId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'preview')
        .key;
    final node = state.graph.nodes[previewId]!;
    state.moveNode(previewId, Offset(400 - node.x, 400 - node.y));
    await tester.pumpAndSettle();

    final beforeW = node.width;
    final beforeH = state.previewExtraHeight(previewId);
    await tester.drag(find.byIcon(Icons.south_east), const Offset(60, 40));
    await tester.pumpAndSettle();
    expect(node.width, beforeW + 60);
    expect(state.previewExtraHeight(previewId), beforeH + 40);

    // 向左上拖出最小值边界后应被钳制。
    await tester.drag(
        find.byIcon(Icons.south_east), const Offset(-10000, -10000));
    await tester.pumpAndSettle();
    expect(node.width, IspStudioState.kMinPreviewNodeWidth);
    expect(state.previewExtraHeight(previewId),
        IspStudioState.kMinPreviewExtraHeight);
  });

  testWidgets('左侧工具栏按分组列出节点类型，点击可添加节点', (tester) async {
    // 高度给足：调色板是懒构建 ListView，表面太矮时分组标题会被
    // 滚出可视区而不构建（find 不到）。
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final palette = find.byType(IspNodePalette);
    expect(palette, findsOneWidget);
    // 分组标题：Source / CIS Src / Process / Output / Instrument。
    for (final name in ['Source', 'CIS Src', 'Process', 'Output', 'Instrument']) {
      expect(find.descendant(of: palette, matching: find.text(name)),
          findsOneWidget);
    }
    // image_source 节点名为 Image。
    expect(find.descendant(of: palette, matching: find.text('Image')),
        findsOneWidget);
    // CIS Src 6 个子类。
    for (final name in [
      'Bayer RGGB',
      'RCCB/RCCG',
      'RCCC',
      'RYYCy',
      'RGB-IR',
      'MONO',
    ]) {
      expect(find.descendant(of: palette, matching: find.text(name)),
          findsOneWidget);
    }
    // Process / Output 分组的节点（Bayer RAW 源不在工具栏，与 CIS Src 的
    // Bayer RGGB 重复）。
    expect(find.descendant(of: palette, matching: find.text('Bayer RAW 源')),
        findsNothing);
    for (final name in [
      '黑电平校正',
      '去马赛克',
      '白平衡',
      '色彩校正 CCM',
      'Gamma/色调',
      '预览',
      '图片输出',
      '视频输出 MP4',
      '音频输出',
      '直方图',
      '示波器',
      '矢量示波器',
      '音频电平',
      '音频波形',
      '音频EQ频谱',
    ]) {
      expect(find.descendant(of: palette, matching: find.text(name)),
          findsWidgets);
    }

    // 默认图已有 1 个 CCM 节点，点击工具栏再添加 1 个。
    int ccmCount() =>
        state.graph.nodes.values.where((n) => n.typeId == 'ccm').length;
    expect(ccmCount(), 1);
    await tester.tap(
        find.descendant(of: palette, matching: find.text('色彩校正 CCM')));
    await tester.pumpAndSettle();
    expect(ccmCount(), 2);

    // 从 CIS Src 分组添加 MONO 源节点。
    int monoCount() =>
        state.graph.nodes.values.where((n) => n.typeId == 'cis_mono').length;
    expect(monoCount(), 0);
    await tester.tap(find.descendant(of: palette, matching: find.text('MONO')));
    await tester.pumpAndSettle();
    expect(monoCount(), 1);
  });

  testWidgets('右键拖动节点与画布，右键不再删除节点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final srcId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'bayer_source')
        .key;
    final node = state.graph.nodes[srcId]!;
    final nodeCount = state.graph.nodes.length;
    final startX = node.x;
    final startY = node.y;
    final nodeFinder = find.ancestor(
        of: find.text('Bayer RAW 源'), matching: find.byType(IspNodeWidget));
    expect(nodeFinder, findsOneWidget);

    // 右键拖动节点 → 节点移动，且不触发删除。
    var gesture = await tester.startGesture(tester.getCenter(nodeFinder),
        buttons: kSecondaryButton);
    await gesture.moveBy(const Offset(50, 30));
    await gesture.up();
    await tester.pump();
    expect(node.x, closeTo(startX + 50, 0.001));
    expect(node.y, closeTo(startY + 30, 0.001));
    expect(state.graph.nodes.length, nodeCount);

    // 右键拖空白处 → 平移画布（避开右侧属性面板，取画布内空白点）。
    final offsetBefore = state.canvasOffset;
    gesture = await tester.startGesture(const Offset(700, 700),
        buttons: kSecondaryButton);
    await gesture.moveBy(const Offset(-40, -25));
    await gesture.up();
    await tester.pump();
    expect(state.canvasOffset.dx,
        closeTo(offsetBefore.dx - 40, 0.001));
    expect(state.canvasOffset.dy,
        closeTo(offsetBefore.dy - 25, 0.001));
  });

  testWidgets('焦点被夺走后点击节点，Delete 仍可删除节点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final srcId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'bayer_source')
        .key;
    final node = state.graph.nodes[srcId]!;
    final canvasTopLeft = tester.getTopLeft(find.byType(IspNodeCanvas));

    // 模拟运行预览 / 文件对话框之后：画布键盘焦点已离开。
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // 点击节点卡片选中（画布应同时夺回焦点）。
    await tester.tapAt(canvasTopLeft + Offset(node.x + 95, node.y + 50));
    await tester.pumpAndSettle();
    expect(state.selectedNodeId, srcId);

    // Delete 删除选中节点。
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(state.graph.nodes.containsKey(srcId), isFalse);
  });

  test('最大化切换：新节点最大化时还原旧节点，删除节点清理状态', () {
    final state = IspStudioState();
    final previewId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'preview')
        .key;
    final histId = state.graph.addNode('histogram', 0, 0);
    const rect = Rect.fromLTWH(0, 0, 1200, 800);

    final node = state.graph.nodes[previewId]!;
    final oldX = node.x;
    final oldY = node.y;
    final oldW = node.width;
    final oldExtra = state.previewExtraHeight(previewId);

    state.toggleMaximize(previewId, rect);
    expect(state.maximizedNodeId, previewId);
    expect(node.x, 12);
    expect(node.y, 12);
    expect(node.width, 1200 - 24);
    // 附加区高 = 视口高 - 边距 - 标题/端口/留白（30 + 3*22 + 8）。
    expect(state.previewExtraHeight(previewId), 800 - 24 - 104);

    // 切换最大化：旧节点几何还原。
    state.toggleMaximize(histId, rect);
    expect(state.maximizedNodeId, histId);
    expect(node.x, oldX);
    expect(node.y, oldY);
    expect(node.width, oldW);
    expect(state.previewExtraHeight(previewId), oldExtra);

    // 非显示区节点不可最大化。
    final gammaId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'gamma')
        .key;
    state.toggleMaximize(gammaId, rect);
    expect(state.maximizedNodeId, histId);

    // 删除最大化节点：状态清理。
    state.removeNode(histId);
    expect(state.maximizedNodeId, isNull);
  });

  testWidgets('预览节点标题栏最大化按钮：点击铺满视口，再点还原', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = IspStudioState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: IspStudioView())),
      ),
    );
    await tester.pumpAndSettle();

    final previewId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'preview')
        .key;
    final node = state.graph.nodes[previewId]!;
    // 默认图中预览节点在视口外，先移到可见区域。
    state.moveNode(previewId, Offset(300 - node.x, 200 - node.y));
    await tester.pumpAndSettle();
    final oldW = node.width;
    final oldX = node.x;
    final nodeFinder = find.ancestor(
        of: find.text('预览'), matching: find.byType(IspNodeWidget));
    expect(nodeFinder, findsOneWidget);

    // 点击最大化按钮 → 节点铺满视口且置顶。
    await tester.tap(
        find.descendant(of: nodeFinder, matching: find.byIcon(Icons.fullscreen)));
    await tester.pumpAndSettle();
    expect(state.maximizedNodeId, previewId);
    expect(node.width, greaterThan(oldW));

    // 再点还原按钮 → 几何恢复。
    await tester.tap(find.descendant(
        of: nodeFinder, matching: find.byIcon(Icons.fullscreen_exit)));
    await tester.pumpAndSettle();
    expect(state.maximizedNodeId, isNull);
    expect(node.width, oldW);
    expect(node.x, oldX);
  });
}
