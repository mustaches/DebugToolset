// ignore_for_file: avoid_print
import 'dart:io';

void main() {
  File file = File('lib/modules/oscilloscope/widgets/packet_list_panel.dart');
  String content = file.readAsStringSync();

  String oldPacketHighlight = '''
                              bool isHighlighted = state.highlightedBusName == widget.busName && 
                                                   state.highlightedStartIndex == packet.startIndex && 
                                                   state.highlightedEndIndex == packet.endIndex;
''';

  String newPacketHighlight = '''
                              bool isHighlighted = false;
                              if (state.highlightedBusName == widget.busName && state.highlightedStartIndex != null && state.highlightedEndIndex != null) {
                                  isHighlighted = packet.startIndex >= state.highlightedStartIndex! && packet.endIndex <= state.highlightedEndIndex!;
                              }
''';

  if (content.contains(oldPacketHighlight)) {
    content = content.replaceFirst(oldPacketHighlight, newPacketHighlight);
    file.writeAsStringSync(content);
    print('Updated packet_list_panel.dart successfully.');
  } else {
    print('Failed to find the packet highlight logic in packet_list_panel.dart.');
  }
}
