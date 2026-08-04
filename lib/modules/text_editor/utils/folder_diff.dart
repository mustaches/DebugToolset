import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'diff_utils.dart';

/// How a file differs between the original and modified folder trees.
enum FolderFileStatus {
  /// Exists only in the modified tree.
  added,

  /// Exists only in the original tree.
  deleted,

  /// Present in both trees with different text content.
  modified,

  /// Present in both trees with identical bytes.
  unchanged,

  /// Present in both trees, differs, and looks like a binary file
  /// (skipped in patches).
  binary,
}

/// A single file's status in a folder-to-folder comparison.
class FolderDiffEntry {
  /// Forward-slash path relative to the compared root folders.
  final String relativePath;
  final FolderFileStatus status;

  /// Line diff of the two versions; only set for [FolderFileStatus.modified].
  final List<DiffLine>? diff;

  const FolderDiffEntry({
    required this.relativePath,
    required this.status,
    this.diff,
  });
}

/// Directory names skipped during folder comparison (VCS metadata, build
/// output and dependency trees that should never end up in a patch).
const kFolderDiffIgnoredDirs = {
  '.git',
  '.svn',
  'node_modules',
  '.dart_tool',
  'build',
};

/// Heuristic binary check: a NUL byte in the first bytes means binary.
bool looksBinary(Uint8List head) => head.contains(0);

/// Lists all files under [rootDir] as sorted forward-slash relative paths,
/// skipping [kFolderDiffIgnoredDirs]. Synchronous and self-contained so it
/// can run in a background isolate via `compute()`.
List<String> listFolderFiles(String rootDir) {
  final map = <String, String>{};
  _collectFiles(Directory(rootDir), rootDir, map);
  return map.keys.toList()..sort();
}

/// Reports progress while [compareFolderTrees] walks the file list:
/// [processed] of [total] files done; [relativePath] is the file just
/// processed, [pathA]/[pathB] its absolute path on each side (null when the
/// file does not exist on that side).
typedef FolderCompareProgress = void Function(
  int processed,
  int total,
  String relativePath,
  String? pathA,
  String? pathB,
);

/// Recursively compares the file trees under [dirA] (original) and [dirB]
/// (modified) and returns the per-file status list, sorted by relative path.
///
/// Synchronous and self-contained so it can run in a background isolate via
/// `compute()`. [onProgress] (when given) is invoked after each file.
List<FolderDiffEntry> compareFolderTrees(
  String dirA,
  String dirB, {
  FolderCompareProgress? onProgress,
}) {
  final mapA = <String, String>{};
  final mapB = <String, String>{};
  _collectFiles(Directory(dirA), dirA, mapA);
  _collectFiles(Directory(dirB), dirB, mapB);

  final allPaths = <String>{...mapA.keys, ...mapB.keys}.toList()..sort();
  final entries = <FolderDiffEntry>[];

  var processed = 0;
  for (final rel in allPaths) {
    final pathA = mapA[rel];
    final pathB = mapB[rel];

    if (pathA == null) {
      entries.add(FolderDiffEntry(
          relativePath: rel, status: FolderFileStatus.added));
    } else if (pathB == null) {
      entries.add(FolderDiffEntry(
          relativePath: rel, status: FolderFileStatus.deleted));
    } else {
      final bytesA = File(pathA).readAsBytesSync();
      final bytesB = File(pathB).readAsBytesSync();
      if (_bytesEqual(bytesA, bytesB)) {
        entries.add(FolderDiffEntry(
            relativePath: rel, status: FolderFileStatus.unchanged));
      } else if (looksBinary(_head(bytesA)) || looksBinary(_head(bytesB))) {
        entries.add(FolderDiffEntry(
            relativePath: rel, status: FolderFileStatus.binary));
      } else {
        final diff = computeDiffFast(
          splitLines(_decodeText(bytesA)),
          splitLines(_decodeText(bytesB)),
        );
        entries.add(FolderDiffEntry(
          relativePath: rel,
          status: FolderFileStatus.modified,
          diff: diff,
        ));
      }
    }
    processed++;
    onProgress?.call(processed, allPaths.length, rel, pathA, pathB);
  }

  return entries;
}

/// Generates a multi-file unified diff patch (git-style `a/`、`b/` headers)
/// from a comparison produced by [compareFolderTrees].
///
/// Added files use `--- /dev/null`, deleted files use `+++ /dev/null`.
/// Unchanged and binary entries are not included. Returns an empty string
/// when there is nothing to patch.
String generateFolderPatch(
  String dirA,
  String dirB,
  List<FolderDiffEntry> entries,
) {
  final buffer = StringBuffer();

  for (final entry in entries) {
    final rel = entry.relativePath;
    switch (entry.status) {
      case FolderFileStatus.modified:
        buffer.write(generateUnifiedDiff(
          splitLines(_readTextFile(p.join(dirA, _toNativePath(rel)))),
          splitLines(_readTextFile(p.join(dirB, _toNativePath(rel)))),
          originalLabel: '--- a/$rel',
          modifiedLabel: '+++ b/$rel',
        ));
        break;
      case FolderFileStatus.added:
        final newLines =
            splitLines(_readTextFile(p.join(dirB, _toNativePath(rel))));
        if (newLines.isEmpty) break; // empty new file: nothing to represent
        buffer.write(generateUnifiedDiff(
          const [],
          newLines,
          originalLabel: '--- /dev/null',
          modifiedLabel: '+++ b/$rel',
        ));
        break;
      case FolderFileStatus.deleted:
        final oldLines =
            splitLines(_readTextFile(p.join(dirA, _toNativePath(rel))));
        if (oldLines.isEmpty) break; // empty deleted file: nothing to represent
        buffer.write(generateUnifiedDiff(
          oldLines,
          const [],
          originalLabel: '--- a/$rel',
          modifiedLabel: '+++ /dev/null',
        ));
        break;
      case FolderFileStatus.unchanged:
      case FolderFileStatus.binary:
        break;
    }
  }

  return buffer.toString();
}

/// Applies the multi-file unified diff [patchPath] to the folder tree at
/// [targetDir], modifying files in place. With [revert] the patch is reversed
/// first, restoring the pre-patch state.
///
/// Two-phase: every section is parsed and verified against the current file
/// contents before anything is written — if any file's context does not
/// match, an exception is thrown and the target folder is left untouched.
///
/// Returns the relative paths of the files that were written, created or
/// deleted.
Future<List<String>> applyFolderPatch(
  String patchPath,
  String targetDir, {
  bool revert = false,
}) async {
  var patchContent = await File(patchPath).readAsString();
  if (revert) {
    patchContent = reverseUnifiedDiffPatch(patchContent);
  }
  final sections = splitMultiFilePatch(patchContent);
  if (sections.isEmpty) {
    throw Exception('补丁为空或无法解析');
  }

  // Phase 1: compute every result without touching the disk.
  final writes = <String, String>{}; // absolute path -> new content
  final deletes = <String>[]; // absolute paths to delete
  final processed = <String>[];

  for (final section in sections) {
    final isNewFile = section.originalPath == '/dev/null';
    final isDeleteFile = section.modifiedPath == '/dev/null';
    final rel = isDeleteFile ? section.originalPath : section.modifiedPath;
    final absPath = p.join(targetDir, _toNativePath(rel));
    final targetFile = File(absPath);

    final List<String> targetLines;
    if (isNewFile) {
      if (targetFile.existsSync()) {
        throw Exception('新增文件已存在: $rel');
      }
      targetLines = const [];
    } else {
      if (!targetFile.existsSync()) {
        throw Exception('目标文件不存在: $rel');
      }
      targetLines = splitLines(await targetFile.readAsString());
    }

    final result = applyUnifiedDiffToLines(targetLines, section.content);

    if (isDeleteFile) {
      if (result.join('\n').isNotEmpty) {
        throw Exception('删除文件后仍有残留内容: $rel');
      }
      deletes.add(absPath);
    } else {
      writes[absPath] = result.join('\n');
    }
    processed.add(rel);
  }

  // Phase 2: all sections verified — write everything.
  for (final entry in writes.entries) {
    final file = File(entry.key);
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  for (final path in deletes) {
    await File(path).delete();
  }

  return processed;
}

/// Recursively collects files under [dir] into [out], mapping
/// forward-slash relative paths to absolute paths.
void _collectFiles(Directory dir, String root, Map<String, String> out) {
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (kFolderDiffIgnoredDirs.contains(p.basename(entity.path))) continue;
      _collectFiles(entity, root, out);
    } else if (entity is File) {
      final rel = p.relative(entity.path, from: root).replaceAll('\\', '/');
      out[rel] = entity.path;
    }
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _head(Uint8List bytes, [int max = 8192]) {
  return bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);
}

String _decodeText(Uint8List bytes) =>
    utf8.decode(bytes, allowMalformed: true);

String _readTextFile(String path) =>
    _decodeText(File(path).readAsBytesSync());

/// Converts a forward-slash relative patch path to the local separator.
String _toNativePath(String rel) =>
    p.separator == '/' ? rel : rel.replaceAll('/', p.separator);
