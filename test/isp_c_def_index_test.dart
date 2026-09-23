import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/c_def_index.dart';

void main() {
  group('indexCDefs', () {
    test('简单定义命中、行号为 1 起始', () {
      final index = indexCDefs({
        'a.c': '/* head */\nint foo(void) {\n  return 0;\n}\n',
      });
      expect(index['foo'], [(file: 'a.c', line: 2)]);
    });

    test('函数原型（; 结尾）不索引', () {
      final index = indexCDefs({
        'a.h': 'int foo(void);\n',
        'a.c': 'int foo(void) {\n  return 0;\n}\n',
      });
      expect(index['foo'], [(file: 'a.c', line: 1)]);
    });

    test('多行签名命中（定义起始行为名字所在行）', () {
      final index = indexCDefs({
        'a.c': 'static int bar(int a,\n    int b)\n{\n  return a + b;\n}\n',
      });
      expect(index['bar'], [(file: 'a.c', line: 1)]);
    });

    test('块注释与行注释里的假定义不索引', () {
      final index = indexCDefs({
        'a.c':
            '/* int fake1(void) { */\n// int fake2(void) {\n/*\nint fake3(void) {\n*/\nint real(void) {\n  return 0;\n}\n',
      });
      expect(index.containsKey('fake1'), isFalse);
      expect(index.containsKey('fake2'), isFalse);
      expect(index.containsKey('fake3'), isFalse);
      expect(index['real'], [(file: 'a.c', line: 6)]);
    });

    test('对象式宏收录且行号正确', () {
      final index = indexCDefs({
        'a.h': '/* head */\n#define ISP_OK 0\n#define ISP_ERR -1\n',
      });
      expect(index['ISP_OK'], [(file: 'a.h', line: 2)]);
      expect(index['ISP_ERR'], [(file: 'a.h', line: 3)]);
    });

    test('函数式宏收录（与对象式同名处理）', () {
      final index = indexCDefs({
        'a.h': '#define ISP_MAX(a, b) ((a) > (b) ? (a) : (b))\n',
      });
      expect(index['ISP_MAX'], [(file: 'a.h', line: 1)]);
    });

    test('多行续行宏只记首行', () {
      final index = indexCDefs({
        'a.h':
            '#define WRAP(x) \\\n  do { \\\n    g(x); \\\n  } while (0)\nint foo(void) {\n  return 0;\n}\n',
      });
      expect(index['WRAP'], [(file: 'a.h', line: 1)]);
      // 续行里的 g/do/while 不产生定义。
      expect(index.containsKey('g'), isFalse);
      expect(index['foo'], [(file: 'a.h', line: 5)]);
    });

    test('其它预处理指令不索引（#include/#ifndef/#if/#pragma）', () {
      final index = indexCDefs({
        'a.h':
            '#ifndef A_H\n#define A_H\n#include <stdint.h>\n#if defined(X)\n#pragma once\n#endif\n',
      });
      expect(index.containsKey('ifndef'), isFalse);
      expect(index.containsKey('include'), isFalse);
      expect(index.containsKey('if'), isFalse);
      expect(index.containsKey('pragma'), isFalse);
      // 头文件守卫的 #define 收录（无害且可跳）。
      expect(index['A_H'], [(file: 'a.h', line: 2)]);
    });

    test('注释块里的 #define 不索引', () {
      final index = indexCDefs({
        'a.c':
            '/* #define FAKE1 1 */\n// #define FAKE2 2\n/*\n#define FAKE3 3\n*/\n#define REAL 4\n',
      });
      expect(index.containsKey('FAKE1'), isFalse);
      expect(index.containsKey('FAKE2'), isFalse);
      expect(index.containsKey('FAKE3'), isFalse);
      expect(index['REAL'], [(file: 'a.c', line: 6)]);
    });

    test('缩进的 #define 不索引（第 0 列规则与函数一致）', () {
      final index = indexCDefs({
        'a.c': 'int foo(void) {\n  #define LOCAL 1\n\t#define LOCAL2 2\n  return 0;\n}\n',
      });
      expect(index.containsKey('LOCAL'), isFalse);
      expect(index.containsKey('LOCAL2'), isFalse);
      expect(index['foo'], [(file: 'a.c', line: 1)]);
    });

    test('宏与函数混合索引互不影响', () {
      final index = indexCDefs({
        'a.h': '#define ISP_OK 0\nint isp_check(void);\n',
        'a.c': '#include "a.h"\nint isp_check(void) {\n  return ISP_OK;\n}\n',
      });
      expect(index['ISP_OK'], [(file: 'a.h', line: 1)]);
      expect(index['isp_check'], [(file: 'a.c', line: 2)]);
    });

    test('第 0 列的 if (x) { 不索引', () {
      final index = indexCDefs({
        'a.c': '#define WRAP(x) \\\nif (x) {\n  g();\n}\n',
      });
      // 续行宏体第 0 列的 if 形态不误判为函数定义；WRAP 本身作为宏收录。
      expect(index['WRAP'], [(file: 'a.c', line: 1)]);
      expect(index.length, 1);
    });

    test('数组初始化 = { 不索引', () {
      final index = indexCDefs({
        // 第 0 列顶层数组初始化，元素含括号形态；= 中止判定。
        'a.c': 'int arr[] = {\n  (1),\n  (2),\n};\n',
      });
      expect(index, isEmpty);
    });

    test('缩进行的函数调用不索引（函数体内调用点）', () {
      final index = indexCDefs({
        'a.c': 'int callee(void) {\n  return 1;\n}\nint caller(void) {\n  return callee();\n}\n',
      });
      expect(index['callee'], [(file: 'a.c', line: 1)]);
      expect(index['caller'], [(file: 'a.c', line: 4)]);
    });

    test('跨文件同名 static helper 记录两处', () {
      final index = indexCDefs({
        'a.c': 'static int clamp(int v) {\n  return v;\n}\n',
        'b.c': 'static int clamp(int v) {\n  return v > 0 ? v : 0;\n}\n',
      });
      expect(index['clamp'], [
        (file: 'a.c', line: 1),
        (file: 'b.c', line: 1),
      ]);
    });

    test('CRLF 输入行号正确', () {
      final index = indexCDefs({
        'a.c': '/* head */\r\n#define CRLF_OK 0\r\nint foo(void) {\r\n  return 0;\r\n}\r\n',
      });
      expect(index['CRLF_OK'], [(file: 'a.c', line: 2)]);
      expect(index['foo'], [(file: 'a.c', line: 3)]);
    });

    test('签名中途遇 = 中止（函数指针变量）', () {
      final index = indexCDefs({
        'a.c': 'int (*fp)(int) = 0;\nint foo(void) {\n  return 0;\n}\n',
      });
      expect(index.containsKey('fp'), isFalse);
      expect(index['foo'], [(file: 'a.c', line: 2)]);
    });
  });
}
