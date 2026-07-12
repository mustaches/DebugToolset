import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart'; // Uncomment after enabling dev mode & pub get

import 'layout/main_layout.dart';
import 'providers/app_state.dart';
import 'providers/terminal_state.dart';
import 'providers/macro_state.dart';
import 'providers/oscilloscope_state.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize window_manager
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1666, 834),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
    title: 'DebugToolSet',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider(create: (_) => TerminalState()),
        ChangeNotifierProxyProvider<TerminalState, OscilloscopeState>(
          create: (context) => OscilloscopeState(Provider.of<TerminalState>(context, listen: false)),
          update: (context, terminal, previous) {
            previous?.updateTerminalState(terminal);
            return previous ?? OscilloscopeState(terminal);
          },
        ),
        ChangeNotifierProvider(create: (_) => MacroState()),
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
