import 'dart:io';

void main() {
  File file = File('G:/DebugToolSet/lib/modules/oscilloscope/widgets/bottom_channel_bar.dart');
  String content = file.readAsStringSync();

  String sckBlock = '''
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('SCK 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiSckPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i'))),
                            onChanged: (v) => setState(() => spiSckPin = v!),
                          ),
                        ],
                      ),
''';

  String mosiBlock = '''
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('MOSI 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiMosiPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i')))
                            ],
                            onChanged: (v) => setState(() => spiMosiPin = v!),
                          ),
                        ],
                      ),
''';

  String misoBlock = '''
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('MISO 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiMisoPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i')))
                            ],
                            onChanged: (v) => setState(() => spiMisoPin = v!),
                          ),
                        ],
                      ),
''';

  String csBlock = '''
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CS 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiCsPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i')))
                            ],
                            onChanged: (v) => setState(() => spiCsPin = v!),
                          ),
                        ],
                      ),
''';

  String originalSequence = sckBlock + mosiBlock + misoBlock + csBlock;

  String newSckBlock = sckBlock.replaceAll("SCK 引脚: ", "SCLK 引脚: ");
  String newMosiBlock = mosiBlock.replaceAll("MOSI 引脚: ", "MOSI/IO0 引脚: ");
  String newMisoBlock = misoBlock.replaceAll("MISO 引脚: ", "MISO/IO1 引脚: ");
  String newCsBlock = csBlock;

  String newSequence = newCsBlock + newSckBlock + newMosiBlock + newMisoBlock;

  content = content.replaceAll(originalSequence, newSequence);

  file.writeAsStringSync(content);
}
