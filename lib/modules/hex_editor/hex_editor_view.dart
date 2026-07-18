import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/hex_editor_state.dart';
import 'widgets/hex_view_panel.dart';
import 'widgets/byte_inspector_panel.dart';
import 'widgets/hex_calculator.dart';
import 'widgets/hex_merge_dialog.dart';

int _parseHexOffset(String value) {
  String trimmed = value.trim();
  if (trimmed.isEmpty) return 0;
  if (trimmed.toLowerCase().startsWith('0x')) {
    trimmed = trimmed.substring(2);
  }
  trimmed = trimmed.replaceAll(' ', '');
  try {
    return int.parse(trimmed, radix: 16);
  } catch (_) {
    return 0;
  }
}

String _formatHexOffset(int value) {
  final hex = (value & 0xFFFFFFFFFFFF).toRadixString(16).toUpperCase().padLeft(12, '0');
  return '0x${hex.substring(0, 4)} ${hex.substring(4, 8)} ${hex.substring(8, 12)}';
}

/// Simulates overtype (insert/overwrite) mode for a fixed-length hex field.
class _OvertypeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final oldText = oldValue.text;
    final newText = newValue.text;
    final oldLen = oldText.length;
    final newLen = newText.length;
    final cursor = newValue.selection.baseOffset;

    if (newLen != oldLen + 1 || cursor <= 0 || cursor > newLen) {
      return newValue;
    }

    final inserted = newText[cursor - 1];
    final int replaceStart;
    final int newCursor;
    if (cursor - 1 >= oldLen - 1) {
      replaceStart = oldLen - 1;
      newCursor = replaceStart;
    } else {
      replaceStart = cursor - 1;
      newCursor = cursor;
    }

    final replacement = oldText.replaceRange(replaceStart, replaceStart + 1, inserted);
    return TextEditingValue(
      text: replacement,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }
}

/// Formats a 12-digit hex offset as 0xXXXX XXXX XXXX while typing.
class _HexOffsetInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String raw = newValue.text.toLowerCase();
    var rawCursor = newValue.selection.baseOffset;

    if (raw.startsWith('0x')) {
      if (rawCursor >= 2) {
        rawCursor -= 2;
      } else {
        rawCursor = 0;
      }
      raw = raw.substring(2);
    }

    var hexCursor = 0;
    for (var i = 0; i < rawCursor && i < raw.length; i++) {
      if (raw[i] != ' ') hexCursor++;
    }

    raw = raw.replaceAll(' ', '');
    if (raw.isEmpty) {
      const text = '0x0000 0000 0000';
      return const TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    }

    final value = int.tryParse(raw, radix: 16);
    if (value == null) return oldValue;
    final clamped = value & 0xFFFFFFFFFFFF;
    final formatted = _formatHexOffset(clamped);

    final int formattedCursor;
    if (hexCursor >= 12) {
      formattedCursor = 15;
    } else {
      formattedCursor = 2 + hexCursor + (hexCursor ~/ 4);
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formattedCursor),
    );
  }
}

class HexEditorView extends StatefulWidget {
  const HexEditorView({super.key});

  @override
  State<HexEditorView> createState() => _HexEditorViewState();
}

class _HexEditorViewState extends State<HexEditorView> {
  final ScrollController _leftScrollController = ScrollController();
  final ScrollController _rightScrollController = ScrollController();
  final TextEditingController _leftOffsetController = TextEditingController(text: '0x0');
  final TextEditingController _rightOffsetController = TextEditingController(text: '0x0');
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _leftScrollController.addListener(() => _syncScroll(_leftScrollController, _rightScrollController));
    _rightScrollController.addListener(() => _syncScroll(_rightScrollController, _leftScrollController));
  }

  @override
  void dispose() {
    _leftScrollController.dispose();
    _rightScrollController.dispose();
    _leftOffsetController.dispose();
    _rightOffsetController.dispose();
    super.dispose();
  }

  void _syncScroll(ScrollController source, ScrollController target) {
    if (!mounted) return;
    final state = context.read<HexEditorState>();
    if (!state.isSyncScrollEnabled) return;
    if (_isSyncing) return;
    if (!target.hasClients) return;

    final double targetOffset = source.offset.clamp(0.0, target.position.maxScrollExtent);
    // Skip sub-row deltas to avoid rebuilding both panels on every scroll frame.
    if ((targetOffset - target.offset).abs() < 26.0) return;

    _isSyncing = true;
    target.jumpTo(targetOffset);
    _isSyncing = false;
  }

  void _showMergeDialog() {
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (context) => const HexMergeDialog(),
    );
  }

  Future<void> _showHexCalculator(BuildContext context, bool isLeft) async {
    final state = context.read<HexEditorState>();
    // Use the current text in the offset box directly so that an uncommitted
    // edit is still passed to the calculator's first operand.
    final controller = isLeft ? _leftOffsetController : _rightOffsetController;
    final current = _parseHexOffset(controller.text);
    if (isLeft) {
      state.setLeftOffset(current);
    } else {
      state.setRightOffset(current);
    }
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.all(12),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        content: HexCalculatorDialog(
          initialValue: current,
          onConfirm: (value) => Navigator.pop(dialogContext, value),
          onCancel: () => Navigator.pop(dialogContext),
        ),
      ),
    );
    if (result == null) return;
    if (isLeft) {
      state.setLeftOffset(result);
      controller.text = _formatHexOffset(result);
    } else {
      state.setRightOffset(result);
      controller.text = _formatHexOffset(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<HexEditorState>();
    final hasBoth = context.select<HexEditorState, bool>(
      (s) => s.leftFile != null && s.rightFile != null,
    );
    final diffCount = context.select<HexEditorState, int>((s) {
      if (s.leftFile == null || s.rightFile == null) return 0;
      return s.alignByAbsoluteAddress
          ? s.mismatchAbsoluteAddresses.length
          : s.mismatchOffsets.length;
    });
    final isSyncScrollEnabled = context.select<HexEditorState, bool>(
      (s) => s.isSyncScrollEnabled,
    );
    final alignByAbsoluteAddress = context.select<HexEditorState, bool>(
      (s) => s.alignByAbsoluteAddress,
    );
    final leftOffset = context.select<HexEditorState, int>((s) => s.leftOffset);
    final rightOffset = context.select<HexEditorState, int>((s) => s.rightOffset);

    // Keep offset input boxes in sync with state whenever they are visible.
    if (!alignByAbsoluteAddress) {
      final expectedLeft = _formatHexOffset(leftOffset);
      final expectedRight = _formatHexOffset(rightOffset);
      if (_leftOffsetController.text != expectedLeft) {
        _leftOffsetController.text = expectedLeft;
      }
      if (_rightOffsetController.text != expectedRight) {
        _rightOffsetController.text = expectedRight;
      }
    }

    final isCalculatingDifferences = context.select<HexEditorState, bool>(
      (s) => s.isCalculatingDifferences,
    );
    final differenceCalculationProgress = context.select<HexEditorState, double>(
      (s) => s.differenceCalculationProgress,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
        // Main Toolbar
        Container(
          height: 48,
          color: Theme.of(context).colorScheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Icon(Icons.memory, color: Colors.cyanAccent, size: 20),
              const SizedBox(width: 8),
              const Text(
                'HEX 比较与编辑器',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(width: 24),
              
              // Align mode switch
              const Text('对齐模式: ', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(width: 8),
              ToggleButtons(
                isSelected: [!alignByAbsoluteAddress, alignByAbsoluteAddress],
                onPressed: (index) {
                  state.toggleAlignByAbsoluteAddress(index == 1);
                },
                borderRadius: BorderRadius.circular(4),
                constraints: const BoxConstraints(minHeight: 26, minWidth: 80),
                fillColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                selectedColor: Colors.white,
                color: Colors.grey,
                children: const [
                  Text('字节偏移', style: TextStyle(fontSize: 11)),
                  Text('绝对地址', style: TextStyle(fontSize: 11)),
                ],
              ),
              const SizedBox(width: 20),

              // Per-side offset inputs (only in byte-offset mode)
              if (!alignByAbsoluteAddress) ...[
                const Text('左偏移:', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 180,
                  height: 28,
                  child: Tooltip(
                    message: '左侧文件参与比较的起始字节偏移（十六进制）',
                    child: TextField(
                      controller: _leftOffsetController,
                      inputFormatters: [_OvertypeFormatter(), _HexOffsetInputFormatter()],
                      cursorWidth: 7,
                      cursorRadius: Radius.zero,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'Consolas'),
                      decoration: InputDecoration(
                        hintText: '0x0',
                        hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                        filled: true,
                        fillColor: const Color(0xFF2A2A2A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(color: Colors.grey.shade700),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(color: Colors.grey.shade700),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: const BorderSide(color: Colors.cyanAccent),
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.calculate, color: Colors.grey, size: 16),
                          tooltip: '十六进制计算器',
                          onPressed: () => _showHexCalculator(context, true),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ),
                      onEditingComplete: () {
                        final parsed = _parseHexOffset(_leftOffsetController.text);
                        state.setLeftOffset(parsed);
                        _leftOffsetController.text = _formatHexOffset(parsed);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text('右偏移:', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 180,
                  height: 28,
                  child: Tooltip(
                    message: '右侧文件参与比较的起始字节偏移（十六进制）',
                    child: TextField(
                      controller: _rightOffsetController,
                      inputFormatters: [_OvertypeFormatter(), _HexOffsetInputFormatter()],
                      cursorWidth: 7,
                      cursorRadius: Radius.zero,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'Consolas'),
                      decoration: InputDecoration(
                        hintText: '0x0',
                        hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                        filled: true,
                        fillColor: const Color(0xFF2A2A2A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(color: Colors.grey.shade700),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(color: Colors.grey.shade700),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: const BorderSide(color: Colors.cyanAccent),
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.calculate, color: Colors.grey, size: 16),
                          tooltip: '十六进制计算器',
                          onPressed: () => _showHexCalculator(context, false),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ),
                      onEditingComplete: () {
                        final parsed = _parseHexOffset(_rightOffsetController.text);
                        state.setRightOffset(parsed);
                        _rightOffsetController.text = _formatHexOffset(parsed);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 20),
              ],

              // Sync Scroll Icon Toggle
              IconButton.filledTonal(
                onPressed: () => state.toggleSyncScroll(!isSyncScrollEnabled),
                icon: Icon(
                  isSyncScrollEnabled ? Icons.link : Icons.link_off,
                  size: 16,
                  color: isSyncScrollEnabled ? Colors.cyanAccent : Colors.grey,
                ),
                tooltip: isSyncScrollEnabled ? '已启用同步滚动' : '同步滚动已断开',
                style: IconButton.styleFrom(
                  backgroundColor: isSyncScrollEnabled 
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                      : const Color(0xFF2D2D2D),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(36, 28),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
              ),
              const Spacer(),

              // Comparison Badge info
              if (hasBoth)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: diffCount > 0 
                        ? Colors.redAccent.withValues(alpha: 0.15) 
                        : Colors.greenAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: diffCount > 0 ? Colors.redAccent : Colors.greenAccent,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        diffCount > 0 ? Icons.difference : Icons.check_circle_outline,
                        size: 14,
                        color: diffCount > 0 ? Colors.redAccent : Colors.greenAccent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        diffCount > 0 ? '检测到 $diffCount 处差异' : '两文件内容完全一致',
                        style: TextStyle(
                          color: diffCount > 0 ? Colors.redAccent : Colors.greenAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                )
              else
                const Text(
                  '请加载左右文件以进行差异比较',
                  style: TextStyle(color: Colors.grey, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              const SizedBox(width: 16),

              // File merger button
              ElevatedButton.icon(
                onPressed: _showMergeDialog,
                icon: const Icon(Icons.merge, size: 14, color: Colors.cyanAccent),
                label: const Text('合并文件', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2A2A2A),
                  elevation: 0,
                  side: BorderSide(color: Colors.grey.shade800),
                  minimumSize: const Size(0, 28),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Double side hex editors
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: HexViewPanel(
                  isLeft: true,
                  scrollController: _leftScrollController,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: HexViewPanel(
                  isLeft: false,
                  scrollController: _rightScrollController,
                ),
              ),
            ],
          ),
        ),

        // Byte Inspector footer panel
        const ByteInspectorPanel(),
            ],
          ),
        ),
        if (isCalculatingDifferences)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              child: Center(
                child: Container(
                  width: 420,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.grey.shade800),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '正在执行文件比较',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      ZebraProgressBar(
                        progress: differenceCalculationProgress,
                        isLeft: false,
                        isLoading: true,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(differenceCalculationProgress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'Consolas'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

}
