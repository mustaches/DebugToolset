import 'dart:io';

import 'package:debug_tool_set/modules/ui_designer/codegen/c_code_exporter.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_event.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_page.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_project.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_widget.dart';
import 'package:debug_tool_set/modules/ui_designer/models/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

// Dumps the generated C files into scratch/gen_c for manual / compiler
// inspection. Not a real assertion test.
void main() {
  test('dump generated C files', () async {
    final project =
        UiProject(name: 'demo', screenWidth: 480, screenHeight: 320);
    final page1 = UiPage(id: 'p1', name: 'main', bgColor: 0xFF101010);
    final page2 = UiPage(id: 'p2', name: 'settings', bgColor: 0xFF202020);

    page1.widgets.add(UiWidgetModel(
      id: 'w1',
      type: 'label',
      name: 'title_1',
      x: 10,
      y: 8,
      width: 200,
      height: 30,
      props: WidgetRegistry.of('label')!.defaultProps()..['text'] = 'Hello',
    ));
    page1.widgets.add(UiWidgetModel(
      id: 'w2',
      type: 'button',
      name: 'btn_ok',
      x: 20,
      y: 60,
      width: 100,
      height: 40,
      props: WidgetRegistry.of('button')!.defaultProps()..['text'] = 'OK',
      events: [
        UiEvent(type: UiEventType.onClick, callback: 'on_ok_click'),
        UiEvent(
            type: UiEventType.onFocus,
            action: UiActionType.gotoPage,
            targetPageId: 'p2'),
      ],
    ));
    page1.widgets.add(UiWidgetModel(
      id: 'w3',
      type: 'slider',
      name: 'slider_vol',
      x: 20,
      y: 120,
      width: 180,
      height: 30,
      props: WidgetRegistry.of('slider')!.defaultProps(),
      events: [UiEvent(type: UiEventType.onValueChange, callback: '')],
    ));
    page1.events.add(UiEvent(
        type: UiEventType.onTimer, callback: 'tick_update', timerMs: 500));

    project.pages
      ..add(page1)
      ..add(page2);

    final dir = Directory('scratch/gen_c')..createSync(recursive: true);
    final files = await CCodeExporter.export(project, dir.path);
    expect(files.length, greaterThanOrEqualTo(6));
  });
}
