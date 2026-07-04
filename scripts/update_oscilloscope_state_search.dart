// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:io';

void main() {
  File file = File('lib/providers/oscilloscope_state.dart');
  String content = file.readAsStringSync();

  // 1. Inject helper methods
  String helpers = '''
  List<int> getDetectedI2cDevices(DigitalBus bus) {
    if (bus.decoder == null || !bus.decoder!.isEnabled || bus.decoder!.name != 'I2C') return [];
    Set<int> addrs = {};
    for (var p in bus.decoder!.packets) {
       if (p.type == PacketType.address && p.rawValue != null) {
          addrs.add(p.rawValue!);
       }
    }
    var list = addrs.toList();
    list.sort();
    return list;
  }

  List<int> getDetectedI2cRegisters(DigitalBus bus, int deviceAddress) {
    if (bus.decoder == null || !bus.decoder!.isEnabled || bus.decoder!.name != 'I2C') return [];
    Set<int> regs = {};
    for (var frame in bus.decoder!.frames) {
       int? currentAddr;
       bool isWrite = false;
       for (int i = 0; i < frame.packets.length; i++) {
          var p = frame.packets[i];
          if (p.type == PacketType.address) {
             currentAddr = p.rawValue;
             if (i + 1 < frame.packets.length && frame.packets[i+1].type == PacketType.readWrite) {
                 isWrite = frame.packets[i+1].data == 'WRITE';
                 i++; // Skip RW packet
             }
          } else if (p.type == PacketType.data && currentAddr == deviceAddress) {
             if (isWrite && p.rawValue != null) {
                 regs.add(p.rawValue!);
                 break; 
             }
          }
       }
    }
    var list = regs.toList();
    list.sort();
    return list;
  }
''';

  if (!content.contains('getDetectedI2cDevices')) {
    content = content.replaceFirst('  void clearSearchMatches() {', helpers + '\n  void clearSearchMatches() {');
  }

  // 2. Modify searchAdvancedBusValue signature and logic
  // Original signature starts at:
  // int searchAdvancedBusValue({
  //   required DigitalBus bus,
  //   required String format,
  //   ...
  // }) {
  
  // We want to replace the whole `int searchAdvancedBusValue({ ... }) { ... }` block.
  // Actually, rewriting it via regex or substring is risky. Let's find the start and the end.
  int startIndex = content.indexOf('  int searchAdvancedBusValue({');
  int endIndex = content.indexOf('  void forceUpdate() {', startIndex);
  if (startIndex != -1 && endIndex != -1) {
    String newFunction = '''
  int searchAdvancedBusValue({
    required DigitalBus bus,
    required String format, 
    required String targetValueStr,
    required bool isBigEndian, 
    required String condition, 
    required String channel, 
    String? i2cFrameType, // 'Any', 'Write Only', 'Read Only'
    int? i2cDeviceAddress,
    int? i2cRegisterAddress,
  }) {
    searchMatches.clear();
    currentSearchMatchIndex = -1;
    if (digitalChannel.count == 0 || _sampleRate <= 0) return 0;

    List<int> targetSequence = [];
    if (format == 'ASCII') {
       for (int i = 0; i < targetValueStr.length; i++) {
          targetSequence.add(targetValueStr.codeUnitAt(i));
       }
    } else {
       String input = targetValueStr.trim();
       if (input.isNotEmpty && condition != 'Error') {
         List<String> parts = input.split(RegExp(r'\\s+'));
         for (String part in parts) {
           try {
             if (format == 'Hex' && !part.toLowerCase().startsWith('0x')) {
               part = '0x' + part;
             }
             if (part.toLowerCase().startsWith('0x')) {
               targetSequence.add(int.parse(part.substring(2), radix: 16));
             } else if (part.toLowerCase().startsWith('0b')) {
               targetSequence.add(int.parse(part.substring(2), radix: 2));
             } else {
               targetSequence.add(int.parse(part));
             }
           } catch (e) {
             // skip invalid parts or return 0
           }
         }
       }
    }

    bool hasDecoder = bus.decoder != null && bus.decoder!.isEnabled;
    String decoderType = bus.decoder?.name ?? '';

    if (hasDecoder) {
      if (decoderType == 'UART') {
        List<ProtocolPacket> packets = bus.decoder!.packets;
        for (int i = 0; i < packets.length; i++) {
          var p = packets[i];
          if (channel == 'TXD' && !p.data.startsWith('Tx:')) continue;
          if (channel == 'RXD' && !p.data.startsWith('Rx:')) continue;

          if (condition == 'Error') {
             if (p.type == PacketType.error) {
               searchMatches.add(BusSearchMatch(time: p.startIndex / _sampleRate, startIndex: p.startIndex, endIndex: p.endIndex, busName: bus.name));
             }
          } else if (condition == 'Data') {
             if (p.type == PacketType.data && targetSequence.isNotEmpty) {
                bool match = true;
                int seqIndex = 0;
                int endIdx = p.endIndex;
                for (int j = 0; j < packets.length - i; j++) {
                   var nextP = packets[i+j];
                   if (channel == 'TXD' && !nextP.data.startsWith('Tx:')) continue;
                   if (channel == 'RXD' && !nextP.data.startsWith('Rx:')) continue;
                   if (nextP.type != PacketType.data || nextP.rawValue != targetSequence[seqIndex]) {
                      match = false; break;
                   }
                   endIdx = nextP.endIndex;
                   seqIndex++;
                   if (seqIndex == targetSequence.length) break;
                }
                if (match && seqIndex == targetSequence.length) {
                   searchMatches.add(BusSearchMatch(time: p.startIndex / _sampleRate, startIndex: p.startIndex, endIndex: endIdx, busName: bus.name));
                }
             }
          }
        }
      } else if (decoderType == 'I2C') {
        for (var frame in bus.decoder!.frames) {
          int? frameDevAddr;
          String rw = '';
          int? frameRegAddr;
          List<int> frameData = [];
          
          bool isWritePhase = false;
          bool isFirstData = true;

          for (int i = 0; i < frame.packets.length; i++) {
            var p = frame.packets[i];
            if (p.type == PacketType.address) {
               frameDevAddr = p.rawValue;
               isFirstData = true;
               if (i + 1 < frame.packets.length && frame.packets[i+1].type == PacketType.readWrite) {
                 rw = frame.packets[i+1].data;
                 isWritePhase = (rw == 'WRITE');
               }
            } else if (p.type == PacketType.data) {
               if (isWritePhase && isFirstData) {
                 frameRegAddr = p.rawValue;
                 isFirstData = false;
               } else {
                 if (p.rawValue != null) frameData.add(p.rawValue!);
               }
            }
          }
          
          // Conditions
          if (i2cDeviceAddress != null && frameDevAddr != i2cDeviceAddress) continue;
          if (i2cFrameType == 'Write Only' && rw != 'WRITE') continue;
          if (i2cFrameType == 'Read Only' && rw != 'READ') continue;
          if (i2cRegisterAddress != null && frameRegAddr != i2cRegisterAddress) continue;
          
          if (targetSequence.isNotEmpty) {
             bool foundSequence = false;
             if (targetSequence.length == 1) {
                foundSequence = frameRegAddr == targetSequence[0] || frameData.contains(targetSequence[0]);
             } else {
                List<int> allBytes = [];
                if (frameRegAddr != null) allBytes.add(frameRegAddr);
                allBytes.addAll(frameData);
                
                for (int i = 0; i <= allBytes.length - targetSequence.length; i++) {
                   bool match = true;
                   for (int j = 0; j < targetSequence.length; j++) {
                      if (allBytes[i+j] != targetSequence[j]) {
                         match = false;
                         break;
                      }
                   }
                   if (match) {
                      foundSequence = true;
                      break;
                   }
                }
             }
             if (!foundSequence) continue;
          }
          
          searchMatches.add(BusSearchMatch(time: frame.startIndex / _sampleRate, startIndex: frame.startIndex, endIndex: frame.endIndex, busName: bus.name));
        }
      }
    } else {
      int targetVal = targetSequence.isNotEmpty ? targetSequence[0] : 0;
      int numPins = (bus.startPin - bus.endPin).abs() + 1;
      int step = bus.startPin < bus.endPin ? 1 : -1;
      int startIndex = digitalChannel.count == digitalChannel.maxPoints ? digitalChannel.head : 0;
      
      int lastBusVal = -1;
      for (int i = 0; i < digitalChannel.count; i++) {
        int idx = (startIndex + i) % digitalChannel.maxPoints;
        int state = digitalChannel.states[idx];
        
        int busVal = 0;
        for (int p = 0; p < numPins; p++) {
          int physicalPin = bus.startPin + p * step;
          int bitVal = (state >> physicalPin) & 1;
          int targetBitPosition = isBigEndian ? (numPins - 1 - p) : p;
          busVal |= (bitVal << targetBitPosition);
        }
        
        if (busVal == targetVal && lastBusVal != targetVal) {
          searchMatches.add(BusSearchMatch(time: i / _sampleRate, startIndex: i, endIndex: i, busName: bus.name));
        }
        lastBusVal = busVal;
      }
    }

    if (searchMatches.isNotEmpty) {
       currentSearchMatchIndex = 0;
       _applySearchMatch(searchMatches[0]);
    }
    notifyListeners();
    return searchMatches.length;
  }
''';
    content = content.substring(0, startIndex) + newFunction + content.substring(endIndex);
  }

  file.writeAsStringSync(content);
}
