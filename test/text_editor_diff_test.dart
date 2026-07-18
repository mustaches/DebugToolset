import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/text_editor/utils/diff_utils.dart';

void main() {
  group('Diff utils', () {
    test('computeDiff detects insertions and deletions', () {
      final original = ['line1', 'line2', 'line3'];
      final modified = ['line1', 'line2 modified', 'line3', 'line4'];

      final diff = computeDiff(original, modified);

      expect(diff.any((l) => l.isDelete && l.text == 'line2'), isTrue);
      expect(diff.any((l) => l.isInsert && l.text == 'line2 modified'), isTrue);
      expect(diff.any((l) => l.isInsert && l.text == 'line4'), isTrue);
      expect(diff.where((l) => l.isEqual).length, 2); // line1 and line3
    });

    test('generateUnifiedDiff produces standard format', () {
      final original = ['a', 'b', 'c'];
      final modified = ['a', 'x', 'c'];

      final patch = generateUnifiedDiff(
        original,
        modified,
        originalLabel: '--- original.txt',
        modifiedLabel: '+++ modified.txt',
      );

      expect(patch, contains('--- original.txt'));
      expect(patch, contains('+++ modified.txt'));
      expect(patch, contains('@@ -1,3 +1,3 @@'));
      expect(patch, contains('-b'));
      expect(patch, contains('+x'));
    });

    test('reverseUnifiedDiffPatch restores the original file', () async {
      final tempDir = Directory.systemTemp.createTempSync('diff_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final originalFile = File('${tempDir.path}/original.txt');
      final modifiedFile = File('${tempDir.path}/modified.txt');
      final patchFile = File('${tempDir.path}/changes.patch');
      final revertedFile = File('${tempDir.path}/reverted.txt');

      await originalFile.writeAsString('line1\nline2\nline3\n');
      await modifiedFile.writeAsString('line1\nline2 modified\nline3\nline4\n');

      final original = (await originalFile.readAsString()).split('\n');
      final modified = (await modifiedFile.readAsString()).split('\n');
      final patch = generateUnifiedDiff(original, modified);
      await patchFile.writeAsString(patch);

      await revertUnifiedDiffPatch(
        modifiedFile.path,
        patchFile.path,
        revertedFile.path,
      );

      final result = await revertedFile.readAsString();
      expect(result, 'line1\nline2\nline3\n');
    });

    test('applyUnifiedDiffPatch round-trip preserves trailing newline', () async {
      final tempDir = Directory.systemTemp.createTempSync('diff_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final originalFile = File('${tempDir.path}/original.txt');
      final modifiedFile = File('${tempDir.path}/modified.txt');
      final patchFile = File('${tempDir.path}/changes.patch');
      final outputFile = File('${tempDir.path}/output.txt');

      // Both files end with a newline, which creates a trailing empty line in
      // the split result. This used to cause a context mismatch during patch
      // application.
      await originalFile.writeAsString('line1\nline2\nline3\n');
      await modifiedFile.writeAsString('line1\nline2 modified\nline3\nline4\n');

      final original = (await originalFile.readAsString()).split('\n');
      final modified = (await modifiedFile.readAsString()).split('\n');
      final patch = generateUnifiedDiff(original, modified);
      await patchFile.writeAsString(patch);

      await applyUnifiedDiffPatch(
        originalFile.path,
        await patchFile.readAsString(),
        outputFile.path,
      );

      final result = await outputFile.readAsString();
      expect(result, 'line1\nline2 modified\nline3\nline4\n');
    });

    test('applyUnifiedDiffPatch round-trip restores modified file', () async {
      final tempDir = Directory.systemTemp.createTempSync('diff_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final originalFile = File('${tempDir.path}/original.txt');
      final modifiedFile = File('${tempDir.path}/modified.txt');
      final patchFile = File('${tempDir.path}/changes.patch');
      final outputFile = File('${tempDir.path}/output.txt');

      await originalFile.writeAsString('line1\nline2\nline3');
      await modifiedFile.writeAsString('line1\nline2 modified\nline3\nline4');

      final original = (await originalFile.readAsString()).split('\n');
      final modified = (await modifiedFile.readAsString()).split('\n');
      final patch = generateUnifiedDiff(original, modified);
      await patchFile.writeAsString(patch);

      await applyUnifiedDiffPatch(
        originalFile.path,
        await patchFile.readAsString(),
        outputFile.path,
      );

      final result = await outputFile.readAsString();
      expect(result, 'line1\nline2 modified\nline3\nline4');
    });

    test('applyUnifiedDiffPatch handles insertions at start of file', () async {
      final tempDir = Directory.systemTemp.createTempSync('diff_test');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final originalFile = File('${tempDir.path}/original.txt');
      final patchFile = File('${tempDir.path}/changes.patch');
      final outputFile = File('${tempDir.path}/output.txt');

      await originalFile.writeAsString('b\nc');
      final original = (await originalFile.readAsString()).split('\n');
      final modified = ['a', 'b', 'c'];
      final patch = generateUnifiedDiff(original, modified);
      await patchFile.writeAsString(patch);

      await applyUnifiedDiffPatch(
        originalFile.path,
        await patchFile.readAsString(),
        outputFile.path,
      );

      final result = await outputFile.readAsString();
      expect(result, 'a\nb\nc');
    });
  });
}
