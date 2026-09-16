import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import '../../providers/terminal_state.dart';
import '../../providers/terminal_session.dart';
import '../../utils/ansi_parser.dart';

class TerminalOutputArea extends StatefulWidget {
  final TerminalSession session;
  final List<TerminalLine> lines;
  final String title;
  final bool enableTimestamp;
  final VoidCallback? onClear;
  final Widget? extraHeaderWidget;
  final bool showSaveAndDepth;
  final bool showCursor;

  const TerminalOutputArea({
    super.key,
    required this.session,
    required this.lines,
    required this.title,
    this.enableTimestamp = true,
    this.onClear,
    this.extraHeaderWidget,
    this.showSaveAndDepth = true,
    this.showCursor = false,
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

  /// 字体与行距设置弹窗：调整实时生效（经 session 的 notifyListeners 触发重建）
  void _showFontSettings() {
    final session = widget.session;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('字体与行距', style: TextStyle(fontSize: 14)),
          content: SizedBox(
            width: 320,
            child: AnimatedBuilder(
              animation: session as ChangeNotifier,
              builder: (context, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('字体', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: session.fontFamily,
                        isExpanded: true,
                        iconSize: 16,
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                        dropdownColor: Theme.of(dialogContext).colorScheme.surfaceContainerHighest,
                        items: TerminalSession.fontFamilies.map((family) {
                          return DropdownMenuItem<String>(
                            value: family,
                            child: Text(family, style: TextStyle(fontSize: 12, fontFamily: family)),
                          );
                        }).toList(),
                        onChanged: (v) {
                          if (v != null) session.setFontFamily(v);
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('字号: ${session.fontSize.toStringAsFixed(0)}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    Slider(
                      value: session.fontSize,
                      min: 8,
                      max: 24,
                      divisions: 16,
                      onChanged: session.setFontSize,
                    ),
                    Text('行距: ${session.lineHeight.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    Slider(
                      value: session.lineHeight,
                      min: 0.5,
                      max: 2.0,
                      divisions: 30,
                      onChanged: session.setLineHeight,
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                session.saveFontSettingsAsDefault();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已保存为默认字体设置，下次启动生效'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: const Text('设定为默认值'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  /// 右键菜单：全选、复制、设置字体与行距
  Widget _buildContextMenu(BuildContext context, SelectableRegionState state) {
    // 复用框架默认项（复制仅在有选区时出现），重贴中文标签并按 全选/复制 排序
    const labels = {
      ContextMenuButtonType.selectAll: '全选',
      ContextMenuButtonType.copy: '复制',
    };
    const order = [
      ContextMenuButtonType.selectAll,
      ContextMenuButtonType.copy,
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        for (final type in order)
          for (final item in state.contextMenuButtonItems)
            if (item.type == type) item.copyWith(label: labels[type]),
        ContextMenuButtonItem(
          label: '设置字体与行距',
          onPressed: () {
            state.hideToolbar();
            _showFontSettings();
          },
        ),
      ],
    );
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
          color: const Color(0xFF2E2E2E),
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
                          value: widget.session.maxLines,
                          isExpanded: true,
                          isDense: true,
                          iconSize: 16,
                          style: const TextStyle(fontSize: 11, color: Colors.white),
                          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          items: TerminalSession.rollbackDepths.map((int value) {
                            return DropdownMenuItem<int>(
                              value: value,
                              child: Text('$value', style: const TextStyle(fontSize: 11)),
                            );
                          }).toList(),
                          onChanged: (int? newValue) {
                            if (newValue != null) {
                              widget.session.setMaxLines(newValue);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(width: 1, height: 12, color: Theme.of(context).dividerColor),
                    const SizedBox(width: 8),
                    // 字体与行距设置
                    IconButton(
                      icon: const Icon(Icons.text_fields, size: 14, color: Colors.blueAccent),
                      tooltip: '字体与行距',
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                      onPressed: _showFontSettings,
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
              // SelectionArea 的手势处理会把焦点抢到文本选择区，
              // 帧后再请求一次，确保焦点最终落在命令输入框
              final node = widget.session.commandFocusNode;
              if (node == null) return;
              node.requestFocus();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                node.requestFocus();
              });
            },
            behavior: HitTestBehavior.translucent,
            child: Container(
              color: Colors.black,
              child: SelectionArea(
                contextMenuBuilder: _buildContextMenu,
                child: ListView.builder(
                  controller: _scrollController,
                  // 底部预留一行高度，最后一行不贴底
                  padding: EdgeInsets.only(
                      bottom: widget.session.fontSize * widget.session.lineHeight + 4),
                  itemCount: widget.lines.length + (widget.showCursor ? 1 : 0),
                  itemBuilder: (context, index) {
                    // 末尾单独一行渲染闪烁光标（标准终端风格）
                    if (widget.showCursor && index == widget.lines.length) {
                      return _CursorLine(session: widget.session);
                    }
                    final line = widget.lines[index];
                    String contentStr = line.content;

                    final session = widget.session;
                    if (widget.enableTimestamp && session.showTimestamp && session.connectionStartTime != null) {
                      Duration diff = line.timestamp.difference(session.connectionStartTime!);
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
                          TextStyle(
                            fontFamily: widget.session.fontFamily,
                            fontSize: widget.session.fontSize,
                            height: widget.session.lineHeight,
                            color: const Color(0xFFCCCCCC),
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

/// 标准终端风格的闪烁块状光标：占用输出末尾单独一行。
/// 命令输入框（终端焦点）持有焦点时以 500ms 周期闪烁，失焦后隐藏。
class _CursorLine extends StatefulWidget {
  final TerminalSession session;

  const _CursorLine({required this.session});

  @override
  State<_CursorLine> createState() => _CursorLineState();
}

class _CursorLineState extends State<_CursorLine> {
  Timer? _blinkTimer;
  bool _cursorOn = false;
  FocusNode? _listenedNode;

  FocusNode? get _focusNode => widget.session.commandFocusNode;

  @override
  void initState() {
    super.initState();
    _ensureListening();
    // 输入框在同一帧稍后构建并注册焦点节点，首帧后重试一次绑定
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureListening();
    });
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _listenedNode?.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _ensureListening() {
    final node = _focusNode;
    if (node == _listenedNode) return;
    _listenedNode?.removeListener(_onFocusChanged);
    _listenedNode = node;
    node?.addListener(_onFocusChanged);
    // 本方法可能在 build 中被调用，状态更新推迟到帧后，避免 build 期 setState
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFocusChanged());
  }

  void _onFocusChanged() {
    if (!mounted) return;
    final focused = _focusNode?.hasFocus ?? false;
    if (focused) {
      _blinkTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() => _cursorOn = !_cursorOn);
      });
      if (!_cursorOn) setState(() => _cursorOn = true);
    } else {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      if (_cursorOn) setState(() => _cursorOn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureListening();
    final session = widget.session;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: (session.fontSize * 0.6).clamp(5.0, 16.0),
          height: session.fontSize,
          color: _cursorOn ? const Color(0xFFCCCCCC) : Colors.transparent,
        ),
      ),
    );
  }
}
