import 'package:debug_tool_set/modules/ui_designer/codegen/c_project_codegen.dart';
import 'package:debug_tool_set/modules/ui_designer/codegen/c_runtime_codegen.dart';
import 'package:debug_tool_set/modules/ui_designer/editor/canvas_view.dart';
import 'package:debug_tool_set/modules/ui_designer/editor/widget_renderer.dart';
import 'package:debug_tool_set/modules/ui_designer/editor/property_panel.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_event.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_page.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_project.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_widget.dart';
import 'package:debug_tool_set/modules/ui_designer/models/widget_registry.dart';
import 'package:debug_tool_set/providers/ui_designer_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

UiWidgetModel _widget(String id, String type, double x, double y,
    {double w = 100, double h = 30, Map<String, dynamic>? props}) {
  return UiWidgetModel(
    id: id,
    type: type,
    name: id,
    x: x,
    y: y,
    width: w,
    height: h,
    props: WidgetRegistry.of(type)!.defaultProps()..addAll(props ?? {}),
  );
}

void main() {
  group('OSD 控件注册表', () {
    test('三种 OSD 控件已注册且带默认属性', () {
      final menu = WidgetRegistry.of('menu')!;
      expect(menu.defaultProps()['items'], contains('项目1'));
      expect(menu.defaultProps()['wrap'], isTrue);
      expect(menu.events, contains(UiEventType.onClick));
      expect(menu.events, contains(UiEventType.onValueChange));

      final value = WidgetRegistry.of('value_item')!;
      expect(value.defaultProps()['step'], 1);
      expect(value.events, contains(UiEventType.onValueChange));

      final option = WidgetRegistry.of('option_item')!;
      expect(option.defaultProps()['options'], contains('自动'));
      expect(option.events, contains(UiEventType.onValueChange));
    });

    test('纯显示控件不可聚焦, OSD 控件可聚焦', () {
      expect(WidgetRegistry.of('line')!.events, isEmpty);
      expect(WidgetRegistry.of('progress')!.events, isEmpty);
      expect(WidgetRegistry.of('menu')!.events, isNotEmpty);
    });
  });

  group('预览按键导航', () {
    late UiDesignerState state;

    setUp(() {
      state = UiDesignerState();
      final page = state.currentPage!;
      page.widgets.add(_widget('btnA', 'button', 10, 10));
      page.widgets.add(_widget('btnB', 'button', 10, 60));
      page.widgets.add(_widget('val1', 'value_item', 10, 110));
      page.widgets.add(_widget('opt1', 'option_item', 10, 160));
      page.widgets.add(_widget('menu1', 'menu', 200, 10, w: 150, h: 120));
      state.enterPreview();
    });
    tearDown(() => state.dispose());

    test('方向键移动焦点, 边界环绕', () {
      expect(state.focusedWidgetId, isNull);
      state.previewNavKey(UiNavDirection.down);
      expect(state.focusedWidgetId, 'btnA'); // 无焦点时聚焦第一个
      state.previewNavKey(UiNavDirection.down);
      expect(state.focusedWidgetId, 'btnB');
      state.previewNavKey(UiNavDirection.up);
      expect(state.focusedWidgetId, 'btnA');
      state.previewNavKey(UiNavDirection.up); // 顶部向上 -> 环绕到最下
      expect(state.focusedWidgetId, 'opt1');
      state.previewNavKey(UiNavDirection.down); // 底部向下 -> 环绕到最上
      expect(state.focusedWidgetId, 'btnA');
      state.previewNavKey(UiNavDirection.right);
      expect(state.focusedWidgetId, 'menu1');
    });

    test('menu 聚焦时上下键移动高亮并循环, 不移动焦点', () {
      state.previewNavKey(UiNavDirection.down);
      state.previewNavKey(UiNavDirection.right);
      expect(state.focusedWidgetId, 'menu1');
      final menu = state.currentPage!.widgetById('menu1')!;

      state.previewNavKey(UiNavDirection.down);
      expect(state.runtimeValueOf(menu), 1);
      expect(state.focusedWidgetId, 'menu1');
      state.previewNavKey(UiNavDirection.up);
      state.previewNavKey(UiNavDirection.up); // 从 0 向上 -> 循环到末项
      expect(state.runtimeValueOf(menu), 2);
    });

    test('value_item 左右调值并按 min/max 钳制, 触发 onValueChange', () {
      final page = state.currentPage!;
      page.widgetById('val1')!.events.add(
          UiEvent(type: UiEventType.onValueChange, callback: 'on_exp_change'));
      state.previewNavKey(UiNavDirection.down);
      state.previewNavKey(UiNavDirection.down);
      state.previewNavKey(UiNavDirection.down);
      expect(state.focusedWidgetId, 'val1');

      final val = page.widgetById('val1')!;
      expect(state.runtimeValueOf(val), 50);
      state.previewNavKey(UiNavDirection.right);
      expect(state.runtimeValueOf(val), 51);
      expect(state.callbackLog.first, contains('on_exp_change(51)'));
      state.previewNavKey(UiNavDirection.left);
      state.previewNavKey(UiNavDirection.left);
      expect(state.runtimeValueOf(val), 49); // 51-2, clamp 由 min=0 兜底
      for (var i = 0; i < 60; i++) {
        state.previewNavKey(UiNavDirection.left);
      }
      expect(state.runtimeValueOf(val), 0); // clamp 到 min
    });

    test('option_item 左右循环切换选项', () {
      final page = state.currentPage!;
      state.previewNavKey(UiNavDirection.down);
      state.previewNavKey(UiNavDirection.down);
      state.previewNavKey(UiNavDirection.down);
      state.previewNavKey(UiNavDirection.down);
      expect(state.focusedWidgetId, 'opt1');

      final opt = page.widgetById('opt1')!;
      expect(state.runtimeValueOf(opt), 0);
      state.previewNavKey(UiNavDirection.left); // 从 0 向左 -> 循环到末项
      expect(state.runtimeValueOf(opt), 2);
      state.previewNavKey(UiNavDirection.right);
      expect(state.runtimeValueOf(opt), 0);
    });

    test('OK 键激活焦点控件并触发 onClick', () {
      final page = state.currentPage!;
      page.widgetById('btnB')!.events.add(
          UiEvent(type: UiEventType.onClick, callback: 'on_ok_click'));
      state.previewNavKey(UiNavDirection.down);
      state.previewNavKey(UiNavDirection.down);
      expect(state.focusedWidgetId, 'btnB');
      state.previewActivate();
      expect(state.callbackLog.first, contains('on_ok_click'));
    });

    test('Esc 清除焦点', () {
      state.previewNavKey(UiNavDirection.down);
      expect(state.focusedWidgetId, isNotNull);
      state.previewClearFocus();
      expect(state.focusedWidgetId, isNull);
    });
  });

  group('OSD 控件渲染冒烟', () {
    Future<void> pumpContent(WidgetTester tester, UiWidgetModel model,
        {bool preview = false, dynamic runtimeValue}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 220,
              height: 160,
              child: UiWidgetContent(
                model: model,
                preview: preview,
                runtimeValue: runtimeValue,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('menu 编辑/预览渲染', (tester) async {
      final m = _widget('m', 'menu', 0, 0, w: 200, h: 120);
      await pumpContent(tester, m);
      expect(find.text('项目1'), findsOneWidget);
      await pumpContent(tester, m, preview: true, runtimeValue: 1);
      expect(find.text('项目2'), findsOneWidget);
    });

    testWidgets('value_item 编辑/预览渲染', (tester) async {
      final v = _widget('v', 'value_item', 0, 0);
      await pumpContent(tester, v);
      expect(find.text('数值'), findsOneWidget);
      expect(find.text('50'), findsOneWidget);
      await pumpContent(tester, v, preview: true, runtimeValue: 42);
      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('option_item 编辑/预览渲染', (tester) async {
      final o = _widget('o', 'option_item', 0, 0);
      await pumpContent(tester, o);
      expect(find.text('< 自动 >'), findsOneWidget);
      await pumpContent(tester, o, preview: true, runtimeValue: 1);
      expect(find.text('< 手动 >'), findsOneWidget);
    });

    testWidgets('progress 信息行与百分比', (tester) async {
      final p = _widget('p', 'progress', 0, 0,
          w: 160, h: 32, props: {'text': '下载中', 'value': 40, 'max': 100});
      await pumpContent(tester, p);
      expect(find.text('下载中'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      await pumpContent(tester, p, preview: true, runtimeValue: 75);
      expect(find.text('75%'), findsOneWidget);
    });
  });

  group('页面背景(图片/视频)', () {
    test('背景字段序列化回环', () {
      final page = UiPage(id: 'p1', name: '主页')
        ..bgType = 'video'
        ..bgVideoPath = 'D:/videos/cam.mp4';
      final restored =
          UiPage.fromJson(page.toJson().cast<String, dynamic>());
      expect(restored.bgType, 'video');
      expect(restored.bgVideoPath, 'D:/videos/cam.mp4');
      expect(restored.bgAssetId, isNull);
      // 旧工程(无背景字段)默认为纯色
      final legacy = UiPage.fromJson(
          {'id': 'p2', 'name': '旧', 'bgColor': 0xFF112233});
      expect(legacy.bgType, 'color');
    });

    testWidgets('视频背景在画布上显示占位提示', (tester) async {
      final state = UiDesignerState();
      addTearDown(state.dispose);
      state.currentPage!
        ..bgType = 'video'
        ..bgVideoPath = 'D:/videos/cam.mp4';
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: CanvasView())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('视频背景: cam.mp4'), findsOneWidget);
    });

    test('代码生成: 视频背景 bg_type=2, 图片资源缺失时退化纯色并告警', () async {
      final state = UiDesignerState();
      addTearDown(state.dispose);
      state.currentPage!
        ..bgType = 'video'
        ..bgVideoPath = 'cam.mp4';
      var result = await CProjectCodegen.generate(state.project,
          assetReader: (asset) async => null);
      expect(result.source, contains('  2, 0, 0, 0, 0,'));
      expect(CRuntimeCodegen.runtimeHeader(), contains('bg_type'));

      state.currentPage!
        ..bgType = 'image'
        ..bgAssetId = 'missing';
      result = await CProjectCodegen.generate(state.project,
          assetReader: (asset) async => null);
      expect(result.source, contains('  0, 0, 0, 0, 0,'));
      expect(result.warnings, isNotEmpty);
    });

    testWidgets('长资源名的背景图片选择器不溢出', (tester) async {
      final state = UiDesignerState();
      addTearDown(state.dispose);
      state.project.assets.add(UiAsset(
        id: 'a1',
        name: 'bg_${'very_long_asset_name_' * 3}',
        srcFile: 'x.png',
      ));
      state.currentPage!
        ..bgType = 'image'
        ..bgAssetId = 'a1';
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 250, child: PropertyPanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('背景图片'), findsOneWidget);
    });
  });

  group('GPU 特效', () {
    test('切换特效字段序列化', () {
      final e = UiEvent(
          type: UiEventType.onClick,
          action: UiActionType.gotoPage,
          targetPageId: 'p2',
          transition: 'cube');
      final restored = UiEvent.fromJson(e.toJson());
      expect(restored.transition, 'cube');
      // 默认无特效时不序列化
      expect(
          UiEvent(type: UiEventType.onClick).toJson().containsKey('transition'),
          isFalse);
    });

    test('gotoPage 带特效时预览进入过渡状态并在结束后清除', () async {
      final state = UiDesignerState();
      addTearDown(state.dispose);
      final p1 = state.currentPage!;
      state.project.pages.add(UiPage(id: 'p2', name: '第二页'));
      p1.widgets.add(_widget('btn', 'button', 10, 10)
        ..events.add(UiEvent(
            type: UiEventType.onClick,
            action: UiActionType.gotoPage,
            targetPageId: 'p2',
            transition: 'slideLeft')));
      state.enterPreview();
      state.previewTap(p1.widgetById('btn')!);
      expect(state.currentPageId, 'p2');
      expect(state.transitionType, 'slideLeft');
      expect(state.transitionFrom, isNotNull);
      expect(state.transitionT, lessThan(1));
      await Future.delayed(const Duration(milliseconds: 400));
      expect(state.transitionFrom, isNull);
      expect(state.transitionT, 1);
    });

    test('变换属性生成到 C 控件表', () async {
      final state = UiDesignerState();
      addTearDown(state.dispose);
      state.currentPage!.widgets.add(_widget('ico', 'image', 10, 10,
          props: {'rotate': 45, 'scale': 150, 'opacity': 80}));
      final result = await CProjectCodegen.generate(state.project,
          assetReader: (asset) async => null);
      expect(result.source, contains(', 45, 150, 80 }'));
      final header = CRuntimeCodegen.runtimeHeader();
      expect(header, contains('uint8_t rotation;'));
      expect(CRuntimeCodegen.portHeader(),
          contains('ui_port_begin_transform'));
    });

    test('背景动画生成到 C 页面表与 port 钩子', () async {
      final state = UiDesignerState();
      addTearDown(state.dispose);
      state.currentPage!
        ..bgType = 'video'
        ..bgAnim = 'kenburns';
      final result = await CProjectCodegen.generate(state.project,
          assetReader: (asset) async => null);
      expect(result.source, contains('  2, 0, 0, 0, 0, 1,'));
      final header = CRuntimeCodegen.runtimeHeader();
      expect(header, contains('uint8_t bg_anim;'));
      final port = CRuntimeCodegen.portHeader();
      expect(port, contains('ui_port_bg_anim_frame'));
      expect(port, contains('ui_port_page_transition'));
    });
  });

  group('C 代码生成', () {    test('运行时模板包含 ui_key API 与新控件类型', () {
      final header = CRuntimeCodegen.runtimeHeader();
      expect(header, contains('UI_W_MENU'));
      expect(header, contains('UI_W_VALUE_ITEM'));
      expect(header, contains('UI_W_OPTION_ITEM'));
      expect(header, contains('ui_key_t'));
      expect(header, contains('void ui_key(ui_key_t key);'));
      final source = CRuntimeCodegen.runtimeSource();
      expect(source, contains('void ui_key(ui_key_t key)'));
      expect(source, contains('focus_move'));
    });

    test('工程表生成新控件映射', () async {
      final state = UiDesignerState();
      addTearDown(state.dispose);
      final page = state.currentPage!;
      page.widgets.add(_widget('m1', 'menu', 10, 10, w: 200, h: 120));
      page.widgets.add(_widget('v1', 'value_item', 10, 140, w: 180));
      page.widgets.add(_widget('o1', 'option_item', 10, 180, w: 200));
      final result = await CProjectCodegen.generate(state.project,
          assetReader: (asset) async => null);
      expect(result.source, contains('UI_W_MENU'));
      expect(result.source, contains('UI_W_VALUE_ITEM'));
      expect(result.source, contains('UI_W_OPTION_ITEM'));
      expect(result.warnings, isEmpty);
    });
  });
}
