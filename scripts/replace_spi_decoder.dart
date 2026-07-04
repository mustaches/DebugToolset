import 'dart:io';

void main() {
  File file = File('G:/DebugToolSet/lib/modules/oscilloscope/models/protocol_decoder.dart');
  List<String> lines = file.readAsLinesSync();
  
  int spiClassStart = -1;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('class SpiDecoder extends ProtocolDecoder')) {
      spiClassStart = i;
      break;
    }
  }

  int decodeStart = -1;
  int decodeEnd = -1;
  int braceCount = 0;
  for (int i = spiClassStart; i < lines.length; i++) {
    if (decodeStart == -1 && lines[i].contains('void decode(Uint32List states')) {
      decodeStart = i - 1; // Include @override
    }
    if (decodeStart != -1 && i >= decodeStart + 1) {
      if (lines[i].contains('{')) braceCount += '{'.allMatches(lines[i]).length;
      if (lines[i].contains('}')) braceCount -= '}'.allMatches(lines[i]).length;
      if (braceCount == 0) {
        decodeEnd = i;
        break;
      }
    }
  }

  String newDecode = """
  @override
  void decode(Uint32List states, int head, int count, double sampleRate) {
    packets.clear();
    frames.clear();
    pinClocks.clear();
    if (count == 0 || !isEnabled) return;
    
    int laneCount = 0;
    List<String> labels = [];
    int localMosiLane = -1; // IO0
    int localMisoLane = -1; // IO1
    int localIo2Lane = -1;  // IO2
    int localIo3Lane = -1;  // IO3
    
    if (mosiPin >= 0) { localMosiLane = 0; labels.add('IO0/MOSI'); laneCount++; }
    if (misoPin >= 0) { localMisoLane = 1; labels.add('IO1/MISO'); laneCount++; }
    if (io2Pin >= 0) { localIo2Lane = 2; labels.add('IO2'); laneCount++; }
    if (io3Pin >= 0) { localIo3Lane = 3; labels.add('IO3'); laneCount++; }
    
    _dynamicMaxLanes = laneCount > 0 ? laneCount : 1;
    _dynamicLaneLabels = labels.isEmpty ? ['SPI'] : labels;

    int i = 0;
    int lastCs = csPin >= 0 ? getPinState(states, head, count, 0, csPin) : 1;
    int lastSck = getPinState(states, head, count, 0, sckPin);
    
    bool inFrame = csPin < 0; 
    if (csPin >= 0 && lastCs == 0) inFrame = true;

    int frameStartIndex = 0;
    List<ProtocolPacket> currentFramePackets = [];

    // State machine variables
    // 0: CMD, 1: ADDR, 2: MODE, 3: DUMMY, 4: DATA
    int decodeState = 0; 
    int addrLines = 1;
    int dataLines = 1;
    int dummyClocks = 0;
    int modeClocks = 0;
    int addrBytes = 0;
    
    int phaseClocks = 0;
    int phaseData = 0;
    int wordStartIdx = 0;
    
    int cmdValue = 0;

    void loadCommandConfig(int cmd) {
      cmdValue = cmd;
      addrLines = 1;
      dataLines = 1;
      dummyClocks = 0;
      modeClocks = 0;
      addrBytes = 0;
      
      if (protocolData != null && protocolData!['registers'] != null) {
        String hexKey = '0x\${cmd.toRadixString(16).toUpperCase().padLeft(2, '0')}';
        var reg = protocolData!['registers'][hexKey];
        if (reg != null) {
          addrLines = reg['addrLines'] ?? 1;
          dataLines = reg['dataLines'] ?? 1;
          dummyClocks = reg['dummyClocks'] ?? 0;
          modeClocks = reg['modeClocks'] ?? 0;
          addrBytes = reg['addrBytes'] ?? 0;
        }
      }
    }

    void processPacket(int startIdx, int endIdx, int rawValue, int bytes, String labelPrefix, Color color, int laneIdx) {
      String hexStr = rawValue.toRadixString(16).toUpperCase().padLeft(bytes * 2, '0');
      currentFramePackets.add(ProtocolPacket(
        startIndex: startIdx,
        endIndex: endIdx,
        data: '\$labelPrefix: 0x\$hexStr',
        rawValue: rawValue,
        type: PacketType.data,
        color: color,
        laneIndex: laneIdx,
      ));
    }

    while (i < count) {
      int cs = csPin >= 0 ? getPinState(states, head, count, i, csPin) : 0;
      int sck = getPinState(states, head, count, i, sckPin);
      
      if (csPin >= 0 && lastCs == 1 && cs == 0) {
        inFrame = true;
        frameStartIndex = i;
        currentFramePackets.clear();
        currentFramePackets.add(ProtocolPacket(startIndex: i, endIndex: i + 1, data: 'CS', type: PacketType.start, color: Colors.blueAccent));
        
        decodeState = 0;
        phaseClocks = 0;
        phaseData = 0;
      }
      
      if (csPin >= 0 && lastCs == 0 && cs == 1) {
        inFrame = false;
        currentFramePackets.add(ProtocolPacket(startIndex: i, endIndex: i + 1, data: 'CS', type: PacketType.stop, color: Colors.orange));
        if (currentFramePackets.isNotEmpty) {
          frames.add(ProtocolFrame(
            startIndex: frameStartIndex, 
            endIndex: i, 
            summary: 'Cmd: 0x\${cmdValue.toRadixString(16).toUpperCase()}', 
            packets: List.from(currentFramePackets)
          ));
        }
        currentFramePackets.clear();
      }

      if (inFrame) {
        bool isSampleEdge = false;
        if (cpol == 0 && cpha == 0) { isSampleEdge = (lastSck == 0 && sck == 1); }
        else if (cpol == 0 && cpha == 1) { isSampleEdge = (lastSck == 1 && sck == 0); }
        else if (cpol == 1 && cpha == 0) { isSampleEdge = (lastSck == 1 && sck == 0); }
        else if (cpol == 1 && cpha == 1) { isSampleEdge = (lastSck == 0 && sck == 1); }

        if (isSampleEdge) {
          if (phaseClocks == 0) wordStartIdx = i;
          
          pinClocks.putIfAbsent(sckPin, () => []).add(ProtocolClock(index: i, label: (phaseClocks + 1).toString()));
          
          int io0 = mosiPin >= 0 ? getPinState(states, head, count, i, mosiPin) : 0;
          int io1 = misoPin >= 0 ? getPinState(states, head, count, i, misoPin) : 0;
          int io2 = io2Pin >= 0 ? getPinState(states, head, count, i, io2Pin) : 0;
          int io3 = io3Pin >= 0 ? getPinState(states, head, count, i, io3Pin) : 0;

          if (decodeState == 0) { // CMD
            phaseData = (phaseData << 1) | io0;
            phaseClocks++;
            if (phaseClocks == 8) {
              processPacket(wordStartIdx, i, phaseData, 1, 'CMD', Colors.purpleAccent, localMosiLane >= 0 ? localMosiLane : 0);
              loadCommandConfig(phaseData);
              
              if (addrBytes > 0) decodeState = 1;
              else if (modeClocks > 0) decodeState = 2;
              else if (dummyClocks > 0) decodeState = 3;
              else decodeState = 4;
              
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 1) { // ADDR
            int bitVal = 0;
            if (addrLines == 4) bitVal = (io3 << 3) | (io2 << 2) | (io1 << 1) | io0;
            else if (addrLines == 2) bitVal = (io1 << 1) | io0;
            else bitVal = io0;

            phaseData = (phaseData << addrLines) | bitVal;
            phaseClocks++;
            
            if (phaseClocks == (addrBytes * 8 ~/ addrLines)) {
              processPacket(wordStartIdx, i, phaseData, addrBytes, 'ADDR', Colors.blue, localMosiLane >= 0 ? localMosiLane : 0);
              if (modeClocks > 0) decodeState = 2;
              else if (dummyClocks > 0) decodeState = 3;
              else decodeState = 4;
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 2) { // MODE
            int bitVal = 0;
            if (addrLines == 4) bitVal = (io3 << 3) | (io2 << 2) | (io1 << 1) | io0;
            else if (addrLines == 2) bitVal = (io1 << 1) | io0;
            else bitVal = io0;

            phaseData = (phaseData << addrLines) | bitVal;
            phaseClocks++;
            
            if (phaseClocks == modeClocks) {
              processPacket(wordStartIdx, i, phaseData, (modeClocks * addrLines) ~/ 8 > 0 ? (modeClocks * addrLines) ~/ 8 : 1, 'MODE', Colors.deepOrange, localMosiLane >= 0 ? localMosiLane : 0);
              if (dummyClocks > 0) decodeState = 3;
              else decodeState = 4;
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 3) { // DUMMY
            phaseClocks++;
            if (phaseClocks == dummyClocks) {
              if (dataLines > 0) decodeState = 4;
              else decodeState = 5; // END
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 4) { // DATA
            int bitVal = 0;
            // In read mode, data comes from MISO. In Dual/Quad it uses all lines.
            // Let's just blindly aggregate lines based on dataLines.
            if (dataLines == 4) bitVal = (io3 << 3) | (io2 << 2) | (io1 << 1) | io0;
            else if (dataLines == 2) bitVal = (io1 << 1) | io0;
            else bitVal = io1; // Default read is on MISO (io1). (Write would be io0, but they're mostly reads)
            // Note: During Page Program (write), data is on MOSI (io0). 
            // In Regfile, we have `access`: "W".
            // So let's check access:
            bool isWrite = false;
            if (protocolData != null && protocolData!['registers'] != null) {
              String hexKey = '0x\${cmdValue.toRadixString(16).toUpperCase().padLeft(2, '0')}';
              var reg = protocolData!['registers'][hexKey];
              if (reg != null && reg['access'] == 'W') isWrite = true;
            }
            if (dataLines == 1 && isWrite) bitVal = io0;

            phaseData = (phaseData << dataLines) | bitVal;
            phaseClocks++;
            
            if (phaseClocks == (8 ~/ dataLines)) {
              processPacket(wordStartIdx, i, phaseData, 1, 'DATA', Colors.green, localMisoLane >= 0 ? localMisoLane : 0);
              phaseClocks = 0; phaseData = 0;
            }
          }
        }
      }

      lastCs = cs;
      lastSck = sck;
      i++;
    }
    
    // Add pending frame if truncated
    if (inFrame && currentFramePackets.isNotEmpty) {
      frames.add(ProtocolFrame(
        startIndex: frameStartIndex,
        endIndex: count,
        summary: 'Cmd: 0x\${cmdValue.toRadixString(16).toUpperCase()} (Incomplete)',
        packets: List.from(currentFramePackets),
      ));
    }
    
    packets.clear();
    for (var f in frames) {
      packets.addAll(f.packets);
    }
  }
""";

  lines.replaceRange(decodeStart, decodeEnd + 1, newDecode.split('\n'));
  file.writeAsStringSync(lines.join('\n'));
}
