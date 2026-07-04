import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:file_selector/file_selector.dart';
import '../../../providers/oscilloscope_state.dart';
import '../models/protocol_decoder.dart';
import '../models/i2c_regfile.dart';
import '../models/uart_protocol_file.dart';

class RegisterInfoPanel extends StatelessWidget {
  const RegisterInfoPanel({super.key});

  void _showMountRegfileDialog(BuildContext context, OscilloscopeState state, String busName, int address) {
    String addrHex = '0x${address.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    I2cRegfile? currentMounted = state.mountedRegfiles[busName]?[address];
    
    List<I2cRegfile> matchingRegfiles = state.availableRegfiles.where((r) {
      if (r.addresses != null && r.addresses!.contains(address)) return true;
      if (r.addressMap != null && r.addressMap!.containsKey(address)) return true;
      return false;
    }).toList();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text('挂载 $addrHex 寄存器文件', style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: SizedBox(
            width: 350,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: matchingRegfiles.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    title: const Text('None (Unmount)', style: TextStyle(color: Colors.grey)),
                    leading: Icon(Icons.clear, color: currentMounted == null ? Colors.cyanAccent : Colors.grey),
                    onTap: () {
                      state.mountI2cDevice(busName, address, null);
                      Navigator.pop(context);
                    },
                  );
                }
                var regfile = matchingRegfiles[index - 1];
                bool isSelected = currentMounted == regfile;
                String pinConfig = '';
                if (regfile.addressMap != null && regfile.addressMap!.containsKey(address)) {
                  pinConfig = ' (${regfile.addressMap![address]})';
                }
                return ListTile(
                  title: Text('${regfile.name}$pinConfig', style: TextStyle(color: isSelected ? Colors.cyanAccent : Colors.white)),
                  leading: Icon(Icons.description, color: isSelected ? Colors.cyanAccent : Colors.grey),
                  onTap: () {
                    state.mountI2cDevice(busName, address, regfile);
                    Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.cyanAccent)),
            )
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();
    
    String? busName = state.highlightedBusName;
    int? highlightStart = state.highlightedStartIndex;
    
    if (busName == null || highlightStart == null) {
      return const Center(
        child: Text('Click a frame to view register info', style: TextStyle(color: Colors.grey)),
      );
    }
    
    var busIndex = state.digitalChannel.buses.indexWhere((b) => b.name == busName);
    if (busIndex < 0) return const SizedBox.shrink();
    var bus = state.digitalChannel.buses[busIndex];
    if (bus.decoder == null) return const SizedBox.shrink();

    // Find the highlighted frame
    ProtocolFrame? selectedFrame;
    for (var f in bus.decoder!.frames) {
      if (f.startIndex <= highlightStart && f.endIndex >= highlightStart) {
        selectedFrame = f;
        break;
      }
    }
    
    if (selectedFrame == null) {
      return const Center(child: Text('Frame not found', style: TextStyle(color: Colors.grey)));
    }

    if (bus.decoder is UartDecoder) {
      return _buildUartPanel(context, state, busName, selectedFrame, bus.decoder as UartDecoder);
    }
    
    if (bus.decoder is SpiDecoder) {
      return _buildSpiPanel(context, state, busName, selectedFrame, bus.decoder as SpiDecoder);
    }

    if (bus.decoder is! I2cDecoder) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))
        ),
        child: Stack(
          children: [
            const Center(child: Text('Unsupported bus type', style: TextStyle(color: Colors.grey))),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  state.closeRegisterInfoPanel();
                },
              ),
            ),
          ],
        ),
      );
    }
    
    // Extract target address first to get the regfile
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
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))
        ),
        child: Stack(
          children: [
            Center(
              child: InkWell(
                onTap: () => _showMountRegfileDialog(context, state, busName, targetAddress!),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text('No Regfile mounted for 0x${targetAddress.toRadixString(16).toUpperCase()} on $busName\n(Click to mount)', 
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.cyanAccent, decoration: TextDecoration.underline)),
                ),
              )
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  state.closeRegisterInfoPanel();
                },
              ),
            ),
          ],
        ),
      );
    }

    bool hasSubaddress = regfile.hasSubaddress ?? true;
    
    // Parse the frame accurately
    bool isWrite = false;
    int? currentSubaddress;
    List<int> payloadBytes = [];
    List<int> payloadStartIndices = [];
    
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
              payloadStartIndices.add(packet.startIndex);
            }
          } else {
            payloadBytes.add(packet.rawValue!);
            payloadStartIndices.add(packet.startIndex);
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
                  Row(
                    children: [
                      if (regfile.name.startsWith('AT24C'))
                        ElevatedButton.icon(
                          onPressed: () async {
                             const XTypeGroup binType = XTypeGroup(label: 'Binary File', extensions: ['bin']);
                             const XTypeGroup hexType = XTypeGroup(label: 'Intel Hex File', extensions: ['hex']);
                             
                             String dumpDir = p.join(Directory.current.path, 'Memorydump');
                             if (!Directory(dumpDir).existsSync()) {
                               Directory(dumpDir).createSync(recursive: true);
                             }

                             int pageOffset = 0;
                             if (regfile.name == 'AT24C04') {
                               pageOffset = (targetAddress! & 0x01) << 8;
                             } else if (regfile.name == 'AT24C08') {
                               pageOffset = (targetAddress! & 0x03) << 8;
                             } else if (regfile.name == 'AT24C16') {
                               pageOffset = (targetAddress! & 0x07) << 8;
                             }
                             int startAddr = (currentSubaddress ?? 0) + pageOffset;
                             int length = payloadBytes.length;
                             String sHex = startAddr.toRadixString(16).toUpperCase();
                             String lHex = length.toRadixString(16).toUpperCase();
                             String baseName = '${regfile.name.replaceAll('/', '_')}_S0x${sHex}_L0x$lHex';

                             final fileLocation = await getSaveLocation(
                               acceptedTypeGroups: [binType, hexType],
                               suggestedName: baseName,
                               initialDirectory: dumpDir,
                             );
                             
                             if (fileLocation != null) {
                               String path = fileLocation.path;
                               String format = 'bin';
                               if (path.toLowerCase().endsWith('.hex')) {
                                 format = 'hex';
                               } else if (!path.toLowerCase().endsWith('.bin')) {
                                 path += '.bin';
                               }
                               
                               try {
                                 if (format == 'hex') {
                                    int addr = startAddr;
                                    StringBuffer sb = StringBuffer();
                                    for (int i = 0; i < payloadBytes.length; i += 16) {
                                      int chunkLen = (payloadBytes.length - i) > 16 ? 16 : (payloadBytes.length - i);
                                      int sum = chunkLen + (addr >> 8) + (addr & 0xFF) + 0x00;
                                      String line = ':${chunkLen.toRadixString(16).padLeft(2, '0').toUpperCase()}';
                                      line += '${addr.toRadixString(16).padLeft(4, '0').toUpperCase()}00';
                                      for (int j = 0; j < chunkLen; j++) {
                                        int b = payloadBytes[i + j];
                                        line += b.toRadixString(16).padLeft(2, '0').toUpperCase();
                                        sum += b;
                                      }
                                      sum = (~sum + 1) & 0xFF;
                                      line += sum.toRadixString(16).padLeft(2, '0').toUpperCase();
                                      sb.writeln(line);
                                      addr += chunkLen;
                                    }
                                    sb.writeln(':00000001FF');
                                    File(path).writeAsStringSync(sb.toString());
                                 } else {
                                    File(path).writeAsBytesSync(payloadBytes);
                                 }
                                 if (context.mounted) {
                                   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $path')));
                                 }
                               } catch (e) {
                                 if (context.mounted) {
                                   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save file: $e')));
                                 }
                               }
                             }
                          },
                          icon: const Icon(Icons.download, size: 16, color: Colors.cyanAccent),
                          label: const Text('DUMP', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF333333),
                            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                            minimumSize: const Size(0, 24),
                          ),
                        ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () => _showMountRegfileDialog(context, state, busName, targetAddress!),
                        icon: const Icon(Icons.eject, size: 14, color: Colors.cyanAccent),
                        label: const Text('Change/Unmount', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF333333),
                          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0.0),
                          minimumSize: const Size(0, 24),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          state.closeRegisterInfoPanel();
                        },
                      ),
                    ]
                  ),
                ],
              ),
            ),
            Expanded(
              child: Builder(
                builder: (context) {
                  int padWidth = 4;
                  int pageOffset = 0;
                  if (regfile.name == 'AT24C01/02') {
                    padWidth = 2;
                  } else if (regfile.name == 'AT24C04') {
                    padWidth = 3;
                    pageOffset = (targetAddress! & 0x01) << 8;
                  } else if (regfile.name == 'AT24C08') {
                    padWidth = 3;
                    pageOffset = (targetAddress! & 0x03) << 8;
                  } else if (regfile.name == 'AT24C16') {
                    padWidth = 3;
                    pageOffset = (targetAddress! & 0x07) << 8;
                  }
                  int absStartAddr = currentSubaddress! + pageOffset;
                  int alignedStart = absStartAddr & ~0x0F;
                  int offsetInFirstRow = absStartAddr % 16;
                  int totalBytesToDisplay = payloadBytes.length + offsetInFirstRow;
                  int rowCount = (totalBytesToDisplay / 16).ceil();

                  String headerHexStr = '00 01 02 03 04 05 06 07   08 09 0A 0B 0C 0D 0E 0F';
                  String headerAsciiStr = '0123456789ABCDEF';

                  Widget header = Padding(
                    padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(width: 80, child: Text('Offset', style: TextStyle(color: Colors.grey, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14))),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: headerHexStr, style: const TextStyle(color: Colors.grey, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14)),
                                const TextSpan(text: '   ', style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14)),
                                TextSpan(text: headerAsciiStr, style: const TextStyle(color: Colors.grey, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14)),
                              ]
                            )
                          )
                        ),
                      ],
                    ),
                  );

                  return Column(
                    children: [
                      header,
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                          itemCount: rowCount,
                          itemBuilder: (context, index) {
                             int rowAddr = alignedStart + index * 16;
                             List<InlineSpan> hexSpans1 = [];
                             List<InlineSpan> hexSpans2 = [];
                             List<InlineSpan> asciiSpans = [];
                             
                             for (int i = 0; i < 16; i++) {
                               int dataIndex = index * 16 + i - offsetInFirstRow;
                               if (dataIndex >= 0 && dataIndex < payloadBytes.length) {
                                 int b = payloadBytes[dataIndex];
                                 int pStart = payloadStartIndices[dataIndex];
                                 bool isHighlighted = false;
                                 if (state.highlightedStartIndex != null && state.highlightedEndIndex != null) {
                                   isHighlighted = pStart >= state.highlightedStartIndex! && pStart < state.highlightedEndIndex!;
                                 }
                                 
                                 String hex = b.toRadixString(16).padLeft(2, '0').toUpperCase();
                                 String ascii = (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.';
                                 
                                 TextStyle hexStyle = isHighlighted 
                                     ? const TextStyle(color: Colors.black, backgroundColor: Colors.amberAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14) 
                                     : const TextStyle(color: Colors.amber, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14);
                                     
                                 TextStyle asciiStyle = isHighlighted 
                                     ? const TextStyle(color: Colors.black, backgroundColor: Colors.amberAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14) 
                                     : const TextStyle(color: Colors.lightGreenAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14);

                                 if (i < 8) {
                                   if (hexSpans1.isNotEmpty) hexSpans1.add(const TextSpan(text: ' '));
                                   hexSpans1.add(TextSpan(text: hex, style: hexStyle));
                                 } else {
                                   if (hexSpans2.isNotEmpty) hexSpans2.add(const TextSpan(text: ' '));
                                   hexSpans2.add(TextSpan(text: hex, style: hexStyle));
                                 }
                                 asciiSpans.add(TextSpan(text: ascii, style: asciiStyle));
                               } else {
                                 TextStyle blankStyle = const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14);
                                 if (i < 8) {
                                   if (hexSpans1.isNotEmpty) hexSpans1.add(TextSpan(text: ' ', style: blankStyle));
                                   hexSpans1.add(TextSpan(text: '  ', style: blankStyle));
                                 } else {
                                   if (hexSpans2.isNotEmpty) hexSpans2.add(TextSpan(text: ' ', style: blankStyle));
                                   hexSpans2.add(TextSpan(text: '  ', style: blankStyle));
                                 }
                                 asciiSpans.add(TextSpan(text: ' ', style: blankStyle));
                               }
                             }
                             
                             return Padding(
                               padding: const EdgeInsets.symmetric(vertical: 4.0),
                               child: Row(
                                 crossAxisAlignment: CrossAxisAlignment.start,
                                 children: [
                                   SizedBox(width: 80, child: Text('0x${rowAddr.toRadixString(16).toUpperCase().padLeft(padWidth, '0')}', style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14))),
                                   Expanded(
                                     child: Text.rich(
                                       TextSpan(
                                         style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14),
                                         children: [
                                           ...hexSpans1,
                                           const TextSpan(text: '   '),
                                           ...hexSpans2,
                                           const TextSpan(text: '   '),
                                           ...asciiSpans,
                                         ]
                                       )
                                     )
                                   ),
                                 ],
                               ),
                             );
                          }
                        )
                      )
                    ]
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
       
       String regName = regDef?.name ?? 'Unknown (0x${renderAddress.toRadixString(16).toUpperCase().padLeft(2, '0')})';
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
                   Text('Reg 0x${renderAddress.toRadixString(16).toUpperCase().padLeft(2, '0')}', 
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
               child: Text('0x${val.toRadixString(16).toUpperCase().padLeft(2, '0')}', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold))
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _showMountRegfileDialog(context, state, busName, targetAddress!),
                      icon: const Icon(Icons.eject, size: 14, color: Colors.cyanAccent),
                      label: const Text('Change/Unmount', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF333333),
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0.0),
                        minimumSize: const Size(0, 24),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 8),
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
  }

  void _selectUartProtocolFile(BuildContext context, OscilloscopeState state, UartDecoder decoder) async {
    final Directory dir = Directory('DeviceProtocol/Uart');
    List<FileSystemEntity> files = [];
    if (await dir.exists()) {
      files = await dir.list().where((e) => e.path.endsWith('.UartProtocol')).toList();
    }
    
    if (!context.mounted) return;
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('Select UART Protocol', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            height: 300,
            child: ListView.builder(
              itemCount: files.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    title: const Text('None (Unmount)', style: TextStyle(color: Colors.grey)),
                    leading: Icon(Icons.clear, color: decoder.protocolFile == null ? Colors.cyanAccent : Colors.grey),
                    onTap: () {
                       decoder.protocolFile = null;
                       state.forceUpdate();
                       Navigator.pop(context);
                    }
                  );
                }
                String filename = p.basename(files[index - 1].path);
                bool isSelected = decoder.protocolFile == filename;
                return ListTile(
                  title: Text(filename, style: TextStyle(color: isSelected ? Colors.cyanAccent : Colors.white)),
                  leading: Icon(Icons.description, color: isSelected ? Colors.cyanAccent : Colors.grey),
                  onTap: () {
                     decoder.protocolFile = filename;
                     state.forceUpdate();
                     Navigator.pop(context);
                  }
                );
              }
            )
          )
        );
      }
    );
  }

  void _selectSpiProtocolFile(BuildContext context, OscilloscopeState state, SpiDecoder decoder) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('Select SPI Protocol', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            height: 300,
            child: ListView.builder(
              itemCount: state.availableSpiRegfiles.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    title: const Text('None (Unmount)', style: TextStyle(color: Colors.grey)),
                    leading: Icon(Icons.clear, color: decoder.protocolFile == null ? Colors.cyanAccent : Colors.grey),
                    onTap: () {
                       decoder.protocolFile = null;
                       state.forceUpdate();
                       Navigator.pop(context);
                    }
                  );
                }
                var regfile = state.availableSpiRegfiles[index - 1];
                bool isSelected = decoder.protocolFile == regfile.name;
                return ListTile(
                  title: Text(regfile.name, style: TextStyle(color: isSelected ? Colors.cyanAccent : Colors.white)),
                  leading: Icon(Icons.description, color: isSelected ? Colors.cyanAccent : Colors.grey),
                  onTap: () {
                     decoder.protocolFile = regfile.name;
                     state.forceUpdate();
                     Navigator.pop(context);
                  }
                );
              }
            )
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.cyanAccent)),
            )
          ],
        );
      },
    );
  }

  Widget _buildUartPanel(BuildContext context, OscilloscopeState state, String busName, ProtocolFrame frame, UartDecoder decoder) {
    List<int> payloadBytes = [];
    List<int> payloadStartIndices = [];
    for (var packet in frame.packets) {
      if (packet.type == PacketType.data && packet.rawValue != null) {
        payloadBytes.add(packet.rawValue!);
        payloadStartIndices.add(packet.startIndex);
      }
    }

    String title = 'Txd/Rxd';
    if (frame.summary.startsWith('Tx')) {
      title = 'Txd';
    } else if (frame.summary.startsWith('Rx')) {
      title = 'Rxd';
    }
    
    int rate = decoder.detectedBaudRate > 0 ? decoder.detectedBaudRate : decoder.baudRate;
    String parityStr = decoder.parity.isNotEmpty ? decoder.parity.substring(0, 1).toUpperCase() : 'N';
    String formatInfo = '${rate}bps, ${decoder.dataBits}$parityStr${decoder.stopBits}';
    title = '$title - $formatInfo';
    String? cmdName;

    List<InlineSpan> hexSpans = [];
    List<InlineSpan> asciiSpans = [];
    
    TextStyle baseMonospace = const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14);
    
    for (int i = 0; i < payloadBytes.length; i++) {
      int b = payloadBytes[i];
      int pStart = payloadStartIndices[i];
      bool isHighlighted = false;
      if (state.highlightedStartIndex != null && state.highlightedEndIndex != null) {
        isHighlighted = pStart >= state.highlightedStartIndex! && pStart < state.highlightedEndIndex!;
      }
      
      String hex = b.toRadixString(16).padLeft(2, '0').toUpperCase();
      String ascii = (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.';
      
      TextStyle hexStyle = isHighlighted 
          ? baseMonospace.copyWith(color: Colors.black, backgroundColor: Colors.amberAccent) 
          : baseMonospace.copyWith(color: Colors.amber);
          
      TextStyle asciiStyle = isHighlighted 
          ? baseMonospace.copyWith(color: Colors.black, backgroundColor: Colors.amberAccent) 
          : baseMonospace.copyWith(color: Colors.lightGreenAccent);

      if (i > 0) {
        hexSpans.add(TextSpan(text: ' ', style: baseMonospace));
        asciiSpans.add(TextSpan(text: '  ', style: baseMonospace));
      }
      hexSpans.add(TextSpan(text: hex, style: hexStyle));
      asciiSpans.add(TextSpan(text: ascii, style: asciiStyle));
    }

    Widget? parsedContent;
    UartProtocolFile? protocol;
    if (decoder.protocolFile != null) {
      protocol = state.availableUartProtocols[decoder.protocolFile!];
    }
    
    if (protocol != null && payloadBytes.isNotEmpty) {
      bool isTx = frame.summary.startsWith('Tx');
      
      bool headerMatch = true;
      for (int i = 0; i < protocol.header.length; i++) {
        if (i >= payloadBytes.length || payloadBytes[i] != protocol.header[i]) {
          headerMatch = false;
          break;
        }
      }
      
      if (headerMatch && payloadBytes.length > protocol.header.length) {
        int cmdIndex = protocol.header.length;
        int cmdId = payloadBytes[cmdIndex];
        
        UartCommandDef? cmd = protocol.commands[cmdId];
        if (cmd != null) {
          cmdName = cmd.name;
          UartPacketDef? packetDef = isTx ? cmd.tx : cmd.rx;
          if (packetDef != null) {
             List<Widget> fieldWidgets = [];
             
             if (protocol.header.isNotEmpty) {
               List<String> hexVals = [];
               for (int i = 0; i < protocol.header.length; i++) {
                 int val = payloadBytes[i];
                 hexVals.add('0x${val.toRadixString(16).padLeft(2, '0').toUpperCase()}');
               }
               String combinedHex = hexVals.join(' ');
               
               double boxWidth = 70.0 + (protocol.header.length - 1) * 35.0;
               
               fieldWidgets.add(
                 Container(
                   constraints: BoxConstraints(minWidth: boxWidth),
                   margin: const EdgeInsets.only(right: 8),
                   padding: const EdgeInsets.all(8),
                   decoration: BoxDecoration(
                     color: const Color(0xFF333333),
                     border: Border.all(color: Colors.grey.shade700),
                     borderRadius: BorderRadius.circular(4)
                   ),
                   child: Column(
                     mainAxisSize: MainAxisSize.min,
                     crossAxisAlignment: CrossAxisAlignment.center,
                     children: [
                       const Text('Header', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13), textAlign: TextAlign.center),
                       const SizedBox(height: 4),
                       Text(combinedHex, style: const TextStyle(color: Colors.yellowAccent, fontSize: 14)),
                       const SizedBox(height: 8),
                       const Text('Frame Header', style: TextStyle(color: Colors.lightGreenAccent, fontSize: 12), textAlign: TextAlign.center)
                     ]
                   )
                 )
               );
             }
             
             for (int i = 0; i < packetDef.payload.length; i++) {
               var field = packetDef.payload[i];
               if (field.byteOffset < payloadBytes.length) {
                 int val = payloadBytes[field.byteOffset];
                 String decoded = field.decode(val);
                 String hexVal = '0x${val.toRadixString(16).padLeft(2, '0').toUpperCase()}';
                 String displayDesc = decoded.isNotEmpty ? decoded : (field.description ?? '');
                 
                 fieldWidgets.add(
                   Container(
                     constraints: const BoxConstraints(minWidth: 70),
                     margin: const EdgeInsets.only(right: 8),
                     padding: const EdgeInsets.all(8),
                     decoration: BoxDecoration(
                       color: const Color(0xFF333333),
                       border: Border.all(color: Colors.grey.shade700),
                       borderRadius: BorderRadius.circular(4)
                     ),
                     child: Column(
                       mainAxisSize: MainAxisSize.min,
                       crossAxisAlignment: CrossAxisAlignment.center,
                       children: [
                         Text(field.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13), textAlign: TextAlign.center),
                         const SizedBox(height: 4),
                         Text(hexVal, style: const TextStyle(color: Colors.yellowAccent, fontSize: 14)),
                         const SizedBox(height: 8),
                         Text(displayDesc, style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 12), textAlign: TextAlign.center)
                       ]
                     )
                   )
                 );
               }
             }
             
             parsedContent = _HorizontalScrollableContent(
               child: IntrinsicHeight(
                 child: Row(
                   crossAxisAlignment: CrossAxisAlignment.stretch,
                   children: fieldWidgets
                 )
               )
             );
          }
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8, right: 40),
                color: const Color(0xFF2A2A2A),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            if (cmdName != null)
                              TextSpan(text: '   CMD:  $cmdName', style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                          ]
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _selectUartProtocolFile(context, state, decoder),
                      icon: Icon(decoder.protocolFile == null ? Icons.upload_file : Icons.eject, size: 14, color: Colors.cyanAccent),
                      label: Text(
                        decoder.protocolFile == null ? 'Mount' : 'Change/Unmount',
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF333333),
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0.0),
                        minimumSize: const Size(0, 24),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (parsedContent == null)
                        Expanded(
                          flex: 2,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text.rich(TextSpan(children: hexSpans)),
                                const SizedBox(height: 8),
                                Text.rich(TextSpan(children: asciiSpans)),
                              ],
                            ),
                          ),
                        ),
                      if (parsedContent != null)
                        Expanded(
                          flex: 2,
                          child: Container(
                            margin: const EdgeInsets.only(top: 8),
                            alignment: Alignment.topLeft,
                            child: parsedContent
                          )
                        ),

                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.grey, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () {
                state.closeRegisterInfoPanel();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpiPanel(BuildContext context, OscilloscopeState state, String busName, ProtocolFrame frame, SpiDecoder decoder) {
    if (decoder.protocolFile == null) {
      return Container(
        decoration: BoxDecoration(color: const Color(0xFF1E1E1E), border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))),
        child: Stack(
          children: [
            Center(
              child: InkWell(
                onTap: () => _selectSpiProtocolFile(context, state, decoder),
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text('No SPI Protocol file mounted\n(Click to mount)', textAlign: TextAlign.center, style: TextStyle(color: Colors.cyanAccent, decoration: TextDecoration.underline)),
                ),
              ),
            ),
            Positioned(top: 8, right: 8, child: IconButton(icon: const Icon(Icons.close, color: Colors.grey, size: 20), onPressed: () => state.closeRegisterInfoPanel())),
          ],
        ),
      );
    }
    
    I2cRegfile? regfile;
    try {
      regfile = state.availableSpiRegfiles.firstWhere((r) => r.name == decoder.protocolFile);
    } catch (_) {}
    
    if (regfile == null) {
      return Container(
        decoration: BoxDecoration(color: const Color(0xFF1E1E1E), border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))),
        child: Stack(
          children: [
            Center(child: Text('SPI Protocol file not found: ${decoder.protocolFile}', style: const TextStyle(color: Colors.grey))),
            Positioned(top: 8, right: 8, child: IconButton(icon: const Icon(Icons.close, color: Colors.grey, size: 20), onPressed: () => state.closeRegisterInfoPanel())),
          ],
        ),
      );
    }

    ProtocolPacket? cmdPacket;
    ProtocolPacket? addrPacket;
    List<ProtocolPacket> dataPackets = [];
    for (var p in frame.packets) {
      if (p.data.startsWith('CMD')) {
        cmdPacket = p;
      } else if (p.data.startsWith('ADDR')) {
        addrPacket = p;
      } else if (p.data.startsWith('DATA')) {
        dataPackets.add(p);
      }
    }
    
    if (cmdPacket == null || cmdPacket.rawValue == null) {
      return Container(
        decoration: BoxDecoration(color: const Color(0xFF1E1E1E), border: Border(top: BorderSide(color: Colors.grey.shade800, width: 2))),
        child: Stack(
          children: [
            const Center(child: Text('No Command (CMD) found in frame', style: TextStyle(color: Colors.grey))),
            Positioned(top: 8, right: 8, child: IconButton(icon: const Icon(Icons.close, color: Colors.grey, size: 20), onPressed: () => state.closeRegisterInfoPanel())),
          ],
        ),
      );
    }
    
    int cmdValue = cmdPacket.rawValue!;
    var regDef = regfile.registers[cmdValue];
    
    String cmdName = regDef?.name ?? 'Unknown Command (0x${cmdValue.toRadixString(16).toUpperCase().padLeft(2, '0')})';
    String cmdDesc = regDef?.description ?? '';
    
    bool isMemoryCommand = const [0x02, 0x03, 0x0B, 0x3B, 0x6B, 0xBB, 0xEB, 0x32].contains(cmdValue);
    
    Widget contentWidget;
    
    if (isMemoryCommand && dataPackets.isNotEmpty) {
      int startingAddress = 0;
      if (addrPacket != null && addrPacket.rawValue != null) {
        startingAddress = addrPacket.rawValue!;
      }
      
      List<int> payloadBytes = dataPackets.map((p) => p.rawValue ?? 0).toList();
      List<int> payloadStartIndices = dataPackets.map((p) => p.startIndex).toList();
      
      int padWidth = 6; 
      int absStartAddr = startingAddress;
      int alignedStart = absStartAddr & ~0x0F;
      int offsetInFirstRow = absStartAddr % 16;
      int totalBytesToDisplay = payloadBytes.length + offsetInFirstRow;
      int rowCount = (totalBytesToDisplay / 16).ceil();

      String headerHexStr = '00 01 02 03 04 05 06 07   08 09 0A 0B 0C 0D 0E 0F';
      String headerAsciiStr = '0123456789ABCDEF';

      Widget header = Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 80, child: Text('Offset', style: TextStyle(color: Colors.grey, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14))),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: headerHexStr, style: const TextStyle(color: Colors.grey, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14)),
                    const TextSpan(text: '   ', style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14)),
                    TextSpan(text: headerAsciiStr, style: const TextStyle(color: Colors.grey, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14)),
                  ]
                )
              )
            ),
          ],
        ),
      );
      
      contentWidget = Column(
        children: [
          header,
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
              itemCount: rowCount,
              itemBuilder: (context, index) {
                 int rowAddr = alignedStart + index * 16;
                 List<InlineSpan> hexSpans1 = [];
                 List<InlineSpan> hexSpans2 = [];
                 List<InlineSpan> asciiSpans = [];
                 
                 for (int i = 0; i < 16; i++) {
                   int dataIndex = index * 16 + i - offsetInFirstRow;
                   if (dataIndex >= 0 && dataIndex < payloadBytes.length) {
                     int b = payloadBytes[dataIndex];
                     int pStart = payloadStartIndices[dataIndex];
                     bool isHighlighted = false;
                     if (state.highlightedStartIndex != null && state.highlightedEndIndex != null) {
                       isHighlighted = pStart >= state.highlightedStartIndex! && pStart < state.highlightedEndIndex!;
                     }
                     
                     String hex = b.toRadixString(16).padLeft(2, '0').toUpperCase();
                     String ascii = (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.';
                     
                     TextStyle hexStyle = isHighlighted 
                         ? const TextStyle(color: Colors.black, backgroundColor: Colors.amberAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14) 
                         : const TextStyle(color: Colors.amber, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14);
                         
                     TextStyle asciiStyle = isHighlighted 
                         ? const TextStyle(color: Colors.black, backgroundColor: Colors.amberAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14) 
                         : const TextStyle(color: Colors.lightGreenAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14);

                     if (i < 8) {
                       if (hexSpans1.isNotEmpty) hexSpans1.add(const TextSpan(text: ' '));
                       hexSpans1.add(TextSpan(text: hex, style: hexStyle));
                     } else {
                       if (hexSpans2.isNotEmpty) hexSpans2.add(const TextSpan(text: ' '));
                       hexSpans2.add(TextSpan(text: hex, style: hexStyle));
                     }
                     asciiSpans.add(TextSpan(text: ascii, style: asciiStyle));
                   } else {
                     TextStyle blankStyle = const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14);
                     if (i < 8) {
                       if (hexSpans1.isNotEmpty) hexSpans1.add(TextSpan(text: ' ', style: blankStyle));
                       hexSpans1.add(TextSpan(text: '  ', style: blankStyle));
                     } else {
                       if (hexSpans2.isNotEmpty) hexSpans2.add(TextSpan(text: ' ', style: blankStyle));
                       hexSpans2.add(TextSpan(text: '  ', style: blankStyle));
                     }
                     asciiSpans.add(TextSpan(text: ' ', style: blankStyle));
                   }
                 }
                 
                 return Padding(
                   padding: const EdgeInsets.symmetric(vertical: 4.0),
                   child: Row(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       SizedBox(width: 80, child: Text('0x${rowAddr.toRadixString(16).toUpperCase().padLeft(padWidth, '0')}', style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14))),
                       Expanded(
                         child: Text.rich(
                           TextSpan(
                             style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Courier New', 'monospace'], fontSize: 14),
                             children: [
                               ...hexSpans1,
                               const TextSpan(text: '   '),
                               ...hexSpans2,
                               const TextSpan(text: '   '),
                               ...asciiSpans,
                             ]
                           )
                         )
                       ),
                     ],
                   ),
                 );
              }
            )
          )
        ]
      );
    } else {
      List<Widget> fieldWidgets = [];
      if (dataPackets.isNotEmpty) {
        for (int i = 0; i < dataPackets.length; i++) {
          int val = dataPackets[i].rawValue ?? 0;
          
          List<Widget> innerFieldWidgets = [];

          if (regDef != null) {
            var sortedFields = List.of(regDef.fields);
            sortedFields.sort((a, b) => b.startBit.compareTo(a.startBit));

            for (var field in sortedFields) {
              String res = field.decode(val);
              if (res.isNotEmpty) {
                int bitWidth = field.endBit - field.startBit + 1;
                int mask = (1 << bitWidth) - 1;
                int extracted = (val >> field.startBit) & mask;
                String binVal = "$bitWidth'b${extracted.toRadixString(2).padLeft(bitWidth, '0')}";
                String displayDesc = res.isNotEmpty ? res : (field.description ?? '');
                String bitInfo = field.startBit == field.endBit ? 'Bit[${field.startBit}]' : 'Bit[${field.endBit}:${field.startBit}]';

                innerFieldWidgets.add(
                  Container(
                    constraints: const BoxConstraints(minWidth: 65),
                    margin: EdgeInsets.only(right: field == sortedFields.last ? 0 : 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF333333),
                      border: Border.all(color: Colors.grey.shade700),
                      borderRadius: BorderRadius.circular(4)
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(field.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13), textAlign: TextAlign.center),
                        Text(bitInfo, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                        const SizedBox(height: 4),
                        Text(binVal, style: const TextStyle(color: Colors.yellowAccent, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text(displayDesc, style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 12), textAlign: TextAlign.center)
                      ]
                    )
                  )
                );
              }
            }
          }

          if (innerFieldWidgets.isNotEmpty) {
            fieldWidgets.add(
              Container(
                margin: EdgeInsets.only(right: i == dataPackets.length - 1 ? 0 : 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  border: Border.all(color: Colors.grey.shade600),
                  borderRadius: BorderRadius.circular(8)
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('DATA[$i] : 0x${val.toRadixString(16).padLeft(2, '0').toUpperCase()}  (${regDef?.name ?? ''})', style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 12),
                    IntrinsicHeight(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: innerFieldWidgets
                      )
                    )
                  ]
                )
              )
            );
          } else {
            fieldWidgets.add(
              Container(
                constraints: const BoxConstraints(minWidth: 65),
                margin: EdgeInsets.only(right: i == dataPackets.length - 1 ? 0 : 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  border: Border.all(color: Colors.grey.shade600),
                  borderRadius: BorderRadius.circular(4)
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('DATA[$i]', style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 13), textAlign: TextAlign.center),
                    const SizedBox(height: 4),
                    Text('0x${val.toRadixString(16).padLeft(2, '0').toUpperCase()}', style: const TextStyle(color: Colors.amber, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(regDef?.decodeFields(val).join(', ') ?? 'Raw Byte', style: const TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center)
                  ]
                )
              )
            );
          }
        }
      }
      
      contentWidget = fieldWidgets.isEmpty 
        ? const Center(child: Text('No DATA bytes in frame', style: TextStyle(color: Colors.grey)))
        : Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _HorizontalScrollableContent(
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: fieldWidgets
                  )
                )
              )
            )
          );
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
                Text('SPI Command: 0x${cmdValue.toRadixString(16).toUpperCase().padLeft(2, '0')} - $cmdName', 
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                if (cmdDesc.isNotEmpty)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(cmdDesc, style: const TextStyle(color: Colors.white70, fontSize: 12), overflow: TextOverflow.ellipsis),
                    ),
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isMemoryCommand && dataPackets.isNotEmpty)
                      ElevatedButton.icon(
                        onPressed: () async {
                           const XTypeGroup binType = XTypeGroup(label: 'Binary File', extensions: ['bin']);
                           const XTypeGroup hexType = XTypeGroup(label: 'Intel Hex File', extensions: ['hex']);
                           
                           String dumpDir = p.join(Directory.current.path, 'Memorydump');
                           if (!Directory(dumpDir).existsSync()) {
                             Directory(dumpDir).createSync(recursive: true);
                           }

                           int startAddr = 0;
                           if (addrPacket != null && addrPacket.rawValue != null) {
                             startAddr = addrPacket.rawValue!;
                           }
                           
                           List<int> payloadBytes = dataPackets.map((pa) => pa.rawValue ?? 0).toList();
                           int length = payloadBytes.length;
                           String sHex = startAddr.toRadixString(16).toUpperCase();
                           String lHex = length.toRadixString(16).toUpperCase();
                           String baseName = '${regfile?.name.replaceAll('/', '_') ?? 'SPI'}_S0x${sHex}_L0x$lHex';

                           final fileLocation = await getSaveLocation(
                             acceptedTypeGroups: [binType, hexType],
                             suggestedName: baseName,
                             initialDirectory: dumpDir,
                           );
                           
                           if (fileLocation != null) {
                             String path = fileLocation.path;
                             String format = 'bin';
                             if (path.toLowerCase().endsWith('.hex')) {
                               format = 'hex';
                             } else if (!path.toLowerCase().endsWith('.bin')) {
                               path += '.bin';
                             }
                             
                             try {
                               if (format == 'hex') {
                                  int addr = startAddr;
                                  StringBuffer sb = StringBuffer();
                                  int currentHighAddr = -1;
                                  for (int i = 0; i < payloadBytes.length; i += 16) {
                                    int highAddr = (addr >> 16) & 0xFFFF;
                                    if (highAddr != currentHighAddr) {
                                      currentHighAddr = highAddr;
                                      int sum = 0x02 + 0x00 + 0x00 + 0x04 + (highAddr >> 8) + (highAddr & 0xFF);
                                      sum = (~sum + 1) & 0xFF;
                                      sb.writeln(':02000004${highAddr.toRadixString(16).padLeft(4, '0').toUpperCase()}${sum.toRadixString(16).padLeft(2, '0').toUpperCase()}');
                                    }
                                    
                                    int chunkLen = (payloadBytes.length - i) > 16 ? 16 : (payloadBytes.length - i);
                                    int lowerAddr = addr & 0xFFFF;
                                    int sum = chunkLen + (lowerAddr >> 8) + (lowerAddr & 0xFF) + 0x00;
                                    String line = ':${chunkLen.toRadixString(16).padLeft(2, '0').toUpperCase()}';
                                    line += '${lowerAddr.toRadixString(16).padLeft(4, '0').toUpperCase()}00';
                                    for (int j = 0; j < chunkLen; j++) {
                                      int b = payloadBytes[i + j];
                                      line += b.toRadixString(16).padLeft(2, '0').toUpperCase();
                                      sum += b;
                                    }
                                    sum = (~sum + 1) & 0xFF;
                                    line += sum.toRadixString(16).padLeft(2, '0').toUpperCase();
                                    sb.writeln(line);
                                    addr += chunkLen;
                                  }
                                  sb.writeln(':00000001FF');
                                  File(path).writeAsStringSync(sb.toString());
                               } else {
                                  File(path).writeAsBytesSync(payloadBytes);
                               }
                               if (context.mounted) {
                                 ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $path')));
                               }
                             } catch (e) {
                               if (context.mounted) {
                                 ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save file: $e')));
                               }
                             }
                           }
                        },
                        icon: const Icon(Icons.download, size: 16, color: Colors.cyanAccent),
                        label: const Text('DUMP', style: TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF333333),
                          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                          minimumSize: const Size(0, 24),
                        ),
                      ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _selectSpiProtocolFile(context, state, decoder),
                      icon: Icon(decoder.protocolFile == null ? Icons.upload_file : Icons.eject, size: 14, color: Colors.cyanAccent),
                      label: Text(
                        decoder.protocolFile == null ? 'Mount' : 'Change/Unmount',
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF333333),
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0.0),
                        minimumSize: const Size(0, 24),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => state.closeRegisterInfoPanel(),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(child: contentWidget),
        ],
      ),
    );
  }
}

class _HorizontalScrollableContent extends StatefulWidget {
  final Widget child;
  const _HorizontalScrollableContent({required this.child});

  @override
  State<_HorizontalScrollableContent> createState() => _HorizontalScrollableContentState();
}

class _HorizontalScrollableContentState extends State<_HorizontalScrollableContent> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      thickness: 8.0,
      radius: const Radius.circular(4),
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12.0), // give space for scrollbar
          child: widget.child,
        ),
      ),
    );
  }
}
