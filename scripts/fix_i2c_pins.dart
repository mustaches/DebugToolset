import 'dart:io';

void main() {
  File file = File('G:/DebugToolSet/lib/modules/oscilloscope/widgets/bottom_channel_bar.dart');
  String content = file.readAsStringSync();

  String oldPattern = '''                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Text('D\$i')
                            )),''';

  String newPattern = '''                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D\$i'),
                              )
                            )),''';

  content = content.replaceAll(oldPattern, newPattern);

  file.writeAsStringSync(content);
}
