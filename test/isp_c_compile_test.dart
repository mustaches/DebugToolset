import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

void main() {
  /// 从磁盘读真实 c_ref 文件（测试不依赖 rootBundle 资产）。
  Future<String> readDisk(String path) => File(path).readAsString();

  /// 白平衡 → Gamma 编组的生成文件集（内存形态）。
  Future<Map<String, String>> sampleFiles() async {
    final graph = IspGraph();
    final wb = graph.addNode('white_balance', 0, 0);
    final gamma = graph.addNode('gamma', 0, 0);
    graph.nodes[wb]!.name = 'wb';
    expect(graph.connect(wb, 'out', gamma, 'in'), isNull);
    graph.groups.add(IspNodeGroup('g1', {wb, gamma}, name: 'pipe'));
    return buildGroupCFiles(graph, graph.groups.single, readFile: readDisk);
  }

  group('工具链探测', () {
    test('detectMsvc：伪 VS/SDK 布局推导环境，取最高版本目录', () async {
      final tmp = await Directory.systemTemp.createTemp('isp_tc_');
      addTearDown(() => tmp.delete(recursive: true));
      // 两个 MSVC 版本目录：应取字符串序最高的 14.30。
      for (final v in ['14.10.25017', '14.30.30704']) {
        await Directory('${tmp.path}\\VS\\$v\\bin\\Hostx64\\x64')
            .create(recursive: true);
        await File('${tmp.path}\\VS\\$v\\bin\\Hostx64\\x64\\cl.exe').create();
      }
      await Directory('${tmp.path}\\Kit\\Include\\10.0.22000.0\\ucrt')
          .create(recursive: true);

      final tc = detectMsvc(
        vsRoots: ['${tmp.path}\\VS'],
        sdkIncludeRoot: '${tmp.path}\\Kit\\Include',
        sdkLibRoot: '${tmp.path}\\Kit\\Lib',
      );
      expect(tc, isNotNull);
      expect(tc!.compilerPath,
          contains('14.30.30704\\bin\\Hostx64\\x64\\cl.exe'));
      expect(tc.env['INCLUDE'], contains('14.30.30704\\include'));
      expect(tc.env['INCLUDE'], contains('10.0.22000.0\\ucrt'));
      expect(tc.env['INCLUDE'], contains('10.0.22000.0\\um'));
      expect(tc.env['LIB'], contains('14.30.30704\\lib\\x64'));
      expect(tc.env['LIB'], contains('10.0.22000.0\\ucrt\\x64'));
      expect(tc.env['PATH'], contains('14.30.30704\\bin\\Hostx64\\x64'));

      // 根目录不存在 → null；SDK 缺失 → null。
      expect(
          detectMsvc(
              vsRoots: ['${tmp.path}\\nope'],
              sdkIncludeRoot: '${tmp.path}\\Kit\\Include',
              sdkLibRoot: '${tmp.path}\\Kit\\Lib'),
          isNull);
      expect(
          detectMsvc(
              vsRoots: ['${tmp.path}\\VS'],
              sdkIncludeRoot: '${tmp.path}\\nope',
              sdkLibRoot: '${tmp.path}\\Kit\\Lib'),
          isNull);
    });

    test('detectArmGcc：bin 目录与安装根两种布局均可命中', () async {
      final tmp = await Directory.systemTemp.createTemp('isp_tc_');
      addTearDown(() => tmp.delete(recursive: true));
      // 布局一：目录直接是 bin。
      await Directory('${tmp.path}\\bin').create(recursive: true);
      await File('${tmp.path}\\bin\\arm-none-eabi-gcc.exe').create();
      // 布局二：安装根\\<版本>\\bin。
      await Directory('${tmp.path}\\root\\10 2021.10\\bin')
          .create(recursive: true);
      await File('${tmp.path}\\root\\10 2021.10\\bin\\arm-none-eabi-gcc.exe')
          .create();

      expect(detectArmGcc(searchDirs: ['${tmp.path}\\bin'])?.compilerPath,
          contains('arm-none-eabi-gcc.exe'));
      expect(detectArmGcc(searchDirs: ['${tmp.path}\\root'])?.compilerPath,
          contains('10 2021.10\\bin\\arm-none-eabi-gcc.exe'));
      expect(detectArmGcc(searchDirs: ['${tmp.path}\\nope']), isNull);
    });

    test('detectLinuxCrossGcc：aarch64 精确名与 riscv 前后缀匹配', () async {
      final tmp = await Directory.systemTemp.createTemp('isp_tc_');
      addTearDown(() => tmp.delete(recursive: true));
      await File('${tmp.path}/aarch64-mix210-linux-gcc.exe').create();
      await File('${tmp.path}/riscv32-cfg5-musl-v1.2.3-elf-gcc.exe')
          .create();
      // 干扰项：缺后缀/缺前缀/非 gcc，均不命中。
      await File('${tmp.path}/riscv32-cfg5-musl-v1-elf-objdump.exe')
          .create();
      await File('${tmp.path}/riscv32-unknown-elf-gcc.exe').create();

      final found = detectLinuxCrossGcc(searchDirs: [tmp.path]);
      expect(found, isNotNull);
      expect(found!.target, CCompileTarget.linuxCross);
      expect(
          found.compilerPath,
          anyOf(contains('aarch64-mix210-linux-gcc.exe'),
              contains('riscv32-cfg5-musl-v1.2.3-elf-gcc.exe')));
      expect(found.env, isEmpty);
      expect(detectLinuxCrossGcc(searchDirs: ['${tmp.path}/nope']), isNull);
    });

    test('parseWslCompilerPath：带/不带发行版与非法形态', () {
      final noDistro = parseWslCompilerPath(
          'wsl:/home/fzdl/toolchains/bin/aarch64-mix210-linux-gcc');
      expect(noDistro, isNotNull);
      expect(noDistro!.distro, isNull);
      expect(noDistro.wslPath,
          '/home/fzdl/toolchains/bin/aarch64-mix210-linux-gcc');

      final withDistro = parseWslCompilerPath(
          'wsl:Ubuntu:/home/fzdl/toolchains/bin/aarch64-mix210-linux-gcc');
      expect(withDistro, isNotNull);
      expect(withDistro!.distro, 'Ubuntu');
      expect(withDistro.wslPath,
          '/home/fzdl/toolchains/bin/aarch64-mix210-linux-gcc');

      // 非 wsl 前缀 / 相对路径 / 缺路径，均不合法。
      expect(parseWslCompilerPath(r'C:\tools\gcc.exe'), isNull);
      expect(parseWslCompilerPath('wsl:Ubuntu:relative/gcc'), isNull);
      expect(parseWslCompilerPath('wsl:'), isNull);
      expect(parseWslCompilerPath('wsl:Ubuntu:'), isNull);
    });

    test('windowsToWslPath：盘符小写、反斜杠转正斜杠', () {
      expect(windowsToWslPath(r'C:\Users\x\AppData\Local\Temp\isp_cc_1'),
          '/mnt/c/Users/x/AppData/Local/Temp/isp_cc_1');
      expect(windowsToWslPath('D:/work/out'), '/mnt/d/work/out');
      // 无盘符原样返回。
      expect(windowsToWslPath('/already/unix'), '/already/unix');
    });

    test('toolchainFromCompilerPath：非标准布局不带额外环境', () {
      final tc = toolchainFromCompilerPath(
          CCompileTarget.arm, r'C:\tools\my-gcc.exe');
      expect(tc.compilerPath, r'C:\tools\my-gcc.exe');
      expect(tc.env, isEmpty);
    });

    test('编译器路径无效时返回失败结果而非抛异常', () async {
      final chunks = <String>[];
      final r = await compileGroupCFiles(
        {'a.c': 'int main(void) { return 0; }\n'},
        CCompileTarget.arm,
        compilerPath: r'C:\nope\not-exist-gcc.exe',
        onOutput: chunks.add,
      );
      expect(r.success, isFalse);
      expect(r.output, contains('编译器启动失败'));
      // 流式回调：拼接后与完整 output 一致。
      expect(chunks, isNotEmpty);
      expect(chunks.join().trim(), r.output);
      // 失败保留临时目录便于排查。
      expect(Directory(r.workDir).existsSync(), isTrue);
    });
  });

  group('buildWslCompileScript', () {
    test('跨文件并行：进度行 / 并发闸门 / 按序回显 / 链接行', () {
      final script = buildWslCompileScript(
        gccPath: '/home/x/bin/aarch64-mix210-linux-gcc',
        sources: ['a.c', 'b.c', 'main.c'],
        artifact: 'app-check.elf',
        bareMetal: true,
      );
      // 并发度取 nproc 与文件数小者；注入 jobs 时用固定值。
      expect(script, contains('JOBS=\$(nproc)'));
      expect(script, contains('N=3'));
      // 逐文件后台编译 + 进度行 + 输出重定向到 log。
      expect(script, contains('echo "[\$i/\$N] a.c"'));
      expect(script, contains('echo "[\$i/\$N] main.c"'));
      expect(script,
          contains('-c "a.c" -o "objs/a.o" >"objs/a.log" 2>&1 &'));
      // 并发闸门（jobs 数限制）与按序 wait 取退出码。
      expect(script, contains('jobs -rp'));
      expect(script, contains('wait "\${pids[\$k]}"'));
      // 失败按序 cat log 后 exit 1；成功保留 warning（非空 log 回显）。
      expect(script, contains('cat "objs/a.log"'));
      expect(script, contains('exit 1'));
      // 链接行（裸机带 nosys.specs，-lm 收尾）。
      expect(script, contains("echo '链接 app-check.elf'"));
      expect(script, contains('objs/a.o objs/b.o objs/main.o'));
      expect(script, contains('-specs=nosys.specs'));
      expect(script, contains('-lm'));

      final fixed = buildWslCompileScript(
          gccPath: '/x/gcc',
          sources: ['a.c'],
          artifact: 'a.elf',
          bareMetal: false,
          jobs: 4);
      expect(fixed, contains('JOBS=1')); // min(文件数 1, jobs 4)
      expect(fixed, isNot(contains('nosys.specs')));
    });
  });

  group('ensureWslReady', () {
    /// 伪 runner 工厂：返回固定 exitCode 或抛异常（不真起 wsl 进程）。
    Future<ProcessResult> Function(String, List<String>,
            {Encoding? stdoutEncoding, Encoding? stderrEncoding})
        fakeRunner({int exitCode = 0, bool throws = false}) {
      return (exe, args, {stdoutEncoding, stderrEncoding}) async {
        if (throws) throw ProcessException(exe, args);
        return ProcessResult(0, exitCode, '', '');
      };
    }

    test('就绪 / 未就绪 / 无 wsl 三路径', () async {
      expect(await ensureWslReady(runner: fakeRunner()), isTrue);
      expect(await ensureWslReady(runner: fakeRunner(exitCode: 1)), isFalse);
      expect(await ensureWslReady(runner: fakeRunner(throws: true)), isFalse);
    });
  });

  group('stubMainCSource', () {
    test('X86 无桩、ARM 带桩、无 topName 空 main', () {
      final x86 = stubMainCSource(
          topName: 'isp_pipeline_p', target: CCompileTarget.x86);
      // volatile 函数指针引用 top 入口（消 -Waddress 的写法）。
      expect(x86, contains('#include "isp_pipeline_p.h"'));
      expect(x86,
          contains('void (*volatile entry)(void) = (void (*)(void))isp_pipeline_p_run;'));
      expect(x86, isNot(contains('_sbrk')));

      final arm = stubMainCSource(
          topName: 'isp_pipeline_p', target: CCompileTarget.arm);
      // ARM 版带裸机 syscall 桩（优先于 libnosys 带 .warning 的默认桩）。
      expect(arm, contains('_sbrk'));
      expect(arm, contains('_close'));
      expect(arm, contains('_exit'));
      expect(arm, contains('volatile entry'));

      final empty = stubMainCSource(target: CCompileTarget.x86);
      expect(empty, contains('int main(void) { return 0; }'));
      expect(empty, isNot(contains('volatile entry')));

      // Linux 交叉：有完整 libc/syscall，stub 为无桩通用形态（同 X86）。
      final linux = stubMainCSource(
          topName: 'isp_pipeline_p', target: CCompileTarget.linuxCross);
      expect(linux, contains('volatile entry'));
      expect(linux, isNot(contains('_sbrk')));
    });
  });

  group('X86 实机编译链接', () {
    test('生成代码编译链接通过（含 stub main 符号解析）', () async {
      final msvc = detectMsvc();
      if (msvc == null) {
        // ignore: avoid_print
        print('未检测到 MSVC，跳过 X86 实机编译');
        return;
      }
      final files = await sampleFiles();
      final chunks = <String>[];
      final r = await compileGroupCFiles(files, CCompileTarget.x86,
          topName: 'isp_pipeline_pipe', onOutput: chunks.add);
      expect(r.success, isTrue, reason: r.output);
      expect(File(r.artifactPath!).existsSync(), isTrue);
      expect(r.artifactPath, endsWith('isp_pipeline_pipe-check.exe'));
      expect(r.sourceCount,
          files.keys.where((f) => f.endsWith('.c')).length);
      // stub main.c 引用 top 层入口（volatile 函数指针），强制符号解析。
      final stubC = File('${r.workDir}/main.c').readAsStringSync();
      expect(stubC, contains('isp_pipeline_pipe_run'));
      // X86 的 stub 不带裸机 syscall 桩（避免与 CRT 符号冲突）。
      expect(stubC, isNot(contains('_sbrk')));
      // 流式回调：依次含临时目录行、命令行、编译器输出、成功结论，
      // 拼接后与完整 output 一致。
      expect(chunks.length, greaterThan(1));
      final joined = chunks.join();
      expect(joined, contains('临时目录：'));
      expect(joined, contains(r.commandLine));
      expect(joined, contains('编译链接成功'));
      expect(joined.trim(), r.output);
      // X86(MSVC) 侧无编译/链接警告。
      expect(r.output, isNot(contains('warning')));
      expect(r.output, isNot(contains('警告')));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('删掉算法实现文件后链接失败并暴露错误输出', () async {
      final msvc = detectMsvc();
      if (msvc == null) {
        // ignore: avoid_print
        print('未检测到 MSVC，跳过 X86 实机编译');
        return;
      }
      final files = await sampleFiles();
      // gamma 封装修改不了（只引用 isp_gamma.h 声明），删掉其实现 →
      // 未解析外部符号，链接失败。
      files.remove('isp_gamma.c');
      final r = await compileGroupCFiles(files, CCompileTarget.x86,
          topName: 'isp_pipeline_pipe');
      expect(r.success, isFalse);
      expect(r.exitCode, isNot(0));
      expect(r.output, isNotEmpty);
      expect(Directory(r.workDir).existsSync(), isTrue); // 失败保留排查
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Linux 交叉实机编译链接', () {
    test('生成代码交叉编译链接通过（Windows 或 WSL 工具链）', () async {
      // Windows PATH 优先；未命中补 WSL 探测（带超时保护）。
      // WSL 冷启动可能耗时数十秒，实机用例放宽超时（UI 侧默认 10 秒）。
      final gcc = detectLinuxCrossGcc() ??
          await detectLinuxCrossGccWsl(
              timeout: const Duration(seconds: 60));
      if (gcc == null) {
        // ignore: avoid_print
        print('Windows 与 WSL 均未检测到 Linux 交叉编译 gcc，跳过实机编译');
        return;
      }
      final files = await sampleFiles();
      final r = await compileGroupCFiles(files, CCompileTarget.linuxCross,
          topName: 'isp_pipeline_pipe');
      expect(r.success, isTrue, reason: r.output);
      expect(r.artifactPath, endsWith('isp_pipeline_pipe-check.elf'));
      // 产物在 Windows 临时目录（wsl 经 /mnt 写回），断言 Windows 路径存在。
      expect(File(r.artifactPath!).existsSync(), isTrue);
      // 通用形态 stub：无 syscall 桩、无 nosys.specs。
      expect(File('${r.workDir}/main.c').readAsStringSync(),
          isNot(contains('_sbrk')));
      expect(r.commandLine, isNot(contains('nosys.specs')));
      // wsl: 形式时命令行为 wsl.exe 转发。
      if (gcc.compilerPath.startsWith('wsl:')) {
        expect(r.commandLine, contains('wsl.exe'));
        expect(r.commandLine, contains('--cd /mnt/'));
      }
      // 分步编译：终端有逐文件进度行与链接行。
      expect(r.output, contains('[1/'));
      expect(r.output, contains('wb.c'));
      expect(r.output, contains('链接 isp_pipeline_pipe-check.elf'));
      expect(r.output, isNot(contains('warning')));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('ARM 实机编译链接', () {
    test('生成代码交叉编译链接通过', () async {
      final gcc = detectArmGcc();
      if (gcc == null) {
        // ignore: avoid_print
        print('未检测到 arm-none-eabi-gcc，跳过 ARM 实机编译');
        return;
      }
      final files = await sampleFiles();
      final r = await compileGroupCFiles(files, CCompileTarget.arm,
          topName: 'isp_pipeline_pipe');
      expect(r.success, isTrue, reason: r.output);
      expect(r.artifactPath, endsWith('isp_pipeline_pipe-check.elf'));
      expect(File(r.artifactPath!).existsSync(), isTrue);
      // stub main.c 带裸机 syscall 桩（优先于 libnosys 带 .warning 的桩）。
      final stubC = File('${r.workDir}/main.c').readAsStringSync();
      expect(stubC, contains('_sbrk'));
      expect(stubC, contains('volatile entry'));
      // 分步编译：终端有逐文件进度行与链接行（nosys.specs 只在链接步）。
      expect(r.output, contains('[1/'));
      expect(r.output, contains('wb.c'));
      expect(r.output, contains('链接 isp_pipeline_pipe-check.elf'));
      expect(r.output, contains('-specs=nosys.specs'));
      // 无 -Waddress（stub 函数地址比较）与 libnosys 桩警告。
      expect(r.output, isNot(contains('-Waddress')));
      expect(r.output, isNot(contains('is not implemented')));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
