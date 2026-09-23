/// 「在 Windows 资源管理器中显示」的路径解析与启动（纯逻辑可测，
/// 仅依赖 dart:io / package:path，无 Flutter 依赖）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// explorer 启动描述：[exe] 为可执行文件，[args] 为其参数。
typedef ExplorerLaunch = ({String exe, List<String> args});

/// 计算资源管理器定位方式。
///
/// - [rawPath] 为空白 → null（调用方据此禁用按钮）。
/// - 相对路径按当前工作目录归一化为绝对路径（Windows 反斜杠）。
/// - 路径本身是已存在的目录 → 直接打开该目录。
/// - 文件存在 → `/select,<绝对路径>`（打开所在目录并选中文件）。
/// - 文件不存在但所在目录存在 → 打开所在目录。
/// - 文件与所在目录都不存在 → null（调用方提示）。
///
/// 重要：参数中**不能**手工加引号——Dart 拼 Windows 命令行时会把内嵌
/// 引号转义为 `\"`，CommandLineToArgvW 能正确解码，但 explorer.exe
/// 自己解析命令行、不认识 `\"` 转义，会回退打开「文档」。路径不含
/// 空格时直接裸传（Dart 不会加引号）；含空格时改经 `cmd /c` 包装
/// （cmd 原生处理引号，explorer 收到干净的命令行）。
///
/// [fileExists] / [dirExists] 可注入以便单测；默认走文件系统。
ExplorerLaunch? explorerRevealLaunch(
  String rawPath, {
  bool Function(String path)? fileExists,
  bool Function(String path)? dirExists,
}) {
  final fe = fileExists ?? (s) => File(s).existsSync();
  final de = dirExists ?? (s) => Directory(s).existsSync();
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) return null;
  final abs = p.normalize(p.absolute(trimmed));
  final String? target; // 传给 explorer 的目标（/select, 前缀或目录）
  if (de(abs)) {
    target = abs;
  } else if (fe(abs)) {
    target = '/select,$abs';
  } else {
    final parent = p.dirname(abs);
    if (!de(parent)) return null;
    target = parent;
  }
  if (!target.contains(' ')) {
    // 无空格：裸传，Dart 不会给参数加引号。
    return (exe: 'explorer.exe', args: [target]);
  }
  // 有空格：经 cmd /c 包装，引号由 cmd 原生处理。
  return (
    exe: 'cmd.exe',
    args: ['/c', 'explorer.exe', target.contains(',') ? _quoteSelect(target) : '"$target"'],
  );
}

/// /select, 形式的目标整体加引号（cmd /c 下 explorer 收到带引号路径）。
String _quoteSelect(String target) {
  final i = target.indexOf(',');
  return '${target.substring(0, i + 1)}"${target.substring(i + 1)}"';
}

/// 打开资源管理器定位 [rawPath]；成功返回 null，失败返回中文提示文案
///（由调用方以 SnackBar 等形式展示）。
Future<String?> revealInExplorer(String rawPath) async {
  final launch = explorerRevealLaunch(rawPath);
  if (launch == null) {
    return rawPath.trim().isEmpty ? '请先设置文件路径' : '路径不存在：$rawPath';
  }
  try {
    await Process.start(launch.exe, launch.args,
        mode: ProcessStartMode.detached);
    return null;
  } catch (e) {
    return '打开资源管理器失败：$e';
  }
}
