import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/text_editor/utils/diff_utils.dart';
import 'package:debug_tool_set/modules/text_editor/utils/folder_diff.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('looksBinary', () {
    test('NUL byte means binary', () {
      expect(looksBinary(Uint8List.fromList([65, 0, 66])), isTrue);
    });
    test('plain text is not binary', () {
      expect(looksBinary(Uint8List.fromList('hello\nworld\n'.codeUnits)),
          isFalse);
    });
  });

  group('splitMultiFilePatch', () {
    test('splits sections and strips a/ b/ prefixes', () {
      final patch = '--- a/x.txt\n'
          '+++ b/x.txt\n'
          '@@ -1,1 +1,1 @@\n'
          '-old\n'
          '+new\n'
          '--- /dev/null\n'
          '+++ b/added.txt\n'
          '@@ -0,0 +1,1 @@\n'
          '+brand new\n';
      final sections = splitMultiFilePatch(patch);
      expect(sections, hasLength(2));
      expect(sections[0].originalPath, 'x.txt');
      expect(sections[0].modifiedPath, 'x.txt');
      expect(sections[1].originalPath, '/dev/null');
      expect(sections[1].modifiedPath, 'added.txt');
    });

    test('hunk content resembling file headers does not break the split', () {
      // Deleting a line "-- x" and inserting "++ y" produces body lines
      // that look exactly like --- / +++ section headers.
      final patch = generateUnifiedDiff(
        ['-- x', 'b'],
        ['++ y', 'b'],
        originalLabel: '--- a/f.txt',
        modifiedLabel: '+++ b/f.txt',
      );
      final sections = splitMultiFilePatch(patch);
      expect(sections, hasLength(1));
      expect(sections[0].originalPath, 'f.txt');
      // And the section still applies correctly.
      final result =
          applyUnifiedDiffToLines(['-- x', 'b'], sections[0].content);
      expect(result, ['++ y', 'b']);
    });
  });

  group('folder diff', () {
    late Directory tempRoot;
    late Directory dirA;
    late Directory dirB;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('folder_diff_test');
      dirA = Directory(p.join(tempRoot.path, 'A'))..createSync();
      dirB = Directory(p.join(tempRoot.path, 'B'))..createSync();
    });

    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    void write(Directory root, String rel, String content) {
      final file = File(p.join(root.path, rel));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    /// Builds a standard A/B pair:
    /// same.txt (unchanged), mod.txt (modified), old.txt (deleted),
    /// new.txt (added), bin.dat (binary), .git/ignored (ignored).
    void buildStandardTrees() {
      write(dirA, 'same.txt', 'identical\n');
      write(dirB, 'same.txt', 'identical\n');
      write(dirA, 'mod.txt', 'alpha\nbeta\ngamma\n');
      write(dirB, 'mod.txt', 'alpha\nBETA\ngamma\ndelta\n');
      write(dirA, 'old.txt', 'legacy\n');
      write(dirB, 'new.txt', 'fresh\ncontent\n');
      File(p.join(dirA.path, 'bin.dat'))
          .writeAsBytesSync([0, 1, 2, 3]);
      File(p.join(dirB.path, 'bin.dat'))
          .writeAsBytesSync([0, 1, 2, 4]);
      write(dirA, '.git/config', 'should be ignored\n');
      write(dirB, 'build/out.txt', 'should be ignored\n');
      write(dirA, 'sub/nested.txt', 'nested same\n');
      write(dirB, 'sub/nested.txt', 'nested same\n');
    }

    FolderDiffEntry? entryOf(List<FolderDiffEntry> entries, String rel) {
      for (final e in entries) {
        if (e.relativePath == rel) return e;
      }
      return null;
    }

    test('compareFolderTrees classifies every status and skips ignored dirs',
        () {
      buildStandardTrees();
      final entries = compareFolderTrees(dirA.path, dirB.path);

      expect(entryOf(entries, 'same.txt')?.status,
          FolderFileStatus.unchanged);
      expect(entryOf(entries, 'sub/nested.txt')?.status,
          FolderFileStatus.unchanged);
      expect(
          entryOf(entries, 'mod.txt')?.status, FolderFileStatus.modified);
      expect(entryOf(entries, 'mod.txt')?.diff, isNotNull);
      expect(entryOf(entries, 'old.txt')?.status, FolderFileStatus.deleted);
      expect(entryOf(entries, 'new.txt')?.status, FolderFileStatus.added);
      expect(entryOf(entries, 'bin.dat')?.status, FolderFileStatus.binary);
      expect(entryOf(entries, '.git/config'), isNull);
      expect(entryOf(entries, 'build/out.txt'), isNull);
    });

    test('generateFolderPatch emits git-style and /dev/null headers', () {
      buildStandardTrees();
      final entries = compareFolderTrees(dirA.path, dirB.path);
      final patch = generateFolderPatch(dirA.path, dirB.path, entries);

      expect(patch, contains('--- a/mod.txt'));
      expect(patch, contains('+++ b/mod.txt'));
      expect(patch, contains('--- a/old.txt'));
      expect(patch, contains('+++ /dev/null'));
      expect(patch, contains('--- /dev/null'));
      expect(patch, contains('+++ b/new.txt'));
      // Binary and unchanged files are excluded.
      expect(patch, isNot(contains('bin.dat')));
      expect(patch, isNot(contains('same.txt')));
    });

    test('apply + revert round-trip restores both trees', () async {
      buildStandardTrees();
      final entries = compareFolderTrees(dirA.path, dirB.path);
      final patch = generateFolderPatch(dirA.path, dirB.path, entries);
      final patchFile = File(p.join(tempRoot.path, 'change.patch'))
        ..writeAsStringSync(patch);

      // Copy A to target, apply -> should equal B (except binary file).
      final target = Directory(p.join(tempRoot.path, 'target'));
      _copyTree(dirA, target);

      final applied = await applyFolderPatch(patchFile.path, target.path);
      expect(applied, containsAll(['mod.txt', 'old.txt', 'new.txt']));

      expect(File(p.join(target.path, 'mod.txt')).readAsStringSync(),
          File(p.join(dirB.path, 'mod.txt')).readAsStringSync());
      expect(File(p.join(target.path, 'new.txt')).readAsStringSync(),
          File(p.join(dirB.path, 'new.txt')).readAsStringSync());
      expect(File(p.join(target.path, 'old.txt')).existsSync(), isFalse);

      // Revert -> back to A.
      await applyFolderPatch(patchFile.path, target.path, revert: true);
      expect(File(p.join(target.path, 'mod.txt')).readAsStringSync(),
          File(p.join(dirA.path, 'mod.txt')).readAsStringSync());
      expect(File(p.join(target.path, 'old.txt')).readAsStringSync(),
          File(p.join(dirA.path, 'old.txt')).readAsStringSync());
      expect(File(p.join(target.path, 'new.txt')).existsSync(), isFalse);
    });

    test('nested added file gets its parent directories created', () async {
      write(dirA, 'base.txt', 'v1\n');
      write(dirB, 'base.txt', 'v1\n');
      write(dirB, 'deep/sub/added.txt', 'deep file\n');

      final entries = compareFolderTrees(dirA.path, dirB.path);
      final patch = generateFolderPatch(dirA.path, dirB.path, entries);
      final patchFile = File(p.join(tempRoot.path, 'deep.patch'))
        ..writeAsStringSync(patch);

      final target = Directory(p.join(tempRoot.path, 'target'));
      _copyTree(dirA, target);
      await applyFolderPatch(patchFile.path, target.path);

      expect(
          File(p.join(target.path, 'deep', 'sub', 'added.txt'))
              .readAsStringSync(),
          'deep file\n');
    });

    test('context mismatch throws and leaves the target folder untouched',
        () async {
      buildStandardTrees();
      final entries = compareFolderTrees(dirA.path, dirB.path);
      final patch = generateFolderPatch(dirA.path, dirB.path, entries);
      final patchFile = File(p.join(tempRoot.path, 'change.patch'))
        ..writeAsStringSync(patch);

      final target = Directory(p.join(tempRoot.path, 'target'));
      _copyTree(dirA, target);
      // Corrupt the target so the mod.txt hunk context no longer matches.
      File(p.join(target.path, 'mod.txt'))
          .writeAsStringSync('completely\ndifferent\nfile\n');

      expect(
        () => applyFolderPatch(patchFile.path, target.path),
        throwsException,
      );
      // Two-phase guarantee: nothing was written — new.txt must not exist
      // and old.txt must not have been deleted even though they are valid.
      await Future<void>.delayed(Duration.zero); // let any async writes land
      expect(File(p.join(target.path, 'new.txt')).existsSync(), isFalse);
      expect(File(p.join(target.path, 'old.txt')).existsSync(), isTrue);
    });

    test('applying an already-applied added file fails cleanly', () async {
      buildStandardTrees();
      final entries = compareFolderTrees(dirA.path, dirB.path);
      final patch = generateFolderPatch(dirA.path, dirB.path, entries);
      final patchFile = File(p.join(tempRoot.path, 'change.patch'))
        ..writeAsStringSync(patch);

      final target = Directory(p.join(tempRoot.path, 'target'));
      _copyTree(dirA, target);
      await applyFolderPatch(patchFile.path, target.path);
      // Second apply: new.txt already exists -> exception, no changes.
      expect(
        () => applyFolderPatch(patchFile.path, target.path),
        throwsException,
      );
    });
  });
}

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true, followLinks: false)) {
    if (entity is File) {
      final rel = p.relative(entity.path, from: from.path);
      final dest = File(p.join(to.path, rel));
      dest.parent.createSync(recursive: true);
      entity.copySync(dest.path);
    }
  }
}
