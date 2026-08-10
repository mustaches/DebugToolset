import 'dart:io';

import 'package:debug_tool_set/modules/ui_designer/codegen/c_code_exporter.dart';
import 'package:debug_tool_set/modules/ui_designer/models/project_serializer.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_event.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_page.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_project.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_widget.dart';
import 'package:debug_tool_set/modules/ui_designer/models/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Generates the GPU effects demo project into UI_Project/.
/// Run with: flutter test test/ui_gpu_effects_project_test.dart
void main() {
  test('generate GPU effects demo project', () async {
    UiWidgetModel widget(
      String id,
      String type,
      String name,
      double x,
      double y,
      double w,
      double h, {
      Map<String, dynamic>? props,
      List<UiEvent>? events,
    }) {
      final def = WidgetRegistry.of(type)!;
      return UiWidgetModel(
        id: id,
        type: type,
        name: name,
        x: x,
        y: y,
        width: w,
        height: h,
        props: def.defaultProps()..addAll(props ?? {}),
        events: events ?? [],
      );
    }

    final project =
        UiProject(name: 'gpu_effects_demo', screenWidth: 480, screenHeight: 272);

    // ------------------------------------------------ page 1: 主界面
    final page1 = UiPage(id: 'page_home', name: '主界面', bgColor: 0xFF0A0A14);
    page1.widgets.addAll([
      // 标题: 旋转 + 透明度变换演示
      widget('w_title', 'label', 'title', 16, 10, 240, 26, props: {
        'text': 'GPU 特效演示',
        'fontSize': 20,
        'bold': true,
        'opacity': 90,
      }),
      // 右侧旋转图标占位(图片控件, 旋转 30° 放大 120%)
      widget('w_badge', 'image', 'badge', 410, 8, 48, 48,
          props: {'rotate': 30, 'scale': 120, 'opacity': 85}),
      // OSD 菜单: 方向键上下移动高亮(滑动动画), OK 进入
      widget(
        'w_menu',
        'menu',
        'main_menu',
        24,
        52,
        200,
        180,
        props: {
          'items': '相机预览,参数设置,特效切换,系统信息,关于',
          'itemExtent': 34,
          'fontSize': 15,
          'highlightColor': 0xFF00695C,
        },
        events: [
          UiEvent(
              type: UiEventType.onValueChange, callback: 'on_menu_highlight'),
          UiEvent(
              type: UiEventType.onClick,
              action: UiActionType.gotoPage,
              targetPageId: 'page_settings',
              transition: 'slideLeft'),
        ],
      ),
      // 双色斜条进度条 + 信息行(条纹流动动画)
      widget('w_progress', 'progress', 'progress', 248, 60, 208, 34, props: {
        'text': '固件下载',
        'value': 65,
        'max': 100,
        'color': 0xFF00897B,
        'stripeColor': 0xFF4DB6AC,
      }),
      // 按钮: 按下缩放回弹 + 立方体翻转转场
      widget(
        'w_btn_fx',
        'button',
        'btn_fx',
        248,
        116,
        96,
        34,
        props: {'text': '特效页', 'radius': 8, 'bgColor': 0xFF00695C},
        events: [
          UiEvent(
              type: UiEventType.onClick,
              action: UiActionType.gotoPage,
              targetPageId: 'page_settings',
              transition: 'cube'),
        ],
      ),
      widget(
        'w_btn_about',
        'button',
        'btn_about',
        356,
        116,
        96,
        34,
        props: {'text': '关于', 'radius': 8, 'bgColor': 0xFF37474F},
        events: [
          UiEvent(
              type: UiEventType.onClick,
              action: UiActionType.gotoPage,
              targetPageId: 'page_about',
              transition: 'fade'),
        ],
      ),
      widget('w_hint', 'label', 'hint', 24, 240, 432, 16, props: {
        'text': '方向键移动焦点 · 上下键操作菜单 · OK 进入 · 注意转场与动效',
        'fontSize': 10,
        'color': 0xFF5F7F99,
      }),
    ]);

    // ------------------------------------------------ page 2: 参数设置
    final page2 =
        UiPage(id: 'page_settings', name: '参数设置', bgColor: 0xFF101820);
    page2.widgets.addAll([
      widget('w_stitle', 'label', 'settings_title', 16, 10, 240, 26,
          props: {'text': '参数设置', 'fontSize': 20, 'bold': true}),
      // 数值项: 左右键调值
      widget('w_exposure', 'value_item', 'exposure', 32, 56, 240, 28,
          props: {
            'text': '曝光补偿',
            'value': 50,
            'min': 0,
            'max': 100,
            'step': 5,
          },
          events: [
            UiEvent(
                type: UiEventType.onValueChange, callback: 'on_exposure')
          ]),
      widget('w_iso', 'value_item', 'iso', 32, 92, 240, 28, props: {
        'text': 'ISO',
        'value': 200,
        'min': 100,
        'max': 6400,
        'step': 100,
      }),
      // 选项项: 左右键循环
      widget('w_wb', 'option_item', 'white_balance', 32, 128, 240, 28,
          props: {'text': '白平衡', 'options': '自动,日光,阴天,白炽灯,荧光灯'}),
          // 分辨率选项
      widget('w_res', 'option_item', 'resolution', 32, 164, 240, 28, props: {
        'text': '分辨率',
        'options': '4K,1080P,720P',
        'selectedIndex': 1,
      }),
      widget(
        'w_btn_back',
        'button',
        'btn_back',
        320,
        220,
        120,
        36,
        props: {'text': '返回', 'radius': 8, 'bgColor': 0xFF37474F},
        events: [
          UiEvent(
              type: UiEventType.onClick,
              action: UiActionType.gotoPage,
              targetPageId: 'page_home',
              transition: 'slideRight'),
        ],
      ),
      widget('w_shint', 'label', 'settings_hint', 32, 232, 260, 16, props: {
        'text': '左右键调值/切换选项 · OK 确认',
        'fontSize': 10,
        'color': 0xFF5F7F99,
      }),
    ]);

    // ------------------------------------------------ page 3: 关于(视频背景演示)
    final page3 = UiPage(id: 'page_about', name: '关于', bgColor: 0xFF000000)
      ..bgType = 'video'
      ..bgVideoPath = 'camera_preview.mp4';
    page3.widgets.addAll([
      widget('w_atitle', 'label', 'about_title', 16, 10, 240, 26, props: {
        'text': '关于(视频背景 OSD)',
        'fontSize': 20,
        'bold': true,
      }),
      widget('w_aver', 'label', 'about_ver', 16, 48, 300, 20, props: {
        'text': 'GPU Effects Demo v1.0 · Mali MP2',
        'fontSize': 13,
        'color': 0xFF9CC3E5,
      }),
      widget('w_apanel', 'panel', 'about_panel', 16, 80, 240, 80, props: {
        'bgColor': 0x80000000, // 半透明 OSD 面板
        'radius': 8,
        'opacity': 90,
      }),
      widget('w_anote', 'label', 'about_note', 28, 92, 220, 56, props: {
        'text': '视频背景下控件直接叠加在实时画面上',
        'fontSize': 12,
        'color': 0xFFFFFFFF,
      }),
      widget(
        'w_btn_aback',
        'button',
        'btn_aback',
        340,
        220,
        120,
        36,
        props: {'text': '返回', 'radius': 8},
        events: [
          UiEvent(
              type: UiEventType.onClick,
              action: UiActionType.gotoPage,
              targetPageId: 'page_home',
              transition: 'pushLeft'),
        ],
      ),
    ]);

    project.pages
      ..add(page1)
      ..add(page2)
      ..add(page3);

    final dir = Directory('UI_Project')..createSync(recursive: true);
    final file = File('${dir.path}/gpu_effects_demo.uiproj');
    file.writeAsStringSync(ProjectSerializer.encode(project));

    // Also export the C code for reference.
    final exportDir = Directory('${dir.path}/gpu_effects_demo_c')
      ..createSync(recursive: true);
    await CCodeExporter.export(project, exportDir.path);

    // Round-trip sanity check.
    final decoded = ProjectSerializer.decode(file.readAsStringSync());
    expect(decoded.screenWidth, 480);
    expect(decoded.pages.length, 3);
    expect(decoded.pages.first.widgets[2].type, 'menu');
    expect(decoded.pages[2].bgType, 'video');
    final menuEvent = decoded.pages.first.widgets
        .firstWhere((w) => w.type == 'menu')
        .events
        .firstWhere((e) => e.action == UiActionType.gotoPage);
    expect(menuEvent.transition, 'slideLeft');
  });
}
