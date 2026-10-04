/// 编组 C 代码的应用内编译验证：工具链探测 + 临时目录编译链接。
///
/// 纯 Dart（仅依赖 dart:io / dart:convert），不依赖 Flutter，方便单测。
///
/// 工具链：
/// - X86：本机 MSVC（cl.exe）。探测顺序：vswhere -latest（VS2017+ 安装器
///   自带，版本无关，VS2026 的 "18" 目录命名亦可定位）→ VS 安装目录枚举
///   兜底（任意年份/SKU）→ 历史硬编码根；取最高版本 MSVC 子目录 +
///   Windows Kits 10 最高版本，手工拼 PATH/INCLUDE/LIB 环境（本机
///   vcvars64.bat 损坏，不能走 vcvars；且手工注入环境对 Process.run 更
///   可控）。scripts/c_syntax_check.bat 等同思路。
/// - ARM：arm-none-eabi-gcc。查 PATH 各目录与 GNU Arm Embedded Toolchain
///   常见安装根。
/// 探测不到时由对话框让用户手填路径，手动值写入 [sessionCompilerPaths]
/// 在本次会话（进程存活期间）内记住。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'c_ident.dart';

/// 编译目标机器。
enum CCompileTarget { x86, arm, linuxCross }

/// 会话内记住的手动编译器路径（对话框中用户改动后写入；进程级，不落盘）。
final Map<CCompileTarget, String> sessionCompilerPaths = {};

/// Linux 交叉编译器 WSL 探测结果的会话缓存（进程级，不落盘）：WSL 探测
/// 可能耗时数十秒（冷启动），进程存活期内只探一次，之后打开编译对话框
/// 直接呈现上次列表。null=尚未探测；空表=探过但未命中（同样缓存，
/// 避免无 WSL 的机器每次开对话框都空等）。
List<CToolchain>? sessionLinuxCrossWslToolchains;

/// 探测到（或由手动路径推导出）的工具链。
class CToolchain {
  final CCompileTarget target;

  /// 编译器可执行文件绝对路径（cl.exe / arm-none-eabi-gcc.exe）。
  final String compilerPath;

  /// 需要注入/覆盖的进程环境变量。MSVC 为 INCLUDE/LIB/PATH，其中 PATH
  /// 语义为「前置到现有 PATH」（cl 需要同目录的 link.exe 与 mspdb 等 dll）。
  final Map<String, String> env;

  const CToolchain(this.target, this.compilerPath, this.env);
}

/// 判定一段字节是否像 UTF-16LE（wsl.exe 自身消息的特征：文本以 ASCII
/// 为主时奇数位（UTF-16 高字节）大量为 NUL）。
bool looksLikeUtf16Le(List<int> bytes) {
  if (bytes.length < 4) return false;
  var nul = 0;
  final n = math.min(bytes.length, 128);
  for (var i = 1; i < n; i += 2) {
    if (bytes[i] == 0) nul++;
  }
  return nul >= n ~/ 4;
}

/// UTF-16LE 解码（去 BOM；dart:convert 无现成 UTF-16 codec）。
/// 尾部奇数字节（块边界截断）丢弃。
String decodeUtf16Le(List<int> bytes) {
  var b = bytes;
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) b = b.sublist(2);
  final units = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    units.add(b[i] | (b[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

/// 目录下版本号子目录中取最高者（字符串序末位，与 .bat 的 for /d 覆盖
/// 取值同效）；目录不存在或为空返回 null。
String? _highestSubdir(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return null;
  final subs = [
    for (final e in dir.listSync())
      if (e is Directory) e.path,
  ]..sort();
  return subs.isEmpty ? null : subs.last;
}

String _baseName(String path) {
  final norm = path.replaceAll('/', '\\');
  final i = norm.lastIndexOf('\\');
  return i < 0 ? norm : norm.substring(i + 1);
}

/// 由 MSVC 版本目录拼 INCLUDE/LIB/PATH 环境；Windows SDK 缺失返回 null。
Map<String, String>? _msvcEnv(
  String msvc, {
  String sdkIncludeRoot = r'C:\Program Files (x86)\Windows Kits\10\Include',
  String sdkLibRoot = r'C:\Program Files (x86)\Windows Kits\10\Lib',
}) {
  final sdkVerDir = _highestSubdir(sdkIncludeRoot);
  if (sdkVerDir == null) return null;
  final sdkVer = _baseName(sdkVerDir);
  return {
    'PATH': '$msvc\\bin\\Hostx64\\x64',
    'INCLUDE':
        '$msvc\\include;$sdkIncludeRoot\\$sdkVer\\ucrt;$sdkIncludeRoot\\$sdkVer\\um;$sdkIncludeRoot\\$sdkVer\\shared',
    'LIB':
        '$msvc\\lib\\x64;$sdkLibRoot\\$sdkVer\\ucrt\\x64;$sdkLibRoot\\$sdkVer\\um\\x64',
  };
}

/// 枚举本机 VS 安装的 MSVC 工具目录候选根（...\VC\Tools\MSVC）。
/// 顺序：vswhere -latest（VS2017+ 安装器自带，版本无关——VS2026 的
/// "18" 目录命名也能正确定位最新安装）→ VS 目录枚举兜底（任意年份/
/// SKU；年份目录字符串排序在新旧命名混用时不可靠，仅作兜底，多版本
/// 并存时以 vswhere 为准）→ 两个历史硬编码根（保持旧行为）。
List<String> enumerateVsMsvcRoots() {
  final roots = <String>[];
  final pf86 = Platform.environment['ProgramFiles(x86)'] ??
      r'C:\Program Files (x86)';
  // 1. vswhere。
  final vswhere = '$pf86\\Microsoft Visual Studio\\Installer\\vswhere.exe';
  if (File(vswhere).existsSync()) {
    try {
      final r = Process.runSync(vswhere, const [
        '-latest',
        '-products', '*',
        '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath',
      ]);
      if (r.exitCode == 0) {
        final p = '${r.stdout}'.trim();
        if (p.isNotEmpty) roots.add('$p\\VC\\Tools\\MSVC');
      }
    } catch (_) {
      // vswhere 执行失败时退回目录枚举。
    }
  }
  // 2. 目录枚举兜底：<ProgramFiles>\Microsoft Visual Studio\<年份>\<SKU>。
  for (final base in [
    r'C:\Program Files\Microsoft Visual Studio',
    '$pf86\\Microsoft Visual Studio',
  ]) {
    final bd = Directory(base);
    if (!bd.existsSync()) continue;
    final years = [
      for (final e in bd.listSync())
        if (e is Directory) e.path
    ]..sort();
    for (final y in years.reversed) {
      final skus = [
        for (final e in Directory(y).listSync())
          if (e is Directory) e.path
      ]..sort();
      for (final s in skus.reversed) {
        roots.add('$s\\VC\\Tools\\MSVC');
      }
    }
  }
  // 3. 历史硬编码根。
  roots.addAll(const [
    r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC',
    r'C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC',
  ]);
  return roots;
}

/// 探测本机 MSVC 工具链；未找到返回 null。
/// [vsRoots] / [sdkIncludeRoot] / [sdkLibRoot] 可注入（测试用临时目录）；
/// vsRoots 缺省为 [enumerateVsMsvcRoots] 的全机枚举结果。
CToolchain? detectMsvc({
  List<String>? vsRoots,
  String sdkIncludeRoot = r'C:\Program Files (x86)\Windows Kits\10\Include',
  String sdkLibRoot = r'C:\Program Files (x86)\Windows Kits\10\Lib',
}) {
  for (final root in vsRoots ?? enumerateVsMsvcRoots()) {
    final msvc = _highestSubdir(root);
    if (msvc == null) continue;
    final cl = '$msvc\\bin\\Hostx64\\x64\\cl.exe';
    if (!File(cl).existsSync()) continue;
    final env = _msvcEnv(msvc,
        sdkIncludeRoot: sdkIncludeRoot, sdkLibRoot: sdkLibRoot);
    if (env == null) continue;
    return CToolchain(CCompileTarget.x86, cl, env);
  }
  return null;
}

/// 探测 arm-none-eabi-gcc；未找到返回 null。
/// [searchDirs] 可注入（测试用）；缺省为 PATH 各目录 + GNU Arm Embedded
/// Toolchain 常见安装根（其下取最高版本子目录的 bin），以及 xpack
/// 用户级安装根（%LOCALAPPDATA%\arm-gnu-toolchain，免管理员权限）。
CToolchain? detectArmGcc({List<String>? searchDirs}) {
  const exe = 'arm-none-eabi-gcc.exe';
  final dirs = searchDirs ??
      [
        ...?Platform.environment['PATH']?.split(';'),
        r'C:\Program Files (x86)\GNU Arm Embedded Toolchain',
        r'C:\Program Files (x86)\GNU Tools ARM Embedded',
        if (Platform.environment['LOCALAPPDATA'] != null)
          '${Platform.environment['LOCALAPPDATA']}\\arm-gnu-toolchain',
      ];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    // 直接是 bin 目录的情况（PATH 条目）。
    final direct = '$dir\\$exe';
    if (File(direct).existsSync()) {
      return CToolchain(CCompileTarget.arm, direct, const {});
    }
    // 安装根的情况：取最高版本子目录的 bin。
    final sub = _highestSubdir(dir);
    if (sub != null) {
      final inSub = '$sub\\bin\\$exe';
      if (File(inSub).existsSync()) {
        return CToolchain(CCompileTarget.arm, inSub, const {});
      }
    }
  }
  return null;
}

/// 探测 Linux 交叉编译 gcc（两种用户工具链），返回全部命中（多编译器
/// 下拉选择用）；未找到返回空表。
/// 命名规则：
/// - aarch64-mix210-linux：精确名 `aarch64-mix210-linux-gcc.exe`；
/// - riscv32-cfg5-musl-<可变段>-elf：前缀 `riscv32-cfg5-musl-`、
///   后缀 `-elf-gcc.exe`（中间版本/配置段可变，按前后缀匹配）。
/// [searchDirs] 可注入（测试用）；缺省为 PATH 各目录。
List<CToolchain> detectLinuxCrossGccAll({List<String>? searchDirs}) {
  const aarch64Exe = 'aarch64-mix210-linux-gcc.exe';
  const riscvPrefix = 'riscv32-cfg5-musl-';
  const riscvSuffix = '-elf-gcc.exe';
  final dirs = searchDirs ?? [...?Platform.environment['PATH']?.split(';')];
  final out = <CToolchain>[];
  final seen = <String>{};
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final e in d.listSync()) {
      if (e is! File) continue;
      final name = _baseName(e.path);
      if ((name == aarch64Exe ||
              (name.startsWith(riscvPrefix) && name.endsWith(riscvSuffix))) &&
          seen.add(e.path)) {
        out.add(CToolchain(CCompileTarget.linuxCross, e.path, const {}));
      }
    }
  }
  return out;
}

/// 单命中版（[detectLinuxCrossGccAll] 的首项）；未找到返回 null。
CToolchain? detectLinuxCrossGcc({List<String>? searchDirs}) =>
    detectLinuxCrossGccAll(searchDirs: searchDirs).firstOrNull;

/// WSL 侧 gcc 文件名是否匹配两种工具链命名（WSL 内无 .exe 后缀）。
bool _isWslCrossGccName(String name) =>
    name == 'aarch64-mix210-linux-gcc' ||
    (name.startsWith('riscv32-cfg5-musl-') && name.endsWith('-elf-gcc'));

/// 解析 'wsl:' 前缀的编译器路径：
/// `'wsl:<WSL内路径>'`（默认发行版）或 `'wsl:<发行版>:<WSL内路径>'`。
/// 非 wsl 前缀或形态不合法（WSL 路径非绝对）返回 null。
({String? distro, String wslPath})? parseWslCompilerPath(String compilerPath) {
  if (!compilerPath.startsWith('wsl:')) return null;
  final rest = compilerPath.substring(4);
  if (rest.startsWith('/')) return (distro: null, wslPath: rest);
  final i = rest.indexOf(':');
  if (i <= 0) return null;
  final distro = rest.substring(0, i);
  final path = rest.substring(i + 1);
  if (distro.isEmpty || !path.startsWith('/')) return null;
  return (distro: distro, wslPath: path);
}

/// Windows 绝对路径 → WSL /mnt 路径（盘符小写、反斜杠转正斜杠）：
/// `C:\Users\x` → `/mnt/c/Users/x`；无盘符原样返回。
String windowsToWslPath(String winPath) {
  final p = winPath.replaceAll('\\', '/');
  final m = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(p);
  if (m == null) return p;
  return '/mnt/${m[1]!.toLowerCase()}/${m[2]}';
}

/// 确认 WSL 虚拟机就绪（阶段一）：轻量命令 `wsl.exe [-d 发行版] -- true`，
/// 独立宽超时（冷启动可能数十秒）。[distro] 为 null 时用默认发行版。
/// [runner] 测试注入用（缺省真实 Process.run）；未安装 wsl / 无发行版 /
/// 超时未就绪均返回 false。
Future<bool> ensureWslReady({
  String? distro,
  Duration timeout = const Duration(seconds: 60),
  Future<ProcessResult> Function(String exe, List<String> args,
      {Encoding? stdoutEncoding, Encoding? stderrEncoding})? runner,
}) async {
  final run = runner ??
      (exe, args, {stdoutEncoding, stderrEncoding}) => Process.run(exe, args,
          stdoutEncoding: stdoutEncoding, stderrEncoding: stderrEncoding);
  try {
    final r = await run(
      'wsl.exe',
      [if (distro != null) ...['-d', distro], '--', 'true'],
      stdoutEncoding: latin1,
      stderrEncoding: latin1,
    ).timeout(timeout);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// WSL 侧探测 Linux 交叉编译 gcc（Windows PATH 未命中时的补充），返回
/// 全部命中（多发行版/多编译器下拉选择用），两阶段：
/// 阶段一「WSL 启动」——[ensureWslReady] 确认虚拟机就绪（[startupTimeout]
/// 独立宽超时，覆盖冷启动）；阶段二「探测编译器」——就绪后经
/// `wsl.exe -l -q` 列发行版（输出为 UTF-16LE，按去 NUL 字节处理）逐个
/// 探测并合并，[timeout] 从就绪后起算。
/// 命中返回 `'wsl:<发行版>:<WSL路径>'` 形式的 CToolchain 表；阶段一失败或
/// 阶段二超时未命中均返回空表。[onPhase] 阶段回调（'startup'/'detect'，
/// 对话框切换等待文案用）。
Future<List<CToolchain>> detectLinuxCrossGccWslAll({
  Duration startupTimeout = const Duration(seconds: 60),
  Duration timeout = const Duration(seconds: 10),
  void Function(String phase)? onPhase,
}) async {
  onPhase?.call('startup');
  if (!await ensureWslReady(timeout: startupTimeout)) return const [];
  onPhase?.call('detect');
  try {
    return await _detectLinuxCrossGccWslAll().timeout(timeout);
  } catch (_) {
    return const [];
  }
}

/// 单命中版（[detectLinuxCrossGccWslAll] 的首项）；未找到返回 null。
Future<CToolchain?> detectLinuxCrossGccWsl({
  Duration startupTimeout = const Duration(seconds: 60),
  Duration timeout = const Duration(seconds: 10),
  void Function(String phase)? onPhase,
}) async =>
    (await detectLinuxCrossGccWslAll(
      startupTimeout: startupTimeout,
      timeout: timeout,
      onPhase: onPhase,
    ))
        .firstOrNull;

Future<List<CToolchain>> _detectLinuxCrossGccWslAll() async {
  // 探测命令只写字面路径、不引用 shell 变量：wsl.exe 从 Windows 传参
  // 会经一层 shell 展开（$ 变量被吃掉），~ 由该层展开为用户家目录。
  // find 的 -name 直接支持 riscv 中间段通配；不存在的根目录报错被
  // 2>/dev/null 吞掉（exit code 可能非 0，按输出解析而非退出码）。
  // -maxdepth 4 + -type l：覆盖 ~/toolchains/<套件>/<工具链>/bin 的
  // 多层布局与符号链接形态（install.sh 创建的版本化软链）。
  // 输出按 latin1 解码并去 NUL：wsl 自身消息可能是 UTF-16LE。
  const findCmd = 'find ~/toolchains/bin ~/toolchains /opt /usr/local/bin '
      '-maxdepth 4 \\( -type f -o -type l \\) '
      '\\( -name aarch64-mix210-linux-gcc -o '
      '-name "riscv32-cfg5-musl-*-elf-gcc" \\) 2>/dev/null';
  Future<List<CToolchain>> probe(String? distro) async {
    try {
      final r = await Process.run(
        'wsl.exe',
        [if (distro != null) ...['-d', distro], '--', 'bash', '-c', findCmd],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      final out = <CToolchain>[];
      for (final line
          in '${r.stdout}'.replaceAll('\x00', '').split('\n')) {
        final path = line.trim();
        if (path.isEmpty || !_isWslCrossGccName(_baseName(path))) continue;
        out.add(CToolchain(
          CCompileTarget.linuxCross,
          distro == null ? 'wsl:$path' : 'wsl:$distro:$path',
          const {},
        ));
      }
      return out;
    } catch (_) {/* 该发行版不可用，按未命中处理 */}
    return const [];
  }

  // 列发行版逐个探测（跳过 docker-desktop 内部发行版）；列不出时回退
  // 只探默认发行版。
  List<String>? distros;
  try {
    final listed = await Process.run('wsl.exe', ['-l', '-q'],
        stdoutEncoding: latin1, stderrEncoding: latin1);
    if (listed.exitCode == 0) {
      distros = [
        for (final l in '${listed.stdout}'.replaceAll('\x00', '').split('\n'))
          if (l.trim().isNotEmpty && !l.trim().startsWith('docker-desktop'))
            l.trim(),
      ];
    }
  } catch (_) {/* 无 wsl，按未命中处理 */}
  final results = <CToolchain>[];
  if (distros == null) {
    results.addAll(await probe(null));
  } else {
    for (final distro in distros) {
      results.addAll(await probe(distro));
    }
  }
  // 去重：~/toolchains/bin 多为指向 ~/toolchains/<工具链>/bin 的软链，
  // maxdepth 4 深搜会同发行版内重复命中同一编译器——按「发行版 +
  // basename」分组保留最短路径（bin 链接目录优先）。
  final byKey = <String, CToolchain>{};
  for (final tc in results) {
    final wsl = parseWslCompilerPath(tc.compilerPath);
    final key = '${wsl?.distro ?? ''}|${_baseName(tc.compilerPath)}';
    final prev = byKey[key];
    if (prev == null || tc.compilerPath.length < prev.compilerPath.length) {
      byKey[key] = tc;
    }
  }
  return byKey.values.toList();
}

/// 由手动指定的编译器路径推导工具链：cl.exe 若处于标准布局
///（...\VC\Tools\MSVC\<ver>\bin\Hostx64\x64\cl.exe）则自动推导
/// INCLUDE/LIB/PATH 环境；其余情况（含 gcc）不带额外环境，依赖用户
/// 自行保证编译器可用。
CToolchain toolchainFromCompilerPath(CCompileTarget target, String path) {
  if (target == CCompileTarget.x86) {
    final norm = path.replaceAll('/', '\\');
    const tail = '\\bin\\Hostx64\\x64\\cl.exe';
    if (norm.endsWith(tail)) {
      final msvc = norm.substring(0, norm.length - tail.length);
      final env = _msvcEnv(msvc);
      if (env != null) return CToolchain(target, path, env);
    }
  }
  return CToolchain(target, path, const {});
}

/// 编译执行器签名（GroupCodePage 的注入点：测试可替换为立即返回的假实现）。
typedef GroupCompileRunner = Future<CCompileResult> Function(
  Map<String, String> files,
  CCompileTarget target, {
  String? topName,
  String? compilerPath,
  void Function(String chunk)? onOutput,
});

/// 编译验证 stub main.c 的内容生成（compileGroupCFiles 与查看代码页
/// 「临时main调用（不导出）」分组共用）。
///
/// -Waddress 取舍：旧写法 `fn != 0` 直接拿函数地址与 0 比较，gcc 报
/// "address will never be NULL"。现用 volatile 函数指针变量——volatile
/// 读强制物化入口地址（top 层符号必须被链接器解析，验证目的不变），
/// 变量与 0 比较在 gcc/MSVC 两侧都无告警。
/// [target] 决定形态：仅 ARM 版带裸机 syscall 桩（优先于 libnosys 带
/// .warning 的默认桩）；X86 与 Linux 交叉版不带（即通用形态，查看代码
/// 页展示用）。
String stubMainCSource({String? topName, required CCompileTarget target}) {
  final stubHeader = topName != null
      ? '/* 链接验证桩：volatile 读 top 层入口函数地址，强制解析全部符号。 */\n'
          '#include "$topName.h"\n\n'
      : '/* 链接验证桩（无 top 层入口，仅验证文件集合可编译链接）。 */\n';
  // 裸机 syscall 桩（仅 ARM）：在目的文件中定义，优先于 libnosys 里带
  // .warning 指令的默认桩（消除链接期 "_close is not implemented and
  // will always fail" 等警告）。全部返回 -1 / 空转，仅供链接验证，
  // 产物不运行。X86(MSVC) 不带这些桩，避免与 CRT 符号冲突。
  const armSyscallStubs = '''
/* 裸机 syscall 桩（优先于 libnosys 默认桩，消除 .warning 链接警告）。 */
int _close(int fd) { (void)fd; return -1; }
int _lseek(int fd, int off, int whence) {
  (void)fd; (void)off; (void)whence; return -1;
}
int _read(int fd, void *buf, int len) {
  (void)fd; (void)buf; (void)len; return -1;
}
int _write(int fd, const void *buf, int len) {
  (void)fd; (void)buf; (void)len; return -1;
}
int _fstat(int fd, void *st) { (void)fd; (void)st; return -1; }
int _isatty(int fd) { (void)fd; return -1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; return -1; }
int _getpid(void) { return -1; }
void *_sbrk(int incr) { (void)incr; return (void *)-1; }
void _exit(int status) { (void)status; for (;;) { } }

''';
  final stubMain = topName != null
      ? 'int main(void) {\n'
          '  void (*volatile entry)(void) = (void (*)(void))${topName}_run;\n'
          '  return entry == 0 ? 1 : 0;\n'
          '}\n'
      : 'int main(void) { return 0; }\n';
  return stubHeader +
      (target == CCompileTarget.arm ? armSyscallStubs : '') +
      stubMain;
}

/// Win32 可运行验证程序（main_win.c）的内容生成——真正可运行的前后效果
/// 对比窗口（与 [stubMainCSource] 的纯链接验证桩同口径：不随导出物分发，
/// 查看代码页「Win32 可运行验证（不导出）」分组展示）。
///
/// 形态：纯 Win32 + CRT（C99，零第三方依赖、零资源文件）。
/// - 播放内置测试图案动画（整数运算，Dart 侧可逐位复刻，供对拍）；
///   `--bmp <文件|目录>` 覆盖为 24bpp BMP 单图/序列；
/// - 并列模式（左原图/右处理后）与单视频模式（整幅单路）实时互切；
///   单视频模式按钮/空格在 原图⇄处理后 间硬切；
/// - 批模式 `--frames N --dump-hash`：不开窗逐帧跑管线，输出处理后帧的
///   FNV-1a 哈希（机器对拍用）；
/// - 帧格式 [inFormat]/[outFormat] 仅支持 'rgb'/'hsl'（HSL 端口经
///   isp_csc_common.h 单像素转换装帧/显示，与 Dart rgbToHsl/hslToRgb
///   逐位一致）；
/// - [hasScratch]：top 层 run 是否带 scratch 参数（整帧版恒有；黑盒
///   行级流水版在无需环形缓冲时没有——调用方按生成的 top .h 判定），
///   没有时 run 调用与 scratch 分配相应省略。
String stubMainWinSource({
  required String topName,
  String inFormat = 'rgb',
  String outFormat = 'rgb',
  bool hasScratch = true,
  int maxValue = 255,
}) {
  assert(inFormat == 'rgb' || inFormat == 'hsl');
  assert(outFormat == 'rgb' || outFormat == 'hsl');
  final macro = cMacroPrefix(topName);
  final needCsc = inFormat == 'hsl' || outFormat == 'hsl';
  // 输入装帧（RGB888 → 管线输入帧格式，先按量化域 MAXV 缩放——MAXV=255
  // 时为恒等直通；LUT 模式节点的查表快路径要求运行时 max_value 与烘焙
  // 域一致，故 MAXV 随编组位深传入而非硬编码 255）。OpenMP 逐像素并行
  //（4K 单线程的 HSL 逐像素转换实测 ~650ms/帧，是批模式吞吐大头；逐像
  // 素独立，并行结果与串行逐位一致）。
  final packBody = inFormat == 'hsl'
      ? '''
#pragma omp parallel for
    for (i = 0; i < n; i++) {
      const int r = g_rgb_src[i * 3] * MAXV / 255;
      const int g = g_rgb_src[i * 3 + 1] * MAXV / 255;
      const int b = g_rgb_src[i * 3 + 2] * MAXV / 255;
      isp_csc_rgb_to_hsl_px(r, g, b, MAXV, 1.0 / MAXV, g_in + i * 3);
    }'''
      : '''
    for (i = 0; i < n * 3; i++) {
      g_in[i] = (uint16_t)(g_rgb_src[i] * MAXV / 255);
    }''';
  // 输出解包（管线输出帧格式 → RGB888 显示帧）。
  final unpackBody = outFormat == 'hsl'
      ? '''
#pragma omp parallel for
    for (i = 0; i < n; i++) {
      int r, g, b;
      isp_csc_hsl_to_rgb_px(g_out[i * 3], g_out[i * 3 + 1], g_out[i * 3 + 2],
                            MAXV, 1.0 / MAXV, &r, &g, &b);
      g_rgb_dst[i * 3] = (unsigned char)(r * 255 / MAXV);
      g_rgb_dst[i * 3 + 1] = (unsigned char)(g * 255 / MAXV);
      g_rgb_dst[i * 3 + 2] = (unsigned char)(b * 255 / MAXV);
    }'''
      : '''
    for (i = 0; i < n * 3; i++) {
      g_rgb_dst[i] = (unsigned char)(g_out[i] * 255 / MAXV);
    }''';
  // 融合装帧/解包（窗口模式管线工作线程）：与 packBody/unpackBody +
  // fill_dib 同数学口径逐位一致，只省整帧中转（g_rgb_src/g_rgb_dst 与
  // fill_dib 的 RGB↔BGR 换序）：rgb24/nv12 源一趟出 g_in + 原图 DIB，
  // 解包直写 BGR 到处理后 DIB。px 为像素序（size_t），r/g/b 为已钳位
  // int，d 为 DIB 行指针、x 为列。
  final packFusedPx = inFormat == 'hsl'
      ? '''isp_csc_rgb_to_hsl_px(r * MAXV / 255, g * MAXV / 255,
                            b * MAXV / 255, MAXV, 1.0 / MAXV, in + px * 3);'''
      : '''in[px * 3] = (uint16_t)(r * MAXV / 255);
        in[px * 3 + 1] = (uint16_t)(g * MAXV / 255);
        in[px * 3 + 2] = (uint16_t)(b * MAXV / 255);''';
  final unpackFusedPx = outFormat == 'hsl'
      ? '''{
        int r, g, b;
        isp_csc_hsl_to_rgb_px(out[px * 3], out[px * 3 + 1], out[px * 3 + 2],
                              MAXV, 1.0 / MAXV, &r, &g, &b);
        d[x * 3] = (unsigned char)(b * 255 / MAXV);
        d[x * 3 + 1] = (unsigned char)(g * 255 / MAXV);
        d[x * 3 + 2] = (unsigned char)(r * 255 / MAXV);
      }'''
      : '''d[x * 3] = (unsigned char)(out[px * 3 + 2] * 255 / MAXV);
      d[x * 3 + 1] = (unsigned char)(out[px * 3 + 1] * 255 / MAXV);
      d[x * 3 + 2] = (unsigned char)(out[px * 3] * 255 / MAXV);''';
  return '''/* Win32 可运行验证程序（自动生成，不随导出物分发）。
 * 并列模式（左原图/右处理后）与单视频模式（整幅单路，按钮/空格硬切）
 * 实时互切；底部进度条点击/拖动跳转（暂停中也可；按下/拖动走关键帧级
 * 低分辨率直显预览——预览工作线程解码（内嵌 libav 常驻解码器优先，回退
 * 子进程单帧），UI 只投递最新位置故快速拖动不卡；并列模式只换左侧画面、
 * 右侧处理后画面冻结置灰，单视频模式整幅预览；松开后精确 seek + 全尺寸
 * 管线处理恢复前后对比）+ 状态栏（分辨率/实时帧率/播放位置）。
 * 帧来源：--video <文件> --ffmpeg <ffmpeg路径>（子进程管道流式解码
 * rgb24，-ss 重启实现跳转，EOF 循环重播）优先；--bmp <文件|目录>
 * 24bpp BMP 序列次之；皆无则内置测试图案。
 * 窗口模式视频解码优先尝试 CUDA 硬解链（NVDEC 解码 + scale_cuda GPU
 * 缩放，首帧读取失败自动回退软解，状态栏标注 GPU/SW，--swdec 强制
 * 软解）；批模式恒软解。
 * 批模式 --frames N --dump-hash 输出每帧处理后 FNV-1a 哈希（机器对拍用）。
 * 控制条显示上一帧管线本体耗时（处理 Xms，不含读流/装帧/解包；分段
 * 均值口径见批模式收尾的 timing 行）。
 * 窗口模式为管线工作线程模型：工作线程独占解码流消费与处理（帧环取
 * 帧+融合装帧 → 管线 → 融合解包 + 三缓冲 DIB 发布），UI 线程只绘制/
 * 输入——旧形态 advance/draw 同在 UI 线程串行，4K60 窗口实测 kept 仅
 * ~32fps（UI 线程每帧 ~25ms 工作超 16.7ms 预算 + SetTimer 17ms 节拍
 * 双封顶，两组不同负载墙钟完全一致钉在 2×15.6ms 滴答）。走帧由工作
 * 线程按墙钟到期驱动（高分辨率可等待定时器，不依赖 SetTimer 粒度），
 * 丢帧对齐墙钟同旧口径：解码不跳读、落后超过 1 帧时中间帧只解码不处
 * 理（帧间依赖使解码无法跳读），运动速度即源帧率（kept 帧率随吞吐）；
 * 解码经读者线程 + RING_N 帧预读环与工作线程重叠，跳帧退化为环内丢
 * 弃（不做转换/拷贝）；强缩小显示走 omp 盒滤波预缩小 + COLORONCOLOR
 *（替代每帧两路 HALFTONE，消除 4K 播放显示瓶颈）。
 * 融合装帧/解包（与 pack_input/unpack_output + fill_dib 逐位一致，
 * 只省整帧中转搬运）：GPU 链 nv12 槽位一趟转 g_in + 原图 DIB（免
 * rgb24 中转与 24MB 槽位拷贝）；软解/BMP/图案 rgb24 同趟出 g_in +
 * DIB；解包 hsl/rgb 直写 BGR DIB（免 g_rgb_dst 中转）。批模式保持
 * 旧四段路径（read/pack/run/unpack，哈希口径不变）。
 * OpenMP 线程数封顶 16（大核数机器上 vcomp 空转自旋会占满全机核），
 * ffmpeg 解码/滤镜线程封顶 FF_DEC_THREADS（默认 auto 按逻辑核数开
 * 线程，大核数机器上软解重载源会起上百个解码线程把内存带宽打满），
 * 进程与 ffmpeg 子进程低于普通优先级（软解重载源不拖垮桌面）。
 */
#include "$topName.h"

#include <math.h>
#include <stdint.h> /* intptr_t（预览工作线程参数） */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <omp.h>     /* omp_set_num_threads：vcomp 工作线程封顶（WinMain），
                        编译须带 /openmp（buildWinVerifyApp 恒带） */
#include <windows.h>
#include <timeapi.h> /* timeBeginPeriod：把系统定时器分辨率提到 1ms，
                        否则 60fps 走帧不可达（默认 ~15.6ms 粒度） */
${needCsc ? '\n#include "isp_csc_common.h" /* HSL 端口装帧/显示转换 */\n' : ''}
#define DEFW 640
#define DEFH 360
#define MAXV $maxValue
#define BAR_H 32
#define PROG_H 14
#define STATUS_H 22
#define WM_APP_FRAME (WM_APP + 1) /* 管线工作线程 → UI：新帧已发布 */
/* Win10 1803+ 高分辨率可等待定时器（旧 SDK 无此宏；创建失败回退事件等
 * 待，见 wait_ms）。 */
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif
/* ffmpeg 解码（-threads）与滤镜（-filter_threads）线程封顶：默认 auto
 * 按逻辑核数开线程，112 核机上软解 4K Rext 会起上百个解码线程打满内
 * 存带宽（内存硬件处于边缘状态的机器因此被压出 WHEA 可更正错误风暴
 * 乃至硬挂起）。线程数不影响解码像素结果，批模式哈希对拍口径不变。 */
#define FF_DEC_THREADS 8

static int g_w = DEFW, g_h = DEFH;
static int g_frames = 120; /* 测试图案动画帧数（循环） */
static unsigned char *g_rgb_src = NULL, *g_rgb_dst = NULL;
static int g_ff_nv12 = 0; /* 当前解码流是否 nv12（GPU 链恒为 1，帧环槽位
                             只用前 1.5B/px；消费时转 rgb24） */
static uint16_t *g_in = NULL, *g_out = NULL;
static void *g_scratch = NULL;
static size_t g_scratch_bytes = 0;
static int g_frame = 0;
static int g_single_mode = 0;    /* 0=并列 1=单视频 */
static int g_show_processed = 1; /* 单视频当前路：0=原图 1=处理后 */
static volatile int g_playing = 1; /* UI 写、管线工作线程读 */
static DWORD g_proc_ms = 0; /* 上一帧管线 {TOP}_run 本体耗时（控制条显示） */
/* ---- 进度条拖动（播放/暂停中均可，不改变播放状态）---- */
static volatile int g_dragging = 0; /* 拖动中（SetCapture 跟踪鼠标；UI 写、
                                       管线工作线程读——拖动期间工作线程暂
                                       停走帧，见 pipe_worker） */
static double g_drag_frac = 0.0; /* 拖动中的显示位置（未节流，即时跟随） */
static int g_drag_moved = 0;     /* 本次拖动移动过（纯点击松开不重复 seek） */
static DWORD g_last_seek = 0;    /* 图案/BMP 拖动跳帧节流（~150ms/次；
                                    视频拖动由预览工作线程天然限速） */
static CRITICAL_SECTION g_prev_cs; /* 预览 DIB 读写锁（预览工作线程 ↔
                                      绘制互斥；WinMain 初始化） */
/* ---- 帧三缓冲（管线工作线程写 / UI 线程读，SPSC 免锁免撕裂）----
 * 下标恒为 {0,1,2} 的排列：worker 写 g_pb_write，完成后与 g_pb_ready
 * 原子交换发布；UI 绘制前与 g_pb_show 原子交换认领最新。worker 写的
 * 永远不是 UI 正显示的那组。 */
#define PBUF_N 3
static HBITMAP g_pb_src[PBUF_N], g_pb_dst[PBUF_N];
static unsigned char *g_pb_src_bits[PBUF_N], *g_pb_dst_bits[PBUF_N];
static volatile LONG g_pb_ready = 0; /* 最新完成帧下标 */
static LONG g_pb_show = 1;           /* UI 私有：当前显示下标 */
static LONG g_pb_write = 2;          /* worker 私有：写入下标 */
/* ---- 管线工作线程（WinMain 启动，WM_DESTROY 汇合）---- */
static HWND g_hwnd_main = NULL;
static HANDLE g_pipe_thread = NULL;
static HANDLE g_pipe_evt = NULL;   /* 手复事件：seek/暂停恢复/拖动状态/退出 */
static HANDLE g_hires_timer = NULL; /* 高分辨率可等待定时器（可空，见
                                       wait_ms） */
static volatile int g_pipe_quit = 0;
static CRITICAL_SECTION g_stream_cs; /* 解码流句柄互斥（管线工作线程 ↔
                                        子进程预览回退路径；WinMain 初始化） */
static volatile LONG g_seek_seq = 0;    /* seek 请求序号（post_seek 递增） */
static volatile double g_seek_frac = 0.0; /* seek 请求位置（先于序号写） */

/* 实时帧率统计：最近 1s 上屏时间戳环形缓冲。 */
static DWORD g_ftimes[128];
static int g_fti = 0, g_ftn = 0;

static void mark_frame(void) {
  g_ftimes[g_fti] = GetTickCount();
  g_fti = (g_fti + 1) % 128;
  if (g_ftn < 128) g_ftn++;
}

static double ui_fps(void) {
  int i, cnt = 0;
  const DWORD now = GetTickCount();
  for (i = 0; i < g_ftn; i++) {
    if (now - g_ftimes[i] <= 1000) cnt++;
  }
  return cnt;
}

/* ---- 测试图案（纯整数运算，Dart 侧可逐位复刻）---- */
static void gen_pattern(int f) {
  int x, y, i = 0;
  const int bx = (f * 3) % (g_w + 80) - 40;
  for (y = 0; y < g_h; y++) {
    for (x = 0; x < g_w; x++, i += 3) {
      int r = (x * 255) / (g_w - 1);
      int g = (y * 255) / (g_h - 1);
      int b = ((x + y) * 255) / (g_w + g_h - 2);
      /* 移动色块：颜色随帧号循环（覆盖色环） */
      if (x >= bx && x < bx + 80 && y >= g_h / 3 && y < g_h / 3 + 80) {
        r = (f * 5) & 255;
        g = (255 - (f * 5)) & 255;
        b = (f * 5 + 128) & 255;
      }
      g_rgb_src[i] = (unsigned char)r;
      g_rgb_src[i + 1] = (unsigned char)g;
      g_rgb_src[i + 2] = (unsigned char)b;
    }
  }
}

/* ---- 24bpp BMP 输入（--bmp：单文件或目录序列）---- */
static char **g_bmp_files = NULL;
static int g_bmp_count = 0;

static int bmp_dims(const char *path, int *w, int *h) {
  FILE *fp = fopen(path, "rb");
  unsigned char hdr[54];
  int ok = 0;
  if (fp == NULL) return 0;
  if (fread(hdr, 1, 54, fp) == 54 && hdr[0] == 'B' && hdr[1] == 'M') {
    const int bpp = hdr[28] | (hdr[29] << 8);
    const int comp = hdr[30] | (hdr[31] << 8) | (hdr[32] << 16) | (hdr[33] << 24);
    if (bpp == 24 && comp == 0) {
      *w = hdr[18] | (hdr[19] << 8) | (hdr[20] << 16) | (hdr[21] << 24);
      *h = hdr[22] | (hdr[23] << 8) | (hdr[24] << 16) | (hdr[25] << 24);
      if (*h < 0) *h = -*h;
      ok = *w > 0 && *h > 0;
    }
  }
  fclose(fp);
  return ok;
}

static int load_bmp(const char *path) {
  FILE *fp = fopen(path, "rb");
  unsigned char hdr[54];
  int x, y, stride, topdown, ok = 0;
  unsigned char *row;
  if (fp == NULL) return 0;
  if (fread(hdr, 1, 54, fp) != 54) { fclose(fp); return 0; }
  {
    const int off = hdr[10] | (hdr[11] << 8) | (hdr[12] << 16) | (hdr[13] << 24);
    const int hh = hdr[22] | (hdr[23] << 8) | (hdr[24] << 16) | (hdr[25] << 24);
    topdown = hh < 0;
    fseek(fp, off, SEEK_SET);
  }
  stride = (g_w * 3 + 3) & ~3;
  row = (unsigned char *)malloc((size_t)stride);
  if (row == NULL) { fclose(fp); return 0; }
  for (y = 0; y < g_h; y++) {
    const int dy = topdown ? y : (g_h - 1 - y);
    if (fread(row, 1, (size_t)stride, fp) != (size_t)stride) goto done;
    for (x = 0; x < g_w; x++) {
      unsigned char *d = g_rgb_src + ((size_t)dy * g_w + x) * 3;
      d[0] = row[x * 3 + 2]; /* BGR→RGB */
      d[1] = row[x * 3 + 1];
      d[2] = row[x * 3];
    }
  }
  ok = 1;
done:
  free(row);
  fclose(fp);
  return ok;
}

static int cmp_str(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int collect_bmp_dir(const char *dir) {
  char pat[MAX_PATH];
  WIN32_FIND_DATAA fd;
  HANDLE h;
  int cap = 16;
  _snprintf(pat, MAX_PATH, "%s\\\\*.bmp", dir);
  h = FindFirstFileA(pat, &fd);
  if (h == INVALID_HANDLE_VALUE) return 0;
  g_bmp_files = (char **)malloc((size_t)cap * sizeof(char *));
  do {
    if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
      if (g_bmp_count >= cap) {
        cap *= 2;
        g_bmp_files =
            (char **)realloc(g_bmp_files, (size_t)cap * sizeof(char *));
      }
      g_bmp_files[g_bmp_count] =
          (char *)malloc(strlen(dir) + strlen(fd.cFileName) + 2);
      _snprintf(g_bmp_files[g_bmp_count], strlen(dir) + strlen(fd.cFileName) + 2,
                "%s\\\\%s", dir, fd.cFileName);
      g_bmp_files[g_bmp_count][strlen(dir) + strlen(fd.cFileName) + 1] = '\\0';
      g_bmp_count++;
    }
  } while (FindNextFileA(h, &fd));
  FindClose(h);
  if (g_bmp_count > 1) {
    qsort(g_bmp_files, (size_t)g_bmp_count, sizeof(char *), cmp_str);
  }
  return g_bmp_count;
}

/* ---- ffmpeg 流式解码（--video）：子进程 stdout 管道读 rgb24 原始帧，
 * stderr 重定向到 NUL（防止写满管道阻塞 ffmpeg）；跳转用 -ss 重启流，
 * EOF 循环重播。---- */
static PROCESS_INFORMATION g_ff_pi;
static int g_ff_pi_valid = 0;
static HANDLE g_ff_rd = NULL;
static double g_duration = 0.0; /* 秒（0=未知/图片） */
static double g_vfps = 30.0;
static double g_pos = 0.0; /* 播放位置估计（seek 起点 + 已读帧/fps） */
static char g_ff_exe[MAX_PATH];
static char g_video_path[MAX_PATH];
static int g_video = 0;
static int g_video_eof = 0;
/* --scale WxH：ffmpeg 解码时缩放（-s），管道/装帧/管线/显示四段耗时
 * 同比缩小。g_native_* 记录原分辨率（状态栏标注）。 */
static int g_scale_w = 0, g_scale_h = 0;
static int g_native_w = 0, g_native_h = 0;
/* 解码后端：1=窗口模式优先尝试 CUDA 硬解链（NVDEC + scale_cuda GPU
 * 缩放），首帧读取失败自动回退 0=软解；--swdec 强制软解；批模式恒软解
 *（GPU 解码/缩放与软解像素不逐位一致，对拍哈希须可复现）。 */
static int g_hw = 1;

/* ---- 拖动预览（关键帧低分辨率直显）---- */
static int g_prev_w = 0, g_prev_h = 0;   /* 预览尺寸：宽 ≤640 等比 */
static unsigned char *g_prev_buf = NULL; /* 预览帧 rgb24 */
static HBITMAP g_dib_prev = NULL;
static unsigned char *g_dib_prev_bits = NULL;
static char g_av_dir[MAX_PATH] = ""; /* --avdir：libav* DLL 目录 */

/* 预读环前向声明（定义在 read_exact/nv12_to_rgb709 之后，见 ff_next_frame
 * 前的「解码预读环」段）。 */
static int ring_start(void);
static void ring_stop(void);

static void ff_kill(void) {
  if (g_ff_pi_valid) {
    TerminateProcess(g_ff_pi.hProcess, 0);
    /* 等进程真正退出再返回：进度条拖动会连续快速重建解码流，旧 ffmpeg
     * 的 CUDA/NVDEC 会话未随进程收尾时，新实例硬解初始化会失败（首帧
     * 读不到被当作 EOF 回放到开头）。 */
    WaitForSingleObject(g_ff_pi.hProcess, 2000);
    CloseHandle(g_ff_pi.hProcess);
    CloseHandle(g_ff_pi.hThread);
    g_ff_pi_valid = 0;
  }
  /* 先终止子进程（管道断裂使读者线程阻塞的 ReadFile 出错返回）、停读
   * 者线程，最后才关读端句柄——避免读者阻塞在 ReadFile 期间句柄被关
   *（句柄关闭与在途 I/O 并发是未定义行为）。 */
  ring_stop();
  if (g_ff_rd != NULL) {
    CloseHandle(g_ff_rd);
    g_ff_rd = NULL;
  }
}

/* 以 -ss start 起解码流；返回 0 成功。[preview] 为拖动预览形态：恒软解
 *（GPU 链 CUDA 初始化 ~0.5s/次，拖动频繁重建受不了）+ 低分辨率
 *（g_prev_w×g_prev_h）+ 单帧（-frames:v 1）+ 关键帧直达
 *（-noaccurate_seek，不解码 GOP 前向帧）。4K VP9 源实测 ~0.5s/次
 *（进程重启 + 单帧软解），比完整 seek + 管线处理（~1s+）快一倍以上；
 * 拖动预览的真瓶颈是子进程模式本身，播放器级顺滑需常驻解码器。
 *（见 seek_preview/worker_seek）。 */
static int ff_spawn_ex(double start_sec, int preview) {
  SECURITY_ATTRIBUTES sa;
  HANDLE rd = NULL, wr = NULL, nul = NULL;
  STARTUPINFOA si;
  char cmd[MAX_PATH * 2 + 256];
  char ss[48];
  /* 匿名管道默认缓冲仅 ~4KB：4K 帧 24MB 会被切成数千次小块读写（每次
   * 都伴随 ffmpeg 进程上下文切换），实测 500ms+/帧的元凶。解码预读的
   * 主力是读者线程 + 帧环（见「解码预读环」），管道缓冲只平滑读者线
   * 程的消费突发：GPU 解码链（CPU 侧仅 hwdownload 拷贝，负载轻）开 6
   * 帧；软解自身吃满 FF_DEC_THREADS 个核，深缓冲只会让 ffmpeg 解码线
   * 程与管线 OpenMP 线程持续争抢（实测 run 段墙钟放大近 4 倍），保持
   * 2 帧——ffmpeg 填满即阻塞，自然让出核给管线。下限 1MB，上限
   * 64MB。 */
  /* GPU 链交付 nv12（每像素 1.5 字节，实测 ~111fps；rgb24 每像素 3 字节
   * 只有 ~57fps——4K 原生播放交付瓶颈），软解/预览保持 rgb24（批模式哈
   * 希口径）。 */
  const size_t npix =
      (size_t)(preview ? g_prev_w : g_w) * (size_t)(preview ? g_prev_h : g_h);
  const size_t frame_bytes = (!preview && g_hw) ? npix * 3 / 2 : npix * 3;
  size_t want = frame_bytes * (preview ? 2 : (g_hw ? 6 : 2));
  DWORD pipeBuf;
  if (want < (size_t)(1 << 20)) want = (size_t)(1 << 20);
  if (want > (size_t)(64 << 20)) want = (size_t)(64 << 20);
  pipeBuf = (DWORD)want;
  ff_kill();
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  sa.lpSecurityDescriptor = NULL;
  if (!CreatePipe(&rd, &wr, &sa, pipeBuf)) return 1;
  /* 读端不继承（子进程只继承写端），父进程关闭写端后 EOF 才能传递。 */
  SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
  nul = CreateFileA("NUL", GENERIC_WRITE, 0, &sa, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
  memset(&si, 0, sizeof(si));
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  si.hStdOutput = wr;
  si.hStdError =
      (nul != NULL && nul != INVALID_HANDLE_VALUE)
          ? nul
          : GetStdHandle(STD_ERROR_HANDLE);
  if (start_sec > 0.0) {
    _snprintf(ss, sizeof(ss),
              preview ? "-noaccurate_seek -ss %.3f " : "-ss %.3f ", start_sec);
  } else {
    ss[0] = '\\0';
  }
  {
    char vf[MAX_PATH + 160];
    if (preview) {
      _snprintf(vf, sizeof(vf), "-i \\"%s\\" -vf scale=%d:%d -frames:v 1 ",
                g_video_path, g_prev_w, g_prev_h);
    } else if (g_hw) {
      /* GPU 链：NVDEC 硬解 + scale_cuda GPU 缩放到工作尺寸（兼 10→8bit
       * 转 nv12——直接 hwdownload,format=nv12 对 10bit 流会配置失败）。
       * -vf 参数含逗号必须加引号。Rext 4:2:2 等 NVDEC 不支持的格式无帧
       * 输出，由 WinMain 首帧探测回退软解。 */
      _snprintf(vf, sizeof(vf),
                "-hwaccel cuda -hwaccel_output_format cuda -i \\"%s\\" "
                "-vf \\"scale_cuda=%d:%d:format=nv12,hwdownload,"
                "format=nv12\\" ",
                g_video_path, g_w, g_h);
    } else if (g_scale_w > 0) {
      /* 输出侧缩放滤镜（-s 放 -i 前是采集设备输入选项，语义错误）。 */
      _snprintf(vf, sizeof(vf), "-i \\"%s\\" -vf scale=%d:%d ",
                g_video_path, g_scale_w, g_scale_h);
    } else {
      _snprintf(vf, sizeof(vf), "-i \\"%s\\" ", g_video_path);
    }
    _snprintf(cmd, sizeof(cmd),
              "\\"%s\\" -hide_banner -loglevel error "
              "-threads %d -filter_threads %d %s%s"
              "-f rawvideo -pix_fmt %s -",
              g_ff_exe, FF_DEC_THREADS, FF_DEC_THREADS, ss, vf,
              (!preview && g_hw) ? "nv12" : "rgb24");
    /* GPU 链出 nv12 由本进程 omp 转 BT.709（见 ff_next_frame）。 */
    g_ff_nv12 = !preview && g_hw;
  }
  /* BELOW_NORMAL：软解重载源（8K/Rext 4:2:2）时 ffmpeg 解码线程（已
   * 封顶 FF_DEC_THREADS）持续满载，低优先级保证桌面/系统保持响应。
   * CREATE_NO_WINDOW：GUI 程序起控制台子进程会弹出终端黑窗。 */
  if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE,
                      BELOW_NORMAL_PRIORITY_CLASS | CREATE_NO_WINDOW, NULL,
                      NULL, &si, &g_ff_pi)) {
    CloseHandle(rd);
    CloseHandle(wr);
    if (nul != NULL && nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    return 1;
  }
  g_ff_pi_valid = 1;
  CloseHandle(wr);
  if (nul != NULL && nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
  g_ff_rd = rd;
  g_video_eof = 0;
  g_pos = start_sec;
  /* 主流解码起预读读者线程（解码与处理/显示重叠，见「解码预读环」）；
   * 预览单帧流不起（拖动高频重建进程，读者线程只服务连续播放/批模式）。 */
  if (!preview && ring_start() != 0) {
    ff_kill();
    return 1;
  }
  return 0;
}

static int ff_spawn(double start_sec) {
  return ff_spawn_ex(start_sec, 0);
}

/* 从解码流读满 need 字节：0 成功，-1 EOF/失败。 */
static int read_exact(unsigned char *buf, size_t need) {
  size_t got = 0;
  while (got < need) {
    DWORD n = 0;
    if (!ReadFile(g_ff_rd, buf + got, (DWORD)(need - got), &n, NULL) ||
        n == 0) {
      return -1;
    }
    got += n;
  }
  return 0;
}

/* nv12 → rgb24（BT.709 限幅，Q8 定点，omp 按行）：GPU 链交付 nv12 由
 * 本进程转换，省去 ffmpeg 软转（4K 交付 ~57 → ~111fps 的关键）。 */
static void nv12_to_rgb709(const unsigned char *nv, unsigned char *rgb,
                           int w, int h) {
  const int rows = h & ~1;
  int y;
#pragma omp parallel for
  for (y = 0; y < rows; y++) {
    const unsigned char *yp = nv + (size_t)y * w;
    const unsigned char *uv = nv + (size_t)w * h + (size_t)(y >> 1) * w;
    unsigned char *d = rgb + (size_t)y * w * 3;
    int x;
    for (x = 0; x < w; x += 2) {
      const int u = uv[x] - 128, v = uv[x + 1] - 128;
      int k;
      for (k = 0; k < 2 && x + k < w; k++) {
        const int yy = yp[x + k] - 16;
        const int r = (298 * yy + 459 * v + 128) >> 8;
        const int g = (298 * yy - 55 * u - 136 * v + 128) >> 8;
        const int b = (298 * yy + 541 * u + 128) >> 8;
        d[(x + k) * 3 + 0] =
            (unsigned char)(r < 0 ? 0 : (r > 255 ? 255 : r));
        d[(x + k) * 3 + 1] =
            (unsigned char)(g < 0 ? 0 : (g > 255 ? 255 : g));
        d[(x + k) * 3 + 2] =
            (unsigned char)(b < 0 ? 0 : (b > 255 ? 255 : b));
      }
    }
  }
}

/* ---- 融合装帧/解包（窗口模式管线工作线程）----
 * 与 pack_input/unpack_output + fill_dib 同数学口径逐位一致，只省整帧
 * 中转（g_rgb_src/g_rgb_dst 物化与 fill_dib 的 RGB↔BGR 换序）：4K 下
 * 整帧内存搬运从 ~156MB/帧降到 ~84MB/帧。批模式不用（保持旧四段路径，
 * 哈希口径不变）。 */

/* rgb24 源（软解槽位/BMP/图案）一趟出 g_in + 原图 DIB（BGR）。 */
static void pack_fused_rgb24(const unsigned char *rgb, uint16_t *in,
                             unsigned char *dib, int w, int h) {
  const int sstride = (w * 3 + 3) & ~3;
  int y;
#pragma omp parallel for
  for (y = 0; y < h; y++) {
    const unsigned char *s = rgb + (size_t)y * (size_t)w * 3u;
    unsigned char *d = dib + (size_t)y * (size_t)sstride;
    int x;
    for (x = 0; x < w; x++) {
      const int r = s[x * 3], g = s[x * 3 + 1], b = s[x * 3 + 2];
      const size_t px = (size_t)y * (size_t)w + (size_t)x;
      d[x * 3] = (unsigned char)b;
      d[x * 3 + 1] = (unsigned char)g;
      d[x * 3 + 2] = (unsigned char)r;
      $packFusedPx
    }
    if (sstride > w * 3) memset(d + w * 3, 0, (size_t)(sstride - w * 3));
  }
}

/* GPU 链 nv12 源一趟出 g_in + 原图 DIB：nv12→rgb Q8 定点（与
 * nv12_to_rgb709 同式）→ 钳位字节 → 装帧（与 pack 同口径）。旧路径的
 * rows = h & ~1 末行缺口在此一并补齐（视频恒偶数行，仅影响奇高 BMP
 * 级边角）。 */
static void pack_fused_nv12(const unsigned char *nv, uint16_t *in,
                            unsigned char *dib, int w, int h) {
  const int sstride = (w * 3 + 3) & ~3;
  int y;
#pragma omp parallel for
  for (y = 0; y < h; y++) {
    const unsigned char *yp = nv + (size_t)y * (size_t)w;
    const unsigned char *uv =
        nv + (size_t)w * (size_t)h + (size_t)(y >> 1) * (size_t)w;
    unsigned char *d = dib + (size_t)y * (size_t)sstride;
    int x;
    for (x = 0; x < w; x += 2) {
      const int u = uv[x] - 128, v = uv[x + 1] - 128;
      int k;
      for (k = 0; k < 2 && x + k < w; k++) {
        const int yy = yp[x + k] - 16;
        const int rq = (298 * yy + 459 * v + 128) >> 8;
        const int gq = (298 * yy - 55 * u - 136 * v + 128) >> 8;
        const int bq = (298 * yy + 541 * u + 128) >> 8;
        const int r = rq < 0 ? 0 : (rq > 255 ? 255 : rq);
        const int g = gq < 0 ? 0 : (gq > 255 ? 255 : gq);
        const int b = bq < 0 ? 0 : (bq > 255 ? 255 : bq);
        const size_t px = (size_t)y * (size_t)w + (size_t)(x + k);
        d[(x + k) * 3] = (unsigned char)b;
        d[(x + k) * 3 + 1] = (unsigned char)g;
        d[(x + k) * 3 + 2] = (unsigned char)r;
        $packFusedPx
      }
    }
    if (sstride > w * 3) memset(d + w * 3, 0, (size_t)(sstride - w * 3));
  }
}

/* 融合解包：g_out 直写 BGR 到处理后 DIB（免 g_rgb_dst 中转）。 */
static void unpack_fused(const uint16_t *out, unsigned char *dib, int w,
                         int h) {
  const int sstride = (w * 3 + 3) & ~3;
  int y;
#pragma omp parallel for
  for (y = 0; y < h; y++) {
    unsigned char *d = dib + (size_t)y * (size_t)sstride;
    int x;
    for (x = 0; x < w; x++) {
      const size_t px = (size_t)y * (size_t)w + (size_t)x;
      $unpackFusedPx
    }
    if (sstride > w * 3) memset(d + w * 3, 0, (size_t)(sstride - w * 3));
  }
}

/* ---- 解码预读环（读者线程 + RING_N 帧环形缓冲）----
 * UI 线程同步读管道的旧形态下，ffmpeg 子进程只有几帧管道缓冲：UI 处理/
 * 显示期间子进程被管道写满阻塞，解码交付退化为与处理串行，追赶期的跳
 * 帧读又被解码速度节流（实测 4K60 源窗口模式仅 ~1fps（GPU 链）/~8fps
 *（软解），而纯解码交付能力实测 200~390fps——瓶颈 100% 在同步耦合）。
 * 读者线程持续 drain 管道入环，解码与处理/显示/跳帧完全重叠；丢帧保速
 * 的跳帧退化为环内丢弃（跳过 nv12 转换/拷贝）。
 * 槽位按 rgb24 最大尺寸分配一次（GPU 链只用前 1.5B/px），spawn 复用；
 * 消费槽位在转换/拷贝完成前经 g_r_held 扣留，不归还读者覆写。 */
#define RING_N 4
static unsigned char *g_ring[RING_N];
static int g_r_head = 0, g_r_count = 0, g_r_held = 0;
static int g_r_eof = 0, g_r_quit = 0;
static CRITICAL_SECTION g_r_cs;
static CONDITION_VARIABLE g_r_has_data, g_r_has_room;
static HANDLE g_r_thread = NULL;

static DWORD WINAPI ring_reader(LPVOID p) {
  const size_t fb =
      g_ff_nv12 ? (size_t)g_w * g_h * 3 / 2 : (size_t)g_w * g_h * 3;
  (void)p;
  for (;;) {
    int slot;
    EnterCriticalSection(&g_r_cs);
    while (g_r_count + g_r_held >= RING_N && !g_r_quit) {
      SleepConditionVariableCS(&g_r_has_room, &g_r_cs, INFINITE);
    }
    if (g_r_quit) {
      LeaveCriticalSection(&g_r_cs);
      return 0;
    }
    slot = (g_r_head + g_r_count) % RING_N;
    LeaveCriticalSection(&g_r_cs);
    /* 阻塞读在锁外进行：EOF/子进程终止（ff_kill）时 read_exact 返回 -1。 */
    if (read_exact(g_ring[slot], fb) != 0) {
      EnterCriticalSection(&g_r_cs);
      g_r_eof = 1;
      WakeAllConditionVariable(&g_r_has_data);
      LeaveCriticalSection(&g_r_cs);
      return 0;
    }
    EnterCriticalSection(&g_r_cs);
    g_r_count++;
    WakeConditionVariable(&g_r_has_data);
    LeaveCriticalSection(&g_r_cs);
  }
}

/* 起读者线程（主流 spawn 成功后调用；槽位首次分配、随后 spawn 复用）。 */
static int ring_start(void) {
  int i;
  for (i = 0; i < RING_N; i++) {
    if (g_ring[i] == NULL) {
      g_ring[i] = (unsigned char *)malloc((size_t)g_w * g_h * 3);
      if (g_ring[i] == NULL) return 1;
    }
  }
  g_r_head = g_r_count = g_r_held = 0;
  g_r_eof = g_r_quit = 0;
  g_r_thread = CreateThread(NULL, 0, ring_reader, NULL, 0, NULL);
  return g_r_thread == NULL;
}

/* 停读者线程（ff_kill 在子进程终止后调用：管道断裂使阻塞的 ReadFile 出
 * 错返回，quit 标志双保险；槽位保留复用）。 */
static void ring_stop(void) {
  if (g_r_thread != NULL) {
    EnterCriticalSection(&g_r_cs);
    g_r_quit = 1;
    WakeAllConditionVariable(&g_r_has_data);
    WakeAllConditionVariable(&g_r_has_room);
    LeaveCriticalSection(&g_r_cs);
    WaitForSingleObject(g_r_thread, 5000);
    CloseHandle(g_r_thread);
    g_r_thread = NULL;
  }
}

/* 从帧环取一帧：[drop] 为 1 仅丢弃（丢帧保速的跳帧，不做 nv12 转换/拷
 * 贝），为 0 交付到 g_rgb_src（GPU 链 nv12→rgb24 omp 转换）：0 成功，
 * -1 EOF/失败。g_pos 每取一帧推进 1/fps（丢弃帧同样推进，与旧口径一致）。 */
static int ring_take(int drop) {
  int slot;
  EnterCriticalSection(&g_r_cs);
  while (g_r_count == 0 && !g_r_eof) {
    SleepConditionVariableCS(&g_r_has_data, &g_r_cs, INFINITE);
  }
  if (g_r_count == 0) {
    LeaveCriticalSection(&g_r_cs);
    return -1;
  }
  slot = g_r_head;
  g_r_head = (g_r_head + 1) % RING_N;
  g_r_count--;
  if (drop) {
    /* 丢弃帧不读槽位内容，立即归还读者。 */
    WakeConditionVariable(&g_r_has_room);
    LeaveCriticalSection(&g_r_cs);
  } else {
    /* 消费槽位扣留至转换/拷贝完成（锁外进行），再归还读者。 */
    g_r_held = 1;
    LeaveCriticalSection(&g_r_cs);
    if (g_ff_nv12) {
      nv12_to_rgb709(g_ring[slot], g_rgb_src, g_w, g_h);
    } else {
      memcpy(g_rgb_src, g_ring[slot], (size_t)g_w * g_h * 3);
    }
    EnterCriticalSection(&g_r_cs);
    g_r_held = 0;
    WakeConditionVariable(&g_r_has_room);
    LeaveCriticalSection(&g_r_cs);
  }
  g_pos += 1.0 / g_vfps;
  return 0;
}

/* 读下一帧到 g_rgb_src（帧环消费；g_ff_nv12 时槽位为 nv12、消费时转
 * rgb24）：0 成功，-1 EOF/失败。 */
static int ff_next_frame(void) {
  return ring_take(0);
}

/* 只解码不处理地跳过 n 帧（丢帧对齐墙钟用：环内丢弃，不做转换/拷贝）：
 * 0 成功，-1 EOF/失败。 */
static int skip_frames(int n) {
  while (n-- > 0) {
    if (ring_take(1) != 0) return -1;
  }
  return 0;
}

/* 帧环取一帧并融合装帧（g_in + 原图 DIB，免 g_rgb_src 整帧中转；nv12
 * 槽位同趟 Q8 转换，rgb24 槽位直接读免 24MB 拷贝）：0 成功，-1 EOF/失
 * 败。锁/扣留纪律与 ring_take 一致。 */
static int worker_take_and_pack(unsigned char *dib) {
  int slot;
  EnterCriticalSection(&g_r_cs);
  while (g_r_count == 0 && !g_r_eof) {
    SleepConditionVariableCS(&g_r_has_data, &g_r_cs, INFINITE);
  }
  if (g_r_count == 0) {
    LeaveCriticalSection(&g_r_cs);
    return -1;
  }
  slot = g_r_head;
  g_r_head = (g_r_head + 1) % RING_N;
  g_r_count--;
  g_r_held = 1;
  LeaveCriticalSection(&g_r_cs);
  if (g_ff_nv12) {
    pack_fused_nv12(g_ring[slot], g_in, dib, g_w, g_h);
  } else {
    pack_fused_rgb24(g_ring[slot], g_in, dib, g_w, g_h);
  }
  EnterCriticalSection(&g_r_cs);
  g_r_held = 0;
  WakeConditionVariable(&g_r_has_room);
  LeaveCriticalSection(&g_r_cs);
  g_pos += 1.0 / g_vfps;
  return 0;
}

/* 播放墙钟对齐（视频模式，丢帧保原始速率）：起点墙钟/帧号。 */
static DWORD g_wall0 = 0;
static int g_frame0 = 0;

/* 探测：分辨率/时长/帧率（解析 ffmpeg 横幅的 ANSI 输出；无输出参数的
 * ffmpeg -i 打印横幅后立即退出）。 */
static void ff_probe(void) {
  SECURITY_ATTRIBUTES sa;
  HANDLE rd = NULL, wr = NULL;
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  char cmd[MAX_PATH * 2 + 32];
  static char buf[65536];
  DWORD total = 0, n = 0;
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  sa.lpSecurityDescriptor = NULL;
  if (!CreatePipe(&rd, &wr, &sa, 0)) return;
  memset(&si, 0, sizeof(si));
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  si.hStdOutput = wr;
  si.hStdError = wr;
  _snprintf(cmd, sizeof(cmd), "\\"%s\\" -hide_banner -i \\"%s\\"", g_ff_exe,
            g_video_path);
  if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL,
                      NULL, &si, &pi)) {
    CloseHandle(rd);
    CloseHandle(wr);
    return;
  }
  CloseHandle(wr);
  while (total < sizeof(buf) - 1 &&
         ReadFile(rd, buf + total, (DWORD)(sizeof(buf) - 1 - total), &n, NULL) &&
         n > 0) {
    total += n;
  }
  buf[total] = '\\0';
  CloseHandle(rd);
  TerminateProcess(pi.hProcess, 0);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  /* 时长：Duration: HH:MM:SS.xx */
  {
    char *p = strstr(buf, "Duration:");
    int hh = 0, mm = 0;
    double ss = 0.0;
    if (p != NULL && sscanf(p + 9, "%d:%d:%lf", &hh, &mm, &ss) == 3) {
      g_duration = hh * 3600.0 + mm * 60.0 + ss;
    }
  }
  /* 分辨率：首个 "Video:" 之后首个合法 WxH（上限守卫跳过 0xXXXX 十六进制
   * 误配，如 codec tag 0x31637661）。 */
  {
    char *p = strstr(buf, "Video:");
    if (p != NULL) {
      for (; *p; p++) {
        int tw = 0, th = 0;
        if (*p >= '0' && *p <= '9' &&
            sscanf(p, "%dx%d", &tw, &th) == 2 &&
            tw >= 16 && tw <= 16384 && th >= 16 && th <= 16384 &&
            p > buf && (p[-1] == ' ' || p[-1] == ',')) {
          g_w = tw;
          g_h = th;
          break;
        }
      }
    }
  }
  /* 帧率："30 fps" 的前缀数字。 */
  {
    char *p = strstr(buf, " fps");
    if (p != NULL) {
      char *s = p;
      while (s > buf && ((s[-1] >= '0' && s[-1] <= '9') || s[-1] == '.')) s--;
      if (s < p) {
        const double v = atof(s);
        if (v >= 1.0 && v <= 240.0) g_vfps = v;
      }
    }
  }
}

/* ---- 装帧/解包/跑管线 ---- */
static void pack_input(void) {
  const int n = g_w * g_h;
  int i;
$packBody
}

static void unpack_output(void) {
  const int n = g_w * g_h;
  int i;
$unpackBody
}

static DWORD g_t_read = 0, g_t_pack = 0, g_t_run = 0, g_t_unpack = 0;

static int process_frame(int f) {
  DWORD t;
  if (g_video) {
    /* 视频流：读下一解码帧；EOF/失败返回 2（调用方决定重播/收尾）。 */
    t = GetTickCount();
    if (ff_next_frame() != 0) return 2;
    g_t_read += GetTickCount() - t;
  } else if (g_bmp_count > 0) {
    t = GetTickCount();
    if (!load_bmp(g_bmp_files[f % g_bmp_count])) return 1;
    g_t_read += GetTickCount() - t;
  } else {
    t = GetTickCount();
    gen_pattern(f);
    g_t_read += GetTickCount() - t;
  }
  t = GetTickCount();
  pack_input();
  g_t_pack += GetTickCount() - t;
  t = GetTickCount();
  if (${topName}_run(g_in, g_w, g_h, MAXV, g_out${hasScratch ? ', g_scratch,\n                     g_scratch_bytes' : ''}) != ISP_OK) {
    return 1;
  }
  g_t_run += GetTickCount() - t;
  g_proc_ms = GetTickCount() - t;
  t = GetTickCount();
  unpack_output();
  g_t_unpack += GetTickCount() - t;
  return 0;
}

/* ---- 管线工作线程（窗口模式）----
 * 独占解码流消费与处理：帧环取帧+融合装帧 → 管线 → 融合解包 → 三缓冲
 * 发布 → PostMessage 通知 UI。走帧按墙钟到期驱动（高分辨率可等待定时
 * 器），丢帧保速/EOF 循环重播口径与旧 UI 线程 advance 一致。 */

/* 高分辨率等待 ms（可到期的走帧等待；g_pipe_evt 上的 seek/暂停/退出可
 * 提前唤醒——唤醒后由调用方循环重检标志）。高分辨率定时器不可用时回退
 * 事件超时等待（系统滴答粒度，仅旧 OS）。 */
static void wait_ms(double ms) {
  if (ms <= 0.0 || g_pipe_evt == NULL) return;
  if (g_hires_timer != NULL) {
    LARGE_INTEGER t;
    HANDLE h[2];
    t.QuadPart = (LONGLONG)(-ms * 10000.0); /* 相对，100ns */
    if (SetWaitableTimer(g_hires_timer, &t, 0, NULL, NULL, 0)) {
      h[0] = g_hires_timer;
      h[1] = g_pipe_evt;
      WaitForMultipleObjects(2, h, FALSE, INFINITE);
      return;
    }
  }
  WaitForSingleObject(g_pipe_evt, (DWORD)(ms + 0.5));
}

/* 窗口模式处理一帧：取帧+融合装帧（g_in+原图 DIB）→ 管线 → 融合解包
 *（处理后 DIB）。0 成功，1 失败，2 视频 EOF。计时口径：pack 段为取帧+
 * 装帧一体（旧 read+pack 合并）。 */
static int proc_one(int f, unsigned char *srcDib, unsigned char *dstDib) {
  DWORD t;
  if (g_video) {
    t = GetTickCount();
    if (worker_take_and_pack(srcDib) != 0) return 2;
    g_t_pack += GetTickCount() - t;
  } else if (g_bmp_count > 0) {
    t = GetTickCount();
    if (!load_bmp(g_bmp_files[f % g_bmp_count])) return 1;
    pack_fused_rgb24(g_rgb_src, g_in, srcDib, g_w, g_h);
    g_t_pack += GetTickCount() - t;
  } else {
    t = GetTickCount();
    gen_pattern(f);
    pack_fused_rgb24(g_rgb_src, g_in, srcDib, g_w, g_h);
    g_t_pack += GetTickCount() - t;
  }
  t = GetTickCount();
  if (${topName}_run(g_in, g_w, g_h, MAXV, g_out${hasScratch ? ', g_scratch,\n                     g_scratch_bytes' : ''}) != ISP_OK) {
    return 1;
  }
  g_t_run += GetTickCount() - t;
  g_proc_ms = GetTickCount() - t;
  t = GetTickCount();
  unpack_fused(g_out, dstDib, g_w, g_h);
  g_t_unpack += GetTickCount() - t;
  return 0;
}

/* 处理一帧并发布到三缓冲 + 通知 UI（0 成功；返回值同 proc_one）。 */
static int proc_publish(int f) {
  const int rc =
      proc_one(f, g_pb_src_bits[g_pb_write], g_pb_dst_bits[g_pb_write]);
  if (rc != 0) return rc;
  /* 发布：写缓冲与 ready 原子交换（SPSC 三缓冲：worker 写的永远不是
   * UI 正显示的那组，免锁免撕裂）。 */
  g_pb_write = InterlockedExchange(&g_pb_ready, g_pb_write);
  mark_frame();
  PostMessage(g_hwnd_main, WM_APP_FRAME, 0, 0);
  return 0;
}

/* 处理/上屏一个到期帧（g_stream_cs 持有；含丢帧保速与 EOF 循环重播，
 * 口径与旧 advance 一致）：0 成功，1 失败。 */
static int step_frame(void) {
  int rc;
  if (!g_video) g_frame = (g_frame + 1) % (g_frames > 0 ? g_frames : 1);
  if (g_video && g_vfps > 0.0) {
    /* 丢帧对齐墙钟（按原始帧率播放）：落后超过 1 帧时中间帧只解码不
     * 处理（帧间依赖使解码无法跳读），处理/显示只做到期帧。 */
    const int due =
        g_frame0 + (int)((double)(GetTickCount() - g_wall0) * g_vfps / 1000.0);
    const int behind = due - g_frame;
    if (behind > 1) {
      if (skip_frames(behind - 1) != 0) {
        /* EOF：循环重播并复位墙钟。 */
        if (ff_spawn(0.0) != 0) return 1;
        g_frame = 0;
        g_frame0 = 0;
        g_wall0 = GetTickCount();
      } else {
        g_frame += behind - 1;
      }
    }
  }
  rc = proc_publish(g_frame);
  if (rc == 2) {
    /* 视频 EOF：循环重播并复位墙钟（拖动/seek 打断的流不计——调用方
     * 在事件循环里优先处理 seek/拖动，见 pipe_worker）。 */
    if (ff_spawn(0.0) == 0) {
      g_frame = 0;
      g_frame0 = 0;
      g_wall0 = GetTickCount();
      rc = proc_publish(0);
    }
  }
  if (rc != 0) return 1;
  if (g_video) g_frame++;
  return 0;
}

/* 工作线程内执行的 seek（进度条落定 / 图案·BMP 拖动跳帧）：重建流 +
 * 处理 + 发布。视频 seek 失败不回放到开头（保持当前画面），口径同旧
 * seek_to_frac。 */
static void worker_seek(double frac) {
  if (frac < 0.0) frac = 0.0;
  if (frac > 1.0) frac = 1.0;
  if (g_video && g_duration > 0.0) {
    if (ff_spawn(frac * g_duration) == 0) {
      if (proc_publish(0) == 0) {
        /* 已处理 seek 后首帧：播放墙钟自此对齐（丢帧保速见 step_frame）。 */
        g_frame = 1;
        g_frame0 = 1;
        g_wall0 = GetTickCount();
      }
    }
  } else if (!g_video && g_frames > 1) {
    proc_publish((int)(frac * (g_frames - 1)));
  }
}

static DWORD WINAPI pipe_worker(LPVOID p) {
  int was_paused = 0;
  LONG seen_seek = 0;
  (void)p;
  for (;;) {
    ResetEvent(g_pipe_evt);
    if (g_pipe_quit) break;
    /* seek 请求优先（落定/非视频拖动跳帧；UI 经 post_seek 异步投递）。 */
    {
      const LONG s = InterlockedCompareExchange(&g_seek_seq, 0, 0);
      if (s != seen_seek) {
        seen_seek = s;
        EnterCriticalSection(&g_stream_cs);
        if (!g_pipe_quit) worker_seek(g_seek_frac);
        LeaveCriticalSection(&g_stream_cs);
        was_paused = 0;
        continue;
      }
    }
    if (g_pipe_quit) break;
    /* 暂停/拖动中挂起（事件唤醒）。拖动期间主流可能已被预览流替换
     *（子进程回退路径），不得消费；HAVE_AV 路径按设计同样冻结右侧处
     * 理后画面。 */
    if (!g_playing || g_dragging) {
      was_paused = 1;
      WaitForSingleObject(g_pipe_evt, INFINITE);
      continue;
    }
    if (was_paused) {
      /* 恢复播放：复位墙钟对齐（从当前帧继续按源帧率计速）。 */
      was_paused = 0;
      g_frame0 = g_frame;
      g_wall0 = GetTickCount();
    }
    if (g_video && g_vfps > 0.0) {
      /* 未到期：高分辨率等到期（事件可提前唤醒）。 */
      const double dueMs = (double)g_wall0 +
                           (double)(g_frame - g_frame0) * 1000.0 / g_vfps;
      const double waitMs = dueMs - (double)GetTickCount();
      if (waitMs > 1.0) {
        wait_ms(waitMs);
        continue;
      }
    }
    {
      int rc;
      const DWORD t0 = GetTickCount();
      EnterCriticalSection(&g_stream_cs);
      if (g_pipe_quit) {
        LeaveCriticalSection(&g_stream_cs);
        break;
      }
      rc = step_frame();
      LeaveCriticalSection(&g_stream_cs);
      if (rc != 0 && !g_pipe_quit) {
        /* 失败停播（画面保持；拖动/seek 竞态导致的流断裂不计——那
         * 些路径由 seek 请求重建）。 */
        if (!g_dragging &&
            InterlockedCompareExchange(&g_seek_seq, 0, 0) == seen_seek) {
          g_playing = 0;
        }
        PostMessage(g_hwnd_main, WM_APP_FRAME, 0, 0);
      }
      if (!g_video) {
        /* 图案/BMP：30ms 走帧节奏（旧 SetTimer 口径）。 */
        const double el = (double)(GetTickCount() - t0);
        if (el < 30.0) wait_ms(30.0 - el);
      }
    }
  }
  return 0;
}

/* UI 投递 seek 请求（进度条落定 / 图案·BMP 拖动跳帧）：工作线程认领
 * 后重建流 + 处理 + 发布（UI 不阻塞；位置先于序号写，worker 见新序
 * 号必见新位置）。 */
static void post_seek(double frac) {
  g_seek_frac = frac;
  InterlockedIncrement(&g_seek_seq);
  SetEvent(g_pipe_evt);
}

static int alloc_all(void) {
  g_scratch_bytes = ${hasScratch ? '(size_t)${macro}_SCRATCH_BYTES(g_w, g_h, MAXV)' : '0'};
  g_rgb_src = (unsigned char *)malloc((size_t)g_w * g_h * 3);
  g_rgb_dst = (unsigned char *)malloc((size_t)g_w * g_h * 3);
  g_in = (uint16_t *)malloc((size_t)g_w * g_h * 3 * sizeof(uint16_t));
  g_out = (uint16_t *)malloc((size_t)g_w * g_h * 3 * sizeof(uint16_t));
  g_scratch = malloc(g_scratch_bytes > 0 ? g_scratch_bytes : 1);
  return g_rgb_src && g_rgb_dst && g_in && g_out && g_scratch;
}

/* ---- 批模式：--frames N --dump-hash ---- */
static unsigned g_fnv;
static void fnv1a_update(const void *p, size_t n) {
  const unsigned char *c = (const unsigned char *)p;
  while (n--) {
    g_fnv ^= *c++;
    g_fnv *= 16777619u;
  }
}

static int batch_run(int frames) {
  int i;
  if (!alloc_all()) return 2;
  for (i = 0; i < frames; i++) {
    const int rc = process_frame(i);
    if (rc == 2) break; /* 视频 EOF：按实际帧数收尾 */
    if (rc != 0) return 1;
    g_fnv = 2166136261u;
    fnv1a_update(g_out, (size_t)g_w * g_h * 3 * sizeof(uint16_t));
    printf("frame %d: %08x\\n", i, g_fnv);
  }
  printf("frames=%d size=%dx%d max=%d\\n", i, g_w, g_h, MAXV);
  /* 分段耗时均值（定位吞吐瓶颈：读流/装帧/管线/解包）。 */
  if (i > 0) {
    printf("timing ms/frame: read %.1f pack %.1f run %.1f unpack %.1f\\n",
           (double)g_t_read / i, (double)g_t_pack / i, (double)g_t_run / i,
           (double)g_t_unpack / i);
  }
  return 0;
}

/* ---- DIB 显示缓冲（24bpp 自上而下，BGR）：三缓冲 DIB 段只在装帧时
 * 创建一次（每帧 CreateDIBSection/DeleteObject 的 GDI 对象分配是帧率
 * 大坑），工作线程写后缓冲、原子交换发布（见 proc_publish）。---- */

static void fill_dib(unsigned char *bits, const unsigned char *rgb, int w,
                     int h) {
  int y;
  const int stride = (w * 3 + 3) & ~3;
  /* RGB→BGR 逐行独立，OpenMP 按行并行（结果与串行逐位一致）。 */
#pragma omp parallel for
  for (y = 0; y < h; y++) {
    int x;
    unsigned char *row = bits + (size_t)y * stride;
    const unsigned char *s = rgb + (size_t)y * w * 3;
    for (x = 0; x < w; x++) {
      row[x * 3] = s[x * 3 + 2]; /* RGB→BGR */
      row[x * 3 + 1] = s[x * 3 + 1];
      row[x * 3 + 2] = s[x * 3];
    }
    if (stride > w * 3) memset(row + w * 3, 0, (size_t)(stride - w * 3));
  }
}

static int alloc_pbufs(void) {
  BITMAPINFO bi;
  int i;
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = g_w;
  bi.bmiHeader.biHeight = -g_h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 24;
  bi.bmiHeader.biCompression = BI_RGB;
  for (i = 0; i < PBUF_N; i++) {
    g_pb_src[i] = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS,
                                   (void **)&g_pb_src_bits[i], NULL, 0);
    g_pb_dst[i] = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS,
                                   (void **)&g_pb_dst_bits[i], NULL, 0);
    if (g_pb_src[i] == NULL || g_pb_dst[i] == NULL ||
        g_pb_src_bits[i] == NULL || g_pb_dst_bits[i] == NULL) {
      return 0;
    }
  }
  return 1;
}

/* 预览 DIB/缓冲（尺寸随视频确定，首次拖动预览时创建）。 */
static int alloc_prev(void) {
  BITMAPINFO bi;
  g_prev_w = g_w > 640 ? 640 : g_w;
  g_prev_h = (g_h * g_prev_w / g_w) & ~1;
  if (g_prev_h <= 0) g_prev_h = 2;
  free(g_prev_buf);
  g_prev_buf = (unsigned char *)malloc((size_t)g_prev_w * g_prev_h * 3);
  if (g_dib_prev != NULL) DeleteObject(g_dib_prev);
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = g_prev_w;
  bi.bmiHeader.biHeight = -g_prev_h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 24;
  bi.bmiHeader.biCompression = BI_RGB;
  g_dib_prev = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS,
                                (void **)&g_dib_prev_bits, NULL, 0);
  return g_prev_buf != NULL && g_dib_prev != NULL && g_dib_prev_bits != NULL;
}

/* 拖动预览：关键帧直达（-noaccurate_seek）+ 软解 + 低分辨率单帧 +
 * 跳过管线处理直接解出原图到预览缓冲（不上屏；见 ff_spawn_ex 注释）。
 * 在预览工作线程上调用。 */
static int seek_preview(double frac) {
  const double t = frac * g_duration;
  if (g_prev_buf == NULL && !alloc_prev()) return 1;
  if (ff_spawn_ex(t, 1) != 0) return 1;
  return read_exact(g_prev_buf, (size_t)g_prev_w * g_prev_h * 3);
}

/* ---- 内嵌 libav 拖动预览解码器（可选，--avdir 指向 DLL 目录）----
 * 播放器级拖动：常驻解码器实例，拖动 seek = av_seek_frame（关键帧直
 * 达）+ 立即解一帧——无进程重启/CUDA 初始化，比子进程预览快一个量级。
 * DLL 经 LoadLibraryEx 运行时加载（免 import lib/免改链接），头文件
 * 编译期经 /I tools/ffmpeg/include 提供（buildWinVerifyApp 自动附加）；
 * 头文件缺失时本段不编译（HAVE_AV=0），DLL 缺失/解码失败时运行时回退
 * 子进程预览（seek_preview）。预览只用于拖动导航（swscale 默认色彩矩
 * 阵），正式画面仍走 ffmpeg 子进程 + 管线全尺寸处理。 */
#if defined(__has_include)
#if __has_include(<libavformat/avformat.h>)
#define HAVE_AV 1
#endif
#endif
#ifndef HAVE_AV
#define HAVE_AV 0
#endif

#if HAVE_AV
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>

typedef int (*fn_avformat_open_input)(AVFormatContext **, const char *,
                                      const AVInputFormat *, AVDictionary **);
typedef int (*fn_avformat_find_stream_info)(AVFormatContext *, AVDictionary **);
typedef int (*fn_av_read_frame)(AVFormatContext *, AVPacket *);
typedef int (*fn_av_seek_frame)(AVFormatContext *, int, int64_t, int);
typedef void (*fn_avformat_close_input)(AVFormatContext **);
typedef const AVCodec *(*fn_avcodec_find_decoder)(enum AVCodecID);
typedef AVCodecContext *(*fn_avcodec_alloc_context3)(const AVCodec *);
typedef int (*fn_avcodec_parameters_to_context)(AVCodecContext *,
                                                const AVCodecParameters *);
typedef int (*fn_avcodec_open2)(AVCodecContext *, const AVCodec *,
                                AVDictionary **);
typedef int (*fn_avcodec_send_packet)(AVCodecContext *, const AVPacket *);
typedef int (*fn_avcodec_receive_frame)(AVCodecContext *, AVFrame *);
typedef void (*fn_avcodec_flush_buffers)(AVCodecContext *);
typedef AVFrame *(*fn_av_frame_alloc)(void);
typedef AVPacket *(*fn_av_packet_alloc)(void);
typedef void (*fn_av_packet_unref)(AVPacket *);
typedef struct SwsContext *(*fn_sws_getContext)(int, int, enum AVPixelFormat,
                                                int, int, enum AVPixelFormat,
                                                int, void *, void *,
                                                const double *);
typedef int (*fn_sws_scale)(struct SwsContext *, const uint8_t *const *,
                            const int *, int, int, uint8_t *const *,
                            const int *);
typedef void (*fn_sws_freeContext)(struct SwsContext *);

static fn_avformat_open_input p_avformat_open_input;
static fn_avformat_find_stream_info p_avformat_find_stream_info;
static fn_av_read_frame p_av_read_frame;
static fn_av_seek_frame p_av_seek_frame;
static fn_avformat_close_input p_avformat_close_input;
static fn_avcodec_find_decoder p_avcodec_find_decoder;
static fn_avcodec_alloc_context3 p_avcodec_alloc_context3;
static fn_avcodec_parameters_to_context p_avcodec_parameters_to_context;
static fn_avcodec_open2 p_avcodec_open2;
static fn_avcodec_send_packet p_avcodec_send_packet;
static fn_avcodec_receive_frame p_avcodec_receive_frame;
static fn_avcodec_flush_buffers p_avcodec_flush_buffers;
static fn_av_frame_alloc p_av_frame_alloc;
static fn_av_packet_alloc p_av_packet_alloc;
static fn_av_packet_unref p_av_packet_unref;
static fn_sws_getContext p_sws_getContext;
static fn_sws_scale p_sws_scale;
static fn_sws_freeContext p_sws_freeContext;

static int g_av_ok = 0; /* libav* DLL 已加载（符号表就绪） */

/* 每 worker 一套 libav 实例（av 上下文不可跨线程共享）。 */
typedef struct {
  AVFormatContext *ic;
  AVCodecContext *dec;
  AVPacket *pkt;
  AVFrame *frame;
  struct SwsContext *sws;
  int vindex;
  int sws_w, sws_h, sws_fmt;
  int ready; /* 0=未初始化 1=可用 -1=初始化失败 */
  unsigned char *buf; /* 预览 rgb24 */
} AvPrev;

/* 在 g_av_dir 下按通配符找 DLL（版本号不固定），全路径加载并解析符号。 */
static int av_load_lib(const char *dll_glob, const char *const *names,
                       FARPROC *out, int n) {
  char pat[MAX_PATH], path[MAX_PATH];
  WIN32_FIND_DATAA fd;
  HANDLE h;
  HMODULE mod;
  int i;
  _snprintf(pat, MAX_PATH, "%s\\\\%s", g_av_dir, dll_glob);
  h = FindFirstFileA(pat, &fd);
  if (h == INVALID_HANDLE_VALUE) return 1;
  FindClose(h);
  _snprintf(path, MAX_PATH, "%s\\\\%s", g_av_dir, fd.cFileName);
  mod = LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (mod == NULL) return 1;
  for (i = 0; i < n; i++) {
    out[i] = GetProcAddress(mod, names[i]);
    if (out[i] == NULL) return 1;
  }
  return 0;
}

/* 加载 libav* DLL 并解析符号表：全部成功返回 0（只调一次，UI 线程）。 */
static int av_load_all(void) {
  static const char *const avutil_names[] = {"av_frame_alloc"};
  /* av_packet_* 在 ffmpeg 9 位于 libavcodec（不在 avutil）。 */
  static const char *const avcodec_names[] = {"avcodec_find_decoder",
                                              "avcodec_alloc_context3",
                                              "avcodec_parameters_to_context",
                                              "avcodec_open2",
                                              "avcodec_send_packet",
                                              "avcodec_receive_frame",
                                              "avcodec_flush_buffers",
                                              "av_packet_alloc",
                                              "av_packet_unref"};
  static const char *const avformat_names[] = {"avformat_open_input",
                                               "avformat_find_stream_info",
                                               "av_read_frame",
                                               "av_seek_frame",
                                               "avformat_close_input"};
  static const char *const swscale_names[] = {"sws_getContext", "sws_scale",
                                              "sws_freeContext"};
  FARPROC f[9];

  if (av_load_lib("avutil-*.dll", avutil_names, f, 1) != 0) return 1;
  p_av_frame_alloc = (fn_av_frame_alloc)f[0];
  if (av_load_lib("avcodec-*.dll", avcodec_names, f, 9) != 0) return 1;
  p_avcodec_find_decoder = (fn_avcodec_find_decoder)f[0];
  p_avcodec_alloc_context3 = (fn_avcodec_alloc_context3)f[1];
  p_avcodec_parameters_to_context = (fn_avcodec_parameters_to_context)f[2];
  p_avcodec_open2 = (fn_avcodec_open2)f[3];
  p_avcodec_send_packet = (fn_avcodec_send_packet)f[4];
  p_avcodec_receive_frame = (fn_avcodec_receive_frame)f[5];
  p_avcodec_flush_buffers = (fn_avcodec_flush_buffers)f[6];
  p_av_packet_alloc = (fn_av_packet_alloc)f[7];
  p_av_packet_unref = (fn_av_packet_unref)f[8];
  if (av_load_lib("avformat-*.dll", avformat_names, f, 5) != 0) return 1;
  p_avformat_open_input = (fn_avformat_open_input)f[0];
  p_avformat_find_stream_info = (fn_avformat_find_stream_info)f[1];
  p_av_read_frame = (fn_av_read_frame)f[2];
  p_av_seek_frame = (fn_av_seek_frame)f[3];
  p_avformat_close_input = (fn_avformat_close_input)f[4];
  if (av_load_lib("swscale-*.dll", swscale_names, f, 3) != 0) return 1;
  p_sws_getContext = (fn_sws_getContext)f[0];
  p_sws_scale = (fn_sws_scale)f[1];
  p_sws_freeContext = (fn_sws_freeContext)f[2];
  return 0;
}

/* 打开本 worker 的解码器实例（每 worker 首次预览时懒调用）。 */
static int av_prev_open(AvPrev *a) {
  const AVCodec *codec;
  int i;
  a->vindex = -1;
  a->sws_fmt = -1;
  if (p_avformat_open_input(&a->ic, g_video_path, NULL, NULL) != 0) return 1;
  if (p_avformat_find_stream_info(a->ic, NULL) < 0) return 1;
  for (i = 0; i < (int)a->ic->nb_streams; i++) {
    if (a->ic->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      a->vindex = i;
      break;
    }
  }
  if (a->vindex < 0) return 1;
  codec = p_avcodec_find_decoder(a->ic->streams[a->vindex]->codecpar->codec_id);
  if (codec == NULL) return 1;
  a->dec = p_avcodec_alloc_context3(codec);
  if (a->dec == NULL) return 1;
  if (p_avcodec_parameters_to_context(
          a->dec, a->ic->streams[a->vindex]->codecpar) < 0) {
    return 1;
  }
  /* 单帧延迟优先：slice 线程（frame 线程要多喂几包才出第一帧）。
   * Rext 等高码率源实测单帧解码与线程数无关（单核瓶颈），跟手吞吐靠
   * 多 worker 实例并行而非解码线程数。 */
  a->dec->thread_count = 8;
  a->dec->thread_type = FF_THREAD_SLICE;
  if (p_avcodec_open2(a->dec, codec, NULL) < 0) return 1;
  a->pkt = p_av_packet_alloc();
  a->frame = p_av_frame_alloc();
  if (a->pkt == NULL || a->frame == NULL) return 1;
  return 0;
}

/* 内嵌解码器拖动预览（worker 实例）：av_seek_frame 关键帧直达 + 解首帧
 * → swscale 到本 worker 的预览缓冲（不上屏，prev_publish 统一上屏）。 */
static int av_prev_fetch(AvPrev *a, double frac) {
  uint8_t *dst[4];
  int stride[4];
  if (a->buf == NULL) {
    a->buf = (unsigned char *)malloc((size_t)g_prev_w * g_prev_h * 3);
    if (a->buf == NULL) return 1;
  }
  if (p_av_seek_frame(a->ic, -1, (int64_t)(frac * (double)a->ic->duration),
                      AVSEEK_FLAG_BACKWARD) < 0) {
    return 1;
  }
  p_avcodec_flush_buffers(a->dec);
  for (;;) {
    if (p_av_read_frame(a->ic, a->pkt) < 0) return 1;
    if (a->pkt->stream_index == a->vindex) {
      p_avcodec_send_packet(a->dec, a->pkt); /* frame 线程排队不会 EAGAIN */
      while (p_avcodec_receive_frame(a->dec, a->frame) == 0) {
        if (a->sws == NULL || a->sws_w != a->frame->width ||
            a->sws_h != a->frame->height || a->sws_fmt != a->frame->format) {
          if (a->sws != NULL) p_sws_freeContext(a->sws);
          a->sws = p_sws_getContext(
              a->frame->width, a->frame->height,
              (enum AVPixelFormat)a->frame->format, g_prev_w, g_prev_h,
              AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
          if (a->sws == NULL) return 1;
          a->sws_w = a->frame->width;
          a->sws_h = a->frame->height;
          a->sws_fmt = a->frame->format;
        }
        dst[0] = a->buf;
        stride[0] = g_prev_w * 3;
        p_sws_scale(a->sws, (const uint8_t *const *)a->frame->data,
                    a->frame->linesize, 0, a->frame->height, dst, stride);
        p_av_packet_unref(a->pkt);
        return 0;
      }
    }
    p_av_packet_unref(a->pkt);
  }
}
#endif /* HAVE_AV */

/* ---- 控制条按钮（客户区坐标）---- */
static const RECT BTN_MODE = {8, 4, 128, 28};
static const RECT BTN_SRC = {136, 4, 276, 28};
static const RECT BTN_PLAY = {284, 4, 364, 28};

static int hit(const RECT *r, int x, int y) {
  return x >= r->left && x < r->right && y >= r->top && y < r->bottom;
}

static void draw_button(HDC dc, const RECT *r, const wchar_t *text,
                        int enabled) {
  HBRUSH br = CreateSolidBrush(enabled ? RGB(58, 58, 58) : RGB(42, 42, 42));
  SetTextColor(dc, enabled ? RGB(235, 235, 235) : RGB(120, 120, 120));
  FillRect(dc, r, br);
  FrameRect(dc, r, (HBRUSH)GetStockObject(GRAY_BRUSH));
  SetBkMode(dc, TRANSPARENT);
  DrawTextW(dc, text, -1, (RECT *)r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  DeleteObject(br);
}

static RECT contain_rect(int ax, int ay, int aw, int ah) {
  double s = (double)aw / g_w;
  RECT r;
  int w, h;
  if ((double)ah / g_h < s) s = (double)ah / g_h;
  w = (int)(g_w * s);
  h = (int)(g_h * s);
  r.left = ax + (aw - w) / 2;
  r.top = ay + (ah - h) / 2;
  r.right = r.left + w;
  r.bottom = r.top + h;
  return r;
}

/* ---- 强缩小显示的盒滤波预缩小（omp）----
 * 4K 帧在 1280 窗口下每帧两路 StretchBlt HALFTONE（CPU 高质量重采样，
 * 百毫秒级）是播放显示瓶颈；改为整数因子盒滤波预缩小到缓存小图
 *（质量接近 HALFTONE）+ 近 1:1 COLORONCOLOR 上屏（毫秒级）。 */
static HBITMAP g_shrink_dib = NULL;
static unsigned char *g_shrink_dib_bits = NULL;
static int g_shrink_w = 0, g_shrink_h = 0;

static int ensure_shrink_dib(HDC dc, int w, int h) {
  BITMAPINFO bi;
  if (g_shrink_dib != NULL && g_shrink_w == w && g_shrink_h == h) return 1;
  if (g_shrink_dib != NULL) DeleteObject(g_shrink_dib);
  g_shrink_dib = NULL;
  memset(&bi, 0, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 24;
  bi.bmiHeader.biCompression = BI_RGB;
  g_shrink_dib = CreateDIBSection(dc, &bi, DIB_RGB_COLORS,
                                  (void **)&g_shrink_dib_bits, NULL, 0);
  if (g_shrink_dib == NULL) return 0;
  g_shrink_w = w;
  g_shrink_h = h;
  return 1;
}

/* 24bpp（BGR，DIB 行序）bits 按整数因子 f 盒滤波缩小到 sw/f × sh/f。 */
static void shrink_box(const unsigned char *bits, int sw, int sh, int f) {
  const int ow = sw / f, oh = sh / f;
  const int sstride = (sw * 3 + 3) & ~3;
  const int ostride = (ow * 3 + 3) & ~3;
  const unsigned div = (unsigned)(f * f);
  int y;
#pragma omp parallel for
  for (y = 0; y < oh; y++) {
    unsigned char *orow = g_shrink_dib_bits + (size_t)y * ostride;
    int x, yy, xx;
    for (x = 0; x < ow; x++) {
      unsigned sum0 = 0, sum1 = 0, sum2 = 0;
      const unsigned char *base =
          bits + (size_t)y * f * sstride + (size_t)x * f * 3;
      for (yy = 0; yy < f; yy++) {
        const unsigned char *p = base + (size_t)yy * sstride;
        for (xx = 0; xx < f; xx++, p += 3) {
          sum0 += p[0];
          sum1 += p[1];
          sum2 += p[2];
        }
      }
      orow[x * 3 + 0] = (unsigned char)(sum0 / div);
      orow[x * 3 + 1] = (unsigned char)(sum1 / div);
      orow[x * 3 + 2] = (unsigned char)(sum2 / div);
    }
  }
}

/* 任意比例定点双线性缩小到 dw × dh（Q8 权重，omp 按行；中等缩小
 *（1.1~3 倍）替代 HALFTONE——后者每路 ~10ms 级，scale 播放的帧率坑）。 */
static void shrink_bilinear(const unsigned char *bits, int sw, int sh,
                            int dw, int dh) {
  const int sstride = (sw * 3 + 3) & ~3;
  const int ostride = (dw * 3 + 3) & ~3;
  const int64_t sx_step = ((int64_t)sw << 16) / (dw > 0 ? dw : 1);
  const int64_t sy_step = ((int64_t)sh << 16) / (dh > 0 ? dh : 1);
  int y;
#pragma omp parallel for
  for (y = 0; y < dh; y++) {
    unsigned char *orow = g_shrink_dib_bits + (size_t)y * ostride;
    /* 中心对齐：src = (dst + 0.5) * s/d - 0.5（Q16 定点）。 */
    const int64_t syf = (int64_t)y * sy_step + (sy_step >> 1) - 32768;
    int sy = (int)(syf >> 16);
    unsigned fy;
    int x;
    if (sy < 0) sy = 0;
    if (sy > sh - 2) sy = sh - 2 >= 0 ? sh - 2 : 0;
    fy = (unsigned)(syf - ((int64_t)sy << 16)) >> 8;
    if (fy > 255) fy = 255;
    for (x = 0; x < dw; x++) {
      const int64_t sxf = (int64_t)x * sx_step + (sx_step >> 1) - 32768;
      int sx = (int)(sxf >> 16);
      unsigned fx;
      const unsigned char *p0, *p1;
      if (sx < 0) sx = 0;
      if (sx > sw - 2) sx = sw - 2 >= 0 ? sw - 2 : 0;
      fx = (unsigned)(sxf - ((int64_t)sx << 16)) >> 8;
      if (fx > 255) fx = 255;
      p0 = bits + (size_t)sy * sstride + (size_t)sx * 3;
      p1 = p0 + sstride;
      {
        const unsigned w0x = 256 - fx, w0y = 256 - fy;
        const unsigned w00 = w0x * w0y, w01 = fx * w0y;
        const unsigned w10 = w0x * fy, w11 = fx * fy;
        const unsigned b0 = (unsigned)p0[0] * w00 + (unsigned)p0[3] * w01 +
                            (unsigned)p1[0] * w10 + (unsigned)p1[3] * w11;
        const unsigned b1 = (unsigned)p0[1] * w00 + (unsigned)p0[4] * w01 +
                            (unsigned)p1[1] * w10 + (unsigned)p1[4] * w11;
        const unsigned b2 = (unsigned)p0[2] * w00 + (unsigned)p0[5] * w01 +
                            (unsigned)p1[2] * w10 + (unsigned)p1[5] * w11;
        orow[x * 3 + 0] = (unsigned char)((b0 + 32768) >> 16);
        orow[x * 3 + 1] = (unsigned char)((b1 + 32768) >> 16);
        orow[x * 3 + 2] = (unsigned char)((b2 + 32768) >> 16);
      }
    }
  }
}

static void blit_dib_dims(HDC dc, HBITMAP dib, const unsigned char *bits,
                          const RECT *r, int sw, int sh) {
  HDC mem;
  const int dw = r->right - r->left;
  const int dh = r->bottom - r->top;
  if (dib == NULL) return;
  /* 强缩小（≥3 倍）走盒滤波预缩小 + 近 1:1 COLORONCOLOR。 */
  if (bits != NULL && dw > 0 && dh > 0 && sw > dw * 3 && sh > 0) {
    int f = sw / dw;
    if (sh > dh * 3 && sh / dh < f) f = sh / dh;
    if (f >= 3) {
      const int ow = sw / f, oh = sh / f;
      if (ensure_shrink_dib(dc, ow, oh)) {
        shrink_box(bits, sw, sh, f);
        mem = CreateCompatibleDC(dc);
        SelectObject(mem, g_shrink_dib);
        SetStretchBltMode(dc, COLORONCOLOR);
        StretchBlt(dc, r->left, r->top, dw, dh, mem, 0, 0, ow, oh, SRCCOPY);
        DeleteDC(mem);
        return;
      }
    }
  }
  /* 中等缩小（>1.1 倍、<3 倍）走定点双线性到目标尺寸 + 1:1 上屏。 */
  if (bits != NULL && dw > 0 && dh > 0 &&
      (dw * 10 < sw * 9 || dh * 10 < sh * 9)) {
    if (ensure_shrink_dib(dc, dw, dh)) {
      shrink_bilinear(bits, sw, sh, dw, dh);
      mem = CreateCompatibleDC(dc);
      SelectObject(mem, g_shrink_dib);
      SetStretchBltMode(dc, COLORONCOLOR);
      StretchBlt(dc, r->left, r->top, dw, dh, mem, 0, 0, dw, dh, SRCCOPY);
      DeleteDC(mem);
      return;
    }
  }
  mem = CreateCompatibleDC(dc);
  SelectObject(mem, dib);
  /* 近 1:1/放大用 COLORONCOLOR（HALFTONE 是 GDI 的 CPU 高质量重采样，
   * 每次拉伸数 ms 起步，是窗口模式帧率大坑）；强缩小保留 HALFTONE
   * 画质。 */
  SetStretchBltMode(dc, (r->right - r->left) * 10 >= sw * 9 ? COLORONCOLOR
                                                            : HALFTONE);
  StretchBlt(dc, r->left, r->top, r->right - r->left, r->bottom - r->top, mem,
             0, 0, sw, sh, SRCCOPY);
  DeleteDC(mem);
}

static void blit_dib(HDC dc, HBITMAP dib, const unsigned char *bits,
                     const RECT *r) {
  blit_dib_dims(dc, dib, bits, r, g_w, g_h);
}

/* 1x1 黑（32bpp）源 DC：AlphaBlend 常数 alpha 置灰用（拖动中标记右侧
 * 处理后画面已冻结）。 */
static HDC g_dim_dc = NULL;

static void dim_rect(HDC dc, const RECT *r) {
  BLENDFUNCTION bf;
  if (g_dim_dc == NULL) {
    BITMAPINFO bi;
    void *bits = NULL;
    HBITMAP b;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = 1;
    bi.bmiHeader.biHeight = 1;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    b = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (b == NULL || bits == NULL) return;
    *(unsigned long *)bits = 0;
    g_dim_dc = CreateCompatibleDC(dc);
    SelectObject(g_dim_dc, b);
  }
  bf.BlendOp = AC_SRC_OVER;
  bf.BlendFlags = 0;
  bf.SourceConstantAlpha = 100;
  bf.AlphaFormat = 0;
  AlphaBlend(dc, r->left, r->top, r->right - r->left, r->bottom - r->top,
             g_dim_dc, 0, 0, 1, 1, bf);
}

/* 后备位图/内存 DC 按客户区尺寸缓存：每帧 WM_PAINT 都
 * CreateCompatibleBitmap/DeleteDC 的 GDI 对象分配是帧率大坑；尺寸变化
 *（WM_SIZE 后首次绘制）时自动重建。 */
static HDC g_back_dc = NULL;
static HBITMAP g_back_bmp = NULL;
static int g_back_w = 0, g_back_h = 0;

static HDC back_dc(HDC dc, int w, int h) {
  if (g_back_dc != NULL && (w != g_back_w || h != g_back_h)) {
    DeleteObject(g_back_bmp);
    DeleteDC(g_back_dc);
    g_back_dc = NULL;
  }
  if (g_back_dc == NULL) {
    g_back_dc = CreateCompatibleDC(dc);
    g_back_bmp = CreateCompatibleBitmap(dc, w > 0 ? w : 1, h > 0 ? h : 1);
    SelectObject(g_back_dc, g_back_bmp);
    g_back_w = w;
    g_back_h = h;
  }
  return g_back_dc;
}

static void draw(HDC dc, const RECT *client) {
  HDC mem = back_dc(dc, client->right, client->bottom);
  HBRUSH bar = CreateSolidBrush(RGB(37, 37, 37));
  RECT barR = {0, 0, client->right, BAR_H};
  RECT area = {0, BAR_H, client->right, client->bottom - PROG_H - STATUS_H};
  RECT progR = {0, client->bottom - PROG_H - STATUS_H, client->right,
                client->bottom - STATUS_H};
  RECT statusR = {0, client->bottom - STATUS_H, client->right,
                  client->bottom};
  HBRUSH black = (HBRUSH)GetStockObject(BLACK_BRUSH);
  HBRUSH progBg = CreateSolidBrush(RGB(24, 24, 24));
  HBRUSH progFg = CreateSolidBrush(RGB(33, 150, 243));
  wchar_t text[160];
  double frac = 0.0;
  /* 认领最新完成帧（工作线程三缓冲发布；拖动中工作线程暂停，ready 不
   * 变，右侧处理后画面自然冻结）。 */
  g_pb_show = InterlockedExchange(&g_pb_ready, g_pb_show);
  FillRect(mem, client, black);
  FillRect(mem, &barR, bar);
  draw_button(mem, &BTN_MODE, g_single_mode ? L"模式: 单视频" : L"模式: 并列",
              1);
  draw_button(mem, &BTN_SRC, g_show_processed ? L"处理后" : L"原图",
              g_single_mode);
  draw_button(mem, &BTN_PLAY, g_playing ? L"暂停" : L"播放", 1);
  /* 控制条：上一帧管线本体耗时（不含读流/装帧/解包）。 */
  if (g_video) {
    _snwprintf(text, 160, L"处理 %lums", (unsigned long)g_proc_ms);
  } else {
    _snwprintf(text, 160, L"帧 %d/%d  处理 %lums", g_frame + 1,
               g_frames > 0 ? g_frames : 1, (unsigned long)g_proc_ms);
  }
  text[159] = L'\\0';
  SetTextColor(mem, RGB(160, 160, 160));
  SetBkMode(mem, TRANSPARENT);
  TextOutW(mem, 380, 10, text, (int)wcslen(text));
  /* 视频区：拖动中并列模式只换左侧（右侧处理后画面冻结置灰），
   * 单视频模式整幅预览；松开恢复前后对比。 */
  if (g_single_mode) {
    const RECT dst = contain_rect(area.left, area.top, area.right,
                                  area.bottom - area.top);
    if (g_dragging && g_video && g_dib_prev != NULL) {
      EnterCriticalSection(&g_prev_cs);
      blit_dib_dims(mem, g_dib_prev, g_dib_prev_bits, &dst, g_prev_w,
                    g_prev_h);
      LeaveCriticalSection(&g_prev_cs);
    } else {
      blit_dib(mem,
               g_show_processed ? g_pb_dst[g_pb_show] : g_pb_src[g_pb_show],
               g_show_processed ? g_pb_dst_bits[g_pb_show]
                                : g_pb_src_bits[g_pb_show],
               &dst);
    }
  } else {
    const int halfW = area.right / 2;
    const RECT l = contain_rect(0, area.top, halfW, area.bottom - area.top);
    const RECT rr =
        contain_rect(halfW, area.top, area.right - halfW, area.bottom - area.top);
    if (g_dragging && g_video && g_dib_prev != NULL) {
      EnterCriticalSection(&g_prev_cs);
      blit_dib_dims(mem, g_dib_prev, g_dib_prev_bits, &l, g_prev_w,
                    g_prev_h);
      LeaveCriticalSection(&g_prev_cs);
    } else {
      blit_dib(mem, g_pb_src[g_pb_show], g_pb_src_bits[g_pb_show], &l);
    }
    blit_dib(mem, g_pb_dst[g_pb_show], g_pb_dst_bits[g_pb_show], &rr);
    if (g_dragging && g_video) dim_rect(mem, &rr);
    {
      HBRUSH divb = CreateSolidBrush(RGB(90, 90, 90));
      RECT div = {halfW - 1, area.top, halfW + 1, area.bottom};
      FillRect(mem, &div, divb);
      DeleteObject(divb);
    }
  }
  /* 进度条：视频按播放位置，图案/BMP 按帧号占比；拖动中即时跟随鼠标
   *（点击/拖动见 WM_LBUTTONDOWN/WM_MOUSEMOVE/WM_LBUTTONUP）。 */
  if (g_dragging) {
    frac = g_drag_frac;
  } else if (g_video) {
    frac = g_duration > 0.0 ? g_pos / g_duration : 0.0;
  } else if (g_frames > 1) {
    frac = (double)g_frame / (g_frames - 1);
  }
  if (frac < 0.0) frac = 0.0;
  if (frac > 1.0) frac = 1.0;
  FillRect(mem, &progR, progBg);
  {
    RECT fillR = {progR.left + 2, progR.top + 4,
                  progR.left + 2 +
                      (int)((progR.right - progR.left - 4) * frac),
                  progR.bottom - 4};
    FillRect(mem, &fillR, progFg);
  }
  /* 状态栏：分辨率（缩放时标注原分辨率） + 实时帧率 + 播放位置
   *（或帧号）。 */
  FillRect(mem, &statusR, bar);
  if (g_video) {
    wchar_t pos[24], dur[24];
    _snwprintf(pos, 24, L"%02d:%04.1f", (int)(g_pos / 60),
               g_pos - (int)(g_pos / 60) * 60);
    pos[23] = L'\\0';
    _snwprintf(dur, 24, L"%02d:%04.1f", (int)(g_duration / 60),
               g_duration - (int)(g_duration / 60) * 60);
    dur[23] = L'\\0';
    if (g_scale_w > 0) {
      _snwprintf(text, 160, L"%dx%d（原 %dx%d） %s   %.1f fps   %s / %s",
                 g_w, g_h, g_native_w, g_native_h, g_hw ? L"GPU" : L"SW",
                 ui_fps(), pos, dur);
    } else {
      _snwprintf(text, 160, L"%dx%d %s   %.1f fps   %s / %s", g_w, g_h,
                 g_hw ? L"GPU" : L"SW", ui_fps(), pos, dur);
    }
  } else {
    _snwprintf(text, 160, L"%dx%d   %.1f fps   帧 %d/%d", g_w, g_h,
               ui_fps(), g_frame + 1, g_frames > 0 ? g_frames : 1);
  }
  text[159] = L'\\0';
  TextOutW(mem, 8, statusR.top + 3, text, (int)wcslen(text));
  BitBlt(dc, 0, 0, client->right, client->bottom, mem, 0, 0, SRCCOPY);
  DeleteObject(progBg);
  DeleteObject(progFg);
  DeleteObject(bar);
}

/* ---- 拖动预览工作线程池 ----
 * 解码在 UI 线程外进行；UI 经 prev_post 原子更新（位置, 序号），worker
 * 只认领最新序号（中间位置直接跳过）。Rext/HEVC 等高码率源的单帧软解
 * 是单核瓶颈（实测与解码线程数无关），单 worker 跟手吞吐 ~6fps——池化
 * 后各 worker 持独立 libav 实例并行解码不同请求，吞吐随 worker 数放
 * 大；上屏按序号丢弃迟到帧（旧帧不覆盖新帧）。预览 DIB 更新经
 * g_prev_cs 与绘制互斥；落定（松开）经 g_claim_cs 封锁新认领 +
 * g_prev_nbusy 等空闲，避免与 ff_kill/ff_spawn 争用解码流句柄。 */
#define PREV_POOL 3
static CRITICAL_SECTION g_claim_cs;      /* 请求/认领锁（WinMain 初始化） */
static HANDLE g_prev_threads[PREV_POOL];
static int g_prev_nthreads = 0;
static HANDLE g_prev_evt = NULL;          /* 有新预览请求 */
static volatile LONG g_prev_seq = 0;      /* 请求序号（prev_post 递增） */
static volatile double g_prev_frac = 0.0; /* 最新请求位置（与序号同锁更新） */
static volatile LONG g_prev_disp = 0;     /* 已认领的最大序号 */
static volatile LONG g_prev_shown = 0;    /* 已上屏的最大序号 */
static volatile int g_prev_quit = 0;
static volatile LONG g_prev_nbusy = 0;    /* 解码中的 worker 数 */
static HWND g_prev_hwnd = NULL;
#if HAVE_AV
static AvPrev g_avx[PREV_POOL];
#endif

/* 投递预览请求（UI 线程；序号与位置同锁更新，worker 读到一致对）。 */
static void prev_post(double frac) {
  EnterCriticalSection(&g_claim_cs);
  g_prev_frac = frac;
  InterlockedIncrement(&g_prev_seq);
  LeaveCriticalSection(&g_claim_cs);
  SetEvent(g_prev_evt);
}

/* 上屏：仅当帧序号更新且仍在拖动中（落定后不再覆盖精确画面）。 */
static void prev_publish(LONG seq, double frac, const unsigned char *rgb) {
  EnterCriticalSection(&g_prev_cs);
  if (seq > g_prev_shown && g_dragging) {
    fill_dib(g_dib_prev_bits, rgb, g_prev_w, g_prev_h);
    g_prev_shown = seq;
    g_pos = frac * g_duration; /* 关键帧精度近似位置 */
  }
  LeaveCriticalSection(&g_prev_cs);
  InvalidateRect(g_prev_hwnd, NULL, FALSE);
}

static DWORD WINAPI preview_worker(void *arg) {
  const int k = (int)(intptr_t)arg;
  for (;;) {
    LONG c = 0, s;
    double f;
    WaitForSingleObject(g_prev_evt, INFINITE);
    if (g_prev_quit) return 0;
    for (;;) {
      EnterCriticalSection(&g_claim_cs);
      s = g_prev_seq;
      if (!g_prev_quit && g_prev_disp < s) {
        /* 直接跳认最新序号：中间位置的请求不解码（快速拖动天然合并）。 */
        g_prev_disp = s;
        c = s;
        f = g_prev_frac;
        InterlockedIncrement(&g_prev_nbusy);
      }
      LeaveCriticalSection(&g_claim_cs);
      if (c == 0) break;
#if HAVE_AV
      if (g_av_ok) {
        AvPrev *a = &g_avx[k];
        if (a->ready == 0) {
          a->ready = av_prev_open(a) == 0 ? 1 : -1;
        }
        if (a->ready == 1 && av_prev_fetch(a, f) == 0) {
          prev_publish(c, f, a->buf);
        }
      } else
#endif
      {
        /* 子进程回退预览与管线工作线程共享解码流句柄（ff_spawn_ex 会
         * 重建主流），互斥防并发（HAVE_AV 路径实例独立，无需锁）。 */
        int src;
        EnterCriticalSection(&g_stream_cs);
        src = seek_preview(f);
        LeaveCriticalSection(&g_stream_cs);
        if (src == 0) {
          prev_publish(c, f, g_prev_buf);
        }
      }
      InterlockedDecrement(&g_prev_nbusy);
      c = 0;
    }
  }
}

/* 懒启动预览线程池（AV 可用时 PREV_POOL 个，子进程兜底 1 个——后者共
 * 享 g_prev_buf/解码流句柄，不能并行）。WM_DESTROY 时停止。 */
static void preview_pool_start(HWND hwnd) {
  int i, n = 1;
  if (g_prev_nthreads > 0) return;
  g_prev_hwnd = hwnd;
#if HAVE_AV
  if (g_av_ok) n = PREV_POOL;
#endif
  if (g_prev_evt == NULL) {
    g_prev_evt = CreateEvent(NULL, FALSE, FALSE, NULL);
  }
  g_prev_quit = 0;
  for (i = 0; i < n; i++) {
    g_prev_threads[i] =
        CreateThread(NULL, 0, preview_worker, (void *)(intptr_t)i, 0, NULL);
  }
  g_prev_nthreads = n;
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_CREATE:
    /* 走帧由管线工作线程驱动（WinMain 启动），UI 不定时不走帧。 */
    return 0;
  case WM_APP_FRAME:
    /* 工作线程发布了新帧（三缓冲 ready 已换）：重绘时认领。 */
    InvalidateRect(hwnd, NULL, FALSE);
    return 0;
  case WM_KEYDOWN:
    if (wp == VK_SPACE && g_single_mode) {
      g_show_processed = !g_show_processed;
      InvalidateRect(hwnd, NULL, FALSE);
    } else if (wp == VK_ESCAPE) {
      DestroyWindow(hwnd);
    }
    return 0;
  case WM_LBUTTONDOWN: {
    const int x = (int)(short)LOWORD(lp), y = (int)(short)HIWORD(lp);
    RECT cr;
    GetClientRect(hwnd, &cr);
    if (hit(&BTN_MODE, x, y)) {
      g_single_mode = !g_single_mode;
      InvalidateRect(hwnd, NULL, FALSE);
    } else if (g_single_mode && hit(&BTN_SRC, x, y)) {
      g_show_processed = !g_show_processed;
      InvalidateRect(hwnd, NULL, FALSE);
    } else if (hit(&BTN_PLAY, x, y)) {
      g_playing = !g_playing;
      /* 唤醒工作线程（恢复播放的墙钟复位由工作线程做，见
       * pipe_worker 的 was_paused）。 */
      SetEvent(g_pipe_evt);
      InvalidateRect(hwnd, NULL, FALSE);
    } else if (y >= cr.bottom - PROG_H - STATUS_H &&
               y < cr.bottom - STATUS_H) {
      /* 进度条：按下即预览并开始拖动（SetCapture 使拖出窗口仍收鼠标
       * 消息）；播放/暂停状态均生效且不改变播放状态。视频投递预览请求
       * 到工作线程（UI 不阻塞）；图案/BMP 直接精确跳帧。 */
      g_dragging = 1;
      g_drag_moved = 0;
      SetCapture(hwnd);
      SetEvent(g_pipe_evt); /* 工作线程尽快暂停走帧（见 pipe_worker） */
      g_drag_frac = (double)x / (cr.right > 0 ? cr.right : 1);
      if (g_video && g_duration > 0.0) {
        if (g_prev_buf == NULL) alloc_prev();
        preview_pool_start(hwnd);
        prev_post(g_drag_frac);
      } else {
        /* 图案/BMP：投递精确跳帧请求（工作线程处理，UI 不阻塞）。 */
        post_seek(g_drag_frac);
        g_last_seek = GetTickCount();
      }
      InvalidateRect(hwnd, NULL, FALSE);
    }
    return 0;
  }
  case WM_MOUSEMOVE: {
    if (g_dragging && (wp & MK_LBUTTON)) {
      const int x = (int)(short)LOWORD(lp);
      RECT cr;
      GetClientRect(hwnd, &cr);
      g_drag_frac = (double)x / (cr.right > 0 ? cr.right : 1);
      if (g_drag_frac < 0.0) g_drag_frac = 0.0;
      if (g_drag_frac > 1.0) g_drag_frac = 1.0;
      g_drag_moved = 1;
      if (g_video && g_duration > 0.0) {
        prev_post(g_drag_frac); /* worker 只认领最新序号 */
      } else if (GetTickCount() - g_last_seek >= 150) {
        post_seek(g_drag_frac);
        g_last_seek = GetTickCount();
      }
      InvalidateRect(hwnd, NULL, FALSE);
    }
    return 0;
  }
  case WM_LBUTTONUP: {
    if (g_dragging) {
      const int x = (int)(short)LOWORD(lp);
      RECT cr;
      GetClientRect(hwnd, &cr);
      g_dragging = 0;
      ReleaseCapture();
      /* 松开/点击落定：视频做精确 seek + 全尺寸管线处理（恢复前后对
       * 比画面；按下/拖动只是关键帧级预览）；图案/BMP 拖过才需要落定
       *（纯点击在按下时已是精确跳帧，不重复）。 */
      if (g_video) {
        /* 封锁新认领并等在途解码完成（≤ 单次解码时长），落定重建在
         * 管线工作线程上做（post_seek 异步投递，g_stream_cs 与在途
         * 子进程预览互斥）。 */
        EnterCriticalSection(&g_claim_cs);
        g_prev_disp = g_prev_seq;
        LeaveCriticalSection(&g_claim_cs);
        while (g_prev_nbusy > 0) Sleep(5);
        post_seek((double)x / (cr.right > 0 ? cr.right : 1));
      } else if (g_drag_moved) {
        post_seek((double)x / (cr.right > 0 ? cr.right : 1));
      }
      InvalidateRect(hwnd, NULL, FALSE);
    }
    return 0;
  }
  case WM_CAPTURECHANGED:
    g_dragging = 0;
    SetEvent(g_pipe_evt); /* 工作线程重估拖动/暂停状态 */
    return 0;
  case WM_PAINT: {
    PAINTSTRUCT ps;
    RECT client;
    HDC dc = BeginPaint(hwnd, &ps);
    GetClientRect(hwnd, &client);
    draw(dc, &client);
    EndPaint(hwnd, &ps);
    return 0;
  }
  case WM_DESTROY:
    /* 先汇合管线工作线程（事件唤醒 + 等退出），再停预览线程/释放资
     * 源——工作线程可能正持有 g_stream_cs 处理或阻塞在帧环等待。 */
    g_pipe_quit = 1;
    SetEvent(g_pipe_evt);
    if (g_pipe_thread != NULL) {
      WaitForSingleObject(g_pipe_thread, 10000);
      CloseHandle(g_pipe_thread);
      g_pipe_thread = NULL;
    }
    if (g_prev_nthreads > 0) {
      int i;
      g_prev_quit = 1;
      SetEvent(g_prev_evt);
      for (i = 0; i < g_prev_nthreads; i++) {
        WaitForSingleObject(g_prev_threads[i], 2000);
        CloseHandle(g_prev_threads[i]);
      }
      g_prev_nthreads = 0;
    }
    if (g_back_dc != NULL) {
      DeleteObject(g_back_bmp);
      DeleteDC(g_back_dc);
      g_back_dc = NULL;
    }
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmdLine,
                   int nShow) {
  int i, frames = -1, dump = 0;
  const char *bmp_path = NULL;
  WNDCLASSW wc;
  HWND hwnd;
  MSG msg;
  RECT wr = {0, 0, DEFW * 2, DEFH + BAR_H + PROG_H + STATUS_H};
  (void)hPrev;
  (void)lpCmdLine;

  /* OpenMP 线程数封顶（不超过 16、核数-2）：默认线程数等于逻辑核数，
   * 大核数机器上装帧/解包的小并行区每帧唤醒上百个 vcomp 工作线程，
   * 帧间隙空转自旋把全机核占满（实测 112 线程机占 ~106 核）。装帧/解
   * 包是 4K HSL 逐像素转换，16 线程内可近线性加速；行/像素并行结果
   * 逐位一致，与线程数无关。 */
  {
    SYSTEM_INFO si;
    int nt;
    GetSystemInfo(&si);
    nt = (int)si.dwNumberOfProcessors - 2;
    if (nt > 16) nt = 16;
    if (nt < 1) nt = 1;
    omp_set_num_threads(nt);
  }
  /* 验证工具不应拖垮整机：低于普通优先级运行（ffmpeg 子进程同样，
   * 见 ff_spawn），软解 8K/Rext 源解码满载时桌面保持响应。 */
  SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
  InitializeCriticalSection(&g_prev_cs); /* 预览 DIB 读写锁（拖动预览） */
  InitializeCriticalSection(&g_claim_cs); /* 预览请求/认领锁（同上） */
  InitializeCriticalSection(&g_r_cs); /* 解码预读环（读者线程 ↔ 消费） */
  InitializeCriticalSection(&g_stream_cs); /* 解码流句柄（管线工作线程 ↔
                                              子进程预览回退） */
  InitializeConditionVariable(&g_r_has_data);
  InitializeConditionVariable(&g_r_has_room);
  g_pipe_evt = CreateEvent(NULL, TRUE, FALSE, NULL); /* 手复：seek/暂停/
                                                        拖动/退出唤醒 */
  /* Win10 1803+ 高分辨率可等待定时器（走帧到期等待；创建失败回退事件
   * 超时等待，见 wait_ms）。 */
  g_hires_timer = CreateWaitableTimerExW(
      NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);

  /* 命令行：--frames N / --dump-hash / --bmp <路径> /
   * --video <路径> --ffmpeg <ffmpeg路径> [--scale WxH] [--swdec] */
  for (i = 1; i < __argc; i++) {
    if (strcmp(__argv[i], "--frames") == 0 && i + 1 < __argc) {
      frames = atoi(__argv[++i]);
    } else if (strcmp(__argv[i], "--dump-hash") == 0) {
      dump = 1;
    } else if (strcmp(__argv[i], "--bmp") == 0 && i + 1 < __argc) {
      bmp_path = __argv[++i];
    } else if (strcmp(__argv[i], "--video") == 0 && i + 1 < __argc) {
      _snprintf(g_video_path, MAX_PATH, "%s", __argv[++i]);
    } else if (strcmp(__argv[i], "--ffmpeg") == 0 && i + 1 < __argc) {
      _snprintf(g_ff_exe, MAX_PATH, "%s", __argv[++i]);
    } else if (strcmp(__argv[i], "--scale") == 0 && i + 1 < __argc) {
      /* --scale WxH：ffmpeg 解码时缩放（-s），见 ff_spawn。 */
      sscanf(__argv[++i], "%dx%d", &g_scale_w, &g_scale_h);
    } else if (strcmp(__argv[i], "--swdec") == 0) {
      /* 强制软解（跳过 CUDA 硬解链探测，调试用）。 */
      g_hw = 0;
    } else if (strcmp(__argv[i], "--avdir") == 0 && i + 1 < __argc) {
      /* libav* DLL 目录（拖动预览内嵌解码器；缺省/加载失败回退子进程）。 */
      _snprintf(g_av_dir, MAX_PATH, "%s", __argv[++i]);
    }
  }
  if (g_video_path[0] != '\\0' && g_ff_exe[0] != '\\0') {
    /* 视频：先探测（分辨率/时长/帧率），再决定缓冲尺寸；--scale 覆盖为
     * 缩放后的工作尺寸。 */
    g_video = 1;
    ff_probe();
    g_native_w = g_w;
    g_native_h = g_h;
    if (g_scale_w > 0 && g_scale_h > 0) {
      g_w = g_scale_w;
      g_h = g_scale_h;
    }
    if (g_w <= 0 || g_h <= 0 || g_w > 16384 || g_h > 16384) {
      fprintf(stderr, "cannot probe video: %s\\n", g_video_path);
      return 2;
    }
  } else if (bmp_path != NULL) {
    DWORD attr = GetFileAttributesA(bmp_path);
    if (attr != INVALID_FILE_ATTRIBUTES &&
        (attr & FILE_ATTRIBUTE_DIRECTORY)) {
      collect_bmp_dir(bmp_path);
    } else {
      g_bmp_files = (char **)malloc(sizeof(char *));
      g_bmp_files[0] = (char *)bmp_path;
      g_bmp_count = 1;
    }
    if (g_bmp_count > 0 && bmp_dims(g_bmp_files[0], &g_w, &g_h)) {
      g_frames = g_bmp_count;
    } else {
      fprintf(stderr, "cannot load BMP: %s\\n", bmp_path);
      return 2;
    }
  }
  if (dump || frames >= 0) {
    /* 批模式恒软解：GPU 解码/缩放与软解像素不逐位一致，对拍哈希须
     * 可复现。 */
    g_hw = 0;
    if (g_video && ff_spawn(0.0) != 0) return 2;
    return batch_run(frames >= 0 ? frames : (g_video ? 0x7fffffff : g_frames));
  }
  if (!alloc_all()) return 2;
  if (!alloc_pbufs()) return 2;
#if HAVE_AV
  /* 内嵌解码器：加载 libav* DLL 并解析符号表（解码器实例由预览工作
   * 线程池按需各自打开；失败回退子进程预览）。 */
  if (g_video && g_av_dir[0] != '\\0' && av_load_all() == 0) g_av_ok = 1;
#endif
  if (g_video) {
    /* GPU 解码链自动探测：先按 CUDA 起流读首帧；读不到（硬解初始化
     * 失败，如 Rext 4:2:2 NVDEC 不支持）回退软解重起流再试。首帧处
     * 理并发布到三缓冲（窗口未建时 PostMessage 空目标静默失败，
     * WM_PAINT 时经 ready 认领）。 */
    int rc;
    if (g_hw) {
      rc = ff_spawn(0.0) == 0 ? proc_publish(0) : 2;
      if (rc != 0) {
        g_hw = 0;
        rc = ff_spawn(0.0) == 0 ? proc_publish(0) : 2;
      }
    } else {
      rc = ff_spawn(0.0) == 0 ? proc_publish(0) : 2;
    }
    if (rc != 0) return 1;
  } else if (proc_publish(0) != 0) {
    return 1;
  }
  /* 播放墙钟起点：首帧已处理（丢帧保速对齐，见 step_frame）。 */
  if (g_video) {
    g_frame = 1;
    g_frame0 = 1;
    g_wall0 = GetTickCount();
  }

  memset(&wc, 0, sizeof(wc));
  wc.lpfnWndProc = wnd_proc;
  wc.hInstance = hInst;
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
  wc.lpszClassName = L"IspCcWinVerify";
  RegisterClassW(&wc);
  AdjustWindowRect(&wr, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
                   FALSE);
  hwnd = CreateWindowW(wc.lpszClassName, L"ISP 编组验证（前后对比）",
                       WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
                       CW_USEDEFAULT, CW_USEDEFAULT, wr.right - wr.left,
                       wr.bottom - wr.top, NULL, NULL, hInst, NULL);
  ShowWindow(hwnd, nShow);
  UpdateWindow(hwnd);
  /* 启动管线工作线程：解码消费/处理/三缓冲发布全在工作线程，UI 只
   * 绘制与输入（创建失败退化为静态首帧，不影响查看）。 */
  g_hwnd_main = hwnd;
  g_pipe_thread = CreateThread(NULL, 0, pipe_worker, NULL, 0, NULL);
  /* 提高系统定时器分辨率（wait_ms 回退路径与短 Sleep 的粒度；走帧主
   * 路径用高分辨率可等待定时器，见 pipe_worker）。进程退出前配对恢复。 */
  timeBeginPeriod(1);
  while (GetMessage(&msg, NULL, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }
  timeEndPeriod(1);
  return 0;
}
''';
}

/// 生成 WSL 内编译脚本 `compile_steps.sh` 的内容（gcc 系目标跨文件并行
/// 编译 + 链接，等效 make -j）：
/// - 并发度取 `nproc` 与文件数的小者（[jobs] 注入固定值时用之，测试/调
///   试用；默认 null 用 nproc）；
/// - 逐文件后台编译，输出重定向到 `objs/xxx.log`，进度行 `[i/N] xxx.c`
///   按源文件顺序在调度时 echo；
/// - 并发闸门控制后台任务数；随后按源文件顺序逐个 wait 取退出码：
///   失败文件按序 cat 其 log 后 exit 1；全部成功时按序 cat 非空 log
///   （保留 warning 可见性）再 echo 链接行并链接。
/// 脚本写到临时目录由 bash 从磁盘执行（不经 wsl.exe 传参层，可自由使用
/// shell 变量）。[bareMetal] 为 true（ARM 裸机）时链接加 -specs=nosys.specs。
/// FLAGS 不带 -mcpu/-mtune：按原厂文档用默认调度（mix210 工具链为
/// gcc 7.3，本就不认 cortex-a55；NEON 由 aarch64 恒预定义 __ARM_NEON
/// 保证，与调度选项无关）。
String buildWslCompileScript({
  required String gccPath,
  required List<String> sources,
  required String artifact,
  required bool bareMetal,
  int? jobs,
}) {
  final n = sources.length;
  final b = StringBuffer()
    ..writeln('#!/bin/bash')
    ..writeln('# 逐文件并行编译（等效 make -j），失败按序回显日志后退出。')
    ..writeln('set -u')
    ..writeln('mkdir -p objs')
    ..writeln('N=$n')
    ..writeln(jobs != null
        ? 'JOBS=${n < jobs ? n : jobs}'
        : 'JOBS=\$(nproc); [ "\$JOBS" -gt "\$N" ] && JOBS=\$N')
    ..writeln('GCC="$gccPath"')
    ..writeln('FLAGS="-std=c99 -O2 -Wall"')
    ..writeln('declare -a pids status')
    ..writeln('i=0');
  // 逐个后台启动 + 并发闸门。
  for (final src in sources) {
    final stem = src.substring(0, src.length - 2);
    b
      ..writeln('i=\$((i+1))')
      ..writeln('echo "[\$i/\$N] $src"')
      ..writeln('"\$GCC" \$FLAGS -c "$src" -o "objs/$stem.o" >"objs/$stem.log" 2>&1 &')
      ..writeln('pids[\$i]=\$!')
      ..writeln('while [ "\$(jobs -rp | wc -l)" -ge "\$JOBS" ]; do sleep 0.05; done');
  }
  // 按源文件顺序回收退出码。
  b.writeln('for k in \$(seq 1 \$N); do');
  b.writeln('  if wait "\${pids[\$k]}"; then status[\$k]=0; else status[\$k]=1; fi');
  b.writeln('done');
  // 按序回显日志：失败即出，成功保留 warning。
  b
    ..writeln('rc=0')
    ..writeln('k=0');
  for (final src in sources) {
    final stem = src.substring(0, src.length - 2);
    b
      ..writeln('k=\$((k+1))')
      ..writeln('if [ "\${status[\$k]}" -ne 0 ]; then cat "objs/$stem.log"; rc=1; '
          'elif [ -s "objs/$stem.log" ]; then cat "objs/$stem.log"; fi');
  }
  final objs = [
    for (final src in sources) 'objs/${src.substring(0, src.length - 2)}.o',
  ].join(' ');
  b
    ..writeln('[ "\$rc" -ne 0 ] && exit 1')
    ..writeln("echo '链接 $artifact'")
    ..write('"\$GCC" $objs -o $artifact'
        '${bareMetal ? ' -specs=nosys.specs' : ''} -lm\n');
  return b.toString();
}

/// 编译结果（结构化，供对话框/终端面板展示）。
class CCompileResult {
  final bool success;
  final int exitCode;
  final String commandLine;
  final String output;

  /// 临时工作目录（生成文件 + 编译产物）。成功与失败都保留：失败方便
  /// 排查，成功可查看产物；目录在系统 temp 下由 OS 清理，体积仅数百 KB。
  final String workDir;

  /// 成功时的产物路径（exe / elf）；失败为 null。
  final String? artifactPath;

  /// 参与编译的源文件数（不含 stub main.c）。
  final int sourceCount;

  const CCompileResult({
    required this.success,
    required this.exitCode,
    required this.commandLine,
    required this.output,
    required this.workDir,
    required this.artifactPath,
    required this.sourceCount,
  });
}

/// 合并进程环境：键名大小写不敏感地覆盖（Windows 环境块不允许同名
/// 不同写的重复键）；PATH 语义为前置。
Map<String, String> _mergedEnv(Map<String, String> overrides) {
  final env = Map<String, String>.of(Platform.environment);
  for (final e in overrides.entries) {
    final key = env.keys.firstWhere(
        (k) => k.toLowerCase() == e.key.toLowerCase(),
        orElse: () => e.key);
    if (e.key.toUpperCase() == 'PATH') {
      env[key] = '${e.value};${env[key] ?? ''}';
    } else {
      env[key] = e.value;
    }
  }
  return env;
}

/// 把 [files]（buildGroupCFiles 的产物：文件名 → 内容）写到系统 temp 下
/// 唯一子目录，追加一个 stub main.c 后编译并链接。
///
/// 生成代码没有 main，stub 里取 top 层入口函数地址返回，强制链接器解析
/// 全部符号（重复符号、未定义引用都会暴露），也防止入口被优化掉。
/// [compilerPath] 手动指定的编译器优先于自动探测。
/// [onOutput] 流式输出回调：依次收到「临时目录行 → 完整命令行 → 编译器
/// 实时输出（收到一块回调一块）→ 成功/失败结论行」；全部块的拼接即
/// 返回结果的 output（终端面板直接追加显示即可）。
/// 探测不到工具链时返回 success=false 的结果（output 为中文说明），不抛异常。
Future<CCompileResult> compileGroupCFiles(
  Map<String, String> files,
  CCompileTarget target, {
  String? topName,
  String? compilerPath,
  void Function(String chunk)? onOutput,
}) async {
  var toolchain = compilerPath != null && compilerPath.isNotEmpty
      ? toolchainFromCompilerPath(target, compilerPath)
      : (switch (target) {
          CCompileTarget.x86 => detectMsvc(),
          CCompileTarget.arm => detectArmGcc(),
          CCompileTarget.linuxCross => detectLinuxCrossGcc(),
        });
  // Linux 交叉：Windows PATH 未命中时追加 WSL 侧探测（带超时保护）。
  if (toolchain == null && compilerPath == null &&
      target == CCompileTarget.linuxCross) {
    toolchain = await detectLinuxCrossGccWsl();
  }
  if (toolchain == null) {
    final msg = switch (target) {
      CCompileTarget.x86 =>
        '未检测到 MSVC（cl.exe）。请安装 Visual Studio（含 C++ 桌面开发负载），'
            '或在上方手动填写 cl.exe 的完整路径。',
      CCompileTarget.arm =>
        '未检测到 arm-none-eabi-gcc。请安装 GNU Arm Embedded Toolchain '
            '并加入 PATH，或在上方手动填写其完整路径。',
      CCompileTarget.linuxCross => '未检测到 Linux 交叉编译 gcc。期望的可执行文件命名：\n'
          '- aarch64-mix210-linux-gcc.exe\n'
          '- riscv32-cfg5-musl-<版本段>-elf-gcc.exe\n'
          '请将其所在目录加入 PATH，或在上方手动填写完整路径\n'
          '（WSL 内工具链可填 wsl:/home/…/bin/…-gcc 形式）。',
    };
    onOutput?.call(msg);
    return CCompileResult(
      success: false,
      exitCode: -1,
      commandLine: '',
      output: msg,
      workDir: '',
      artifactPath: null,
      sourceCount: 0,
    );
  }
  // 闭包内使用不便依赖可空提升，取非空局部引用。
  final tc = toolchain;

  // ---- 写临时目录 ----
  final workDir = await Directory.systemTemp.createTemp('isp_cc_');
  for (final e in files.entries) {
    await File('${workDir.path}/${e.key}').writeAsString(e.value);
  }
  final sources = [for (final f in files.keys) if (f.endsWith('.c')) f]..sort();

  // stub main.c：按目标生成（X86 不带 syscall 桩，ARM 裸机需要），
  // 内容生成见 stubMainCSource（与查看代码页「临时main调用（不导出）」分组共用）。
  // -specs=nosys.specs 保留作其余符号的兜底（我们的桩已覆盖实际被拖入
  // 的 _close/_lseek/_read/_write 及启动/退出路径符号）。
  // 例外：调用方在文件集中注入 main_win.c（Win32 可运行验证程序，见
  // stubMainWinSource）时——X86 改用它替代链接验证 stub（链接
  // user32/gdi32，见下方 x86 分支）；gcc 系目标无法编译 Win32 代码，
  // 从源列表剔除并回退 stub main.c。
  final useWinMain =
      target == CCompileTarget.x86 && files.containsKey('main_win.c');
  if (!useWinMain) {
    sources.remove('main_win.c');
    final stub = stubMainCSource(topName: topName, target: target);
    await File('${workDir.path}/main.c').writeAsString(stub);
    sources.add('main.c');
  }

  // ---- 编译并链接 ----
  // X86 保持单条 cl（cl 自己逐文件打印源文件名）；gcc 系目标改分步：
  // 逐 .c 编译为 objs/*.o 并打印 [i/N] 进度行（单条 gcc 成功时无任何
  // 中间输出，终端看不到过程），全部通过后打印链接行再链接；首个失败
  // 即停，编译器错误随流式输出展示。编译选项/stub/nosys.specs/-lm 语义
  // 与原单条命令一致。
  final base = topName ?? 'app';
  final artifact =
      target == CCompileTarget.x86 ? '$base-check.exe' : '$base-check.elf';
  final encoding =
      target == CCompileTarget.x86 ? const SystemEncoding() : utf8;
  const gccFlags = ['-std=c99', '-O2', '-Wall'];
  final bareMetal = target == CCompileTarget.arm;
  // wsl:<发行版>:<WSL路径> 形式（仅 gcc 系目标）：经 wsl.exe 在 WSL 内
  // 执行；工作目录经 /mnt 映射转换（产物由 wsl 经 /mnt 写回 Windows 临时
  // 目录，结果展示仍用 Windows 路径）。
  final wsl = parseWslCompilerPath(tc.compilerPath);

  // 流式输出：追加一块就回调一次，同时累计完整文本（含装饰行与结论行）。
  final buf = StringBuffer();
  void emit(String chunk) {
    if (chunk.isEmpty) return;
    buf.write(chunk);
    onOutput?.call(chunk);
  }

  emit('临时目录：${workDir.path}\n');

  /// 流式执行一条命令，返回 exitCode；启动失败返回 -1。
  /// [sink] 非空时输出按文件缓冲（只写 sink、不实时进终端，由调用方在
  /// 该文件结束后整体 flush——并发编译时避免多进程输出交织）。
  /// [wslMixed] 为 true 时按块启发式解码：wsl.exe 自身消息是 UTF-16LE
  ///（如 localhost 代理警告），bash/gcc 输出是 UTF-8，同一管道写批次
  /// 通常同源，按块判定（见 [looksLikeUtf16Le]）。
  Future<int> runStep(String exe, List<String> stepArgs,
      {StringBuffer? sink, bool wslMixed = false}) async {
    final Process proc;
    try {
      proc = await Process.start(
        exe,
        stepArgs,
        workingDirectory: workDir.path,
        environment: _mergedEnv(tc.env),
      );
    } catch (e) {
      // 编译器路径无效 / 无法启动进程：按失败处理而非抛异常。
      emit('编译器启动失败：$e\n');
      return -1;
    }
    void drain(String chunk) {
      if (chunk.isEmpty) return;
      if (sink != null) {
        sink.write(chunk);
      } else {
        emit(chunk);
      }
    }

    // 先挂流监听再 await exitCode，避免管道缓冲打满阻塞子进程。
    // wslMixed：直接听原始字节流按块启发式解码（wsl.exe 自身消息
    // UTF-16LE / bash 输出 UTF-8 混流）；UTF-8 中文跨块截断时边界处
    // 可能出现单个 U+FFFD（罕见，无害）。
    final Future outDone;
    final Future errDone;
    if (wslMixed) {
      void drainBytes(List<int> bytes) => drain(looksLikeUtf16Le(bytes)
          ? decodeUtf16Le(bytes)
          : utf8.decode(bytes, allowMalformed: true));
      outDone = proc.stdout.listen(drainBytes).asFuture<void>();
      errDone = proc.stderr.listen(drainBytes).asFuture<void>();
    } else {
      outDone = proc.stdout.transform(encoding.decoder).forEach(drain);
      errDone = proc.stderr.transform(encoding.decoder).forEach(drain);
    }
    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    return code;
  }

  final String commandLine;
  final int exitCode;
  if (target == CCompileTarget.x86) {
    // 选项与 scripts/c_build_harness.bat 对齐（不指定 /std：生成代码为
    // C99 风格，cl 默认即可）；/Fo 指向 objs 子目录避免散落临时根。
    await Directory('${workDir.path}/objs').create();
    final args = [
      '/nologo', '/O2', '/utf-8',
      ...sources,
      '/Fe:$artifact', r'/Foobjs\',
      // main_win.c（Win32 窗口程序）替换 stub 时链接窗口/绘图/多媒体定时器
      // 库；/openmp 加速装帧/解包的逐像素转换（4K HSL 单线程 ~650ms/帧）。
      if (useWinMain) ...[
        '/openmp', 'user32.lib', 'gdi32.lib', 'winmm.lib', 'msimg32.lib'],
    ];
    commandLine = '"${tc.compilerPath}" ${args.join(' ')}';
    emit('$commandLine\n\n');
    exitCode = await runStep(tc.compilerPath, args);
  } else if (wsl != null) {
    // WSL：脚本写到临时目录（bash 从磁盘读，不受 wsl.exe 传参层吃 $
    // 变量的限制），单次 wsl 调用执行（逐文件起 wsl 进程每次都有秒级
    // 启动开销，不可行）。脚本内含跨文件并行（见 buildWslCompileScript）。
    final script = buildWslCompileScript(
      gccPath: wsl.wslPath,
      sources: sources,
      artifact: artifact,
      bareMetal: bareMetal,
    );
    // 必须 LF 行尾（Windows 侧写文件，bash 不容 CRLF）。
    await File('${workDir.path}/compile_steps.sh')
        .writeAsString(script.replaceAll('\r\n', '\n'));
    final execArgs = [
      if (wsl.distro != null) ...['-d', wsl.distro!],
      '--cd', windowsToWslPath(workDir.path),
      '--', 'bash', 'compile_steps.sh',
    ];
    commandLine = '"wsl.exe" --cd ${windowsToWslPath(workDir.path)} -- '
        'bash compile_steps.sh（并行编译 ${sources.length} 个源文件）';
    emit('$commandLine\n\n');
    exitCode = await runStep('wsl.exe', execArgs, wslMixed: true);
  } else {
    // 原生 gcc：跨文件并行编译（等效 make -j；gcc 单文件无法多核并行），
    // 并发度 = min(核数, 文件数)。进度行按源文件顺序在调度时打印；每个
    // 文件的编译器输出按文件缓冲、结束时整体 flush，避免并发输出交织。
    // 任一失败后停止调度新任务，已启动的跑完后按失败语义收尾。
    await Directory('${workDir.path}/objs').create();
    commandLine = '"${tc.compilerPath}" ${gccFlags.join(' ')} '
        '<并行编译 ${sources.length} 个源文件> -o $artifact'
        '${bareMetal ? ' -specs=nosys.specs' : ''} -lm';
    emit('$commandLine\n\n');
    final jobs =
        sources.isEmpty ? 1 : math.min(Platform.numberOfProcessors, sources.length);
    var nextIndex = 0;
    var firstFailure = 0;
    final objs = List<String?>.filled(sources.length, null);
    Future<void> worker() async {
      while (firstFailure == 0) {
        // Dart 单线程事件循环：自增与取件之间无 await，取件是原子的。
        final i = nextIndex++;
        if (i >= sources.length) return;
        final src = sources[i];
        emit('[${i + 1}/${sources.length}] $src\n');
        final obj = 'objs/${src.substring(0, src.length - 2)}.o';
        final fileBuf = StringBuffer();
        final code = await runStep(
            tc.compilerPath, [...gccFlags, '-c', src, '-o', obj],
            sink: fileBuf);
        if (fileBuf.isNotEmpty) emit(fileBuf.toString());
        if (code != 0 && firstFailure == 0) firstFailure = code;
        objs[i] = obj;
      }
    }

    await Future.wait([for (var w = 0; w < jobs; w++) worker()]);
    var code = firstFailure;
    if (code == 0) {
      emit('链接 $artifact\n');
      code = await runStep(tc.compilerPath, [
        ...objs.nonNulls,
        '-o', artifact,
        if (bareMetal) '-specs=nosys.specs',
        '-lm',
      ]);
    }
    exitCode = code;
  }

  final artifactFile = File('${workDir.path}/$artifact');
  final success = exitCode == 0 && artifactFile.existsSync();
  emit(success
      ? '\n编译链接成功，产物：${artifactFile.path}\n'
      : '\n编译失败（exit $exitCode）\n');
  return CCompileResult(
    success: success,
    exitCode: exitCode,
    commandLine: commandLine,
    output: buf.toString().trim(),
    workDir: workDir.path,
    artifactPath: success ? artifactFile.path : null,
    sourceCount: sources.length - 1,
  );
}

/// Win32 可运行验证程序的构建入口（X86/MSVC 专用）：文件集 + 生成的
/// main_win.c（[stubMainWinSource]）→ `scratch/cc_win_check/` 下 cl 链接
/// （追加 user32.lib gdi32.lib）出 `{topName}_win.exe`。固定产物目录
/// （非系统临时目录），构建成功后用户可直接双击运行；工作目录不可写时
/// （安装版）自动回退 `%LOCALAPPDATA%\DebugToolSet\cc_win_check\`。
/// [inFormat]/[outFormat] 为编组外部输入/输出帧格式（'rgb'/'hsl'）；
/// 需要 HSL 转换且文件集中没有 isp_csc_common.h 时，优先用
/// [cscCommonHeader]（调用方经 rootBundle 注入，安装版无 lib/ 目录）；
/// 缺省时从 `lib/modules/isp_studio/c_ref/` 读盘注入（工作目录相对路径，
/// 测试/开发环境行为）。
/// [hasScratch] 透传 [stubMainWinSource]（黑盒无 scratch 参数的形态）。
/// [maxValue] 为管线量化域（编组位深推导，见 lutDomainMaxOf）：LUT 模式
/// 节点的查表快路径要求运行时 max_value 与烘焙域一致，缺省 255。
Future<CCompileResult> buildWinVerifyApp(
  Map<String, String> files, {
  required String topName,
  String inFormat = 'rgb',
  String outFormat = 'rgb',
  bool hasScratch = true,
  int maxValue = 255,
  String? cscCommonHeader,
  String? compilerPath,
  void Function(String chunk)? onOutput,
}) async {
  final buf = StringBuffer();
  void emit(String chunk) {
    if (chunk.isEmpty) return;
    buf.write(chunk);
    onOutput?.call(chunk);
  }

  final tc = compilerPath != null && compilerPath.isNotEmpty
      ? toolchainFromCompilerPath(CCompileTarget.x86, compilerPath)
      : detectMsvc();
  if (tc == null) {
    const msg = '未检测到 MSVC（cl.exe）。请安装 Visual Studio（含 C++ 桌面开发负载），'
        '或在上方手动填写 cl.exe 的完整路径。';
    emit('$msg\n');
    return CCompileResult(
      success: false,
      exitCode: -1,
      commandLine: '',
      output: msg,
      workDir: '',
      artifactPath: null,
      sourceCount: 0,
    );
  }

  // 固定产物目录（重建前清空，避免旧 obj/exe 混入；目录被运行中的
  // 验证程序占用时（exe 文件锁）改用带时间戳的备用目录，不打扰用户
  // 正在运行的窗口）。优先 工作目录/scratch/cc_win_check（开发机行为
  // 不变）；创建抛 FileSystemException 时（安装到 Program Files 后
  // 普通用户对工作目录不可写）回退 %LOCALAPPDATA%\DebugToolSet\
  // cc_win_check（无 LOCALAPPDATA 再用系统临时目录）。
  var workDir =
      Directory('${Directory.current.path}/scratch/cc_win_check');
  if (workDir.existsSync()) {
    try {
      await workDir.delete(recursive: true);
    } on FileSystemException {
      workDir = Directory(
          '${Directory.current.path}/scratch/cc_win_check_${DateTime.now().millisecondsSinceEpoch}');
      emit('固定产物目录被运行中的验证程序占用，改用 ${workDir.path}\n');
    }
  }
  try {
    await workDir.create(recursive: true);
  } on FileSystemException {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    workDir = Directory(localAppData != null
        ? '$localAppData\\DebugToolSet\\cc_win_check'
        : '${Directory.systemTemp.path}/cc_win_check');
    await workDir.create(recursive: true);
    emit('工作目录不可写，产物目录改用 ${workDir.path}\n');
  }
  final allFiles = Map<String, String>.of(files);
  final needCsc = inFormat == 'hsl' || outFormat == 'hsl';
  if (needCsc && !allFiles.containsKey('isp_csc_common.h')) {
    allFiles['isp_csc_common.h'] = cscCommonHeader ??
        await File(
                '${Directory.current.path}/lib/modules/isp_studio/c_ref/isp_csc_common.h')
            .readAsString();
  }
  allFiles['main_win.c'] = stubMainWinSource(
      topName: topName,
      inFormat: inFormat,
      outFormat: outFormat,
      hasScratch: hasScratch,
      maxValue: maxValue);
  for (final e in allFiles.entries) {
    await File('${workDir.path}/${e.key}').writeAsString(e.value);
  }
  final sources = [for (final f in allFiles.keys) if (f.endsWith('.c')) f]
    ..sort();
  final artifact = '${topName}_win.exe';
  await Directory('${workDir.path}/objs').create();
  // libav* 头文件（tools/ffmpeg/include，ffmpeg shared 包）：存在时编译进
  // 内嵌拖动预览解码器（main_win.c 的 HAVE_AV 分支，DLL 运行时加载）。
  final avInclude = Directory(
      '${Directory.current.path}${Platform.pathSeparator}tools'
      '${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}include');
  final args = [
    '/nologo', '/O2', '/utf-8',
    if (avInclude.existsSync()) '/I"${avInclude.path}"',
    ...sources,
    '/Fe:$artifact', r'/Foobjs\',
    // Win32 窗口（窗口/绘图/多媒体定时器 API）链接库；/openmp 加速
    // 装帧/解包的逐像素转换。
    '/openmp', 'user32.lib', 'gdi32.lib', 'winmm.lib', 'msimg32.lib',
  ];
  final commandLine = '"${tc.compilerPath}" ${args.join(' ')}';
  emit('产物目录：${workDir.path}\n$commandLine\n\n');

  final Process proc;
  try {
    proc = await Process.start(tc.compilerPath, args,
        workingDirectory: workDir.path, environment: _mergedEnv(tc.env));
  } catch (e) {
    emit('编译器启动失败：$e\n');
    return CCompileResult(
      success: false,
      exitCode: -1,
      commandLine: commandLine,
      output: buf.toString().trim(),
      workDir: workDir.path,
      artifactPath: null,
      sourceCount: sources.length - 1,
    );
  }
  // 先挂流监听再 await exitCode，避免管道缓冲打满阻塞子进程；
  // MSVC 输出按系统编码（中文 GBK）解码。
  const encoding = SystemEncoding();
  final outDone = proc.stdout.transform(encoding.decoder).forEach(emit);
  final errDone = proc.stderr.transform(encoding.decoder).forEach(emit);
  final exitCode = await proc.exitCode;
  await Future.wait([outDone, errDone]);

  final artifactFile = File('${workDir.path}/$artifact');
  final success = exitCode == 0 && artifactFile.existsSync();
  emit(success
      ? '\n编译链接成功，产物：${artifactFile.path}\n'
      : '\n编译失败（exit $exitCode）\n');
  return CCompileResult(
    success: success,
    exitCode: exitCode,
    commandLine: commandLine,
    output: buf.toString().trim(),
    workDir: workDir.path,
    artifactPath: success ? artifactFile.path : null,
    sourceCount: sources.length - 1,
  );
}
