import 'package:debug_tool_set/modules/oscilloscope/models/protocol_decoder.dart';
import 'dart:typed_data';

void main() {
    int baudRate = 115200;
    double sampleRate = 500000;
    double samplesPerBitUart = sampleRate / baudRate;
    int uartTotalSamples = (0.05 * sampleRate).toInt(); // 50ms period
    
    Uint32List uartSequence = Uint32List(uartTotalSamples);
    int uartIdle = (1 << 2) | (1 << 3);
    for (int i = 0; i < uartTotalSamples; i++) {
        uartSequence[i] = uartIdle;
    }
    
    void drawUartBytes(List<int> bytes, int startSample, int pin) {
        double currentStart = startSample.toDouble();
        for (int byte in bytes) {
           int bits = (byte << 1) | 0x200;
           for (int bit = 0; bit < 10; bit++) {
              int bitVal = (bits >> bit) & 1;
              int bitStart = (currentStart + bit * samplesPerBitUart).toInt();
              int bitEnd = (currentStart + (bit + 1) * samplesPerBitUart).toInt();
              for (int idx = bitStart; idx < bitEnd; idx++) {
                if (idx < uartTotalSamples) {
                   if (bitVal == 1) {
                       uartSequence[idx] |= (1 << pin);
                   } else {
                       uartSequence[idx] &= ~(1 << pin);
                   }
                }
              }
           }
           currentStart += 10 * samplesPerBitUart;
        }
    }
    
    List<int> txBytes = [0xAA, 0x55, 0x80, 0x01, 0x04, 0x00, 0x10, 0x27, 0x00, 0x00];
    int txStart = (0.002 * sampleRate).toInt();
    drawUartBytes(txBytes, txStart, 3);
    
    var decoder = UartDecoder(rxPin: 2, txPin: 3, baudRate: 115200);
    decoder.decode(uartSequence, 0, uartTotalSamples, sampleRate);
    
    for (var frame in decoder.frames) {
        // ignore: avoid_print
        print('Frame: ${frame.summary}');
        for (var pkt in frame.packets) {
            // ignore: avoid_print
            print('  ${pkt.data}');
        }
    }
}

