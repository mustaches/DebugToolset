/// 打印 Windows 构建将使用的 CMake 生成器（如 "Visual Studio 18 2026"）。
///
/// rebuild.bat 在 flutter build 前调用本脚本，把结果经
/// --dart-define=CMAKE_GENERATOR=... 烘焙进二进制，使 Inno Setup 打包
/// 安装后的应用版本信息对话框仍能显示编译环境。
///
/// 优先解析既有 build/windows/x64/CMakeCache.txt（与实际构建一致）；
/// 不存在时（flutter clean 之后）解析 `cmake --help` 列出的默认生成器——
/// flutter tool 配置 Windows 工程时不显式指定 -G，用的正是该默认值。
/// 探测失败时不输出任何内容（批处理按未定义处理，退化为普通构建）。
///
/// cmake 定位顺序：PATH → vswhere 定位的 VS 内置 CMake
/// （VS 安装的 cmake 通常不在 PATH 中，flutter clean 后必须走这条路径）。
library;

import 'dart:io';

void main() {
  final generator = detectCmakeGenerator();
  if (generator != null) stdout.write(generator);
}

String? detectCmakeGenerator() {
  final cache = File('build/windows/x64/CMakeCache.txt');
  if (cache.existsSync()) {
    final match = RegExp(r'^CMAKE_GENERATOR:INTERNAL=(.*)$', multiLine: true)
        .firstMatch(cache.readAsStringSync());
    final value = match?.group(1)?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  for (final cmake in _cmakeCandidates()) {
    final generator = _defaultGeneratorFromCmakeHelp(cmake);
    if (generator != null) return generator;
  }
  return null;
}

/// 候选 cmake 路径：PATH 中的 cmake + vswhere 定位的 VS 内置 cmake。
Iterable<String> _cmakeCandidates() sync* {
  yield 'cmake';
  const vswhereDirs = [
    r'C:\Program Files\Microsoft Visual Studio\Installer\vswhere.exe',
    r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
  ];
  for (final vswhere in vswhereDirs) {
    if (!File(vswhere).existsSync()) continue;
    try {
      final result =
          Process.runSync(vswhere, ['-latest', '-property', 'installationPath']);
      if (result.exitCode != 0) continue;
      final vsPath = result.stdout.toString().trim();
      if (vsPath.isEmpty) continue;
      final cmake =
          '$vsPath\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe';
      if (File(cmake).existsSync()) yield cmake;
    } catch (_) {
      // 忽略，尝试下一个候选
    }
  }
}

/// 解析 `cmake --help` 列出的默认生成器（行首带 * 的一行）。
/// flutter tool 配置 Windows 工程时不显式指定 -G，用的正是该默认值。
String? _defaultGeneratorFromCmakeHelp(String cmake) {
  try {
    final result = Process.runSync(cmake, ['--help']);
    if (result.exitCode != 0) return null;
    // 默认生成器行形如: "* Visual Studio 18 2026        = Generates ..."
    final line = result.stdout
        .toString()
        .split('\n')
        .map((l) => l.trimRight())
        .firstWhere((l) => l.startsWith('* '), orElse: () => '');
    if (line.isEmpty) return null;
    final body = line.substring(2);
    final eq = body.indexOf('=');
    final name = (eq >= 0 ? body.substring(0, eq) : body).trim();
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}
