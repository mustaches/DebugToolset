import 'dart:io';

import 'package:debug_tool_set/modules/ui_designer/codegen/c_code_exporter.dart';
import 'package:debug_tool_set/modules/ui_designer/models/project_serializer.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_event.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_page.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_project.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_widget.dart';
import 'package:debug_tool_set/modules/ui_designer/models/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Generates the PSP-style emulator UI sample project into UI_Project/.
/// Run with: flutter test test/ui_sample_psp_project_test.dart
void main() {
  test('generate PSP emulator sample project', () async {
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
        UiProject(name: 'psp_emulator', screenWidth: 480, screenHeight: 282);

    // ------------------------------------------------ page 1: 主界面
    final page1 = UiPage(id: 'page_main', name: '主界面', bgColor: 0xFF001428);
    page1.widgets.addAll([
      // 顶栏
      widget('w_topbar', 'panel', 'top_bar', 0, 0, 480, 34,
          props: {'bgColor': 0xFF00284D}),
      widget('w_title', 'label', 'title', 14, 5, 220, 24,
          props: {'text': 'PSP 模拟器', 'fontSize': 18, 'bold': true}),
      widget('w_clock', 'label', 'clock', 396, 8, 70, 20,
          props: {
            'text': '14:30',
            'fontSize': 12,
            'color': 0xFF9CC3E5,
            'align': 'right'
          }),
      widget('w_topline', 'line', 'top_line', 0, 34, 480, 2,
          props: {'color': 0xFF0A3A66, 'thickness': 2}),
      // 左列：模拟器类型（上下滑动）
      widget('w_emu_hdr', 'label', 'emu_header', 24, 44, 120, 18,
          props: {'text': '模拟器', 'fontSize': 12, 'color': 0xFF7FA8C9}),
      widget(
        'w_emu_list',
        'scrolllist',
        'emu_list',
        24,
        66,
        150,
        200,
        props: {
          'orientation': 'vertical',
          'items': 'PSP,PS1,GBA,GBC,NDS,FC,SFC,MD,街机,N64',
          'itemExtent': 36,
          'spacing': 6,
          'fontSize': 16,
          'selectedIndex': 0,
          'selectedColor': 0xFF1E88E5,
        },
        events: [
          UiEvent(
              type: UiEventType.onValueChange,
              callback: 'on_emulator_changed'),
        ],
      ),
      // 右列：游戏（左右滑动）
      widget('w_game_hdr', 'label', 'game_header', 194, 44, 120, 18,
          props: {'text': '游戏', 'fontSize': 12, 'color': 0xFF7FA8C9}),
      widget(
        'w_game_list',
        'scrolllist',
        'game_list',
        194,
        96,
        262,
        90,
        props: {
          'orientation': 'horizontal',
          'items': '怪物猎人,战神,最终幻想,山脊赛车,合金装备,啪嗒砰,实况足球,寂静岭',
          'itemExtent': 80,
          'spacing': 8,
          'fontSize': 14,
          'selectedIndex': 0,
          'selectedColor': 0xFF1E88E5,
        },
        events: [
          UiEvent(
              type: UiEventType.onValueChange, callback: 'on_game_changed'),
        ],
      ),
      widget('w_hint', 'label', 'hint', 194, 196, 262, 16,
          props: {
            'text': '上下滑动选模拟器，左右滑动选游戏',
            'fontSize': 10,
            'color': 0xFF5F7F99
          }),
      // 按钮
      widget(
        'w_btn_start',
        'button',
        'btn_start',
        330,
        226,
        120,
        38,
        props: {'text': '开始游戏', 'radius': 8},
        events: [UiEvent(type: UiEventType.onClick, callback: 'on_game_start')],
      ),
      widget(
        'w_btn_detail',
        'button',
        'btn_detail',
        194,
        226,
        120,
        38,
        props: {
          'text': '游戏详情',
          'radius': 8,
          'bgColor': 0xFF37474F,
          'pressedColor': 0xFF263238,
        },
        events: [
          UiEvent(
              type: UiEventType.onClick,
              action: UiActionType.gotoPage,
              targetPageId: 'page_detail'),
        ],
      ),
      widget('w_footer', 'label', 'footer', 14, 258, 300, 16,
          props: {
            'text': 'DebugToolSet UI Designer',
            'fontSize': 10,
            'color': 0xFF3F5F79
          }),
    ]);

    // ------------------------------------------------ page 2: 游戏详情
    final page2 = UiPage(id: 'page_detail', name: '游戏详情', bgColor: 0xFF101820);
    page2.widgets.addAll([
      widget('w_card', 'panel', 'detail_card', 40, 40, 400, 180,
          props: {
            'bgColor': 0xFF1A2A3A,
            'radius': 12,
            'borderColor': 0xFF2A4A6A,
            'borderWidth': 1,
          }),
      widget('w_dtitle', 'label', 'detail_title', 60, 56, 200, 28,
          props: {'text': '游戏详情', 'fontSize': 20, 'bold': true}),
      widget('w_dname', 'label', 'detail_name', 60, 96, 240, 20,
          props: {'text': '名称：怪物猎人 P3', 'fontSize': 14}),
      widget('w_dplat', 'label', 'detail_platform', 60, 122, 240, 20,
          props: {'text': '平台：PSP', 'fontSize': 14}),
      widget('w_dsize', 'label', 'detail_size', 60, 148, 240, 20,
          props: {'text': '大小：1.2 GB', 'fontSize': 14}),
      widget(
        'w_btn_back',
        'button',
        'btn_back',
        60,
        230,
        100,
        36,
        props: {
          'text': '返回',
          'bgColor': 0xFF37474F,
          'pressedColor': 0xFF263238,
        },
        events: [
          UiEvent(
              type: UiEventType.onClick,
              action: UiActionType.gotoPage,
              targetPageId: 'page_main'),
        ],
      ),
      widget(
        'w_btn_launch',
        'button',
        'btn_launch',
        320,
        230,
        100,
        36,
        props: {'text': '启动'},
        events: [UiEvent(type: UiEventType.onClick, callback: 'on_game_start')],
      ),
    ]);

    project.pages
      ..add(page1)
      ..add(page2);

    final dir = Directory('UI_Project')..createSync(recursive: true);
    final file = File('${dir.path}/psp_emulator.uiproj');
    file.writeAsStringSync(ProjectSerializer.encode(project));

    // Also export the C code for reference.
    final exportDir = Directory('${dir.path}/exported_c')
      ..createSync(recursive: true);
    await CCodeExporter.export(project, exportDir.path);

    // Round-trip sanity check.
    final decoded =
        ProjectSerializer.decode(file.readAsStringSync());
    expect(decoded.screenWidth, 480);
    expect(decoded.screenHeight, 282);
    expect(decoded.pages.length, 2);
    expect(decoded.pages.first.widgets.length, 12);
    expect(decoded.pages.first.widgets[5].type, 'scrolllist');
  });
}
