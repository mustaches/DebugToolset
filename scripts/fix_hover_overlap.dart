// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:io';

void main() {
  File file = File('lib/modules/oscilloscope/widgets/chart_widget.dart');
  List<String> lines = file.readAsLinesSync();
  
  bool inHoverSection = false;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].contains('List<Widget> indicators = [];')) {
      lines[i] = '              List<Widget> edgeWidgets = [];\n              List<Widget> inlineWidgets = [];';
    } else if (lines[i].contains('for (var bus in state.digitalChannel.buses) {')) {
      inHoverSection = false; // Reset for each bus
    } else if (lines[i].contains('// Add Hovers for Protocol Packets')) {
      inHoverSection = true; // Enter hover section for this bus
    } else if (lines[i].contains('return indicators;')) {
      lines[i] = '              return [...inlineWidgets, ...edgeWidgets];';
      break;
    } else if (lines[i].contains('indicators.add(')) {
      if (inHoverSection) {
        lines[i] = lines[i].replaceFirst('indicators.add(', 'inlineWidgets.add(');
      } else {
        lines[i] = lines[i].replaceFirst('indicators.add(', 'edgeWidgets.add(');
      }
    }
  }

  file.writeAsStringSync(lines.join('\n') + '\n');
  print('Fixed layering issue by splitting edgeWidgets and inlineWidgets.');
}
