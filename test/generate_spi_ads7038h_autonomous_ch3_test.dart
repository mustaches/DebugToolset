import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/oscilloscope_state.dart';
import 'package:debug_tool_set/providers/terminal_state.dart';
import 'package:debug_tool_set/utils/waveform_storage.dart';
import 'package:debug_tool_set/modules/oscilloscope/models/protocol_decoder.dart';
import 'dart:typed_data';
import 'dart:math';

void main() {
  test('Generate SPI ADS7038H Autonomous Mode Ch3 Waveform', () async {
    const int sampleRate = 100000000; // 100 MHz
    const int spiBaud = 25000000;    // 25 MHz
    
    TerminalState tState = TerminalState();
    OscilloscopeState state = OscilloscopeState(tState);
    state.setSampleRate(sampleRate.toDouble());
    
    state.digitalChannel.enabledPins.addAll([0, 1, 2, 3]);
    state.digitalChannel.pinNames[0] = 'CS';
    state.digitalChannel.pinNames[1] = 'SCLK';
    state.digitalChannel.pinNames[2] = 'MOSI';
    state.digitalChannel.pinNames[3] = 'MISO';
    
    state.addDigitalBus('SPI_ADS7038H', 0, 3, DigitalBusFormat.hex, decoder: Ads7038hDecoder(csPin: 0, sckPin: 1, mosiPin: 2, misoPin: 3));

    double samplesPerBit = sampleRate / spiBaud;
    int totalSamples = (0.01 * sampleRate).toInt(); // 10ms max
    
    Uint32List data = Uint32List(totalSamples);
    int idleState = (1 << 0); // CS high, others low
    for (int i = 0; i < totalSamples; i++) {
      data[i] = idleState;
    }
    
    int currentSample = (0.0001 * sampleRate).toInt();
    
    void addDelay(double seconds) {
        currentSample += (seconds * sampleRate).toInt();
    }
    
    // Command frames are always 24 clocks (8-bit cmd, 8-bit addr, 8-bit data)
    void drawCommandFrame(int cmd, int addr, int val) {
       int sckPin = 1;
       int mosiPin = 2;
       
       // CS low
       for (int i = 0; i < 10; i++) {
          data[currentSample++] = 0; // CS low, SCLK low
       }
       
       int frameVal = (cmd << 16) | (addr << 8) | val;
       
       for (int bit = 23; bit >= 0; bit--) {
          int mosiBit = (frameVal >> bit) & 1;
          int pinState = (mosiBit << mosiPin);
          
          // First half (SCLK low)
          for (int s = 0; s < samplesPerBit / 2; s++) {
             data[currentSample++] = pinState; 
          }
          // Second half (SCLK high)
          for (int s = 0; s < samplesPerBit / 2; s++) {
             data[currentSample++] = pinState | (1 << sckPin);
          }
       }
       
       // CS high
       for (int i = 0; i < 10; i++) {
          data[currentSample++] = idleState; 
       }
    }
    
    // Reading data is exactly 12 clocks
    void drawDataReadFrame12Bit(int misoVal) {
       int sckPin = 1;
       int misoPin = 3;
       
       // CS low
       for (int i = 0; i < 10; i++) {
          data[currentSample++] = 0; // CS low, SCLK low
       }
       
       for (int bit = 11; bit >= 0; bit--) {
          int misoBit = (misoVal >> bit) & 1;
          int pinState = (misoBit << misoPin);
          
          // First half (SCLK low)
          for (int s = 0; s < samplesPerBit / 2; s++) {
             data[currentSample++] = pinState; 
          }
          // Second half (SCLK high)
          for (int s = 0; s < samplesPerBit / 2; s++) {
             data[currentSample++] = pinState | (1 << sckPin);
          }
       }
       
       // CS high
       for (int i = 0; i < 10; i++) {
          data[currentSample++] = idleState; 
       }
    }
    
    // Command definitions
    final int cmdWrite = 0x08;
    
    // Registers
    final int regGeneralCfg   = 0x01;
    final int regOpmodeCfg    = 0x04;
    final int regSequenceCfg  = 0x10;
    final int regAutoSeqCh    = 0x12;
    
    // 1. Reset via GENERAL_CFG (bit 0 = RST)
    drawCommandFrame(cmdWrite, regGeneralCfg, 0x01);
    addDelay(0.00005);
    
    // 2. Configure Autonomous Mode for CH3
    // AUTO_SEQ_CH_SEL: bit 3 = 1 -> 0x08
    drawCommandFrame(cmdWrite, regAutoSeqCh, 0x08);
    addDelay(0.00001);
    
    // OPMODE_CFG: CONV_MODE=01b (Autonomous) -> 0x01
    drawCommandFrame(cmdWrite, regOpmodeCfg, 0x01);
    addDelay(0.00001);
    
    // SEQUENCE_CFG: SEQ_MODE=01b (Auto), SEQ_START=1 -> 0x11
    drawCommandFrame(cmdWrite, regSequenceCfg, 0x11);
    addDelay(0.00005);
    
    // 3. Continuous AD sampling of channel 3 with 1KHz 5Vpp sine wave
    double freq = 1000.0;
    double t = 0.0;
    
    // Provide the first start of conversion (dummy read as mentioned in modes)
    drawDataReadFrame12Bit(0x000);
    addDelay(0.000001);
    
    for (int i = 0; i < 2500; i++) {
       // Sine wave: value = 2048 + 2047 * sin(2 * pi * freq * t)
       // (5Vpp -> Amplitude is 2.5V. Assuming 5.0V reference, 2.5V = 4095/5.0*2.5 ≈ 2047 ADC units)
       int adcVal = (2048.0 + 2047.0 * sin(2 * pi * freq * t)).toInt();
       if (adcVal < 0) adcVal = 0;
       if (adcVal > 4095) adcVal = 4095;
       
       int frameStartSample = currentSample;
       // Output exactly 12 bits data on MISO
       drawDataReadFrame12Bit(adcVal);
       
       int frameSamples = currentSample - frameStartSample;
       int remainingSamples = 100 - frameSamples; // 100 samples @ 100MHz = 1us = 1Msps
       for(int s = 0; s < remainingSamples; s++) {
           data[currentSample++] = idleState;
       }
       t += 0.000001; // 1us step
    }
    
    for (int i = 0; i < currentSample; i++) {
      state.digitalChannel.addPoint(data[i]);
    }
    
    String filename = 'waveform/mock_spi_ads7038h_autonomous_ch3.waveform';
    await WaveformStorage.saveWaveform(filename, state);
    print("Saved waveform");
  });
}
