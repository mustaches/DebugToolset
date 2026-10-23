/// Icarus Verilog 探测与一键仿真：把 IP 包写临时唯一目录 → `iverilog
/// -g2012` 编译 → `vvp` 运行 → 解析 PASS/FAIL。仿 c_compile.dart 的
/// detectArmGcc + runStep（流式输出 + 超时保护）。无 iverilog 时探测返回
/// null（UI 提示安装，导出功能本身不受影响）。
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

/// iverilog 编译器可执行文件路径（`iverilog`/`vvp` 两件套）。未找到返回
/// null。
class IverilogToolchain {
  final String iverilog;
  final String vvp;

  const IverilogToolchain(this.iverilog, this.vvp);
}

/// 随应用打包的 iverilog 目录（相对工作目录，与 tools/ffmpeg 同口径；
/// 安装版中位于 exe 同级 tools/ 下）。须转为绝对路径——仿真子进程会
/// 切换工作目录，相对路径在其下不可解析。
String _bundledToolDir(String rel) => '${Directory.current.path}\\$rel';

/// 探测 iverilog：应用内置 tools/iverilog/bin 优先（安装版开箱即用），
/// 其次 PATH 各目录与常见安装根（C:\iverilog\bin 等）。返回编译器 +
/// 运行器路径；[searchDirs] 可注入（测试用）。
IverilogToolchain? detectIverilog({List<String>? searchDirs}) {
  final dirs = searchDirs ??
      [
        _bundledToolDir(r'tools\iverilog\bin'),
        ...?Platform.environment['PATH']?.split(';'),
        r'C:\iverilog\bin',
        r'C:\iverilog\bin\x64',
        r'C:\Program Files\iverilog\bin',
        r'C:\Program Files (x86)\iverilog\bin',
      ];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final iv = '$dir\\iverilog.exe';
    final vv = '$dir\\vvp.exe';
    if (File(iv).existsSync() && File(vv).existsSync()) {
      return IverilogToolchain(iv, vv);
    }
  }
  return null;
}

/// 一键仿真结果。
class IpSimResult {
  final bool success;
  final bool passed;
  final String output;
  final int exitCode;

  /// tb 转储的 wave.vcd 内容（内嵌波形标签页用；临时目录删除前捕获，
  /// 无波形文件时为 null）。
  final Uint8List? vcdData;

  const IpSimResult({
    required this.success,
    required this.passed,
    required this.output,
    required this.exitCode,
    this.vcdData,
  });
}

/// 运行 IP 仿真：把 [files]（文件名→内容）写临时唯一目录 → iverilog 编译
/// 全部 `.v`（含 tb）→ vvp 运行 → 解析输出中的 PASS/FAIL。[onOutput]
/// 流式回调（终端面板实时显示）；[iverilog] 注入用（测试），缺省探测。
/// 波形展示由内嵌「仿真波形」标签页承担（经 [IpSimResult.vcdData]）。
Future<IpSimResult> runIpSimulation(
  Map<String, String> files, {
  void Function(String chunk)? onOutput,
  IverilogToolchain? iverilog,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final tc = iverilog ?? detectIverilog();
  if (tc == null) {
    return const IpSimResult(
        success: false, passed: false, output: '未检测到 iverilog', exitCode: -1);
  }
  final dir = await Directory.systemTemp.createTemp('isp_ip_sim_');
  final out = StringBuffer();
  void emit(String s) {
    out.write(s);
    onOutput?.call(s);
  }

  try {
    // 写文件（键可带子目录如 xgui/xxx.tcl：先建父目录）。
    for (final e in files.entries) {
      final f = File('${dir.path}${Platform.pathSeparator}${e.key}');
      await f.parent.create(recursive: true);
      await f.writeAsString(e.value);
    }
    final sources = [
      for (final name in files.keys)
        if (name.endsWith('.v')) name,
    ];
    final vvpOut = '${dir.path}${Platform.pathSeparator}sim.vvp';
    emit('$sources\n\n');

    final compileCode = await _runStep(tc.iverilog,
        ['-g2012', '-o', vvpOut, ...sources], dir.path, emit, timeout);
    if (compileCode != 0) {
      return IpSimResult(
          success: false, passed: false, output: out.toString(), exitCode: compileCode);
    }
    final runCode = await _runStep(tc.vvp, [vvpOut], dir.path, emit, timeout);
    final passed = out.toString().contains('PASS');

    // 目录删除前捕获波形内容（内嵌波形标签页经回环伺服读取）。
    final vcd = '${dir.path}${Platform.pathSeparator}wave.vcd';
    Uint8List? vcdData;
    try {
      final f = File(vcd);
      if (f.existsSync()) vcdData = await f.readAsBytes();
    } catch (_) {}

    return IpSimResult(
        success: true,
        passed: passed,
        output: out.toString(),
        exitCode: runCode,
        vcdData: vcdData);
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败不致命（系统重启后回收）。
    }
  }
}

Future<int> _runStep(String exe, List<String> args, String workDir,
    void Function(String) emit, Duration timeout) async {
  final Process proc;
  try {
    proc = await Process.start(exe, args, workingDirectory: workDir);
  } catch (e) {
    emit('启动失败：$e\n');
    return -1;
  }
  final outDone =
      proc.stdout.transform(utf8.decoder).forEach(emit);
  final errDone =
      proc.stderr.transform(utf8.decoder).forEach(emit);
  final code = await proc.exitCode.timeout(timeout, onTimeout: () {
    proc.kill();
    return -2;
  });
  await Future.wait([outDone, errDone]);
  return code;
}
