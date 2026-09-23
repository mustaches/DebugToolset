/// ISP Studio「查看代码」的源码符号提取器（纯 Dart，无 Flutter 依赖）。
///
/// 本项目代码经 dart format 格式化：顶层声明从第 0 列开始，其函数/类
/// 体的结束 `}` 单独成行且也在第 0 列。利用这一点做行扫描即可对本
/// 项目代码可靠定位符号，无需完整解析。
library;

/// 从 [source] 提取名为 [name] 的顶层声明（含其前紧邻的连续 `///`
/// 文档注释行）。支持函数（含多行签名、表达式体）、类、枚举、变量
/// （含多行 const 列表）。找不到返回 null。
String? extractSymbol(String source, String name) {
  final lines = _splitLines(source);
  final start = _findDeclStart(lines, name);
  if (start < 0) return null;
  final span = _declSpan(lines, start);
  if (span == null) return null;
  var docStart = start;
  while (docStart > 0 && lines[docStart - 1].startsWith('///')) {
    docStart--;
  }
  return lines.sublist(docStart, span.end + 1).join('\n');
}

/// 扫描 [source] 的全部顶层声明，建立 符号名 → 完整声明文本（含前导
/// `///` 文档注释）的索引。覆盖顶层函数（含私有 `_xxx`）、类、枚举、
/// typedef 与顶层常量/变量；类/枚举体内的成员不入索引。
Map<String, String> indexDeclarations(String source) {
  final lines = _splitLines(source);
  final index = <String, String>{};
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.isEmpty ||
        line.startsWith(' ') ||
        line.startsWith('\t') ||
        line.startsWith('//') ||
        line.startsWith('import ') ||
        line.startsWith('export ') ||
        line.startsWith('library ')) {
      i++;
      continue;
    }
    final span = _declSpan(lines, i);
    if (span == null) {
      i++;
      continue;
    }
    final name = _declName(span.signature);
    if (name != null) {
      var docStart = i;
      while (docStart > 0 && lines[docStart - 1].startsWith('///')) {
        docStart--;
      }
      index[name] = lines.sublist(docStart, span.end + 1).join('\n');
    }
    i = span.end + 1;
  }
  return index;
}

/// 从代码文本中扫描标识符（先剥离字符串字面量与注释），按出现顺序
/// 返回去重后的序列。调用方自行与声明索引比对筛选内部引用。
List<String> scanIdentifiers(String code) {
  final str = _StringScanState();
  final seen = <String>{};
  final result = <String>[];
  final re = RegExp(r'[A-Za-z_]\w*');
  for (final raw in _splitLines(code)) {
    final line = _stripStringsAndComments(raw, str);
    for (final m in re.allMatches(line)) {
      final id = m.group(0)!;
      if (seen.add(id)) result.add(id);
    }
  }
  return result;
}

/// 从 [source] 提取 switch 中 `case '<label>':` 分支。紧随其后的空
/// 贯穿标签（`case 'x':` 独占一行、无语句）视为同一组一并捕获；捕获
/// 到下一个带语句的 case/default 标签或 switch 结束 `}` 之前（不含）。
/// 找不到返回 null。
String? extractSwitchCase(String source, String label) {
  final lines = _splitLines(source);
  final startRe =
      RegExp('^(\\s*)case\\s+\'${RegExp.escape(label)}\'\\s*:(.*)\$');
  var start = -1;
  var indent = 0;
  var hasBody = false;
  for (var i = 0; i < lines.length; i++) {
    final m = startRe.firstMatch(lines[i]);
    if (m == null) continue;
    start = i;
    indent = m.group(1)!.length;
    hasBody = m.group(2)!.trim().isNotEmpty;
    break;
  }
  if (start < 0) return null;
  final bareLabel = RegExp('^\\s*(case\\s+.*|default)\\s*:\\s*\$');
  final out = <String>[lines[start]];
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      out.add(line);
      continue;
    }
    final cur = line.length - line.trimLeft().length;
    if (cur <= indent) {
      if (line.trim() == '}') break; // switch 结束
      // 空贯穿标签属于本组；带语句的标签是下一组的开始。
      if (!hasBody && bareLabel.hasMatch(line)) {
        out.add(line);
        continue;
      }
      break;
    }
    out.add(line);
    hasBody = true;
  }
  while (out.length > 1 && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

/// 统一换行符后按行拆分（容忍 CRLF 检出的工作区）。
List<String> _splitLines(String source) =>
    source.replaceAll('\r\n', '\n').split('\n');

/// 声明起始行：第 0 列、非注释、非 import/export/library、包含符号名
/// （词边界），且名字的首次出现不在 `=>` 之后（排除
/// `xxxInIsolate(...) => xxx(...)` 这类包装声明里的调用）。
int _findDeclStart(List<String> lines, String name) {
  final re =
      RegExp('(^|[^A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty || line.startsWith(' ') || line.startsWith('\t')) {
      continue;
    }
    if (line.startsWith('//')) continue;
    if (line.startsWith('import ') ||
        line.startsWith('export ') ||
        line.startsWith('library ')) {
      continue;
    }
    final m = re.firstMatch(line);
    if (m == null) continue;
    if (line.substring(0, m.start).contains('=>')) continue;
    return i;
  }
  return -1;
}

/// 声明边界：结束行 [end]（含）与签名文本 [signature]（剥离字符串/
/// 注释，不含函数体与模式标记，供声明名解析）。
({int end, String signature})? _declSpan(List<String> lines, int start) {
  final str = _StringScanState();
  final sig = StringBuffer();
  var depth = 0; // ( [ { 合计深度
  var expr = false; // 已进入表达式模式（`=>` 或深度 0 处的 `=`）
  for (var i = start; i < lines.length; i++) {
    final line = _stripStringsAndComments(lines[i], str);
    for (var k = 0; k < line.length; k++) {
      final c = line[k];
      if (!expr) {
        if (c == '(' || c == '[') {
          depth++;
        } else if (c == ')' || c == ']') {
          depth--;
        } else if (c == '{') {
          if (depth == 0) {
            // 函数/类/枚举体；同一行内闭合（`void f() {}`）则当场结束。
            final end = line.substring(k + 1).contains('}')
                ? i
                : _findBraceEnd(lines, i);
            if (end < 0) return null;
            return (end: end, signature: sig.toString());
          }
          depth++;
        } else if (c == '}') {
          depth--;
        } else if (c == ';') {
          if (depth == 0) return (end: i, signature: sig.toString());
        } else if (c == '=' && depth == 0) {
          if (k + 1 < line.length && line[k + 1] == '=') {
            sig.write('==');
            k++; // `==` 不是初始化（防御，声明中不会出现）
            continue;
          }
          expr = true; // `=` 与 `=>` 都进入表达式模式，模式标记不入签名
          continue;
        }
        sig.write(c);
      } else {
        // 表达式模式：只跟踪深度，等待深度归 0 的结束 `;`。
        if (c == '(' || c == '[' || c == '{') {
          depth++;
        } else if (c == ')' || c == ']' || c == '}') {
          depth--;
        } else if (c == ';' && depth == 0) {
          return (end: i, signature: sig.toString());
        }
      }
    }
    if (expr && depth <= 0 && line.trimRight().endsWith(';')) {
      return (end: i, signature: sig.toString());
    }
    if (!expr && i > start) sig.write('\n');
  }
  return null;
}

/// `{...}` 体的结束：第一个整行就是 `}`（第 0 列）的行。
int _findBraceEnd(List<String> lines, int from) {
  for (var i = from + 1; i < lines.length; i++) {
    if (lines[i] == '}') return i;
  }
  return -1;
}

/// 从签名文本解析声明的符号名。
String? _declName(String signature) {
  var sig = signature.trim();
  if (sig.isEmpty) return null;
  // class / enum / mixin / extension / typedef：关键字后即名称。
  final kw = RegExp('^(?:class|enum|mixin|extension|typedef)\\s+([A-Za-z_]\\w*)')
      .firstMatch(sig);
  if (kw != null) return kw.group(1);
  // 去掉尾部模式标记残留（`=>`、`;`）。
  sig = sig.replaceAll(RegExp('[=>;\\s]+\$'), '');
  if (sig.isEmpty) return null;
  // 函数：名称紧跟参数列表 `(`（角度括号深度 0，且名称前不是 `.`）。
  var angle = 0;
  for (var k = 0; k < sig.length; k++) {
    final c = sig[k];
    if (c == '<') {
      angle++;
    } else if (c == '>') {
      if (angle > 0) angle--;
    } else if (c == '(' && angle == 0) {
      var j = k - 1;
      while (j >= 0 && _isIdentChar(sig[j])) {
        j--;
      }
      if (j < k - 1 && (j < 0 || sig[j] != '.')) {
        return sig.substring(j + 1, k);
      }
    }
  }
  // 变量/getter：尾部标识符。
  final v = RegExp('([A-Za-z_]\\w*)\$').firstMatch(sig);
  return v?.group(1);
}

/// 字符串/注释扫描状态（跨行：三引号字符串与块注释会跨行）。
class _StringScanState {
  bool inString = false;
  bool triple = false;
  bool raw = false;
  String quote = '';
  bool inBlockComment = false;
}

/// 剥离 [line] 中的字符串字面量内容与注释（`//` 行注释、`/* */` 块
/// 注释），保留其余字符（括号/`;`/`=` 等结构字符），供深度扫描使用。
String _stripStringsAndComments(String line, _StringScanState s) {
  final buf = StringBuffer();
  var i = 0;
  while (i < line.length) {
    if (s.inBlockComment) {
      final end = line.indexOf('*/', i);
      if (end < 0) return buf.toString();
      s.inBlockComment = false;
      i = end + 2;
      continue;
    }
    if (s.inString) {
      if (!s.raw && line[i] == r'\') {
        i += 2; // 转义字符
        continue;
      }
      if (s.triple) {
        if (line.startsWith(s.quote * 3, i)) {
          s.inString = false;
          i += 3;
        } else {
          i++;
        }
        continue;
      }
      if (line[i] == s.quote) s.inString = false;
      i++;
      continue;
    }
    final c = line[i];
    if (c == '/' && i + 1 < line.length) {
      if (line[i + 1] == '/') break;
      if (line[i + 1] == '*') {
        s.inBlockComment = true;
        i += 2;
        continue;
      }
    }
    var raw = false;
    var q = i;
    if (c == 'r' &&
        i + 1 < line.length &&
        (line[i + 1] == "'" || line[i + 1] == '"') &&
        (i == 0 || !_isIdentChar(line[i - 1]))) {
      raw = true; // r'...' 原始字符串前缀
      q = i + 1;
    }
    if (line[q] == "'" || line[q] == '"') {
      s.inString = true;
      s.raw = raw;
      s.quote = line[q];
      if (line.startsWith(s.quote * 3, q)) {
        s.triple = true;
        i = q + 3;
      } else {
        s.triple = false;
        i = q + 1;
      }
      continue;
    }
    buf.write(c);
    i++;
  }
  return buf.toString();
}

bool _isIdentChar(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      c == '_' ||
      c == r'$';
}
