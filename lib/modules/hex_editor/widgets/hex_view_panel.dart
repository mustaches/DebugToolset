import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import '../../../providers/hex_editor_state.dart';
import '../models/hex_file_data.dart';
import 'hex_minimap.dart';

class HexViewPanel extends StatefulWidget {
  final bool isLeft;
  final ScrollController scrollController;

  const HexViewPanel({
    super.key,
    required this.isLeft,
    required this.scrollController,
  });

  @override
  State<HexViewPanel> createState() => _HexViewPanelState();
}

class _HexViewPanelState extends State<HexViewPanel> {
  // Forwarding getters so all methods can use isLeft / scrollController directly
  bool get isLeft => widget.isLeft;
  ScrollController get scrollController => widget.scrollController;

  /// Address where the current drag selection started (null = not dragging)
  int? _dragStartAddr;

  /// Latest pointer position in list-local coordinates during a drag
  Offset? _lastDragLocalPos;

  /// Auto-scroll timer fired while pointer is near the viewport edge
  Timer? _autoScrollTimer;

  /// GlobalKey for the GestureDetector wrapper so we can measure viewport height
  final GlobalKey _listKey = GlobalKey();

  /// Parameters forwarded from the build to auto-scroll callbacks
  HexFileData? _dragFile;
  int _dragRowCount = 0;
  bool _dragAlignAbs = false;
  int _dragAlignedStart = 0;
  int _dragSideOffset = 0;
  HexEditorState? _dragState;

  /// Current address-column geometry, updated each build so hit tests stay aligned.
  double _addrColWidth = 100.0;
  double _addrGapWidth = 12.0;

  // ---------------------------------------------------------------------------
  // Edit mode state
  // ---------------------------------------------------------------------------
  bool _isEditMode = false;
  final FocusNode _editFocusNode = FocusNode();
  /// Address of the cell currently being typed into
  int? _editingAddr;
  /// First hex nibble typed (0-15), null means waiting for first char
  int? _pendingNibble;
  /// Whether the mouse is hovering over the edit-mode toggle icon
  bool _isHoveringEdit = false;

  /// Whether the external-change prompt is currently shown.
  bool _externalChangePromptShown = false;

  // Auto-scroll constants
  static const double _edgeThreshold = 48.0;  // px from edge that triggers auto-scroll
  static const double _scrollStep = 26.0;      // px per timer tick (= 1 row)
  static const Duration _scrollInterval = Duration(milliseconds: 40); // ~25 fps

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _tryAutoScroll(Offset localPos) {
    final RenderBox? rb = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final double viewportH = rb.size.height;
    _lastDragLocalPos = localPos;

    final bool nearBottom = localPos.dy > viewportH - _edgeThreshold;
    final bool nearTop = localPos.dy < _edgeThreshold;

    if (!nearBottom && !nearTop) {
      _stopAutoScroll();
      return;
    }

    // Already scrolling in the right direction – keep the existing timer
    if (_autoScrollTimer != null) return;

    _autoScrollTimer = Timer.periodic(_scrollInterval, (_) {
      if (!scrollController.hasClients) { _stopAutoScroll(); return; }

      final double current = scrollController.offset;
      final double max = scrollController.position.maxScrollExtent;

      final RenderBox? rb2 = _listKey.currentContext?.findRenderObject() as RenderBox?;
      final double h = rb2?.size.height ?? 0;
      final Offset? pos = _lastDragLocalPos;
      if (pos == null) { _stopAutoScroll(); return; }

      double delta = 0;
      if (pos.dy > h - _edgeThreshold) {
        delta = _scrollStep;
      } else if (pos.dy < _edgeThreshold) {
        delta = -_scrollStep;
      } else {
        _stopAutoScroll();
        return;
      }

      final double next = (current + delta).clamp(0.0, max);
      scrollController.jumpTo(next);

      // Re-evaluate selection after scroll using stored pointer pos
      final f = _dragFile;
      final st = _dragState;
      if (_dragStartAddr != null && f != null && st != null) {
        final addr = _addrFromLocalPosition(pos, f, _dragRowCount, _dragAlignAbs, _dragAlignedStart, _dragSideOffset);
        if (addr != null) st.setSelection(isLeft, _dragStartAddr!, addr);
      }
    });
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _editFocusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Keyboard editing handler
  // ---------------------------------------------------------------------------

  /// Called by the KeyboardListener when a key is pressed in edit mode.
  void _handleEditKeyEvent(KeyEvent event, HexEditorState state) {
    if (!_isEditMode) return;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    final addr = _editingAddr;
    if (addr == null) return;

    final logical = event.logicalKey;
    // Navigate cells with arrow keys
    if (logical == LogicalKeyboardKey.arrowRight || logical == LogicalKeyboardKey.tab) {
      setState(() { _editingAddr = addr + 1; _pendingNibble = null; });
      return;
    }
    if (logical == LogicalKeyboardKey.arrowLeft) {
      setState(() { _editingAddr = addr - 1 < 0 ? 0 : addr - 1; _pendingNibble = null; });
      return;
    }
    if (logical == LogicalKeyboardKey.arrowDown) {
      setState(() { _editingAddr = addr + 16; _pendingNibble = null; });
      return;
    }
    if (logical == LogicalKeyboardKey.arrowUp) {
      setState(() { _editingAddr = addr > 16 ? addr - 16 : 0; _pendingNibble = null; });
      return;
    }
    if (logical == LogicalKeyboardKey.escape) {
      setState(() { _isEditMode = false; _editingAddr = null; _pendingNibble = null; });
      return;
    }

    // Hex digit input
    const hexChars = '0123456789abcdefABCDEF';
    final char = event.character;
    if (char == null || char.isEmpty || !hexChars.contains(char)) return;
    final nibble = int.parse(char, radix: 16);

    if (_pendingNibble == null) {
      // First nibble: store and wait
      setState(() { _pendingNibble = nibble; });
    } else {
      // Second nibble: form the byte, commit, advance
      final newByte = (_pendingNibble! << 4) | nibble;
      state.editByte(isLeft, addr, newByte);
      setState(() { _editingAddr = addr + 1; _pendingNibble = null; });
    }
  }

  // ---------------------------------------------------------------------------
  // Address calculation from pointer position
  // ---------------------------------------------------------------------------

  /// Converts a [localOffset] inside the list viewport to an absolute/offset
  /// address. Returns null if the pointer is outside the hex byte grid area.
  int? _addrFromLocalPosition(
    Offset localOffset,
    HexFileData file,
    int rowCount,
    bool alignAbs,
    int alignedStart,
    int sideOffset,
  ) {
    const double rowHeight = 26.0;
    const double listTopPad = 4.0;    // ListView vertical padding
    const double listLeftPad = 16.0;  // ListView horizontal padding
    const double cellW = 24.0;
    const double cellGap = 4.0;
    const double midGap = 12.0;       // extra gap after byte 7

    final double scrollOffset = scrollController.hasClients ? scrollController.offset : 0;
    final double contentY = localOffset.dy + scrollOffset - listTopPad;
    if (contentY < 0) return null;

    final int rowIndex = (contentY / rowHeight).floor();
    if (rowIndex < 0 || rowIndex >= rowCount) return null;

    // x position relative to the start of the hex byte grid
    final double hexGridX = localOffset.dx - listLeftPad - _addrColWidth - _addrGapWidth;
    if (hexGridX < 0) return null;

    // Determine which byte column (0-15) the pointer is over.
    // First 8 cells: [cell(4gap)cell(4gap)...cell(12gap)], then next 8: same without trailing gap
    int col = -1;
    double x = 0;
    for (int i = 0; i < 16; i++) {
      final double cellEnd = x + cellW;
      if (hexGridX >= x && hexGridX < cellEnd) {
        col = i;
        break;
      }
      x += cellW;
      if (i < 15) x += (i == 7 ? midGap : cellGap);
    }
    if (col < 0) return null;

    final int rowVirtualOffset = rowIndex * 16;
    if (alignAbs) {
      return alignedStart + rowVirtualOffset + col;
    }
    return file.baseAddress + sideOffset + rowVirtualOffset + col;
  }

  Future<void> _showCreateFileDialog(BuildContext context) async {
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (context) => const _CreateFileDialog(),
    );
    if (result == null) return;
    if (!context.mounted) return;
    try {
      final state = context.read<HexEditorState>();
      await state.createRightFile(result.$1, result.$2);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('新建文件失败: \$e', style: const TextStyle(color: Colors.white)),
        ),
      );
    }
  }

  Future<void> _pickAndLoadFile(BuildContext context) async {
    const XTypeGroup binType = XTypeGroup(label: 'Binary File (*.bin, *.dat)', extensions: ['bin', 'dat']);
    const XTypeGroup hexType = XTypeGroup(label: 'Intel Hex File (*.hex)', extensions: ['hex']);
    
    try {
      final XFile? file = await openFile(acceptedTypeGroups: [binType, hexType]);
      if (file != null) {
        if (!context.mounted) return;
        final state = context.read<HexEditorState>();
        
        if (isLeft) {
          await state.loadLeftFile(file.path);
        } else {
          await state.loadRightFile(file.path);
        }
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('打开文件失败: $e', style: const TextStyle(color: Colors.white)),
        ),
      );
    }
  }

  int _parseHexAddress(String value) {
    String trimmed = value.trim();
    if (trimmed.isEmpty) return 0;
    if (trimmed.toLowerCase().startsWith('0x')) {
      trimmed = trimmed.substring(2);
    }
    try {
      return int.parse(trimmed, radix: 16);
    } catch (_) {
      return 0;
    }
  }

  Future<void> _showManualSelectionDialog(BuildContext context, HexEditorState state, HexFileData fileData) async {
    final alignAbs = state.alignByAbsoluteAddress;
    final sideOffset = isLeft ? state.leftOffset : state.rightOffset;
    final selectionStart = isLeft ? state.selectionStartLeft : state.selectionStartRight;

    final int effectiveStart = alignAbs
        ? fileData.baseAddress
        : (fileData.baseAddress + sideOffset);
    final int effectiveEnd = fileData.maxAddress;

    final currentStart = selectionStart ?? effectiveStart;
    // End address always defaults to the maximum valid address for convenience.
    final currentEnd = effectiveEnd;

    final startController = TextEditingController(
      text: '0x${currentStart.toRadixString(16).toUpperCase()}',
    );
    final endController = TextEditingController(
      text: '0x${currentEnd.toRadixString(16).toUpperCase()}',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text(
            '手动选择选区',
            style: TextStyle(color: Colors.white, fontSize: 14),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '有效范围: 0x${effectiveStart.toRadixString(16).toUpperCase()} - 0x${effectiveEnd.toRadixString(16).toUpperCase()}',
                style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'Consolas'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: startController,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Consolas'),
                decoration: InputDecoration(
                  labelText: '起始地址',
                  labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  hintText: '0x0',
                  hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade700),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Colors.cyanAccent),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: endController,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Consolas'),
                decoration: InputDecoration(
                  labelText: '结束地址',
                  labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  hintText: '0x0',
                  hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: Colors.grey.shade700),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Colors.cyanAccent),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认', style: TextStyle(color: Colors.cyanAccent)),
            ),
          ],
        );
      },
    );

    startController.dispose();
    endController.dispose();

    if (confirmed == true) {
      int start = _parseHexAddress(startController.text);
      int end = _parseHexAddress(endController.text);

      // Clamp to valid file range
      if (start < effectiveStart) start = effectiveStart;
      if (start > effectiveEnd) start = effectiveEnd;
      if (end < effectiveStart) end = effectiveStart;
      if (end > effectiveEnd) end = effectiveEnd;

      if (start > end) {
        final tmp = start;
        start = end;
        end = tmp;
      }

      // Use independent selection so left/right can have different sizes for overwrite.
      state.setSelectionWithoutSync(isLeft, start, end);
      state.setSelectedAddress(isLeft, end);
    }
  }

  Future<void> _exportSelection(BuildContext context, HexFileData fileData, int startAddr, int endAddr, String format) async {
    const XTypeGroup binType = XTypeGroup(label: 'Binary File (*.bin)', extensions: ['bin']);
    const XTypeGroup hexType = XTypeGroup(label: 'Intel Hex File (*.hex)', extensions: ['hex']);
    const XTypeGroup headerType = XTypeGroup(label: 'C/C++ Header File (*.h)', extensions: ['h']);

    final int start = startAddr < endAddr ? startAddr : endAddr;
    final int end = startAddr < endAddr ? endAddr : startAddr;
    final int len = end - start + 1;

    final String baseName = fileData.fileName.split('.').first;
    final String extension = switch (format) {
      'hex' => 'hex',
      'header' => 'h',
      _ => 'bin',
    };
    final String suggestedName = '${baseName}_Crop_S0x${start.toRadixString(16).toUpperCase()}_L$len.$extension';

    try {
      final FileSaveLocation? fileLocation = await getSaveLocation(
        acceptedTypeGroups: switch (format) {
          'hex' => [hexType],
          'header' => [headerType],
          _ => [binType],
        },
        suggestedName: suggestedName,
      );

      if (fileLocation != null) {
        if (!context.mounted) return;
        final state = context.read<HexEditorState>();
        
        String path = fileLocation.path;
        final expectedSuffix = '.$extension';
        if (!path.toLowerCase().endsWith(expectedSuffix)) {
          path = '$path$expectedSuffix';
        }
        
        await state.exportSelection(
          isLeft: isLeft,
          startAddr: start,
          endAddr: end,
          outputPath: path,
          asHex: format == 'hex',
          asHeader: format == 'header',
        );

        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功导出 $len 字节至 $path')),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('导出失败: $e', style: const TextStyle(color: Colors.white)),
        ),
      );
    }
  }

  void _showExternalChangePrompt(BuildContext context) {
    final state = context.read<HexEditorState>();
    final fileName = (isLeft ? state.leftFile : state.rightFile)?.fileName ?? (isLeft ? '左侧文件' : '右侧文件');
    final hasUnsavedEdits = isLeft ? state.hasLeftEdits : state.hasRightEdits;
    final messenger = ScaffoldMessenger.of(context);

    final snackBar = SnackBar(
      duration: const Duration(days: 1),
      content: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasUnsavedEdits
                  ? '$fileName 已被外部程序修改，当前有未保存的更改。'
                  : '$fileName 已被外部程序修改。',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              state.reloadFile(isLeft);
              messenger.hideCurrentSnackBar();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              elevation: 0,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            child: const Text('重载', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              state.ignoreExternalChange(isLeft);
              messenger.hideCurrentSnackBar();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              elevation: 0,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );

    final controller = messenger.showSnackBar(snackBar);
    controller.closed.then((reason) {
      if (!mounted) return;
      if (reason != SnackBarClosedReason.hide) {
        // User dismissed the snack bar without choosing an action: treat as ignore.
        state.ignoreExternalChange(isLeft);
      }
    });
  }

  /// Measures the width of a single character for the given [style].
  double _measureCharWidth(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.size.width;
  }

  /// Measures the width of the given [text] for the given [style].
  double _measureTextWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.size.width;
  }

  /// Builds a 12-digit hex address label formatted as `0xXXXX XXXX XXXX`.
  /// The gaps between each 4-nibble group are half a character width.
  Widget _buildAddress12(int address, double charWidth) {
    const style = TextStyle(
      color: Color(0xFF00E5FF),
      fontFamily: 'Consolas',
      fontSize: 14,
    );
    final gap = SizedBox(width: charWidth / 2);
    final hex = (address & 0xFFFFFFFFFFFF).toRadixString(16).toUpperCase().padLeft(12, '0');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('0x', style: style),
        Text(hex.substring(0, 4), style: style),
        gap,
        Text(hex.substring(4, 8), style: style),
        gap,
        Text(hex.substring(8, 12), style: style),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const addressStyle = TextStyle(
      color: Color(0xFF00E5FF),
      fontFamily: 'Consolas',
      fontSize: 14,
    );
    final addressCharWidth = _measureCharWidth(addressStyle);
    final addressContentGap = SizedBox(width: addressCharWidth * 2);
    final addressLabelWidth = _measureTextWidth('0xFFFF FFFF FFFF', addressStyle);
    _addrColWidth = addressLabelWidth;
    _addrGapWidth = addressCharWidth * 2;

    final state = context.read<HexEditorState>();
    final file = context.select<HexEditorState, HexFileData?>((s) => isLeft ? s.leftFile : s.rightFile);
    final isLoading = context.select<HexEditorState, bool>((s) => isLeft ? s.isLeftLoading : s.isRightLoading);
    final loadProgress = context.select<HexEditorState, double>((s) => isLeft ? s.leftLoadProgress : s.rightLoadProgress);

    if (file == null || isLoading) {
      if (isLoading) {
        return Container(
          color: const Color(0xFF161616),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.hourglass_bottom,
                  size: 48,
                  color: Colors.cyanAccent,
                ),
                const SizedBox(height: 16),
                const Text(
                  '正在载入并解析固件文件...',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Text(
                  '进度: ${(loadProgress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.grey, fontSize: 12, fontFamily: 'Consolas'),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: 240,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: ZebraProgressBar(
                      progress: loadProgress,
                      isLeft: isLeft,
                      isLoading: isLoading,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      return Container(
        color: const Color(0xFF161616),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isLeft ? Icons.drive_folder_upload : Icons.folder_open,
                size: 48,
                color: Colors.grey.shade700,
              ),
              const SizedBox(height: 16),
              Text(
                isLeft ? '未加载左侧文件' : '未加载右侧文件',
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () => _pickAndLoadFile(context),
                icon: const Icon(Icons.add, size: 16, color: Colors.cyanAccent),
                label: const Text('加载 BIN / HEX 文件', style: TextStyle(color: Colors.cyanAccent)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2A2A2A),
                  elevation: 0,
                  side: BorderSide(color: Colors.grey.shade800),
                ),
              ),
              if (!isLeft) ...[
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () => _showCreateFileDialog(context),
                  icon: const Icon(Icons.create_new_folder, size: 16, color: Colors.cyanAccent),
                  label: const Text('新建文件', style: TextStyle(color: Colors.cyanAccent)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2A2A2A),
                    elevation: 0,
                    side: BorderSide(color: Colors.grey.shade800),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // Detect external file changes and prompt the user to reload.
    final fileChangedExternally = context.select<HexEditorState, bool>(
      (s) => isLeft ? s.leftFileChangedExternally : s.rightFileChangedExternally,
    );
    if (fileChangedExternally && !_externalChangePromptShown) {
      _externalChangePromptShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showExternalChangePrompt(context);
      });
    } else if (!fileChangedExternally) {
      _externalChangePromptShown = false;
    }

    // Determine row count and details
    final alignAbs = context.select<HexEditorState, bool>((s) => s.alignByAbsoluteAddress);
    final sideOffset = context.select<HexEditorState, int>((s) => isLeft ? s.leftOffset : s.rightOffset);
    final selectionStart = context.select<HexEditorState, int?>((s) => isLeft ? s.selectionStartLeft : s.selectionStartRight);
    final selectionEnd = context.select<HexEditorState, int?>((s) => isLeft ? s.selectionEndLeft : s.selectionEndRight);
    final otherSelectionStart = context.select<HexEditorState, int?>((s) => isLeft ? s.selectionStartRight : s.selectionStartLeft);
    final otherSelectionEnd = context.select<HexEditorState, int?>((s) => isLeft ? s.selectionEndRight : s.selectionEndLeft);
    final bool canOverwrite = selectionStart != null && selectionEnd != null &&
        otherSelectionStart != null && otherSelectionEnd != null;
    final selectedAddress = context.select<HexEditorState, int?>((s) => isLeft ? s.selectedAddressLeft : s.selectedAddressRight);
    final hasEdits = context.select<HexEditorState, bool>((s) => isLeft ? s.hasLeftEdits : s.hasRightEdits);
    final mismatchAbsoluteAddresses = context.select<HexEditorState, Set<int>>((s) => s.mismatchAbsoluteAddresses);
    final mismatchOffsets = context.select<HexEditorState, Set<int>>((s) => s.mismatchOffsets);
    final mismatchRows = context.select<HexEditorState, Set<int>>((s) => s.mismatchRows);
    final sortedMismatchRows = context.select<HexEditorState, List<int>>((s) => s.sortedMismatchRows);

    int alignedStart = 0;
    int offsetInFirstRow = 0;
    int totalBytesToDisplay = 0;
    int rowCount = 0;

    if (alignAbs) {
      alignedStart = file.baseAddress & ~0x0F;
      offsetInFirstRow = file.baseAddress - alignedStart;
      totalBytesToDisplay = file.bytes.length + offsetInFirstRow;
      rowCount = (totalBytesToDisplay / 16).ceil();
    } else {
      totalBytesToDisplay = file.bytes.length > sideOffset ? file.bytes.length - sideOffset : 0;
      rowCount = (totalBytesToDisplay / 16).ceil();
    }

    return Container(
      color: const Color(0xFF161616),
      child: Column(
        children: [
          // Sub toolbar for this file
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: const Color(0xFF222222),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: file.filePath,
                        preferBelow: false,
                        child: Text(
                          file.filePath,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '起始地址: 0x${file.baseAddress.toRadixString(16).toUpperCase().padLeft(8, '0')} | 大小: ${file.bytes.length} 字节',
                        style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: 'Consolas'),
                      ),
                    ],
                  ),
                ),
                if (!_isEditMode) ...[
                  // Manual selection input button (always available)
                  IconButton(
                    icon: const Icon(Icons.edit_note, size: 14, color: Colors.grey),
                    onPressed: () => _showManualSelectionDialog(context, state, file),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: '手动输入选区',
                  ),
                  const SizedBox(width: 4),
                ],
                if (!_isEditMode && selectionStart != null && selectionEnd != null) ...[
                  // Clear selection button (moved to front)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 14, color: Colors.grey),
                    onPressed: () => state.clearSelection(isLeft),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: '清除选择',
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '选区: 0x${(selectionStart < selectionEnd ? selectionStart : selectionEnd).toRadixString(16).toUpperCase()} - 0x${(selectionStart > selectionEnd ? selectionStart : selectionEnd).toRadixString(16).toUpperCase()} (${(selectionEnd - selectionStart).abs() + 1}B)',
                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontFamily: 'Consolas'),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: '选择导出格式并保存选区',
                    offset: const Offset(0, 24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.upload, size: 16, color: Colors.cyanAccent),
                          Icon(Icons.arrow_drop_down, size: 14, color: Colors.cyanAccent),
                        ],
                      ),
                    ),
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        value: 'bin',
                        height: 32,
                        child: Row(
                          children: [
                            Icon(Icons.file_present, size: 16, color: Colors.greenAccent),
                            SizedBox(width: 8),
                            Text('导出为 BIN 文件 (*.bin)', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'hex',
                        height: 32,
                        child: Row(
                          children: [
                            Icon(Icons.code, size: 16, color: Colors.amberAccent),
                            SizedBox(width: 8),
                            Text('导出为 Intel HEX 文件 (*.hex)', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'header',
                        height: 32,
                        child: Row(
                          children: [
                            Icon(Icons.description, size: 16, color: Colors.lightBlueAccent),
                            SizedBox(width: 8),
                            Text('导出为 C/C++ 头文件 (*.h)', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (format) {
                      _exportSelection(context, file, selectionStart, selectionEnd, format);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                if (!_isEditMode && canOverwrite) ...[
                  // Overwrite opposite side's selection with this side's selection
                  Tooltip(
                    message: isLeft ? '用左侧选区覆盖右侧选区' : '用右侧选区覆盖左侧选区',
                    child: IconButton(
                      icon: Icon(
                        isLeft ? Icons.arrow_forward : Icons.arrow_back,
                        size: 16,
                        color: Colors.redAccent,
                      ),
                      onPressed: () {
                        _playOverwriteAnimation(context, isLeft);
                        state.overwriteSelection(isLeft);
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // --- Edit / Save / Discard buttons (always visible when file loaded) ---
                const SizedBox(width: 4),
                Tooltip(
                  message: _isEditMode ? '退出编辑模式 (Esc)' : '进入编辑模式：直接修改 HEX 字节',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _isHoveringEdit = true),
                    onExit: (_) => setState(() => _isHoveringEdit = false),
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _isEditMode = !_isEditMode;
                          if (_isEditMode) {
                            _editingAddr = selectedAddress;
                            // If nothing was selected, default to the first visible byte.
                            _editingAddr ??= alignAbs
                                ? file.baseAddress
                                : (file.baseAddress + sideOffset);
                            _pendingNibble = null;
                            _editFocusNode.requestFocus();
                          } else {
                            _editingAddr = null;
                            _pendingNibble = null;
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Icon(
                          _isEditMode ? Icons.edit_off : Icons.edit,
                          size: 16,
                          color: _isEditMode
                              ? Colors.cyanAccent
                              : (_isHoveringEdit ? Colors.orange : Colors.grey),
                        ),
                      ),
                    ),
                  ),
                ),
                if (hasEdits) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '丢弃全部未保存修改',
                    child: IconButton(
                      icon: const Icon(Icons.undo, size: 16, color: Colors.green),
                      onPressed: () async {
                        await state.discardEdits(isLeft);
                        setState(() { _pendingNibble = null; });
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: '丢弃修改',
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '保存修改到原文件 (${file.fileName})',
                    child: GestureDetector(
                      onTap: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('覆盖确认'),
                            content: Text('确定要保存并覆盖原文件吗？\n${file.filePath}'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(dialogContext).pop(false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(dialogContext).pop(true),
                                child: const Text('覆盖', style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        if (!mounted) return;

                        try {
                          await state.saveFile(isLeft);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('文件已保存: ${file.filePath}')),
                          );
                          setState(() { _isEditMode = false; _editingAddr = null; _pendingNibble = null; });
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(backgroundColor: Colors.redAccent, content: Text('保存失败: $e', style: const TextStyle(color: Colors.white))),
                          );
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: const Icon(Icons.save, size: 18, color: Colors.red),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                  onPressed: () {
                    if (isLeft) {
                      state.closeLeftFile();
                    } else {
                      state.closeRightFile();
                    }
                    setState(() { _isEditMode = false; _editingAddr = null; _pendingNibble = null; });
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: '关闭文件',
                ),

              ],
            ),
          ),
          // Table header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: const Color(0xFF1E1E1E),
            child: Row(
              children: [
                SizedBox(
                  width: addressLabelWidth,
                  child: const Text('Address', style: TextStyle(color: Colors.grey, fontSize: 14, fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
                ),
                addressContentGap,
                SizedBox(
                  width: 452,
                  child: Row(
                    children: List.generate(16, (i) {
                      final String hexLabel = i.toRadixString(16).padLeft(2, '0').toUpperCase();
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 24,
                            alignment: Alignment.center,
                            child: Text(
                              hexLabel,
                              style: const TextStyle(
                                color: Color(0xFF9E9E9E),
                                fontSize: 14,
                                fontFamily: 'Consolas',
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (i < 15) SizedBox(width: i == 7 ? 12 : 4),
                        ],
                      );
                    }),
                  ),
                ),
                const SizedBox(width: 16),
                const Text('ASCII', style: TextStyle(color: Colors.grey, fontSize: 14, fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          // Scrollable Hex View List & Minimap
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: KeyboardListener(
                    focusNode: _editFocusNode,
                    onKeyEvent: (event) => _handleEditKeyEvent(event, state),
                    child: Scrollbar(
                      controller: scrollController,
                      thumbVisibility: true,
                      thickness: 9,
                      radius: const Radius.circular(3),
                      child: GestureDetector(
                        key: _listKey,
                        // Allow pointer events to pass through to the scrollbar thumb
                        // while still receiving pan/tap gestures on the hex content.
                        behavior: HitTestBehavior.translucent,
                        onTapDown: (details) {
                          final addr = _addrFromLocalPosition(
                            details.localPosition,
                            file,
                            rowCount,
                            alignAbs,
                            alignedStart,
                            sideOffset,
                          );
                          if (addr == null) return;
                          if (_isEditMode) {
                            setState(() {
                              _editingAddr = addr;
                              _pendingNibble = null;
                            });
                            _editFocusNode.requestFocus();
                          } else {
                            _handleCellTap(state, addr);
                          }
                        },

                        onPanStart: (details) {
                          // Store build-time params for use inside the async timer
                          _dragFile = file;
                          _dragRowCount = rowCount;
                          _dragAlignAbs = alignAbs;
                          _dragAlignedStart = alignedStart;
                          _dragSideOffset = sideOffset;
                          _dragState = state;

                          final addr = _addrFromLocalPosition(
                            details.localPosition,
                            file,
                            rowCount,
                            alignAbs,
                            alignedStart,
                            sideOffset,
                          );
                          if (addr != null) {
                            _dragStartAddr = addr;
                            state.setSelectedAddress(isLeft, addr);
                            state.setSelection(isLeft, addr, addr);
                          }
                        },
                        onPanUpdate: (details) {
                          if (_dragStartAddr == null) return;
                          _lastDragLocalPos = details.localPosition;
                          final addr = _addrFromLocalPosition(
                            details.localPosition,
                            file,
                            rowCount,
                            alignAbs,
                            alignedStart,
                            sideOffset,
                          );
                          if (addr != null) {
                            state.setSelection(isLeft, _dragStartAddr!, addr);
                          }
                          _tryAutoScroll(details.localPosition);
                        },
                        onPanEnd: (_) {
                          _stopAutoScroll();
                          _dragStartAddr = null;
                          _lastDragLocalPos = null;
                        },
                        onPanCancel: () {
                          _stopAutoScroll();
                          _dragStartAddr = null;
                          _lastDragLocalPos = null;
                        },
                        child: ListView.builder(
                          controller: scrollController,
                          itemCount: rowCount,
                          itemExtent: 26, // Fixed height per row for high performance virtual list scrolling
                          addAutomaticKeepAlives: false, // Rows are lightweight; avoid keep-alive overhead
                          padding: const EdgeInsets.only(left: 16, right: 0, top: 4, bottom: 4),
                itemBuilder: (context, index) {
                  final int rowVirtualOffset = index * 16;
                  final int rowDisplayAddress = alignAbs
                      ? (alignedStart + rowVirtualOffset)
                      : (file.baseAddress + sideOffset + rowVirtualOffset);
                  
                  final List<Widget> hexCells = [];
                  final List<InlineSpan> asciiSpans = [];

                  // Cache frequently accessed state values once per row.
                  final sideEdits = isLeft ? state.leftEdits : state.rightEdits;
                  final otherFile = isLeft ? state.rightFile : state.leftFile;
                  final otherSideOffset = isLeft ? state.rightOffset : state.leftOffset;

                  // Precompute theme-derived colors and borders once per row
                  // instead of allocating them inside the 16-cell loop.
                  final Color primaryColor = Theme.of(context).colorScheme.primary;
                  final Color selectedBg = primaryColor.withValues(alpha: 0.35);
                  final Border clickedBorder = Border.all(color: Colors.cyanAccent, width: 1.5);
                  final Color editingBg = Colors.orange.withValues(alpha: 0.3);
                  final Border editingBorder = Border.all(color: Colors.orangeAccent, width: 1.5);
                  final Border editedBorder = Border.all(color: const Color(0xFFFFD54F), width: 1);
                  final Color mismatchBg = Colors.red.withValues(alpha: 0.15);
                  final Border mismatchBorder = Border.all(color: Colors.redAccent.withValues(alpha: 0.5), width: 1);
                  final Color missingByteBg = Colors.red.withValues(alpha: 0.08);
                  final Border missingByteBorder = Border.all(color: Colors.red.withValues(alpha: 0.2), width: 1);
                  final Color zeroByteColor = Colors.grey.shade600;
                  final Color ffByteColor = Colors.amber.shade700;
                  final Color asciiByteColor = Colors.green.shade400;
                  final Color mismatchTextColor = Colors.redAccent.shade100;
                  final Color emptyCellTextColor = Colors.grey.shade800;

                  for (int i = 0; i < 16; i++) {
                    final int cellVirtualOffset = rowVirtualOffset + i;
                    final int cellFileOffset = sideOffset + cellVirtualOffset;
                    final int cellAddr = alignAbs
                        ? (rowDisplayAddress + i)
                        : (file.baseAddress + cellFileOffset);

                    final bool isDataPresent = alignAbs
                        ? (cellAddr >= file.baseAddress && cellAddr <= file.maxAddress && file.hasByteAt(cellAddr))
                        : (cellFileOffset >= 0 && cellFileOffset < file.bytes.length);

                    if (isDataPresent) {
                      // Use in-memory edit value if available, else fall back to file byte
                      final int byteVal = sideEdits[cellAddr] ?? file.getByteAt(cellAddr);

                      // Check mismatch (byte-offset mode compares by virtual aligned offset)
                      bool isMismatch = false;
                      if (alignAbs) {
                        isMismatch = mismatchAbsoluteAddresses.contains(cellAddr);
                      } else {
                        isMismatch = mismatchOffsets.contains(cellVirtualOffset);
                      }

                      // Check selection (addresses are always stored as real absolute addresses)
                      // Selection highlight is hidden while in edit mode.
                      bool isSelected = false;
                      if (!_isEditMode && selectionStart != null && selectionEnd != null) {
                        final int minSel = selectionStart < selectionEnd ? selectionStart : selectionEnd;
                        final int maxSel = selectionStart > selectionEnd ? selectionStart : selectionEnd;
                        isSelected = cellAddr >= minSel && cellAddr <= maxSel;
                      }

                      // Clicked border is hidden in edit mode so it does not clash with the edit highlight.
                      final isClicked = !_isEditMode && selectedAddress == cellAddr;

                      // Edit mode flags
                      final bool isEdited = sideEdits.containsKey(cellAddr);
                      final bool isEditing = _isEditMode && _editingAddr == cellAddr;

                      // Semantic color for bytes
                      Color byteColor = Colors.white70;
                      if (byteVal == 0x00) {
                        byteColor = zeroByteColor;
                      } else if (byteVal == 0xFF) {
                        byteColor = ffByteColor;
                      } else if (byteVal >= 32 && byteVal <= 126) {
                        byteColor = asciiByteColor;
                      }
                      // Edited byte color override
                      if (isEdited) byteColor = const Color(0xFFFFD54F); // amber-300

                      // Mismatch color override
                      Color? bgCol;
                      Border? cellBorder;
                      if (isMismatch) {
                        bgCol = mismatchBg;
                        cellBorder = mismatchBorder;
                      }
                      if (isSelected) {
                        bgCol = selectedBg;
                      }
                      if (isClicked) {
                        cellBorder = clickedBorder;
                      }
                      if (isEdited) {
                        bgCol = (bgCol ?? Colors.transparent).withValues(alpha: 0.0) == Colors.transparent
                            ? const Color(0xFF1A1500)
                            : bgCol;
                        cellBorder = editedBorder;
                      }
                      if (isEditing) {
                        bgCol = editingBg;
                        cellBorder = editingBorder;
                      }

                      // Pending first-nibble display
                      final String hexText = (isEditing && _pendingNibble != null)
                          ? '${_pendingNibble!.toRadixString(16).toUpperCase()}_'
                          : byteVal.toRadixString(16).padLeft(2, '0').toUpperCase();
                      final String asciiChar = (byteVal >= 32 && byteVal <= 126) ? String.fromCharCode(byteVal) : '.';

                      // Hex Cell
                      hexCells.add(
                        Container(
                          width: 24,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: bgCol,
                            border: cellBorder,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            hexText,
                            style: TextStyle(
                              color: isMismatch ? mismatchTextColor : byteColor,
                              fontSize: isEditing && _pendingNibble != null ? 11 : 14,
                              fontFamily: 'Consolas',
                              fontWeight: (isMismatch || isEdited || isEditing) ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      );


                      // ASCII Span
                      asciiSpans.add(
                        TextSpan(
                          text: asciiChar,
                          style: TextStyle(
                            color: isMismatch 
                                ? mismatchTextColor 
                                : isSelected 
                                    ? Colors.cyanAccent 
                                    : byteColor,
                            backgroundColor: bgCol,
                            fontFamily: 'Consolas',
                            fontSize: 14,
                            fontWeight: (isMismatch || isSelected) ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      );

                    } else {
                      // Empty cell (sparse gap or out of bounds)
                      // Check if out-of-bounds mismatch (i.e. the other file has data here, so it is a difference)
                      bool otherHasData = false;
                      if (otherFile != null) {
                        if (alignAbs) {
                          otherHasData = cellAddr >= otherFile.baseAddress && cellAddr <= otherFile.maxAddress && otherFile.hasByteAt(cellAddr);
                        } else {
                          final int otherEffectiveLen = otherFile.bytes.length > otherSideOffset ? otherFile.bytes.length - otherSideOffset : 0;
                          otherHasData = cellVirtualOffset >= 0 && cellVirtualOffset < otherEffectiveLen;
                        }
                      }

                      Color? bgCol;
                      Border? cellBorder;
                      if (otherHasData) {
                        bgCol = missingByteBg; // Missing byte highlight
                        cellBorder = missingByteBorder;
                      }

                      hexCells.add(
                        Container(
                          width: 24,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: bgCol,
                            border: cellBorder,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            '--',
                            style: TextStyle(
                              color: emptyCellTextColor,
                              fontSize: 14,
                              fontFamily: 'Consolas',
                            ),
                          ),
                        ),
                      );

                      asciiSpans.add(
                        TextSpan(
                          text: ' ',
                          style: TextStyle(
                            backgroundColor: bgCol,
                            fontFamily: 'Consolas',
                            fontSize: 14,
                          ),
                        ),
                      );
                    }

                    // Add spaces between cells for grouping (extra space between 7 and 8)
                    if (i < 15) {
                      hexCells.add(SizedBox(width: i == 7 ? 12 : 4));
                    }
                  }

                  return Row(
                    children: [
                      // Address column
                      SizedBox(
                        width: addressLabelWidth,
                        child: _buildAddress12(rowDisplayAddress, addressCharWidth),
                      ),
                      addressContentGap,
                      // Hex cells (fixed width for tight alignment with ASCII)
                      SizedBox(
                        width: 452,
                        child: Row(children: hexCells),
                      ),
                      const SizedBox(width: 16),
                      // ASCII cells
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: asciiSpans),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  );
                },
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 21,
                  child: Column(
                    children: [
                      Tooltip(
                        message: '上一个差异',
                        child: InkWell(
                          onTap: () => _navigateToMismatch(context, state, false),
                          child: const SizedBox(
                            width: 21,
                            height: 22,
                            child: Icon(Icons.arrow_drop_up, color: Colors.grey, size: 20),
                          ),
                        ),
                      ),
                      Tooltip(
                        message: '下一个差异',
                        child: InkWell(
                          onTap: () => _navigateToMismatch(context, state, true),
                          child: const SizedBox(
                            width: 21,
                            height: 22,
                            child: Icon(Icons.arrow_drop_down, color: Colors.grey, size: 20),
                          ),
                        ),
                      ),
                      Expanded(
                        child: HexMinimap(
                          scrollController: scrollController,
                          file: file,
                          mismatchRows: mismatchRows,
                          sortedMismatchRows: sortedMismatchRows,
                          alignAbs: alignAbs,
                          rowCount: rowCount,
                        ),
                      ),
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

  void _navigateToMismatch(BuildContext context, HexEditorState state, bool goNext) {
    if (state.sortedMismatchRows.isEmpty) return;

    final double offset = scrollController.offset;
    final int currentVisibleRow = (offset / 26.0).floor();

    int targetRow = -1;

    if (goNext) {
      targetRow = state.sortedMismatchRows.firstWhere(
        (r) => r > currentVisibleRow,
        orElse: () => -1,
      );
      if (targetRow == -1) {
        targetRow = state.sortedMismatchRows.first;
      }
    } else {
      targetRow = state.sortedMismatchRows.lastWhere(
        (r) => r < currentVisibleRow,
        orElse: () => -1,
      );
      if (targetRow == -1) {
        targetRow = state.sortedMismatchRows.last;
      }
    }

    if (targetRow != -1) {
      final double targetOffset = (targetRow * 26.0).clamp(
        0.0,
        scrollController.position.maxScrollExtent,
      );
      scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  void _handleCellTap(HexEditorState state, int target) {
    final isShiftPressed = HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.shiftLeft) ||
                           HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.shiftRight);

    final start = isLeft ? state.selectionStartLeft : state.selectionStartRight;

    if (isShiftPressed && start != null) {
      state.setSelection(isLeft, start, target);
    } else {
      state.setSelectedAddress(isLeft, target);
      state.setSelection(isLeft, target, target);
    }
  }

  void _playOverwriteAnimation(BuildContext context, bool fromLeft) {
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (context) => _OverwriteAnimation(fromLeft: fromLeft),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 700), () {
      entry.remove();
    });
  }
}

class ZebraProgressBar extends StatefulWidget {
  final double progress;
  final bool isLeft;
  final bool isLoading;

  const ZebraProgressBar({
    super.key,
    required this.progress,
    required this.isLeft,
    required this.isLoading,
  });

  @override
  State<ZebraProgressBar> createState() => _ZebraProgressBarState();
}

class _ZebraProgressBarState extends State<ZebraProgressBar> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    if (widget.isLoading) {
      _animationController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant ZebraProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading && !_animationController.isAnimating) {
      _animationController.repeat();
    } else if (!widget.isLoading && _animationController.isAnimating) {
      _animationController.stop();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading && widget.progress <= 0) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        final double phase = _animationController.value * 14.0;
        return SizedBox(
          height: 8,
          width: double.infinity,
          child: CustomPaint(
            painter: _ZebraProgressBarPainter(
              progress: widget.progress,
              isLeft: widget.isLeft,
              phase: phase,
            ),
          ),
        );
      },
    );
  }
}

class _ZebraProgressBarPainter extends CustomPainter {
  final double progress;
  final bool isLeft;
  final double phase;

  _ZebraProgressBarPainter({
    required this.progress,
    required this.isLeft,
    required this.phase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double barWidth = size.width * progress;
    final Rect bgRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final Rect progressRect = Rect.fromLTWH(0, 0, barWidth, size.height);

    final bgPaint = Paint()
      ..color = const Color(0xFF1E1E1E)
      ..style = PaintingStyle.fill;
    canvas.drawRect(bgRect, bgPaint);

    if (barWidth <= 0) return;

    Color baseColor;
    Color stripeColor;
    if (isLeft) {
      baseColor = const Color(0xFFB57C00);
      stripeColor = const Color(0xFFFFD54F);
    } else {
      baseColor = const Color(0xFF0D47A1);
      stripeColor = const Color(0xFF2979FF);
    }

    final basePaint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.fill;
    canvas.drawRect(progressRect, basePaint);

    canvas.save();
    canvas.clipRect(progressRect);

    final stripePaint = Paint()
      ..color = stripeColor
      ..strokeWidth = 3.0;

    const double step = 14.0;
    for (double x = -size.height - phase; x < barWidth + size.height; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        stripePaint,
      );
    }
    canvas.restore();

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, 0), Offset(size.width, 0), borderPaint);
  }

  @override
  bool shouldRepaint(covariant _ZebraProgressBarPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.isLeft != isLeft ||
        oldDelegate.phase != phase;
  }
}

/// A short flying-arrow overlay shown when one side's selection overwrites the other.
class _OverwriteAnimation extends StatefulWidget {
  final bool fromLeft;

  const _OverwriteAnimation({required this.fromLeft});

  @override
  State<_OverwriteAnimation> createState() => _OverwriteAnimationState();
}

class _OverwriteAnimationState extends State<_OverwriteAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _positionAnimation;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _positionAnimation = Tween<Offset>(
      begin: widget.fromLeft ? const Offset(-0.35, 0) : const Offset(0.35, 0),
      end: widget.fromLeft ? const Offset(0.35, 0) : const Offset(-0.35, 0),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _opacityAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.0), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 25),
    ]).animate(_controller);

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final size = MediaQuery.of(context).size;
        return IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: _opacityAnimation.value,
              child: Transform.translate(
                offset: Offset(
                  size.width / 2 + _positionAnimation.value.dx * size.width,
                  size.height / 2,
                ),
                child: Icon(
                  widget.fromLeft ? Icons.arrow_forward : Icons.arrow_back,
                  color: Colors.redAccent,
                  size: 56,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A simple formatter that restricts input to hex digits (0-9, A-F)
/// and optionally limits the number of digits.
class _HexDigitsFormatter extends TextInputFormatter {
  final int maxDigits;

  const _HexDigitsFormatter({this.maxDigits = 8});

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var text = newValue.text.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    if (text.length > maxDigits) {
      text = text.substring(0, maxDigits);
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Dialog for creating a new in-memory file for the right hex panel.
class _CreateFileDialog extends StatefulWidget {
  const _CreateFileDialog();

  @override
  State<_CreateFileDialog> createState() => _CreateFileDialogState();
}

class _CreateFileDialogState extends State<_CreateFileDialog> {
  final _lengthController = TextEditingController(text: '100');
  final _fillController = TextEditingController(text: '00');

  @override
  void dispose() {
    _lengthController.dispose();
    _fillController.dispose();
    super.dispose();
  }

  void _confirm() {
    final lengthText = _lengthController.text;
    final fillText = _fillController.text;
    if (lengthText.isEmpty || fillText.isEmpty) return;

    final length = int.tryParse(lengthText, radix: 16);
    final fill = int.tryParse(fillText, radix: 16);
    if (length == null || length <= 0) {
      _showError('文件长度必须是有效的正十六进制数');
      return;
    }
    if (fill == null || fill < 0 || fill > 0xFF) {
      _showError('填充值必须是 0x00 ~ 0xFF 之间的十六进制数');
      return;
    }
    Navigator.pop(context, (length, fill));
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.redAccent,
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    String hint,
    int maxDigits,
  ) {
    return TextField(
      controller: controller,
      inputFormatters: [_HexDigitsFormatter(maxDigits: maxDigits)],
      style: const TextStyle(color: Colors.white, fontFamily: 'Consolas', fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.grey),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade700),
        filled: true,
        fillColor: const Color(0xFF1A1A1A),
        border: const OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.grey.shade700),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.cyanAccent),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text('新建右侧文件', style: TextStyle(color: Colors.white, fontSize: 14)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTextField(_lengthController, '文件长度（字节，十六进制）', '例如：100', 8),
            const SizedBox(height: 12),
            _buildTextField(_fillController, '填充值（单字节，十六进制）', '例如：FF', 2),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: _confirm,
          child: const Text('确认', style: TextStyle(color: Colors.cyanAccent)),
        ),
      ],
    );
  }
}
