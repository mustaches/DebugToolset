// 一次性测量脚本：渲染串口/网络终端的配置面板与命令输入框，打印实际高度。
// 运行：flutter test scratch/measure_terminal_heights_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/providers/terminal_state.dart';
import 'package:debug_tool_set/providers/network_terminal_state.dart';
import 'package:debug_tool_set/providers/macro_state.dart';
import 'package:debug_tool_set/modules/terminal/connection_config_panel.dart';
import 'package:debug_tool_set/modules/network_terminal/network_config_panel.dart';
import 'package:debug_tool_set/modules/terminal/terminal_input_box.dart';
import 'package:debug_tool_set/theme/app_theme.dart';

void main() {
  testWidgets('measure terminal panel heights', (tester) async {
    final terminalState = TerminalState();
    final networkState = NetworkTerminalState();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: terminalState),
          ChangeNotifierProvider.value(value: networkState),
          ChangeNotifierProvider(create: (_) => MacroState()),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Column(
              children: [
                const ConnectionConfigPanel(key: Key('serialPanel')),
                const NetworkConfigPanel(key: Key('networkPanel')),
                Builder(
                  builder: (context) => TerminalInputBox(
                    key: const Key('serialInput'),
                    session: context.read<TerminalState>(),
                  ),
                ),
                Builder(
                  builder: (context) => TerminalInputBox(
                    key: const Key('networkInput'),
                    session: context.read<NetworkTerminalState>(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    void report(String name, Key key) {
      final size = tester.getSize(find.byKey(key));
      debugPrint('$name: w=${size.width} h=${size.height}');
    }

    report('串口配置面板', const Key('serialPanel'));
    report('网络配置面板', const Key('networkPanel'));
    report('串口命令输入区', const Key('serialInput'));
    report('网络命令输入区', const Key('networkInput'));

    final toggle = tester.getSize(find.byType(ToggleButtons));
    debugPrint('TCP/SSH ToggleButtons: h=${toggle.height}');

    // 网络面板里的主机输入框外层 Container（28 高）
    final hostBox = tester.getSize(find
        .descendant(
          of: find.byType(NetworkConfigPanel),
          matching: find.byType(TextField),
        )
        .first);
    debugPrint('网络主机输入框 TextField: h=${hostBox.height}');
  });
}
