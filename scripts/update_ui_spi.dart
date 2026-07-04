import 'dart:io';

void main() {
  File file = File('G:/DebugToolSet/lib/modules/oscilloscope/widgets/bottom_channel_bar.dart');
  String content = file.readAsStringSync();
  
  // 1. Add variables to Edit dialog
  content = content.replaceAll(
    'int spiCsPin = -1;', 
    'int spiCsPin = -1;\n    int spiIo2Pin = -1;\n    int spiIo3Pin = -1;\n    String? spiProtocolFile;'
  );

  // 2. Initialize variables in Edit dialog
  content = content.replaceAll(
    'spiCsPin = (bus.decoder as SpiDecoder).csPin;',
    'spiCsPin = (bus.decoder as SpiDecoder).csPin;\n        spiIo2Pin = (bus.decoder as SpiDecoder).io2Pin;\n        spiIo3Pin = (bus.decoder as SpiDecoder).io3Pin;\n        spiProtocolFile = (bus.decoder as SpiDecoder).protocolFile;'
  );
  
  // 3. Update SpiDecoder instantiation in Edit dialog
  content = content.replaceAll(
    'csPin: spiCsPin, cpol: spiCpol, cpha: spiCpha, dataBits: spiDataBits, lsbFirst: spiLsbFirst',
    'csPin: spiCsPin, io2Pin: spiIo2Pin, io3Pin: spiIo3Pin, protocolFile: spiProtocolFile, cpol: spiCpol, cpha: spiCpha, dataBits: spiDataBits, lsbFirst: spiLsbFirst'
  );

  // 4. Add UI elements to Edit Dialog (and Add dialog)
  String uiToAdd = '''
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('IO2 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiIo2Pin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i')))
                            ],
                            onChanged: (v) => setState(() => spiIo2Pin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('IO3 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiIo3Pin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(value: i, child: Text('D\$i')))
                            ],
                            onChanged: (v) => setState(() => spiIo3Pin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('协议文件 (可选): ', style: TextStyle(color: Colors.white)),
                          DropdownButton<String?>(
                            value: spiProtocolFile,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: null, child: Text('无')),
                              ...state.loadedRegfiles.keys.map((k) => DropdownMenuItem(value: k, child: Text(k)))
                            ],
                            onChanged: (v) => setState(() => spiProtocolFile = v),
                          ),
                        ],
                      ),
''';

  // Find CS Pin UI block and append
  String csPinBlock = '''
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
  
  content = content.replaceAll(csPinBlock, csPinBlock + uiToAdd);
  
  // 5. Check if it was replaced in Add dialog as well
  // The Add dialog also uses `int spiCsPin = 3;` 
  content = content.replaceAll(
    'int spiCsPin = 3;',
    'int spiCsPin = 3;\n    int spiIo2Pin = -1;\n    int spiIo3Pin = -1;\n    String? spiProtocolFile;'
  );

  file.writeAsStringSync(content);
}
