import 'package:flutter/material.dart';
import 'dart:typed_data';

enum PacketType { data, start, stop, error, info, address, readWrite }

enum ProtocolDataFormat { hex, decimal, ascii }

class ProtocolPacket {
  final int startIndex;
  int endIndex;
  String data;
  final int? rawValue; // Add raw value for tooltips and formatting
  final PacketType type;
  Color color;
  final int laneIndex;

  ProtocolPacket({
    required this.startIndex,
    required this.endIndex,
    required this.data,
    this.rawValue,
    required this.type,
    required this.color,
    this.laneIndex = 0,
  });
}

class ProtocolFrame {
  final int startIndex;
  final int endIndex;
  final String summary;
  final List<ProtocolPacket> packets;

  ProtocolFrame({
    required this.startIndex,
    required this.endIndex,
    required this.summary,
    required this.packets,
  });
}

class ProtocolClock {
  final int index;
  final String label;

  ProtocolClock({
    required this.index,
    required this.label,
  });
}

abstract class ProtocolDecoder {
  String get name;
  bool isEnabled = true;
  Color color = Colors.orangeAccent;
  ProtocolDataFormat dataFormat = ProtocolDataFormat.hex;
  
  List<ProtocolPacket> packets = [];
  List<ProtocolFrame> frames = [];
  Map<int, List<ProtocolClock>> pinClocks = {};
  
  Set<PacketType> get supportedPacketTypes => PacketType.values.toSet();
  Set<PacketType> get defaultHiddenPacketTypes => {};
  String getPacketTypeName(PacketType type) => type.name.toUpperCase();
  int lastDecodeAbsoluteOffset = 0;
  
  int get maxLanes => 1;
  String getLaneLabel(int laneIndex) => 'Lane $laneIndex';

  Map<String, dynamic> toJson();
  
  void decode(Uint32List states, int head, int count, double sampleRate);
  
  int getPinState(Uint32List states, int head, int count, int index, int pin) {
    int realIndex = count < states.length ? index : (head + index) % states.length;
    return (states[realIndex] >> pin) & 1;
  }

  String formatData(int value, int numBits) {
    if (dataFormat == ProtocolDataFormat.ascii) {
      if (value >= 32 && value <= 126) {
        return "'${String.fromCharCode(value)}'";
      } else {
        return "\\x${value.toRadixString(16).toUpperCase().padLeft(2, '0')}";
      }
    } else if (dataFormat == ProtocolDataFormat.decimal) {
      return value.toString();
    } else {
      int hexDigits = (numBits / 4).ceil();
      return '0x${value.toRadixString(16).toUpperCase().padLeft(hexDigits, '0')}';
    }
  }
}

class UartDecoder extends ProtocolDecoder {
  @override
  String get name => 'UART';
  
  int rxPin;
  int txPin;
  int baudRate; // 0 means Auto
  int detectedBaudRate = 0; // The actual baud rate used (detected or manual)
  int dataBits;
  int stopBits;
  String parity;
  bool lsbFirst;
  String? protocolFile;
  
  @override
  Set<PacketType> get supportedPacketTypes => {
    PacketType.start, 
    PacketType.data, 
    PacketType.info, // For Parity
    PacketType.stop, 
    PacketType.error
  };
  
  @override
  Set<PacketType> get defaultHiddenPacketTypes => {
    PacketType.start,
    PacketType.info,
    PacketType.stop
  };
  
  @override
  String getPacketTypeName(PacketType type) {
    if (type == PacketType.info) return 'PARITY';
    return super.getPacketTypeName(type);
  }
  
  int _dynamicMaxLanes = 1;
  List<String> _dynamicLaneLabels = ['UART'];

  @override
  int get maxLanes => _dynamicMaxLanes;
  
  @override
  String getLaneLabel(int laneIndex) {
    if (laneIndex >= 0 && laneIndex < _dynamicLaneLabels.length) {
      return _dynamicLaneLabels[laneIndex];
    }
    return 'Lane $laneIndex';
  }
  
  UartDecoder({
    required this.rxPin,
    this.txPin = -1,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = 'N',
    this.lsbFirst = true,
    this.protocolFile,
  });
  
  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'UART',
      'isEnabled': isEnabled,
      'dataFormat': dataFormat.index,
      'rxPin': rxPin,
      'txPin': txPin,
      'baudRate': baudRate,
      'dataBits': dataBits,
      'stopBits': stopBits,
      'parity': parity,
      'lsbFirst': lsbFirst,
      'protocolFile': protocolFile,
    };
  }
  
  factory UartDecoder.fromJson(Map<String, dynamic> json) {
    return UartDecoder(
      rxPin: json['rxPin'] ?? 0,
      txPin: json['txPin'] ?? -1,
      baudRate: json['baudRate'] ?? 115200,
      dataBits: json['dataBits'] ?? 8,
      stopBits: json['stopBits'] ?? 1,
      parity: json['parity'] ?? 'N',
      lsbFirst: json['lsbFirst'] ?? true,
      protocolFile: json['protocolFile'],
    )..isEnabled = json['isEnabled'] ?? true
     ..dataFormat = ProtocolDataFormat.values[json['dataFormat'] ?? 0];
  }

  @override
  void decode(Uint32List states, int head, int count, double sampleRate) {
    packets.clear();
    frames.clear();
    if (count == 0 || !isEnabled) return;
    if (sampleRate <= 0) return;
    
    int actualBaudRate = baudRate;
    
    // Auto Baud Rate Detection
    if (baudRate <= 0) {
      actualBaudRate = _autoDetectBaudRate(states, head, count, sampleRate);
      if (actualBaudRate <= 0) return; // Cannot detect
    }
    
    detectedBaudRate = actualBaudRate;
    double samplesPerBit = sampleRate / actualBaudRate;
    if (samplesPerBit < 1.0) return;
    
    int laneCount = 0;
    List<String> labels = [];
    int localRxLane = -1;
    int localTxLane = -1;
    
    if (rxPin >= 0 && txPin >= 0) {
      localTxLane = 0;
      localRxLane = 1;
      labels.addAll(['TXD', 'RXD']);
      laneCount = 2;
    } else if (txPin >= 0) {
      localTxLane = 0;
      labels.add('TXD');
      laneCount = 1;
    } else if (rxPin >= 0) {
      localRxLane = 0;
      labels.add('RXD');
      laneCount = 1;
    }
    
    _dynamicMaxLanes = laneCount > 0 ? laneCount : 1;
    _dynamicLaneLabels = labels.isEmpty ? ['UART'] : labels;
    
    List<ProtocolPacket> rxPackets = [];
    if (rxPin >= 0) {
      rxPackets = _decodeSinglePin(states, head, count, samplesPerBit, rxPin, false, localRxLane);
    }
    
    List<ProtocolPacket> txPackets = [];
    if (txPin >= 0) {
      txPackets = _decodeSinglePin(states, head, count, samplesPerBit, txPin, true, localTxLane);
    }
    
    packets.addAll(rxPackets);
    packets.addAll(txPackets);
    packets.sort((a, b) => a.startIndex.compareTo(b.startIndex));
    
    // Group UART packets into frames based on idle time and direction
    List<ProtocolPacket> currentFramePackets = [];
    double maxIdleSamples = samplesPerBit * (dataBits + 2) * 2; // ~2 bytes of idle time
    bool currentIsTx = false;
    
    for (int pIdx = 0; pIdx < packets.length; pIdx++) {
      var packet = packets[pIdx];
      bool isTx = txPin >= 0 && packet.laneIndex == localTxLane;
      
      if (currentFramePackets.isEmpty) {
        currentFramePackets.add(packet);
        currentIsTx = isTx;
      } else {
        var lastPacket = currentFramePackets.last;
        // Close frame if time gap is too large OR direction changed
        if ((packet.startIndex - lastPacket.endIndex) > maxIdleSamples || isTx != currentIsTx) {
          String dir = currentIsTx ? "Tx" : "Rx";
          int dataCount = currentFramePackets.where((p) => p.type == PacketType.data).length;
          frames.add(ProtocolFrame(
            startIndex: currentFramePackets.first.startIndex,
            endIndex: currentFramePackets.last.endIndex,
            summary: '$dir: DB($dataCount)',
            packets: List.from(currentFramePackets),
          ));
          currentFramePackets.clear();
          currentIsTx = isTx;
        }
        currentFramePackets.add(packet);
      }
    }
    
    if (currentFramePackets.isNotEmpty) {
      String dir = currentIsTx ? "Tx" : "Rx";
      int dataCount = currentFramePackets.where((p) => p.type == PacketType.data).length;
      frames.add(ProtocolFrame(
        startIndex: currentFramePackets.first.startIndex,
        endIndex: currentFramePackets.last.endIndex,
        summary: '$dir: DB($dataCount)',
        packets: currentFramePackets,
      ));
    }
  }

  List<ProtocolPacket> _decodeSinglePin(Uint32List states, int head, int count, double samplesPerBit, int pin, bool isTx, int laneIndex) {
    List<ProtocolPacket> result = [];
    int i = 0;
    int lastState = getPinState(states, head, count, 0, pin);
    
    while (i < count) {
      int state = getPinState(states, head, count, i, pin);
      
      // Look for start bit (falling edge)
      if (lastState == 1 && state == 0) {
        int startIndex = i;
        double samplePos = i + samplesPerBit * 0.5;
        
        int startEnd = samplePos.round();
        if (startEnd >= count) startEnd = count - 1;
        
        result.add(ProtocolPacket(
          startIndex: startIndex,
          endIndex: startEnd,
          data: 'S',
          type: PacketType.start,
          color: Colors.grey,
          laneIndex: laneIndex >= 0 ? laneIndex : 0,
        ));
        
        samplePos = i + samplesPerBit * 1.5;
        int data = 0;
        
        int dataStart = startEnd;
        
        for (int b = 0; b < dataBits; b++) {
          int bitIdx = samplePos.round();
          if (bitIdx >= count) break;
          
          int bitState = getPinState(states, head, count, bitIdx, pin);
          if (lsbFirst) {
            data |= (bitState << b);
          } else {
            data |= (bitState << (dataBits - 1 - b));
          }
          
          samplePos += samplesPerBit;
        }
        
        int dataEnd = (samplePos - samplesPerBit * 0.5).round();
        if (dataEnd >= count) dataEnd = count - 1;
        
        String dataStr = formatData(data, dataBits);
        String prefix = isTx ? 'Tx: ' : 'Rx: ';
        
        result.add(ProtocolPacket(
          startIndex: dataStart,
          endIndex: dataEnd,
          data: prefix + dataStr,
          rawValue: data,
          type: PacketType.data,
          color: const Color(0xFF4CAF50),
          laneIndex: laneIndex >= 0 ? laneIndex : 0,
        ));
        
        int currentEnd = dataEnd;
        
        if (parity != 'none') {
           int parityBitIdx = samplePos.round();
           int parityState = -1;
           if (parityBitIdx < count) {
               parityState = getPinState(states, head, count, parityBitIdx, pin);
           }
           
           samplePos += samplesPerBit;
           int parityEnd = (samplePos - samplesPerBit * 0.5).round();
           if (parityEnd >= count) parityEnd = count - 1;
           
           bool parityError = false;
           if (parityState != -1) {
               int ones = 0;
               for (int b = 0; b < dataBits; b++) {
                   if ((data & (1 << b)) != 0) ones++;
               }
               if (parity == 'even' && (ones % 2) != parityState) parityError = true;
               if (parity == 'odd' && (ones % 2) == parityState) parityError = true;
           } else {
               parityError = true;
           }
           
           result.add(ProtocolPacket(
             startIndex: currentEnd,
             endIndex: parityEnd,
             data: parityError ? 'P!' : 'P',
             type: parityError ? PacketType.error : PacketType.info,
             color: parityError ? Colors.red : Colors.blueAccent,
             laneIndex: laneIndex >= 0 ? laneIndex : 0,
           ));
           
           currentEnd = parityEnd;
        }
        
        // Check stop bits
        for (int sb = 0; sb < stopBits; sb++) {
            int stopIdx = samplePos.round();
            int stopState = -1;
            bool stopError = false;
            if (stopIdx < count) {
               stopState = getPinState(states, head, count, stopIdx, pin);
               if (stopState == 0) stopError = true;
            } else {
               stopError = true;
            }
            
            samplePos += samplesPerBit;
            int stopEnd = (samplePos - samplesPerBit * 0.5).round();
            if (stopEnd >= count) stopEnd = count - 1;
            
            result.add(ProtocolPacket(
              startIndex: currentEnd,
              endIndex: stopEnd,
              data: stopError ? 'T!' : 'T',
              type: stopError ? PacketType.error : PacketType.stop,
              color: stopError ? Colors.red : Colors.orangeAccent,
              laneIndex: laneIndex >= 0 ? laneIndex : 0,
            ));
            
            currentEnd = stopEnd;
        }
        
        // Advance i to the middle of the last stop bit
        int stopCenterIdx = (samplePos - samplesPerBit).round();
        if (stopBits <= 0) stopCenterIdx = (samplePos - samplesPerBit * 0.5).round();
        i = stopCenterIdx;
        if (i < count) {
          lastState = getPinState(states, head, count, i, pin);
        }
      } else {
        lastState = state;
        i++;
      }
    }
    return result;
  }

  int _autoDetectBaudRate(Uint32List states, int head, int count, double sampleRate) {
    int minPulseSamples = count;
    
    void scanPin(int pin) {
      if (pin < 0) return;
      int i = 0;
      int lastState = getPinState(states, head, count, 0, pin);
      int lastEdgeIndex = -1;
      
      while (i < count) {
        int state = getPinState(states, head, count, i, pin);
        if (state != lastState) {
          if (lastEdgeIndex != -1) {
            int pulseWidth = i - lastEdgeIndex;
            // Ignore very short pulses (glitches) typically < 3 samples depending on sample rate
            if (pulseWidth > 2 && pulseWidth < minPulseSamples) {
              minPulseSamples = pulseWidth;
            }
          }
          lastEdgeIndex = i;
          lastState = state;
        }
        i++;
      }
    }
    
    scanPin(rxPin);
    scanPin(txPin);
    
    if (minPulseSamples == count || minPulseSamples == 0) return 115200; // Fallback
    
    double rawBaudRate = sampleRate / minPulseSamples;
    
    // Snap to standard baud rates
    const List<int> standardRates = [
      300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400,
      57600, 76800, 115200, 230400, 460800, 576000, 921600, 1000000, 1152000, 1500000, 2000000, 2500000, 3000000
    ];
    
    int closestRate = standardRates.first;
    double minDiff = (rawBaudRate - closestRate).abs();
    
    for (int rate in standardRates) {
      double diff = (rawBaudRate - rate).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closestRate = rate;
      }
    }
    
    // If raw baud rate is way off standard ones, use raw, otherwise snap
    if (minDiff / closestRate > 0.1) { 
      return rawBaudRate.round();
    }
    
    return closestRate;
  }
}

class I2cDecoder extends ProtocolDecoder {
  @override
  String get name => 'I2C';
  
  @override
  Set<PacketType> get supportedPacketTypes => {
    PacketType.start,
    PacketType.address,
    PacketType.readWrite,
    PacketType.data,
    PacketType.info, // For Ack/Nack
    PacketType.stop,
    PacketType.error
  };

  @override
  Set<PacketType> get defaultHiddenPacketTypes => {
    PacketType.info // Hide Ack/Nack by default
  };

  @override
  String getPacketTypeName(PacketType type) {
    if (type == PacketType.info) return 'ACK/NACK';
    if (type == PacketType.readWrite) return 'READ/WRITE';
    return super.getPacketTypeName(type);
  }

  int _dynamicMaxLanes = 2;
  List<String> _dynamicLaneLabels = ['Write', 'Read'];

  @override
  int get maxLanes => _dynamicMaxLanes;
  
  int sclPin;
  int sdaPin;
  Map<int, String> deviceAliases = {};
  
  I2cDecoder({
    required this.sclPin,
    required this.sdaPin,
  });
  
  @override
  String getLaneLabel(int laneIndex) {
    if (laneIndex >= 0 && laneIndex < _dynamicLaneLabels.length) {
      return _dynamicLaneLabels[laneIndex];
    }
    return 'Lane $laneIndex';
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'I2C',
      'isEnabled': isEnabled,
      'dataFormat': dataFormat.index,
      'sclPin': sclPin,
      'sdaPin': sdaPin,
      'deviceAliases': deviceAliases.map((k, v) => MapEntry(k.toString(), v)),
    };
  }
  
  factory I2cDecoder.fromJson(Map<String, dynamic> json) {
    var decoder = I2cDecoder(
      sclPin: json['sclPin'] ?? 0,
      sdaPin: json['sdaPin'] ?? 1,
    )..isEnabled = json['isEnabled'] ?? true
     ..dataFormat = ProtocolDataFormat.values[json['dataFormat'] ?? 0];
     
    if (json['deviceAliases'] != null) {
      Map<String, dynamic> aliasesMap = json['deviceAliases'];
      aliasesMap.forEach((k, v) {
        decoder.deviceAliases[int.parse(k)] = v.toString();
      });
    }
    
    return decoder;
  }

  static const Map<int, String> commonI2cAddresses = {
    0x3C: 'OLED',
    0x3D: 'OLED',
    0x68: 'MPU6050/RTC',
    0x50: 'EEPROM',
    0x51: 'EEPROM',
    0x52: 'EEPROM',
    0x53: 'EEPROM',
    0x54: 'EEPROM',
    0x55: 'EEPROM',
    0x56: 'EEPROM',
    0x57: 'EEPROM',
    0x27: 'LCD PCF8574',
    0x3F: 'LCD PCF8574',
    0x40: 'PCA9685/HTU21D',
    0x76: 'BME280/BMP280',
    0x77: 'BME280/BMP280',
    0x23: 'BH1750',
    0x44: 'SHT31',
    0x45: 'SHT31',
  };

  @override
  void decode(Uint32List states, int head, int count, double sampleRate) {
    packets.clear();
    pinClocks.clear();
    if (count == 0 || !isEnabled) return;
    
    int i = 0;
    int lastScl = getPinState(states, head, count, 0, sclPin);
    int lastSda = getPinState(states, head, count, 0, sdaPin);
    
    bool inFrame = false;
    int bitsRead = 0;
    int data = 0;
    bool isAckPhase = false;
    bool isFirstByte = false;
    
    int frameStartIndex = 0;
    int rwStartIndex = 0;
    
    bool pendingData = false;
    bool pendingAddress = false;
    bool pendingAck = false;
    int ackStartIndex = 0;
    int ackBit = 0;
    int dataToEmit = 0;
    
    void flushPendingPackets(int endIndex) {
       if (pendingAddress) {
           int addr = dataToEmit >> 1;
           bool isRead = (dataToEmit & 1) == 1;
           String addrHex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, '0')}';
           String label = addrHex;

           packets.add(ProtocolPacket(
             startIndex: frameStartIndex,
             endIndex: rwStartIndex, 
             data: label,
             rawValue: addr,
             type: PacketType.address,
             color: Colors.cyan,
           ));
           packets.add(ProtocolPacket(
             startIndex: rwStartIndex,
             endIndex: endIndex, 
             data: isRead ? 'READ' : 'WRITE',
             type: PacketType.readWrite,
             color: isRead ? Colors.amber : Colors.pinkAccent,
           ));
           pendingAddress = false;
       } else if (pendingData) {
           packets.add(ProtocolPacket(
             startIndex: frameStartIndex,
             endIndex: endIndex, 
             data: formatData(dataToEmit, 8),
             rawValue: dataToEmit,
             type: PacketType.data,
             color: Colors.green,
           ));
           pendingData = false;
       }
       if (pendingAck) {
           bool ack = (ackBit == 0);
           packets.add(ProtocolPacket(
             startIndex: ackStartIndex,
             endIndex: endIndex,
             data: ack ? 'ACK' : 'NACK',
             type: PacketType.info,
             color: ack ? Colors.teal : Colors.redAccent,
           ));
           pendingAck = false;
       }
    }

    int startConditionSdaEdge = 0;
    bool waitingForStartSclFall = false;
    int lastSclRise = 0;
    
    while (i < count) {
      int scl = getPinState(states, head, count, i, sclPin);
      int sda = getPinState(states, head, count, i, sdaPin);
      
      if (lastScl == 0 && scl == 1) {
        lastSclRise = i;
      }
      
      // Start condition: SCL high, SDA falling
      if (scl == 1 && lastScl == 1 && lastSda == 1 && sda == 0) {
        flushPendingPackets(i); // Flush any hanging ACK/Data up to this Start edge
        
        startConditionSdaEdge = i;
        inFrame = true;
        bitsRead = 0;
        data = 0;
        isAckPhase = false;
        waitingForStartSclFall = true;
        isFirstByte = true;
      }
      // Start condition SCL fall
      else if (waitingForStartSclFall && lastScl == 1 && scl == 0) {
        packets.add(ProtocolPacket(
          startIndex: startConditionSdaEdge,
          endIndex: i, // Ends exactly at SCL fall
          data: 'S',
          type: PacketType.start,
          color: Colors.blueAccent,
        ));
        waitingForStartSclFall = false;
      }
      // Stop condition: SCL high, SDA rising
      else if (scl == 1 && lastScl == 1 && lastSda == 0 && sda == 1) {
        int stopStart = lastSclRise > 0 ? lastSclRise : i - 5;
        flushPendingPackets(stopStart); // Flush hanging ACK/Data up to Stop SCL rise
        
        packets.add(ProtocolPacket(
          startIndex: stopStart,
          endIndex: i, // Ends exactly at SDA rise
          data: 'P',
          type: PacketType.stop,
          color: Colors.orange,
        ));
        inFrame = false;
        waitingForStartSclFall = false;
      }
      // Data sampling: SCL rising edge
      else if (inFrame && lastScl == 0 && scl == 1) {
        if (!isAckPhase) {
          if (bitsRead == 0) {
             frameStartIndex = i;
             flushPendingPackets(i); // The previous ACK ends precisely at this SCL rise
          }
          if (isFirstByte && bitsRead == 7) {
             rwStartIndex = i;
          }
          
          data = (data << 1) | sda;
          bitsRead++;
          
          pinClocks.putIfAbsent(sclPin, () => []).add(ProtocolClock(
            index: i,
            label: bitsRead.toString(),
          ));
          
          if (bitsRead == 8) {
             dataToEmit = data;
             if (isFirstByte) {
                 pendingAddress = true;
                 isFirstByte = false;
             } else {
                 pendingData = true;
             }
             isAckPhase = true;
          }
        } else {
          // 9th SCL rise
          pinClocks.putIfAbsent(sclPin, () => []).add(ProtocolClock(
            index: i,
            label: '9',
          ));
          
          flushPendingPackets(i); // The previous 8-bit Data/RW ends precisely at this 9th SCL rise
          
          ackStartIndex = i;
          ackBit = sda;
          pendingAck = true;
          
          isAckPhase = false;
          bitsRead = 0;
          data = 0;
        }
      }
      
      lastScl = scl;
      lastSda = sda;
      i++;
    }
    flushPendingPackets(i);

    // Post-process I2C packets into frames
    List<ProtocolFrame> unlanedFrames = [];
    List<ProtocolPacket> currentFramePackets = [];
    Set<String> frameAddresses = {};
    Set<String> frameRWs = {};

    for (int pIdx = 0; pIdx < packets.length; pIdx++) {
      var packet = packets[pIdx];
      
      if (packet.type == PacketType.stop) {
        currentFramePackets.add(packet);
        
        bool isRead = frameRWs.contains('READ');
        String action = isRead ? 'R' : (frameRWs.contains('WRITE') ? 'W' : 'Tx');
        String addrStr = frameAddresses.isNotEmpty ? frameAddresses.join(' & ') : 'Unknown';

        unlanedFrames.add(ProtocolFrame(
          startIndex: currentFramePackets.first.startIndex,
          endIndex: currentFramePackets.last.endIndex,
          summary: '$action: $addrStr',
          packets: List.from(currentFramePackets),
        ));
        currentFramePackets.clear();
        frameAddresses.clear();
        frameRWs.clear();
      } else {
        if (packet.type == PacketType.address) frameAddresses.add(packet.data);
        if (packet.type == PacketType.readWrite) frameRWs.add(packet.data);
        currentFramePackets.add(packet);
      }
    }
    
    if (currentFramePackets.isNotEmpty) {
      bool isRead = frameRWs.contains('READ');
      String action = isRead ? 'R' : (frameRWs.contains('WRITE') ? 'W' : 'Tx');
      String addrStr = frameAddresses.isNotEmpty ? frameAddresses.join(' & ') : 'Unknown';

      unlanedFrames.add(ProtocolFrame(
        startIndex: currentFramePackets.first.startIndex,
        endIndex: currentFramePackets.last.endIndex,
        summary: '$action: $addrStr (Incomplete)',
        packets: List.from(currentFramePackets),
      ));
    }
    
    // Filter out corrupted/incomplete frames at boundaries
    if (unlanedFrames.isNotEmpty) {
      if (unlanedFrames.first.summary.contains('(Incomplete)') || unlanedFrames.first.summary.contains('Unknown')) {
        unlanedFrames.removeAt(0);
      }
    }
    if (unlanedFrames.isNotEmpty) {
      if (unlanedFrames.last.summary.contains('(Incomplete)') || unlanedFrames.last.summary.contains('Unknown')) {
        unlanedFrames.removeLast();
      }
    }

    // Now analyze unlanedFrames to assign distinct lanes only for active actions
    List<String> activeLaneLabels = [];
    for (var f in unlanedFrames) {
      String label = f.summary.replaceAll(' (Incomplete)', '');
      if (label.contains('Unknown')) continue; // Skip unknown from getting a lane if possible
      if (!activeLaneLabels.contains(label)) {
        activeLaneLabels.add(label);
      }
    }
    
    // Sort active labels to be consistent
    activeLaneLabels.sort();

    _dynamicMaxLanes = activeLaneLabels.isEmpty ? 1 : activeLaneLabels.length;
    _dynamicLaneLabels = activeLaneLabels.isEmpty ? ['Write/Read'] : activeLaneLabels;

    // Second pass: Update laneIndex for packets in frames and build final lists
    List<ProtocolPacket> finalLanedPackets = [];
    frames.clear();
    
    for (var f in unlanedFrames) {
      String label = f.summary.replaceAll(' (Incomplete)', '');
      int lane = _dynamicLaneLabels.indexOf(label);
      if (lane == -1) lane = 0; // Fallback

      List<ProtocolPacket> lanedPackets = f.packets.map((p) => ProtocolPacket(
        startIndex: p.startIndex,
        endIndex: p.endIndex,
        data: p.data,
        rawValue: p.rawValue,
        type: p.type,
        color: p.color,
        laneIndex: lane,
      )).toList();
      
      finalLanedPackets.addAll(lanedPackets);
      frames.add(ProtocolFrame(
        startIndex: lanedPackets.first.startIndex,
        endIndex: lanedPackets.last.endIndex,
        summary: f.summary,
        packets: lanedPackets,
      ));
    }

    packets = finalLanedPackets;
  }
}

class SpiDecoder extends ProtocolDecoder {
  @override
  String get name => 'SPI';

  int sckPin;
  int mosiPin;
  int misoPin;
  int csPin;
  int io2Pin;
  int io3Pin;
  
  int cpol;
  int cpha;
  int dataBits;
  bool lsbFirst;
  String? protocolFile;
  
  // Transient property to hold the regfile configuration
  Map<String, dynamic>? protocolData;
  
  @override
  Set<PacketType> get supportedPacketTypes => {
    PacketType.start,
    PacketType.data,
    PacketType.stop,
    PacketType.error
  };

  @override
  Set<PacketType> get defaultHiddenPacketTypes => {
    PacketType.start,
    PacketType.stop
  };

  int _dynamicMaxLanes = 2;
  List<String> _dynamicLaneLabels = ['MOSI', 'MISO'];

  @override
  int get maxLanes => _dynamicMaxLanes;
  
  @override
  String getLaneLabel(int laneIndex) {
    if (laneIndex >= 0 && laneIndex < _dynamicLaneLabels.length) {
      return _dynamicLaneLabels[laneIndex];
    }
    return 'Lane $laneIndex';
  }

  SpiDecoder({
    required this.sckPin,
    this.mosiPin = -1,
    this.misoPin = -1,
    this.csPin = -1,
    this.io2Pin = -1,
    this.io3Pin = -1,
    this.cpol = 0,
    this.cpha = 0,
    this.dataBits = 8,
    this.lsbFirst = false,
    this.protocolFile,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'SPI',
      'isEnabled': isEnabled,
      'dataFormat': dataFormat.index,
      'sckPin': sckPin,
      'mosiPin': mosiPin,
      'misoPin': misoPin,
      'csPin': csPin,
      'io2Pin': io2Pin,
      'io3Pin': io3Pin,
      'cpol': cpol,
      'cpha': cpha,
      'dataBits': dataBits,
      'lsbFirst': lsbFirst,
      'protocolFile': protocolFile,
    };
  }
  
  factory SpiDecoder.fromJson(Map<String, dynamic> json) {
    return SpiDecoder(
      sckPin: json['sckPin'] ?? 0,
      mosiPin: json['mosiPin'] ?? -1,
      misoPin: json['misoPin'] ?? -1,
      csPin: json['csPin'] ?? -1,
      io2Pin: json['io2Pin'] ?? -1,
      io3Pin: json['io3Pin'] ?? -1,
      cpol: json['cpol'] ?? 0,
      cpha: json['cpha'] ?? 0,
      dataBits: json['dataBits'] ?? 8,
      lsbFirst: json['lsbFirst'] ?? false,
      protocolFile: json['protocolFile'],
    )..isEnabled = json['isEnabled'] ?? true
     ..dataFormat = ProtocolDataFormat.values[json['dataFormat'] ?? 0];
  }

  @override
  void decode(Uint32List states, int head, int count, double sampleRate) {
    packets.clear();
    frames.clear();
    pinClocks.clear();
    if (count == 0 || !isEnabled) return;
    
    int localMosiLane = 0; // MOSI
    int localMisoLane = 1; // MISO
    
    _dynamicMaxLanes = 2;
    _dynamicLaneLabels = ['MOSI', 'MISO'];

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
        var reg = protocolData!['registers'][cmd];
        if (reg != null) {
          addrLines = reg.rawJson['addrLines'] ?? 1;
          dataLines = reg.rawJson['dataLines'] ?? 1;
          dummyClocks = reg.rawJson['dummyClocks'] ?? 0;
          modeClocks = reg.rawJson['modeClocks'] ?? 0;
          addrBytes = reg.rawJson['addrBytes'] ?? 0;
        }
      }
    }

    ProtocolPacket? pendingPacket;

    ProtocolPacket createPacket(int startIdx, int rawValue, int bytes, String labelPrefix, Color color, int laneIdx) {
      String hexStr = rawValue.toRadixString(16).toUpperCase().padLeft(bytes * 2, '0');
      return ProtocolPacket(
        startIndex: startIdx,
        endIndex: startIdx,
        data: '$labelPrefix: 0x$hexStr',
        rawValue: rawValue,
        type: PacketType.data,
        color: color,
        laneIndex: laneIdx,
      );
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
        pendingPacket = null;
      }
      
      if (csPin >= 0 && lastCs == 0 && cs == 1) {
        if (pendingPacket != null) {
          pendingPacket.endIndex = i;
          currentFramePackets.add(pendingPacket);
          pendingPacket = null;
        }
        inFrame = false;
        currentFramePackets.add(ProtocolPacket(startIndex: i, endIndex: i + 1, data: 'CS', type: PacketType.stop, color: Colors.orange));
        if (currentFramePackets.isNotEmpty) {
          frames.add(ProtocolFrame(
            startIndex: frameStartIndex, 
            endIndex: i, 
            summary: 'Cmd: 0x${cmdValue.toRadixString(16).toUpperCase()}', 
            packets: List.from(currentFramePackets)
          ));
        }
        currentFramePackets.clear();
      }

      if (inFrame) {
        bool isSampleEdge = false;
        if (cpol == 0 && cpha == 0) { 
          isSampleEdge = (lastSck == 0 && sck == 1); 
        }
        else if (cpol == 0 && cpha == 1) { 
          isSampleEdge = (lastSck == 1 && sck == 0); 
        }
        else if (cpol == 1 && cpha == 0) { 
          isSampleEdge = (lastSck == 1 && sck == 0); 
        }
        else if (cpol == 1 && cpha == 1) { 
          isSampleEdge = (lastSck == 0 && sck == 1); 
        }

        if (isSampleEdge) {
          if (phaseClocks == 0) {
            if (pendingPacket != null) {
              pendingPacket.endIndex = i;
              currentFramePackets.add(pendingPacket);
              pendingPacket = null;
            }
            wordStartIdx = i;
          }
          
          pinClocks.putIfAbsent(sckPin, () => []).add(ProtocolClock(index: i, label: (phaseClocks + 1).toString()));
          
          int io0 = mosiPin >= 0 ? getPinState(states, head, count, i, mosiPin) : 0;
          int io1 = misoPin >= 0 ? getPinState(states, head, count, i, misoPin) : 0;
          int io2 = io2Pin >= 0 ? getPinState(states, head, count, i, io2Pin) : 0;
          int io3 = io3Pin >= 0 ? getPinState(states, head, count, i, io3Pin) : 0;

          if (decodeState == 0) { // CMD
            phaseData = (phaseData << 1) | io0;
            phaseClocks++;
            if (phaseClocks == 8) {
              pendingPacket = createPacket(wordStartIdx, phaseData, 1, 'CMD', Colors.purpleAccent, localMosiLane >= 0 ? localMosiLane : 0);
              loadCommandConfig(phaseData);
              
              if (addrBytes > 0) { decodeState = 1; }
              else if (modeClocks > 0) { decodeState = 2; }
              else if (dummyClocks > 0) { decodeState = 3; }
              else { decodeState = 4; }
              
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 1) { // ADDR
            int bitVal = 0;
            if (addrLines == 4) { bitVal = (io3 << 3) | (io2 << 2) | (io1 << 1) | io0; }
            else if (addrLines == 2) { bitVal = (io1 << 1) | io0; }
            else { bitVal = io0; }

            phaseData = (phaseData << addrLines) | bitVal;
            phaseClocks++;
            
            if (phaseClocks == (addrBytes * 8 ~/ addrLines)) {
              pendingPacket = createPacket(wordStartIdx, phaseData, addrBytes, 'ADDR', Colors.blue, localMosiLane >= 0 ? localMosiLane : 0);
              if (modeClocks > 0) { decodeState = 2; }
              else if (dummyClocks > 0) { decodeState = 3; }
              else { decodeState = 4; }
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 2) { // MODE
            int bitVal = 0;
            if (addrLines == 4) { bitVal = (io3 << 3) | (io2 << 2) | (io1 << 1) | io0; }
            else if (addrLines == 2) { bitVal = (io1 << 1) | io0; }
            else { bitVal = io0; }

            phaseData = (phaseData << addrLines) | bitVal;
            phaseClocks++;
            
            if (phaseClocks == modeClocks) {
              pendingPacket = createPacket(wordStartIdx, phaseData, (modeClocks * addrLines) ~/ 8 > 0 ? (modeClocks * addrLines) ~/ 8 : 1, 'MODE', Colors.deepOrange, localMosiLane >= 0 ? localMosiLane : 0);
              if (dummyClocks > 0) { decodeState = 3; }
              else { decodeState = 4; }
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 3) { // DUMMY
            phaseClocks++;
            if (phaseClocks == dummyClocks) {
              if (dataLines > 0) { decodeState = 4; }
              else { decodeState = 5; } // END
              phaseClocks = 0; phaseData = 0;
            }
          } else if (decodeState == 4) { // DATA
            int bitVal = 0;
            // In read mode, data comes from MISO. In Dual/Quad it uses all lines.
            // Let's just blindly aggregate lines based on dataLines.
            if (dataLines == 4) { bitVal = (io3 << 3) | (io2 << 2) | (io1 << 1) | io0; }
            else if (dataLines == 2) { bitVal = (io1 << 1) | io0; }
            else { bitVal = io1; } // Default read is on MISO (io1). (Write would be io0, but they're mostly reads)
            // Note: During Page Program (write), data is on MOSI (io0). 
            // In Regfile, we have `access`: "W".
            // So let's check access:
            bool isWrite = false;
            if (protocolData != null && protocolData!['registers'] != null) {
              var reg = protocolData!['registers'][cmdValue];
              if (reg != null && reg.access == 'W') isWrite = true;
            }
            if (dataLines == 1 && isWrite) bitVal = io0;

            phaseData = (phaseData << dataLines) | bitVal;
            phaseClocks++;
            
            if (phaseClocks == (8 ~/ dataLines)) {
              pendingPacket = createPacket(wordStartIdx, phaseData, 1, 'DATA', Colors.green, localMisoLane >= 0 ? localMisoLane : 0);
              phaseClocks = 0; phaseData = 0;
            }
          }
        }
      }

      lastCs = cs;
      lastSck = sck;
      i++;
    }
    
    // Add pending packet if truncated
    if (pendingPacket != null) {
      pendingPacket.endIndex = count;
      currentFramePackets.add(pendingPacket);
    }
    
    // Add pending frame if truncated
    if (inFrame && currentFramePackets.isNotEmpty) {
      frames.add(ProtocolFrame(
        startIndex: frameStartIndex,
        endIndex: count,
        summary: 'Cmd: 0x${cmdValue.toRadixString(16).toUpperCase()} (Incomplete)',
        packets: List.from(currentFramePackets),
      ));
    }
    
    packets.clear();
    for (var f in frames) {
      packets.addAll(f.packets);
    }
  }

}