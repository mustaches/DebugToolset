import 'dart:io';

void main() {
  File file = File('G:/DebugToolSet/lib/modules/oscilloscope/widgets/bottom_channel_bar.dart');
  String content = file.readAsStringSync();

  // Pattern 1: ...List.generate
  String oldPattern1 = "...List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i')))";
  String newPattern1 = '''...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D\$i'),
                                )
                              ))''';
                              
  // Pattern 2: items: List.generate
  String oldPattern2 = "items: List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i'))),";
  String newPattern2 = '''items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D\$i'),
                              )
                            )),''';

  content = content.replaceAll(oldPattern1, newPattern1);
  content = content.replaceAll(oldPattern2, newPattern2);

  file.writeAsStringSync(content);
}
