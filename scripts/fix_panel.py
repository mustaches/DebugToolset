import sys

with open(r'g:\DebugToolSet\lib\modules\oscilloscope\widgets\register_info_panel.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find the start index: "    // Extract target address, RW, and data"
start_idx = -1
for i, line in enumerate(lines):
    if "    // Extract target address, RW, and data" in line:
        start_idx = i
        break

# Find the end index: "  }" (end of build method)
end_idx = -1
for i in range(len(lines)-1, -1, -1):
    if lines[i].strip() == "}" and "}" in lines[i-1].strip(): # end of build and class
        end_idx = i - 1
        break

if start_idx != -1 and end_idx != -1:
    new_code = """    // Extract target address first to get the regfile
    int? targetAddress;
    for (var packet in selectedFrame.packets) {
      if (packet.type == PacketType.address && packet.rawValue != null) {
        targetAddress = packet.rawValue;
        break;
      }
    }
    
    if (targetAddress == null) {
      return const Center(child: Text('No address found in frame', style: TextStyle(color: Colors.grey)));
    }
    
    I2cRegfile? regfile = state.getRegfileFor(busName, targetAddress);
    
    if (regfile == null) {
      return Center(
        child: InkWell(
          onTap: () => _showMountRegfileDialog(context, state, busName, targetAddress!),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text('No Regfile mounted for 0x${targetAddress!.toRadixString(16).toUpperCase()} on $busName\\n(Click to mount)', 
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.cyanAccent, decoration: TextDecoration.underline)),
          ),
        )
      );
    }

    bool hasSubaddress = regfile.hasSubaddress ?? true;
    
    // Parse the frame accurately
    bool isWrite = false;
    int? currentSubaddress;
    List<int> payloadBytes = [];
    
    bool currentIsWrite = false;
    bool isTarget = false;
    
    for (var packet in selectedFrame.packets) {
      if (packet.type == PacketType.address && packet.rawValue != null) {
        isTarget = (packet.rawValue == targetAddress);
      } else if (packet.type == PacketType.readWrite) {
        currentIsWrite = packet.data == 'WRITE';
        if (isTarget) isWrite = currentIsWrite; // Last RW wins for the overall operation
      } else if (packet.type == PacketType.data && packet.rawValue != null) {
        if (isTarget) {
          if (currentIsWrite && hasSubaddress) {
            if (currentSubaddress == null) {
              currentSubaddress = packet.rawValue; 
            } else {
              payloadBytes.add(packet.rawValue!);
            }
          } else {
            payloadBytes.add(packet.rawValue!);
          }
        }
      }
    }
    
    // Backward search if subaddress is still null and device has subaddress
    if (hasSubaddress && currentSubaddress == null) {
      int frameIndex = bus.decoder!.frames.indexOf(selectedFrame);
      int offset = 0;
      for (int i = frameIndex - 1; i >= 0; i--) {
        var f = bus.decoder!.frames[i];
        bool fIsTarget = false;
        bool fIsW = false;
        int? fExplicitAddr;
        int fDataCount = 0;
        for (var p in f.packets) {
          if (p.type == PacketType.address && p.rawValue == targetAddress) {
            fIsTarget = true;
          } else if (p.type == PacketType.readWrite) {
            fIsW = (p.data == 'WRITE');
          } else if (fIsTarget && p.type == PacketType.data && p.rawValue != null) {
            if (fIsW && fExplicitAddr == null) {
              fExplicitAddr = p.rawValue;
            } else {
              fDataCount++;
            }
          }
        }
        if (fIsTarget) {
          if (fExplicitAddr != null) {
            currentSubaddress = fExplicitAddr + fDataCount + offset;
            break;
          } else {
            offset += fDataCount;
          }
        }
      }
    }
    
    currentSubaddress ??= 0;

    if (payloadBytes.isEmpty) {
      return const Center(child: Text('No data bytes in frame', style: TextStyle(color: Colors.grey)));
    }

    if (regfile.registers.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              color: const Color(0xFF2A2A2A),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Builder(
                    builder: (context) {
                      String pinConfig = '';
                      if (regfile.addressMap != null && regfile.addressMap!.containsKey(targetAddress)) {
                        pinConfig = ' [Pin Config: ${regfile.addressMap![targetAddress]}]';
                      }
                      return Text('EEPROM: ${regfile.name} (0x${targetAddress!.toRadixString(16).toUpperCase()})$pinConfig - ${isWrite ? 'Write' : 'Read'}', 
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold));
                    }
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      state.closeRegisterInfoPanel();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: (payloadBytes.length / 8).ceil(),
                  itemBuilder: (context, index) {
                     int rowStart = index * 8;
                     int rowAddr = currentSubaddress! + rowStart;
                     List<String> hexBytes = [];
                     List<String> asciiBytes = [];
                     for (int i = 0; i < 8; i++) {
                       if (rowStart + i < payloadBytes.length) {
                         int b = payloadBytes[rowStart + i];
                         hexBytes.add(b.toRadixString(16).padLeft(2, '0').toUpperCase());
                         asciiBytes.add((b >= 32 && b <= 126) ? String.fromCharCode(b) : '.');
                       } else {
                         hexBytes.add('  ');
                       }
                     }
                     return Padding(
                       padding: const EdgeInsets.symmetric(vertical: 4.0),
                       child: Row(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           SizedBox(width: 80, child: Text('0x${rowAddr.toRadixString(16).padLeft(4, '0')}:', style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 14))),
                           Expanded(child: Text(hexBytes.join('  '), style: const TextStyle(color: Colors.amber, fontFamily: 'monospace', fontSize: 14))),
                           SizedBox(width: 80, child: Text(asciiBytes.join(''), style: const TextStyle(color: Colors.lightGreenAccent, fontFamily: 'monospace', fontSize: 14))),
                         ],
                       ),
                     );
                  }
                )
            ),
          ],
        ),
      );
    }

    List<Widget> rows = [];
    int renderAddress = currentSubaddress;
    
    for (int i = 0; i < payloadBytes.length; i++) {
       int val = payloadBytes[i];
       var regDef = regfile.registers[renderAddress];
       
       String regName = regDef?.name ?? 'Unknown (0x${renderAddress.toRadixString(16).padLeft(2, '0')})';
       String regDesc = regDef?.description ?? '';
       String regAccess = regDef?.access ?? '';
       
       List<Widget> fieldWidgets = [];
       if (regDef != null) {
         for (var field in regDef.fields) {
           String res = field.decode(val);
           if (res.isNotEmpty) {
             String bitInfo = field.startBit == field.endBit 
                 ? 'Bit[${field.startBit}]' 
                 : 'Bit[${field.endBit}:${field.startBit}]';
                 
             int bitWidth = field.endBit - field.startBit + 1;
             int mask = (1 << bitWidth) - 1;
             int extracted = (val >> field.startBit) & mask;
             String binVal = "$bitWidth'b${extracted.toRadixString(2).padLeft(bitWidth, '0')}";

             fieldWidgets.add(Padding(
               padding: const EdgeInsets.only(bottom: 6.0),
               child: Text.rich(
                 TextSpan(
                   children: [
                     TextSpan(text: '$bitInfo ', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                     TextSpan(text: '$binVal ', style: const TextStyle(color: Colors.yellowAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                     TextSpan(text: res, style: const TextStyle(color: Colors.lightGreenAccent, fontWeight: FontWeight.bold)),
                     if (field.access != null && field.access!.isNotEmpty)
                       TextSpan(text: ' [${field.access}]', style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
                     if (field.description != null && field.description!.isNotEmpty)
                       TextSpan(text: '  ${field.description}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                   ],
                 ),
               ),
             ));
           }
         }
       }
       
       rows.add(Container(
         padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
         decoration: BoxDecoration(
           color: i % 2 == 0 ? Colors.transparent : Colors.white.withValues(alpha: 0.03),
           border: Border(bottom: BorderSide(color: Colors.grey.shade800))
         ),
         child: Row(
           crossAxisAlignment: CrossAxisAlignment.start,
           children: [
             SizedBox(
               width: 150,
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   Text('Reg 0x${renderAddress.toRadixString(16).padLeft(2, '0')}', 
                     style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                   if (regAccess.isNotEmpty)
                     Padding(
                       padding: const EdgeInsets.only(top: 4.0),
                       child: Text('Access: $regAccess', style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
                     ),
                 ],
               )
             ),
             Expanded(
               flex: 2,
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   Text(regName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                   if (regDesc.isNotEmpty)
                     Padding(
                       padding: const EdgeInsets.only(top: 4.0, right: 8.0),
                       child: Text(regDesc, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                     ),
                 ],
               )
             ),
             SizedBox(
               width: 80,
               child: Text('0x${val.toRadixString(16).padLeft(2, '0')}', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold))
             ),
             Expanded(
               flex: 3,
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: fieldWidgets.isNotEmpty 
                   ? fieldWidgets 
                   : [Text(regDef?.decodeFields(val).join(', ') ?? '', style: const TextStyle(color: Colors.lightGreenAccent))],
               )
             )
           ],
         ),
       ));
       renderAddress++;
    }
    
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF2A2A2A),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Builder(
                  builder: (context) {
                    String pinConfig = '';
                    if (regfile.addressMap != null && regfile.addressMap!.containsKey(targetAddress)) {
                      pinConfig = ' [Pin Config: ${regfile.addressMap![targetAddress]}]';
                    }
                    return Text('Device: ${regfile.name} (0x${targetAddress!.toRadixString(16).toUpperCase()})$pinConfig - ${isWrite ? 'Write' : 'Read'}', 
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold));
                  }
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    state.closeRegisterInfoPanel();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty 
              ? const Center(child: Text('No register data to display', style: TextStyle(color: Colors.grey)))
              : ListView(children: rows),
          ),
        ],
      ),
    );
"""
    
    # We replace from start_idx to end_idx
    lines = lines[:start_idx] + [new_code] + lines[end_idx:]
    with open(r'g:\DebugToolSet\lib\modules\oscilloscope\widgets\register_info_panel.dart', 'w', encoding='utf-8') as f:
        f.writelines(lines)
    print("Done")
else:
    print("Failed to find start or end index.")
