import 'dart:convert';

import 'ui_project.dart';

/// Serializes projects to / from the `.uiproj` JSON format.
class ProjectSerializer {
  ProjectSerializer._();

  static String encode(UiProject project) =>
      const JsonEncoder.withIndent('  ').convert(project.toJson());

  static UiProject decode(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('不是有效的 UI 工程文件');
    }
    return UiProject.fromJson(decoded);
  }
}

/// Turns arbitrary user text into a valid C identifier (`my_func_1`).
/// Returns null when nothing usable remains.
String? sanitizeCIdentifier(String input) {
  var s = input.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  s = s.replaceAll(RegExp(r'_+'), '_');
  s = s.replaceAll(RegExp(r'^_+|_+$'), '');
  if (s.isEmpty) return null;
  if (RegExp(r'^[0-9]').hasMatch(s)) s = '_$s';
  return s;
}
