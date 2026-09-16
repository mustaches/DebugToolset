import 'dart:convert';
import 'dart:io';

/// 终端输出区字体设置的持久化（工作目录下的 terminal_font_settings.json）。
/// 按终端分别存储：serial = 串口终端，network = 网络终端。
class TerminalFontPrefs {
  final double fontSize;
  final double lineHeight;
  final String fontFamily;

  const TerminalFontPrefs({
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
  });

  static File get _file => File('terminal_font_settings.json');

  static Future<Map<String, dynamic>> _readAll() async {
    try {
      if (await _file.exists()) {
        final json = jsonDecode(await _file.readAsString());
        if (json is Map<String, dynamic>) return json;
      }
    } catch (_) {
      // 文件缺失或损坏时视为无保存值
    }
    return {};
  }

  static Future<TerminalFontPrefs?> load(String key) async {
    final entry = (await _readAll())[key];
    if (entry is! Map) return null;
    final fontSize = (entry['fontSize'] as num?)?.toDouble();
    final lineHeight = (entry['lineHeight'] as num?)?.toDouble();
    final fontFamily = entry['fontFamily'] as String?;
    if (fontSize == null || lineHeight == null || fontFamily == null) {
      return null;
    }
    return TerminalFontPrefs(
      fontSize: fontSize,
      lineHeight: lineHeight,
      fontFamily: fontFamily,
    );
  }

  static Future<void> save(String key, TerminalFontPrefs prefs) async {
    final all = await _readAll();
    all[key] = {
      'fontSize': prefs.fontSize,
      'lineHeight': prefs.lineHeight,
      'fontFamily': prefs.fontFamily,
    };
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(all));
  }
}
