import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/oscilloscope_state.dart';
import 'package:debug_tool_set/providers/terminal_state.dart';
import 'package:debug_tool_set/utils/waveform_storage.dart';
import 'package:debug_tool_set/modules/oscilloscope/models/protocol_decoder.dart';
import 'dart:typed_data';

void main() {
  test('Generate SPI ADS7038H Modes Waveforms', () async {
    const int sampleRate = 2000000;
    const int spiBaud = 100000;
    
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
    // 2 seconds max
    int totalSamples = (2.0 * sampleRate).toInt(); 
    
    Uint32List data = Uint32List(totalSamples);
    int idleState = (1 << 0); // CS high, others low
    for (int i = 0; i < totalSamples; i++) {
      data[i] = idleState;
    }
    
    int currentSample = (0.01 * sampleRate).toInt();
    
    void addDelay(double seconds) {
        currentSample += (seconds * sampleRate).toInt();
    }
    
    void drawSpiFrame(List<int> mosiBytes, List<int> misoBytes) {
       int sckPin = 1;
       int mosiPin = 2;
       int misoPin = 3;
       
       // CS low
       for (int i = 0; i < (0.0001 * sampleRate).toInt(); i++) {
          data[currentSample++] = 0; // CS low, SCLK low
       }
       
       int numBytes = mosiBytes.length > misoBytes.length ? mosiBytes.length : misoBytes.length;
       
       for (int i = 0; i < numBytes; i++) {
          int mosiB = i < mosiBytes.length ? mosiBytes[i] : 0;
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
    
    // Command definitions
    final int cmdWrite = 0x08;
    final int cmdRead  = 0x10;
    
    // Registers
    final int regSystemStatus = 0x00;
    final int regGeneralCfg   = 0x01;
    final int regOpmodeCfg    = 0x04;
    final int regSequenceCfg  = 0x10;
    final int regChannelSel   = 0x11;
    final int regAutoSeqCh   = 0x12;
    
    // --- Mode 1: Device Power-Up and Reset ---
    // Reset via GENERAL_CFG (bit 0 = RST)
    drawSpiFrame([cmdWrite, regGeneralCfg, 0x01], []);
    addDelay(0.005);
    // Read SYSTEM_STATUS to verify BOR bit
    drawSpiFrame([cmdRead, regSystemStatus, 0x00], []); // req
    drawSpiFrame([0x00, 0x00, 0x00], [0x81, 0x00, 0x00]); // resp: BOR=1
    
    addDelay(0.01);
    
    // --- Mode 2: Manual Mode ---
    // Write OPMODE_CFG CONV_MODE=00b (0x00)
    drawSpiFrame([cmdWrite, regOpmodeCfg, 0x00], []);
    // Write SEQUENCE_CFG SEQ_MODE=00b (0x00)
    drawSpiFrame([cmdWrite, regSequenceCfg, 0x00], []);
    // Cycle N: Select Channel 2 (MANUAL_CHID = 2)
    drawSpiFrame([cmdWrite, regChannelSel, 0x02], []);
    // Cycle N+1: Sample AIN2
    drawSpiFrame([0x00, 0x00], [0x00, 0x00]); // Dummy conversion cycle
    // Cycle N+2: Data AIN2 available (e.g., read out ADC value)
    drawSpiFrame([0x00, 0x00], [0xA5, 0x5A]); // Assuming 16-bit output frame size
    
    addDelay(0.01);
    
    // --- Mode 3: On-the-Fly Mode ---
    // Write SEQUENCE_CFG SEQ_MODE=10b (0x02)
    drawSpiFrame([cmdWrite, regSequenceCfg, 0x02], []);
    // Cycle N: Send On-the-Fly ID for CH3 (1 0011 000 = 0x98)
    drawSpiFrame([0x98, 0x00], [0xA5, 0x5A]); // reads previous conversion AIN2, commands CH3
    // Cycle N+1: Send On-the-Fly ID for CH5 (1 0101 000 = 0xA8)
    drawSpiFrame([0xA8, 0x00], [0x12, 0x34]); // reads AIN3, commands CH5
    
    addDelay(0.01);
    
    // --- Mode 4: Auto-sequence Mode ---
    // Enable sequencing for AIN2 and AIN6 -> AUTO_SEQ_CH_SEL (bit2=1, bit6=1) = 0x44
    drawSpiFrame([cmdWrite, regAutoSeqCh, 0x44], []);
    // Select Auto-sequence Mode: SEQ_MODE=01b (0x01), SEQ_START=1 (0x10) -> SEQUENCE_CFG = 0x11
    drawSpiFrame([cmdWrite, regSequenceCfg, 0x11], []);
    // Sequence reads
    drawSpiFrame([0x00, 0x00], [0x00, 0x00]); // sample AIN2
    drawSpiFrame([0x00, 0x00], [0x02, 0x22]); // Data AIN2, sample AIN6
    drawSpiFrame([0x00, 0x00], [0x06, 0x66]); // Data AIN6, sample AIN2
    drawSpiFrame([0x00, 0x00], [0x02, 0x22]); // Data AIN2, sample AIN6
    
    addDelay(0.01);
    
    // --- Mode 5: Autonomous Mode ---
    // Set DWC_EN=1 (0x10) and CONV_MODE=01b (0x01) -> OPMODE_CFG = 0x11
    drawSpiFrame([cmdWrite, regOpmodeCfg, 0x11], []);
    // SEQ_START=1 (0x10) in SEQUENCE_CFG (assuming SEQ_MODE=01b still set, so 0x11)
    drawSpiFrame([cmdWrite, regSequenceCfg, 0x11], []);
    addDelay(0.005);
    // Read ALERT flags EVENT_FLAG (0x18)
    drawSpiFrame([cmdRead, 0x18, 0x00], []);
    drawSpiFrame([0x00, 0x00, 0x00], [0x04, 0x00, 0x00]); // ALERT on CH2
    
    addDelay(0.01);
    
    // --- Mode 6: Turbo Comparator Mode ---
    // Set DWC_EN=1 (0x10) and CONV_MODE=10b (0x02) -> OPMODE_CFG = 0x12
    drawSpiFrame([cmdWrite, regOpmodeCfg, 0x12], []);
    // Start turbo (SEQ_START=1, SEQ_MODE=01b)
    drawSpiFrame([cmdWrite, regSequenceCfg, 0x11], []);
    addDelay(0.005);
    // Read ALERT flags EVENT_FLAG (0x18)
    drawSpiFrame([cmdRead, 0x18, 0x00], []);
    drawSpiFrame([0x00, 0x00, 0x00], [0x40, 0x00, 0x00]); // ALERT on CH6
    
    
    for (int i = 0; i < currentSample; i++) {
      state.digitalChannel.addPoint(data[i]);
    }
    
    String filename = 'waveform/mock_spi_ads7038h_modes.waveform';
    await WaveformStorage.saveWaveform(filename, state);
    // ignore: avoid_print
    print('Saved $filename');
  });
}
