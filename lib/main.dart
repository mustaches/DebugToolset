import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart'; // Uncomment after enabling dev mode & pub get
import 'package:screen_retriever/screen_retriever.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'layout/main_layout.dart';
import 'providers/app_state.dart';
import 'providers/font_extractor_state.dart';
import 'providers/terminal_state.dart';
import 'providers/network_terminal_state.dart';
import 'providers/macro_state.dart';
import 'providers/oscilloscope_state.dart';
import 'providers/hex_editor_state.dart';
import 'providers/text_editor_state.dart';
import 'providers/ui_designer_state.dart';
import 'providers/isp_studio_state.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize window_manager
  await windowManager.ensureInitialized();

  // 标题栏显示版本号（取自 pubspec.yaml 的 version 字段）
  String appTitle = 'DebugToolSet';
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) {
      appTitle = 'DebugToolSet v${info.version}';
    }
  } catch (_) {
    // 读取失败时退回不带版本号的标题
  }

  WindowOptions windowOptions = WindowOptions(
    size: const Size(1658, 869),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
    title: appTitle,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // 多显示器时把窗口移到主显示器（第一个显示器）工作区内，确保最大化也落在主屏
    try {
      final primary = await screenRetriever.getPrimaryDisplay();
      final Offset origin = primary.visiblePosition ?? Offset.zero;
      final Size area = primary.visibleSize ?? primary.size;
      const winSize = Size(1658, 869);
      await windowManager.setPosition(Offset(
        origin.dx + (area.width - winSize.width) / 2,
        origin.dy + (area.height - winSize.height) / 2,
      ));
    } catch (_) {
      // 获取显示器信息失败时保持默认位置
    }
    await windowManager.show();
    await windowManager.setTitle(appTitle);
    // 默认最大化启动
    await windowManager.maximize();
    await windowManager.focus();
  });

  _installAutoplayDiag();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        ChangeNotifierProvider(create: (_) => TerminalState()),
        ChangeNotifierProvider(create: (_) => NetworkTerminalState()),
        ChangeNotifierProxyProvider<TerminalState, OscilloscopeState>(
          create: (context) => OscilloscopeState(Provider.of<TerminalState>(context, listen: false)),
          update: (context, terminal, previous) {
            previous?.updateTerminalState(terminal);
            return previous ?? OscilloscopeState(terminal);
          },
        ),
        ChangeNotifierProvider(create: (_) => MacroState()),
        ChangeNotifierProvider(create: (_) => HexEditorState()),
        ChangeNotifierProvider(create: (_) => TextEditorState()),
        ChangeNotifierProvider(create: (_) => FontExtractorState()),
        ChangeNotifierProvider(create: (_) => UiDesignerState()),
        ChangeNotifierProvider.value(value: ispState),
      ],
      child: const DebugToolSetApp(),
    ),
  );
}

/// 诊断自动播放（环境变量驱动，日常为空不生效）：ISP_AUTOPLAY=<视频
/// 路径> 启动 3s 后自动建 视频源→预览 流程并播放；状态栏指标每秒
/// 采样追加到 ISP_AUTOLOG（缺省 scratch/autoplay_bench.log），供无
/// 交互采集真机播放诊断数据（帧泵/构建/栅格/呈现峰值）。
/// ISP_AUTOMOD=<模块序号> 时同时切到该模块页（7=ISP Studio，预览
/// 可见才能复现上屏栅格开销）。
final ispState = IspStudioState();
final appState = AppState();

void _installAutoplayDiag() {
  final video = Platform.environment['ISP_AUTOPLAY'] ?? '';
  if (video.isEmpty) return;
  final logPath =
      Platform.environment['ISP_AUTOLOG'] ?? 'scratch/autoplay_bench.log';
  Timer(const Duration(seconds: 3), () async {
    try {
      final mod = int.tryParse(Platform.environment['ISP_AUTOMOD'] ?? '');
      if (mod != null) appState.setModuleIndex(mod);
      // ISP_AUTOFLOW=<.ispflow 路径>：加载既有流程（含用户的预览节点
      // 尺寸/仪器挂载），把其中第一个视频源的文件换成 ISP_AUTOPLAY——
      // 复现用户真实流程形态；缺省自建 视频源→预览 小图流程。
      final flow = Platform.environment['ISP_AUTOFLOW'] ?? '';
      String srcId;
      if (flow.isNotEmpty) {
        await ispState.importGraphFromFile(flow);
        srcId = ispState.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'video_source')
            .key;
      } else {
        srcId = ispState.graph.addNode('video_source', 0, 0);
        final prevId = ispState.graph.addNode('preview', 300, 0);
        ispState.graph.connect(srcId, 'out_rgb', prevId, 'in');
      }
      ispState.setParam(srcId, 'filePath', video);
      await ispState.autoFillFromVideo(srcId);
      // ISP_AUTOMAX=1：把第一个预览节点直接拉到铺满画布（录屏对比
      // 实验用——预览画面占满屏幕主体，与系统播放器全屏口径可比）。
      if (Platform.environment['ISP_AUTOMAX'] == '1') {
        final pv = ispState.graph.nodes.entries
            .where((e) => e.value.typeId == 'preview')
            .firstOrNull;
        if (pv != null) {
          pv.value.x = 12;
          pv.value.y = 12;
          pv.value.width = 2160;
          ispState.setPreviewExtraHeight(pv.key, 1280);
        }
      }
      // ISP_AUTOHASH=1：逐帧记录上屏内容的 FNV-1a 采样哈希到
      // <log>.hash（录屏对比实验——previewFrame 递增而上屏内容重复/
      // 乱序在此现形）。必须在 togglePlayback 之前注册：其 future 要
      // 等播放结束才完成。
      if (Platform.environment['ISP_AUTOHASH'] == '1') {
        var lastF = -1;
        var dumped = false;
        Timer.periodic(const Duration(milliseconds: 5), (_) {
          final f = ispState.previewFrame;
          if (f == lastF) return;
          lastF = f;
          final bytes = ispState.debugDisplayedBytes;
          if (bytes == null) return;
          if (!dumped && f >= 150) {
            dumped = true;
            File('scratch/app_frame_$f.bin').writeAsBytesSync(bytes);
          }
          var h = 0x811c9dc5;
          for (var i = 0; i < bytes.length; i += 16) {
            h ^= bytes[i];
            h = (h * 0x01000193) & 0xFFFFFFFF;
          }
          File('$logPath.hash').writeAsStringSync(
              '$f ${DateTime.now().microsecondsSinceEpoch} ${bytes.length} '
              '${h.toRadixString(16).padLeft(8, '0')}\n',
              mode: FileMode.append);
        });
      }
      await ispState.togglePlayback();
    } catch (e) {
      File(logPath).writeAsStringSync('autoplay error: $e\n',
          mode: FileMode.append);
    }
  });
  Timer.periodic(const Duration(seconds: 1), (_) {
    File(logPath).writeAsStringSync(
        '${DateTime.now().toIso8601String()} ${ispState.statusMessage}\n',
        mode: FileMode.append);
  });
}

class DebugToolSetApp extends StatelessWidget {
  const DebugToolSetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DebugToolSet',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark, // Force dark mode
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      home: const MainLayout(),
    );
  }
}
