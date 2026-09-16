import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/network_terminal_state.dart';
import '../terminal/terminal_output_area.dart';
import '../terminal/terminal_input_box.dart';
import 'network_config_panel.dart';

class NetworkTerminalView extends StatefulWidget {
  const NetworkTerminalView({super.key});

  @override
  State<NetworkTerminalView> createState() => _NetworkTerminalViewState();
}

class _NetworkTerminalViewState extends State<NetworkTerminalView> {
  // 底部系统交互状态窗口初始高度设定为容纳 5 行文本的高度（约 130 像素）
  double _bottomHeight = 130.0;

  // 系统交互状态（下屏）是否可见；默认隐藏，底部显示细长恢复条
  bool _bottomVisible = false;

  // 宏工具栏是否可见；默认隐藏，与系统交互状态的恢复条共用一行
  bool _macroVisible = false;

  // 已处理的错误级系统日志计数，用于错误出现时自动展开隐藏的系统交互状态
  int _lastSystemLogErrorCount = 0;

  void _toggleBottomVisible() {
    setState(() => _bottomVisible = !_bottomVisible);
  }

  /// 恢复条中的单个条目：图标按钮 + 说明文字，单击按钮或双击条目恢复
  Widget _restoreEntry({
    required String label,
    required String tooltip,
    required VoidCallback onRestore,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTap: onRestore,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up,
                  size: 14, color: Colors.blueAccent),
              tooltip: tooltip,
              splashRadius: 12,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: onRestore,
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white)),
          ],
        ),
      ),
    );
  }

  /// 隐藏面板的统一恢复条：左侧系统交互状态，右侧宏工具栏
  Widget _buildRestoreStrip() {
    return Container(
      height: 24,
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_bottomVisible)
            const SizedBox.shrink()
          else
            _restoreEntry(
              label: '系统交互状态已隐藏（双击恢复）',
              tooltip: '显示系统交互状态',
              onRestore: _toggleBottomVisible,
            ),
          if (_macroVisible)
            const SizedBox.shrink()
          else
            _restoreEntry(
              label: '宏工具栏已隐藏（双击恢复）',
              tooltip: '显示宏工具栏',
              onRestore: () => setState(() => _macroVisible = true),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final networkState = context.watch<NetworkTerminalState>();

    // 出现新的错误级系统日志时，若系统交互状态处于隐藏则自动展开
    if (networkState.systemLogErrorCount != _lastSystemLogErrorCount) {
      _lastSystemLogErrorCount = networkState.systemLogErrorCount;
      if (!_bottomVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_bottomVisible) {
            setState(() => _bottomVisible = true);
          }
        });
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部连接配置面板
        const NetworkConfigPanel(),
        const Divider(height: 1),

        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const dividerHeight = 8.0;
              // 隐藏下屏时不预留分割线高度，恢复条移至输出区与输入框之间
              final availableHeight =
                  constraints.maxHeight - (_bottomVisible ? dividerHeight : 0.0);

              // 防止溢出的安全高度分配
              double bottomHeight = _bottomVisible ? _bottomHeight : 0.0;
              if (_bottomVisible) {
                if (bottomHeight < 40) bottomHeight = 40; // 最小高度限制
                if (bottomHeight > availableHeight - 40) bottomHeight = availableHeight - 40; // 最大高度限制
              }

              double topHeight = availableHeight - bottomHeight;

              return Column(
                children: [
                  // 纯数据终端 (上屏)
                  SizedBox(
                    height: topHeight,
                    child: TerminalOutputArea(
                      session: networkState,
                      lines: networkState.rawDataLog,
                      title: '纯净数据终端 (Raw Data)',
                      showCursor: true,
                      onClear: networkState.clearTerminalOutput,
                      extraHeaderWidget: Row(
                        children: [
                          SizedBox(
                            height: 20,
                            width: 20,
                            child: Checkbox(
                              value: networkState.hexDisplay,
                              onChanged: (val) {
                                if (val != null) networkState.toggleHexDisplay(val);
                              },
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Text('Hex 接收', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          const SizedBox(width: 8),
                          Container(width: 1, height: 12, color: Theme.of(context).dividerColor),
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 20,
                            width: 20,
                            child: Checkbox(
                              value: networkState.showTimestamp,
                              onChanged: (val) {
                                if (val != null) networkState.toggleShowTimestamp(val);
                              },
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Text('显示时间戳', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),

                  // 可拖拽分割线（双击隐藏下屏）
                  if (_bottomVisible)
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: _toggleBottomVisible,
                      onPanUpdate: (details) {
                        setState(() {
                          // 往上拖动 delta.dy 为负数，所以减去它是增加 bottomHeight
                          _bottomHeight -= details.delta.dy;
                          if (_bottomHeight < 40) _bottomHeight = 40;
                        });
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        child: Tooltip(
                          message: '拖拽调整高度，双击隐藏',
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
                    ),

                  // 系统交互状态 (下屏)；隐藏时不渲染，由恢复条统一恢复
                  if (_bottomVisible)
                    SizedBox(
                      height: bottomHeight,
                      child: TerminalOutputArea(
                        session: networkState,
                        lines: networkState.systemLog,
                        title: '系统交互状态 (System / Interaction)',
                        enableTimestamp: false,
                        showSaveAndDepth: false,
                        onClear: networkState.clearSystemLog,
                        extraHeaderWidget: IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down,
                              size: 14, color: Colors.blueAccent),
                          tooltip: '隐藏系统交互状态',
                          splashRadius: 16,
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 24, minHeight: 24),
                          onPressed: _toggleBottomVisible,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),

        // 隐藏面板的统一恢复条：左侧系统交互状态，右侧宏工具栏
        if (!_bottomVisible || !_macroVisible) ...[
          const Divider(height: 1),
          _buildRestoreStrip(),
        ],

        const Divider(height: 1),

        // 命令输入框
        TerminalInputBox(
          session: networkState,
          showMacroToolbar: _macroVisible,
          onHideMacro: () => setState(() => _macroVisible = false),
        ),
      ],
    );
  }
}
