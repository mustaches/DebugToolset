/// 电路图网表提取管线（**自研渲染的数据来源**）：把 IP 包 `.v` 文件写工作
/// 目录 → `yosys（read_verilog → hierarchy -top → proc → opt_clean →
/// write_json）` 出 RTL 级层级网表 JSON → 由 [YosysNetlist] 在 Dart 侧解析
/// 成可绘制的模块/单元/引脚/总线，交给 `widgets/netlist_diagram.dart` 自研
/// 布局与绘制。
///
/// 与旧链路（`yosys → node netlistsvg/ELK → SVG → flutter_svg`）的差别：
/// - **不 flatten**：保留模块层级（顶层是端口 + 子模块实例，可下钻），且
///   真实信号名（`n1_hv17`/`n1_hsum`）不被 `$flatten\u_core.` 前缀污染；
/// - **不依赖 Node/ELK/SVG**：布局与绘制全在 Dart 侧，无 `<style>` 块兼容
///   问题、无 ELK 超大画布/1:18 长条问题、悬停高亮与点击无需解析 SVG 命中
///   模型、导出 SVG/PNG 由同一布局模型生成（所见即所得）。
///
/// 只做到 RTL 级（触发器/运算器/选择器/ROM 读口等标准单元符号，适合浏览
/// 生成逻辑），不做 synth/abc 门级映射。
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart' show SvgBytesLoader;
import 'package:vector_graphics/vector_graphics.dart';

import 'netlist_model.dart';

/// 解析 SVG 根元素的 width/height 属性（自研导出的 SVG 必带；外部 SVG 也要
/// 能取尺寸）。解析失败或尺寸非正返回 null。
({double w, double h})? parseSvgSize(String svg) {
  final m = RegExp(r'<svg\b[^>]*>').firstMatch(svg);
  if (m == null) return null;
  final tag = m.group(0)!;
  double? attr(String name) {
    final a = RegExp('$name="([0-9.]+)').firstMatch(tag);
    return a == null ? null : double.tryParse(a.group(1)!);
  }

  final w = attr('width'), h = attr('height');
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  return (w: w, h: h);
}

/// SVG 字节栅格化为 PNG 字节（暗色底铺底，与应用内暗色预览同风格；
/// 按固有尺寸 × [scale] 输出；「导出PNG」用）。经 vector_graphics
/// 离屏绘制，不经 widget 树。
Future<Uint8List> rasterizeSvgPng(
  Uint8List svgBytes, {
  double scale = 2,
}) async {
  final info = await vg.loadPicture(SvgBytesLoader(svgBytes), null);
  final w = (info.size.width * scale).ceil();
  final h = (info.size.height * scale).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF1E1E1E),
    )
    ..scale(scale.toDouble());
  canvas.drawPicture(info.picture);
  info.picture.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Yosys 可执行文件。
class YosysToolchain {
  final String exe;

  const YosysToolchain(this.exe);
}

/// 随应用打包的工具目录（相对工作目录，与 tools/ffmpeg 同口径；安装版中
/// 位于 exe 同级 tools/ 下）。须转为绝对路径——渲染子进程会切换工作目录，
/// 相对路径在其下不可解析。
String _bundledToolDir(String rel) => '${Directory.current.path}\\$rel';

/// 探测 yosys：应用内置 tools/yosys/bin 优先（安装版开箱即用），其次
/// PATH 各目录与 oss-cad-suite 常见安装根。未找到返回 null。
/// [searchDirs] 可注入（测试用）。
YosysToolchain? detectYosys({List<String>? searchDirs}) {
  final dirs =
      searchDirs ??
      [
        _bundledToolDir(r'tools\yosys\bin'),
        ...?Platform.environment['PATH']?.split(';'),
        r'C:\oss-cad-suite\bin',
        r'D:\oss-cad-suite\bin',
      ];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final exe = '$dir\\yosys.exe';
    if (File(exe).existsSync()) return YosysToolchain(exe);
  }
  return null;
}

/// 网表提取结果：解析后的层级网表 + 顶层模块名 + 全程日志。
class SchNetlistResult {
  final bool success;

  /// 解析后的网表（成功时非 null）。
  final YosysNetlist? netlist;

  /// 顶层模块名（用于默认视图与「回顶层」）。
  final String? topModule;

  /// 管线全程日志（写文件清单 + yosys 流式输出）。
  final String log;

  /// 缺失的工具名（'yosys'），未缺失为 null。
  final String? missingTool;

  /// 网表 JSON 产物路径（调试/排查用，成功时非 null）。
  final String? netJsonPath;

  const SchNetlistResult({
    required this.success,
    this.netlist,
    this.topModule,
    required this.log,
    this.missingTool,
    this.netJsonPath,
  });
}

/// 提取电路图网表：把 [files]（IP 包「文件名→内容」）中的 `.v` 写入工作
/// 目录 → yosys 出**层级**网表 JSON（不 flatten）→ Dart 侧解析。
/// [topName] 为顶层模块名（一般取 [schematicTopModule]）；[onOutput] 流式
/// 回调日志。工具链注入参数供测试；缺省探测内置 tools/。
Future<SchNetlistResult> extractSchematicNetlist(
  Map<String, String> files, {
  required String topName,
  void Function(String chunk)? onOutput,
  YosysToolchain? yosys,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final log = StringBuffer();
  void emit(String s) {
    log.write(s);
    onOutput?.call(s);
  }

  final tc = yosys ?? detectYosys();
  if (tc == null) {
    return SchNetlistResult(
      success: false,
      log: '未检测到 yosys（tools/yosys 或 PATH）',
      missingTool: 'yosys',
    );
  }

  // 工作目录：scratch/ip_sch/<top>（开发机）；不可写时（安装版运行于
  // C:\Program Files\）回退 %LOCALAPPDATA%\DebugToolSet\ip_sch（与
  // c_compile.dart 的 cc_win_check 回退同口径）。
  final dir = await _workDir(topName);
  try {
    await Directory(dir).create(recursive: true);
    // 清掉上次提取的残留（同名编组重提）。
    await for (final f in Directory(dir).list()) {
      try {
        await f.delete(recursive: true);
      } catch (_) {}
    }
    final sources = <String>[];
    for (final e in files.entries) {
      if (!e.key.endsWith('.v')) continue;
      await File(
        '$dir${Platform.pathSeparator}${e.key}',
      ).writeAsString(e.value);
      // tb_ 测试台不参与综合。
      if (!e.key.startsWith('tb_')) sources.add(e.key);
    }
    emit('源文件：$sources\n顶层模块：$topName\n\n');

    const netJson = 'net.json';
    // 不 flatten：保留层级（顶层 = 端口 + 子模块实例，可下钻）与真实信号名。
    final yosysScript =
        'read_verilog ${sources.join(' ')}; '
        'hierarchy -top $topName; proc; opt_clean; write_json $netJson';
    emit('> yosys -p "$yosysScript"\n');
    final yosysCode = await _runStep(
      tc.exe,
      ['-p', yosysScript],
      dir,
      emit,
      timeout,
    );
    final netPath = '$dir${Platform.pathSeparator}$netJson';
    if (yosysCode != 0 || !File(netPath).existsSync()) {
      emit('\nyosys 失败（退出码 $yosysCode）\n');
      return SchNetlistResult(success: false, log: log.toString());
    }

    // Dart 侧解析（非逻辑单元——ROM 初始化 / 层次调试 / 形式断言——由
    // 模型层 `NetlistCell.isDrawable` 跳过，无需再改 JSON）。
    final json = await File(netPath).readAsString();
    final YosysNetlist netlist;
    try {
      netlist = YosysNetlist.parse(json);
    } catch (e) {
      emit('\n网表解析失败：$e\n');
      return SchNetlistResult(success: false, log: log.toString());
    }
    final top = netlist.module(topName);
    if (top == null) {
      emit(
        '\n网表里找不到顶层模块 $topName'
        '（现有：${netlist.modules.keys.join('、')}）\n',
      );
      return SchNetlistResult(success: false, log: log.toString());
    }
    emit(
      '解析完成：${netlist.modules.length} 个模块，'
      '顶层 ${top.name}：${top.cells.length} 个单元、'
      '${top.ports.length} 个端口\n',
    );
    return SchNetlistResult(
      success: true,
      netlist: netlist,
      topModule: top.name,
      log: log.toString(),
      netJsonPath: netPath,
    );
  } catch (e) {
    emit('\n提取异常：$e\n');
    return SchNetlistResult(success: false, log: log.toString());
  }
}

/// 从 IP 包文件集选电路图顶层模块：最外层封装优先（Vivado AXI4-Stream
/// `*_axis` > Libero `*_libero` > 通用 `*_top`）；[vendorHint] 非空时优先
/// 对应封装。返回模块名（= 文件基名）。
String schematicTopModule(Map<String, String> files, {String? vendorHint}) {
  String? base(String suffix) {
    for (final name in files.keys) {
      if (name.endsWith(suffix)) return name.substring(0, name.length - 2);
    }
    return null;
  }

  if (vendorHint == 'vivado') {
    final m = base('_axis.v');
    if (m != null) return m;
  } else if (vendorHint == 'libero') {
    final m = base('_libero.v');
    if (m != null) return m;
  }
  return base('_axis.v') ?? base('_libero.v') ?? base('_top.v') ?? 'top';
}

/// 工作目录选择：优先 `工作目录/scratch/ip_sch/<top>`；不可写回退
/// %LOCALAPPDATA%\DebugToolSet\ip_sch\<top>（再退系统临时目录）。
Future<String> _workDir(String topName) async {
  final scratch = Directory(
    '${Directory.current.path}\\scratch\\ip_sch\\$topName',
  );
  try {
    scratch.createSync(recursive: true);
    final probe = File('${scratch.path}\\.probe');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return scratch.path;
  } on FileSystemException {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final alt = localAppData != null
        ? '$localAppData\\DebugToolSet\\ip_sch\\$topName'
        : null;
    if (alt != null) {
      try {
        await Directory(alt).create(recursive: true);
        return alt;
      } catch (_) {}
    }
    final tmp = await Directory.systemTemp.createTemp('isp_ip_sch_');
    return tmp.path;
  }
}

Future<int> _runStep(
  String exe,
  List<String> args,
  String workDir,
  void Function(String) emit,
  Duration timeout,
) async {
  final Process proc;
  try {
    proc = await Process.start(exe, args, workingDirectory: workDir);
  } catch (e) {
    emit('启动失败：$e\n');
    return -1;
  }
  final outDone = proc.stdout.transform(utf8.decoder).forEach(emit);
  final errDone = proc.stderr.transform(utf8.decoder).forEach(emit);
  final code = await proc.exitCode.timeout(
    timeout,
    onTimeout: () {
      proc.kill();
      return -2;
    },
  );
  await Future.wait([outDone, errDone]);
  return code;
}
