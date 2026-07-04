import 'dart:typed_data';

void main() {
    const int sampleRate = 2000000;
    int baudRate = 115200;
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
    
    List<int> txBytes = [0xAA, 0x55, 0x80, 0x01, 0x04, 0x00, 0x10, 0x27, 0x00, 0x00];
    int txStart = (0.002 * sampleRate).toInt();
    drawBytes(txBytes, txStart, 3);
    
    int txEnd = txStart + (txBytes.length * 10 * samplesPerBit).toInt();
    int gapSamples = (0.005 * sampleRate).toInt();
    int rxStart = txEnd + gapSamples;
    
    List<int> rxBytes = [0xAA, 0x55, 0x40, 0x01, 0x04, 0x00, 0x10, 0x27, 0x00, 0x00];
    drawBytes(rxBytes, rxStart, 2);

    int countD2Low = 0;
    int countD3Low = 0;
    for (int i = 0; i < totalSamples; i++) {
        if ((data[i] & (1<<2)) == 0) countD2Low++;
        if ((data[i] & (1<<3)) == 0) countD3Low++;
    }
    // ignore: avoid_print
    print('D2 Low Count: $countD2Low');
    // ignore: avoid_print
    print('D3 Low Count: $countD3Low');
}

