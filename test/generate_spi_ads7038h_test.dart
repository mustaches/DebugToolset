import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/oscilloscope_state.dart';
import 'package:debug_tool_set/providers/terminal_state.dart';
import 'package:debug_tool_set/utils/waveform_storage.dart';
import 'package:debug_tool_set/modules/oscilloscope/models/protocol_decoder.dart';
import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';

void main() {
  test('Generate SPI ADS7038H Waveforms', () async {
    const int sampleRate = 2000000;
    const int spiBaud = 100000;
    
    // ignore: avoid_print
    print('Generating SPI for ADS7038H...');
    
    TerminalState tState = TerminalState();
    OscilloscopeState state = OscilloscopeState(tState);
    state.setSampleRate(sampleRate.toDouble());
    
    state.digitalChannel.enabledPins.addAll([0, 1, 2, 3]);
    state.digitalChannel.pinNames[0] = 'CS';
    state.digitalChannel.pinNames[1] = 'SCLK';
    state.digitalChannel.pinNames[2] = 'MOSI';
    state.digitalChannel.pinNames[3] = 'MISO';
    
    state.addDigitalBus('SPI_ADS7038H', 0, 3, DigitalBusFormat.hex, decoder: SpiDecoder(csPin: 0, sckPin: 1, mosiPin: 2, misoPin: 3, protocolFile: 'ADS7038H', cpol: 0, cpha: 0, dataBits: 8, lsbFirst: false));

    double samplesPerBit = sampleRate / spiBaud;
    int totalSamples = (1.0 * sampleRate).toInt(); // 1.0 sec
    
    Uint32List data = Uint32List(totalSamples);
    int idleState = (1 << 0); // CS high, others low
    for (int i = 0; i < totalSamples; i++) {
      data[i] = idleState;
    }
    
    int currentSample = (0.01 * sampleRate).toInt();
    
    void drawSpiFrame(List<int> mosiBytes, List<int> misoBytes) {
       int sckPin = 1;
       int mosiPin = 2;
       int misoPin = 3;
       
       // CS low
       for (int i = 0; i < (0.0001 * sampleRate).toInt(); i++) {
          data[currentSample++] = 0; // CS low, SCLK low
       }
       
       for (int i = 0; i < mosiBytes.length; i++) {
          int mosiB = mosiBytes[i];
          int misoB = i < misoBytes.length ? misoBytes[i] : 0;
          for (int bit = 7; bit >= 0; bit--) {
             int mosiBit = (mosiB >> bit) & 1;
             int misoBit = (misoB >> bit) & 1;
             int pinState = (mosiBit << mosiPin) | (misoBit << misoPin);
             
             // First half (SCLK low)
             for (int s = 0; s < samplesPerBit / 2; s++) {
                data[currentSample++] = pinState; 
             }
             
             // Second half (SCLK high)
             for (int s = 0; s < samplesPerBit / 2; s++) {
                data[currentSample++] = pinState | (1 << sckPin);
             }
          }
       }
       
       // CS high
       for (int i = 0; i < (0.0001 * sampleRate).toInt(); i++) {
          data[currentSample++] = idleState; 
       }
       
       // Gap
       for (int i = 0; i < (0.001 * sampleRate).toInt(); i++) {
          data[currentSample++] = idleState; 
       }
    }
    
    // 1. NOP (just once)
    drawSpiFrame([0x00, 0x00, 0x00], [0x00, 0x00, 0x00]);
    
    // Read the Regfile to get all register addresses
    File regfile = File('DeviceProtocol/SPI/ADS7038H.Regfile');
    if (regfile.existsSync()) {
      String content = regfile.readAsStringSync();
      Map<String, dynamic> json = jsonDecode(content);
      Map<String, dynamic> registers = json['registers'] ?? {};
      
      List<int> addresses = [];
      registers.forEach((key, value) {
        if (key.startsWith('0x')) {
          addresses.add(int.parse(key.substring(2), radix: 16));
        } else {
          addresses.add(int.parse(key));
        }
      });
      addresses.sort(); // Sort addresses
      
      for (int addr in addresses) {
         // Command 0x08: Single register write (Data: 0x55)
         drawSpiFrame([0x08, addr, 0x55], [0x00, 0x00, 0x00]);
         
         // Command 0x10: Single register read (expecting 0x55 back)
         drawSpiFrame([0x10, addr, 0x00], [0x00, 0x00, 0x00]); // Req
         drawSpiFrame([0x00, 0x00, 0x00], [0x55, 0x00, 0x00]); // Resp
         
         // Command 0x18: Set bit (Data: 0x01)
         drawSpiFrame([0x18, addr, 0x01], [0x00, 0x00, 0x00]);
         
         // Command 0x20: Clear bit (Data: 0x01)
         drawSpiFrame([0x20, addr, 0x01], [0x00, 0x00, 0x00]);
      }
    }
    
    for (int i = 0; i < currentSample; i++) {
      state.digitalChannel.addPoint(data[i]);
    }
    
    String filename = 'waveform/mock_spi_ads7038h_full.waveform';
    await WaveformStorage.saveWaveform(filename, state);
    // ignore: avoid_print
    print('Saved $filename');
  });
}
