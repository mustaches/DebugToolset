// 窗口模式工作线程模型分段计时基准（一次性脚本）：把 scratch/cc_win_check
// 产物复制到 scratch/cc_win_uibench，给 main_win.c 打补丁（proc_publish
// 计数/汇总 + draw 计时 + --wframes N 自动关窗），重编译后跑 4K60 视频
// 窗口模式 N 帧，量化工作线程模型下各段成本与 kept 帧率。
// 运行：flutter test scratch/eq_ui_bench_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';

Map<String, String> mergedEnv(Map<String, String> overrides) {
  final env = Map<String, String>.of(Platform.environment);
  for (final e in overrides.entries) {
    final key = env.keys.firstWhere((k) => k.toLowerCase() == e.key.toLowerCase(),
        orElse: () => e.key);
    if (e.key.toUpperCase() == 'PATH') {
      env[key] = '${e.value};${env[key] ?? ''}';
    } else {
      env[key] = e.value;
    }
  }
  return env;
}

void main() {
  test('窗口模式工作线程模型分段计时（4K60）', () async {
    final tc = detectMsvc();
    if (tc == null) return; // 无 MSVC 跳过
    final srcDir = Directory('${Directory.current.path}/scratch/cc_win_check');
    final dstDir = Directory('${Directory.current.path}/scratch/cc_win_uibench');
    if (dstDir.existsSync()) dstDir.deleteSync(recursive: true);
    dstDir.createSync(recursive: true);
    for (final f in srcDir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.c') || name.endsWith('.h')) {
        f.copySync('${dstDir.path}/$name');
      }
    }
    Directory('${dstDir.path}/objs').createSync();

    final mwFile = File('${dstDir.path}/main_win.c');
    var mw = mwFile.readAsStringSync();
    void patch(String from, String to) {
      if (!mw.contains(from)) fail('补丁锚点未命中: ${from.substring(0, 40)}...');
      mw = mw.replaceFirst(from, to);
    }

    patch(
      'static DWORD g_t_read = 0, g_t_pack = 0, g_t_run = 0, g_t_unpack = 0;',
      'static DWORD g_t_read = 0, g_t_pack = 0, g_t_run = 0, g_t_unpack = 0;\n'
      'static DWORD g_t_draw = 0;\n'
      'static DWORD g_adv_t0 = 0;\n'
      'static int g_wframes = -1, g_adv_n = 0;',
    );
    patch(
      '  g_pb_write = InterlockedExchange(&g_pb_ready, g_pb_write);\n'
      '  mark_frame();\n'
      '  PostMessage(g_hwnd_main, WM_APP_FRAME, 0, 0);',
      '  g_pb_write = InterlockedExchange(&g_pb_ready, g_pb_write);\n'
      '  if (g_adv_t0 == 0) g_adv_t0 = GetTickCount();\n'
      '  mark_frame();\n'
      '  g_adv_n++;\n'
      '  if (g_wframes > 0 && g_adv_n >= g_wframes) {\n'
      '    fprintf(stderr,\n'
      '            "WUIBENCH adv=%d wall=%lums read=%lu pack=%lu run=%lu unpack=%lu draw=%lu\\n",\n'
      '            g_adv_n, (unsigned long)(GetTickCount() - g_adv_t0),\n'
      '            (unsigned long)g_t_read, (unsigned long)g_t_pack,\n'
      '            (unsigned long)g_t_run, (unsigned long)g_t_unpack,\n'
      '            (unsigned long)g_t_draw);\n'
      '    PostMessage(g_hwnd_main, WM_CLOSE, 0, 0);\n'
      '  }\n'
      '  PostMessage(g_hwnd_main, WM_APP_FRAME, 0, 0);',
    );
    patch(
      'static void draw(HDC dc, const RECT *client) {\n'
      '  HDC mem = back_dc(dc, client->right, client->bottom);',
      'static void draw(HDC dc, const RECT *client) {\n'
      '  const DWORD t_draw0 = GetTickCount();\n'
      '  HDC mem = back_dc(dc, client->right, client->bottom);',
    );
    patch(
      '  BitBlt(dc, 0, 0, client->right, client->bottom, mem, 0, 0, SRCCOPY);\n'
      '  DeleteObject(progBg);',
      '  BitBlt(dc, 0, 0, client->right, client->bottom, mem, 0, 0, SRCCOPY);\n'
      '  g_t_draw += GetTickCount() - t_draw0;\n'
      '  DeleteObject(progBg);',
    );
    patch(
      '    if (strcmp(__argv[i], "--frames") == 0 && i + 1 < __argc) {\n'
      '      frames = atoi(__argv[++i]);\n'
      '    } else if (strcmp(__argv[i], "--dump-hash") == 0) {',
      '    if (strcmp(__argv[i], "--frames") == 0 && i + 1 < __argc) {\n'
      '      frames = atoi(__argv[++i]);\n'
      '    } else if (strcmp(__argv[i], "--wframes") == 0 && i + 1 < __argc) {\n'
      '      g_wframes = atoi(__argv[++i]);\n'
      '    } else if (strcmp(__argv[i], "--dump-hash") == 0) {',
    );
    mwFile.writeAsStringSync(mw);

    final sources = [
      for (final f in dstDir.listSync().whereType<File>())
        if (f.path.endsWith('.c')) f.uri.pathSegments.last
    ]..sort();
    final avInclude =
        '${Directory.current.path}${Platform.pathSeparator}tools${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}include';
    final args = [
      '/nologo', '/O2', '/utf-8',
      if (Directory(avInclude).existsSync()) '/I"$avInclude"',
      ...sources,
      '/Fe:uibench.exe', r'/Foobjs\',
      '/openmp', 'user32.lib', 'gdi32.lib', 'winmm.lib', 'msimg32.lib',
    ];
    final cr = await Process.run(tc.compilerPath, args,
        workingDirectory: dstDir.path, environment: mergedEnv(tc.env));
    // ignore: avoid_print
    print('${cr.stdout}\n${cr.stderr}');
    expect(cr.exitCode, 0, reason: '编译失败');

    final pr = await Process.run('${dstDir.path}/uibench.exe', [
      '--video', 'G:/DebugToolSet/4k60VRec/Sony 4K60p SDR Demo Video.MP4',
      '--ffmpeg', 'G:/DebugToolSet/tools/ffmpeg/ffmpeg.exe',
      '--wframes', '300',
    ], workingDirectory: dstDir.path);
    // ignore: avoid_print
    print('stdout: ${pr.stdout}\nstderr: ${pr.stderr}\nexit: ${pr.exitCode}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
