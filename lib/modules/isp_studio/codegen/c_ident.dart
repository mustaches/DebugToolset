/// ISP 编组导出 C 代码：标识符 / 文件名净化与去重。
///
/// 节点名（如「Gamma#1」「色彩 平衡#2」）与编组名可以是任意 Unicode，
/// 需要净化为合法 C 标识符（同时作为文件名，不含扩展名）。
library;

/// 把任意名称净化为小写 C 标识符：非 [a-z0-9] 一律转为 '_'，
/// 合并连续 '_' 并去首尾 '_'；结果为空（纯非 ASCII 名）返回 null。
String? sanitizeCIdent(String name) {
  final buf = StringBuffer();
  var lastUnderscore = true; // 视为开头已有 '_'，避免前导下划线
  for (final unit in name.toLowerCase().codeUnits) {
    final isAlnum = (unit >= 0x61 && unit <= 0x7a) || // a-z
        (unit >= 0x30 && unit <= 0x39); // 0-9
    if (isAlnum) {
      buf.writeCharCode(unit);
      lastUnderscore = false;
    } else if (!lastUnderscore) {
      buf.write('_');
      lastUnderscore = true;
    }
  }
  var s = buf.toString();
  if (s.endsWith('_')) s = s.substring(0, s.length - 1);
  if (s.isEmpty) return null;
  // C 标识符不能以数字开头。
  if (s.codeUnitAt(0) >= 0x30 && s.codeUnitAt(0) <= 0x39) s = 'n$s';
  return s;
}

/// 组内唯一标识符分配：先净化名称，空则回退 [fallback]；
/// 与已占用标识符冲突时追加 `_2`、`_3`…。
String uniqueCIdent(String name, String fallback, Set<String> taken) {
  var base = sanitizeCIdent(name) ?? sanitizeCIdent(fallback) ?? 'node';
  if (!taken.contains(base)) {
    taken.add(base);
    return base;
  }
  for (var i = 2;; i++) {
    final cand = '${base}_$i';
    if (!taken.contains(cand)) {
      taken.add(cand);
      return cand;
    }
  }
}

/// 标识符 → 宏前缀（全大写）。
String cMacroPrefix(String ident) => ident.toUpperCase();
