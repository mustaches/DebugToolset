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

/// 编译目标机器。
enum CCompileTarget { x86, arm, linuxCross }

/// 会话内记住的手动编译器路径（对话框中用户改动后写入；进程级，不落盘）。
final Map<CCompileTarget, String> sessionCompilerPaths = {};

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

/// 探测 Linux 交叉编译 gcc（两种用户工具链）；未找到返回 null。
/// 命名规则：
/// - aarch64-mix210-linux：精确名 `aarch64-mix210-linux-gcc.exe`；
/// - riscv32-cfg5-musl-<可变段>-elf：前缀 `riscv32-cfg5-musl-`、
///   后缀 `-elf-gcc.exe`（中间版本/配置段可变，按前后缀匹配）。
/// [searchDirs] 可注入（测试用）；缺省为 PATH 各目录。
CToolchain? detectLinuxCrossGcc({List<String>? searchDirs}) {
  const aarch64Exe = 'aarch64-mix210-linux-gcc.exe';
  const riscvPrefix = 'riscv32-cfg5-musl-';
  const riscvSuffix = '-elf-gcc.exe';
  final dirs = searchDirs ?? [...?Platform.environment['PATH']?.split(';')];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final e in d.listSync()) {
      if (e is! File) continue;
      final name = _baseName(e.path);
      if (name == aarch64Exe ||
          (name.startsWith(riscvPrefix) && name.endsWith(riscvSuffix))) {
        return CToolchain(CCompileTarget.linuxCross, e.path, const {});
      }
    }
  }
  return null;
}

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

/// WSL 侧探测 Linux 交叉编译 gcc（Windows PATH 未命中时的补充），两阶段：
/// 阶段一「WSL 启动」——[ensureWslReady] 确认虚拟机就绪（[startupTimeout]
/// 独立宽超时，覆盖冷启动）；阶段二「探测编译器」——就绪后先查默认发行版
/// （一次 wsl 调用，命中路径最快），未命中再经 `wsl.exe -l -q` 列发行版
/// （输出为 UTF-16LE，按去 NUL 字节处理）逐个探测，[timeout] 从就绪后起算。
/// 命中返回 `'wsl:<发行版>:<WSL路径>'` 形式的 CToolchain；阶段一失败或
/// 阶段二超时未命中均返回 null。[onPhase] 阶段回调（'startup'/'detect'，
/// 对话框切换等待文案用）。
Future<CToolchain?> detectLinuxCrossGccWsl({
  Duration startupTimeout = const Duration(seconds: 60),
  Duration timeout = const Duration(seconds: 10),
  void Function(String phase)? onPhase,
}) async {
  onPhase?.call('startup');
  if (!await ensureWslReady(timeout: startupTimeout)) return null;
  onPhase?.call('detect');
  try {
    return await _detectLinuxCrossGccWsl().timeout(timeout);
  } catch (_) {
    return null;
  }
}

Future<CToolchain?> _detectLinuxCrossGccWsl() async {
  // 探测命令只写字面路径、不引用 shell 变量：wsl.exe 从 Windows 传参
  // 会经一层 shell 展开（$ 变量被吃掉），~ 由该层展开为用户家目录。
  // find 的 -name 直接支持 riscv 中间段通配；不存在的根目录报错被
  // 2>/dev/null 吞掉（exit code 可能非 0，按输出解析而非退出码）。
  // 输出按 latin1 解码并去 NUL：wsl 自身消息可能是 UTF-16LE。
  const findCmd = 'find ~/toolchains/bin ~/toolchains /opt /usr/local/bin '
      '-maxdepth 1 -type f '
      '\\( -name aarch64-mix210-linux-gcc -o '
      '-name "riscv32-cfg5-musl-*-elf-gcc" \\) 2>/dev/null';
  Future<CToolchain?> probe(String? distro) async {
    try {
      final r = await Process.run(
        'wsl.exe',
        [if (distro != null) ...['-d', distro], '--', 'bash', '-c', findCmd],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      );
      for (final line
          in '${r.stdout}'.replaceAll('\x00', '').split('\n')) {
        final path = line.trim();
        if (path.isEmpty || !_isWslCrossGccName(_baseName(path))) continue;
        return CToolchain(
          CCompileTarget.linuxCross,
          distro == null ? 'wsl:$path' : 'wsl:$distro:$path',
          const {},
        );
      }
    } catch (_) {/* 该发行版不可用，按未命中处理 */}
    return null;
  }

  // 默认发行版优先（一次 wsl 调用即命中是常见路径）。
  final hit = await probe(null);
  if (hit != null) return hit;
  // 再列发行版逐个探测。
  List<String> distros;
  try {
    final listed = await Process.run('wsl.exe', ['-l', '-q'],
        stdoutEncoding: latin1, stderrEncoding: latin1);
    if (listed.exitCode != 0) return null;
    distros = [
      for (final l in '${listed.stdout}'.replaceAll('\x00', '').split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
  } catch (_) {
    return null; // 无 wsl
  }
  for (final distro in distros) {
    final tc = await probe(distro);
    if (tc != null) return tc;
  }
  return null;
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
  final stub = stubMainCSource(topName: topName, target: target);
  await File('${workDir.path}/main.c').writeAsString(stub);
  sources.add('main.c');

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
