import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../modules/hex_editor/models/hex_file_data.dart';

class MergeItem {
  final String filePath;
  final String fileName;
  final int startAddress; // The target absolute address where this file starts
  final int size;
  final bool isHex;

  MergeItem({
    required this.filePath,
    required this.fileName,
    required this.startAddress,
    required this.size,
    required this.isHex,
  });

  MergeItem copyWith({
    String? filePath,
    String? fileName,
    int? startAddress,
    int? size,
    bool? isHex,
  }) {
    return MergeItem(
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      startAddress: startAddress ?? this.startAddress,
      size: size ?? this.size,
      isHex: isHex ?? this.isHex,
    );
  }
}

class HexEditorState extends ChangeNotifier {
  HexFileData? _leftFile;
  HexFileData? _rightFile;

  bool _isSyncScrollEnabled = true;
  bool _alignByAbsoluteAddress = false;

  // Per-side byte offsets used in "byte offset" alignment mode.
  // When non-zero, comparison/display starts from this offset inside each file.
  int _leftOffset = 0;
  int _rightOffset = 0;

  // Selections
  int? _selectedAddressLeft;
  int? _selectedAddressRight;

  int? _selectionStartLeft;
  int? _selectionEndLeft;

  int? _selectionStartRight;
  int? _selectionEndRight;

  // Comparison cache
  // Maps absolute address / offset to boolean (true if mismatch)
  Set<int> _mismatchOffsets = {};
  Set<int> _mismatchAbsoluteAddresses = {};
  Set<int> _mismatchRows = SplayTreeSet<int>();
  List<int> _sortedMismatchRows = [];

  // Edit tracking (addr -> new byte value, for in-memory edits before save)
  final Map<int, int> _leftEdits = {};
  final Map<int, int> _rightEdits = {};

  // True when the underlying file bytes have been modified by overwrite/insert/delete
  // operations (as opposed to single-byte edits).
  bool _leftFileModified = false;
  bool _rightFileModified = false;

  // Used to cancel stale asynchronous difference calculations.
  int _diffCalculationId = 0;

  // True while the right panel holds an in-memory "new file" that has no
  // counterpart on disk; difference comparison is skipped in that case.
  bool _rightFileIsNew = false;

  bool _isCalculatingDifferences = false;
  double _differenceCalculationProgress = 0.0;

  bool _isLeftLoading = false;
  bool _isRightLoading = false;
  double _leftLoadProgress = 0.0;
  double _rightLoadProgress = 0.0;

  // External file change detection
  Timer? _fileWatchTimer;
  DateTime? _leftFileLastModified;
  int? _leftFileSize;
  DateTime? _rightFileLastModified;
  int? _rightFileSize;
  bool _leftFileChangedExternally = false;
  bool _rightFileChangedExternally = false;
  bool _isSaving = false;

  // Getters
  HexFileData? get leftFile => _leftFile;
  HexFileData? get rightFile => _rightFile;

  bool get isSyncScrollEnabled => _isSyncScrollEnabled;
  bool get alignByAbsoluteAddress => _alignByAbsoluteAddress;

  int get leftOffset => _leftOffset;
  int get rightOffset => _rightOffset;

  bool get isCalculatingDifferences => _isCalculatingDifferences;
  double get differenceCalculationProgress => _differenceCalculationProgress;

  bool get isLeftLoading => _isLeftLoading;
  bool get isRightLoading => _isRightLoading;
  double get leftLoadProgress => _leftLoadProgress;
  double get rightLoadProgress => _rightLoadProgress;

  Map<int, int> get leftEdits => _leftEdits;
  Map<int, int> get rightEdits => _rightEdits;
  bool get hasLeftEdits => _leftEdits.isNotEmpty || _leftFileModified;
  bool get hasRightEdits => _rightEdits.isNotEmpty || _rightFileModified;

  bool get leftFileChangedExternally => _leftFileChangedExternally;
  bool get rightFileChangedExternally => _rightFileChangedExternally;

  int? get selectedAddressLeft => _selectedAddressLeft;
  int? get selectedAddressRight => _selectedAddressRight;

  int? get selectionStartLeft => _selectionStartLeft;
  int? get selectionEndLeft => _selectionEndLeft;

  int? get selectionStartRight => _selectionStartRight;
  int? get selectionEndRight => _selectionEndRight;

  Set<int> get mismatchOffsets => _mismatchOffsets;
  Set<int> get mismatchAbsoluteAddresses => _mismatchAbsoluteAddresses;
  Set<int> get mismatchRows => _mismatchRows;
  List<int> get sortedMismatchRows => _sortedMismatchRows;

  // Setters & Actions
  void toggleSyncScroll(bool value) {
    _isSyncScrollEnabled = value;
    if (_isSyncScrollEnabled) {
      if (_selectedAddressLeft != null) {
        _selectedAddressRight = _getSyncAddress(true, _selectedAddressLeft);
        _selectionStartRight = _getSyncAddress(true, _selectionStartLeft);
        _selectionEndRight = _getSyncAddress(true, _selectionEndLeft);
      } else if (_selectedAddressRight != null) {
        _selectedAddressLeft = _getSyncAddress(false, _selectedAddressRight);
        _selectionStartLeft = _getSyncAddress(false, _selectionStartRight);
        _selectionEndLeft = _getSyncAddress(false, _selectionEndRight);
      }
    }
    notifyListeners();
  }

  Future<void> toggleAlignByAbsoluteAddress(bool value) async {
    _alignByAbsoluteAddress = value;
    notifyListeners();
    await _recalculateDifferences();
  }

  Future<void> setLeftOffset(int value) async {
    final clamped = value < 0 ? 0 : value;
    if (_leftOffset == clamped) return;
    _leftOffset = clamped;
    notifyListeners();
    await _recalculateDifferences();
  }

  Future<void> setRightOffset(int value) async {
    final clamped = value < 0 ? 0 : value;
    if (_rightOffset == clamped) return;
    _rightOffset = clamped;
    notifyListeners();
    await _recalculateDifferences();
  }

  /// Converts a virtual aligned offset to the real absolute address for the given side.
  /// In byte-offset mode this is baseAddress + sideOffset + virtualOffset.
  /// In absolute-address mode virtualOffset is already the absolute address.
  int getEffectiveAddress(bool isLeft, int virtualOffset) {
    if (_alignByAbsoluteAddress) return virtualOffset;
    final file = isLeft ? _leftFile : _rightFile;
    final sideOffset = isLeft ? _leftOffset : _rightOffset;
    return (file?.baseAddress ?? 0) + sideOffset + virtualOffset;
  }

  int? _getSyncAddress(bool fromLeft, int? address) {
    if (address == null) return null;
    final sourceFile = fromLeft ? _leftFile : _rightFile;
    final targetFile = fromLeft ? _rightFile : _leftFile;
    if (sourceFile == null || targetFile == null) return null;
    
    if (_alignByAbsoluteAddress) {
      return address;
    } else {
      final sourceOffset = fromLeft ? _leftOffset : _rightOffset;
      final targetOffset = fromLeft ? _rightOffset : _leftOffset;
      final virtualOffset = address - sourceFile.baseAddress - sourceOffset;
      return targetFile.baseAddress + targetOffset + virtualOffset;
    }
  }

  void setSelectedAddress(bool isLeft, int? address) {
    if (isLeft) {
      _selectedAddressLeft = address;
      if (_isSyncScrollEnabled) {
        _selectedAddressRight = _getSyncAddress(true, address);
      }
    } else {
      _selectedAddressRight = address;
      if (_isSyncScrollEnabled) {
        _selectedAddressLeft = _getSyncAddress(false, address);
      }
    }
    notifyListeners();
  }

  void setSelection(bool isLeft, int? start, int? end) {
    if (isLeft) {
      _selectionStartLeft = start;
      _selectionEndLeft = end;
      if (_isSyncScrollEnabled) {
        _selectionStartRight = _getSyncAddress(true, start);
        _selectionEndRight = _getSyncAddress(true, end);
      }
    } else {
      _selectionStartRight = start;
      _selectionEndRight = end;
      if (_isSyncScrollEnabled) {
        _selectionStartLeft = _getSyncAddress(false, start);
        _selectionEndLeft = _getSyncAddress(false, end);
      }
    }
    notifyListeners();
  }

  /// Sets the selection for one side without syncing it to the opposite side.
  /// Useful when the two sides need independent selections (e.g. for overwrite).
  void setSelectionWithoutSync(bool isLeft, int? start, int? end) {
    if (isLeft) {
      _selectionStartLeft = start;
      _selectionEndLeft = end;
    } else {
      _selectionStartRight = start;
      _selectionEndRight = end;
    }
    notifyListeners();
  }

  void clearSelection(bool isLeft) {
    if (isLeft) {
      _selectionStartLeft = null;
      _selectionEndLeft = null;
      _selectedAddressLeft = null;
      if (_isSyncScrollEnabled) {
        _selectionStartRight = null;
        _selectionEndRight = null;
        _selectedAddressRight = null;
      }
    } else {
      _selectionStartRight = null;
      _selectionEndRight = null;
      _selectedAddressRight = null;
      if (_isSyncScrollEnabled) {
        _selectionStartLeft = null;
        _selectionEndLeft = null;
        _selectedAddressLeft = null;
      }
    }
    notifyListeners();
  }

  Future<void> loadLeftFile(String path, {int baseAddr = 0}) async {
    try {
      _stopFileWatcher();
      _isLeftLoading = true;
      _leftLoadProgress = 0.0;
      notifyListeners();

      // Granular loading progress animation (approx 600ms for smooth visibility)
      for (int i = 1; i <= 20; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        _leftLoadProgress = i * 0.045; // fills up to 0.90
        notifyListeners();
      }

      final file = File(path);
      final bytes = await file.readAsBytes();
      final isHex = path.toLowerCase().endsWith('.hex');
      
      _leftLoadProgress = 0.95;
      notifyListeners();

      if (isHex) {
        _leftFile = HexFileData.fromHexBytes(bytes, path);
      } else {
        _leftFile = HexFileData.fromBinBytes(bytes, path, baseAddr: baseAddr);
      }

      _leftLoadProgress = 1.0;
      notifyListeners();
      
      // Keep 100% visible briefly so the user sees the completed bar
      await Future.delayed(const Duration(milliseconds: 150));
      
      _isLeftLoading = false;
      _selectedAddressLeft = null;
      _selectionStartLeft = null;
      _selectionEndLeft = null;
      _leftEdits.clear();
      _leftFileModified = false;
      _recordFileState(true);
      _startFileWatcher();
      notifyListeners();
      await _recalculateDifferences();
    } catch (e) {
      _isLeftLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> loadRightFile(String path, {int baseAddr = 0}) async {
    try {
      _stopFileWatcher();
      _rightFileIsNew = false;
      _isRightLoading = true;
      _rightLoadProgress = 0.0;
      notifyListeners();

      // Granular loading progress animation (approx 600ms for smooth visibility)
      for (int i = 1; i <= 20; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        _rightLoadProgress = i * 0.045; // fills up to 0.90
        notifyListeners();
      }

      final file = File(path);
      final bytes = await file.readAsBytes();
      final isHex = path.toLowerCase().endsWith('.hex');
      
      _rightLoadProgress = 0.95;
      notifyListeners();

      if (isHex) {
        _rightFile = HexFileData.fromHexBytes(bytes, path);
      } else {
        _rightFile = HexFileData.fromBinBytes(bytes, path, baseAddr: baseAddr);
      }

      _rightLoadProgress = 1.0;
      notifyListeners();
      
      // Keep 100% visible briefly so the user sees the completed bar
      await Future.delayed(const Duration(milliseconds: 150));

      _isRightLoading = false;
      _selectedAddressRight = null;
      _selectionStartRight = null;
      _selectionEndRight = null;
      _rightEdits.clear();
      _rightFileModified = false;
      _recordFileState(false);
      _startFileWatcher();
      notifyListeners();
      await _recalculateDifferences();
    } catch (e) {
      _isRightLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> createRightFile(int length, int fillValue) async {
    if (length <= 0) return;
    try {
      _stopFileWatcher();
      _rightFileIsNew = true;
      _isRightLoading = true;
      _rightLoadProgress = 0.0;
      notifyListeners();

      for (int i = 1; i <= 20; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        _rightLoadProgress = i * 0.045;
        notifyListeners();
      }

      final bytes = Uint8List(length);
      final byte = fillValue & 0xFF;
      for (int i = 0; i < length; i++) {
        bytes[i] = byte;
      }

      _rightFile = HexFileData.fromBinBytes(bytes, '新建文件.bin', baseAddr: 0);

      _rightLoadProgress = 1.0;
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 150));

      _isRightLoading = false;
      _selectedAddressRight = null;
      _selectionStartRight = null;
      _selectionEndRight = null;
      _rightEdits.clear();
      _rightFileModified = false;
      _rightFileLastModified = null;
      _rightFileSize = length;
      _rightFileChangedExternally = false;
      notifyListeners();
      await _recalculateDifferences();
    } catch (e) {
      _isRightLoading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> closeLeftFile() async {
    _stopFileWatcher();
    _leftFile = null;
    _leftFileLastModified = null;
    _leftFileSize = null;
    _leftFileChangedExternally = false;
    _selectedAddressLeft = null;
    _selectionStartLeft = null;
    _selectionEndLeft = null;
    _leftEdits.clear();
    _leftFileModified = false;
    notifyListeners();
    await _recalculateDifferences();
  }

  Future<void> closeRightFile() async {
    _stopFileWatcher();
    _rightFile = null;
    _rightFileIsNew = false;
    _rightFileLastModified = null;
    _rightFileSize = null;
    _rightFileChangedExternally = false;
    _selectedAddressRight = null;
    _selectionStartRight = null;
    _selectionEndRight = null;
    _rightEdits.clear();
    _rightFileModified = false;
    notifyListeners();
    await _recalculateDifferences();
  }

  Future<void> _recalculateDifferences() async {
    final calculationId = ++_diffCalculationId;
    final Set<int> mismatchOffsets = {};
    final Set<int> mismatchAbsoluteAddresses = {};
    final Set<int> mismatchRows = SplayTreeSet<int>();

    // Skip comparison entirely while the right side is an in-memory new file.
    if (_rightFileIsNew) {
      _mismatchOffsets = mismatchOffsets;
      _mismatchAbsoluteAddresses = mismatchAbsoluteAddresses;
      _mismatchRows = mismatchRows;
      _sortedMismatchRows = const [];
      _isCalculatingDifferences = false;
      _differenceCalculationProgress = 0.0;
      notifyListeners();
      return;
    }

    _isCalculatingDifferences = true;
    _differenceCalculationProgress = 0.0;
    notifyListeners();

    void updateProgress(double value) {
      final quantized = (value * 50).round() / 50; // 2% steps
      if (quantized != _differenceCalculationProgress) {
        _differenceCalculationProgress = quantized;
        notifyListeners();
      }
    }

    if (_leftFile != null && _rightFile != null) {
      // Smaller chunks let the UI update progress more frequently.
      const int chunkSize = 4096;

      if (_alignByAbsoluteAddress) {
        final alignedStart = _leftFile!.baseAddress & ~0x0F;

        if (_leftFile!.isContiguous && _rightFile!.isContiguous) {
          final start = min(_leftFile!.baseAddress, _rightFile!.baseAddress);
          final end = max(_leftFile!.maxAddress, _rightFile!.maxAddress);
          final total = end - start + 1;

          for (int chunkStart = start; chunkStart <= end; chunkStart += chunkSize) {
            if (calculationId != _diffCalculationId) return;
            final chunkEnd = min(chunkStart + chunkSize - 1, end);
            for (int addr = chunkStart; addr <= chunkEnd; addr++) {
              final leftHas = _leftFile!.hasByteAt(addr);
              final rightHas = _rightFile!.hasByteAt(addr);
              if (!leftHas || !rightHas) {
                mismatchAbsoluteAddresses.add(addr);
                mismatchRows.add((addr - alignedStart) ~/ 16);
              } else if (_leftFile!.getByteAt(addr) != _rightFile!.getByteAt(addr)) {
                mismatchAbsoluteAddresses.add(addr);
                mismatchRows.add((addr - alignedStart) ~/ 16);
              }
            }
            updateProgress((chunkEnd - start + 1) / total);
            await Future.delayed(Duration.zero);
          }
        } else {
          // Sparse / mixed files: build address set from HEX map keys or contiguous range.
          final allAddresses = <int>{};
          if (_leftFile!.isContiguous) {
            for (int addr = _leftFile!.baseAddress; addr <= _leftFile!.maxAddress; addr++) {
              allAddresses.add(addr);
            }
          } else {
            allAddresses.addAll(_leftFile!.absoluteAddressMap.keys);
          }
          if (_rightFile!.isContiguous) {
            for (int addr = _rightFile!.baseAddress; addr <= _rightFile!.maxAddress; addr++) {
              allAddresses.add(addr);
            }
          } else {
            allAddresses.addAll(_rightFile!.absoluteAddressMap.keys);
          }

          final addressList = allAddresses.toList()..sort();
          final totalAddresses = addressList.length;
          for (int i = 0; i < totalAddresses; i += chunkSize) {
            if (calculationId != _diffCalculationId) return;
            final chunkEnd = min(i + chunkSize, totalAddresses);
            for (int j = i; j < chunkEnd; j++) {
              final addr = addressList[j];
              final leftHas = _leftFile!.hasByteAt(addr);
              final rightHas = _rightFile!.hasByteAt(addr);
              if (!leftHas || !rightHas) {
                mismatchAbsoluteAddresses.add(addr);
                mismatchRows.add((addr - alignedStart) ~/ 16);
              } else if (_leftFile!.getByteAt(addr) != _rightFile!.getByteAt(addr)) {
                mismatchAbsoluteAddresses.add(addr);
                mismatchRows.add((addr - alignedStart) ~/ 16);
              }
            }
            updateProgress(chunkEnd / totalAddresses);
            await Future.delayed(Duration.zero);
          }
        }
      } else {
        // Align by virtual offset, optionally skipping a per-side start offset.
        final leftEffectiveLen = max(0, _leftFile!.bytes.length - _leftOffset);
        final rightEffectiveLen = max(0, _rightFile!.bytes.length - _rightOffset);
        final maxLen = leftEffectiveLen > rightEffectiveLen ? leftEffectiveLen : rightEffectiveLen;

        for (int chunkStart = 0; chunkStart < maxLen; chunkStart += chunkSize) {
          if (calculationId != _diffCalculationId) return;
          final chunkEnd = min(chunkStart + chunkSize - 1, maxLen - 1);
          for (int virtualOffset = chunkStart; virtualOffset <= chunkEnd; virtualOffset++) {
            final leftIndex = _leftOffset + virtualOffset;
            final rightIndex = _rightOffset + virtualOffset;
            final leftHas = leftIndex >= 0 && leftIndex < _leftFile!.bytes.length;
            final rightHas = rightIndex >= 0 && rightIndex < _rightFile!.bytes.length;
            if (!leftHas || !rightHas) {
              mismatchOffsets.add(virtualOffset);
              mismatchRows.add(virtualOffset ~/ 16);
            } else if (_leftFile!.bytes[leftIndex] != _rightFile!.bytes[rightIndex]) {
              mismatchOffsets.add(virtualOffset);
              mismatchRows.add(virtualOffset ~/ 16);
            }
          }
          updateProgress((chunkEnd + 1) / maxLen);
          await Future.delayed(Duration.zero);
        }
      }
    }

    if (calculationId != _diffCalculationId) return;

    // Show 100% first so the user sees the comparison completed before the
    // overlay disappears and the results are finalized.
    _differenceCalculationProgress = 1.0;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 120));

    _mismatchOffsets = mismatchOffsets;
    _mismatchAbsoluteAddresses = mismatchAbsoluteAddresses;
    _mismatchRows = mismatchRows;
    _sortedMismatchRows = mismatchRows.toList();
    _isCalculatingDifferences = false;
    notifyListeners();
  }

  /// Records a single byte edit in memory.
  /// [addr] is the absolute address (or offset depending on alignment mode).
  void editByte(bool isLeft, int addr, int value) {
    if (isLeft) {
      _leftEdits[addr] = value;
    } else {
      _rightEdits[addr] = value;
    }
    notifyListeners();
  }

  /// Overwrites the opposite side's selection with this side's selection.
  /// [fromLeft] true means copy left selection onto right selection.
  /// The target selection is deleted first, then the source bytes are inserted,
  /// so the resulting target length equals the source selection length.
  void overwriteSelection(bool fromLeft) {
    final sourceFile = fromLeft ? _leftFile : _rightFile;
    final targetFile = fromLeft ? _rightFile : _leftFile;
    final sourceSelectionStart = fromLeft ? _selectionStartLeft : _selectionStartRight;
    final sourceSelectionEnd = fromLeft ? _selectionEndLeft : _selectionEndRight;
    final targetSelectionStart = fromLeft ? _selectionStartRight : _selectionStartLeft;
    final targetSelectionEnd = fromLeft ? _selectionEndRight : _selectionEndLeft;

    if (sourceFile == null || targetFile == null) return;
    if (sourceSelectionStart == null || sourceSelectionEnd == null ||
        targetSelectionStart == null || targetSelectionEnd == null) {
      return;
    }

    final sourceStart = sourceSelectionStart < sourceSelectionEnd ? sourceSelectionStart : sourceSelectionEnd;
    final sourceEnd = sourceSelectionStart > sourceSelectionEnd ? sourceSelectionStart : sourceSelectionEnd;
    final targetStart = targetSelectionStart < targetSelectionEnd ? targetSelectionStart : targetSelectionEnd;
    final targetEnd = targetSelectionStart > targetSelectionEnd ? targetSelectionStart : targetSelectionEnd;

    final sourceLen = sourceEnd - sourceStart + 1;

    // Read source bytes
    final sourceBytes = Uint8List(sourceLen);
    for (int i = 0; i < sourceLen; i++) {
      sourceBytes[i] = sourceFile.getByteAt(sourceStart + i);
    }

    // Build new target bytes: keep bytes before target selection, insert source bytes, keep bytes after
    final targetOffsetStart = targetStart - targetFile.baseAddress;
    final targetOffsetEnd = targetEnd - targetFile.baseAddress;
    final before = targetFile.bytes.sublist(0, targetOffsetStart);
    final after = targetFile.bytes.sublist(targetOffsetEnd + 1);

    final builder = BytesBuilder();
    builder.add(before);
    builder.add(sourceBytes);
    builder.add(after);
    final newBytes = builder.toBytes();

    // Replace target file and update selection to the inserted range
    final newTargetFile = targetFile.copyWith(bytes: newBytes);
    final newTargetEnd = targetStart + sourceLen - 1;

    if (fromLeft) {
      _rightFile = newTargetFile;
      _rightEdits.clear();
      _rightFileModified = true;
      _selectionStartRight = targetStart;
      _selectionEndRight = newTargetEnd;
      _selectedAddressRight = newTargetEnd;
    } else {
      _leftFile = newTargetFile;
      _leftEdits.clear();
      _leftFileModified = true;
      _selectionStartLeft = targetStart;
      _selectionEndLeft = newTargetEnd;
      _selectedAddressLeft = newTargetEnd;
    }

    notifyListeners();
    _recalculateDifferences();
  }

  /// Returns the display value for a byte at [addr], preferring in-memory edits.
  int getDisplayByte(bool isLeft, int addr, {int defaultValue = 0xFF}) {
    final edits = isLeft ? _leftEdits : _rightEdits;
    if (edits.containsKey(addr)) return edits[addr]!;
    final file = isLeft ? _leftFile : _rightFile;
    return file?.getByteAt(addr, defaultValue: defaultValue) ?? defaultValue;
  }

  /// Discards all unsaved edits for the given side.
  /// If the file bytes were modified by insert/delete operations, reloads the original file.
  Future<void> discardEdits(bool isLeft) async {
    if (isLeft) {
      if (_leftFileModified && _leftFile != null) {
        await loadLeftFile(_leftFile!.filePath, baseAddr: _leftFile!.isHexFormat ? 0 : _leftFile!.baseAddress);
      } else {
        _leftEdits.clear();
        _leftFileModified = false;
        notifyListeners();
      }
    } else {
      if (_rightFileModified && _rightFile != null) {
        await loadRightFile(_rightFile!.filePath, baseAddr: _rightFile!.isHexFormat ? 0 : _rightFile!.baseAddress);
      } else {
        _rightEdits.clear();
        _rightFileModified = false;
        notifyListeners();
      }
    }
  }

  /// Saves in-memory edits back to the original file on disk.
  Future<void> saveFile(bool isLeft) async {
    final file = isLeft ? _leftFile : _rightFile;
    final edits = isLeft ? _leftEdits : _rightEdits;
    if (file == null) return;
    if (edits.isEmpty && !(isLeft ? _leftFileModified : _rightFileModified)) return;

    // Apply edits onto a mutable copy of the bytes
    final Uint8List newBytes = Uint8List.fromList(file.bytes);
    for (final entry in edits.entries) {
      final int addr = entry.key;
      final int offset = addr - file.baseAddress;
      if (offset >= 0 && offset < newBytes.length) {
        newBytes[offset] = entry.value;
      }
    }

    final ioFile = File(file.filePath);
    _isSaving = true;
    try {
      if (file.isHexFormat) {
        final hexString = _encodeIntelHex(newBytes, file.baseAddress);
        await ioFile.writeAsString(hexString);
      } else {
        await ioFile.writeAsBytes(newBytes);
      }

      // Clear edits and reload to refresh the in-memory model
      if (isLeft) {
        _leftEdits.clear();
        _leftFileModified = false;
        await loadLeftFile(file.filePath, baseAddr: file.isHexFormat ? 0 : file.baseAddress);
      } else {
        _rightEdits.clear();
        _rightFileModified = false;
        await loadRightFile(file.filePath, baseAddr: file.isHexFormat ? 0 : file.baseAddress);
      }
    } finally {
      _isSaving = false;
    }
  }

  /// Exports selection range (inclusive of start and end addresses)

  Future<void> exportSelection({
    required bool isLeft,
    required int startAddr,
    required int endAddr,
    required String outputPath,
    bool asHex = false,
    bool asHeader = false,
  }) async {
    final fileData = isLeft ? _leftFile : _rightFile;
    if (fileData == null) throw Exception('没有文件可供导出');

    final int start = startAddr < endAddr ? startAddr : endAddr;
    final int end = startAddr < endAddr ? endAddr : startAddr;

    final List<int> exportedBytes = [];
    for (int addr = start; addr <= end; addr++) {
      exportedBytes.add(fileData.getByteAt(addr));
    }

    final Uint8List rawExport = Uint8List.fromList(exportedBytes);
    final file = File(outputPath);

    if (asHex) {
      final hexString = _encodeIntelHex(rawExport, start);
      await file.writeAsString(hexString);
    } else if (asHeader) {
      final headerString = _encodeCHeader(rawExport, start, fileData.fileName);
      await file.writeAsString(headerString);
    } else {
      await file.writeAsBytes(rawExport);
    }
  }

  /// Merges multiple files (either bin or hex) and writes them out.
  /// The heavy lifting is run in a background isolate so the UI stays responsive.
  Future<void> mergeFiles({
    required List<MergeItem> items,
    required int fillByte,
    required String outputPath,
    required bool asHex,
    void Function(double progress)? onProgress,
  }) async {
    if (items.isEmpty) throw Exception('没有要合并的文件');

    final receivePort = ReceivePort();
    final args = _MergeIsolateArgs(
      sendPort: receivePort.sendPort,
      items: items,
      fillByte: fillByte,
      outputPath: outputPath,
      asHex: asHex,
    );

    final isolate = await Isolate.spawn(_mergeFilesIsolate, args);

    try {
      await for (final message in receivePort) {
        if (message is double) {
          onProgress?.call(message);
        } else if (message is _MergeIsolateError) {
          throw message.error;
        } else if (message == _mergeIsolateDone) {
          break;
        }
      }
    } finally {
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  // External file change detection helpers
  void _recordFileState(bool isLeft) {
    final fileData = isLeft ? _leftFile : _rightFile;
    if (fileData == null) return;
    try {
      final stat = File(fileData.filePath).statSync();
      if (isLeft) {
        _leftFileLastModified = stat.modified;
        _leftFileSize = stat.size;
        _leftFileChangedExternally = false;
      } else {
        _rightFileLastModified = stat.modified;
        _rightFileSize = stat.size;
        _rightFileChangedExternally = false;
      }
    } catch (_) {
      // Keep previous metadata if stat fails; the next check will flag it.
    }
  }

  void _startFileWatcher() {
    _stopFileWatcher();
    if (_leftFile == null && _rightFile == null) return;
    _fileWatchTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkExternalChanges());
  }

  void _stopFileWatcher() {
    _fileWatchTimer?.cancel();
    _fileWatchTimer = null;
  }

  void _checkExternalChanges() {
    if (_isSaving) return;
    _checkSide(true);
    _checkSide(false);
  }

  void _checkSide(bool isLeft) {
    final fileData = isLeft ? _leftFile : _rightFile;
    final lastModified = isLeft ? _leftFileLastModified : _rightFileLastModified;
    final fileSize = isLeft ? _leftFileSize : _rightFileSize;
    if (fileData == null) return;
    if (lastModified == null || fileSize == null) return;

    try {
      final stat = File(fileData.filePath).statSync();
      if (stat.modified != lastModified || stat.size != fileSize) {
        if (isLeft) {
          _leftFileChangedExternally = true;
        } else {
          _rightFileChangedExternally = true;
        }
        notifyListeners();
      }
    } catch (_) {
      if (isLeft) {
        _leftFileChangedExternally = true;
      } else {
        _rightFileChangedExternally = true;
      }
      notifyListeners();
    }
  }

  /// Public entry for tests or manual checks.
  void checkExternalChanges() => _checkExternalChanges();

  Future<void> reloadFile(bool isLeft) async {
    final file = isLeft ? _leftFile : _rightFile;
    if (file == null) return;
    if (isLeft) {
      await loadLeftFile(file.filePath, baseAddr: file.isHexFormat ? 0 : file.baseAddress);
    } else {
      await loadRightFile(file.filePath, baseAddr: file.isHexFormat ? 0 : file.baseAddress);
    }
  }

  void ignoreExternalChange(bool isLeft) {
    _recordFileState(isLeft);
    notifyListeners();
  }

  @override
  void dispose() {
    _stopFileWatcher();
    super.dispose();
  }
}


// Helper data classes for the isolate-based merge pipeline.
class _MergeIsolateArgs {
  final SendPort sendPort;
  final List<MergeItem> items;
  final int fillByte;
  final String outputPath;
  final bool asHex;

  _MergeIsolateArgs({
    required this.sendPort,
    required this.items,
    required this.fillByte,
    required this.outputPath,
    required this.asHex,
  });
}

class _MergeIsolateError {
  final Object error;
  _MergeIsolateError(this.error);
}

const _mergeIsolateDone = #mergeIsolateDone;

/// Runs the heavy merge work in a background isolate so the UI thread remains
/// responsive. Progress updates (0.0–1.0) and completion/error signals are sent
/// back through the provided [SendPort].
void _mergeFilesIsolate(_MergeIsolateArgs args) async {
  try {
    final Map<int, int> mergedMap = {};
    int minAddr = -1;
    int maxAddr = -1;

    int fileIndex = 0;
    for (final item in args.items) {
      final fileBytes = await File(item.filePath).readAsBytes();
      Map<int, int> fileAddrMap = {};
      int fileBaseAddr = 0;

      if (item.isHex) {
        final parsed = HexFileData.fromHexBytes(fileBytes, item.filePath, fillByte: args.fillByte);
        fileAddrMap = parsed.absoluteAddressMap;
        fileBaseAddr = parsed.baseAddress;
      } else {
        for (int i = 0; i < fileBytes.length; i++) {
          fileAddrMap[i] = fileBytes[i];
        }
        fileBaseAddr = 0;
      }

      final shift = item.startAddress - fileBaseAddr;
      fileAddrMap.forEach((srcAddr, val) {
        final targetAddr = srcAddr + shift;
        mergedMap[targetAddr] = val;

        if (minAddr == -1 || targetAddr < minAddr) minAddr = targetAddr;
        if (maxAddr == -1 || targetAddr > maxAddr) maxAddr = targetAddr;
      });

      fileIndex++;
      args.sendPort.send(0.1 + 0.5 * fileIndex / args.items.length);
      await Future.delayed(Duration.zero);
    }

    if (mergedMap.isEmpty) {
      throw Exception('合并后的文件数据为空');
    }

    final int mergedSize = maxAddr - minAddr + 1;
    if (mergedSize > 100 * 1024 * 1024) {
      throw Exception('合并后的文件跨度过大（${(mergedSize / 1024 / 1024).toStringAsFixed(2)}MB），超过了 100MB 限制');
    }

    final Uint8List mergedBytes = Uint8List(mergedSize);
    for (int i = 0; i < mergedSize; i++) {
      mergedBytes[i] = mergedMap[minAddr + i] ?? args.fillByte;
      if ((i & 0xFFFFF) == 0) {
        args.sendPort.send(0.6 + 0.3 * i / mergedSize);
        await Future.delayed(Duration.zero);
      }
    }

    args.sendPort.send(0.95);
    final file = File(args.outputPath);
    if (args.asHex) {
      final hexString = _encodeIntelHex(mergedBytes, minAddr);
      await file.writeAsString(hexString);
    } else {
      await file.writeAsBytes(mergedBytes);
    }
    args.sendPort.send(1.0);
    args.sendPort.send(_mergeIsolateDone);
  } catch (e, st) {
    args.sendPort.send(_MergeIsolateError('合并失败: $e\n$st'));
  }
}

String _encodeIntelHex(Uint8List bytes, int startAddr) {
  final StringBuffer sb = StringBuffer();
  int currentUpperLinear = -1;

  for (int i = 0; i < bytes.length; i += 16) {
    final int addr = startAddr + i;
    final int upperLinear = addr >> 16;

    if (upperLinear != currentUpperLinear) {
      currentUpperLinear = upperLinear;
      // Write type 04: Extended Linear Address Record
      final int sum = 2 + 0 + 0 + 4 + (upperLinear >> 8) + (upperLinear & 0xFF);
      final int chk = (~sum + 1) & 0xFF;
      final String line = ':02000004${upperLinear.toRadixString(16).padLeft(4, '0').toUpperCase()}${chk.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      sb.writeln(line);
    }

    final int chunkLen = (bytes.length - i) > 16 ? 16 : (bytes.length - i);
    final int addrOffset = addr & 0xFFFF;
    int sum = chunkLen + (addrOffset >> 8) + (addrOffset & 0xFF) + 0x00;

    String line = ':${chunkLen.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    line += '${addrOffset.toRadixString(16).padLeft(4, '0').toUpperCase()}00';

    for (int j = 0; j < chunkLen; j++) {
      final int b = bytes[i + j];
      line += b.toRadixString(16).padLeft(2, '0').toUpperCase();
      sum += b;
    }

    final int checksum = (~sum + 1) & 0xFF;
    line += checksum.toRadixString(16).padLeft(2, '0').toUpperCase();
    sb.writeln(line);
  }

  sb.writeln(':00000001FF');
  return sb.toString();
}

String _encodeCHeader(Uint8List bytes, int startAddr, String sourceFileName) {
  final baseName = p.basenameWithoutExtension(sourceFileName);
  final suffix = 'S0x${startAddr.toRadixString(16).toUpperCase()}_L${bytes.length}';
  final arrayName = _toCIdentifier('${baseName}_$suffix');
  final guardName = arrayName.toUpperCase();

  final buffer = StringBuffer();
  buffer.writeln('#ifndef $guardName');
  buffer.writeln('#define $guardName');
  buffer.writeln();
  buffer.writeln('/*');
  buffer.writeln(' * Exported from: $sourceFileName');
  buffer.writeln(' * Start address: 0x${startAddr.toRadixString(16).toUpperCase().padLeft(8, '0')}');
  buffer.writeln(' * Length: ${bytes.length} bytes');
  buffer.writeln(' */');
  buffer.writeln('const unsigned char $arrayName[] = {');

  const bytesPerLine = 16;
  for (int i = 0; i < bytes.length; i += bytesPerLine) {
    buffer.write('    ');
    final end = (i + bytesPerLine < bytes.length) ? i + bytesPerLine : bytes.length;
    for (int j = i; j < end; j++) {
      buffer.write('0x${bytes[j].toRadixString(16).toUpperCase().padLeft(2, '0')}');
      if (j < bytes.length - 1) buffer.write(', ');
    }
    buffer.writeln();
  }

  buffer.writeln('};');
  buffer.writeln();
  buffer.writeln('#define ${arrayName}_LEN (${bytes.length})');
  buffer.writeln();
  buffer.writeln('#endif /* $guardName */');
  return buffer.toString();
}

String _toCIdentifier(String name) {
  final buffer = StringBuffer();
  for (int i = 0; i < name.length; i++) {
    final c = name[i];
    final code = c.codeUnitAt(0);
    final isValid = (code >= 97 && code <= 122) ||
                    (code >= 65 && code <= 90) ||
                    code == 95 ||
                    (i > 0 && code >= 48 && code <= 57);
    buffer.write(isValid ? c : '_');
  }
  if (buffer.isEmpty) return 'data';
  final result = buffer.toString();
  final first = result.codeUnitAt(0);
  if (first >= 48 && first <= 57) return 'data_$result';
  return result;
}
