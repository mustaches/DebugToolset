/// 生成源码的写盘编码：Verilog/Tcl 在 Windows 上跟随 Vivado 的版本编码
/// （2020.2 及旧版用系统代码页，2024.2+ 用 UTF-8）；Markdown 文档固定 UTF-8，
/// 因为 README/UserGuide 主要由 VSCode、GitHub 等 UTF-8 编辑器/查看器打开。
library;

import 'dart:convert' show Encoding, utf8;
import 'dart:io';

Encoding get generatedTextEncoding =>
    Platform.isWindows ? systemEncoding : utf8;

bool _vivadoNeedsUtf8(String? executable) {
  if (executable == null || executable.isEmpty) return false;
  final match = RegExp(r'(20\d{2})\.(\d+)').firstMatch(executable);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  return year > 2024 || (year == 2024 && minor >= 2);
}

/// 2020.2 及旧版 Windows Vivado 使用系统代码页；2024.2 及新版使用 UTF-8。
Encoding generatedTextEncodingForVivado(String? executable) {
  return !Platform.isWindows || _vivadoNeedsUtf8(executable)
      ? utf8
      : systemEncoding;
}

Future<void> writeGeneratedText(
  File file,
  String contents, {
  String? vivadoExecutable,
}) {
  final lower = file.path.toLowerCase();
  final isMarkdown = lower.endsWith('.md') || lower.endsWith('.markdown');
  return file.writeAsString(
    contents,
    encoding: isMarkdown
        ? utf8
        : generatedTextEncodingForVivado(vivadoExecutable),
  );
}
