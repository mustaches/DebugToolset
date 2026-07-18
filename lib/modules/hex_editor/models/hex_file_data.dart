import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

class HexFileData {
  final String filePath;
  final String fileName;
  final int baseAddress;
  final Uint8List bytes;
  final Map<int, int> absoluteAddressMap;
  final bool isHexFormat;
  final bool isContiguous;

  HexFileData({
    required this.filePath,
    required this.fileName,
    required this.baseAddress,
    required this.bytes,
    required this.absoluteAddressMap,
    required this.isHexFormat,
    required this.isContiguous,
  });

  HexFileData copyWith({
    String? filePath,
    String? fileName,
    int? baseAddress,
    Uint8List? bytes,
    Map<int, int>? absoluteAddressMap,
    bool? isHexFormat,
    bool? isContiguous,
  }) {
    return HexFileData(
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      baseAddress: baseAddress ?? this.baseAddress,
      bytes: bytes ?? this.bytes,
      absoluteAddressMap: absoluteAddressMap ?? this.absoluteAddressMap,
      isHexFormat: isHexFormat ?? this.isHexFormat,
      isContiguous: isContiguous ?? this.isContiguous,
    );
  }

  /// Get the absolute maximum address this file covers.
  int get maxAddress => baseAddress + bytes.length - 1;

  /// Check if the file contains data at the given absolute address.
  bool hasByteAt(int absoluteAddress) {
    if (isContiguous) {
      final off = absoluteAddress - baseAddress;
      return off >= 0 && off < bytes.length;
    }
    return absoluteAddressMap.containsKey(absoluteAddress);
  }

  /// Get byte at absolute address, returns `defaultValue` (default 0xFF) if sparse gap.
  int getByteAt(int absoluteAddress, {int defaultValue = 0xFF}) {
    if (isContiguous) {
      final off = absoluteAddress - baseAddress;
      return (off >= 0 && off < bytes.length) ? bytes[off] : defaultValue;
    }
    return absoluteAddressMap[absoluteAddress] ?? defaultValue;
  }

  /// Create a HexFileData from raw bytes of a BIN file.
  factory HexFileData.fromBinBytes(Uint8List rawBytes, String filePath, {int baseAddr = 0}) {
    final String name = p.basename(filePath);
    return HexFileData(
      filePath: filePath,
      fileName: name,
      baseAddress: baseAddr,
      bytes: rawBytes,
      absoluteAddressMap: const {},
      isHexFormat: false,
      isContiguous: true,
    );
  }

  /// Create a HexFileData by parsing Intel HEX content.
  factory HexFileData.fromHexBytes(Uint8List rawBytes, String filePath, {int fillByte = 0xFF}) {
    final String name = p.basename(filePath);
    String content;
    try {
      content = utf8.decode(rawBytes);
    } catch (_) {
      content = String.fromCharCodes(rawBytes);
    }

    final List<String> lines = const LineSplitter().convert(content);
    final Map<int, int> tempAddressMap = {};

    int extendedSegmentAddress = 0;
    int extendedLinearAddress = 0;
    int minAddr = -1;
    int maxAddr = -1;

    for (int lineNum = 1; lineNum <= lines.length; lineNum++) {
      String line = lines[lineNum - 1].trim();
      if (line.isEmpty) continue;

      if (!line.startsWith(':')) {
        throw FormatException('第 $lineNum 行格式错误：Intel HEX 记录必须以冒号 (:) 开头');
      }

      // Read length
      if (line.length < 11) {
        throw FormatException('第 $lineNum 行格式错误：记录长度不足');
      }

      int byteCount = int.parse(line.substring(1, 3), radix: 16);
      int addressOffset = int.parse(line.substring(3, 7), radix: 16);
      int recordType = int.parse(line.substring(7, 9), radix: 16);

      int expectedLength = 1 + 2 + 4 + 2 + byteCount * 2 + 2;
      if (line.length < expectedLength) {
        throw FormatException('第 $lineNum 行数据长度与声明的字节数不匹配');
      }

      // Checksum validation
      int calculatedSum = byteCount + (addressOffset >> 8) + (addressOffset & 0xFF) + recordType;
      List<int> dataBytes = [];
      for (int i = 0; i < byteCount; i++) {
        int byteVal = int.parse(line.substring(9 + i * 2, 11 + i * 2), radix: 16);
        dataBytes.add(byteVal);
        calculatedSum += byteVal;
      }
      int checksumVal = int.parse(line.substring(9 + byteCount * 2, 11 + byteCount * 2), radix: 16);
      calculatedSum = (calculatedSum + checksumVal) & 0xFF;
      if (calculatedSum != 0) {
        throw FormatException('第 $lineNum 行格式错误：校验和 (Checksum) 验证失败');
      }

      // Process record types
      if (recordType == 0) {
        // Data Record
        int absBase = (extendedLinearAddress << 16) + (extendedSegmentAddress << 4) + addressOffset;
        for (int i = 0; i < byteCount; i++) {
          int targetAddr = absBase + i;
          tempAddressMap[targetAddr] = dataBytes[i];
          if (minAddr == -1 || targetAddr < minAddr) minAddr = targetAddr;
          if (maxAddr == -1 || targetAddr > maxAddr) maxAddr = targetAddr;
        }
      } else if (recordType == 1) {
        // End of File
        break;
      } else if (recordType == 2) {
        // Extended Segment Address
        if (byteCount != 2) {
          throw FormatException('第 $lineNum 行格式错误：段地址记录长度必须为 2 字节');
        }
        extendedSegmentAddress = (dataBytes[0] << 8) | dataBytes[1];
      } else if (recordType == 4) {
        // Extended Linear Address
        if (byteCount != 2) {
          throw FormatException('第 $lineNum 行格式错误：线性地址记录长度必须为 2 字节');
        }
        extendedLinearAddress = (dataBytes[0] << 8) | dataBytes[1];
      }
      // Type 3 and 5 are start addresses, which we can safely ignore for hex viewing
    }

    if (tempAddressMap.isEmpty) {
      return HexFileData(
        filePath: filePath,
        fileName: name,
        baseAddress: 0,
        bytes: Uint8List(0),
        absoluteAddressMap: const {},
        isHexFormat: true,
        isContiguous: false,
      );
    }

    // Build contiguous bytes array
    int size = maxAddr - minAddr + 1;
    // Capped limit to prevent massive memory allocating (e.g. 50MB max contiguous size for UI safety)
    if (size > 50 * 1024 * 1024) {
      throw FormatException('Intel HEX 文件跨度过大 (${(size / 1024 / 1024).toStringAsFixed(2)}MB)，超过了 50MB 的限制。');
    }

    final Uint8List bytes = Uint8List(size);
    for (int i = 0; i < size; i++) {
      bytes[i] = tempAddressMap[minAddr + i] ?? fillByte;
    }

    return HexFileData(
      filePath: filePath,
      fileName: name,
      baseAddress: minAddr,
      bytes: bytes,
      absoluteAddressMap: tempAddressMap,
      isHexFormat: true,
      isContiguous: false,
    );
  }
}
