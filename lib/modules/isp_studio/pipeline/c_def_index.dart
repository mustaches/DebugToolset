/// ISP Studio 编组代码页「Go to REF」用的 C 定义索引器（纯 Dart，无
/// Flutter 依赖）。
///
/// 对一组 C 源文件（文件名 → 内容）做启发式扫描，建立 函数名/宏名 → 定义
/// 位置（文件 + 1 起始行号）的索引，供代码区悬停跳转。同名函数/宏可能有
/// 多个定义（如各 .c 里的同名 static helper），全部记录，由调用方择优。
///
/// 启发式规则（面向本项目的 C 代码风格，非完整解析）：
/// - 先剥离 `//` 与 `/* */` 注释：注释内容替换为等长空白、保留换行，
///   保证行号不变；字符串字面量不剥离（串里的 `//` 会被误当注释剥掉，
///   但串只影响本行余下部分，顶层声明行一般不含带 `//` 的串，风险可接受）。
/// - 预处理行：只收录第 0 列顶格的 `#define NAME`（对象式 `#define X 0`
///   与函数式 `#define MAX(a, b) ...` 均收录，宏名 → `#define` 所在行号；
///   多行 `\` 续行宏只记首行）；`#include`/`#ifndef`/`#pragma`/`#if` 等
///   其它预处理指令不收录。
/// - 其余行逐行扫描：空行、`#` 开头的其它预处理行跳过；**行首为空格/tab
///   的行跳过**——本项目顶层声明从第 0 列开始，函数体内的调用都是缩进的，
///   此规则天然排除调用点误判（代价是缩进的 `#define`、缩进在函数体内的
///   局部函数定义之类罕见形态不支持，生成物里 define 都是顶格写的）。
/// - 在行内找第一个 `标识符(`；标识符是 C 关键字（if/for/while/switch/
///   return/sizeof 等）则跳过（排除第 0 列 `if (x) {` 之类宏/顶层误形态）。
/// - 从匹配结束处继续扫描（跨行，上限 30 行）：跟踪圆括号深度（起评 1），
///   深度归 0 后找下一个非空白字符——是 `{` 判为函数定义；途中遇 `;`
///   或 `=` 中止（函数原型声明、函数指针变量初始化如 `= {` 数组初始化）。
///
/// 局限：`#if` 条件编译遮蔽的定义可能漏收；宏展开生成的函数名收不到。
/// 对代码浏览跳转场景够用。
library;

/// 定义位置：所在文件 + 1 起始的定义起始行号。
typedef CDefLocation = ({String file, int line});

/// 扫描 [files]（文件名 → 内容），建立 函数名/宏名 → 全部定义位置 的索引。
Map<String, List<CDefLocation>> indexCDefs(Map<String, String> files) {
  final index = <String, List<CDefLocation>>{};
  for (final entry in files.entries) {
    final lines = _stripComments(entry.value.replaceAll('\r\n', '\n'))
        .split('\n');
    _scanFile(entry.key, lines, index);
  }
  return index;
}

/// C 关键字：出现在 `标识符(` 形态时跳过（宏调用/控制语句而非函数定义）。
const _cKeywords = {
  'if', 'for', 'while', 'switch', 'return', 'sizeof', 'do', 'else',
  'case', 'typedef', 'struct', 'enum', 'union', 'goto',
};

final _identParenRe = RegExp(r'([A-Za-z_]\w*)\s*\(');

/// 顶格 `#define` 宏：`#define` 后须空白，宏名为合法 C 标识符（对象式与
/// 函数式宏同名处理，函数式的形参括号不参与匹配）。
final _macroDefineRe = RegExp(r'#define[ \t]+([A-Za-z_]\w*)');

/// 单文件扫描：顶格 `#define` 直接收录宏；其余第 0 列的 `name(...)` 候选
/// + 括号配对，深度归 0 后紧跟 `{` 判为定义。
void _scanFile(String file, List<String> lines,
    Map<String, List<CDefLocation>> index) {
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty || line.startsWith(' ') || line.startsWith('\t')) {
      continue;
    }
    if (line.startsWith('#')) {
      // 预处理行只收录 #define 宏（多行续行宏只记首行；续行不以 #define
      // 开头，天然不会再命中）。
      final m = _macroDefineRe.firstMatch(line);
      if (m != null) {
        (index[m.group(1)!] ??= []).add((file: file, line: i + 1));
      }
      continue;
    }
    final m = _identParenRe.firstMatch(line);
    if (m == null) continue;
    final name = m.group(1)!;
    if (_cKeywords.contains(name)) continue;
    // 从匹配结束处跨行扫描：起评深度 1（`(` 已开），深度归 0 后找下一
    // 个非空白字符；途中遇 `;`/`=` 中止（原型/函数指针变量）。
    var depth = 1;
    var isDef = false;
    outer:
    for (var j = i; j < lines.length && j < i + 30; j++) {
      final l = lines[j];
      var k = (j == i) ? m.end : 0;
      for (; k < l.length; k++) {
        final ch = l[k];
        if (depth > 0) {
          if (ch == ';' || ch == '=') break outer;
          if (ch == '(') {
            depth++;
          } else if (ch == ')') {
            depth--;
          }
        } else {
          if (ch == ' ' || ch == '\t') continue;
          if (ch == '{') isDef = true;
          break outer;
        }
      }
    }
    if (isDef) {
      (index[name] ??= []).add((file: file, line: i + 1));
    }
  }
}

/// 剥离 `//` 与 `/* */` 注释：注释内容替换为等长空白，换行原样保留
/// （行号不变）。字符串字面量不处理（见文件头注释的风险说明）。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inBlock = false; // 是否在 /* */ 块注释内（跨行状态）
  while (i < src.length) {
    if (inBlock) {
      if (src[i] == '*' && i + 1 < src.length && src[i + 1] == '/') {
        out.write('  ');
        i += 2;
        inBlock = false;
      } else {
        out.write(src[i] == '\n' ? '\n' : ' ');
        i++;
      }
    } else if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '/') {
      // 行注释：到行尾（不含换行）替换为空白。
      while (i < src.length && src[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '*') {
      out.write('  ');
      i += 2;
      inBlock = true;
    } else {
      out.write(src[i]);
      i++;
    }
  }
  return out.toString();
}
