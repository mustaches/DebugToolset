import 'dart:typed_data';

import 'package:debug_tool_set/modules/ui_designer/codegen/c_callbacks_codegen.dart';
import 'package:debug_tool_set/modules/ui_designer/codegen/c_project_codegen.dart';
import 'package:debug_tool_set/modules/ui_designer/models/project_serializer.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_event.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_page.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_project.dart';
import 'package:debug_tool_set/modules/ui_designer/models/ui_widget.dart';
import 'package:debug_tool_set/modules/ui_designer/models/widget_registry.dart';
import 'package:debug_tool_set/modules/ui_designer/tools/pixel_formats.dart';
import 'package:flutter_test/flutter_test.dart';

UiProject _sampleProject() {
  final project = UiProject(name: 'demo', screenWidth: 480, screenHeight: 320);
  final page1 = UiPage(id: 'p1', name: '主页', bgColor: 0xFF101010);
  final page2 = UiPage(id: 'p2', name: '设置', bgColor: 0xFF202020);

  final labelDef = WidgetRegistry.of('label')!;
  page1.widgets.add(UiWidgetModel(
    id: 'w1',
    type: 'label',
    name: 'title_1',
    x: 10,
    y: 8,
    width: 200,
    height: 30,
    props: labelDef.defaultProps()
      ..['text'] = '你好'
      ..['align'] = 'center',
  ));
  page1.widgets.add(UiWidgetModel(
    id: 'w2',
    type: 'button',
    name: 'btn_ok',
    x: 20,
    y: 60,
    width: 100,
    height: 40,
    props: WidgetRegistry.of('button')!.defaultProps()..['text'] = '确定',
    events: [
      UiEvent(type: UiEventType.onClick, callback: 'on_ok_click'),
      UiEvent(
          type: UiEventType.onFocus,
          action: UiActionType.gotoPage,
          targetPageId: 'p2'),
    ],
  ));
  page1.events.add(UiEvent(
      type: UiEventType.onTimer, callback: 'tick_update', timerMs: 500));

  project.pages
    ..add(page1)
    ..add(page2);
  return project;
}

void main() {
  group('ProjectSerializer', () {
    test('round-trip keeps pages, widgets, events', () {
      final project = _sampleProject();
      final decoded =
          ProjectSerializer.decode(ProjectSerializer.encode(project));

      expect(decoded.name, 'demo');
      expect(decoded.screenWidth, 480);
      expect(decoded.pages.length, 2);
      final page = decoded.pages.first;
      expect(page.widgets.length, 2);
      final btn = page.widgets[1];
      expect(btn.name, 'btn_ok');
      expect(btn.props['text'], '确定');
      expect(btn.events.length, 2);
      expect(btn.events[0].callback, 'on_ok_click');
      expect(btn.events[1].action, UiActionType.gotoPage);
      expect(btn.events[1].targetPageId, 'p2');
      expect(page.events.single.type, UiEventType.onTimer);
      expect(page.events.single.timerMs, 500);
    });

    test('rejects invalid input', () {
      expect(() => ProjectSerializer.decode('42'), throwsFormatException);
    });
  });

  group('sanitizeCIdentifier', () {
    test('keeps valid identifiers', () {
      expect(sanitizeCIdentifier('on_ok_click'), 'on_ok_click');
    });
    test('sanitizes junk', () {
      expect(sanitizeCIdentifier('  a-b c.d '), 'a_b_c_d');
      expect(sanitizeCIdentifier('123abc'), '_123abc');
    });
    test('returns null when unusable', () {
      expect(sanitizeCIdentifier('你好'), isNull);
      expect(sanitizeCIdentifier('   '), isNull);
    });
  });

  group('WidgetRegistry', () {
    test('all types have unique keys and default sizes', () {
      final keys = WidgetRegistry.all.map((d) => d.type).toSet();
      expect(keys.length, WidgetRegistry.all.length);
      for (final def in WidgetRegistry.all) {
        expect(def.defaultWidth, greaterThan(0));
        expect(def.defaultHeight, greaterThan(0));
        expect(WidgetRegistry.of(def.type), same(def));
      }
    });

    test('defaultProps covers every schema key', () {
      for (final def in WidgetRegistry.all) {
        final props = def.defaultProps();
        for (final p in def.props) {
          expect(props.containsKey(p.key), isTrue,
              reason: '${def.type}.${p.key} missing');
        }
      }
    });
  });

  group('C codegen', () {
    test('ui_pages contains tables, events and start page', () async {
      final project = _sampleProject();
      final result = await CProjectCodegen.generate(project,
          assetReader: (_) async => null);

      expect(result.header, contains('#define UI_SCREEN_WIDTH 480'));
      expect(result.header, contains('#define UI_START_PAGE'));
      expect(result.source, contains('const ui_page_t ui_page_'));
      expect(result.source, contains('UI_W_BUTTON'));
      expect(result.source, contains('on_ok_click'));
      expect(result.source, contains('UI_ACT_GOTO_PAGE'));
      expect(result.source, contains('UI_EV_TIMER'));
      expect(result.source, contains(', 500 },'));
      expect(result.callbacks, containsAll(['on_ok_click', 'tick_update']));
    });

    test('auto callback name is generated for empty callback', () async {
      final project = _sampleProject();
      project.pages.first.widgets[1].events[0].callback = '';
      final result = await CProjectCodegen.generate(project,
          assetReader: (_) async => null);
      expect(result.callbacks, contains('ui_cb_btn_ok_onClick'));
    });

    test('image asset embeds converted bytes', () async {
      final project = _sampleProject();
      final asset = UiAsset(
          id: 'a1',
          name: 'img_logo',
          srcFile: 'logo.png',
          binFile: 'logo.bin',
          width: 2,
          height: 1);
      project.assets.add(asset);
      project.pages.first.widgets.add(UiWidgetModel(
        id: 'w3',
        type: 'image',
        name: 'logo',
        x: 0,
        y: 0,
        width: 32,
        height: 32,
        props: WidgetRegistry.of('image')!.defaultProps()..['asset'] = 'a1',
      ));
      final result = await CProjectCodegen.generate(project,
          assetReader: (_) async => [0x12, 0x34, 0xAB, 0xCD]);
      expect(result.source, contains('static const uint8_t img_logo_data[]'));
      expect(result.source, contains('0x12, 0x34, 0xab, 0xcd'));
    });

    test('callbacks are weak stubs with matching header', () {
      final header = CCallbacksCodegen.header(['on_ok_click']);
      final source = CCallbacksCodegen.source(['on_ok_click']);
      expect(header,
          contains('void on_ok_click(int32_t widget_id, int32_t value);'));
      expect(source, contains('__attribute__((weak))'));
      expect(
          source,
          contains(
              'UI_WEAK void on_ok_click(int32_t widget_id, int32_t value)'));
    });
  });

  group('pixel formats', () {
    test('rgbaToRaw rgb565 matches known values', () {
      // red, green, blue, white
      final rgba = Uint8List.fromList([
        255, 0, 0, 255,
        0, 255, 0, 255,
        0, 0, 255, 255,
        255, 255, 255, 255,
      ]);
      final raw = rgbaToRaw(rgba, 4, 1, PixelFormat.rgb565);
      expect(raw[0] << 8 | raw[1], 0xF800);
      expect(raw[2] << 8 | raw[3], 0x07E0);
      expect(raw[4] << 8 | raw[5], 0x001F);
      expect(raw[6] << 8 | raw[7], 0xFFFF);
    });

    test('rawToRgba inverts rgb565', () {
      final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]);
      final raw = rgbaToRaw(rgba, 2, 1, PixelFormat.rgb565);
      final back = rawToRgba(raw, 2, 1, PixelFormat.rgb565);
      expect(back[0], 255);
      expect(back[1], 0);
      expect(back[2], 0);
      expect(back[4], 0);
      expect(back[5], 0);
      expect(back[6], 255);
    });

    test('gray8 uses luma weights', () {
      final rgba = Uint8List.fromList([255, 255, 255, 255]);
      final raw = rgbaToRaw(rgba, 1, 1, PixelFormat.gray8);
      expect(raw[0], 255);
    });

    test('mono1 packs 8 pixels per byte, MSB first', () {
      final rgba = Uint8List(8 * 4);
      // first and last pixel white
      rgba[0] = rgba[1] = rgba[2] = 255;
      rgba[28] = rgba[29] = rgba[30] = 255;
      final raw = rgbaToRaw(rgba, 8, 1, PixelFormat.mono1);
      expect(raw.length, 1);
      expect(raw[0], 0x81);
    });

    test('column major scanning reorders pixels', () {
      // 2x2 image: A(red) B(green) / C(blue) D(white), row major.
      // Column-major scan order => A C B D.
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, // A
        0, 255, 0, 255, // B
        0, 0, 255, 255, // C
        255, 255, 255, 255, // D
      ]);
      final raw = rgbaToRaw(rgba, 2, 2, PixelFormat.gray8, columnMajor: true);
      expect(raw[0], 76); // A red: 255*299/1000
      expect(raw[1], 29); // C blue: 255*114/1000
      expect(raw[2], 149); // B green: 255*587/1000
      expect(raw[3], 255); // D white
    });
  });
}
