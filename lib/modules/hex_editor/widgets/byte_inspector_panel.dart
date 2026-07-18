import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/hex_editor_state.dart';
import '../models/hex_file_data.dart';

class ByteInspectorPanel extends StatelessWidget {
  const ByteInspectorPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final leftFile = context.select<HexEditorState, HexFileData?>((s) => s.leftFile);
    final rightFile = context.select<HexEditorState, HexFileData?>((s) => s.rightFile);
    final selectedAddressLeft = context.select<HexEditorState, int?>((s) => s.selectedAddressLeft);
    final selectedAddressRight = context.select<HexEditorState, int?>((s) => s.selectedAddressRight);

    final hasLeftFile = leftFile != null;
    final hasRightFile = rightFile != null;

    // If no files are loaded at all, show a simple centralized prompt
    if (!hasLeftFile && !hasRightFile) {
      return Container(
        height: 110, // Reduced from 150
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Text(
            '请加载 BIN / HEX 文件并点击字节查看数值解析',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
        ),
      );
    }

    final hasLeftSelection = hasLeftFile && selectedAddressLeft != null;
    final hasRightSelection = hasRightFile && selectedAddressRight != null;

    return Container(
      height: 145, // Reduced from 175
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        border: Border(top: BorderSide(color: Color(0xFF333333))),
      ),
      child: Row(
        children: [
          // Left Column
          Expanded(
            child: _buildColumnContent(
              context,
              hasFile: hasLeftFile,
              hasSelection: hasLeftSelection,
              file: leftFile,
              address: selectedAddressLeft,
              sideName: '左侧',
            ),
          ),
          const VerticalDivider(width: 1, color: Color(0xFF333333)),
          // Right Column
          Expanded(
            child: _buildColumnContent(
              context,
              hasFile: hasRightFile,
              hasSelection: hasRightSelection,
              file: rightFile,
              address: selectedAddressRight,
              sideName: '右侧',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColumnContent(
    BuildContext context, {
    required bool hasFile,
    required bool hasSelection,
    required HexFileData? file,
    required int? address,
    required String sideName,
  }) {
    if (!hasFile) {
      return _buildEmptyPlaceholder('$sideName文件未加载');
    }
    if (!hasSelection) {
      return _buildEmptyPlaceholder('$sideName未选择字节');
    }
    return _buildInspectorColumn(
      context,
      title: '$sideName数值解析 (${file!.fileName})',
      file: file,
      address: address!,
    );
  }

  Widget _buildEmptyPlaceholder(String message) {
    return Container(
      alignment: Alignment.center,
      color: const Color(0xFF191919),
      child: Text(
        message,
        style: const TextStyle(
          color: Colors.grey,
          fontSize: 14,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Widget _buildInspectorColumn(
    BuildContext context, {
    required String title,
    required HexFileData file,
    required int address,
  }) {
    final int val = file.getByteAt(address, defaultValue: 0);

    // Prepare ByteData for endian conversion
    ByteData getBytes(int len) {
      final buffer = Uint8List(len);
      for (int i = 0; i < len; i++) {
        buffer[i] = file.getByteAt(address + i, defaultValue: 0);
      }
      return ByteData.sublistView(buffer);
    }

    final int8 = getBytes(1).getInt8(0);
    final uint8 = val;
    final int16LE = getBytes(2).getInt16(0, Endian.little);
    final uint16LE = getBytes(2).getUint16(0, Endian.little);
    final int16BE = getBytes(2).getInt16(0, Endian.big);
    final uint16BE = getBytes(2).getUint16(0, Endian.big);
    
    final int32LE = getBytes(4).getInt32(0, Endian.little);
    final uint32LE = getBytes(4).getUint32(0, Endian.little);
    final int32BE = getBytes(4).getInt32(0, Endian.big);
    final uint32BE = getBytes(4).getUint32(0, Endian.big);

    final binaryStr = val.toRadixString(2).padLeft(8, '0');
    final formattedBin = '${binaryStr.substring(0, 4)} ${binaryStr.substring(4)}';
    final asciiChar = (val >= 32 && val <= 126) ? String.fromCharCode(val) : '.';

    final localOffset = address - file.baseAddress;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), // Reduced vertical padding to 4
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '地址: 0x${address.toRadixString(16).toUpperCase().padLeft(8, '0')} (偏移: 0x${localOffset.toRadixString(16).toUpperCase().padLeft(8, '0')})',
                style: const TextStyle(color: Colors.grey, fontSize: 14, fontFamily: 'Consolas'),
              ),
            ],
          ),
          const SizedBox(height: 1), // Reduced spacing from 2
          Expanded(
            child: Table(
              columnWidths: const {
                0: FixedColumnWidth(115), // Category Column
                1: FlexColumnWidth(1.2),  // Column 1: Hex
                2: FlexColumnWidth(1.5),  // Column 2: Binary / Int
                3: FlexColumnWidth(1.4),  // Column 3: ASCII / Uint
                4: FlexColumnWidth(0.8),  // Column 4: Int8
                5: FlexColumnWidth(0.8),  // Column 5: Uint8
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                _buildTableRow(
                  '8位数据',
                  [
                    _buildItem('16进制', '0x${val.toRadixString(16).toUpperCase().padLeft(2, '0')}'),
                    _buildItem('二进制', formattedBin),
                    _buildItem('ASCII', asciiChar),
                    _buildItem('Int8', '$int8'),
                    _buildItem('Uint8', '$uint8'),
                  ],
                ),
                _buildTableRow(
                  '16位小端(LE)',
                  [
                    _buildItem('16进制', '0x${uint16LE.toRadixString(16).toUpperCase().padLeft(4, '0')}'),
                    _buildItem('Int16', '$int16LE'),
                    _buildItem('Uint16', '$uint16LE'),
                    const SizedBox.shrink(),
                    const SizedBox.shrink(),
                  ],
                ),
                _buildTableRow(
                  '16位大端(BE)',
                  [
                    _buildItem('16进制', '0x${uint16BE.toRadixString(16).toUpperCase().padLeft(4, '0')}'),
                    _buildItem('Int16', '$int16BE'),
                    _buildItem('Uint16', '$uint16BE'),
                    const SizedBox.shrink(),
                    const SizedBox.shrink(),
                  ],
                ),
                _buildTableRow(
                  '32位小端(LE)',
                  [
                    _buildItem('16进制', '0x${uint32LE.toRadixString(16).toUpperCase().padLeft(8, '0')}'),
                    _buildItem('Int32', '$int32LE'),
                    _buildItem('Uint32', '$uint32LE'),
                    const SizedBox.shrink(),
                    const SizedBox.shrink(),
                  ],
                ),
                _buildTableRow(
                  '32位大端(BE)',
                  [
                    _buildItem('16进制', '0x${uint32BE.toRadixString(16).toUpperCase().padLeft(8, '0')}'),
                    _buildItem('Int32', '$int32BE'),
                    _buildItem('Uint32', '$uint32BE'),
                    const SizedBox.shrink(),
                    const SizedBox.shrink(),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TableRow _buildTableRow(String category, List<Widget> cells) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 0.5), // Reduced vertical padding to 0.5
          child: Text(
            '$category:',
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...cells.map((cell) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 0.5), // Reduced vertical padding to 0.5
          child: cell,
        )),
      ],
    );
  }

  Widget _buildItem(String label, String value) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(color: Colors.grey, fontSize: 14),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontFamily: 'Consolas',
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
