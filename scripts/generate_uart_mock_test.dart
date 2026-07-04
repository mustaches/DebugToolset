import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/oscilloscope_state.dart';
import 'package:debug_tool_set/providers/terminal_state.dart';
import 'package:debug_tool_set/utils/waveform_storage.dart';
import 'package:debug_tool_set/modules/oscilloscope/models/protocol_decoder.dart';
import 'dart:typed_data';

void main() {
  test('Generate UART Mock Waveforms', () async {
    const int sampleRate = 2000000;
    
    Future<void> generateUart(int baudRate) async {
      // ignore: avoid_print
      print('Generating UART at $baudRate baud...');
      
      TerminalState tState = TerminalState();
      OscilloscopeState state = OscilloscopeState(tState);
      state.setSampleRate(sampleRate.toDouble());
      
      state.digitalChannel.enabledPins.addAll([2, 3]);
      state.digitalChannel.pinNames[2] = 'RXD';
      state.digitalChannel.pinNames[3] = 'TXD';
      
      state.addDigitalBus('UART_RX', 2, 2, DigitalBusFormat.hex, decoder: UartDecoder(rxPin: 2, baudRate: baudRate));
      state.addDigitalBus('UART_TX', 3, 3, DigitalBusFormat.hex, decoder: UartDecoder(rxPin: 3, baudRate: baudRate));

      List<int> txBytes = [0xAA, 0x55, 0x80, 0x01, 0x04, 0x00, 0x10, 0x27, 0x00, 0x00];
      List<int> rxBytes = [0xAA, 0x55, 0x40, 0x01, 0x04, 0x00, 0x10, 0x27, 0x00, 0x00];
      
      double samplesPerBit = sampleRate / baudRate;
      int totalSamples = (0.05 * sampleRate).toInt();
      
      Uint32List data = Uint32List(totalSamples);
      int idleState = (1 << 2) | (1 << 3);
      for (int i = 0; i < totalSamples; i++) {
        data[i] = idleState;
      }
      
      void drawBytes(List<int> bytes, int startSample, int pin) {
        double currentStart = startSample.toDouble();
        for (int byte in bytes) {
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
      
      int txStart = (0.002 * sampleRate).toInt();
      drawBytes(txBytes, txStart, 3);
      
      int txEnd = txStart + (txBytes.length * 10 * samplesPerBit).toInt();
      int gapSamples = (0.005 * sampleRate).toInt();
      int rxStart = txEnd + gapSamples;
      drawBytes(rxBytes, rxStart, 2);

      for (int i = 0; i < totalSamples; i++) {
        state.digitalChannel.addPoint(data[i]);
      }
      
      String filename = 'mock_uart_$baudRate.dtw';
      await WaveformStorage.saveWaveform(filename, state);
      // ignore: avoid_print
      print('Saved $filename');
    }
    
    await generateUart(115200);
  });
}

