import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart'; // Uncomment after enabling dev mode & pub get
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
    await windowManager.show();
    await windowManager.setTitle(appTitle);
    await windowManager.focus();
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
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
        ChangeNotifierProvider(create: (_) => IspStudioState()),
      ],
      child: const DebugToolSetApp(),
    ),
  );
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
