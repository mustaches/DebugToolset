// ignore_for_file: avoid_print
import 'dart:io';

void main() {
  File file = File('lib/modules/oscilloscope/widgets/register_info_panel.dart');
  String content = file.readAsStringSync();

  // Replace Hex Dump highlight logic
  String oldHexHighlight = '''
                                 int pStart = payloadStartIndices[dataIndex];
                                 bool isHighlighted = (pStart == state.highlightedStartIndex);
''';
  String newHexHighlight = '''
                                 int pStart = payloadStartIndices[dataIndex];
                                 bool isHighlighted = false;
                                 if (state.highlightedStartIndex != null && state.highlightedEndIndex != null) {
                                   isHighlighted = pStart >= state.highlightedStartIndex! && pStart <= state.highlightedEndIndex!;
                                 }
''';

  // Replace UART highlight logic
  String oldUartHighlight = '''
      int pStart = payloadStartIndices[i];
      bool isHighlighted = (pStart == state.highlightedStartIndex);
''';
  String newUartHighlight = '''
      int pStart = payloadStartIndices[i];
      bool isHighlighted = false;
      if (state.highlightedStartIndex != null && state.highlightedEndIndex != null) {
        isHighlighted = pStart >= state.highlightedStartIndex! && pStart <= state.highlightedEndIndex!;
      }
''';

  bool success = true;

  if (content.contains(oldHexHighlight)) {
    content = content.replaceFirst(oldHexHighlight, newHexHighlight);
    print('Replaced Hex Dump highlight logic.');
  } else {
    print('Failed to find Hex Dump highlight logic!');
    success = false;
  }

  if (content.contains(oldUartHighlight)) {
    content = content.replaceFirst(oldUartHighlight, newUartHighlight);
    print('Replaced UART highlight logic.');
  } else {
    print('Failed to find UART highlight logic!');
    success = false;
  }

  if (success) {
    file.writeAsStringSync(content);
    print('Updated register_info_panel.dart successfully.');
  }
}
