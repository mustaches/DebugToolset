// rebuild 构建成功后自动递增 pubspec.yaml 中的构建号：
//   version: 1.1.0+2 → version: 1.1.0+3
//   version: 1.1.0   → version: 1.1.0+1
// 用法：dart scripts/bump_build_number.dart [pubspec路径]
// （默认 pubspec.yaml，相对工作目录）

import 'dart:io';

/// 对 pubspec.yaml 文本执行构建号递增，返回递增后的完整文本。
/// 找不到 version 行时抛 [FormatException]。
String bumpBuildNumber(String pubspecText) {
  final pattern =
      RegExp(r'^(version:\s*\d+\.\d+\.\d+)(?:\+(\d+))?(\s*)$', multiLine: true);
  final match = pattern.firstMatch(pubspecText);
  if (match == null) {
    throw const FormatException('pubspec.yaml 中未找到 version 行');
  }
  final current = int.tryParse(match.group(2) ?? '') ?? 0;
  final replacement = '${match.group(1)}+${current + 1}${match.group(3)}';
  return pubspecText.replaceRange(match.start, match.end, replacement);
}

void main(List<String> args) {
  final path = args.isEmpty ? 'pubspec.yaml' : args[0];
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('错误：找不到 $path（请从工程根目录运行）');
    exit(1);
  }

  final original = file.readAsStringSync();
  final String updated;
  try {
    updated = bumpBuildNumber(original);
  } on FormatException catch (e) {
    stderr.writeln('错误：${e.message}');
    exit(1);
  }
  if (updated == original) {
    stderr.writeln('错误：构建号未发生变化');
    exit(1);
  }
  file.writeAsStringSync(updated, flush: true);

  final oldLine =
      RegExp(r'^version:.*$', multiLine: true).firstMatch(original)?.group(0);
  final newLine =
      RegExp(r'^version:.*$', multiLine: true).firstMatch(updated)?.group(0);
  stdout.writeln('构建号已递增：$oldLine → $newLine');
}
