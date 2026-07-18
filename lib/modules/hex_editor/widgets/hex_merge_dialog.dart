import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import '../../../providers/hex_editor_state.dart';
import '../models/hex_file_data.dart';
import 'hex_calculator.dart';
import 'hex_view_panel.dart';

String _formatHex12(int value) {
  final hex = (value & 0xFFFFFFFFFFFF).toRadixString(16).toUpperCase().padLeft(12, '0');
  return '0x${hex.substring(0, 4)},${hex.substring(4, 8)},${hex.substring(8, 12)}';
}

/// Formats an address as 0xXXXX XXXX XXXX with a half-character space between groups.
String _formatHexAddressHalfSpace(int value) {
  final hex = (value & 0xFFFFFFFFFFFF).toRadixString(16).toUpperCase().padLeft(12, '0');
  const halfSpace = '\u200A';
  return '0x${hex.substring(0, 4)}$halfSpace${hex.substring(4, 8)}$halfSpace${hex.substring(8, 12)}';
}

/// Simulates overtype (insert/overwrite) mode for a fixed-length hex field:
/// - Typing replaces the character under the cursor.
/// - The cursor advances one position after each keystroke.
/// - Once the cursor reaches the last digit, it stays there; further input
///   only changes that lowest digit.
class _OvertypeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final oldText = oldValue.text;
    final newText = newValue.text;
    final oldLen = oldText.length;
    final newLen = newText.length;
    final cursor = newValue.selection.baseOffset;

    // Only handle single-character insertions.
    if (newLen != oldLen + 1 || cursor <= 0 || cursor > newLen) {
      return newValue;
    }

    // The inserted character is immediately before the new cursor position.
    final inserted = newText[cursor - 1];
    final int replaceStart;
    final int newCursor;
    if (cursor - 1 >= oldLen - 1) {
      // At or past the last character: keep replacing the lowest digit.
      replaceStart = oldLen - 1;
      newCursor = replaceStart;
    } else {
      // Replace the character under the cursor and advance.
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

/// Automatically formats a target-address input as 0xXXXX,XXXX,XXXX while typing.
class _HexAddressInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String raw = newValue.text.toLowerCase();
    var rawCursor = newValue.selection.baseOffset;

    // Strip the 0x prefix and adjust the cursor accordingly.
    if (raw.startsWith('0x')) {
      if (rawCursor >= 2) {
        rawCursor -= 2;
      } else {
        rawCursor = 0;
      }
      raw = raw.substring(2);
    }

    // Count hex digits before the cursor, ignoring comma separators.
    var hexCursor = 0;
    for (var i = 0; i < rawCursor && i < raw.length; i++) {
      if (raw[i] != ',') hexCursor++;
    }

    raw = raw.replaceAll(',', '');
    if (raw.isEmpty) {
      const text = '0x0000,0000,0000';
      return const TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    }

    final value = int.tryParse(raw, radix: 16);
    if (value == null) return oldValue;
    final clamped = value & 0xFFFFFFFFFFFF;
    final formatted = _formatHex12(clamped);

    // Map the hex-digit cursor position back to the formatted string.
    // When the cursor is at/past the last digit, keep it over the last digit.
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

class HexMergeDialog extends StatefulWidget {
  const HexMergeDialog({super.key});

  @override
  State<HexMergeDialog> createState() => _HexMergeDialogState();
}

class _HexMergeDialogState extends State<HexMergeDialog> {
  final List<MergeItem> _items = [];
  final TextEditingController _fillByteController = TextEditingController(text: '0xFF');
  bool _asHex = false;

  final Map<int, TextEditingController> _addrControllers = {};

  // Index of the row whose calculator panel is currently open, if any.
  int? _calcIndex;

  @override
  void dispose() {
    _fillByteController.dispose();
    for (var c in _addrControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  int? _parseNumber(String text) {
    text = text.trim();
    if (text.isEmpty) return null;
    if (text.toLowerCase().startsWith('0x')) {
      return int.tryParse(text.substring(2), radix: 16);
    }
    return int.tryParse(text);
  }

  /// Parses a hex address, tolerating optional commas.
  int? _parseHexAddress(String text) {
    text = text.trim();
    if (text.isEmpty) return null;
    if (text.toLowerCase().startsWith('0x')) {
      text = text.substring(2);
    }
    text = text.replaceAll(',', '');
    if (text.isEmpty) return null;
    return int.tryParse(text, radix: 16);
  }

  Future<void> _addFile() async {
    const XTypeGroup binType = XTypeGroup(label: 'Binary File (*.bin, *.dat)', extensions: ['bin', 'dat']);
    const XTypeGroup hexType = XTypeGroup(label: 'Intel Hex File (*.hex)', extensions: ['hex']);

    try {
      final XFile? file = await openFile(acceptedTypeGroups: [binType, hexType]);
      if (file != null) {
        final path = file.path;
        final name = p.basename(path);
        final isHex = path.toLowerCase().endsWith('.hex');
        
        final bytes = await File(path).readAsBytes();
        int baseAddr = 0;
        int size = bytes.length;

        if (isHex) {
          try {
            final parsed = HexFileData.fromHexBytes(bytes, path);
            baseAddr = parsed.baseAddress;
            size = parsed.bytes.length;
          } catch (_) {}
        }

        // If there are existing items, place the new file immediately after the last one.
        if (_items.isNotEmpty) {
          final lastIndex = _items.length - 1;
          final lastAddr = _parseHexAddress(_addrControllers[lastIndex]?.text ?? '') ?? _items[lastIndex].startAddress;
          baseAddr = lastAddr + _items[lastIndex].size;
        }

        setState(() {
          final index = _items.length;
          _items.add(MergeItem(
            filePath: path,
            fileName: name,
            startAddress: baseAddr,
            size: size,
            isHex: isHex,
          ));
          _addrControllers[index] = TextEditingController(
            text: _formatHex12(baseAddr),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text('添加文件失败: $e')),
      );
    }
  }

  Future<void> _loadList() async {
    const XTypeGroup jsonType = XTypeGroup(label: 'Merge List (*.json)', extensions: ['json']);

    try {
      final XFile? file = await openFile(acceptedTypeGroups: [jsonType]);
      if (!mounted || file == null) return;

      final content = await File(file.path).readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      final version = data['version'] as int?;
      if (version != 1) {
        throw Exception('不支持的清单版本: $version');
      }

      final fillByte = (data['fillByte'] as String?) ?? '0xFF';
      final asHex = data['asHex'] as bool? ?? false;
      final rawItems = (data['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      if (rawItems.isEmpty) {
        throw Exception('清单中没有文件');
      }

      final List<MergeItem> newItems = [];
      final Map<int, TextEditingController> newControllers = {};
      final List<String> missingFiles = [];

      for (int i = 0; i < rawItems.length; i++) {
        final raw = rawItems[i];
        final filePath = raw['filePath'] as String?;
        if (filePath == null || filePath.isEmpty) {
          throw Exception('第 ${i + 1} 项缺少文件路径');
        }

        if (!File(filePath).existsSync()) {
          missingFiles.add(filePath);
          continue;
        }

        final bytes = await File(filePath).readAsBytes();
        final isHex = filePath.toLowerCase().endsWith('.hex');
        int size = bytes.length;
        if (isHex) {
          try {
            final parsed = HexFileData.fromHexBytes(bytes, filePath);
            size = parsed.bytes.length;
          } catch (_) {
            size = (raw['size'] as int?) ?? bytes.length;
          }
        }

        final startAddress = _parseHexAddress(raw['startAddress'] as String? ?? '') ?? 0;
        final item = MergeItem(
          filePath: filePath,
          fileName: p.basename(filePath),
          startAddress: startAddress,
          size: size,
          isHex: isHex,
        );

        newItems.add(item);
        newControllers[newItems.length - 1] = TextEditingController(text: _formatHex12(startAddress));
      }

      if (newItems.isEmpty) {
        throw Exception('清单中的所有文件都不存在');
      }

      setState(() {
        _items.clear();
        for (var c in _addrControllers.values) {
          c.dispose();
        }
        _addrControllers.clear();
        _items.addAll(newItems);
        _addrControllers.addAll(newControllers);
        _fillByteController.text = fillByte;
        _asHex = asHex;
      });

      if (missingFiles.isNotEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.orangeAccent,
            content: Text('以下文件不存在，已跳过：${missingFiles.map(p.basename).join(', ')}'),
          ),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(backgroundColor: Colors.green, content: Text('清单加载成功')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text('加载清单失败: $e')),
      );
    }
  }

  Future<void> _saveList() async {
    if (_items.isEmpty) return;

    const XTypeGroup jsonType = XTypeGroup(label: 'Merge List (*.json)', extensions: ['json']);

    try {
      final FileSaveLocation? location = await getSaveLocation(
        acceptedTypeGroups: [jsonType],
        suggestedName: 'merge_list.json',
      );
      if (!mounted || location == null) return;

      final items = <Map<String, dynamic>>[];
      for (int i = 0; i < _items.length; i++) {
        items.add({
          'filePath': _items[i].filePath,
          'startAddress': _addrControllers[i]?.text ?? _formatHex12(_items[i].startAddress),
          'size': _items[i].size,
          'isHex': _items[i].isHex,
        });
      }

      final data = {
        'version': 1,
        'fillByte': _fillByteController.text,
        'asHex': _asHex,
        'items': items,
      };

      await File(location.path).writeAsString(jsonEncode(data));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.green, content: Text('清单已保存至 ${location.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text('保存清单失败: $e')),
      );
    }
  }

  /// Minimum legal target address for item [index]: the end of the previous
  /// file in the chain (0 for the first file).
  int _minAddressFor(int index) {
    if (index <= 0) return 0;
    final prevAddr = _parseHexAddress(_addrControllers[index - 1]?.text ?? '') ??
        _items[index - 1].startAddress;
    return prevAddr + _items[index - 1].size;
  }

  /// Recalculates the target addresses of items after [index] only where
  /// needed: if a file's predecessor now ends at or before the file's own
  /// target address (prev addr + prev size <= own addr), the file keeps its
  /// address and the cascade stops; otherwise the file is moved to the end
  /// of its predecessor and the check continues down the chain.
  void _cascadeFrom(int index) {
    for (int i = index + 1; i < _items.length; i++) {
      final prevAddr = _parseHexAddress(_addrControllers[i - 1]?.text ?? '') ??
          _items[i - 1].startAddress;
      final prevEnd = prevAddr + _items[i - 1].size;
      final curAddr = _parseHexAddress(_addrControllers[i]?.text ?? '') ??
          _items[i].startAddress;
      if (prevEnd <= curAddr) break;
      _addrControllers[i]?.text = _formatHex12(prevEnd & 0xFFFFFFFFFFFF);
    }
  }

  /// Resets only this row's target address to the minimum legal value:
  /// 0x0 for the first file, otherwise prev file's addr + prev file's size.
  /// Subsequent rows are intentionally left untouched.
  void _resetAddress(int index) {
    final newAddr = index == 0 ? 0 : _minAddressFor(index);
    _addrControllers[index]!.text = _formatHex12(newAddr);
    setState(() {});
  }

  void _removeFile(int index) {
    setState(() {
      _items.removeAt(index);
      final c = _addrControllers.remove(index);
      c?.dispose();
      // Re-map controllers
      final temp = <int, TextEditingController>{};
      for (int i = 0; i < _items.length; i++) {
        temp[i] = _addrControllers[i + 1] ?? _addrControllers[i] ?? TextEditingController();
      }
      _addrControllers.clear();
      _addrControllers.addAll(temp);
    });
  }

  void _moveFile(int index, bool up) {
    if (up && index == 0) return;
    if (!up && index == _items.length - 1) return;

    final targetIndex = up ? index - 1 : index + 1;
    setState(() {
      final item = _items.removeAt(index);
      _items.insert(targetIndex, item);

      // Swap controllers
      final tempVal = _addrControllers[index]!.text;
      _addrControllers[index]!.text = _addrControllers[targetIndex]!.text;
      _addrControllers[targetIndex]!.text = tempVal;
    });
  }

  Future<void> _executeMerge() async {
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: Colors.orangeAccent, content: Text('请至少添加一个文件')),
      );
      return;
    }

    final fillVal = _parseNumber(_fillByteController.text);
    if (fillVal == null || fillVal < 0 || fillVal > 255) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: Colors.redAccent, content: Text('无效的填充字节（必须在 0x00 - 0xFF 之间）')),
      );
      return;
    }

    // Compile list of MergeItems with updated addresses, clamping each
    // address to the minimum legal value (end of the previous file).
    final List<MergeItem> updatedItems = [];
    for (int i = 0; i < _items.length; i++) {
      var addr = _parseHexAddress(_addrControllers[i]!.text);
      if (addr == null || addr < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.redAccent, content: Text('文件 "${_items[i].fileName}" 的目标地址无效')),
        );
        return;
      }
      final minAddr = _minAddressFor(i);
      if (addr < minAddr) addr = minAddr;
      updatedItems.add(_items[i].copyWith(startAddress: addr));
    }

    const XTypeGroup binType = XTypeGroup(label: 'Binary File (*.bin)', extensions: ['bin']);
    const XTypeGroup hexType = XTypeGroup(label: 'Intel Hex File (*.hex)', extensions: ['hex']);

    final state = context.read<HexEditorState>();

    try {
      final FileSaveLocation? fileLocation = await getSaveLocation(
        acceptedTypeGroups: _asHex ? [hexType, binType] : [binType, hexType],
        suggestedName: _asHex ? 'merged_firmware.hex' : 'merged_firmware.bin',
      );
      if (!mounted) return;

      if (fileLocation != null) {
        final path = fileLocation.path;

        // Progress dialog styled like the "正在执行文件比较" overlay.
        final progress = ValueNotifier<double>(0.0);
        var progressShown = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            content: Container(
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
                    '正在合并文件',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<double>(
                    valueListenable: progress,
                    builder: (context, value, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ZebraProgressBar(
                          progress: value,
                          isLeft: false,
                          isLoading: true,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${(value * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'Consolas'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ).then((_) => progressShown = false);

        // Give the framework one frame to render the progress overlay before
        // the isolate starts, so the transition feels immediate and smooth.
        await Future.delayed(const Duration(milliseconds: 50));

        try {
          await state.mergeFiles(
            items: updatedItems,
            fillByte: fillVal,
            outputPath: path,
            asHex: path.toLowerCase().endsWith('.hex'),
            onProgress: (p) => progress.value = p,
          );
        } finally {
          if (progressShown && mounted) {
            Navigator.of(context, rootNavigator: true).pop();
          }
          progress.dispose();
        }

        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.green, content: Text('合并完成，文件已保存至 $path')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text('合并失败: $e')),
      );
    }
  }

  Widget _buildMemoryMap() {
    if (_items.isEmpty) {
      return Container(
        height: 50,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade800),
        ),
        alignment: Alignment.center,
        child: const Text('添加文件以预览内存映像', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    // Resolve items and calculate bounds
    int globalMin = -1;
    int globalMax = -1;

    final List<MergeItem> mappedItems = [];
    for (int i = 0; i < _items.length; i++) {
      final addr = _parseHexAddress(_addrControllers[i]?.text ?? '') ?? _items[i].startAddress;
      final end = addr + _items[i].size - 1;
      mappedItems.add(_items[i].copyWith(startAddress: addr));

      if (globalMin == -1 || addr < globalMin) globalMin = addr;
      if (globalMax == -1 || end > globalMax) globalMax = end;
    }

    // Start the map at 0 so a non-zero first target address shows up as a
    // leading gap block.
    final totalSpan = globalMax + 1;
    if (totalSpan <= 0) return const SizedBox.shrink();

    // Group segments to render visual blocks
    // Sort mappedItems by start address
    mappedItems.sort((a, b) => a.startAddress.compareTo(b.startAddress));

    final List<Widget> segments = [];
    int lastPos = 0;

    final colors = [
      Colors.cyan.shade800,
      Colors.purple.shade800,
      Colors.teal.shade800,
      Colors.indigo.shade800,
      Colors.orange.shade800,
    ];

    for (int i = 0; i < mappedItems.length; i++) {
      final item = mappedItems[i];
      
      // Check if there is a gap before this item
      if (item.startAddress > lastPos) {
        final gapSize = item.startAddress - lastPos;
        final gapFlex = (gapSize / totalSpan * 1000).round();
        if (gapFlex > 0) {
          segments.add(
            Expanded(
              flex: gapFlex,
              child: Container(
                color: Colors.red.withValues(alpha: 0.15),
                alignment: Alignment.center,
                child: Tooltip(
                  message: '间隙: $gapSize 字节',
                  child: const Text(
                    '间隙',
                    style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          );
        }
      }

      // Add the file block
      final fileFlex = (item.size / totalSpan * 1000).round();
      final color = colors[i % colors.length];
      if (fileFlex > 0) {
        segments.add(
          Expanded(
            flex: fileFlex,
            child: Container(
              color: color,
              alignment: Alignment.center,
              child: Tooltip(
                message: '${item.fileName}\n${_formatHexAddressHalfSpace(item.startAddress)} - ${_formatHexAddressHalfSpace(item.startAddress + item.size - 1)}\n${item.size} 字节',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2.0),
                  child: Text(
                    item.fileName,
                    style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      lastPos = item.startAddress + item.size;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('内存映像映射图 (Memory Map Preview)', style: TextStyle(color: Colors.grey, fontSize: 11)),
            Text(
              '范围: ${_formatHexAddressHalfSpace(0)} - ${_formatHexAddressHalfSpace(globalMax)} (${totalSpan}B)',
              style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontFamily: 'Consolas'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 16,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade800),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(children: segments),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Row(
        children: [
          Icon(Icons.merge, color: Colors.cyanAccent),
          SizedBox(width: 12),
          Text('合并多个 BIN / HEX 文件', style: TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 920,
            height: 480,
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Files List Toolbar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('文件合并清单', style: TextStyle(color: Colors.grey, fontSize: 12)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _addFile,
                      icon: const Icon(Icons.add, size: 14, color: Colors.cyanAccent),
                      label: const Text('添加文件', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF333333),
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _loadList,
                      icon: const Icon(Icons.folder_open, size: 14, color: Colors.cyanAccent),
                      label: const Text('加载清单', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF333333),
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _items.isEmpty ? null : _saveList,
                      icon: const Icon(Icons.save, size: 14, color: Colors.cyanAccent),
                      label: const Text('保存清单', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF333333),
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Files Scrollable Area
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  border: Border.all(color: Colors.grey.shade800),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _items.isEmpty
                    ? const Center(child: Text('没有添加文件。请点击“添加文件”按钮。', style: TextStyle(color: Colors.grey, fontSize: 13)))
                    : ListView.builder(
                        itemCount: _items.length,
                        itemBuilder: (context, idx) {
                          final item = _items[idx];

                          // Resolve current target address of this row.
                          final targetAddress =
                              _parseHexAddress(_addrControllers[idx]?.text ?? '') ??
                                  _items[idx].startAddress;

                          return Container(
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: Colors.grey.shade800)),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: Row(
                              children: [
                                // Sequence number
                                SizedBox(
                                  width: 28,
                                  child: Text(
                                    '${idx + 1}',
                                    style: const TextStyle(color: Colors.grey, fontSize: 12, fontFamily: 'Consolas'),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                // File icon / type
                                Icon(
                                  item.isHex ? Icons.code : Icons.settings_input_hdmi,
                                  color: item.isHex ? Colors.amber : Colors.cyan,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                // Name & size
                                Expanded(
                                  flex: 2,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.fileName,
                                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '大小: ${item.size} 字节',
                                        style: const TextStyle(color: Colors.grey, fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Merge info columns: target address, merged offset, length
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Target address (editable)
                                    SizedBox(
                                      width: 242,
                                      child: Row(
                                        children: [
                                          // Reset target address to the
                                          // minimum legal value.
                                          Tooltip(
                                            message: '复位目标地址',
                                            child: InkWell(
                                              onTap: () => _resetAddress(idx),
                                              borderRadius: BorderRadius.circular(10),
                                              child: const Padding(
                                                padding: EdgeInsets.all(2),
                                                child: Icon(Icons.restart_alt, size: 16, color: Colors.cyanAccent),
                                              ),
                                            ),
                                          ),
                                          const Text('目标地址: ', style: TextStyle(color: Colors.grey, fontSize: 10)),
                                          Expanded(
                                            child: SizedBox(
                                              height: 28,
                                              child: TextField(
                                                controller: _addrControllers[idx],
                                                inputFormatters: [_OvertypeFormatter(), _HexAddressInputFormatter()],
                                                onChanged: (val) {
                                                  // Live-update following files.
                                                  _cascadeFrom(idx);
                                                  setState(() {});
                                                },
                                                onSubmitted: (val) {
                                                  final parsed = _parseHexAddress(val);
                                                  if (parsed == null || parsed < 0 || parsed > 0xFFFFFFFFFFFF) {
                                                    ScaffoldMessenger.of(context).showSnackBar(
                                                      const SnackBar(backgroundColor: Colors.redAccent, content: Text('目标地址无效，必须为 0x0 - 0xFFFF,FFFF,FFFF')),
                                                    );
                                                    _addrControllers[idx]!.text = _formatHex12(targetAddress);
                                                  } else {
                                                    final minAddr = _minAddressFor(idx);
                                                    if (parsed < minAddr) {
                                                      // Too small: clamp up to the minimum legal address.
                                                      _addrControllers[idx]!.text = _formatHex12(minAddr);
                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        SnackBar(
                                                          backgroundColor: Colors.orangeAccent,
                                                          content: Text('目标地址过小，已自动调整为最小目标地址 ${_formatHex12(minAddr)}'),
                                                        ),
                                                      );
                                                    } else {
                                                      _addrControllers[idx]!.text = _formatHex12(parsed);
                                                    }
                                                    _cascadeFrom(idx);
                                                  }
                                                  setState(() {});
                                                },
                                                cursorWidth: 7,
                                                cursorRadius: Radius.zero,
                                                style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'Consolas'),
                                                decoration: InputDecoration(
                                                  contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                                                  filled: true,
                                                  fillColor: const Color(0xFF2E2E2E),
                                                  border: OutlineInputBorder(
                                                    borderRadius: BorderRadius.circular(3),
                                                    borderSide: BorderSide.none,
                                                  ),
                                                  // Hex calculator inside the
                                                  // field, like the offset inputs.
                                                  suffixIcon: IconButton(
                                                    icon: Icon(
                                                      Icons.calculate,
                                                      size: 16,
                                                      color: _calcIndex == idx ? Colors.cyanAccent : Colors.grey,
                                                    ),
                                                    tooltip: '十六进制计算器',
                                                    onPressed: () => setState(
                                                      () => _calcIndex = _calcIndex == idx ? null : idx,
                                                    ),
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Length (read-only)
                                    SizedBox(
                                      width: 150,
                                      child: Row(
                                        children: [
                                          const Text('长度: ', style: TextStyle(color: Colors.grey, fontSize: 10)),
                                          Expanded(
                                            child: Container(
                                              height: 28,
                                              alignment: Alignment.centerLeft,
                                              padding: const EdgeInsets.symmetric(horizontal: 4),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF262626),
                                                borderRadius: BorderRadius.circular(3),
                                              ),
                                              child: Text(
                                                _formatHex12(item.size),
                                                style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontFamily: 'Consolas'),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 8),
                                // Order & delete actions
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.arrow_upward, size: 14, color: Colors.grey),
                                      onPressed: idx == 0 ? null : () => _moveFile(idx, true),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton(
                                      icon: const Icon(Icons.arrow_downward, size: 14, color: Colors.grey),
                                      onPressed: idx == _items.length - 1 ? null : () => _moveFile(idx, false),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                      onPressed: () => _removeFile(idx),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 12),
            // Preview Map
            _buildMemoryMap(),
            const SizedBox(height: 12),
            // Global settings
            Row(
              children: [
                // Fill byte
                Expanded(
                  child: Row(
                    children: [
                      const Text('填充字节: ', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      SizedBox(
                        width: 70,
                        height: 28,
                        child: TextField(
                          controller: _fillByteController,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'Consolas'),
                          decoration: InputDecoration(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                            filled: true,
                            fillColor: const Color(0xFF1E1E1E),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Output Format Mode
                Row(
                  children: [
                    const Text('默认导出格式: ', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(width: 8),
                    ToggleButtons(
                      isSelected: [!_asHex, _asHex],
                      onPressed: (index) {
                        setState(() {
                          _asHex = index == 1;
                        });
                      },
                      borderRadius: BorderRadius.circular(4),
                      constraints: const BoxConstraints(minHeight: 24, minWidth: 60),
                      fillColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                      selectedColor: Colors.white,
                      color: Colors.grey,
                      children: const [
                        Text('BIN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        Text('HEX', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
          ),
          // Embedded hex calculator panel, shown to the right of the merge
          // content while open. The dialog widens so the merge view shifts
          // left; closing the panel re-centers it.
          if (_calcIndex != null) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF242424),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: HexCalculatorDialog(
                key: ValueKey(_calcIndex),
                initialValue:
                    _parseHexAddress(_addrControllers[_calcIndex!]?.text ?? '') ??
                        _items[_calcIndex!].startAddress,
                onConfirm: (value) {
                  final idx = _calcIndex!;
                  final minAddr = _minAddressFor(idx);
                  final clamped = value < minAddr ? minAddr : value;
                  _addrControllers[idx]!.text = _formatHex12(clamped);
                  _cascadeFrom(idx);
                  setState(() => _calcIndex = null);
                },
                onCancel: () => setState(() => _calcIndex = null),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: _executeMerge,
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(140, 36),
          ),
          child: const Text('开始合并并保存'),
        ),
      ],
    );
  }
}
