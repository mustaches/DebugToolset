import 'dart:io';

/// The kind of change a single diff line represents.
enum DiffOperation { equal, insert, delete }

/// A single line in a side-by-side diff view.
class DiffLine {
  final DiffOperation operation;
  final String text;
  final int? originalLineNumber;
  final int? modifiedLineNumber;

  DiffLine({
    required this.operation,
    required this.text,
    this.originalLineNumber,
    this.modifiedLineNumber,
  });

  bool get isEqual => operation == DiffOperation.equal;
  bool get isInsert => operation == DiffOperation.insert;
  bool get isDelete => operation == DiffOperation.delete;
}

/// A hunk inside a unified diff patch.
class _PatchHunk {
  final int originalStart;
  final int originalCount;
  final int modifiedStart;
  final int modifiedCount;
  final List<String> lines;

  _PatchHunk({
    required this.originalStart,
    required this.originalCount,
    required this.modifiedStart,
    required this.modifiedCount,
    required this.lines,
  });
}

class _DiffRange {
  final int start;
  final int end;
  _DiffRange(this.start, this.end);
}

/// Computes a line-based diff between [original] and [modified] using a simple
/// LCS (Longest Common Subsequence) algorithm.
///
/// The returned [DiffLine] list is suitable for rendering a side-by-side view:
/// deletions are paired with blank modified lines, insertions are paired with
/// blank original lines, and equal lines appear on both sides.
List<DiffLine> computeDiff(List<String> original, List<String> modified) {
  final n = original.length;
  final m = modified.length;

  // LCS table. lcs[i][j] = length of LCS of original[0..i-1] and modified[0..j-1].
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));

  for (int i = 1; i <= n; i++) {
    for (int j = 1; j <= m; j++) {
      if (original[i - 1] == modified[j - 1]) {
        lcs[i][j] = lcs[i - 1][j - 1] + 1;
      } else {
        lcs[i][j] = lcs[i - 1][j] > lcs[i][j - 1] ? lcs[i - 1][j] : lcs[i][j - 1];
      }
    }
  }

  // Backtrack to build the diff.
  final reversedDiff = <DiffLine>[];
  int i = n;
  int j = m;
  int originalLine = n;
  int modifiedLine = m;

  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && original[i - 1] == modified[j - 1]) {
      reversedDiff.add(DiffLine(
        operation: DiffOperation.equal,
        text: original[i - 1],
        originalLineNumber: originalLine,
        modifiedLineNumber: modifiedLine,
      ));
      i--;
      j--;
      originalLine--;
      modifiedLine--;
    } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
      reversedDiff.add(DiffLine(
        operation: DiffOperation.insert,
        text: modified[j - 1],
        modifiedLineNumber: modifiedLine,
      ));
      j--;
      modifiedLine--;
    } else {
      reversedDiff.add(DiffLine(
        operation: DiffOperation.delete,
        text: original[i - 1],
        originalLineNumber: originalLine,
      ));
      i--;
      originalLine--;
    }
  }

  return reversedDiff.reversed.toList();
}

/// Generates a unified diff patch from [original] and [modified].
///
/// The output follows the standard unified diff format:
///
///     --- original.txt
///     +++ modified.txt
///     @@ -1,3 +1,3 @@
///      context
///     -deleted
///     +inserted
///      context
///
/// [contextLines] controls how many unchanged lines are included around each
/// hunk.
String generateUnifiedDiff(
  List<String> original,
  List<String> modified, {
  String originalLabel = '--- original',
  String modifiedLabel = '+++ modified',
  int contextLines = 3,
}) {
  final diff = computeDiff(original, modified);
  if (diff.isEmpty) return '';

  final buffer = StringBuffer();
  buffer.writeln(originalLabel);
  buffer.writeln(modifiedLabel);

  // Collect indices of changed lines, then build hunk ranges with surrounding
  // context. Adjacent/overlapping ranges are merged.
  final changeIndices = <int>[];
  for (int i = 0; i < diff.length; i++) {
    if (!diff[i].isEqual) changeIndices.add(i);
  }

  final ranges = <_DiffRange>[];
  for (final idx in changeIndices) {
    final start = (idx - contextLines).clamp(0, diff.length - 1);
    final end = (idx + contextLines).clamp(0, diff.length - 1);
    if (ranges.isNotEmpty && start <= ranges.last.end + 1) {
      ranges.last = _DiffRange(ranges.last.start, end);
    } else {
      ranges.add(_DiffRange(start, end));
    }
  }

  for (final range in ranges) {
    final hunk = diff.sublist(range.start, range.end + 1);

    // Find the first non-null line number on each side to determine the hunk
    // header. If the hunk starts with inserts/deletes only, start at 0.
    int? originalStart;
    int? modifiedStart;
    for (final line in hunk) {
      if (originalStart == null && line.originalLineNumber != null) {
        originalStart = line.originalLineNumber! - 1;
      }
      if (modifiedStart == null && line.modifiedLineNumber != null) {
        modifiedStart = line.modifiedLineNumber! - 1;
      }
    }

    final originalStart0 = originalStart ?? 0;
    final modifiedStart0 = modifiedStart ?? 0;

    int originalCount = 0;
    int modifiedCount = 0;
    for (final line in hunk) {
      if (line.isEqual || line.isDelete) originalCount++;
      if (line.isEqual || line.isInsert) modifiedCount++;
    }

    final originalHeaderStart = originalCount == 0 ? 0 : originalStart0 + 1;
    final modifiedHeaderStart = modifiedCount == 0 ? 0 : modifiedStart0 + 1;

    buffer.writeln('@@ -$originalHeaderStart,$originalCount +$modifiedHeaderStart,$modifiedCount @@');

    for (final line in hunk) {
      if (line.isEqual) {
        buffer.writeln(' ${line.text}');
      } else if (line.isDelete) {
        buffer.writeln('-${line.text}');
      } else if (line.isInsert) {
        buffer.writeln('+${line.text}');
      }
    }
  }

  return buffer.toString();
}

/// Applies a unified diff [patchContent] to the contents of [targetFilePath]
/// and writes the result to [outputFilePath].
///
/// The patch is applied line-by-line using the context lines inside each hunk.
/// If the context does not match, an exception is thrown.
Future<void> applyUnifiedDiffPatch(
  String targetFilePath,
  String patchContent,
  String outputFilePath,
) async {
  final targetLines = (await File(targetFilePath).readAsString()).split('\n');

  final hunks = _parsePatchHunks(patchContent);
  final result = List<String>.from(targetLines);

  // Apply hunks from bottom to top so line numbers remain valid after each
  // modification.
  hunks.sort((a, b) => b.originalStart.compareTo(a.originalStart));

  for (final hunk in hunks) {
    _applyHunk(result, hunk);
  }

  final output = result.join('\n');
  await File(outputFilePath).writeAsString(output);
}

/// Parses a unified diff string into a list of hunks.
List<_PatchHunk> _parsePatchHunks(String patchContent) {
  final hunks = <_PatchHunk>[];
  final lines = patchContent.split('\n');

  int i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.startsWith('@@')) {
      // Parse hunk header: @@ -start,count +start,count @@
      final match = RegExp(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@').firstMatch(line);
      if (match == null) {
        throw FormatException('无法解析 hunk 头: $line');
      }

      final originalStart = int.parse(match.group(1)!);
      final originalCount = int.parse(match.group(2) ?? '1');
      final modifiedStart = int.parse(match.group(3)!);
      final modifiedCount = int.parse(match.group(4) ?? '1');

      final hunkLines = <String>[];
      i++;
      while (i < lines.length && !lines[i].startsWith('@@')) {
        hunkLines.add(lines[i]);
        i++;
      }

      hunks.add(_PatchHunk(
        originalStart: originalStart,
        originalCount: originalCount,
        modifiedStart: modifiedStart,
        modifiedCount: modifiedCount,
        lines: hunkLines,
      ));
    } else {
      i++;
    }
  }

  return hunks;
}

/// Applies a single hunk to [result].
void _applyHunk(List<String> result, _PatchHunk hunk) {
  // Convert 1-indexed start to 0-indexed position in result.
  int pos = hunk.originalStart - 1;
  if (pos < 0) pos = 0;

  // Walk through the hunk lines, verifying context and applying changes.
  for (final line in hunk.lines) {
    if (line.isEmpty) continue;
    final marker = line[0];
    final content = line.substring(1);

    if (marker == ' ') {
      // Context line must match.
      if (pos >= result.length || result[pos] != content) {
        throw Exception('补丁上下文不匹配：期望 "$content"，实际 "${pos < result.length ? result[pos] : '<EOF>'}"');
      }
      pos++;
    } else if (marker == '-') {
      // Deleted line must match.
      if (pos >= result.length || result[pos] != content) {
        throw Exception('补丁删除行不匹配：期望 "$content"，实际 "${pos < result.length ? result[pos] : '<EOF>'}"');
      }
      result.removeAt(pos);
    } else if (marker == '+') {
      // Inserted line.
      result.insert(pos, content);
      pos++;
    } else if (marker == '\\') {
      // "\ No newline at end of file" marker, ignore.
    } else {
      // Unknown marker, ignore.
    }
  }
}

/// Splits [text] into lines while preserving trailing empty lines.
List<String> splitLines(String text) {
  if (text.isEmpty) return [];
  return text.split('\n');
}


/// Reverses a unified diff patch so that applying it to the patched file
/// restores the original file.
///
/// The reversal swaps the `---` and `+++` file headers, swaps the line-number
/// ranges in each hunk header, and exchanges `-` and `+` lines within hunks.
String reverseUnifiedDiffPatch(String patchContent) {
  final lines = patchContent.split('\n');
  final buffer = StringBuffer();

  for (final line in lines) {
    if (line.startsWith('---')) {
      // Swap original file marker to modified file marker.
      buffer.writeln('+++${line.substring(3)}');
    } else if (line.startsWith('+++')) {
      // Swap modified file marker to original file marker.
      buffer.writeln('---${line.substring(3)}');
    } else if (line.startsWith('@@')) {
      // Parse hunk header and swap original/modified ranges.
      final match = RegExp(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@').firstMatch(line);
      if (match != null) {
        final originalStart = match.group(1)!;
        final originalCount = match.group(2) ?? '1';
        final modifiedStart = match.group(3)!;
        final modifiedCount = match.group(4) ?? '1';
        buffer.writeln('@@ -$modifiedStart,$modifiedCount +$originalStart,$originalCount @@');
      } else {
        buffer.writeln(line);
      }
    } else if (line.startsWith('-')) {
      // Deletion becomes insertion.
      buffer.writeln('+${line.substring(1)}');
    } else if (line.startsWith('+')) {
      // Insertion becomes deletion.
      buffer.writeln('-${line.substring(1)}');
    } else {
      // Context, comments and other markers stay unchanged.
      buffer.writeln(line);
    }
  }

  return buffer.toString();
}

/// Reverts a previously applied patch: reads [patchFilePath], reverses it, and
/// applies the reversed patch to [targetFilePath], writing the result to
/// [outputFilePath].
///
/// [targetFilePath] should be the already-patched file; the output will be
/// the file in its pre-patch state.
Future<void> revertUnifiedDiffPatch(
  String targetFilePath,
  String patchFilePath,
  String outputFilePath,
) async {
  final patchContent = await File(patchFilePath).readAsString();
  final reversedPatch = reverseUnifiedDiffPatch(patchContent);
  await applyUnifiedDiffPatch(targetFilePath, reversedPatch, outputFilePath);
}
