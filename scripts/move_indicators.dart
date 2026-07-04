// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:io';

void main() {
  File file = File('lib/modules/oscilloscope/widgets/chart_widget.dart');
  List<String> lines = file.readAsLinesSync();
  
  int startIdx = -1;
  int endIdx = -1;
  int insertIdx = -1;
  
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].contains('// Draggable 0V Indicators for each active channel') && startIdx == -1) {
      startIdx = i;
    }
    if (startIdx != -1 && lines[i].trim() == '})(),' && endIdx == -1) {
      endIdx = i;
    }
  }
  
  // Find the end of the Stack.
  // The Stack is inside `builder: (context, hash, child) { return Stack( ... children: [ ... ] ); }`
  // The end of `children: [` is followed by `],` at the indentation level of `children: [`.
  // Looking around line 908.
  for (int i = startIdx; i < lines.length; i++) {
    if (lines[i].trim() == '],') {
      if (lines[i+1].trim() == '];') continue; // Not this one (it's inside some inner return)
      if (lines[i+1].trim() == ')' || lines[i+1].trim() == ');' || lines[i+1].trim() == '],' && lines[i+2].trim() == ');') {
         // This is likely the end of the Stack's children array
         insertIdx = i;
         break;
      }
    }
  }
  
  if (startIdx != -1 && endIdx != -1 && insertIdx != -1) {
    List<String> block = lines.sublist(startIdx, endIdx + 1);
    lines.removeRange(startIdx, endIdx + 1);
    
    int newInsertIdx = insertIdx - block.length;
    lines.insertAll(newInsertIdx, block);
    
    file.writeAsStringSync(lines.join('\n') + '\n');
    print('Successfully moved block from lines $startIdx-$endIdx to before line $insertIdx.');
  } else {
    print('Failed to find indices. start: $startIdx, end: $endIdx, insert: $insertIdx');
  }
}
