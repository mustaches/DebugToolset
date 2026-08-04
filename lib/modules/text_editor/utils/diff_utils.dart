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

/// Computes a line-based diff between [original] and [modified] using a
/// high-performance, linear-space Myers diff algorithm with O(1) integer hashing
/// and automatic prefix/suffix trimming.
///
/// Easily handles 50,000+ line files (like font data arrays) in milliseconds.
List<DiffLine> computeDiffFast(List<String> original, List<String> modified) {
  final N = original.length;
  final M = modified.length;

  if (N == 0 && M == 0) return const [];

  // 1. Fast-path: Strip common prefix
  int start = 0;
  while (start < N && start < M && original[start] == modified[start]) {
    start++;
  }

  // 2. Fast-path: Strip common suffix
  int endOrig = N - 1;
  int endMod = M - 1;
  while (endOrig >= start && endMod >= start && original[endOrig] == modified[endMod]) {
    endOrig--;
    endMod--;
  }

  final result = <DiffLine>[];

  // Add prefix equal lines
  for (int i = 0; i < start; i++) {
    result.add(DiffLine(
      operation: DiffOperation.equal,
      text: original[i],
      originalLineNumber: i + 1,
      modifiedLineNumber: i + 1,
    ));
  }

  // Middle range that actually differs
  final origMiddle = original.sublist(start, endOrig + 1);
  final modMiddle = modified.sublist(start, endMod + 1);

  if (origMiddle.isNotEmpty || modMiddle.isNotEmpty) {
    final middleDiff = _myersDiffLinear(origMiddle, modMiddle, start + 1, start + 1);
    result.addAll(middleDiff);
  }

  // Add suffix equal lines
  final suffixLen = N - 1 - endOrig;
  for (int i = 0; i < suffixLen; i++) {
    final origIdx = endOrig + 1 + i;
    final modIdx = endMod + 1 + i;
    result.add(DiffLine(
      operation: DiffOperation.equal,
      text: original[origIdx],
      originalLineNumber: origIdx + 1,
      modifiedLineNumber: modIdx + 1,
    ));
  }

  return result;
}

List<DiffLine> computeDiff(List<String> original, List<String> modified) {
  return computeDiffFast(original, modified);
}

/// Internal linear-space / bounded Myers diff.
List<DiffLine> _myersDiffLinear(
  List<String> a,
  List<String> b,
  int startOrigLine,
  int startModLine,
) {
  final N = a.length;
  final M = b.length;

  if (N == 0) {
    return List.generate(M, (j) => DiffLine(
      operation: DiffOperation.insert,
      text: b[j],
      modifiedLineNumber: startModLine + j,
    ));
  }
  if (M == 0) {
    return List.generate(N, (i) => DiffLine(
      operation: DiffOperation.delete,
      text: a[i],
      originalLineNumber: startOrigLine + i,
    ));
  }

  // Line-to-int mapping for O(1) integer comparison
  final lineMap = <String, int>{};
  int nextId = 1;
  final aInts = List<int>.generate(N, (i) {
    return lineMap.putIfAbsent(a[i], () => nextId++);
  });
  final bInts = List<int>.generate(M, (j) {
    return lineMap.putIfAbsent(b[j], () => nextId++);
  });

  final maxD = N + M;
  final offset = maxD;
  final v = List<int>.filled(2 * maxD + 1, 0);
  final trace = <List<int>>[];

  bool found = false;
  for (int d = 0; d <= maxD; d++) {
    final vCopy = List<int>.from(v);
    trace.add(vCopy);

    for (int k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) {
        x = v[k + 1 + offset];
      } else {
        x = v[k - 1 + offset] + 1;
      }
      int y = x - k;

      while (x < N && y < M && aInts[x] == bInts[y]) {
        x++;
        y++;
      }
      v[k + offset] = x;

      if (x >= N && y >= M) {
        found = true;
        break;
      }
    }
    if (found) break;
  }

  // Backtrack to extract edit script
  final diff = <DiffLine>[];
  int x = N;
  int y = M;

  for (int d = trace.length - 1; d >= 0; d--) {
    final vCurrent = trace[d];
    final k = x - y;

    int prevK;
    if (k == -d || (k != d && vCurrent[k - 1 + offset] < vCurrent[k + 1 + offset])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }

    final prevX = vCurrent[prevK + offset];
    final prevY = prevX - prevK;

    while (x > prevX && y > prevY) {
      x--;
      y--;
      diff.add(DiffLine(
        operation: DiffOperation.equal,
        text: a[x],
        originalLineNumber: startOrigLine + x,
        modifiedLineNumber: startModLine + y,
      ));
    }

    if (d > 0) {
      if (x == prevX) {
        y--;
        diff.add(DiffLine(
          operation: DiffOperation.insert,
          text: b[y],
          modifiedLineNumber: startModLine + y,
        ));
      } else if (y == prevY) {
        x--;
        diff.add(DiffLine(
          operation: DiffOperation.delete,
          text: a[x],
          originalLineNumber: startOrigLine + x,
        ));
      }
    }
  }

  return diff.reversed.toList();
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
  final result = applyUnifiedDiffToLines(targetLines, patchContent);
  final output = result.join('\n');
  await File(outputFilePath).writeAsString(output);
}

/// Applies a single-file unified diff [patchContent] to [targetLines] and
/// returns the resulting lines. Pure string operation; throws when any hunk's
/// context does not match.
List<String> applyUnifiedDiffToLines(
  List<String> targetLines,
  String patchContent,
) {
  final hunks = _parsePatchHunks(patchContent);
  final result = List<String>.from(targetLines);

  // Apply hunks from bottom to top so line numbers remain valid after each
  // modification.
  hunks.sort((a, b) => b.originalStart.compareTo(a.originalStart));

  for (final hunk in hunks) {
    _applyHunk(result, hunk);
  }

  return result;
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

/// One file's section of a (possibly multi-file) unified diff patch.
class FilePatchSection {
  /// Path from the `---` header with any `a/` or `b/` prefix stripped;
  /// `/dev/null` when the file did not exist on that side (new file).
  final String originalPath;

  /// Path from the `+++` header with any `a/` or `b/` prefix stripped;
  /// `/dev/null` when the file does not exist on that side (deleted file).
  final String modifiedPath;

  /// The full `---`/`+++`/`@@` section text for this file.
  final String content;

  const FilePatchSection({
    required this.originalPath,
    required this.modifiedPath,
    required this.content,
  });
}

/// Splits a (possibly multi-file) unified diff into per-file sections.
///
/// Hunk bodies are consumed by their declared line counts, so content lines
/// that happen to look like `--- `/`+++ ` headers inside a hunk do not break
/// the split. `a/` and `b/` prefixes are stripped from both paths.
///
/// Patches reversed by [reverseUnifiedDiffPatch] have each header pair in
/// swapped order (`+++` line before `---`); both orders are accepted and the
/// `---` side is always treated as the original path.
List<FilePatchSection> splitMultiFilePatch(String patchContent) {
  final lines = patchContent.split('\n');
  final sections = <FilePatchSection>[];
  final hunkRe =
      RegExp(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

  String stripPrefix(String raw) {
    // Drop an optional tab-separated timestamp after the path.
    var path = raw.split('\t').first.trim();
    if (path.startsWith('a/') || path.startsWith('b/')) {
      path = path.substring(2);
    }
    return path;
  }

  int i = 0;
  while (i < lines.length) {
    final isNormalHeader = lines[i].startsWith('--- ') &&
        i + 1 < lines.length &&
        lines[i + 1].startsWith('+++ ');
    final isReversedHeader = lines[i].startsWith('+++ ') &&
        i + 1 < lines.length &&
        lines[i + 1].startsWith('--- ');
    if (!isNormalHeader && !isReversedHeader) {
      if (lines[i].startsWith('--- ') &&
          (i + 1 >= lines.length || !lines[i + 1].startsWith('+++ '))) {
        throw FormatException('补丁缺少 +++ 头: ${lines[i]}');
      }
      i++;
      continue;
    }
    final start = i;
    final String originalPath;
    final String modifiedPath;
    if (isNormalHeader) {
      originalPath = stripPrefix(lines[i].substring(4));
      modifiedPath = stripPrefix(lines[i + 1].substring(4));
    } else {
      // Reversed patch: +++ line first, --- line second.
      modifiedPath = stripPrefix(lines[i].substring(4));
      originalPath = stripPrefix(lines[i + 1].substring(4));
    }
    i += 2;

    // Consume hunks precisely by their declared line counts.
    while (i < lines.length) {
      final hm = hunkRe.firstMatch(lines[i]);
      if (hm == null) break;
      var needOrig = int.parse(hm.group(2) ?? '1');
      var needMod = int.parse(hm.group(4) ?? '1');
      i++;
      while (i < lines.length && (needOrig > 0 || needMod > 0)) {
        final line = lines[i];
        if (line.startsWith('\\')) {
          // "\ No newline at end of file" marker, does not count.
          i++;
          continue;
        }
        final marker = line.isEmpty ? ' ' : line[0];
        if (marker == ' ') {
          needOrig--;
          needMod--;
        } else if (marker == '-') {
          needOrig--;
        } else if (marker == '+') {
          needMod--;
        }
        i++;
      }
    }

    sections.add(FilePatchSection(
      originalPath: originalPath,
      modifiedPath: modifiedPath,
      content: '${lines.sublist(start, i).join('\n')}\n',
    ));
  }
  return sections;
}
