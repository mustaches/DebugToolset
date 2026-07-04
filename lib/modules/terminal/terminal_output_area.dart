import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import '../../providers/terminal_state.dart';
import '../../utils/ansi_parser.dart';

class TerminalOutputArea extends StatefulWidget {
  final List<TerminalLine> lines;
  final String title;
  final bool enableTimestamp;
  final VoidCallback? onClear;
  final Widget? extraHeaderWidget;
  final bool showSaveAndDepth;

  const TerminalOutputArea({
    super.key,
    required this.lines,
    required this.title,
    this.enableTimestamp = true,
    this.onClear,
    this.extraHeaderWidget,
    this.showSaveAndDepth = true,
  });

  @override
  State<TerminalOutputArea> createState() => _TerminalOutputAreaState();
}

class _TerminalOutputAreaState extends State<TerminalOutputArea> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients && _autoScroll) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  Future<void> _saveToFile() async {
    final String text = widget.lines.map((e) => e.content).join('\n');
    final FileSaveLocation? result = await getSaveLocation(
      acceptedTypeGroups: [
        XTypeGroup(label: 'Text Documents', extensions: ['txt', 'log'])
      ],
      suggestedName: 'terminal_log_${DateTime.now().millisecondsSinceEpoch}.txt',
    );
    if (result != null) {
      final Uint8List fileData = Uint8List.fromList(text.codeUnits);
      final XFile textFile = XFile.fromData(fileData, mimeType: 'text/plain', name: 'log.txt');
      await textFile.saveTo(result.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存到文件'), duration: Duration(seconds: 2)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // We defer scrolling to bottom after the layout phase
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Theme.of(context).colorScheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.extraHeaderWidget != null) ...[
                    widget.extraHeaderWidget!,
                    const SizedBox(width: 8),
                    Container(width: 1, height: 12, color: Theme.of(context).dividerColor),
                    const SizedBox(width: 8),
                  ],
                  if (widget.onClear != null) ...[
                    if (widget.showSaveAndDepth) ...[
                      IconButton(
                        icon: const Icon(Icons.save_alt, size: 14, color: Colors.blueAccent),
                        tooltip: '另存为文件',
                        splashRadius: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        onPressed: _saveToFile,
                      ),
                      const SizedBox(width: 8),
                      Container(width: 1, height: 12, color: Theme.of(context).dividerColor),
                      const SizedBox(width: 8),
                    ],
                    IconButton(
                      icon: const Icon(Icons.delete_sweep, size: 14, color: Colors.blueAccent),
                      tooltip: '清除输出',
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onPressed: widget.onClear,
                    ),
                    const SizedBox(width: 8),
                    Container(width: 1, height: 12, color: Theme.of(context).dividerColor),
                    const SizedBox(width: 8),
                  ],
                  
                  if (widget.showSaveAndDepth) ...[
                    // 回滚深度下拉框
                    const Text('回滚深度:', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 80,
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: context.watch<TerminalState>().maxLines,
                          isExpanded: true,
                          iconSize: 16,
                          style: const TextStyle(fontSize: 11, color: Colors.white),
                          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          items: TerminalState.rollbackDepths.map((int value) {
                            return DropdownMenuItem<int>(
                              value: value,
                              child: Text('$value', style: const TextStyle(fontSize: 11)),
                            );
                          }).toList(),
                          onChanged: (int? newValue) {
                            if (newValue != null) {
                              context.read<TerminalState>().setMaxLines(newValue);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(width: 1, height: 12, color: Theme.of(context).dividerColor),
                    const SizedBox(width: 8),
                  ],
                  
                  SizedBox(
                    height: 20,
                    width: 20,
                    child: Checkbox(
                      value: _autoScroll,
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _autoScroll = val;
                            if (_autoScroll) _scrollToBottom();
                          });
                        }
                      },
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text('自动滚动', style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              )
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: GestureDetector(
            onTap: () {
              context.read<TerminalState>().commandFocusNode?.requestFocus();
            },
            behavior: HitTestBehavior.translucent,
            child: Container(
              color: const Color(0xFF1E1E1E),
              child: SelectionArea(
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: widget.lines.length,
                  itemBuilder: (context, index) {
                    final line = widget.lines[index];
                    String contentStr = line.content;

                    final terminalState = context.read<TerminalState>();
                    if (widget.enableTimestamp && terminalState.showTimestamp && terminalState.connectionStartTime != null) {
                      Duration diff = line.timestamp.difference(terminalState.connectionStartTime!);
                      if (!diff.isNegative) {
                        String ts = '${diff.inDays.toString().padLeft(2, '0')}:'
                            '${(diff.inHours % 24).toString().padLeft(2, '0')}:'
                            '${(diff.inMinutes % 60).toString().padLeft(2, '0')}:'
                            '${(diff.inSeconds % 60).toString().padLeft(2, '0')}.'
                            '${(diff.inMilliseconds % 1000).toString().padLeft(3, '0')}';
                        contentStr = '\x1b[90m[$ts]\x1b[0m $contentStr';
                      }
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                      child: Text.rich(
                        AnsiParser.parse(
                          contentStr,
                          const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 14,
                            color: Color(0xFFCCCCCC),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
