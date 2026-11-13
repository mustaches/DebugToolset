/// Vivado 探测与 demo_prj 批处理生成。
library;

import 'dart:convert' show Utf8Decoder;
import 'dart:io';

class VivadoToolchain {
  final String executable;

  const VivadoToolchain(this.executable);

  String get version {
    var dir = File(executable).parent;
    final pattern = RegExp(r'^\d+\.\d+(?:\.\d+)?$');
    for (var i = 0; i < 6; i++) {
      final segments = dir.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final candidate = segments.isEmpty ? '' : segments.last;
      if (pattern.hasMatch(candidate)) return candidate;
      dir = dir.parent;
    }
    return '';
  }

  String get displayName => version.isEmpty
      ? 'Vivado — $executable'
      : 'Vivado $version — $executable';

  String get _key => Platform.isWindows ? executable.toLowerCase() : executable;

  @override
  bool operator ==(Object other) =>
      other is VivadoToolchain && other._key == _key;

  @override
  int get hashCode => _key.hashCode;
}

String? _vivadoExecutable(String dir) {
  for (final name in const ['vivado.exe', 'vivado.bat', 'vivado']) {
    final path = '$dir${Platform.pathSeparator}$name';
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// 从注册表卸载项的 LaunchVlmString 提取 Vivado bin 目录。
List<String> parseVivadoRegistryBins(String output) {
  final bins = <String>{};
  final launch = RegExp(
    r'LaunchVlmString\s+REG_SZ\s+(.+)$',
    caseSensitive: false,
  );
  final vvgl = RegExp(
    r'"([^"]+vvgl\.exe)"|(\S+vvgl\.exe)',
    caseSensitive: false,
  );
  for (final line in output.split('\n')) {
    final m = launch.firstMatch(line.trim());
    if (m == null) continue;
    final exe = vvgl.firstMatch(m.group(1)!);
    if (exe == null) continue;
    final path = exe.group(1) ?? exe.group(2)!;
    bins.add(File(path).parent.parent.parent.path);
  }
  return bins.toList();
}

List<String> _vivadoRegistryBinDirs() {
  if (!Platform.isWindows) return const [];
  final bins = <String>{};
  for (final key in const [
    r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
  ]) {
    for (final hive in const ['HKLM', 'HKCU']) {
      try {
        final result = Process.runSync(
          'reg',
          ['query', '$hive\\$key', '/s', '/f', 'Vivado'],
          stdoutEncoding: systemEncoding,
          stderrEncoding: systemEncoding,
        );
        if (result.exitCode == 0) {
          bins.addAll(parseVivadoRegistryBins(result.stdout as String));
        }
      } catch (_) {}
    }
  }
  return bins.toList();
}

int _compareVersions(String a, String b) {
  final pa = a.split('.').map(int.tryParse).toList();
  final pb = b.split('.').map(int.tryParse).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final c = (pa[i] ?? 0).compareTo(pb[i] ?? 0);
    if (c != 0) return c;
  }
  return a.compareTo(b);
}

/// 探测本机全部 Vivado 安装，按版本降序返回并按可执行路径去重。
/// [searchDirs] 为直接包含 vivado 可执行文件的目录，供测试注入。
List<VivadoToolchain> detectVivadoInstallations({
  List<String>? searchDirs,
  List<String>? installRoots,
}) {
  final pathDirs =
      searchDirs ??
      (Platform.environment['PATH']?.split(Platform.isWindows ? ';' : ':') ??
          const <String>[]);
  final candidates = <String>[];
  for (final dir in pathDirs) {
    if (dir.isEmpty) continue;
    final exe = _vivadoExecutable(dir);
    if (exe != null) candidates.add(exe);
  }
  if (searchDirs == null) {
    for (final bin in _vivadoRegistryBinDirs()) {
      final exe = _vivadoExecutable(bin);
      if (exe != null) candidates.add(exe);
    }
  }
  if (searchDirs == null || installRoots != null) {
    final roots =
        installRoots ??
        const [
          r'C:\Xilinx\Vivado',
          r'C:\AMD\Vivado',
          r'D:\Xilinx\Vivado',
          r'D:\AMD\Vivado',
          r'C:\AMDDesignTools',
          r'D:\AMDDesignTools',
        ];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entry in dir.listSync()) {
        if (entry is! Directory) continue;
        for (final bin in [
          '${entry.path}${Platform.pathSeparator}bin',
          '${entry.path}${Platform.pathSeparator}Vivado${Platform.pathSeparator}bin',
        ]) {
          final exe = _vivadoExecutable(bin);
          if (exe != null) candidates.add(exe);
        }
      }
    }
  }
  final unique = <String, VivadoToolchain>{};
  for (final exe in candidates) {
    final absolute = File(exe).absolute.path;
    final key = Platform.isWindows ? absolute.toLowerCase() : absolute;
    unique[key] = VivadoToolchain(absolute);
  }
  final result = unique.values.toList()
    ..sort((a, b) {
      final byVersion = _compareVersions(b.version, a.version);
      return byVersion != 0 ? byVersion : a.executable.compareTo(b.executable);
    });
  return result;
}

/// 对话框默认版本：优先 2020.2，未安装时使用列表中的最新版本。
VivadoToolchain? preferredVivadoToolchain(
  Iterable<VivadoToolchain> toolchains,
) {
  if (toolchains.isEmpty) return null;
  for (final toolchain in toolchains) {
    if (toolchain.version == '2020.2') return toolchain;
  }
  return toolchains.first;
}

/// 默认使用探测到的最新 Vivado。
VivadoToolchain? detectVivado({
  List<String>? searchDirs,
  List<String>? installRoots,
}) {
  final all = detectVivadoInstallations(
    searchDirs: searchDirs,
    installRoots: installRoots,
  );
  return all.isEmpty ? null : all.first;
}

class VivadoDemoResult {
  final bool success;
  final String output;
  final int exitCode;
  final String projectPath;

  const VivadoDemoResult({
    required this.success,
    required this.output,
    required this.exitCode,
    required this.projectPath,
  });
}

/// 运行已写盘 IP 包的 demo/create_demo_project.tcl。
Future<VivadoDemoResult> runVivadoDemoProject(
  String packageDir, {
  void Function(String chunk)? onOutput,
  VivadoToolchain? vivado,
  String projectName = 'demo_prj',
  Duration timeout = const Duration(minutes: 30),
}) async {
  final demoDir = '$packageDir${Platform.pathSeparator}demo';
  final projectPath =
      '$demoDir${Platform.pathSeparator}$projectName${Platform.pathSeparator}$projectName.xpr';
  final out = StringBuffer();
  void emit(String s) {
    out.write(s);
    onOutput?.call(s);
  }

  final tc = vivado ?? detectVivado();
  if (tc == null) {
    emit('未检测到 Vivado，请安装 Vivado 或将其 bin 目录加入 PATH。\n');
    return VivadoDemoResult(
      success: false,
      output: out.toString(),
      exitCode: -1,
      projectPath: projectPath,
    );
  }
  final script = '$demoDir${Platform.pathSeparator}create_demo_project.tcl';
  emit('Vivado: ${tc.executable}\n');
  emit('脚本: $script\n\n');
  final Process proc;
  try {
    proc = await Process.start(
      tc.executable,
      ['-mode', 'batch', '-source', script],
      workingDirectory: demoDir,
      runInShell: tc.executable.toLowerCase().endsWith('.bat'),
    );
  } catch (e) {
    emit('Vivado 启动失败：$e\n');
    return VivadoDemoResult(
      success: false,
      output: out.toString(),
      exitCode: -1,
      projectPath: projectPath,
    );
  }
  const decoder = Utf8Decoder(allowMalformed: true);
  final outDone = proc.stdout.transform(decoder).forEach(emit);
  final errDone = proc.stderr.transform(decoder).forEach(emit);
  final code = await proc.exitCode.timeout(
    timeout,
    onTimeout: () {
      proc.kill();
      emit('Vivado 执行超时，已终止。\n');
      return -2;
    },
  );
  await Future.wait([outDone, errDone]);
  final exists = File(projectPath).existsSync();
  if (code == 0 && !exists) emit('Vivado 已退出，但未找到 $projectName.xpr。\n');
  emit(
    code == 0 && exists
        ? '\n$projectName 生成成功：$projectPath\n'
        : '\n$projectName 生成失败（退出码 $code）。\n',
  );
  return VivadoDemoResult(
    success: code == 0 && exists,
    output: out.toString(),
    exitCode: code,
    projectPath: projectPath,
  );
}
