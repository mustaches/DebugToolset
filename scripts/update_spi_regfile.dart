import 'dart:io';
import 'dart:convert';

void main() {
  File file = File('G:/DebugToolSet/DeviceProtocol/SPI/W25Q64JW.Regfile');
  String content = file.readAsStringSync();
  Map<String, dynamic> data = jsonDecode(content);

  List<String> cmdsWithAddr3 = [
    '0x03', '0x0B', '0x02', '0x3B', '0x6B', '0xBB', '0xEB', '0x32', 
    '0x92', '0x94', '0x77', '0x20', '0x52', '0xD8', '0x44', '0x42', 
    '0x48', '0x3D', '0x36', '0x39', '0x5A', '0x90'
  ];

  Map<String, dynamic> registers = data['registers'];
  
  for (String cmd in registers.keys) {
    if (cmdsWithAddr3.contains(cmd)) {
      registers[cmd]['addrBytes'] = 3;
    }
  }

  file.writeAsStringSync(jsonEncode(data));
}
