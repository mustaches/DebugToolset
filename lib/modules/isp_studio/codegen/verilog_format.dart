String formatVerilogSource(String source, {int maxLineLength = 110}) {
  return source
      .split('\n')
      .expand(_splitVerilogStatements)
      .expand(_splitVerilogConnections)
      .expand((line) => _formatVerilogLine(line, maxLineLength))
      .join('\n');
}

List<String> _splitVerilogConnections(String line) {
  final trimmed = line.trimLeft();
  if (!trimmed.startsWith('.') || !line.contains(', ')) return [line];
  final indentation = line.substring(0, line.length - trimmed.length);
  final connections = <String>[];
  var start = 0;
  var depth = 0;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == '/' && index + 1 < line.length && line[index + 1] == '/') {
      break;
    }
    if (char == '(' || char == '[' || char == '{') depth++;
    if (char == ')' || char == ']' || char == '}') depth--;
    if (char == ',' && depth == 0) {
      final connection = line.substring(start, index + 1);
      connections.add(
        connections.isEmpty
            ? connection
            : '$indentation${connection.trimLeft()}',
      );
      start = index + 1;
    }
  }
  if (start < line.length) {
    final rest = line.substring(start);
    if (rest.trim().isNotEmpty) {
      if (connections.isEmpty) return [line];
      connections.add('$indentation${rest.trimLeft()}');
    }
  }
  return connections;
}

List<String> _splitVerilogStatements(String line) {
  if (line.trimLeft().startsWith('//') || !line.contains(';')) return [line];
  final statements = <String>[];
  final indentation = line.substring(0, line.length - line.trimLeft().length);
  var start = 0;
  var depth = 0;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == '/' && index + 1 < line.length && line[index + 1] == '/') {
      break;
    }
    if (char == '(' || char == '[' || char == '{') depth++;
    if (char == ')' || char == ']' || char == '}') depth--;
    if (char == ';' && depth == 0) {
      final statement = line.substring(start, index + 1);
      statements.add(
        statements.isEmpty ? statement : '$indentation${statement.trimLeft()}',
      );
      start = index + 1;
    }
  }
  if (start < line.length) {
    final rest = line.substring(start);
    if (rest.trim().isNotEmpty) {
      if (statements.isEmpty) return [line];
      statements.add('$indentation${rest.trimLeft()}');
    }
  }
  return statements;
}

List<String> _formatVerilogLine(String line, int maxLineLength) {
  if (line.length <= maxLineLength) return [line];
  final indentation = line.substring(0, line.length - line.trimLeft().length);
  final content = line.substring(indentation.length);
  line = '$indentation${_collapseWhitespaceOutsideStrings(content)}';
  final isComment = line.trimLeft().startsWith('//');
  final continuation = isComment ? '$indentation// ' : '$indentation  ';
  final output = <String>[];
  var remaining = line;
  while (remaining.length > maxLineLength) {
    var breakAt = -1;
    if (!isComment) {
      breakAt = _lastBreakBefore(remaining, '; ', maxLineLength);
      if (breakAt < 0) {
        breakAt = _lastBreakBefore(remaining, ', ', maxLineLength);
      }
      if (breakAt < 0) {
        breakAt = _lastOperatorBreakBefore(remaining, maxLineLength);
      }
    }
    if (breakAt < 0) {
      breakAt = _lastOutsideString(remaining, ' ', maxLineLength);
    }
    if (breakAt <= continuation.length) return [...output, remaining];
    output.add(remaining.substring(0, breakAt));
    remaining = continuation + remaining.substring(breakAt).trimLeft();
  }
  output.add(remaining);
  return output;
}

String _collapseWhitespaceOutsideStrings(String text) {
  final parts = text.split('"');
  return [
    for (var index = 0; index < parts.length; index++)
      index.isEven
          ? parts[index].replaceAll(RegExp(r'\s+'), ' ')
          : parts[index],
  ].join('"');
}

int _lastOperatorBreakBefore(String line, int limit) {
  var best = -1;
  for (final operator in ['>>>', '<<', '+', '?', ':']) {
    final index = _lastOutsideString(line, operator, limit);
    if (index > best) best = index;
  }
  return best;
}

int _lastBreakBefore(String line, String delimiter, int limit) {
  final index = _lastOutsideString(line, delimiter, limit);
  return index < 0 ? -1 : index + 1;
}

int _lastOutsideString(String line, String pattern, int limit) {
  var best = -1;
  var inString = false;
  var escaped = false;
  final last = limit < line.length ? limit : line.length - 1;
  for (var index = 0; index <= last; index++) {
    final char = line[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
    } else if (line.startsWith(pattern, index)) {
      best = index;
    }
  }
  return best;
}
