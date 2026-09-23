import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/widgets/code_browser.dart';

void main() {
  const hl = kIdentHighlightStyle;

  TextSpan sp(String text, [TextStyle? style]) =>
      TextSpan(text: text, style: style);

  /// 段带黄底黑字高亮样式。
  bool isHl(TextSpan s) =>
      s.style?.backgroundColor == const Color(0xFFFFF176) &&
      s.style?.color == Colors.black;

  group('applyIdentHighlight', () {
    test('单行多 span：跨段区间切成 前/中/后，中段叠加高亮', () {
      final spans = [
        sp('ab', const TextStyle(color: Colors.red)),
        sp('cd', const TextStyle(color: Colors.green)),
        sp('ef', const TextStyle(color: Colors.blue)),
      ];
      final out = applyIdentHighlight(spans, 0, 1, 5, hl);
      expect(out.map((s) => s.text), ['a', 'b', 'cd', 'e', 'f']);
      expect(isHl(out[0]), isFalse);
      expect(out[0].style?.color, Colors.red);
      expect(isHl(out[1]), isTrue);
      // merge：高亮只覆盖背景色/文字色，原样式其余属性保留。
      expect(out[1].style?.color, Colors.black);
      expect(isHl(out[2]), isTrue);
      expect(isHl(out[3]), isTrue);
      expect(isHl(out[4]), isFalse);
      expect(out[4].style?.color, Colors.blue);
    });

    test('区间恰好落在 span 边界：不产生空段', () {
      final spans = [
        sp('int ', const TextStyle(color: Colors.red)),
        sp('foo', const TextStyle(color: Colors.green)),
        sp('(void) {', const TextStyle(color: Colors.blue)),
      ];
      final out = applyIdentHighlight(spans, 0, 4, 7, hl);
      expect(out.map((s) => s.text), ['int ', 'foo', '(void) {']);
      expect(isHl(out[0]), isFalse);
      expect(isHl(out[1]), isTrue);
      expect(isHl(out[2]), isFalse);
    });

    test('非目标行不动（同一对象原样保留）', () {
      final spans = [
        sp('abc'),
        sp('\n'),
        sp('def'),
      ];
      final out = applyIdentHighlight(spans, 0, 0, 2, hl);
      expect(out.map((s) => s.text), ['ab', 'c', '\n', 'def']);
      expect(identical(out[2], spans[1]), isTrue);
      expect(identical(out[3], spans[2]), isTrue);
      expect(isHl(out[0]), isTrue);
      expect(isHl(out[1]), isFalse);
    });

    test('目标段含换行符：只拆行内部分，换行留在尾段', () {
      final spans = [sp('abcd\n'), sp('xy')];
      final out = applyIdentHighlight(spans, 0, 1, 3, hl);
      expect(out.map((s) => s.text), ['a', 'bc', 'd\n', 'xy']);
      expect(isHl(out[1]), isTrue);
      expect(isHl(out[2]), isFalse);
      expect(identical(out[3], spans[1]), isTrue);
    });

    test('无样式 span：高亮样式直接生效', () {
      final out = applyIdentHighlight([sp('hello')], 0, 0, 5, hl);
      expect(out, hasLength(1));
      expect(isHl(out[0]), isTrue);
    });
  });

  group('findIdentRangeInLine', () {
    test('函数定义行取名字本身的整词区间', () {
      final spans = [sp('/* wb.c */\n'), sp('int isp_wb_run(void) {\n')];
      expect(findIdentRangeInLine(spans, 1, 'isp_wb_run'), (4, 14));
    });

    test('#define 行取宏名区间', () {
      final spans = [sp('/* common h */\n'), sp('#define ISP_OK 0\n')];
      expect(findIdentRangeInLine(spans, 1, 'ISP_OK'), (8, 14));
    });

    test('整词匹配：跳过前缀/后缀更长的同名片段', () {
      final spans = [sp('int ISP_OK2 = ISP_OK;')];
      expect(findIdentRangeInLine(spans, 0, 'ISP_OK'), (14, 20));
    });

    test('行号越界 / 行内无整词出现返回 null', () {
      final spans = [sp('int foo;\n')];
      expect(findIdentRangeInLine(spans, 5, 'foo'), isNull);
      expect(findIdentRangeInLine(spans, 0, 'bar'), isNull);
    });
  });

  group('CodeArea 行号与代码行对齐（strut 固定行高）', () {
    testWidgets('含 CJK 注释行时 gutter 行号与代码区各行垂直位置一致', (
      tester,
    ) async {
      // 多行代码，中间夹中文注释行：CJK 走回退字体，ascent/descent 度量
      // 大于 Consolas。gutter 是单个 Text（行号 '\n' 连接），与代码区
      // 同样式同 strut、同一布局引擎逐行算行高，两边首字符框应逐行重合。
      const lines = [
        'int a = 1;',
        'int b = 2;',
        '// 中文注释：白平衡增益调整',
        'int c = 3;',
        '// 又一行中文注释',
        'int d = 4;',
        'int e = 5;',
      ];
      final spans = [sp(lines.join('\n'))];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: CodeArea(spans: spans),
            ),
          ),
        ),
      );
      // gutter：单个 Text（'1\n2\n…'），行号色 0xFF858585。
      final gutterFinder = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data?.startsWith('1\n2\n') ?? false) &&
            w.style?.color == const Color(0xFF858585),
      );
      // 结构断言：gutter 为单段落 Text，与代码区共用同一 strut
      //（同一布局引擎逐行算行高，行号与代码行不存在两套度量）。
      final gutterText = tester.widget<Text>(gutterFinder);
      expect(gutterText.data, [for (var i = 1; i <= 7; i++) '$i'].join('\n'));
      expect(gutterText.strutStyle, kCodeBrowserStrut);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).strutStyle,
        kCodeBrowserStrut,
      );
      // 从元素树手动取渲染对象（SelectableText → EditableText 间还有
      // 组合回调层，直接 renderObject<T> cast 会失败）。
      T? findRo<T extends RenderObject>(Finder finder) {
        T? found;
        void visit(Element e) {
          final ro = e.renderObject;
          if (ro is T && found == null) found = ro;
          e.visitChildren(visit);
        }

        tester.element(finder).visitChildren(visit);
        return found;
      }

      final g = findRo<RenderParagraph>(gutterFinder);
      final c = findRo<RenderEditable>(find.byType(SelectableText));
      expect(g, isNotNull, reason: '未找到 gutter 的 RenderParagraph');
      expect(c, isNotNull, reason: '未找到代码区的 RenderEditable');
      // 对齐不变量：同一起点（Row 顶对齐）+ 相同的总高度（同样的固定行高
      // × 行数）。有 CJK 行撑高代码侧行高时总高度会超出 gutter，此断言变红。
      expect(
        tester.getTopLeft(gutterFinder).dy,
        tester.getTopLeft(find.byType(SelectableText)).dy,
      );
      expect(
        (g!.size.height - c!.size.height).abs(),
        lessThanOrEqualTo(0.01),
        reason: 'gutter 高=${g.size.height}，代码区高=${c.size.height}',
      );
    });
  });
}
