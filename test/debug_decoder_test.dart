import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:debug_tool_set/modules/oscilloscope/models/protocol_decoder.dart';
import 'dart:typed_data';

void main() {
  test('Debug Ads7038hDecoder', () {
    var decoder = Ads7038hDecoder(csPin: 0, sckPin: 1, mosiPin: 2, misoPin: 3);
    List<int> states = [];
    
    // 12 clocks
    states.add(1); // CS=1
    states.add(0); // CS=0
    
    int adcValue = 0x8AA; 
    for (int i = 0; i < 12; i++) {
        int bit = (adcValue >> (11 - i)) & 1;
        states.add( (bit << 3) | (1 << 1) );
        states.add( (bit << 3) | (0 << 1) );
    }
    states.add(1); // CS=1
    
    var stateList = Uint32List.fromList(states);
    decoder.decode(stateList, 0, stateList.length, 1000000);
    
    print('Decoded packets count: ' + decoder.packets.length.toString());
    for (var p in decoder.packets) {
       print('Packet: ' + p.data + ', Lane: ' + p.laneIndex.toString() + ', Type: ' + p.type.toString());
    }
  });
}
