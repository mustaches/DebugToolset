import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/width_classify.dart';

/// Dumps classifyWidth() as compressed ranges: `start-end:class`.
void main() {
  int start = 0;
  var prev = classifyWidth(0);
  for (int cp = 1; cp <= 0x10FFFF; cp++) {
    final c = classifyWidth(cp);
    if (c != prev) {
      stdout.writeln(
          '${start.toRadixString(16)}-${(cp - 1).toRadixString(16)}:${prev.name}');
      start = cp;
      prev = c;
    }
  }
  stdout.writeln('${start.toRadixString(16)}-10ffff:${prev.name}');
}
