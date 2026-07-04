import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/terminal_state.dart';
import 'connection_config_panel.dart';
import 'terminal_output_area.dart';
import 'terminal_input_box.dart';

class TerminalView extends StatefulWidget {
  const TerminalView({super.key});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  // 底部系统交互状态窗口初始高度设定为容纳 5 行文本的高度（约 130 像素）
  double _bottomHeight = 130.0;

  @override
  Widget build(BuildContext context) {
    final terminalState = context.watch<TerminalState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部连接配置面板
        const ConnectionConfigPanel(),
        const Divider(height: 1),
        
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const dividerHeight = 8.0;
              final availableHeight = constraints.maxHeight - dividerHeight;
              
              // 防止溢出的安全高度分配
              double bottomHeight = _bottomHeight;
              if (bottomHeight < 40) bottomHeight = 40; // 最小高度限制
              if (bottomHeight > availableHeight - 40) bottomHeight = availableHeight - 40; // 最大高度限制
              
              double topHeight = availableHeight - bottomHeight;

              return Column(
                children: [
                  // 纯数据终端 (上屏)
                  SizedBox(
                    height: topHeight,
                    child: TerminalOutputArea(
                      lines: terminalState.rawDataLog,
                      title: '纯净数据终端 (Raw Data)',
                      onClear: terminalState.clearTerminalOutput,
                      extraHeaderWidget: Row(
                        children: [
                          SizedBox(
                            height: 20,
                            width: 20,
                            child: Checkbox(
                              value: terminalState.hexDisplay,
                              onChanged: (val) {
                                if (val != null) terminalState.toggleHexDisplay(val);
                              },
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Text('Hex 接收', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
                  
                  // 可拖拽分割线
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onPanUpdate: (details) {
                      setState(() {
                        // 往上拖动 delta.dy 为负数，所以减去它是增加 bottomHeight
                        _bottomHeight -= details.delta.dy;
                        if (_bottomHeight < 40) _bottomHeight = 40;
                      });
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: Container(
                        height: dividerHeight,
                        color: Theme.of(context).colorScheme.surface,
                        child: Center(
                          child: Container(
                            height: 2,
                            width: 40,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade600,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  
                  // 系统交互状态 (下屏)
                  SizedBox(
                    height: bottomHeight,
                    child: TerminalOutputArea(
                      lines: terminalState.systemLog,
                      title: '系统交互状态 (System / Interaction)',
                      enableTimestamp: false,
                      showSaveAndDepth: false,
                      onClear: terminalState.clearSystemLog,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        
        const Divider(height: 1),
        
        // 命令输入框
        const TerminalInputBox(),
      ],
    );
  }
}
