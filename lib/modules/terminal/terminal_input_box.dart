import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/terminal_state.dart';
import '../../providers/macro_state.dart';
import 'macro_toolbar.dart';
import '../../utils/terminal_input_formatter.dart';

class TerminalInputBox extends StatefulWidget {
  const TerminalInputBox({super.key});

  @override
  State<TerminalInputBox> createState() => _TerminalInputBoxState();
}

class _TerminalInputBoxState extends State<TerminalInputBox> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final terminalState = context.read<TerminalState>();
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            String? prev = terminalState.getPreviousCommand(isHex: _isHexMode);
            if (prev != null) {
              _controller.text = prev;
              _controller.selection = TextSelection.collapsed(offset: prev.length);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            String? next = terminalState.getNextCommand(isHex: _isHexMode);
            if (next != null) {
              _controller.text = next;
              _controller.selection = TextSelection.collapsed(offset: next.length);
            }
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
    );
  }

  bool _isHexMode = false;
  String _eolMode = 'None';
  bool _isPeriodic = false;
  int _periodicIntervalMs = 1000;
  Timer? _periodicTimer;



  @override
  void dispose() {
    _periodicTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submitCommand() {
    final terminalState = context.read<TerminalState>();
    if (!terminalState.isConnected) {
      terminalState.addSystemLog('\x1b[33m[Warning] 请先连接设备。\x1b[0m');
      return;
    }

    String command = _controller.text.trim();
    if (command.isEmpty) return;

    if (_isHexMode) {
      List<String> chunks = command.split(RegExp(r'\s+'));
      for (int i = 0; i < chunks.length; i++) {
        if (chunks[i].length == 1) chunks[i] = '0${chunks[i]}';
      }
      command = chunks.join(' ');
      _controller.text = command;
      _controller.selection = TextSelection.collapsed(offset: command.length);
    }

    if (_isPeriodic) {
      if (_periodicTimer != null) {
        _periodicTimer!.cancel();
        _periodicTimer = null;
        terminalState.addSystemLog('\x1b[33m[SYSTEM] 停止定时发送。\x1b[0m');
      } else {
        terminalState.addSystemLog('\x1b[33m[SYSTEM] 开启定时发送，间隔 ${_periodicIntervalMs}ms。\x1b[0m');
        _periodicTimer = Timer.periodic(Duration(milliseconds: _periodicIntervalMs), (timer) {
          if (!mounted || !terminalState.isConnected) {
            timer.cancel();
            setState(() { _periodicTimer = null; });
            terminalState.addSystemLog('\x1b[33m[SYSTEM] 设备断开，定时发送自动停止。\x1b[0m');
            return;
          }
          terminalState.sendCommand(command, isHex: _isHexMode, eolMode: _eolMode);
        });
      }
      setState(() {});
    } else {
      terminalState.sendCommand(command, isHex: _isHexMode, eolMode: _eolMode);
    }
    terminalState.addCommandToHistory(command, isHex: _isHexMode);
    context.read<MacroState>().recordStep(command, _isHexMode, _eolMode);

    if (!_isPeriodic) {
      _controller.clear();
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 第一行：独立的宏工具栏
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(6),
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.05),
            ),
            child: MacroToolbar(
              onPlayCommand: (command, isHex, eolMode) {
                final terminalState = context.read<TerminalState>();
                terminalState.sendCommand(command, isHex: isHex, eolMode: eolMode);
              },
            ),
          ),
          const SizedBox(height: 8),
          
          // 第二行：命令行靠左，发送设置靠右
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 命令行 (靠左)
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
                      borderRadius: BorderRadius.circular(6),
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.1),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              hintText: '输入要发送的数据...',
                              hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
                            ),
                            style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                            inputFormatters: [
                              if (_isHexMode) HexInputFormatter() else AsciiInputFormatter(),
                            ],
                            onSubmitted: (_) => _submitCommand(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          icon: Icon(_periodicTimer != null ? Icons.stop : Icons.send, size: 16),
                          tooltip: _periodicTimer != null ? '停止定时发送' : '发送',
                          style: IconButton.styleFrom(
                            backgroundColor: _periodicTimer != null ? Colors.red.shade700 : Colors.blueAccent.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            minimumSize: const Size(36, 36),
                          ),
                          onPressed: _submitCommand,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                
                // 结束符与发送设置组 (靠右)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(6),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.05),
                  ),
                  child: Row(
                    children: [
                      const Text('结束符: ', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 85,
                        child: DropdownButtonFormField<String>(
                          initialValue: _eolMode,
                          isExpanded: true,
                          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.all(4), border: OutlineInputBorder()),
                          items: ['None', 'CR', 'LF', 'CRLF'].map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 12)))).toList(),
                          onChanged: _periodicTimer != null || _isHexMode ? null : (val) {
                            if (val != null) setState(() => _eolMode = val);
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Row(
                        children: [
                          Checkbox(
                            value: _isHexMode,
                            onChanged: _periodicTimer != null ? null : (val) {
                              if (val != null) {
                                final terminalState = context.read<TerminalState>();
                                setState(() {
                                  if (_controller.text.trim().isNotEmpty) {
                                    terminalState.addCommandToHistory(_controller.text, isHex: _isHexMode);
                                  }
                                  
                                  _isHexMode = val;
                                  
                                  String latest = terminalState.getLatestCommand(isHex: _isHexMode) ?? '';
                                  _controller.text = latest;
                                  _controller.selection = TextSelection.collapsed(offset: latest.length);
                                });
                              }
                            },
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          const Text('Hex 发送', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                      const SizedBox(width: 16),
                      Row(
                        children: [
                          Checkbox(
                            value: _isPeriodic,
                            onChanged: _periodicTimer != null ? null : (val) {
                              if (val != null) setState(() => _isPeriodic = val);
                            },
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          const Text('定时发送', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                      const SizedBox(width: 8),
                      if (_isPeriodic) ...[
                        SizedBox(
                          width: 50,
                          child: TextField(
                            enabled: _periodicTimer == null,
                            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.all(4), border: OutlineInputBorder()),
                            controller: TextEditingController(text: _periodicIntervalMs.toString())..selection = TextSelection.collapsed(offset: _periodicIntervalMs.toString().length),
                            style: const TextStyle(fontSize: 12),
                            onChanged: (val) {
                              int? parsed = int.tryParse(val);
                              if (parsed != null && parsed > 0) _periodicIntervalMs = parsed;
                            },
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text('ms', style: TextStyle(fontSize: 12)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
