/// Yosys + netlistsvg 电路图渲染管线：把 IP 包 `.v` 文件写临时目录 →
/// `yosys（read_verilog → hierarchy → proc → opt_clean → write_json）`
/// 出 RTL 级网表 JSON → `node netlistsvg` 布局生成 SVG。仿
/// iverilog_sim.dart 的探测与进程模式（内置 tools/ 优先，PATH 兜底；
/// 工具缺失时返回 missingTool，UI 提示安装，功能其余部分不受影响）。
///
/// 只做到 RTL 级（触发器/运算器/选择器单元框图，适合浏览生成逻辑），
/// 不做 synth/abc 门级映射。
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

/// Yosys 可执行文件。
class YosysToolchain {
  final String exe;

  const YosysToolchain(this.exe);
}

/// netlistsvg 工具链：Node.js 运行时 + netlistsvg 包目录（其下
/// `node_modules/netlistsvg/bin/netlistsvg.js` 为入口）。
class NetlistsvgToolchain {
  final String nodeExe;

  /// netlistsvg.js 入口的绝对路径。
  final String netlistsvgJs;

  const NetlistsvgToolchain(this.nodeExe, this.netlistsvgJs);
}

/// 随应用打包的工具目录（相对工作目录，与 tools/ffmpeg 同口径；安装版中
/// 位于 exe 同级 tools/ 下）。须转为绝对路径——渲染子进程会切换工作目录，
/// 相对路径在其下不可解析。
String _bundledToolDir(String rel) => '${Directory.current.path}\\$rel';

/// 探测 yosys：应用内置 tools/yosys/bin 优先（安装版开箱即用），其次
/// PATH 各目录与 oss-cad-suite 常见安装根。未找到返回 null。
/// [searchDirs] 可注入（测试用）。
YosysToolchain? detectYosys({List<String>? searchDirs}) {
  final dirs = searchDirs ??
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

/// 探测 netlistsvg：应用内置 tools/netlistsvg（node.exe + npm 安装的包）
/// 优先；其次 PATH 的 node + 工作目录 tools/netlistsvg 的包（node.exe
/// 未拷贝但本机装有 Node.js 的开发机场景）。均未找到返回 null。
NetlistsvgToolchain? detectNetlistsvg({String? packageDir, String? nodeExe}) {
  final pkgDir = packageDir ?? _bundledToolDir(r'tools\netlistsvg');
  final js =
      '$pkgDir\\node_modules\\netlistsvg\\bin\\netlistsvg.js';
  if (!File(js).existsSync()) return null;
  final candidates = [
    ?nodeExe,
    '$pkgDir\\node.exe',
    ...?Platform.environment['PATH']
        ?.split(';')
        .map((d) => d.isEmpty ? '' : '$d\\node.exe'),
  ];
  for (final exe in candidates) {
    if (exe.isNotEmpty && File(exe).existsSync()) {
      return NetlistsvgToolchain(exe, js);
    }
  }
  return null;
}

/// netlistsvg 产出的 SVG 依赖 `<style>` 块 CSS，而 flutter_svg /
/// vector_graphics 不支持样式块：把关键规则内联为呈现属性——
/// 根元素补 `fill="none" stroke="#000"`（可继承，否则 cell 矩形默认
/// 填充成全黑块）；`<text>` 补 fill/stroke/字号字族与 text-anchor
/// （.nodelabel 居中、.inputPortLabel 右对齐）；`.splitjoinBody`
/// （分叉/汇合黑点）补实心填充。
String adaptNetlistsvgSvg(String svg) {
  // 元素标签补属性（兼容自闭合 `/>` 收尾）。
  String amend(String tag, String attrs) {
    final selfClose = tag.endsWith('/>');
    final body = tag.substring(0, tag.length - (selfClose ? 2 : 1));
    return '$body$attrs${selfClose ? '/>' : '>'}';
  }

  var out = svg.replaceFirst('<svg ', '<svg fill="none" stroke="#000" ');
  out = out.replaceAllMapped(RegExp(r'<text\b[^>]*>'), (m) {
    final tag = m.group(0)!;
    final buf = StringBuffer();
    final hasFill = tag.contains('fill:') || tag.contains('fill=');
    if (!hasFill) buf.write(' fill="#000" stroke="none"');
    if (!tag.contains('font-size')) {
      buf.write(' font-size="10" font-weight="bold"');
    }
    if (!tag.contains('font-family')) buf.write(' font-family="monospace"');
    if (!tag.contains('text-anchor')) {
      if (tag.contains('inputPortLabel')) {
        buf.write(' text-anchor="end"');
      } else if (tag.contains('nodelabel')) {
        buf.write(' text-anchor="middle"');
      }
    }
    return amend(tag, buf.toString());
  });
  // 分叉/汇合块实心黑（CSS .splitjoinBody{fill:#000}）。
  out = out.replaceAllMapped(
      RegExp(
          r'<(path|rect|circle|ellipse)\b[^>]*class="[^"]*splitjoinBody[^"]*"[^>]*>'),
      (m) {
    final tag = m.group(0)!;
    if (tag.contains('fill:') || tag.contains('fill=')) return tag;
    return amend(tag, ' fill="#000"');
  });
  return out;
}

/// 电路图渲染结果。
class SchRenderResult {
  final bool success;

  /// 生成的 SVG 内容（成功时非 null）。
  final Uint8List? svgBytes;

  /// 管线全程日志（写文件清单 + 两进程流式输出）。
  final String log;

  /// 缺失的工具名（'yosys' / 'netlistsvg' / 'node'），未缺失为 null。
  final String? missingTool;

  /// 产出的 SVG 文件路径（成功时非 null，供「导出SVG」复用同一份产物）。
  final String? svgPath;

  const SchRenderResult({
    required this.success,
    this.svgBytes,
    required this.log,
    this.missingTool,
    this.svgPath,
  });
}

/// 渲染电路图：把 [files]（IP 包「文件名→内容」）中的 `.v` 写入工作目录 →
/// yosys 出网表 JSON → netlistsvg 出 SVG。[topName] 为顶层模块名（一般取
/// 最外层封装，见 [schematicTopModule]）；[onOutput] 流式回调日志。
/// 工具链注入参数供测试；缺省探测内置 tools/。
Future<SchRenderResult> renderSchematic(
  Map<String, String> files, {
  required String topName,
  void Function(String chunk)? onOutput,
  YosysToolchain? yosys,
  NetlistsvgToolchain? netlistsvg,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final log = StringBuffer();
  void emit(String s) {
    log.write(s);
    onOutput?.call(s);
  }

  final tc = yosys ?? detectYosys();
  if (tc == null) {
    return SchRenderResult(
        success: false,
        log: '未检测到 yosys（tools/yosys 或 PATH）',
        missingTool: 'yosys');
  }
  final nl = netlistsvg ?? detectNetlistsvg();
  if (nl == null) {
    return SchRenderResult(
        success: false,
        log: '未检测到 netlistsvg 或 Node.js（tools/netlistsvg）',
        missingTool: 'netlistsvg');
  }

  // 工作目录：scratch/ip_sch/<top>（开发机）；不可写时（安装版运行于
  // C:\Program Files\）回退 %LOCALAPPDATA%\DebugToolSet\ip_sch（与
  // c_compile.dart 的 cc_win_check 回退同口径）。
  final dir = await _workDir(topName);
  try {
    await Directory(dir).create(recursive: true);
    // 清掉上次渲染的残留（同名编组重渲染）。
    await for (final f in Directory(dir).list()) {
      try {
        await f.delete(recursive: true);
      } catch (_) {}
    }
    final sources = <String>[];
    for (final e in files.entries) {
      if (!e.key.endsWith('.v')) continue;
      await File('$dir${Platform.pathSeparator}${e.key}')
          .writeAsString(e.value);
      // tb_ 测试台不参与综合。
      if (!e.key.startsWith('tb_')) sources.add(e.key);
    }
    emit('源文件：$sources\n顶层模块：$topName\n\n');

    const netJson = 'net.json';
    final yosysScript = 'read_verilog ${sources.join(' ')}; '
        'hierarchy -top $topName; proc; opt_clean; write_json $netJson';
    emit('> yosys -p "$yosysScript"\n');
    final yosysCode = await _runStep(
        tc.exe, ['-p', yosysScript], dir, emit, timeout);
    if (yosysCode != 0 || !File('$dir${Platform.pathSeparator}$netJson').existsSync()) {
      emit('\nyosys 失败（退出码 $yosysCode）\n');
      return SchRenderResult(success: false, log: log.toString());
    }

    const svgName = 'sch.svg';
    emit('\n> node netlistsvg.js $netJson -o $svgName\n');
    final nlCode = await _runStep(
        nl.nodeExe, [nl.netlistsvgJs, netJson, '-o', svgName],
        dir, emit, timeout);
    final svgFile = File('$dir${Platform.pathSeparator}$svgName');
    if (nlCode != 0 || !svgFile.existsSync()) {
      emit('\nnetlistsvg 失败（退出码 $nlCode）\n');
      return SchRenderResult(success: false, log: log.toString());
    }
    final bytes = await svgFile.readAsBytes();
    // netlistsvg 的 SVG 依赖 <style> 块 CSS，flutter_svg/vector_graphics
    // 不支持：内联为呈现属性（见 adaptNetlistsvgSvg）。
    final adapted = utf8.encode(adaptNetlistsvgSvg(utf8.decode(bytes)));
    emit('\n电路图已生成：${svgFile.path}\n');
    return SchRenderResult(
        success: true,
        svgBytes: adapted,
        log: log.toString(),
        svgPath: svgFile.path);
  } catch (e) {
    emit('\n渲染过程出错：$e\n');
    return SchRenderResult(success: false, log: log.toString());
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
  final scratch =
      Directory('${Directory.current.path}\\scratch\\ip_sch\\$topName');
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

Future<int> _runStep(String exe, List<String> args, String workDir,
    void Function(String) emit, Duration timeout) async {
  final Process proc;
  try {
    proc = await Process.start(exe, args, workingDirectory: workDir);
  } catch (e) {
    emit('启动失败：$e\n');
    return -1;
  }
  final outDone = proc.stdout.transform(utf8.decoder).forEach(emit);
  final errDone = proc.stderr.transform(utf8.decoder).forEach(emit);
  final code = await proc.exitCode.timeout(timeout, onTimeout: () {
    proc.kill();
    return -2;
  });
  await Future.wait([outDone, errDone]);
  return code;
}
