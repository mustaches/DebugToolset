// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/oscilloscope_state.dart';
import 'package:debug_tool_set/providers/terminal_state.dart';
import 'package:debug_tool_set/utils/waveform_storage.dart';
import 'package:debug_tool_set/modules/oscilloscope/models/protocol_decoder.dart';
import 'dart:typed_data';

void main() {
  test('Generate OAS UART Mock Waveforms', () async {
    const int sampleRate = 2000000;
    const int baudRate = 115200;
    
    print('Generating OAS-1000D100 UART Mock Waveform at $baudRate baud...');
  
  TerminalState tState = TerminalState();
  OscilloscopeState state = OscilloscopeState(tState);
  state.setSampleRate(sampleRate.toDouble());
  
  state.digitalChannel.enabledPins.addAll([2, 3]);
  state.digitalChannel.pinNames[2] = 'RXD';
  state.digitalChannel.pinNames[3] = 'TXD';
  
  state.addDigitalBus('UART', 2, 3, DigitalBusFormat.hex, decoder: UartDecoder(rxPin: 2, txPin: 3, baudRate: baudRate));

  List<int> calculateChecksum(List<int> bytes) {
    int sum = 0;
    for (int i = 2; i < bytes.length; i++) {
      sum += bytes[i];
    }
    bytes.add(sum & 0xFF);
    return bytes;
  }

  // 1. External Circuit Enable
  List<int> tx1 = calculateChecksum([0x55, 0xAA, 0x70, 0xAB, 0xCD, 0x00, 0x00]);
  List<int> rx1 = calculateChecksum([0x55, 0xAA, 0x70, 0x01, 0x00, 0x00, 0x00]);

  // 2. Single Measurement
  List<int> tx2 = calculateChecksum([0x55, 0xAA, 0x88, 0xFF, 0xFF, 0xFF, 0xFF]);
  List<int> rx2 = calculateChecksum([0x55, 0xAA, 0x88, 0x01, 0xFF, 0x01, 0x23]);

  // 3. Angle Measurement
  List<int> tx3 = calculateChecksum([0x55, 0xAA, 0x8A, 0xFF, 0xFF, 0xFF, 0xFF]);
  List<int> rx3 = calculateChecksum([0x55, 0xAA, 0x8A, 0x01, 0xFF, 0x00, 0x45]);
  
  double samplesPerBit = sampleRate / baudRate;
  
  // Create a relatively large buffer to hold all the data
  int totalSamples = (0.2 * sampleRate).toInt(); // 200ms
  
  Uint32List data = Uint32List(totalSamples);
  int idleState = (1 << 2) | (1 << 3); // RXD and TXD high
  for (int i = 0; i < totalSamples; i++) {
    data[i] = idleState;
  }
  
  void drawBytes(List<int> bytes, int startSample, int pin) {
    double currentStart = startSample.toDouble();
    for (int byte in bytes) {
       // 1 start bit (0), 8 data bits, 1 stop bit (1)
       int bits = (byte << 1) | 0x200;
       for (int bit = 0; bit < 10; bit++) {
          int bitVal = (bits >> bit) & 1;
          int bitStart = (currentStart + bit * samplesPerBit).toInt();
          int bitEnd = (currentStart + (bit + 1) * samplesPerBit).toInt();
          
          for (int idx = bitStart; idx < bitEnd; idx++) {
            if (idx < totalSamples) {
               if (bitVal == 1) {
                   data[idx] |= (1 << pin);
               } else {
                   data[idx] &= ~(1 << pin);
               }
            }
          }
       }
       currentStart += 10 * samplesPerBit;
    }
  }
  
  int currentPos = (0.005 * sampleRate).toInt(); // Start at 5ms
  
  // Function to draw a command interaction
  void drawInteraction(List<int> tx, List<int> rx) {
    drawBytes(tx, currentPos, 3);
    currentPos += (tx.length * 10 * samplesPerBit).toInt();
    
    // Gap before response (2ms)
    currentPos += (0.002 * sampleRate).toInt();
    
    drawBytes(rx, currentPos, 2);
    currentPos += (rx.length * 10 * samplesPerBit).toInt();
    
    // Gap before next command (15ms)
    currentPos += (0.015 * sampleRate).toInt();
  }
  
  drawInteraction(tx1, rx1);
  drawInteraction(tx2, rx2);
  drawInteraction(tx3, rx3);

  // Stop at the actual end of data to save space
  int actualEndSamples = currentPos + (0.005 * sampleRate).toInt();
  if (actualEndSamples > totalSamples) actualEndSamples = totalSamples;

  for (int i = 0; i < actualEndSamples; i++) {
    state.digitalChannel.addPoint(data[i]);
  }
  
  String filename = 'mock_oas1000d100_uart.dtw';
  await WaveformStorage.saveWaveform(filename, state);
  print('Saved $filename to root directory.');
  });
}
