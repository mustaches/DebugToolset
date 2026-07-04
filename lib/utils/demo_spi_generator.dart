import 'dart:math';

/// Generates a mock SPI sequence representing a variety of commands and communication 
/// for the W25Q64JW SPI Flash.
/// The pins are mapped as follows (offsets from bit 0):
/// 0: nCS (Active Low)
/// 1: SCLK
/// 2: MOSI / IO0
/// 3: MISO / IO1
/// 4: nWP / IO2
/// 5: nHOLD / IO3
/// 
/// Note: The returned sequence contains states where only bits 0-5 are used.
/// The caller (e.g. oscilloscope_state.dart) should shift these bits to the correct position (D24-D29).
List<int> generateW25Q64JwSpiSequence() {
  List<int> sequence = [];
  int currentState = (1 << 0) | (1 << 4) | (1 << 5); // nCS=1, nWP=1, nHOLD=1

  void addState(int duration) {
    for (int i = 0; i < duration; i++) {
      sequence.add(currentState);
    }
  }

  void setPin(int offset, int val) {
    if (val == 1) {
      currentState |= (1 << offset);
    } else {
      currentState &= ~(1 << offset);
    }
  }

  void csLow() { setPin(0, 0); addState(4); }
  void csHigh() { setPin(0, 1); addState(10); }

  void transferOutByte(int val) {
    for (int i = 7; i >= 0; i--) {
      setPin(2, (val >> i) & 1); // MOSI
      setPin(3, 0); // MISO Idle
      addState(1);
      setPin(1, 1); // SCLK high
      addState(2);
      setPin(1, 0); // SCLK low
      addState(1);
    }
  }

  void transferInByte(int val) {
    for (int i = 7; i >= 0; i--) {
      setPin(2, 0); // MOSI Idle
      setPin(3, (val >> i) & 1); // MISO
      addState(1);
      setPin(1, 1); // SCLK high
      addState(2);
      setPin(1, 0); // SCLK low
      addState(1);
    }
  }
  
  void transferDualOutByte(int val) {
    for (int i = 3; i >= 0; i--) {
      setPin(2, (val >> (i * 2)) & 1);     // IO0
      setPin(3, (val >> (i * 2 + 1)) & 1); // IO1
      addState(1);
      setPin(1, 1); // SCLK high
      addState(2);
      setPin(1, 0); // SCLK low
      addState(1);
    }
  }
  
  void transferDualInByte(int val) {
    for (int i = 3; i >= 0; i--) {
      setPin(2, (val >> (i * 2)) & 1);     // IO0
      setPin(3, (val >> (i * 2 + 1)) & 1); // IO1
      addState(1);
      setPin(1, 1); // SCLK high
      addState(2);
      setPin(1, 0); // SCLK low
      addState(1);
    }
  }

  void transferQuadOutByte(int val) {
    for (int i = 1; i >= 0; i--) {
      setPin(2, (val >> (i * 4 + 0)) & 1); // IO0
      setPin(3, (val >> (i * 4 + 1)) & 1); // IO1
      setPin(4, (val >> (i * 4 + 2)) & 1); // IO2
      setPin(5, (val >> (i * 4 + 3)) & 1); // IO3
      addState(1);
      setPin(1, 1); // SCLK high
      addState(2);
      setPin(1, 0); // SCLK low
      addState(1);
    }
  }
  
  void transferQuadInByte(int val) {
    for (int i = 1; i >= 0; i--) {
      setPin(2, (val >> (i * 4 + 0)) & 1); // IO0
      setPin(3, (val >> (i * 4 + 1)) & 1); // IO1
      setPin(4, (val >> (i * 4 + 2)) & 1); // IO2
      setPin(5, (val >> (i * 4 + 3)) & 1); // IO3
      addState(1);
      setPin(1, 1); // SCLK high
      addState(2);
      setPin(1, 0); // SCLK low
      addState(1);
    }
  }

  void address24(int addr) {
    transferOutByte((addr >> 16) & 0xFF);
    transferOutByte((addr >> 8) & 0xFF);
    transferOutByte(addr & 0xFF);
  }
  
  void address24Dual(int addr) {
    transferDualOutByte((addr >> 16) & 0xFF);
    transferDualOutByte((addr >> 8) & 0xFF);
    transferDualOutByte(addr & 0xFF);
  }
  
  void address24Quad(int addr) {
    transferQuadOutByte((addr >> 16) & 0xFF);
    transferQuadOutByte((addr >> 8) & 0xFF);
    transferQuadOutByte(addr & 0xFF);
  }

  Random rand = Random(42);

  addState(50); // Initial idle

  // 1. Write Enable (06h)
  csLow(); transferOutByte(0x06); csHigh(); addState(20);

  // 2. Read Status Register-1 (05h)
  csLow(); transferOutByte(0x05); transferInByte(0x02); // WEL=1
  csHigh(); addState(20);

  // 3. Page Program (02h)
  csLow(); transferOutByte(0x02); address24(0x000100);
  for (int i = 0; i < 32; i++) { 
    transferOutByte(rand.nextInt(256));
  }
  csHigh(); addState(50);

  // 4. Read Data (03h)
  csLow(); transferOutByte(0x03); address24(0x000100);
  for (int i = 0; i < 32; i++) {
    transferInByte(rand.nextInt(256));
  }
  csHigh(); addState(20);

  // 5. Fast Read (0Bh)
  csLow(); transferOutByte(0x0B); address24(0x000200); transferOutByte(0xFF); // 1 dummy byte
  for (int i = 0; i < 16; i++) {
    transferInByte(rand.nextInt(256));
  }
  csHigh(); addState(20);

  // 6. Fast Read Dual Output (3Bh)
  csLow(); transferOutByte(0x3B); address24(0x000300); transferOutByte(0xFF); // 1 dummy byte
  for (int i = 0; i < 16; i++) {
    transferDualInByte(rand.nextInt(256));
  }
  csHigh(); addState(20);

  // 7. Fast Read Quad Output (6Bh)
  csLow(); transferOutByte(0x6B); address24(0x000400); transferOutByte(0xFF); // 1 dummy byte
  for (int i = 0; i < 16; i++) {
    transferQuadInByte(rand.nextInt(256));
  }
  csHigh(); addState(20);

  // 8. Fast Read Dual I/O (BBh)
  csLow(); transferOutByte(0xBB); address24Dual(0x000500); transferDualOutByte(0xFF); // mode
  for (int i = 0; i < 16; i++) {
    transferDualInByte(rand.nextInt(256));
  }
  csHigh(); addState(20);

  // 9. Fast Read Quad I/O (EBh)
  csLow(); transferOutByte(0xEB); address24Quad(0x000600); transferQuadOutByte(0xFF); // mode
  transferQuadOutByte(0xFF); // dummy
  for (int i = 0; i < 16; i++) {
    transferQuadInByte(rand.nextInt(256));
  }
  csHigh(); addState(20);

  // 10. Quad Input Page Program (32h)
  csLow(); transferOutByte(0x32); address24(0x000700);
  for (int i = 0; i < 32; i++) {
    transferQuadOutByte(rand.nextInt(256));
  }
  csHigh(); addState(50);

  // 11. Read JEDEC ID (9Fh)
  csLow(); transferOutByte(0x9F); transferInByte(0xEF); transferInByte(0x60); transferInByte(0x17);
  csHigh(); addState(20);

  // 12. Read Manufacturer/Device ID (90h)
  csLow(); transferOutByte(0x90); address24(0x000000); transferInByte(0xEF); transferInByte(0x16);
  csHigh(); addState(20);

  // 13. Read Unique ID (4Bh)
  csLow(); transferOutByte(0x4B); 
  transferOutByte(0xFF); transferOutByte(0xFF); transferOutByte(0xFF); transferOutByte(0xFF); // 4 dummy bytes
  for (int i = 0; i < 8; i++) {
    transferInByte(rand.nextInt(256)); // 64-bit ID
  }
  csHigh(); addState(20);

  // 14. Sector Erase 4KB (20h)
  csLow(); transferOutByte(0x20); address24(0x001000);
  csHigh(); addState(50);
  
  // 15. Block Erase 32KB (52h)
  csLow(); transferOutByte(0x52); address24(0x008000);
  csHigh(); addState(50);

  // 16. Block Erase 64KB (D8h)
  csLow(); transferOutByte(0xD8); address24(0x010000);
  csHigh(); addState(50);
  
  // 17. Chip Erase (C7h)
  csLow(); transferOutByte(0xC7);
  csHigh(); addState(50);

  // 18. Power-down (B9h)
  csLow(); transferOutByte(0xB9);
  csHigh(); addState(50);

  // 19. Release Power-down / Device ID (ABh)
  csLow(); transferOutByte(0xAB); transferOutByte(0xFF); transferOutByte(0xFF); transferOutByte(0xFF); transferInByte(0x16);
  csHigh(); addState(20);

  // 20. Erase/Program Suspend (75h)
  csLow(); transferOutByte(0x75);
  csHigh(); addState(20);

  // 21. Erase/Program Resume (7Ah)
  csLow(); transferOutByte(0x7A);
  csHigh(); addState(20);

  // 22. Write Status Register 1 (01h)
  csLow(); transferOutByte(0x01); transferOutByte(0x00);
  csHigh(); addState(20);
  
  // 23. Write Enable for Volatile Status Register (50h)
  csLow(); transferOutByte(0x50); csHigh(); addState(20);

  // 24. Read SFDP Register (5Ah)
  csLow(); transferOutByte(0x5A); address24(0x000000); transferOutByte(0xFF); // 1 dummy byte
  for (int i = 0; i < 16; i++) {
    transferInByte(rand.nextInt(256));
  }
  csHigh(); addState(20);

  // 25. Mftr./Device ID Dual I/O (92h)
  csLow(); transferOutByte(0x92); 
  address24Dual(0x000000); 
  transferDualOutByte(0xFF); // mode / dummy
  transferDualInByte(0xEF); // Winbond Manufacturer ID
  transferDualInByte(0x16); // Device ID
  csHigh(); addState(20);

  // 26. Mftr./Device ID Quad I/O (94h)
  csLow(); transferOutByte(0x94); 
  address24Quad(0x000000); 
  transferQuadOutByte(0xFF); // mode
  transferQuadOutByte(0xFF); // dummy
  transferQuadOutByte(0xFF); // dummy
  transferQuadInByte(0xEF); // Winbond Manufacturer ID
  transferQuadInByte(0x16); // Device ID
  csHigh(); addState(20);

  // 27. Set Burst with Wrap (77h)
  csLow(); transferOutByte(0x77); 
  transferQuadOutByte(0xFF); transferQuadOutByte(0xFF); transferQuadOutByte(0xFF); // 3 dummy bytes (quad)
  transferQuadOutByte(0x00); // W7-W0
  csHigh(); addState(20);

  // 28. Enable Reset (66h) & Reset Device (99h)
  csLow(); transferOutByte(0x66); csHigh(); addState(20);
  csLow(); transferOutByte(0x99); csHigh(); addState(50);

  return sequence;
}
