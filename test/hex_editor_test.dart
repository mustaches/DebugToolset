import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:debug_tool_set/modules/hex_editor/models/hex_file_data.dart';
import 'package:debug_tool_set/providers/hex_editor_state.dart';

void main() {
  group('Intel HEX Parser Tests', () {
    test('Parse simple valid Intel HEX with linear base', () {
      // Mock hex file contents:
      // Line 1: Extended Linear Address (type 04), sets base to 0x08000000 (0x0800 in hex)
      // :020000040800F2
      // Line 2: Data Record (type 00), 4 bytes at offset 0x0010: [0xAA, 0xBB, 0xCC, 0xDD]
      // Byte Count: 04, Addr: 0010, Type: 00, Data: AABBCCDD, Chk: 04 + 00 + 10 + 00 + AA + BB + CC + DD = 802 (0x322) -> chk = (~0x22 + 1) & 0xFF = 0xDE
      // :04001000AABBCCDDDE
      // Line 3: End of File (type 01)
      // :00000001FF
      final hexString = ':020000040800F2\r\n:04001000AABBCCDDDE\r\n:00000001FF';
      final rawBytes = Uint8List.fromList(hexString.codeUnits);

      final fileData = HexFileData.fromHexBytes(rawBytes, 'test.hex');

      expect(fileData.isHexFormat, isTrue);
      expect(fileData.baseAddress, equals(0x08000010));
      expect(fileData.bytes.length, equals(4));
      expect(fileData.bytes[0], equals(0xAA));
      expect(fileData.bytes[1], equals(0xBB));
      expect(fileData.bytes[2], equals(0xCC));
      expect(fileData.bytes[3], equals(0xDD));
      expect(fileData.absoluteAddressMap[0x08000010], equals(0xAA));
      expect(fileData.absoluteAddressMap[0x08000013], equals(0xDD));
    });

    test('Parse Intel HEX with gaps and fill byte', () {
      // Line 1: Data Record (type 00) at offset 0x0000: [0x11, 0x22]
      // Checksum: 02 + 00 + 00 + 00 + 11 + 22 = 0x35 -> chk = (~0x35 + 1) & 0xFF = 0xCB
      // :020000001122CB
      // Line 2: Data Record (type 00) at offset 0x0005: [0x55]
      // Checksum: 01 + 00 + 05 + 00 + 55 = 0x5B -> chk = (~0x5B + 1) & 0xFF = 0xA5
      // :0100050055A5
      // Line 3: End of File (type 01)
      // :00000001FF
      final hexString = ':020000001122CB\r\n:0100050055A5\r\n:00000001FF';
      final rawBytes = Uint8List.fromList(hexString.codeUnits);

      final fileData = HexFileData.fromHexBytes(rawBytes, 'test.hex', fillByte: 0x99);

      expect(fileData.baseAddress, equals(0));
      expect(fileData.bytes.length, equals(6)); // Spans from 0x00 to 0x05 (size 6)
      expect(fileData.bytes[0], equals(0x11));
      expect(fileData.bytes[1], equals(0x22));
      
      // Gaps filled with 0x99
      expect(fileData.bytes[2], equals(0x99));
      expect(fileData.bytes[3], equals(0x99));
      expect(fileData.bytes[4], equals(0x99));
      
      expect(fileData.bytes[5], equals(0x55));
    });

    test('Parser invalid checksum error detection', () {
      // Invalid checksum record (changed CB to CC)
      final hexString = ':020000001122CC\r\n:00000001FF';
      final rawBytes = Uint8List.fromList(hexString.codeUnits);

      expect(
        () => HexFileData.fromHexBytes(rawBytes, 'test.hex'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('File Merging Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hex_merge_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Merge two BIN files with configured address and gap', () async {
      final file1Path = p.join(tempDir.path, 'f1.bin');
      final file2Path = p.join(tempDir.path, 'f2.bin');
      final outputPath = p.join(tempDir.path, 'merged.bin');

      // Create two binary files
      await File(file1Path).writeAsBytes([0x01, 0x02]);
      await File(file2Path).writeAsBytes([0x08, 0x09]);

      final mergeItems = [
        MergeItem(
          filePath: file1Path,
          fileName: 'f1.bin',
          startAddress: 0x10, // Merge file 1 at address 0x10
          size: 2,
          isHex: false,
        ),
        MergeItem(
          filePath: file2Path,
          fileName: 'f2.bin',
          startAddress: 0x14, // Merge file 2 at address 0x14 (leaves gap 0x12, 0x13)
          size: 2,
          isHex: false,
        ),
      ];

      final editorState = HexEditorState();
      await editorState.mergeFiles(
        items: mergeItems,
        fillByte: 0xAA,
        outputPath: outputPath,
        asHex: false,
      );

      final mergedBytes = await File(outputPath).readAsBytes();

      // Span is from 0x10 to 0x15 (size 6)
      expect(mergedBytes.length, equals(6));
      expect(mergedBytes[0], equals(0x01)); // 0x10
      expect(mergedBytes[1], equals(0x02)); // 0x11
      expect(mergedBytes[2], equals(0xAA)); // 0x12 gap
      expect(mergedBytes[3], equals(0xAA)); // 0x13 gap
      expect(mergedBytes[4], equals(0x08)); // 0x14
      expect(mergedBytes[5], equals(0x09)); // 0x15
    });
  });

  group('Byte Offset Alignment Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hex_offset_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Per-side offsets change which bytes are compared', () async {
      final leftPath = p.join(tempDir.path, 'left.bin');
      final rightPath = p.join(tempDir.path, 'right.bin');

      // left:  [0x00, 0x11, 0x22, 0x33]
      // right: [0xFF, 0xEE, 0x22, 0x33]
      // With leftOffset=1, rightOffset=2:
      //   virtual 0: left[1]=0x11 vs right[2]=0x22 -> mismatch
      //   virtual 1: left[2]=0x22 vs right[3]=0x33 -> mismatch
      //   virtual 2: left[3]=0x33 vs right[4]=missing -> mismatch
      await File(leftPath).writeAsBytes([0x00, 0x11, 0x22, 0x33]);
      await File(rightPath).writeAsBytes([0xFF, 0xEE, 0x22, 0x33]);

      final state = HexEditorState();
      await state.loadLeftFile(leftPath);
      await state.loadRightFile(rightPath);

      await state.setLeftOffset(1);
      await state.setRightOffset(2);

      expect(state.alignByAbsoluteAddress, isFalse);
      expect(state.mismatchOffsets, equals({0, 1, 2}));
    });

    test('Offsets can align identical payloads at different positions', () async {
      final leftPath = p.join(tempDir.path, 'left.bin');
      final rightPath = p.join(tempDir.path, 'right.bin');

      // left:  [0xAA, 0xBB, 0xCC, 0xDD]
      // right: [0xFF, 0xAA, 0xBB, 0xCC, 0xDD]
      // With leftOffset=0, rightOffset=1 -> all 4 compared bytes match
      await File(leftPath).writeAsBytes([0xAA, 0xBB, 0xCC, 0xDD]);
      await File(rightPath).writeAsBytes([0xFF, 0xAA, 0xBB, 0xCC, 0xDD]);

      final state = HexEditorState();
      await state.loadLeftFile(leftPath);
      await state.loadRightFile(rightPath);

      await state.setLeftOffset(0);
      await state.setRightOffset(1);

      expect(state.mismatchOffsets, isEmpty);
    });

    test('Sync address respects per-side offsets', () async {
      final leftPath = p.join(tempDir.path, 'left.bin');
      final rightPath = p.join(tempDir.path, 'right.bin');

      await File(leftPath).writeAsBytes([0x00, 0x11, 0x22, 0x33]);
      await File(rightPath).writeAsBytes([0xFF, 0xEE, 0x22, 0x33]);

      final state = HexEditorState();
      await state.loadLeftFile(leftPath);
      await state.loadRightFile(rightPath);

      await state.setLeftOffset(1);
      await state.setRightOffset(2);

      // Click on left absolute address 0x01 (virtual offset 0)
      state.setSelectedAddress(true, 0x01);
      // Right sync address = base(0) + rightOffset(2) + virtual(0) = 0x02
      expect(state.selectedAddressRight, equals(0x02));

      // Click on right absolute address 0x03 (virtual offset 1)
      state.setSelectedAddress(false, 0x03);
      // Left sync address = base(0) + leftOffset(1) + virtual(1) = 0x02
      expect(state.selectedAddressLeft, equals(0x02));
    });

    test('Offset beyond file length marks missing side as mismatch', () async {
      final leftPath = p.join(tempDir.path, 'left.bin');
      final rightPath = p.join(tempDir.path, 'right.bin');

      await File(leftPath).writeAsBytes([0x00, 0x11]);
      await File(rightPath).writeAsBytes([0x00, 0x11]);

      final state = HexEditorState();
      await state.loadLeftFile(leftPath);
      await state.loadRightFile(rightPath);

      // Only left offset is beyond file length -> right side has data but left does not
      await state.setLeftOffset(10);

      expect(state.mismatchOffsets, equals({0, 1}));
    });

    test('Both offsets beyond file length results in empty comparison', () async {
      final leftPath = p.join(tempDir.path, 'left.bin');
      final rightPath = p.join(tempDir.path, 'right.bin');

      await File(leftPath).writeAsBytes([0x00, 0x11]);
      await File(rightPath).writeAsBytes([0x00, 0x11]);

      final state = HexEditorState();
      await state.loadLeftFile(leftPath);
      await state.loadRightFile(rightPath);

      await state.setLeftOffset(10);
      await state.setRightOffset(10);

      expect(state.mismatchOffsets, isEmpty);
    });

    test('Overwrite selection supports different sizes (insert/delete)', () async {
      final leftPath = p.join(tempDir.path, 'left.bin');
      final rightPath = p.join(tempDir.path, 'right.bin');

      // left selection: 3 bytes, right selection: 2 bytes
      await File(leftPath).writeAsBytes([0x00, 0x11, 0x22, 0x33, 0x44]);
      await File(rightPath).writeAsBytes([0xFF, 0xEE, 0xDD, 0xCC]);

      final state = HexEditorState();
      await state.loadLeftFile(leftPath);
      await state.loadRightFile(rightPath);

      // Disable sync scroll so the two selections stay independent during the test.
      state.toggleSyncScroll(false);
      state.setSelection(true, 0, 2);
      state.setSelection(false, 0, 1);

      state.overwriteSelection(true);

      // Right file becomes left[0..2] + right[2..3]
      expect(state.rightFile!.bytes, equals([0x00, 0x11, 0x22, 0xDD, 0xCC]));
      expect(state.getDisplayByte(false, 0), equals(0x00));
      expect(state.getDisplayByte(false, 1), equals(0x11));
      expect(state.getDisplayByte(false, 2), equals(0x22));
      expect(state.getDisplayByte(false, 3), equals(0xDD));
      // Selection on right updated to inserted range
      expect(state.selectionEndRight, equals(2));
    });
  });

  group('External File Change Detection Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hex_external_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Detects external content change and reloads', () async {
      final path = p.join(tempDir.path, 'watch.bin');
      await File(path).writeAsBytes([0x01, 0x02, 0x03, 0x04]);

      final state = HexEditorState();
      addTearDown(state.dispose);
      await state.loadLeftFile(path);

      expect(state.leftFileChangedExternally, isFalse);
      expect(state.leftFile?.bytes, equals([0x01, 0x02, 0x03, 0x04]));

      // Simulate external modification and force a different mtime.
      await File(path).writeAsBytes([0xAA, 0xBB, 0xCC, 0xDD]);
      await File(path).setLastModified(DateTime.now().add(const Duration(seconds: 1)));

      state.checkExternalChanges();

      expect(state.leftFileChangedExternally, isTrue);
      // In-memory bytes stay unchanged until the user reloads.
      expect(state.leftFile?.bytes, equals([0x01, 0x02, 0x03, 0x04]));

      await state.reloadFile(true);

      expect(state.leftFileChangedExternally, isFalse);
      expect(state.leftFile?.bytes, equals([0xAA, 0xBB, 0xCC, 0xDD]));
    });

    test('Ignore external change keeps in-memory bytes', () async {
      final path = p.join(tempDir.path, 'ignore.bin');
      await File(path).writeAsBytes([0x01, 0x02, 0x03]);

      final state = HexEditorState();
      addTearDown(state.dispose);
      await state.loadLeftFile(path);

      await File(path).writeAsBytes([0xFF, 0xFF, 0xFF]);
      await File(path).setLastModified(DateTime.now().add(const Duration(seconds: 1)));

      state.checkExternalChanges();
      expect(state.leftFileChangedExternally, isTrue);

      state.ignoreExternalChange(true);
      expect(state.leftFileChangedExternally, isFalse);
      expect(state.leftFile?.bytes, equals([0x01, 0x02, 0x03]));

      // Calling check again should not flag the same change.
      state.checkExternalChanges();
      expect(state.leftFileChangedExternally, isFalse);
    });

    test('Detects external size change', () async {
      final path = p.join(tempDir.path, 'resize.bin');
      await File(path).writeAsBytes([0x01, 0x02]);

      final state = HexEditorState();
      addTearDown(state.dispose);
      await state.loadLeftFile(path);

      await File(path).writeAsBytes([0x01, 0x02, 0x03, 0x04, 0x05]);
      await File(path).setLastModified(DateTime.now().add(const Duration(seconds: 1)));

      state.checkExternalChanges();
      expect(state.leftFileChangedExternally, isTrue);
    });

    test('Saving does not trigger external change flag', () async {
      final path = p.join(tempDir.path, 'save.bin');
      await File(path).writeAsBytes([0x01, 0x02, 0x03, 0x04]);

      final state = HexEditorState();
      addTearDown(state.dispose);
      await state.loadLeftFile(path);

      // Apply a single-byte edit and save.
      state.editByte(true, 0, 0x99);
      await state.saveFile(true);

      expect(state.leftFileChangedExternally, isFalse);
      final bytes = await File(path).readAsBytes();
      expect(bytes[0], equals(0x99));
    });
  });
}
