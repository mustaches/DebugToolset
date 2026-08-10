/// 从节点代码片段中静态提取变量声明（名称 / 类型 / 内容），
/// 供代码标签页右侧的变量表展示。纯 Dart，无 Flutter 依赖。
///
/// 只识别带初始化表达式的 `final` / `const` / `var` 声明
/// （含 `var a = 1, b = 2;` 多声明与 for 循环内的声明）；
/// 数组字面量的元素按顶层逗号拆分后放入 [CodeVariable.items]。
library;

/// 一个解析出的变量。
class CodeVariable {
  /// 变量名。
  final String name;

  /// 数据类型：显式声明的类型，或从初始化表达式推断
  /// （int/double/bool/String/List/构造器名），无法推断时为声明关键字。
  final String type;

  /// 变量内容：初始化表达式（压缩为单行）。
  final String value;

  /// 数组字面量的元素内容（与 [value] 中的顺序一致）；非数组为 null。
  final List<String>? items;

  /// 数组元素的坐标标签（如 `(0, 3, 1)`），与 [items] 一一对应；
  /// null 时界面用数字序号。
  final List<String>? itemLabels;

  /// 运行缓冲的帧宽/帧高/通道数（坐标查询的取值范围）；非运行缓冲为 null。
  final int? frameWidth;
  final int? frameHeight;
  final int? frameChannels;

  /// 坐标查询的目标节点：输出缓冲为本节点，输入缓冲为上游节点；
  /// null 表示该变量不支持坐标查询。
  final String? queryNodeId;

  const CodeVariable({
    required this.name,
    required this.type,
    required this.value,
    this.items,
    this.itemLabels,
    this.frameWidth,
    this.frameHeight,
    this.frameChannels,
    this.queryNodeId,
  });
}

final _keywordRe = RegExp(r'\b(final|const|var)\b');
final _nameRe = RegExp(r'[A-Za-z_]\w*');

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\r' || c == '\n';

/// 去掉注释与字符串字面量（字符串替换为 `''`），保留换行结构，
/// 避免注释/字符串里的文本被误判为声明。
String _stripCommentsAndStrings(String code) {
  final buf = StringBuffer();
  final n = code.length;
  var i = 0;
  while (i < n) {
    final c = code[i];
    final two = i + 1 < n ? code.substring(i, i + 2) : '';
    if (two == '//') {
      final eol = code.indexOf('\n', i);
      if (eol < 0) break;
      buf.write('\n');
      i = eol + 1;
    } else if (two == '/*') {
      final end = code.indexOf('*/', i + 2);
      final stop = end < 0 ? n : end + 2;
      for (var k = i; k < stop; k++) {
        if (code[k] == '\n') buf.write('\n');
      }
      i = stop;
    } else if (c == "'" || c == '"') {
      final raw = i > 0 && code[i - 1] == 'r';
      var j = i + 1;
      if (raw) {
        while (j < n && code[j] != c && code[j] != '\n') {
          j++;
        }
        if (j < n && code[j] == c) j++;
      } else {
        var escape = false;
        while (j < n) {
          final ch = code[j];
          if (escape) {
            escape = false;
          } else if (ch == r'\') {
            escape = true;
          } else if (ch == c) {
            j++;
            break;
          } else if (ch == '\n') {
            break;
          }
          j++;
        }
      }
      buf.write("''");
      i = j;
    } else {
      buf.write(c);
      i++;
    }
  }
  return buf.toString();
}

int _skipSpaces(String s, int i) {
  while (i < s.length && _isSpace(s[i])) {
    i++;
  }
  return i;
}

/// 从 [start] 扫描初始化表达式，返回（表达式, 终止符位置, 终止符）。
/// 终止符为顶层（括号深度 0）的 `,` 或 `;`。
(String, int, String) _scanInitializer(String s, int start) {
  var depth = 0;
  var i = start;
  while (i < s.length) {
    final c = s[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) break; // for 循环的右括号等
      depth--;
    }
    if (depth == 0 && (c == ',' || c == ';')) break;
    i++;
  }
  return (s.substring(start, i), i, i < s.length ? s[i] : '');
}

/// 按顶层逗号拆分（数组元素可能本身是列表字面量）。
List<String> _splitTopLevel(String s) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ',' && depth == 0) {
      parts.add(s.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(s.substring(start));
  return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
}

String _oneLine(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

/// 从初始化表达式推断数据类型。
String _inferType(String expr, String keyword) {
  final e = expr.trim();
  if (e.startsWith('[')) return 'List';
  if (e.startsWith("''")) return 'String';
  if (e == 'true' || e == 'false') return 'bool';
  if (RegExp(r'^\d+$').hasMatch(e)) return 'int';
  if (RegExp(r'^\d*\.\d').hasMatch(e) ||
      RegExp(r'^\d+(\.\d+)?[eE]').hasMatch(e)) {
    return 'double';
  }
  // 构造器调用（大写开头，如 `Uint16List(...)`、`List<double>.filled(...)`）。
  final ctor = RegExp(r'^([A-Z]\w*(?:<[^>]*>)?)\s*[.(]').firstMatch(e);
  if (ctor != null) return ctor.group(1)!;
  return keyword;
}

/// 数组字面量的元素列表；非数组字面量返回 null。
List<String>? _arrayItems(String expr) {
  final e = expr.trim();
  if (e.length < 2 || !e.startsWith('[') || !e.endsWith(']')) return null;
  return _splitTopLevel(e.substring(1, e.length - 1));
}

/// 提取 [code] 中的变量声明，按出现顺序返回（同名只保留首次）。
List<CodeVariable> extractVariables(String code) {
  final clean = _stripCommentsAndStrings(code);
  final result = <CodeVariable>[];
  final seen = <String>{};

  for (final match in _keywordRe.allMatches(clean)) {
    final keyword = match.group(1)!;
    var i = _skipSpaces(clean, match.end);
    // `final (w, h) = ...` 解构与 `const [ ... ]` 字面量：无变量名，跳过。
    if (i >= clean.length || _nameRe.matchAsPrefix(clean, i) == null) {
      continue;
    }

    // 可选的显式类型：`final List<double> m = ...` / `var int x = ...` 形式。
    String? declaredType;
    final firstWord = _nameRe.matchAsPrefix(clean, i);
    if (firstWord != null) {
      final afterFirst = _skipSpaces(clean, firstWord.end);
      final secondWord = afterFirst < clean.length
          ? _nameRe.matchAsPrefix(clean, afterFirst)
          : null;
      final afterSecond = secondWord != null
          ? _skipSpaces(clean, secondWord.end)
          : afterFirst;
      if (secondWord != null &&
          afterSecond < clean.length &&
          (clean[afterSecond] == '=' || clean[afterSecond] == ',')) {
        declaredType = firstWord.group(0);
        i = afterFirst;
      }
    }

    // 依次读取每个声明子句：name = expr（顶层逗号/分号分隔）。
    while (i < clean.length) {
      i = _skipSpaces(clean, i);
      final nameMatch = _nameRe.matchAsPrefix(clean, i);
      if (nameMatch == null) break;
      final name = nameMatch.group(0)!;
      i = _skipSpaces(clean, nameMatch.end);
      if (i >= clean.length || clean[i] != '=') break;
      // `==` / `=>` 不是初始化。
      if (i + 1 < clean.length &&
          (clean[i + 1] == '=' || clean[i + 1] == '>')) {
        break;
      }
      i = _skipSpaces(clean, i + 1);
      final (expr, end, terminator) = _scanInitializer(clean, i);
      if (seen.add(name)) {
        final value = _oneLine(expr);
        result.add(CodeVariable(
          name: name,
          type: declaredType ?? _inferType(expr, keyword),
          value: value,
          items: _arrayItems(expr),
        ));
      }
      if (terminator != ',') break;
      i = end + 1;
    }
  }
  return result;
}
