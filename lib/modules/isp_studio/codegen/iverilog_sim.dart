/// Icarus Verilog 探测与一键仿真：把 IP 包写临时唯一目录 → `iverilog
/// -g2012` 编译 → `vvp` 运行 → 解析 PASS/FAIL。仿 c_compile.dart 的
/// detectArmGcc + runStep（流式输出 + 超时保护）。无 iverilog 时探测返回
/// null（UI 提示安装，导出功能本身不受影响）。
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

/// iverilog 编译器可执行文件路径（含 `iverilog`/`vvp` 两件套，附带可选的
/// `gtkwave` 波形查看器）。未找到返回 null。
class IverilogToolchain {
  final String iverilog;
  final String vvp;

  /// GTKWave 波形查看器（bleyer.org 的 Icarus Windows 包自带，与 iverilog
  /// 同目录）；未找到为 null，仿真仍可进行只是不自动开波形。
  final String? gtkwave;

  const IverilogToolchain(this.iverilog, this.vvp, {this.gtkwave});
}

/// 随应用打包的 iverilog 目录（相对工作目录，与 tools/ffmpeg 同口径；
/// 安装版中位于 exe 同级 tools/ 下）。须转为绝对路径——仿真子进程会
/// 切换工作目录，相对路径在其下不可解析。
String _bundledToolDir(String rel) => '${Directory.current.path}\\$rel';

/// 探测 iverilog：应用内置 tools/iverilog/bin 优先（安装版开箱即用），
/// 其次 PATH 各目录与常见安装根（C:\iverilog\bin 等）。返回编译器 +
/// 运行器路径（同目录有 gtkwave.exe 一并带上）；[searchDirs] 可注入
/// （测试用）。
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
      final gw = '$dir\\gtkwave.exe';
      return IverilogToolchain(iv, vv,
          gtkwave: File(gw).existsSync() ? gw : null);
    }
  }
  return null;
}

/// 波形查看器：优先 Surfer（现代渲染，拖动/缩放流畅），其次 GTKWave。
class WaveViewer {
  final String exe;
  final bool isSurfer;

  const WaveViewer(this.exe, {required this.isSurfer});
}

/// 探测波形查看器：应用内置 tools/surfer 优先（安装版开箱即用），其次
/// PATH 与 C:\surfer 下的 surfer.exe；最后 iverilog 同目录的 gtkwave.exe。
/// 均未找到返回 null。
WaveViewer? detectWaveViewer(IverilogToolchain? tc) {
  final dirs = [
    _bundledToolDir(r'tools\surfer'),
    ...?Platform.environment['PATH']?.split(';'),
    r'C:\surfer',
  ];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final s = '$dir\\surfer.exe';
    if (File(s).existsSync()) return WaveViewer(s, isSurfer: true);
  }
  final gw = tc?.gtkwave;
  if (gw != null) return WaveViewer(gw, isSurfer: false);
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
/// [openWaveform] 为 true 且检测到 GTKWave 时，仿真结束后自动用 GTKWave
/// 打开 tb dump 出的 wave.vcd（该路径下临时目录保留不删，交给系统回收，
/// 否则 GTKWave 进程尚未读完文件目录就被清掉）。
Future<IpSimResult> runIpSimulation(
  Map<String, String> files, {
  void Function(String chunk)? onOutput,
  IverilogToolchain? iverilog,
  bool openWaveform = true,
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

  // 打开波形时保留临时目录（GTWave 异步读 wave.vcd）。
  var keepDir = false;
  try {
    // 写文件（按文件名，含子目录不含；IP 包为平铺文件）。
    for (final e in files.entries) {
      await File('${dir.path}${Platform.pathSeparator}${e.key}')
          .writeAsString(e.value);
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

    // 仿真结束自动打开波形查看器：优先 Surfer（经 wave.sucl 命令文件自动
    // 加载信号），其次 GTKWave（经 wave.gtkw 保存文件自动加载信号）。
    final vcd = '${dir.path}${Platform.pathSeparator}wave.vcd';
    final viewer = detectWaveViewer(tc);
    if (openWaveform && viewer != null && File(vcd).existsSync()) {
      final sucl = '${dir.path}${Platform.pathSeparator}wave.sucl';
      final gtkw = '${dir.path}${Platform.pathSeparator}wave.gtkw';
      final args = viewer.isSurfer
          ? [vcd, if (File(sucl).existsSync()) ...['--command-file', sucl]]
          : [vcd, if (File(gtkw).existsSync()) gtkw];
      final viewerName = viewer.isSurfer ? 'Surfer' : 'GTKWave';
      try {
        await Process.start(viewer.exe, args,
            workingDirectory: dir.path, mode: ProcessStartMode.detached);
        keepDir = true;
        emit('\n已用 $viewerName 打开波形：$vcd\n');
      } catch (e) {
        emit('\n$viewerName 启动失败：$e\n');
      }
    } else if (openWaveform && viewer == null) {
      emit('\n未检测到波形查看器（Surfer / GTKWave），波形文件未打开\n');
    }

    // 目录删除前捕获波形内容（内嵌波形标签页经回环伺服读取）。
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
    if (!keepDir) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 临时目录清理失败不致命（系统重启后回收）。
      }
    }
  }
}

/// 外部查看器兜底（内嵌 WebView2 不可用时的回退）：把波形与查看器配置
/// 写临时目录，用探测到的查看器打开。临时目录保留不删（查看器异步读
/// 文件，交给系统回收）。返回查看器名；无可用查看器返回 null。
Future<String?> launchWaveformExternally(Uint8List vcd,
    {String? sucl, String? gtkw}) async {
  final viewer = detectWaveViewer(detectIverilog());
  if (viewer == null) return null;
  final dir = await Directory.systemTemp.createTemp('isp_ip_wave_');
  final vcdPath = '${dir.path}${Platform.pathSeparator}wave.vcd';
  await File(vcdPath).writeAsBytes(vcd);
  final List<String> args;
  if (viewer.isSurfer) {
    String? suclPath;
    if (sucl != null) {
      suclPath = '${dir.path}${Platform.pathSeparator}wave.sucl';
      await File(suclPath).writeAsString(sucl);
    }
    args = [vcdPath, if (suclPath != null) ...['--command-file', suclPath]];
  } else {
    String? gtkwPath;
    if (gtkw != null) {
      gtkwPath = '${dir.path}${Platform.pathSeparator}wave.gtkw';
      await File(gtkwPath).writeAsString(gtkw);
    }
    args = [vcdPath, ?gtkwPath];
  }
  await Process.start(viewer.exe, args,
      workingDirectory: dir.path, mode: ProcessStartMode.detached);
  return viewer.isSurfer ? 'Surfer' : 'GTKWave';
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
