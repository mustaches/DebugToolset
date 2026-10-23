// 「仿真波形」标签页总线数值格式化（sim_wave_tab.dart 的 formatBusBits）
// 高位 0 补全测试。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:debug_tool_set/modules/isp_studio/codegen/sim_wave_store.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/vcd_parser.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/sim_wave_tab.dart';

void main() {
  group('formatBusBits 高位 0 补全', () {
    test('hex 按信号位宽补全（24 位恒 6 位十六进制）', () {
      // VCD 值位串高位 0 被省略（20 位）时按 width=24 补齐。
      expect(formatBusBits('111111111101111111', BusDisplayFormat.hex, width: 24),
          '0x03FF7F');
      expect(formatBusBits('0' * 24, BusDisplayFormat.hex, width: 24),
          '0x000000');
      // 未给位宽时按位串长度（向后兼容）。
      expect(formatBusBits('11111111', BusDisplayFormat.hex), '0xFF');
    });

    test('decimal 补全到最大值位数（8 位 → 3 位十进制）', () {
      expect(formatBusBits('101', BusDisplayFormat.decimal, width: 8), '005');
      expect(formatBusBits('11111111', BusDisplayFormat.decimal, width: 8),
          '255');
    });

    test('binary 左侧补 0 到 4 的倍数', () {
      expect(formatBusBits('101', BusDisplayFormat.binary, width: 8),
          '0000 0101');
    });

    test('含 x/z 保持原口径', () {
      expect(formatBusBits('10x1', BusDisplayFormat.hex, width: 8), 'x');
      expect(formatBusBits('10x1', BusDisplayFormat.binary, width: 8),
          '0000 10x1');
    });
  });

  group('parseBusValueInput 总线值解析（Bus Search）', () {
    test('缺省十六进制（可带 0x 前缀），高位 0 按位宽补全', () {
      expect(parseBusValueInput('03FF7F', 24), '000000111111111101111111');
      expect(parseBusValueInput('0x03FF7F', 24), '000000111111111101111111');
      expect(parseBusValueInput('F', 8), '00001111');
      // 超宽截取低位。
      expect(parseBusValueInput('1FF', 8), '11111111');
    });

    test('0b 前缀二进制（允许 x/z），超长拒绝', () {
      expect(parseBusValueInput('0b101', 8), '00000101');
      expect(parseBusValueInput('0b1x1z', 4), '1x1z');
      expect(parseBusValueInput('0b', 8), isNull);
      expect(parseBusValueInput('0b11111', 4), isNull);
    });

    test('hex 的 x 为整组 4 位未知', () {
      expect(parseBusValueInput('0xxf', 8), 'xxxx1111');
    });

    test('非法输入返回 null', () {
      expect(parseBusValueInput('', 8), isNull);
      expect(parseBusValueInput('   ', 8), isNull);
      expect(parseBusValueInput('0xGG', 8), isNull);
      expect(parseBusValueInput('12', 0), isNull);
    });
  });

  group('busBitsEqual 规范化相等（VCD 短记法兼容）', () {
    test('全等直接相等', () {
      expect(busBitsEqual('0101', '0101'), isTrue);
      expect(busBitsEqual('0101', '0110'), isFalse);
    });

    test('短记法右对齐：数字短串补 0 扩展', () {
      // `b0 "` 全 0 向量 ≡ 24 个 0（用户照显示输入的补全值）。
      expect(busBitsEqual('0', '0' * 24), isTrue);
      expect(busBitsEqual('101', '00000101'), isTrue);
      expect(busBitsEqual('111111111101111111',
          '000000111111111101111111'), isTrue);
      // 扩展位与长串高位不符则不等。
      expect(busBitsEqual('101', '10000101'), isFalse);
      expect(busBitsEqual('0', '0' * 23 + '1'), isFalse);
    });

    test('短记法：x/z 短串按首字符扩展', () {
      expect(busBitsEqual('x', 'xxxxxxxx'), isTrue);
      expect(busBitsEqual('z', 'zzzz'), isTrue);
      expect(busBitsEqual('x1', 'xxxxxxx1'), isTrue);
      // 数字短串不向 x 扩展。
      expect(busBitsEqual('1', 'xxxxxxx1'), isFalse);
    });
  });

  addWaveCursorTest();
}

// 见文件尾部 addWaveCursorTest 定义。

// 最小 VCD：clk 周期 10ns + 24 位总线跳变。
const _kTestVcd = '''
\$timescale 1ps \$end
\$scope module tb \$end
\$var wire 1 ! clk \$end
\$var wire 24 " in_data [23:0] \$end
\$upscope \$end
\$enddefinitions \$end
#0
0!
b000000000000000000000000 "
#5000
1!
b000000111111111101111111 "
#10000
0!
b111111111111111111111111 "
#15000
1!
''';

// 短记法 VCD（高位 0 省略的右对齐写法，iverilog 等工具的真实输出
// 形态）：总线值 `b0 "`（全 0）/ 18 位短串（0x03FF7F）/ 全 1。
const _kShortVcd = '''
\$timescale 1ps \$end
\$scope module tb \$end
\$var wire 1 ! clk \$end
\$var wire 24 " in_data [23:0] \$end
\$upscope \$end
\$enddefinitions \$end
#0
0!
b0 "
#5000
1!
b111111111101111111 "
#10000
0!
b111111111111111111111111 "
#15000
1!
''';

/// 波形区交互：左键点击应在鼠标位置放置 M 光标（Mcursor.time 显示时刻）。
void addWaveCursorTest() {
  testWidgets('波形区左键点击放置 M 光标', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();
    // 放置前：Mcursor.time 行在、时间值行无内容（无 ps 文本）。
    expect(
      find.textContaining('.time', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('ps', findRichText: true),
      findsNothing,
    );
    // 波形区中部点击（右于 Scopes 190 + Signal 170 + 分隔条）。
    await tester.tapAt(const Offset(600, 400));
    await tester.pump();
    // 放置后：时间值行显示时刻（000,…ps）。
    expect(
      find.textContaining('ps', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('波形区左键点击选中所在行信号', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();
    // 点击前：无选中行高亮（暗蓝 #094771）。
    bool hasSelection() => tester
        .widgetList<Container>(find.byType(Container))
        .any((c) => c.color == const Color(0xFF094771));
    expect(hasSelection(), isFalse);
    // 取 Signal 列表中 clk 文本的纵坐标（Scopes 树/波形区数值列里也有
    // 同名文本，按 x 范围过滤出信号名面板内的），在同一行波形区点击。
    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    expect(clkPos, isNotNull);
    await tester.tapAt(Offset(600, clkPos!.dy));
    await tester.pump();
    expect(hasSelection(), isTrue);
  });

  testWidgets('import UI.cfg 后（显示列表物化+总线展开）波形区点击选中',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();

    // 信号名面板内（x 范围）查找 name 文本的全局中心坐标。
    Offset? namesPos(String name) {
      Offset? pos;
      for (final e in find.text(name).evaluate()) {
        final box = e.renderObject! as RenderBox;
        final p = box.localToGlobal(box.size.center(Offset.zero));
        if (p.dx > 200 && p.dx < 360) pos = p;
      }
      return pos;
    }

    // 信号名面板内 name 所在行是否有选中高亮（暗蓝 #094771 容器）。
    bool namesRowSelected(String name) {
      for (final e in find.text(name).evaluate()) {
        final box = e.renderObject! as RenderBox;
        final p = box.localToGlobal(box.size.center(Offset.zero));
        if (p.dx <= 200 || p.dx >= 360) continue;
        var hit = false;
        e.visitAncestorElements((a) {
          final w = a.widget;
          if (w is Container && w.color == const Color(0xFF094771)) {
            hit = true;
          }
          return !hit;
        });
        if (hit) return true;
      }
      return false;
    }

    // 总线展开（等价 import cfg 恢复 expandedBuses）：点击 in_data 行
    // 的展开箭头（信号名面板 x 范围内的 chevron_right）。
    Offset? expandPos;
    for (final e in find.byIcon(Icons.chevron_right).evaluate()) {
      final box = e.renderObject! as RenderBox;
      final p = box.localToGlobal(box.size.center(Offset.zero));
      if (p.dx > 200 && p.dx < 360) expandPos = p;
    }
    expect(expandPos, isNotNull);
    await tester.tapAt(expandPos!);
    await tester.pump();

    // 显示列表物化（等价 import cfg 恢复 displayedPaths）：信号名面板
    // 右键 clk 行 → 「在当前信号上方插入分隔符」。
    final clkNames = namesPos('clk');
    expect(clkNames, isNotNull);
    await tester.tapAt(clkNames!, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('在当前信号上方插入分隔符'));
    await tester.pumpAndSettle();

    // 点击 clk 整信号行 → 选中 clk。
    final clkRow = namesPos('clk');
    expect(clkRow, isNotNull);
    await tester.tapAt(Offset(600, clkRow!.dy));
    await tester.pump();
    expect(namesRowSelected('clk'), isTrue);
    expect(namesRowSelected('in_data [23:0]'), isFalse);

    // 点击 in_data 展开的位行 → 应选中宿主信号 in_data（位行的派生
    // 1 位信号不在显示列表中，直接上报其名字会选中落空；宿主行文本
    // 带位宽后缀）。
    final bitRow = namesPos('in_data [5]');
    expect(bitRow, isNotNull);
    await tester.tapAt(Offset(600, bitRow!.dy));
    await tester.pump();
    expect(namesRowSelected('in_data [23:0]'), isTrue);
    expect(namesRowSelected('clk'), isFalse);
  });

  testWidgets('波形区右键菜单查找上一个/下一个匹配项', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();

    // M 光标时刻文本（左侧时间值行）。
    String mcursorText() {
      final e =
          find.textContaining('ps', findRichText: true).evaluate().single;
      final w = e.widget;
      if (w is Text) return w.data ?? w.textSpan?.toPlainText() ?? '';
      if (w is RichText) return w.text.toPlainText();
      return '';
    }

    // 右键菜单项启用状态。
    bool menuItemEnabled(String label) =>
        tester
            .widget<MenuItemButton>(
                find.widgetWithText(MenuItemButton, label))
            .onPressed !=
        null;

    // 工具栏按钮启用状态（禁用置灰 white24，启用为 null）。
    Color? toolbarIconColor(String asset) => tester
        .widgetList<Image>(find.byType(Image))
        .firstWhere((im) =>
            im.image is AssetImage &&
            (im.image as AssetImage).assetName == asset)
        .color;

    // 匹配区是否显示指定边沿图标。
    bool hasEdgeIcon(String asset) => tester
        .widgetList<Image>(find.byType(Image))
        .any((im) =>
            im.image is AssetImage &&
            (im.image as AssetImage).assetName == asset);

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    expect(clkPos, isNotNull);
    final clkRowPos = clkPos!;
    // 左键点击 clk 行：选中 + 放置 M 光标（点击处在 5000ps 与 10000ps
    // 之间，clk=1；吸附半径外不贴沿）。
    await tester.tapAt(Offset(600, clkRowPos.dy));
    await tester.pump();
    final t0 = mcursorText();
    expect(t0, contains('ps'));

    // 右键弹出菜单：应含两个查找匹配项；光标处值 0 的段起点前后各有
    // 一个（0ps/10000ps），两个方向均可用（菜单项与工具栏同步）。
    await tester.tapAt(Offset(600, clkRowPos.dy), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('查找上一个匹配项'), findsOneWidget);
    expect(find.text('查找下一个匹配项'), findsOneWidget);
    expect(menuItemEnabled('查找上一个匹配项'), isTrue);
    expect(menuItemEnabled('查找下一个匹配项'), isTrue);
    expect(toolbarIconColor('icons/chevron-left.png'), isNull);
    expect(toolbarIconColor('icons/chevron-right.png'), isNull);

    // 下一个匹配：clk=1 的下一段起点在 15000ps（测试 VCD clk 边沿为
    // 0/5000/10000/15000），光标应移走（菜单关闭动画需 pumpAndSettle
    // 才冲刷重建）。
    await tester.tap(find.text('查找下一个匹配项'));
    await tester.pumpAndSettle();
    final t1 = mcursorText();
    expect(t1, isNot(t0));
    // clk=0 的段起点共 2 个（0ps/10000ps），命中第二个 → Matched 2/2；
    // 右部下行显示信号名 + 下降沿图标与文字（值 0 段起点即下降沿）。
    expect(find.textContaining('Matched 2/2', findRichText: true), findsOneWidget);
    expect(find.textContaining('clk  ', findRichText: true), findsOneWidget);
    expect(hasEdgeIcon('icons/falling-edge.png'), isTrue);
    expect(find.text('下降沿'), findsOneWidget);

    // 已到最后一个匹配：「查找下一个匹配项」置灰（菜单项与工具栏），
    // 「查找上一个匹配项」仍可用。
    await tester.tapAt(Offset(600, clkRowPos.dy), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(menuItemEnabled('查找下一个匹配项'), isFalse);
    expect(menuItemEnabled('查找上一个匹配项'), isTrue);
    expect(toolbarIconColor('icons/chevron-right.png'), Colors.white24);
    expect(toolbarIconColor('icons/chevron-left.png'), isNull);

    // 上一个匹配：光标应移到更早的同值段起点（≠ 10000ps）。
    await tester.tap(find.text('查找上一个匹配项'));
    await tester.pumpAndSettle();
    final t2 = mcursorText();
    expect(t2, isNot(t1));
    expect(find.textContaining('Matched 1/2', findRichText: true), findsOneWidget);

    // 已到第一个匹配：「查找上一个匹配项」置灰，「查找下一个匹配项」
    // 仍可用；点击它回到 10000ps（顺带关菜单）。
    await tester.tapAt(Offset(600, clkRowPos.dy), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(menuItemEnabled('查找上一个匹配项'), isFalse);
    expect(menuItemEnabled('查找下一个匹配项'), isTrue);
    expect(toolbarIconColor('icons/chevron-left.png'), Colors.white24);
    expect(toolbarIconColor('icons/chevron-right.png'), isNull);
    await tester.tap(find.text('查找下一个匹配项'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Matched 2/2', findRichText: true), findsOneWidget);
    // 输入框同步显示「当前/总数」。
    expect(find.text('2/2'), findsOneWidget);

    // 序号输入框回车直达：输入 1 → 匹配 1/2；输入 9 越界钳位到
    // 总数 → 匹配 2/2（输入框同步）。
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('Matched 1/2', findRichText: true), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('Matched 2/2', findRichText: true), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);

    // 手动点击移动 M 光标：匹配数量与信号名/边沿图标一并清除。
    await tester.tapAt(Offset(700, clkRowPos.dy));
    await tester.pump();
    expect(find.textContaining('Matched', findRichText: true), findsNothing);
    expect(hasEdgeIcon('icons/falling-edge.png'), isFalse);

    // 值为 1 的段起点显示上升沿图标（点击 x=1000 → ~7657ps，clk=1，
    // 上一个匹配为 5000ps 段起点）。
    await tester.tapAt(Offset(1000, clkRowPos.dy));
    await tester.pump();
    await tester.tapAt(Offset(1000, clkRowPos.dy), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找上一个匹配项'));
    await tester.pumpAndSettle();
    expect(hasEdgeIcon('icons/rising-edge.png'), isTrue);
    expect(find.text('上升沿'), findsOneWidget);
  });

  testWidgets('总线匹配显示带位宽的总线名', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();

    // 点击 in_data 行：选中 + 放置 M 光标（光标处值为 0x000000）。
    Offset? busPos;
    for (final e in find.text('in_data [23:0]').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) busPos = pos;
    }
    expect(busPos, isNotNull);
    final busRowPos = busPos!;
    await tester.tapAt(Offset(600, busRowPos.dy));
    await tester.pump();

    // 右键 → 查找上一个匹配项（0ps 段起点）→ 匹配区应显示
    // 「in_data [23:0]  0x000000」（总线名带位宽）。
    await tester.tapAt(Offset(600, busRowPos.dy), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查找上一个匹配项'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Matched 1/1', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('in_data [23:0]  0x000000'),
        findsOneWidget);
  });

  testWidgets('Dimension 基线标注法（放线/自动错行/截断/右键退出）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    // 标注像素判定（白色文字/箭头/徽章或 30 度灰竖线，含抗锯齿）。
    bool isAnnot(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
      final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
      if (hi - lo >= 40) return false;
      return lo > 120 || (lo > 33 && hi < 120);
    }

    // 预览/悬停黄色（0xFFFFFF00）判定。
    bool isYellow(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 110 && p.g > 110 && p.b < p.r * 0.5;
    }

    // 横线采样：y 带 × x 范围内任一标注像素即命中。
    bool arrowSpanAt(img.Image im, int y0, int y1, int x0, int x1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          if (isAnnot(im, x, y)) return true;
        }
      }
      return false;
    }

    // 竖线采样：列带 [x-2, x+1] × y 范围内任一标注像素即视为线存在。
    bool whiteLineAt(img.Image im, int x, double y0, double y1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return true;
        }
      }
      return false;
    }

    bool yellowLineAt(img.Image im, int x, double y0, double y1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isYellow(im, xx, yy)) return true;
        }
      }
      return false;
    }

    // 截断验证：列带 [x-2, x+1] 在 y0 之下无标注像素。
    bool noWhiteBelow(img.Image im, int x, double y0, double canvasTop) {
      for (var yy = y0.round(); yy <= (canvasTop + 700).round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return false;
        }
      }
      return true;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;
    // 标注段行：第 0 行 baseY=局部 128（本例 2 行信号，行底 68+60），
    // 第 1 行 +162。
    final row0y = (canvasTop + 128).round();
    final row1y = (canvasTop + 162).round();

    // 竖线存在性：列带 [x-2, x+1] × 顶部窄带（时间尺下沿与 tn 徽章之间）。
    bool whiteLineTopAt(img.Image im, int x) {
      for (var yy = (canvasTop + 21).round(); yy <= (canvasTop + 34).round();
          yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return true;
        }
      }
      return false;
    }

    // M 光标时刻文本（未放置时无 ps 文本）。
    Finder mTimeFinder() => find.textContaining('ps', findRichText: true);

    // Dimension Baseline 按钮无需 M 光标即可用。
    Color? dimBtnColor() => tester
        .widgetList<Image>(find.byType(Image))
        .firstWhere((im) =>
            im.image is AssetImage &&
            (im.image as AssetImage).assetName == 'icons/dim-base.png')
        .color;
    expect(dimBtnColor(), isNull);

    // 进入基线标注法模式（实心黄线跟随鼠标）。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Baseline'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(Offset(700, canvasTop + 200));
    await tester.pump();
    var im = await shot();
    expect(yellowLineAt(im, 700, canvasTop + 30, canvasTop + 700), isTrue,
        reason: '黄线跟随鼠标');
    expect(whiteLineTopAt(im, 700), isFalse, reason: '尚未放线');

    // 放第一条线（t0）：仅竖线，不产生标注段。
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await tester.pump();
    im = await shot();
    expect(whiteLineTopAt(im, 700), isTrue, reason: 't0 竖线已放置');
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 1090), isFalse,
        reason: '首条线不产生标注段');

    // 放第二条线（1100）：基线法段 t0→t1（700→1100）在第 0 行。
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await mouse.moveTo(Offset(1400, canvasTop + 200));
    await tester.pump();
    im = await shot();
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 1090), isTrue,
        reason: '基线法段 700→1100（第 0 行）');

    // 放第三条线（950）：新段 700→950 与既有 700→1100 水平交叠——自动
    // 错行：短段 700→950 在第 0 行，长段 700→1100 退到第 1 行。
    await mouse.down(Offset(950, canvasTop + 200));
    await mouse.up();
    await mouse.moveTo(Offset(1400, canvasTop + 200));
    await tester.pump();
    im = await shot();
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 940), isTrue,
        reason: '短段 700→950 在第 0 行');
    expect(arrowSpanAt(im, row0y, row0y + 2, 960, 1090), isFalse,
        reason: '第 0 行无长段残留');
    expect(arrowSpanAt(im, row1y, row1y + 2, 710, 1090), isTrue,
        reason: '长段 700→1100 自动错到第 1 行');

    // 竖线截断：每条线止于自身作为端点的最低箭头线下 8px。
    // t0（700）关联第 0/1 两行段 → 局部 170；950 仅第 0 行 → 136；
    // 1100 仅第 1 行 → 170。（950/1100 的列带被外来段的标签/箭头
    // 横穿，只能在线身区段验证——见各段注释。）
    expect(whiteLineAt(im, 700, canvasTop + 164, canvasTop + 170), isTrue,
        reason: 't0 续画到最低箭头线下 8px（局部 170）');
    expect(noWhiteBelow(im, 700, canvasTop + 178, canvasTop), isTrue,
        reason: 't0 止于局部 170');
    // 950：线身止于 136（本段箭头线 128 + 8）——130-136 有线、
    // 138-144（外来段标签 ~145 起）无线。
    expect(whiteLineAt(im, 950, canvasTop + 130, canvasTop + 136), isTrue,
        reason: '950 线身续画到本段箭头线下 8px');
    expect(whiteLineAt(im, 950, canvasTop + 138, canvasTop + 144), isFalse,
        reason: '950 止于本段箭头线下 8px（局部 136）');
    // 1100：关联第 1 行段 → 170（其列带被第 0 行短段箭头 128 横穿，
    // 外来段标签在 791-859 不覆盖 1100；只验证 170 之下无线）。
    expect(whiteLineAt(im, 1100, canvasTop + 164, canvasTop + 170), isTrue,
        reason: '1100 续画到本段箭头线下 8px（局部 170）');
    expect(noWhiteBelow(im, 1100, canvasTop + 178, canvasTop), isTrue,
        reason: '1100 止于局部 170');

    // 右键退出模式：黄线消失，左键恢复移动 M 光标（不再放线）。
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pump();
    await tester.tapAt(Offset(1400, canvasTop + 300));
    await tester.pump();
    expect(mTimeFinder(), findsOneWidget, reason: '退出后左键移动 M 光标');
    im = await shot();
    expect(whiteLineTopAt(im, 1400), isFalse, reason: '退出后左键不再放线');
    expect(yellowLineAt(im, 1400, canvasTop + 30, canvasTop + 700), isFalse,
        reason: '退出后无黄线');
    // 退出模式后标注保留且不可改动：拖 950 线不动。
    await tester.dragFrom(Offset(950, canvasTop + 40), const Offset(50, 0));
    await tester.pump();
    im = await shot();
    expect(whiteLineTopAt(im, 950), isTrue, reason: '退出模式后标注不可改动');
    expect(whiteLineTopAt(im, 1000), isFalse);
  });

  testWidgets('Dimension 标注 悬停高亮与 Del 删除（竖线/标注段/菜单清除）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    bool isAnnot(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
      final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
      if (hi - lo >= 40) return false;
      return lo > 120 || (lo > 33 && hi < 120);
    }

    bool isYellow(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 110 && p.g > 110 && p.b < p.r * 0.5;
    }

    bool arrowSpanAt(img.Image im, int y0, int y1, int x0, int x1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          if (isAnnot(im, x, y)) return true;
        }
      }
      return false;
    }

    bool yellowSpanAt(img.Image im, int y0, int y1, int x0, int x1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          if (isYellow(im, x, y)) return true;
        }
      }
      return false;
    }

    bool whiteLineAt(img.Image im, int x, double y0, double y1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return true;
        }
      }
      return false;
    }

    bool yellowLineAt(img.Image im, int x, double y0, double y1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isYellow(im, xx, yy)) return true;
        }
      }
      return false;
    }

    bool noWhiteBelow(img.Image im, int x, double y0, double canvasTop) {
      for (var yy = y0.round(); yy <= (canvasTop + 700).round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return false;
        }
      }
      return true;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;
    final row0y = (canvasTop + 128).round();

    // 进入基线标注法模式并放置 t0（700）、t1（1100）→ 段 700→1100。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Baseline'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await tester.pump();

    // 悬停竖线 1100：该线与以其为端点的标注段黄；700 不黄。
    await mouse.moveTo(Offset(1100, canvasTop + 200));
    await tester.pump();
    var im = await shot();
    expect(yellowLineAt(im, 1100, canvasTop + 30, canvasTop + 110), isTrue,
        reason: '悬停竖线：该线黄');
    expect(yellowSpanAt(im, row0y - 2, row0y + 2, 710, 1090), isTrue,
        reason: '悬停竖线：以其为端点的段黄');
    expect(yellowLineAt(im, 700, canvasTop + 96, canvasTop + 116), isFalse,
        reason: '悬停竖线：另一条线不黄');

    // Del 删除竖线 1100：关联段一并删除；700 保留且上下贯穿（无关联段）。
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    im = await shot();
    expect(whiteLineAt(im, 1100, canvasTop + 30, canvasTop + 700), isFalse,
        reason: '竖线 1100 已删除');
    expect(arrowSpanAt(im, row0y - 2, row0y + 2, 710, 1090), isFalse,
        reason: '关联标注段一并删除');
    expect(whiteLineAt(im, 700, canvasTop + 30, canvasTop + 110), isTrue,
        reason: '700 保留');
    expect(noWhiteBelow(im, 700, canvasTop + 200, canvasTop), isFalse,
        reason: '无关联段的线上下贯穿');

    // 重新放置 1100（模式仍激活；非最早线——从 t0=700 生成段）→
    // 段 700→1100 恢复。
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await tester.pump();
    im = await shot();
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 1090), isTrue,
        reason: '重新放置后段恢复');

    // 悬停标注段（850, 第 0 行）：仅该段黄，两条竖线不黄。
    await mouse.moveTo(Offset(850, row0y.toDouble()));
    await tester.pump();
    im = await shot();
    expect(yellowSpanAt(im, row0y - 2, row0y + 2, 710, 1090), isTrue,
        reason: '悬停标注段：该段黄');
    expect(yellowLineAt(im, 700, canvasTop + 96, canvasTop + 116), isFalse,
        reason: '悬停标注段：竖线不黄');
    expect(yellowLineAt(im, 1100, canvasTop + 96, canvasTop + 116), isFalse,
        reason: '悬停标注段：竖线不黄');

    // Del 删除标注段：竖线保留。
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    im = await shot();
    expect(arrowSpanAt(im, row0y - 2, row0y + 2, 710, 1090), isFalse,
        reason: '标注段已删除');
    expect(whiteLineAt(im, 700, canvasTop + 30, canvasTop + 110), isTrue,
        reason: '竖线 700 保留');
    expect(whiteLineAt(im, 1100, canvasTop + 30, canvasTop + 110), isTrue,
        reason: '竖线 1100 保留');

    // 右键退出模式后菜单「删除标注」：清除全部标注；无标注时置灰。
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pump();
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('删除标注'), findsOneWidget);
    expect(
        tester
                .widget<MenuItemButton>(
                    find.widgetWithText(MenuItemButton, '删除标注'))
                .onPressed !=
            null,
        isTrue,
        reason: '有标注时「删除标注」可用');
    await tester.tap(find.text('删除标注'));
    await tester.pumpAndSettle();
    im = await shot();
    expect(whiteLineAt(im, 700, canvasTop + 30, canvasTop + 700), isFalse,
        reason: '菜单删除标注：700 已清除');
    expect(whiteLineAt(im, 1100, canvasTop + 30, canvasTop + 700), isFalse,
        reason: '菜单删除标注：1100 已清除');
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<MenuItemButton>(
                find.widgetWithText(MenuItemButton, '删除标注'))
            .onPressed,
        isNull,
        reason: '无标注时「删除标注」置灰');
    await tester.tapAt(Offset(1400, canvasTop + 300)); // 关菜单
    await tester.pumpAndSettle();

    // 右键菜单「进入连续标注模式」：进入后黄线跟随。
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('进入连续标注模式'), findsOneWidget);
    await tester.tap(find.text('进入连续标注模式'));
    await tester.pumpAndSettle();
    await mouse.moveTo(Offset(1300, canvasTop + 300));
    await tester.pump();
    im = await shot();
    expect(yellowLineAt(im, 1300, canvasTop + 30, canvasTop + 700), isTrue,
        reason: '菜单进入连续标注模式后黄线跟随');
  });

  testWidgets('Dimension 连续标注法（链式段同一行+插入自动错行）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    bool isAnnot(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
      final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
      if (hi - lo >= 40) return false;
      return lo > 120 || (lo > 33 && hi < 120);
    }

    bool arrowSpanAt(img.Image im, int y0, int y1, int x0, int x1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          if (isAnnot(im, x, y)) return true;
        }
      }
      return false;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;
    final row0y = (canvasTop + 128).round();
    final row1y = (canvasTop + 162).round();

    // Dimension Continue 按钮无需 M 光标即可用。
    Color? dimContBtnColor() => tester
        .widgetList<Image>(find.byType(Image))
        .firstWhere((im) =>
            im.image is AssetImage &&
            (im.image as AssetImage).assetName == 'icons/dim-continue.png')
        .color;
    expect(dimContBtnColor(), isNull);

    // 进入连续标注法模式，依次放线 700 / 900 / 1100：链式段 700→900、
    // 900→1100 端点相接不算交叠——同一行。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Continue'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(900, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await mouse.moveTo(Offset(1400, canvasTop + 200));
    await tester.pump();
    var im = await shot();
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 890), isTrue,
        reason: '链式段 700→900（第 0 行）');
    expect(arrowSpanAt(im, row0y, row0y + 2, 910, 1090), isTrue,
        reason: '链式段 900→1100（与左段同一行）');
    expect(arrowSpanAt(im, row1y, row1y + 2, 710, 1090), isFalse,
        reason: '链式段无需错行（第 1 行为空）');

    // 在 700 与 900 之间插入 800：新段 700→800（前一条线为基线）；
    // 700→900 与两段都交叠——自动错到第 1 行。
    await mouse.down(Offset(800, canvasTop + 200));
    await mouse.up();
    await mouse.moveTo(Offset(1400, canvasTop + 200));
    await tester.pump();
    im = await shot();
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 790), isTrue,
        reason: '插入段 700→800（第 0 行）');
    expect(arrowSpanAt(im, row0y, row0y + 2, 810, 890), isFalse,
        reason: '700→900 让出第 0 行');
    expect(arrowSpanAt(im, row1y, row1y + 2, 710, 890), isTrue,
        reason: '700→900 自动错到第 1 行');
    expect(arrowSpanAt(im, row0y, row0y + 2, 910, 1090), isTrue,
        reason: '900→1100 仍在第 0 行');
  });

  testWidgets('Dimension 两种标注法混合（链式段同行+基线长段错行+跨法删除）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    bool isAnnot(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
      final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
      if (hi - lo >= 40) return false;
      return lo > 120 || (lo > 33 && hi < 120);
    }

    bool arrowSpanAt(img.Image im, int y0, int y1, int x0, int x1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          if (isAnnot(im, x, y)) return true;
        }
      }
      return false;
    }

    bool whiteLineAt(img.Image im, int x, double y0, double y1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return true;
        }
      }
      return false;
    }

    bool noWhiteBelow(img.Image im, int x, double y0, double canvasTop) {
      for (var yy = y0.round(); yy <= (canvasTop + 700).round(); yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return false;
        }
      }
      return true;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;
    final row0y = (canvasTop + 128).round();
    final row1y = (canvasTop + 162).round();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // 连续标注法放线 700 / 900 / 1100：链式段在第 0 行。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Continue'),
        matching: find.byType(InkWell)));
    await tester.pump();
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(900, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await tester.pump();
    // 右键退出后换基线标注法放 1300：长段 700→1300 与链式段混合共存，
    // 自动错到第 1 行。
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pump();
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Baseline'),
        matching: find.byType(InkWell)));
    await tester.pump();
    await mouse.down(Offset(1300, canvasTop + 200));
    await mouse.up();
    await mouse.moveTo(Offset(1400, canvasTop + 200));
    await tester.pump();
    var im = await shot();
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 890), isTrue,
        reason: '连续法链式段 700→900 保留在第 0 行');
    expect(arrowSpanAt(im, row0y, row0y + 2, 910, 1090), isTrue,
        reason: '连续法链式段 900→1100 保留在第 0 行');
    expect(arrowSpanAt(im, row1y, row1y + 2, 710, 1290), isTrue,
        reason: '基线法长段 700→1300 自动错到第 1 行（两种标注法混合）');

    // 竖线截断：每条线止于自身作为端点的最低箭头线下 8px（跨法关联
    // 同样生效）：700 关联第 0/1 行 → 170；900/1100 仅第 0 行 → 136；
    // 1300 仅第 1 行 → 170。（900/1100 的列带被外来长段箭头（局部
    // 162）横穿，线身在 136 与 162 之间的区段验证。）
    expect(whiteLineAt(im, 700, canvasTop + 164, canvasTop + 170), isTrue,
        reason: '700 续画到最低箭头线下 8px（局部 170）');
    expect(noWhiteBelow(im, 700, canvasTop + 178, canvasTop), isTrue);
    expect(whiteLineAt(im, 900, canvasTop + 130, canvasTop + 136), isTrue,
        reason: '900 线身续画到第 0 行箭头线下 8px');
    expect(whiteLineAt(im, 900, canvasTop + 138, canvasTop + 158), isFalse,
        reason: '900 止于第 0 行箭头线下 8px');
    expect(whiteLineAt(im, 1100, canvasTop + 130, canvasTop + 136), isTrue,
        reason: '1100 线身续画到第 0 行箭头线下 8px');
    expect(whiteLineAt(im, 1100, canvasTop + 138, canvasTop + 158), isFalse,
        reason: '1100 止于第 0 行箭头线下 8px');
    expect(noWhiteBelow(im, 1300, canvasTop + 178, canvasTop), isTrue,
        reason: '1300 止于第 1 行箭头线下 8px');

    // 悬停长段（1000, 第 1 行）+ Del：只删该段，链式段与竖线保留。
    await mouse.moveTo(Offset(1000, row1y.toDouble()));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    im = await shot();
    expect(arrowSpanAt(im, row1y - 2, row1y + 2, 710, 1290), isFalse,
        reason: '长段已删除');
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 890), isTrue,
        reason: '链式段不受影响');
    expect(noWhiteBelow(im, 1300, canvasTop + 200, canvasTop), isFalse,
        reason: '1300 竖线保留且上下贯穿');
  });

  testWidgets('Dimension 标注 拖动（竖线端点跟随+标注段换行）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    bool isAnnot(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
      final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
      if (hi - lo >= 40) return false;
      return lo > 120 || (lo > 33 && hi < 120);
    }

    bool arrowSpanAt(img.Image im, int y0, int y1, int x0, int x1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          if (isAnnot(im, x, y)) return true;
        }
      }
      return false;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;
    final row0y = (canvasTop + 128).round();
    final row1y = (canvasTop + 162).round();

    bool whiteLineTopAt(img.Image im, int x) {
      for (var yy = (canvasTop + 21).round(); yy <= (canvasTop + 34).round();
          yy++) {
        for (var xx = x - 2; xx <= x + 1; xx++) {
          if (isAnnot(im, xx, yy)) return true;
        }
      }
      return false;
    }

    // 连续标注法放线 700 / 900 / 1100（链式段第 0 行）。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Continue'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(900, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await tester.pump();

    // 拖动竖线 900 → 1000：关联段端点跟随（700→1000、1000→1100）。
    await tester.dragFrom(
        Offset(900, canvasTop + 40), const Offset(100, 0));
    await tester.pump();
    var im = await shot();
    expect(whiteLineTopAt(im, 1000), isTrue, reason: '竖线拖到 1000');
    expect(whiteLineTopAt(im, 900), isFalse, reason: '原位无残留');
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 990), isTrue,
        reason: '段端点跟随：700→1000');
    expect(arrowSpanAt(im, row0y, row0y + 2, 1010, 1090), isTrue,
        reason: '段端点跟随：1000→1100');

    // 拖动标注段 700→1000（第 0 行）下移 30px → 换到第 1 行；另一段
    // 不受影响。
    await tester.dragFrom(
        Offset(850, row0y.toDouble()), const Offset(0, 30));
    await tester.pump();
    im = await shot();
    expect(arrowSpanAt(im, row1y, row1y + 2, 710, 990), isTrue,
        reason: '标注段整行拖到第 1 行');
    expect(arrowSpanAt(im, row0y, row0y + 2, 1010, 1090), isTrue,
        reason: '另一段仍在第 0 行');
    expect(arrowSpanAt(im, row0y, row0y + 2, 710, 990), isFalse,
        reason: '第 0 行无残留');
  });

  testWidgets('Bus search 对话框（总线选择+值输入+匹配计数+跳转）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();

    // 工具栏 Bus search 按钮打开对话框。
    await tester.tap(find.descendant(
        of: find.byTooltip('Bus search'),
        matching: find.byType(InkWell)));
    await tester.pumpAndSettle();
    expect(find.text('Bus Search'), findsOneWidget, reason: '对话框打开');
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('in_data [23:0]')),
        findsOneWidget,
        reason: '下拉显示总线信号名（含位域）');

    final valueField = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));

    // 无匹配的值：计数 0，「查找」置灰。
    await tester.enterText(valueField, '0x123456');
    await tester.pump();
    expect(find.text('匹配数量：0'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '查找'))
            .onPressed,
        isNull,
        reason: '无匹配时「查找」置灰');

    // 无法解析的输入：提示且「查找」置灰。
    await tester.enterText(valueField, '0xGG');
    await tester.pump();
    expect(find.text('输入无法解析'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '查找'))
            .onPressed,
        isNull,
        reason: '无法解析时「查找」置灰');

    // 匹配值（测试 VCD 的 in_data 在 5000ps 跳为 0x03FF7F）：计数 1；
    // 确认后对话框关闭，匹配信息区显示 Matched 1/1 与信号名+匹配值。
    await tester.enterText(valueField, '03FF7F');
    await tester.pump();
    expect(find.text('匹配数量：1'), findsOneWidget);
    expect(
        tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '查找'))
                .onPressed !=
            null,
        isTrue,
        reason: '有匹配时「查找」可用');
    await tester.tap(find.text('查找'));
    await tester.pumpAndSettle();
    expect(find.text('Bus Search'), findsNothing, reason: '确认后对话框关闭');
    expect(find.textContaining('Matched 1/1', findRichText: true),
        findsOneWidget,
        reason: '匹配数量正常显示');
    expect(find.textContaining('in_data [23:0]  0x03FF7F'), findsOneWidget,
        reason: '匹配信号名与匹配值显示');
  });

  testWidgets('Bus search 短记法 VCD（高位省略的存储也能匹配）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kShortVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.byTooltip('Bus search'),
        matching: find.byType(InkWell)));
    await tester.pumpAndSettle();
    final valueField = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));

    // VCD 以 `b111111111101111111 "`（18 位短串）存储 0x03FF7F：
    // 照显示输入 24 位补全值也能匹配（busBitsEqual 规范化比较）。
    await tester.enterText(valueField, '03FF7F');
    await tester.pump();
    expect(find.text('匹配数量：1'), findsOneWidget,
        reason: '短记法存储与补全输入匹配');

    // `b0 "`（全 0 短记法）：输入 0x000000 匹配。
    await tester.enterText(valueField, '0x000000');
    await tester.pump();
    expect(find.text('匹配数量：1'), findsOneWidget,
        reason: 'b0 短记法与 0x000000 匹配');

    // 确认跳转：匹配信息区正常显示（匹配值按显示口径补全）。
    await tester.enterText(valueField, '03FF7F');
    await tester.pump();
    await tester.tap(find.text('查找'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Matched 1/1', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('in_data [23:0]  0x03FF7F'), findsOneWidget);
  });

  testWidgets('M 光标时间标签（避让布局+右键菜单开关）', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    // M 光标红（0xFFFF1744）判定。
    bool isRed(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 180 && p.g < 90 && p.b < 110;
    }

    // 白色文字判定（徽章内文字）。
    bool isWhite(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 200 && p.g > 200 && p.b > 200;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;

    // 指定 y/x 带内是否有红色像素。
    bool redAt(img.Image im, double y0, double y1, int x0, int x1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var x = x0; x <= x1; x++) {
          if (isRed(im, x, yy)) return true;
        }
      }
      return false;
    }

    // 指定 y/x 带内是否有白色文字像素。
    bool whiteAt(img.Image im, double y0, double y1, int x0, int x1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var x = x0; x <= x1; x++) {
          if (isWhite(im, x, yy)) return true;
        }
      }
      return false;
    }

    // 左键放 M 光标（x=820 → 吸附到 5000ps 沿，光标 x≈822；标签在其
    // 右侧 x≈824 起）。本例 2 行信号（行底 68）——标签避让到 Signal
    // 列表下方（y≈72 起），不在时间尺内（不压刻度数字）。时间格式为
    // `M  000,000,005,000 ps`（长数字串落在 x~870-1120；红底采样取
    // M 与数字间的空隙带，避开白色字形）。
    await tester.tapAt(Offset(820, canvasTop + 200));
    await tester.pump();
    var im = await shot();
    expect(redAt(im, canvasTop + 74, canvasTop + 86, 841, 868), isTrue,
        reason: '默认显示时间标签（Signal 列表下方）');
    expect(whiteAt(im, canvasTop + 74, canvasTop + 86, 950, 1080), isTrue,
        reason: '长格式（000,000,005,000 ps）数字文字');
    expect(redAt(im, canvasTop + 2, canvasTop + 12, 850, 875), isFalse,
        reason: '时间尺内无标签（不压刻度数字）');

    // 避让标注：在与光标同一 x 放一条 Dimension 竖线（其 tn 徽章占据
    // Signal 列表下方第一行）后，M 标签下移到下一空行。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Baseline'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(Offset(820, canvasTop + 200));
    await mouse.up();
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton); // 退出标注模式
    await tester.pump();
    im = await shot();
    expect(redAt(im, canvasTop + 74, canvasTop + 86, 850, 875), isFalse,
        reason: 'tn 徽章占位后 M 标签离开第一行');
    expect(redAt(im, canvasTop + 92, canvasTop + 108, 850, 875), isTrue,
        reason: 'M 标签下移到下一空行（避让 tn 徽章）');

    // 右键菜单「M光标时间标签」：勾选态，点击后关闭时间标签（徽章
    // 收窄为仅 M，仍走避让布局）。
    await tester.tapAt(Offset(820, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('M光标时间标签'), findsOneWidget);
    expect(
        find.descendant(
            of: find.widgetWithText(MenuItemButton, 'M光标时间标签'),
            matching: find.byIcon(Icons.check)),
        findsOneWidget,
        reason: '初始为勾选态');
    await tester.tap(find.text('M光标时间标签'));
    await tester.pumpAndSettle();
    im = await shot();
    expect(redAt(im, canvasTop + 92, canvasTop + 108, 850, 875), isFalse,
        reason: '关闭时间标签后宽徽章消失');
    expect(redAt(im, canvasTop + 92, canvasTop + 108, 818, 835), isTrue,
        reason: '仅 M 的窄徽章仍在（避让位置）');

    // 再开菜单：勾选标记消失；再次点击恢复时间标签。
    await tester.tapAt(Offset(820, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.widgetWithText(MenuItemButton, 'M光标时间标签'),
            matching: find.byIcon(Icons.check)),
        findsNothing,
        reason: '关闭后无勾选');
    await tester.tap(find.text('M光标时间标签'));
    await tester.pumpAndSettle();
    im = await shot();
    expect(redAt(im, canvasTop + 92, canvasTop + 108, 850, 875), isTrue,
        reason: '重新开启时间标签');
  });

  testWidgets('M 光标线避让标注（虚线跳过标注段横线）', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    // M 光标红判定（容差版：1px 虚线落在像素边界上 AA 后仅 ~50%
    // 强度（r≈127），按色调判红排除白色箭头/灰线/绿波形/棕灰分隔线）。
    bool isRed(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 80 && p.r > p.g * 2.5 && p.r > p.b * 1.8;
    }

    bool redAt(img.Image im, double y0, double y1, int x0, int x1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var x = x0; x <= x1; x++) {
          if (isRed(im, x, yy)) return true;
        }
      }
      return false;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;

    // 基线标注法放线 700 / 1100：标注段横线在局部 y=128（命中矩形
    // 124-132），ΔT 标签居中 x≈900（不覆盖光标 x≈820）。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Baseline'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton); // 退出标注模式
    await tester.pump();

    // 放 M 光标（x=820 → 吸附 5000ps，cx≈822，穿过标注段横线）。
    await tester.tapAt(Offset(820, canvasTop + 200));
    await tester.pump();
    final im = await shot();
    // 虚线在标注段横线之上正常绘制（列带 819-823 避开 M 标签徽章
    // 左沿 x≈824）。
    expect(redAt(im, canvasTop + 104, canvasTop + 118, 819, 823), isTrue,
        reason: '横线之上：光标虚线正常');
    // 横线命中矩形（局部 128-132）内的虚线段被跳过。
    expect(redAt(im, canvasTop + 129, canvasTop + 131, 819, 823), isFalse,
        reason: '标注段横线处：光标虚线跳过（避让）');
    // 横线之下虚线恢复（M 标签徽章在 x≥824，不干扰该列带）。
    expect(redAt(im, canvasTop + 144, canvasTop + 151, 819, 823), isTrue,
        reason: '横线之下：光标虚线恢复');
  });

  testWidgets('M 光标标签翻转到光标线左侧时为左侧圆角', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    // M 光标红（0xFFFF1744）判定。
    bool isRed(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 180 && p.g < 90 && p.b < 110;
    }

    bool redAt(img.Image im, double y0, double y1, int x0, int x1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var x = x0; x <= x1; x++) {
          if (isRed(im, x, yy)) return true;
        }
      }
      return false;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;

    // 光标放到近右缘（x=1400 → 光标局部 ~958，无吸附）：长格式标签
    //（~258px）右侧放不下，翻转到光标线左侧（局部 ~698-956，
    // 全局 ~1139-1397，y≈72-86）。
    await tester.tapAt(Offset(1400, canvasTop + 200));
    await tester.pump();
    final im = await shot();
    expect(redAt(im, canvasTop + 74, canvasTop + 84, 1160, 1180), isTrue,
        reason: '标签翻转到光标线左侧');
    // 左侧上下角：左侧圆角——角部 1-2px 被裁（无红）。
    expect(redAt(im, canvasTop + 72, canvasTop + 73, 1139, 1140), isFalse,
        reason: '翻转到左侧：左上角为圆角（被裁）');
    expect(redAt(im, canvasTop + 85, canvasTop + 86, 1139, 1140), isFalse,
        reason: '翻转到左侧：左下角为圆角（被裁）');
    // 右下角：直角——红底到角（右上角被 's' 字形覆盖不采样）。
    expect(redAt(im, canvasTop + 85, canvasTop + 86, 1395, 1397), isTrue,
        reason: '翻转到左侧：右下角为直角');
  });

  testWidgets('Dimension 标注段时间标注锚定可见区中心（放大中点出屏仍可见）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    // 标注像素判定（白色文字/箭头或灰竖线，含抗锯齿混合）。
    bool isAnnot(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
      final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
      if (hi - lo >= 40) return false;
      return lo > 120 || (lo > 33 && hi < 120);
    }

    bool whiteAt(img.Image im, double y0, double y1, int x0, int x1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var x = x0; x <= x1; x++) {
          if (isAnnot(im, x, yy)) return true;
        }
      }
      return false;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;

    // 基线标注法放线 700 / 1100（段自然中点 x=900，标签居中其上）。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Baseline'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton); // 退出标注模式
    await tester.pump();

    // Ctrl+滚轮在局部 x=300 处放大（~7.4 倍）：线段拉长，自然中点
    //（局部 ~1477）移出屏幕右侧；可见区 = [0, 视口宽]，时间标注应
    // 显示在可见区中心（局部 ~562，全局 ~1003，标签矩形 ~969-1037）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(PointerScrollEvent(
      position: Offset(741, canvasTop + 300),
      scrollDelta: const Offset(0, -1000),
    ));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final im = await shot();
    // 标注段横线仍贯穿可见区（局部 y=128）。
    expect(whiteAt(im, canvasTop + 126, canvasTop + 130, 700, 900), isTrue,
        reason: '放大后横线仍在');
    // 时间标注显示在可见区中心附近（标签行局部 y≈110-124）。
    expect(whiteAt(im, canvasTop + 110, canvasTop + 124, 969, 1037), isTrue,
        reason: '中点出屏后时间标注锚定可见区中心');
    // 可见区左四分之一处无标签（未滞留在自然中点/随意位置）。
    expect(whiteAt(im, canvasTop + 110, canvasTop + 124, 700, 850), isFalse,
        reason: '标签未偏离可见区中心');
  });

  testWidgets('Dimension 标注段完全屏外时时间标注不显示（不吸到屏幕边缘）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    // 标注像素判定（白色文字/箭头或灰竖线，含抗锯齿混合）。
    bool isAnnot(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      final lo = math.min(p.r, math.min(p.g, p.b)).toInt();
      final hi = math.max(p.r, math.max(p.g, p.b)).toInt();
      if (hi - lo >= 40) return false;
      return lo > 120 || (lo > 33 && hi < 120);
    }

    bool whiteAt(img.Image im, double y0, double y1, int x0, int x1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var x = x0; x <= x1; x++) {
          if (isAnnot(im, x, yy)) return true;
        }
      }
      return false;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;

    // 基线标注法放线 700 / 1100。
    await tester.tap(find.descendant(
        of: find.byTooltip('Dimension Baseline'),
        matching: find.byType(InkWell)));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.down(Offset(700, canvasTop + 200));
    await mouse.up();
    await mouse.down(Offset(1100, canvasTop + 200));
    await mouse.up();
    await tester.tapAt(Offset(1400, canvasTop + 300),
        buttons: kSecondaryButton); // 退出标注模式
    await tester.pump();

    // 先 Ctrl+滚轮放大（允许平移），再大幅右滚：线段整体移出屏幕
    // 左侧。时间标注应保持屏外不显示（此前会被钳位吸到屏幕左缘，
    // 错位叠到可见区内容上）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(PointerScrollEvent(
      position: Offset(741, canvasTop + 300),
      scrollDelta: const Offset(0, -1000),
    ));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendEventToBinding(PointerScrollEvent(
      position: Offset(800, canvasTop + 300),
      scrollDelta: const Offset(0, 4000),
    ));
    await tester.pump();
    final im = await shot();
    // 标签行（局部 y≈110-124）整行无时间标注：既不吸到左缘，也不
    // 显示在任何可见位置。
    expect(whiteAt(im, canvasTop + 110, canvasTop + 124, 442, 520), isFalse,
        reason: '屏外线段的标注不吸到屏幕左缘');
    expect(whiteAt(im, canvasTop + 110, canvasTop + 124, 442, 1590), isFalse,
        reason: '线段完全屏外：时间标注不显示');
  });

  testWidgets('右键菜单「隐藏M光标」（隐藏/显示/重新放置恢复）',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('root'),
      child: const MaterialApp(home: Scaffold(body: SimWaveTab())),
    ));
    await tester.pumpAndSettle();

    Future<img.Image> shot() async {
      late img.Image out;
      await tester.runAsync(() async {
        final b = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('root')));
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        out = img.decodePng(bd!.buffer.asUint8List())!;
      });
      return out;
    }

    // M 光标红判定（容差版：1px 虚线 AA 半强度）。
    bool isRed(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 80 && p.r > p.g * 2.5 && p.r > p.b * 1.8;
    }

    bool redAt(img.Image im, double y0, double y1, int x0, int x1) {
      for (var yy = y0.round(); yy <= y1.round(); yy++) {
        for (var x = x0; x <= x1; x++) {
          if (isRed(im, x, yy)) return true;
        }
      }
      return false;
    }

    Offset? clkPos;
    for (final e in find.text('clk').evaluate()) {
      final box = e.renderObject! as RenderBox;
      final pos = box.localToGlobal(box.size.center(Offset.zero));
      if (pos.dx > 200 && pos.dx < 360) clkPos = pos;
    }
    final canvasTop = clkPos!.dy - 32;

    // 全局图左下角的 Mcursor.time 文本（ps 时间值行）。
    Finder mTime() => find.textContaining('ps', findRichText: true);

    // 放 M 光标（x=820 → 吸附 5000ps，cx≈820-822）。
    await tester.tapAt(Offset(820, canvasTop + 200));
    await tester.pump();
    var im = await shot();
    expect(redAt(im, canvasTop + 60, canvasTop + 200, 818, 823), isTrue,
        reason: '光标线可见');
    expect(mTime(), findsOneWidget, reason: '全局图时间显示');

    // 右键菜单「隐藏M光标」：光标线与全局图时间隐藏（位置保留）。
    await tester.tapAt(Offset(900, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('隐藏M光标'), findsOneWidget);
    await tester.tap(find.text('隐藏M光标'));
    await tester.pumpAndSettle();
    im = await shot();
    expect(redAt(im, canvasTop + 60, canvasTop + 200, 818, 823), isFalse,
        reason: '隐藏后光标线不可见');
    expect(mTime(), findsNothing, reason: '隐藏后全局图时间隐藏');

    // 再开菜单 →「显示M光标」：恢复原位置显示。
    await tester.tapAt(Offset(900, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('显示M光标'), findsOneWidget);
    await tester.tap(find.text('显示M光标'));
    await tester.pumpAndSettle();
    im = await shot();
    expect(redAt(im, canvasTop + 60, canvasTop + 200, 818, 823), isTrue,
        reason: '显示后光标线恢复（原位置）');

    // 再次隐藏后左键重新放置：自动恢复显示。
    await tester.tapAt(Offset(900, canvasTop + 300),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐藏M光标'));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(1000, canvasTop + 200));
    await tester.pump();
    im = await shot();
    expect(redAt(im, canvasTop + 60, canvasTop + 200, 998, 1003), isTrue,
        reason: '重新放置光标自动恢复显示');
  });

  testWidgets('Signal 面板右键菜单删除当前信号', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SimWaveStore.instance.registerWave(utf8.encode(_kTestVcd));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SimWaveTab()),
    ));
    await tester.pumpAndSettle();

    // 信号名面板内 name 文本的全局中心（x 限定在 Signal 列表区）。
    Offset? namesPos(String name) {
      Offset? pos;
      for (final e in find.text(name).evaluate()) {
        final box = e.renderObject! as RenderBox;
        final p = box.localToGlobal(box.size.center(Offset.zero));
        if (p.dx > 200 && p.dx < 360) pos = p;
      }
      return pos;
    }

    // 全部信号已显示时：空白处（无信号行区域）右键仅有置灰提示项。
    await tester.tapAt(const Offset(280, 700), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('可添加信号'), findsOneWidget, reason: '菜单标题');
    expect(find.text('（没有可加入的信号）'), findsOneWidget);
    await tester.tapAt(const Offset(280, 700)); // 关菜单
    await tester.pumpAndSettle();

    // 删除标量信号 clk：右键 clk 行 → 菜单含「删除当前信号」。
    final clkPos = namesPos('clk');
    expect(clkPos, isNotNull);
    await tester.tapAt(clkPos!, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('删除当前信号'), findsOneWidget);
    await tester.tap(find.text('删除当前信号'));
    await tester.pumpAndSettle();
    expect(namesPos('clk'), isNull, reason: 'clk 已从 Signal 列表删除');
    expect(namesPos('in_data [23:0]'), isNotNull, reason: '其余信号保留');

    // 空白处右键：菜单列出未显示的 clk，点选加回（总线仍在显示，
    // 不在候选中）。
    await tester.tapAt(const Offset(280, 700), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('可添加信号'), findsOneWidget, reason: '菜单标题');
    expect(find.widgetWithText(MenuItemButton, 'clk'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'in_data [23:0]'),
        findsNothing);
    await tester.tap(find.widgetWithText(MenuItemButton, 'clk'));
    await tester.pumpAndSettle();
    expect(namesPos('clk'), isNotNull, reason: '空白处菜单加回 clk');

    // 删除总线 in_data（先展开——展开位行应随宿主一并删除）。
    final busPos = namesPos('in_data [23:0]')!;
    await tester.tapAt(busPos); // 行上左键（选中，不影响菜单）
    await tester.pump();
    final expandPos = find
        .byIcon(Icons.chevron_right)
        .evaluate()
        .map((e) =>
            (e.renderObject! as RenderBox)
                .localToGlobal((e.renderObject! as RenderBox)
                    .size
                    .center(Offset.zero)))
        .where((p) => p.dx > 200 && p.dx < 360)
        .firstOrNull;
    expect(expandPos, isNotNull);
    await tester.tapAt(expandPos!);
    await tester.pump();
    expect(namesPos('in_data [5]'), isNotNull, reason: '总线已展开位行');
    await tester.tapAt(namesPos('in_data [23:0]')!,
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除当前信号'));
    await tester.pumpAndSettle();
    expect(namesPos('in_data [23:0]'), isNull, reason: '总线已删除');
    expect(namesPos('in_data [5]'), isNull, reason: '展开位行随宿主删除');

    // 再删 clk（此前已由空白处菜单加回）：Signal 列表清空。
    await tester.tapAt(namesPos('clk')!, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除当前信号'));
    await tester.pumpAndSettle();
    // 测试 VCD 仅 clk/in_data 两个信号：全部删除后 Signal 列表为空。
    expect(namesPos('clk'), isNull, reason: 'Signal 列表已空');

    // 空列表的空白处右键：菜单列出两个候选，逐一点选加回。
    await tester.tapAt(const Offset(280, 700), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'clk'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'in_data [23:0]'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(MenuItemButton, 'in_data [23:0]'));
    await tester.pumpAndSettle();
    expect(namesPos('in_data [23:0]'), isNotNull, reason: '空列表菜单加回总线');
    await tester.tapAt(const Offset(280, 700), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'clk'));
    await tester.pumpAndSettle();
    expect(namesPos('clk'), isNotNull, reason: '空列表菜单加回 clk');
  });
}
