import 'package:flutter/material.dart';

/// 串口终端与网络终端共享的会话接口。
/// 终端 UI 组件（输出区 / 输入框 / 宏工具栏）只依赖此接口，不关心底层是串口还是网络。
abstract class TerminalSession {
  static const List<int> rollbackDepths = [2000, 5000, 10000, 20000, 50000, 100000, 200000];

  /// 输出区可选等宽字体
  static const List<String> fontFamilies = [
    'Consolas',
    'Cascadia Mono',
    'Courier New',
    'Lucida Console',
    'monospace',
  ];

  bool get isConnected;
  DateTime? get connectionStartTime;
  bool get showTimestamp;
  int get maxLines;
  void setMaxLines(int limit);
  FocusNode? get commandFocusNode;
  set commandFocusNode(FocusNode? node);

  /// 输出区字体设置（两个终端各自独立，未保存时重启后恢复内置默认）
  double get fontSize;
  void setFontSize(double size);
  double get lineHeight;
  void setLineHeight(double height);
  String get fontFamily;
  void setFontFamily(String family);

  /// 将当前字体设置保存为默认值（持久化到 terminal_font_settings.json，下次启动生效）
  void saveFontSettingsAsDefault();

  void sendCommand(String command, {bool isHex = false, String eolMode = 'None'});
  void addSystemLog(String data);

  void addCommandToHistory(String command, {bool isHex = false});
  String? getPreviousCommand({bool isHex = false});
  String? getNextCommand({bool isHex = false});
  String? getLatestCommand({bool isHex = false});
}
