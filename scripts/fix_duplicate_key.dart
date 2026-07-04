// ignore_for_file: avoid_print
import 'dart:io';

void main() {
  File file = File('lib/modules/oscilloscope/widgets/packet_list_panel.dart');
  String content = file.readAsStringSync();

  // Remove the GlobalKey declaration
  content = content.replaceFirst('final GlobalKey _highlightKey = GlobalKey();\n', '');
  
  // Replace the key assignment
  String oldKeyAssignment = 'key: isHighlighted ? _highlightKey : null,';
  if (content.contains(oldKeyAssignment)) {
    content = content.replaceFirst(oldKeyAssignment, '');
    file.writeAsStringSync(content);
    print('Fixed Duplicate GlobalKey error successfully.');
  } else {
    print('Failed to find the key assignment in packet_list_panel.dart.');
  }
}
