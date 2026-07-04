// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:io';

void main() {
  File file = File('lib/modules/oscilloscope/widgets/chart_widget.dart');
  List<String> lines = file.readAsLinesSync();
  
  int startIdx = -1;
  int endIdx = -1;
  
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].contains('// Draggable 0V Indicators for each active channel') && startIdx == -1) {
      startIdx = i;
    }
    if (startIdx != -1 && lines[i].trim() == '})(),' && endIdx == -1) {
      endIdx = i;
    }
  }
  
  if (startIdx != -1 && endIdx != -1) {
    List<String> block = lines.sublist(startIdx, endIdx + 1);
    lines.removeRange(startIdx, endIdx + 1);
    
    // Find the insertion point: right after the Info Panel Positioned closes.
    // The Info Panel ends with a Positioned which is closed by `),`.
    // Then there is a `],` for the Stack children.
    int insertIdx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].trim() == '],') {
        if (i + 1 < lines.length && lines[i+1].trim() == '],') {
          if (i + 2 < lines.length && lines[i+2].trim() == ');') {
            insertIdx = i;
            break;
          }
        }
      }
    }
    
    if (insertIdx != -1) {
      lines.insertAll(insertIdx, block);
      file.writeAsStringSync(lines.join('\n') + '\n');
      print('Fixed! Moved from $startIdx-$endIdx to $insertIdx');
    } else {
      print('Failed to find insertion point');
    }
  } else {
    print('Failed to find block. start: $startIdx, end: $endIdx');
  }
}
