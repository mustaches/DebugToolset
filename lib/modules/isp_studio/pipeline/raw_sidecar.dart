/// RAW 同名 .txt 旁车文件（传感器采集工具导出）的解析。
///
/// 文件为 INI 风格，`[common]` 节包含 Width/Height/Bits/Bayer 与
/// BlackLevel_R/Gr/Gb/B 等字段；黑电平为 16 倍刻度（如 804 ≈ 实际 50.25）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 读取 [rawPath] 同名 .txt 的 `[common]` 节键值对（ trimmed，区分大小写）。
/// 文件不存在或没有 `[common]` 节时返回 null。
Future<Map<String, String>?> readRawSidecarCommon(String rawPath) async {
  final file = File(p.setExtension(rawPath, '.txt'));
  if (!await file.exists()) return null;
  final text = await file.readAsString();

  final values = <String, String>{};
  var inCommon = false;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.startsWith('[')) {
      inCommon = t.toLowerCase() == '[common]';
      continue;
    }
    if (!inCommon) continue;
    final eq = t.indexOf('=');
    if (eq <= 0) continue;
    values[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
  }
  return values.isEmpty ? null : values;
}

/// 读取 [rawPath] 同名 .txt 中的黑电平，返回 (R, Gr, Gb, B) 实际值。
/// 文件不存在、缺 `[common]` 节或缺字段时返回 null。
Future<(double, double, double, double)?> readRawSidecarBlackLevels(
    String rawPath) async {
  final values = await readRawSidecarCommon(rawPath);
  if (values == null) return null;
  final r = double.tryParse(values['BlackLevel_R'] ?? '');
  final gr = double.tryParse(values['BlackLevel_Gr'] ?? '');
  final gb = double.tryParse(values['BlackLevel_Gb'] ?? '');
  final b = double.tryParse(values['BlackLevel_B'] ?? '');
  if (r == null || gr == null || gb == null || b == null) return null;
  // 16 倍刻度 → 实际像素值。
  return (r / 16, gr / 16, gb / 16, b / 16);
}
