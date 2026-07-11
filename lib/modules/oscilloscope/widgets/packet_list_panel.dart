import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';
import '../models/protocol_decoder.dart';
import '../models/i2c_regfile.dart';

class PacketListPanel extends StatefulWidget {
  final String busName;

  const PacketListPanel({super.key, required this.busName});

  @override
  State<PacketListPanel> createState() => _PacketListPanelState();
}

class _PacketListPanelState extends State<PacketListPanel> {
  Set<PacketType>? _hiddenTypes; 
  final TextEditingController _searchController = TextEditingController();

  final ScrollController _scrollController = ScrollController();
    int? _lastProcessedHighlightSequence;
  final Set<int> _expandedFrames = {};
  bool _preventNextAutoExpand = false;
  DateTime? _lastTapTime;
  int? _lastTapFrameIndex;

  // Debounced search logic
  Timer? _debounce;
  String _activeSearchQuery = '';
  List<Map<String, dynamic>>? _filteredData;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String val, OscilloscopeState state) {
    String q = val.trim().toLowerCase();
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _activeSearchQuery != q) {
        _activeSearchQuery = q;
        _runFilter(state);
      }
    });
  }

  void _runFilter(OscilloscopeState state) {
    if (_activeSearchQuery.isEmpty) {
      setState(() {
        _filteredData = null;
      });
      return;
    }

    var busIndex = state.digitalChannel.buses.indexWhere((b) => b.name == widget.busName);
    if (busIndex < 0) return;
    var bus = state.digitalChannel.buses[busIndex];
    if (bus.decoder == null) return;

    var frames = bus.decoder!.frames;
    List<Map<String, dynamic>> visibleFramesData = [];

    for (int fIdx = 0; fIdx < frames.length; fIdx++) {
      var frame = frames[fIdx];
      bool frameSummaryMatches = frame.summary.toLowerCase().contains(_activeSearchQuery);
      
      bool hasMatchedPacket = false;
      for (var packet in frame.packets) {
        bool packetMatchesSearch = packet.data.toLowerCase().contains(_activeSearchQuery) || 
            (packet.rawValue?.toString().contains(_activeSearchQuery) ?? false);
            
        if (packetMatchesSearch) {
          hasMatchedPacket = true;
          break;
        }
      }
      
      if (frameSummaryMatches || hasMatchedPacket) {
         visibleFramesData.add({
           'frameIndex': fIdx,
         });
      }
    }

    setState(() {
      _filteredData = visibleFramesData;
    });
  }

  void _showMountRegfileDialog(BuildContext context, OscilloscopeState state, String busName, int address, I2cDecoder decoder) {
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
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      }
    );
  }

  int _getGlobalPacketIndex(List<ProtocolPacket> allPackets, ProtocolPacket target) {
    int low = 0;
    int high = allPackets.length - 1;
    while (low <= high) {
      int mid = low + (high - low) ~/ 2;
      if (allPackets[mid] == target) return mid;
      if (allPackets[mid].startIndex < target.startIndex) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    var state = context.watch<OscilloscopeState>();
    var busIndex = state.digitalChannel.buses.indexWhere((b) => b.name == widget.busName);
    if (busIndex < 0) return const SizedBox.shrink();
    var decoder = state.digitalChannel.buses[busIndex].decoder;
    if (decoder == null) return const SizedBox.shrink();

    _hiddenTypes ??= Set.from(decoder.defaultHiddenPacketTypes);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: Colors.grey.shade800, width: 2.0),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            color: const Color(0xFF2A2A2A),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('事件列表 - ${widget.busName}', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    context.read<OscilloscopeState>().toggleEventList(null);
                  },
                ),
              ],
            ),
          ),
          
          // Toolbar (Search & Filter)
          Container(
            padding: const EdgeInsets.all(8.0),
            color: const Color(0xFF1A1A1A),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search (e.g. 0x3C)...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                      filled: true,
                      fillColor: const Color(0xFF2A2A2A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.grey, size: 16),
                              onPressed: () {
                                _searchController.clear();
                                _onSearchChanged('', context.read<OscilloscopeState>());
                              },
                            )
                          : null,
                    ),
                    onChanged: (val) {
                      _onSearchChanged(val, context.read<OscilloscopeState>());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<void>(
                  icon: const Icon(Icons.visibility, color: Colors.cyanAccent, size: 20),
                  tooltip: 'Show/Hide Event Types',
                  color: const Color(0xFF2A2A2A),
                  itemBuilder: (context) {
                    return [
                      PopupMenuItem<void>(
                        enabled: false,
                        padding: EdgeInsets.zero,
                        child: StatefulBuilder(
                          builder: (context, setPopupState) {
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: decoder.supportedPacketTypes.map((type) {
                                bool isHidden = _hiddenTypes!.contains(type);
                                return InkWell(
                                  onTap: () {
                                    setState(() {
                                      if (_hiddenTypes!.contains(type)) {
                                        _hiddenTypes!.remove(type);
                                      } else {
                                        _hiddenTypes!.add(type);
                                      }
                                    });
                                    setPopupState(() {});
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isHidden ? Icons.check_box_outline_blank : Icons.check_box,
                                          color: isHidden ? Colors.grey : Colors.cyanAccent,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 12),
                                        Text(decoder.getPacketTypeName(type), style: const TextStyle(color: Colors.white, fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ),
                    ];
                  },
                ),
              ],
            ),
          ),
          
          // List
          Expanded(
            child: Selector<OscilloscopeState, String>(
              selector: (context, state) {
                var busIndex = state.digitalChannel.buses.indexWhere((b) => b.name == widget.busName);
                if (busIndex < 0) return '';
                var bus = state.digitalChannel.buses[busIndex];
                if (bus.decoder == null) return '';
                // Include _activeSearchQuery in selector so if data changes while searching, it doesn't freeze but we still know length changed.
                // Note: updating _filteredData should ideally be triggered if packet length changes. 
                // For simplicity, we just return the packet length.
                return '${bus.decoder!.packets.length}|${state.highlightedStartIndex}|${state.highlightedBusName}|${state.highlightTriggerSequence}';
              },
              builder: (context, _, child) {
                final state = context.read<OscilloscopeState>();
                var busIndex = state.digitalChannel.buses.indexWhere((b) => b.name == widget.busName);
                if (busIndex < 0) return const Center(child: Text('Bus not found', style: TextStyle(color: Colors.red)));
                var bus = state.digitalChannel.buses[busIndex];
                if (bus.decoder == null) return const Center(child: Text('No decoder found', style: TextStyle(color: Colors.grey)));

                var packets = bus.decoder!.packets;
                if (packets.isEmpty) return const Center(child: Text('No packets recorded', style: TextStyle(color: Colors.grey)));

                var frames = bus.decoder!.frames;
                if (frames.isEmpty) {
                  frames = [
                    ProtocolFrame(
                      startIndex: packets.isNotEmpty ? packets.first.startIndex : 0,
                      endIndex: packets.isNotEmpty ? packets.last.endIndex : 0,
                      summary: 'Raw Packets',
                      packets: packets,
                    )
                  ];
                }

                // Note: If new data arrived and we are searching, _filteredData might be slightly outdated
                // until the debounce triggers again, which is perfectly fine for performance!
                bool isSearching = _activeSearchQuery.isNotEmpty;
                int itemCount = isSearching ? (_filteredData?.length ?? 0) : frames.length;

                if (itemCount == 0 && isSearching) {
                  return const Center(child: Text('No matching events', style: TextStyle(color: Colors.grey)));
                }

                // Process Highlight
                int? highlightStart = state.highlightedStartIndex;
                if (state.highlightTriggerSequence != _lastProcessedHighlightSequence && state.highlightedBusName == widget.busName && highlightStart != null) {
                  _lastProcessedHighlightSequence = state.highlightTriggerSequence;
                  
                  int targetListIndex = -1;
                  for (int i = 0; i < itemCount; i++) {
                     int fIdx = isSearching ? _filteredData![i]['frameIndex'] : i;
                     // Prevent out of bounds if frames updated before filter
                     if (fIdx >= frames.length) continue;
                     var frame = frames[fIdx];
                     if (highlightStart >= frame.startIndex && highlightStart <= frame.endIndex) {
                        targetListIndex = i;
                        if (!_preventNextAutoExpand) {
                          _expandedFrames.add(fIdx);
                        }
                        break;
                     }
                  }
                  
                  bool shouldAutoScroll = !_preventNextAutoExpand;
                  _preventNextAutoExpand = false;
                  
                  if (targetListIndex != -1 && shouldAutoScroll) {
                    double exactOffset = 0.0;
                    for (int i = 0; i < targetListIndex; i++) {
                       int prevFIdx = isSearching ? _filteredData![i]['frameIndex'] : i;
                       if (prevFIdx >= frames.length) {
                         exactOffset += 48.0;
                         continue;
                       }
                       if (!_expandedFrames.contains(prevFIdx)) {
                         exactOffset += 48.0;
                       } else {
                         ProtocolFrame prevFrame = frames[prevFIdx];
                         int visiblePackets = 0;
                         for (var p in prevFrame.packets) {
                            if (!_hiddenTypes!.contains(p.type)) {
                               if (!isSearching || p.data.toLowerCase().contains(_activeSearchQuery) || (p.rawValue?.toString().contains(_activeSearchQuery) ?? false)) {
                                  visiblePackets++;
                               }
                            }
                         }
                         exactOffset += 48.0 + (visiblePackets * 32.0);
                       }
                    }

                     WidgetsBinding.instance.addPostFrameCallback((_) {
                       if (_scrollController.hasClients) {
                           int maxJumps = 20;
                           while (maxJumps-- > 0) {
                               double currentMax = _scrollController.position.maxScrollExtent;
                               if (exactOffset <= currentMax) {
                                   _scrollController.jumpTo(exactOffset);
                                   break;
                               } else {
                                   _scrollController.jumpTo(currentMax);
                                   if (_scrollController.position.maxScrollExtent <= currentMax) {
                                       // The extent didn't grow, we reached the absolute physical limit
                                       break; 
                                   }
                               }
                           }
                       }
                     });
                  }
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.only(top: 4.0, left: 4.0, right: 4.0, bottom: MediaQuery.of(context).size.height),
                  itemCount: itemCount,
                  itemExtentBuilder: (index, dimension) {
                     int frameIndex = isSearching ? _filteredData![index]['frameIndex'] : index;
                     if (frameIndex >= frames.length) return 48.0;
                     if (!_expandedFrames.contains(frameIndex)) return 48.0;
                     
                     ProtocolFrame frame = frames[frameIndex];
                     int visiblePackets = 0;
                     for (var p in frame.packets) {
                        if (!_hiddenTypes!.contains(p.type)) {
                           if (!isSearching || p.data.toLowerCase().contains(_activeSearchQuery) || (p.rawValue?.toString().contains(_activeSearchQuery) ?? false)) {
                              visiblePackets++;
                           }
                        }
                     }
                     return 48.0 + (visiblePackets * 32.0);
                  },
                  itemBuilder: (context, index) {
                     int frameIndex = isSearching ? _filteredData![index]['frameIndex'] : index;
                     if (frameIndex >= frames.length) return const SizedBox.shrink(); // Safety check
                     
                     ProtocolFrame frame = frames[frameIndex];
                     bool isExpanded = _expandedFrames.contains(frameIndex);
                     bool isHighlighted = state.highlightedBusName == widget.busName && 
                                          state.highlightedStartIndex != null && 
                                          state.highlightedStartIndex! >= frame.startIndex && 
                                          state.highlightedStartIndex! <= frame.endIndex;
                     
                     // Compute valid packet count for header dynamically
                     int validPktCount = 0;
                     for (var p in frame.packets) {
                        if (!_hiddenTypes!.contains(p.type)) {
                           if (!isSearching || p.data.toLowerCase().contains(_activeSearchQuery) || (p.rawValue?.toString().contains(_activeSearchQuery) ?? false)) {
                              validPktCount++;
                           }
                        }
                     }

                     Color frameColor = Colors.cyanAccent;
                     bool hasError = frame.packets.any((p) => p.type == PacketType.error);
                     
                     // I2C specific NACK error logic
                     if (!hasError) {
                       bool currentIsRead = false;
                       for (int i = 0; i < frame.packets.length; i++) {
                         var p = frame.packets[i];
                         if (p.type == PacketType.readWrite) {
                           currentIsRead = (p.data == 'READ');
                         } else if (p.data == 'NACK') {
                           if (i > 0) {
                             var prev = frame.packets[i - 1];
                             if (prev.type == PacketType.readWrite) {
                               hasError = true;
                               break;
                             } else if (prev.type == PacketType.data) {
                               if (!currentIsRead) {
                                 hasError = true;
                                 break;
                               } else {
                                 bool isErrorNack = false;
                                 for (int j = i + 1; j < frame.packets.length; j++) {
                                   if (frame.packets[j].type == PacketType.data) {
                                     isErrorNack = true; 
                                     break;
                                   } else if (frame.packets[j].type == PacketType.start || frame.packets[j].type == PacketType.stop) {
                                     break; 
                                   }
                                 }
                                 if (isErrorNack) {
                                   hasError = true;
                                   break;
                                 }
                               }
                             }
                           }
                         }
                       }
                     }

                     if (hasError) {
                       frameColor = Colors.red;
                     } else if (frame.summary.endsWith('(Incomplete)')) {
                       frameColor = Colors.white;
                     } else if (frame.summary.startsWith('Rx') || frame.summary.startsWith('W:')) {
                       frameColor = Colors.cyanAccent;
                     } else if (frame.summary.startsWith('Tx') || frame.summary.startsWith('R:')) {
                       frameColor = Colors.yellow;
                     }

                     return Column(
                       children: [
                         // Frame Header (Card)
                         SizedBox(
                            height: 48.0,
                            child: Card(
                               color: isHighlighted ? const Color(0xFF1E3A5F) : const Color(0xFF222222),
                               shape: isHighlighted 
                                   ? RoundedRectangleBorder(
                                       side: const BorderSide(color: Colors.cyan, width: 1.0),
                                       borderRadius: BorderRadius.circular(4.0),
                                     )
                                   : null,
                               margin: const EdgeInsets.only(bottom: 2.0, left: 4, right: 4),
                               child: InkWell(
                                 onTap: () {
                                   // 1. Perform waveform positioning immediately (Zero delay!)
                                   int currentAbsoluteOffset = state.digitalChannel.totalPointsAdded - state.digitalChannel.count;
                                   int offsetDiff = bus.decoder!.lastDecodeAbsoluteOffset - currentAbsoluteOffset;
                                   int startLogical = frame.startIndex + offsetDiff;
                                   
                                   int latestX = state.latestX.toInt();
                                   
                                   double activeScale = state.xScale;
                                   double minScale = state.chartWidth / OscilloscopeState.maxPointsPerChannel;
                                   if (activeScale < minScale) activeScale = minScale;
                                   
                                   double targetOffset = (latestX - startLogical) * activeScale - state.chartWidth * 11.0 / 14.0;
                                   if (targetOffset < 0) targetOffset = 0;
                                   state.setXScrollOffset(targetOffset);
                                   
                                   _preventNextAutoExpand = true;
                                   state.setHighlight(bus.name, frame.startIndex, frame.endIndex);

                                   // 2. Detect double tap manually to expand/collapse
                                   final now = DateTime.now();
                                   if (_lastTapTime != null && 
                                       _lastTapFrameIndex == frameIndex && 
                                       now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
                                     setState(() {
                                       if (isExpanded) {
                                         _expandedFrames.remove(frameIndex);
                                       } else {
                                         _expandedFrames.add(frameIndex);
                                       }
                                     });
                                     _lastTapTime = null;
                                     _lastTapFrameIndex = null;
                                   } else {
                                     _lastTapTime = now;
                                     _lastTapFrameIndex = frameIndex;
                                   }
                                 },
                                 child: Padding(
                                   padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                                   child: Row(
                                     children: [
                                       SizedBox(
                                         width: 60, 
                                         child: Column(
                                           mainAxisSize: MainAxisSize.min,
                                           crossAxisAlignment: CrossAxisAlignment.start,
                                           children: [
                                             const Text('Frame', style: TextStyle(color: Colors.grey, fontSize: 10, height: 1.0)),
                                             Text('#$frameIndex', style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold, height: 1.2)),
                                           ],
                                         ),
                                       ),
                                       Expanded(child: Text(frame.summary, style: TextStyle(color: frameColor, fontSize: 13, fontWeight: FontWeight.bold))),
                                       Text('$validPktCount pkts', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                       const SizedBox(width: 8),
                                       Icon(isExpanded ? Icons.expand_less : Icons.expand_more, color: Colors.grey, size: 20),
                                     ],
                                   ),
                                 ),
                               ),
                            ),
                         ),

                         // Packets List
                         if (isExpanded)
                           ...frame.packets.map((packet) {
                              if (_hiddenTypes!.contains(packet.type)) return const SizedBox.shrink();
                              
                              bool packetMatchesSearch = !isSearching || 
                                  packet.data.toLowerCase().contains(_activeSearchQuery) || 
                                  (packet.rawValue?.toString().contains(_activeSearchQuery) ?? false);
                              if (!packetMatchesSearch) return const SizedBox.shrink();
                              
                              int globalIdx = _getGlobalPacketIndex(bus.decoder!.packets, packet);
                              
                              bool isHighlighted = false;
                              if (state.highlightedBusName == widget.busName && state.highlightedStartIndex != null && state.highlightedEndIndex != null) {
                                  isHighlighted = packet.startIndex >= state.highlightedStartIndex! && packet.endIndex <= state.highlightedEndIndex!;
                              }
                                                   
                              return Container(
                                
                                height: 30.0,
                                margin: const EdgeInsets.only(bottom: 2.0, left: 16, right: 4),
                                decoration: BoxDecoration(
                                  color: isHighlighted ? Colors.cyan.withValues(alpha: 0.3) : const Color(0xFF1A1A1A),
                                  borderRadius: BorderRadius.circular(2),
                                  border: Border(left: BorderSide(color: packet.color, width: 3)),
                                ),
                                child: InkWell(
                                  onDoubleTap: () {
                                    if (packet.type == PacketType.address && decoder is I2cDecoder && packet.rawValue != null) {
                                      _showMountRegfileDialog(context, state, widget.busName, packet.rawValue!, decoder);
                                    }
                                  },
                                  onTap: () {
                                      int currentAbsoluteOffset = state.digitalChannel.totalPointsAdded - state.digitalChannel.count;
                                      int offsetDiff = bus.decoder!.lastDecodeAbsoluteOffset - currentAbsoluteOffset;
                                      int startLogical = packet.startIndex + offsetDiff;
                                      
                                      int latestX = state.latestX.toInt();
                                      
                                      double activeScale = state.xScale;
                                      double minScale = state.chartWidth / OscilloscopeState.maxPointsPerChannel;
                                      if (activeScale < minScale) activeScale = minScale;
                                      
                                      double targetOffset = (latestX - startLogical) * activeScale - state.chartWidth / 2.0;
                                      if (targetOffset < 0) targetOffset = 0;
                                      state.setXScrollOffset(targetOffset);
                                      if (state.highlightedBusName != bus.name || state.highlightedStartIndex != packet.startIndex) {
                                        _preventNextAutoExpand = true;
                                      }
                                      state.setHighlight(bus.name, packet.startIndex, packet.endIndex);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 68, child: Text('#$globalIdx', style: const TextStyle(color: Colors.grey, fontSize: 12))),
                                        SizedBox(width: 100, child: Text(
                                          decoder.getPacketTypeName(packet.type), 
                                          style: TextStyle(
                                            color: packet.color, 
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12
                                          )
                                        )),
                                        SizedBox(width: 150, child: Builder(
                                          builder: (context) {
                                            String displayData = packet.data;
                                            if (packet.type == PacketType.address && packet.rawValue != null) {
                                              var state = context.read<OscilloscopeState>();
                                              var regfile = state.getRegfileFor(bus.name, packet.rawValue!);
                                              if (regfile != null) {
                                                displayData = '${packet.data} (${regfile.name})';
                                              }
                                            }
                                            return Text(
                                              displayData,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: packet.data == 'ACK' ? Colors.green : (packet.data == 'NACK' ? Colors.redAccent : Colors.white), 
                                                fontWeight: (packet.data == 'ACK' || packet.data == 'NACK') ? FontWeight.bold : FontWeight.normal,
                                                fontSize: 13
                                              )
                                            );
                                          }
                                        )),
                                        if (packet.rawValue != null)
                                          Expanded(
                                            child: Text(
                                              packet.rawValue.toString(),
                                              textAlign: TextAlign.right,
                                              style: const TextStyle(color: Colors.grey, fontSize: 12, fontFamily: 'monospace')
                                            )
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                           }) // map
                       ],
                     );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
