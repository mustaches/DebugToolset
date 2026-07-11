import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';
import '../../../providers/terminal_state.dart';
import '../models/protocol_decoder.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import '../../../utils/hover_builder.dart';

class BottomChannelBar extends StatefulWidget {
  const BottomChannelBar({super.key});

  @override
  State<BottomChannelBar> createState() => _BottomChannelBarState();
}

class _BottomChannelBarState extends State<BottomChannelBar> {
  Timer? _timer;
  String _currentTime = '';
  String _currentDate = '';

  @override
  void initState() {
    super.initState();
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTime();
    });
  }

  void _updateTime() {
    final now = DateTime.now();
    setState(() {
      _currentTime = DateFormat('HH:mm:ss').format(now);
      _currentDate = DateFormat('yyyy/MM/dd').format(now);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();
    final terminal = context.watch<TerminalState>();

    return Container(
      height: 64, // Increased to fix overflow
      decoration: BoxDecoration(
        color: const Color(0xFF161616), // Dark background
        border: Border(top: BorderSide(color: Colors.grey.shade800, width: 1.0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
      child: Row(
        children: [
          // 1. Gear Icon
          HoverBuilder(
            builder: (context, isHovered) {
              return GestureDetector(
                onTap: () => _showGlobalChannelToggleDialog(context, state),
                child: Container(
                  padding: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color: isHovered ? const Color(0xFF222222) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(Icons.settings, color: isHovered ? Colors.white : Colors.grey, size: 28),
                ),
              );
            }
          ),
          
          // 2. Analog Channels (A1-A4)
          Row(
            children: List.generate(state.channels.length, (index) {
              final ch = state.channels[index];
              return _buildAnalogChannelBox(context, state, index, ch);
            }),
          ),
          const SizedBox(width: 24),

          // 3. Digital Channels (L1-L4)
          Row(
            children: List.generate(4, (index) {
              return _buildDigitalBusBox(context, state, index);
            }),
          ),
          const Spacer(),

          if (state.showCursors)
            Row(
              children: [
                _buildCursorToggle(
                  label: 'XCursor',
                  value: state.showXCursors,
                  onChanged: (v) => state.toggleXCursors(),
                  color: Colors.yellowAccent,
                ),
                const SizedBox(width: 8),
                _buildCursorToggle(
                  label: 'YCursor',
                  value: state.showYCursors,
                  onChanged: (v) => state.toggleYCursors(),
                  color: Colors.cyanAccent,
                ),
                const SizedBox(width: 16),
              ],
            ),
          
          // 4. Time/Date and Connection Status Box
          _buildSystemStatusBox(terminal),
        ],
      ),
    );
  }
  Widget _buildCursorToggle({required String label, required bool value, required Function(bool?) onChanged, required Color color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Theme(
          data: ThemeData(
            unselectedWidgetColor: Colors.grey,
            checkboxTheme: CheckboxThemeData(
              fillColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? color : Colors.transparent),
              checkColor: WidgetStateProperty.all(Colors.black),
            )
          ),
          child: Checkbox(
            value: value,
            onChanged: onChanged,
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
          ),
        ),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildAnalogChannelBox(BuildContext context, OscilloscopeState state, int index, ChannelData ch) {
    bool isActive = ch.isVisible;
    Color boxColor = isActive ? ch.color : Colors.grey.shade600;

    return HoverBuilder(
      builder: (context, isHovered) {
        return Container(
          width: 85,
          margin: const EdgeInsets.only(right: 6.0),
          decoration: BoxDecoration(
            color: isHovered ? const Color(0xFF2A2A2A) : const Color(0xFF202020),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isHovered ? (isActive ? ch.color : Colors.white) : (isActive ? boxColor : Colors.grey.shade800), 
              width: isActive || isHovered ? 3.0 : 2.0
            ),
            boxShadow: isHovered && isActive ? [BoxShadow(color: boxColor.withValues(alpha: 0.3), blurRadius: 4)] : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Channel Number Tab
              GestureDetector(
                onTap: () => state.toggleChannelVisibility(index),
                child: Container(
                  width: 24,
                  color: isActive ? boxColor : Colors.grey.shade800,
                  alignment: Alignment.center,
                  child: Text(
                    'A${index + 1}',
                    style: TextStyle(
                      color: isActive ? Colors.black : Colors.grey.shade400, 
                      fontWeight: FontWeight.w900, 
                      fontSize: 12
                    ),
                  ),
                ),
              ),
              // Channel Info
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(isActive ? '${ch.yScale.toStringAsFixed(2)}V/' : '', style: TextStyle(color: boxColor, fontSize: 10, fontWeight: FontWeight.bold)),
                          Text(isActive ? '' : 'OFF', style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
                        ],
                      ),
                      Text(isActive ? '${ch.yOffset.toStringAsFixed(2)}V' : '', style: const TextStyle(color: Colors.grey, fontSize: 10)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(isActive ? '1X' : '', style: const TextStyle(color: Colors.grey, fontSize: 9)),
                          Text(isActive ? '----' : '', style: const TextStyle(color: Colors.grey, fontSize: 9)),
                        ],
                      )
                    ],
                  ),
                ),
              )
            ],
          ),
        );
      }
    );
  }

  Widget _buildDigitalBusBox(BuildContext context, OscilloscopeState state, int busIndex) {
    int startPin = busIndex * 8;
    int endPin = startPin + 7;
    bool isActive = state.digitalChannel.enabledPins.any((p) => p >= startPin && p <= endPin);
    Color boxColor = isActive ? Colors.purpleAccent : Colors.grey.shade600;
    
    String rangeLabel = '';
    if (busIndex == 0) rangeLabel = 'D[7:0]';
    else if (busIndex == 1) rangeLabel = 'D[15:8]';
    else if (busIndex == 2) rangeLabel = 'D[23:16]';
    else if (busIndex == 3) rangeLabel = 'D[31:24]';

    return HoverBuilder(
      builder: (context, isHovered) {
        return GestureDetector(
          onTap: () {
            bool anyEnabled = false;
            for (int p = startPin; p <= endPin; p++) {
              if (state.digitalChannel.enabledPins.contains(p)) {
                anyEnabled = true;
                break;
              }
            }
            state.setDigitalPinGroupVisibility(startPin, endPin, !anyEnabled);
          },
          onLongPress: () {
            _showMsoGroupDialog(context, state, busIndex);
          },
          child: Container(
            width: 85,
            margin: const EdgeInsets.only(right: 6.0),
            decoration: BoxDecoration(
              color: isHovered ? const Color(0xFF2A2A2A) : const Color(0xFF202020),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isHovered ? (isActive ? Colors.purpleAccent : Colors.white) : (isActive ? boxColor : Colors.grey.shade800), 
                width: isActive || isHovered ? 3.0 : 2.0
              ),
              boxShadow: isHovered && isActive ? [BoxShadow(color: boxColor.withValues(alpha: 0.3), blurRadius: 4)] : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 24,
                  color: isActive ? boxColor : Colors.grey.shade800,
                  alignment: Alignment.center,
                  child: Text(
                    'L${busIndex + 1}',
                    style: TextStyle(
                      color: isActive ? Colors.black : Colors.grey.shade400, 
                      fontWeight: FontWeight.w900, 
                      fontSize: 12
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2.0, vertical: 2.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          rangeLabel,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: boxColor, fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                        _buildDigitalPinRow(state, startPin, startPin + 3),
                        _buildDigitalPinRow(state, startPin + 4, endPin),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    );
  }

  Widget _buildDigitalPinRow(OscilloscopeState state, int startPin, int endPin) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(endPin - startPin + 1, (i) {
        int pin = startPin + i;
        bool isEnabled = state.digitalChannel.enabledPins.contains(pin);
        return Text(
          '$pin',
          style: TextStyle(
            color: isEnabled ? Colors.greenAccent : Colors.grey.shade700,
            fontSize: 8,
            fontWeight: isEnabled ? FontWeight.bold : FontWeight.normal,
          ),
        );
      }),
    );
  }

  Widget _buildSystemStatusBox(TerminalState terminal) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              Text('LXI', style: TextStyle(color: terminal.isConnected ? Colors.greenAccent : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Icon(terminal.isConnected ? Icons.usb : Icons.usb_off, color: terminal.isConnected ? Colors.greenAccent : Colors.grey, size: 14),
            ],
          ),
          const SizedBox(height: 4),
          Text(_currentTime, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          Text(_currentDate, style: const TextStyle(color: Colors.grey, fontSize: 10)),
        ],
      ),
    );
  }

  void _showGlobalChannelToggleDialog(BuildContext context, OscilloscopeState state) {
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('通道快速设置', style: TextStyle(color: Colors.white, fontSize: 16)),
          content: Container(
            width: 880,
            constraints: const BoxConstraints(maxHeight: 600),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Column: Channels
                SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Consumer<OscilloscopeState>(
                      builder: (ctx, consumerState, child) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('模拟通道 (Analog)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                Switch(
                                  value: consumerState.channels.every((ch) => ch.isVisible),
                                  activeThumbColor: Colors.blueAccent,
                                  onChanged: (v) {
                                    consumerState.setAllChannelsVisibility(v);
                                  },
                                )
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: List.generate(consumerState.channels.length, (i) {
                                final ch = consumerState.channels[i];
                                return FilterChip(
                                  label: Text('CH${i + 1}', style: TextStyle(color: ch.isVisible ? Colors.black : Colors.white, fontWeight: FontWeight.bold)),
                                  selected: ch.isVisible,
                                  onSelected: (_) => consumerState.toggleChannelVisibility(i),
                                  selectedColor: ch.color,
                                  backgroundColor: Colors.grey.shade800,
                                  checkmarkColor: Colors.black,
                                );
                              }),
                            ),
                            const SizedBox(height: 16),
                            const Divider(color: Colors.grey),
                            const SizedBox(height: 8),
                            const Text('数字逻辑通道 (Digital)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                            const SizedBox(height: 8),
                            Column(
                              children: List.generate(4, (index) {
                                int groupIndex = 3 - index; // D31-D24, D23-D16, D15-D8, D7-D0 from top to bottom
                                int start = groupIndex * 8;
                                int end = start + 7;
                                
                                bool allEnabled = true;
                                for (int i = start; i <= end; i++) {
                                  if (!consumerState.digitalChannel.enabledPins.contains(i)) {
                                    allEnabled = false;
                                    break;
                                  }
                                }
                                
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: [
                                      const Color(0xFF1A2634), // D7-D0 (dark blue)
                                      const Color(0xFF1A3426), // D15-D8 (dark green)
                                      const Color(0xFF341A26), // D23-D16 (dark pink)
                                      const Color(0xFF34261A), // D31-D24 (dark orange)
                                    ][groupIndex],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.grey.shade800),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text('D$end - D$start', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                          SizedBox(
                                            height: 28,
                                            child: Switch(
                                              value: allEnabled,
                                              activeThumbColor: Colors.purpleAccent,
                                              onChanged: (v) {
                                                consumerState.setDigitalPinGroupVisibility(start, end, v);
                                              },
                                            ),
                                          )
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: List.generate(8, (pinOffset) {
                                          int pin = end - pinOffset; // D31 down to D24, D7 down to D0
                                          bool isEnabled = consumerState.digitalChannel.enabledPins.contains(pin);
                                          return FilterChip(
                                            label: SizedBox(
                                              width: 22,
                                              child: Center(child: Text('D$pin', style: TextStyle(fontSize: 9, color: isEnabled ? Colors.white : Colors.grey.shade400)))
                                            ),
                                            selected: isEnabled,
                                            onSelected: (_) => consumerState.toggleDigitalPinVisibility(pin),
                                            showCheckmark: false,
                                            selectedColor: Colors.purpleAccent.withValues(alpha: 0.6),
                                            backgroundColor: Colors.grey.shade900,
                                            padding: EdgeInsets.zero,
                                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          );
                                        }),
                                      )
                                    ],
                                  ),
                                );
                              }),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                
                // Vertical Divider
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: 1,
                    color: Colors.grey.shade800,
                  ),
                ),
                
                // Right Column: Buses
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('总线分组配置 (Buses)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 8),
                      
                      // Scrollable Buses list
                      Expanded(
                        child: Consumer<OscilloscopeState>(
                          builder: (ctx, consumerState, child) {
                            final buses = consumerState.digitalChannel.buses;
                            if (buses.isEmpty) {
                              return const Center(
                                child: Text(
                                  '暂无总线配置',
                                  style: TextStyle(color: Colors.grey, fontSize: 12),
                                ),
                              );
                            }
                            return ListView.builder(
                              itemCount: buses.length,
                              itemBuilder: (ctx, idx) => _buildBusItem(consumerState, buses[idx]),
                            );
                          }
                        ),
                      ),
                      const SizedBox(height: 12),
                      
                      // Buttons grid
                      Consumer<OscilloscopeState>(
                        builder: (ctx, consumerState, child) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _showAddBusDialog(context, consumerState),
                                      icon: const Icon(Icons.add, size: 14),
                                      label: const Text('添加总线', style: TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.grey.shade800,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _saveBusSetup(context, consumerState),
                                      icon: const Icon(Icons.save, size: 14),
                                      label: const Text('保存配置', style: TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.grey.shade800,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _importBusSetup(context, consumerState),
                                      icon: const Icon(Icons.download, size: 14),
                                      label: const Text('导入配置', style: TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.grey.shade800,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _deleteBusSetup(context),
                                      icon: const Icon(Icons.delete, size: 14),
                                      label: const Text('删除配置', style: TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.grey.shade800,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        }
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showChannelConfigDialog(BuildContext context, OscilloscopeState state, int index, ChannelData ch) {
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text('CH${index + 1} 设置', style: TextStyle(color: ch.color, fontSize: 14)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Vertical Scale: ${ch.yScale.toStringAsFixed(2)} V/div', style: const TextStyle(color: Colors.white, fontSize: 12)),
              Slider(
                value: ch.yScale,
                min: 0.1,
                max: 10.0,
                onChanged: (v) => state.setChannelScale(index, v),
              ),
              const SizedBox(height: 16),
              Text('Vertical Offset: ${ch.yOffset.toStringAsFixed(0)} px', style: const TextStyle(color: Colors.white, fontSize: 12)),
              Slider(
                value: ch.yOffset,
                min: -400.0,
                max: 400.0,
                onChanged: (v) => state.setChannelOffset(index, v),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  state.toggleChannelVisibility(index);
                  Navigator.of(ctx).pop();
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('关闭通道', style: TextStyle(color: Colors.white)),
              )
            ],
          ),
        );
      }
    );
  }

  void _showMsoGroupDialog(BuildContext context, OscilloscopeState state, int busIndex) {
    int start = busIndex * 8;
    int end = start + 7;
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text('MSO L${busIndex + 1} (D$start - D$end) 数字逻辑引脚配置', style: const TextStyle(color: Colors.white, fontSize: 14)),
          content: SizedBox(
            width: 320,
            child: Consumer<OscilloscopeState>(
              builder: (ctx, consumerState, child) {
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(8, (i) {
                    int index = start + i;
                    final isEnabled = consumerState.digitalChannel.enabledPins.contains(index);
                    return FilterChip(
                      label: Text('D$index', style: const TextStyle(fontSize: 10, color: Colors.white)),
                      selected: isEnabled,
                      onSelected: (_) => consumerState.toggleDigitalPinVisibility(index),
                      showCheckmark: false,
                      selectedColor: Colors.purpleAccent,
                      backgroundColor: Colors.grey.shade800,
                      padding: EdgeInsets.zero,
                    );
                  }),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showBatchRenamePinsDialog(BuildContext context, OscilloscopeState state, DigitalBus bus) {
    
    List<int> pinsOrdered = [];
    if (bus.startPin < bus.endPin) {
      for (int p = bus.endPin; p >= bus.startPin; p--) {
        pinsOrdered.add(p);
      }
    } else {
      for (int p = bus.startPin; p >= bus.endPin; p--) {
        pinsOrdered.add(p);
      }
    }
    
    Map<int, TextEditingController> controllers = {};
    for (int p in pinsOrdered) {
      controllers[p] = TextEditingController(text: bus.pinNames[p] ?? '');
    }
    
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text('批量命名引脚 (${bus.name})', style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: SizedBox(
            width: 300,
            height: 400,
            child: ListView.builder(
              itemCount: pinsOrdered.length,
              itemBuilder: (context, index) {
                int p = pinsOrdered[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    children: [
                      SizedBox(width: 40, child: Text('D$p', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                      Expanded(
                        child: TextField(
                          controller: controllers[p],
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            hintText: '留空则清除',
                            hintStyle: TextStyle(color: Colors.grey, fontSize: 12),
                            border: OutlineInputBorder(),
                            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyan)),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                for (int p in pinsOrdered) {
                  state.setDigitalBusPinName(bus.name, p, controllers[p]!.text.trim());
                }
                Navigator.of(ctx).pop();
              },
              child: const Text('确定', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      }
    );
  }

  Widget _buildBusItem(OscilloscopeState state, DigitalBus bus) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                GestureDetector(
                  onTap: () {
                    List<Color> colors = [
                      Colors.redAccent, Colors.pinkAccent, Colors.purpleAccent, Colors.deepPurpleAccent,
                      Colors.indigoAccent, Colors.blueAccent, Colors.lightBlueAccent, Colors.cyanAccent,
                      Colors.tealAccent, Colors.greenAccent, Colors.lightGreenAccent, Colors.limeAccent,
                      Colors.yellowAccent, Colors.amberAccent, Colors.orangeAccent, Colors.deepOrangeAccent,
                    ];
                    showDialog(
                      context: context,
                      useRootNavigator: false,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF2A2A2A),
                        title: const Text('选择总线颜色', style: TextStyle(color: Colors.white, fontSize: 14)),
                        content: SizedBox(
                          width: 240,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: colors.map((c) => GestureDetector(
                              onTap: () {
                                state.setDigitalBusColor(bus.name, c);
                                Navigator.of(ctx).pop();
                              },
                              child: Container(
                                width: 32, height: 32,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white24, width: 2),
                                ),
                              ),
                            )).toList(),
                          ),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: bus.color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white54, width: 1),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    TextEditingController controller = TextEditingController(text: bus.name);
                    showDialog(
                      context: context,
                      useRootNavigator: false,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF2A2A2A),
                        title: const Text('重命名总线', style: TextStyle(color: Colors.white, fontSize: 14)),
                        content: TextField(
                          controller: controller,
                          autofocus: true,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: '输入新名称',
                            hintStyle: TextStyle(color: Colors.grey),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('取消', style: TextStyle(color: Colors.grey)),
                          ),
                          TextButton(
                            onPressed: () {
                              state.renameDigitalBus(bus.name, controller.text.trim());
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('确定', style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      )
                    );
                  },
                  child: Row(
                    children: [
                      Text(bus.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 4),
                      const Icon(Icons.edit, color: Colors.grey, size: 12),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: () {
                    _showEditBusDialog(context, state, bus);
                  },
                  child: Row(
                    children: [
                      Text('Pins: D${bus.startPin} - D${bus.endPin}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 4),
                      const Icon(Icons.settings, color: Colors.grey, size: 12),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: () {
                    _showBatchRenamePinsDialog(context, state, bus);
                  },
                  child: Row(
                    children: [
                      const Text('批量命名引脚', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 4),
                      const Icon(Icons.drive_file_rename_outline, color: Colors.grey, size: 12),
                    ],
                  ),
                ),
                if (bus.decoder != null) ...[
                  const SizedBox(width: 16),
                  GestureDetector(
                    onTap: () {
                      state.toggleEventList(bus.name);
                    },
                    child: Row(
                      children: [
                        Text(state.activeEventListBusName == bus.name ? '隐藏列表' : '事件列表', 
                             style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 4),
                        Icon(state.activeEventListBusName == bus.name ? Icons.expand_more : Icons.list_alt, 
                             color: Colors.cyanAccent, size: 12),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          ),
          IconButton(
            icon: Icon(bus.isExpanded ? Icons.unfold_less : Icons.unfold_more, color: Colors.white, size: 20),
            onPressed: () => state.toggleDigitalBusExpanded(bus.name),
            tooltip: bus.isExpanded ? '聚合' : '散开',
          ),
          DropdownButton<DigitalBusFormat>(
            value: bus.format,
            dropdownColor: const Color(0xFF2A2A2A),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: DigitalBusFormat.hex, child: Text('HEX')),
              DropdownMenuItem(value: DigitalBusFormat.decimal, child: Text('DEC')),
              DropdownMenuItem(value: DigitalBusFormat.binary, child: Text('BIN')),
              DropdownMenuItem(value: DigitalBusFormat.ascii, child: Text('ASCII')),
            ],
            onChanged: (fmt) {
              if (fmt != null) state.updateDigitalBusFormat(bus.name, fmt);
            },
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
            onPressed: () => state.removeDigitalBus(bus.name),
            tooltip: '删除总线',
          ),
        ],
      ),
    );
  }

  void _showEditBusDialog(BuildContext context, OscilloscopeState state, DigitalBus bus) {
    TextEditingController nameController = TextEditingController(text: bus.name);

    String busType = 'normal';
    int start = bus.startPin;
    int end = bus.endPin;
    DigitalBusFormat format = bus.format;
    
    int rxPin = bus.startPin;
    int txPin = -1;
    int baudRate = 0;
    int dataBits = 8;
    String parity = 'none';
    int stopBits = 1;
    bool lsbFirst = true;
    
    int sclPin = bus.startPin;
    int sdaPin = bus.endPin;

    int spiSckPin = bus.startPin;
    int spiMosiPin = bus.endPin;
    int spiMisoPin = -1;
    int spiCsPin = -1;
    int spiIo2Pin = -1;
    int spiIo3Pin = -1;
    String? spiProtocolFile;
    int spiCpol = 0;
    int spiCpha = 0;
    int spiDataBits = 8;
    bool spiLsbFirst = false;
    
    if (bus.decoder != null) {
      if (bus.decoder is UartDecoder) {
        busType = 'uart';
        rxPin = (bus.decoder as UartDecoder).rxPin;
        txPin = (bus.decoder as UartDecoder).txPin;
        baudRate = (bus.decoder as UartDecoder).baudRate;
        dataBits = (bus.decoder as UartDecoder).dataBits;
        parity = (bus.decoder as UartDecoder).parity;
        stopBits = (bus.decoder as UartDecoder).stopBits;
        lsbFirst = (bus.decoder as UartDecoder).lsbFirst;
      } else if (bus.decoder is I2cDecoder) {
        busType = 'i2c';
        sclPin = (bus.decoder as I2cDecoder).sclPin;
        sdaPin = (bus.decoder as I2cDecoder).sdaPin;
      } else if (bus.decoder is Ads7038hDecoder) {
        busType = 'spi_ads7038h';
        spiSckPin = (bus.decoder as Ads7038hDecoder).sckPin;
        spiMosiPin = (bus.decoder as Ads7038hDecoder).mosiPin;
        spiMisoPin = (bus.decoder as Ads7038hDecoder).misoPin;
        spiCsPin = (bus.decoder as Ads7038hDecoder).csPin;
      } else if (bus.decoder is SpiDecoder) {
        busType = 'spi';
        spiSckPin = (bus.decoder as SpiDecoder).sckPin;
        spiMosiPin = (bus.decoder as SpiDecoder).mosiPin;
        spiMisoPin = (bus.decoder as SpiDecoder).misoPin;
        spiCsPin = (bus.decoder as SpiDecoder).csPin;
        spiIo2Pin = (bus.decoder as SpiDecoder).io2Pin;
        spiIo3Pin = (bus.decoder as SpiDecoder).io3Pin;
        spiProtocolFile = (bus.decoder as SpiDecoder).protocolFile;
        spiCpol = (bus.decoder as SpiDecoder).cpol;
        spiCpha = (bus.decoder as SpiDecoder).cpha;
        spiDataBits = (bus.decoder as SpiDecoder).dataBits;
        spiLsbFirst = (bus.decoder as SpiDecoder).lsbFirst;
      }
    }
    
    Color getPinColor(int pin) {
      int groupIndex = pin ~/ 8;
      return [
        const Color(0xFF1A2634), // dark blue tint
        const Color(0xFF1A3426), // dark green tint
        const Color(0xFF341A26), // dark pink tint
        const Color(0xFF34261A), // dark orange tint
      ][groupIndex];
    }
    
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2A2A2A),
              title: Text('修改总线/分析器: ${bus.name}', style: const TextStyle(color: Colors.white, fontSize: 14)),
              content: SizedBox(
                width: 400,
                child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('总线类型: ', style: TextStyle(color: Colors.white)),
                        DropdownButton<String>(
                          value: busType,
                          dropdownColor: const Color(0xFF2A2A2A),
                          style: const TextStyle(color: Colors.white),
                          items: const [
                            DropdownMenuItem(value: 'normal', child: Text('普通总线')),
                            DropdownMenuItem(value: 'uart', child: Text('UART 协议分析器')),
                            DropdownMenuItem(value: 'i2c', child: Text('I2C 协议分析器')),
                            DropdownMenuItem(value: 'spi', child: Text('SPI 协议分析器')),
                            DropdownMenuItem(value: 'spi_ads7038h', child: Text('ADS7038H 专属分析器')),
                          ],
                          onChanged: (v) => setState(() => busType = v!),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('总线名称: ', style: TextStyle(color: Colors.white)),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: nameController,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '输入名称',
                              hintStyle: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (busType == 'normal') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Start Pin (LSB): ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: start,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(31, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) {
                              setState(() {
                                start = v!;
                                if (end <= start) {
                                  end = start + 1;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('End Pin (MSB): ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: end,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32 - (start + 1), (i) {
                              int pin = start + 1 + i;
                              return DropdownMenuItem(
                                value: pin, 
                                child: Container(
                                  color: getPinColor(pin),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$pin'),
                                )
                              );
                            }),
                            onChanged: (v) => setState(() => end = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Format: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<DigitalBusFormat>(
                            value: format,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: DigitalBusFormat.hex, child: Text('HEX')),
                              DropdownMenuItem(value: DigitalBusFormat.decimal, child: Text('DEC')),
                              DropdownMenuItem(value: DigitalBusFormat.binary, child: Text('BIN')),
                              DropdownMenuItem(value: DigitalBusFormat.ascii, child: Text('ASCII')),
                            ],
                            onChanged: (v) => setState(() => format = v!),
                          ),
                        ],
                      ),
                    ],
                    if (busType == 'uart') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('RX 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: rxPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => rxPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('TX 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: txPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => txPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('波特率: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: baudRate,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: 0, child: Text('Auto')),
                              ...[9600, 19200, 38400, 57600, 115200, 921600].map((b) => DropdownMenuItem(
                                value: b, 
                                child: Text(b.toString())
                              ))
                            ],
                            onChanged: (v) => setState(() => baudRate = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('数据位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: dataBits,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [5, 6, 7, 8, 9].map((b) => DropdownMenuItem(value: b, child: Text(b.toString()))).toList(),
                            onChanged: (v) => setState(() => dataBits = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('校验位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<String>(
                            value: parity,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: 'none', child: Text('None')),
                              DropdownMenuItem(value: 'even', child: Text('Even')),
                              DropdownMenuItem(value: 'odd', child: Text('Odd')),
                            ],
                            onChanged: (v) => setState(() => parity = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('停止位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: stopBits,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [1, 2].map((b) => DropdownMenuItem(value: b, child: Text(b.toString()))).toList(),
                            onChanged: (v) => setState(() => stopBits = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('位序: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<bool>(
                            value: lsbFirst,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: true, child: Text('LSB First')),
                              DropdownMenuItem(value: false, child: Text('MSB First')),
                            ],
                            onChanged: (v) => setState(() => lsbFirst = v!),
                          ),
                        ],
                      ),
                    ],
                    if (busType == 'i2c') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('SCL 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: sclPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) => setState(() => sclPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('SDA 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: sdaPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) => setState(() => sdaPin = v!),
                          ),
                        ],
                      ),
                    ],
                    if (busType == 'spi' || busType == 'spi_ads7038h') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CS 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiCsPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiCsPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('SCLK 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiSckPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) => setState(() => spiSckPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('MOSI/IO0 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiMosiPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiMosiPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('MISO/IO1 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiMisoPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiMisoPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('IO2 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiIo2Pin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiIo2Pin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('IO3 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiIo3Pin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiIo3Pin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('协议文件 (可选): ', style: TextStyle(color: Colors.white)),
                          DropdownButton<String?>(
                            value: spiProtocolFile,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: null, child: Text('无')),
                              ...state.availableSpiRegfiles.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name)))
                            ],
                            onChanged: (v) => setState(() => spiProtocolFile = v),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CPOL: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiCpol,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('0 (Idle Low)')),
                              DropdownMenuItem(value: 1, child: Text('1 (Idle High)')),
                            ],
                            onChanged: (v) => setState(() => spiCpol = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CPHA: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiCpha,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('0 (1st Edge)')),
                              DropdownMenuItem(value: 1, child: Text('1 (2nd Edge)')),
                            ],
                            onChanged: (v) => setState(() => spiCpha = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('数据位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiDataBits,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [4, 8, 16, 24, 32].map((b) => DropdownMenuItem(value: b, child: Text(b.toString()))).toList(),
                            onChanged: (v) => setState(() => spiDataBits = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('位序: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<bool>(
                            value: spiLsbFirst,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: false, child: Text('MSB First')),
                              DropdownMenuItem(value: true, child: Text('LSB First')),
                            ],
                            onChanged: (v) => setState(() => spiLsbFirst = v!),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (busType == 'normal') {
                      state.updateDigitalBus(DigitalBus(name: nameController.text.trim(), startPin: start, endPin: end, format: format, color: bus.color, yScale: bus.yScale, yOffset: bus.yOffset, isExpanded: bus.isExpanded), bus.name);
                    } else if (busType == 'uart') {
                      int startPin = rxPin >= 0 ? rxPin : (txPin >= 0 ? txPin : 0);
                      int endPin = txPin >= 0 ? txPin : (rxPin >= 0 ? rxPin : 0);
                      state.updateDigitalBus(DigitalBus(name: nameController.text.trim(), startPin: startPin, endPin: endPin, format: DigitalBusFormat.hex, color: bus.color, yScale: bus.yScale, yOffset: bus.yOffset, isExpanded: bus.isExpanded, decoder: UartDecoder(rxPin: rxPin, txPin: txPin, baudRate: baudRate, dataBits: dataBits, parity: parity, stopBits: stopBits, lsbFirst: lsbFirst)), bus.name);
                    } else if (busType == 'i2c') {
                      int newStartPin = sclPin < sdaPin ? sclPin : sdaPin;
                      int newEndPin = sclPin > sdaPin ? sclPin : sdaPin;
                      state.updateDigitalBus(DigitalBus(name: nameController.text.trim(), startPin: newStartPin, endPin: newEndPin, format: DigitalBusFormat.hex, color: bus.color, yScale: bus.yScale, yOffset: bus.yOffset, isExpanded: bus.isExpanded, decoder: I2cDecoder(sclPin: sclPin, sdaPin: sdaPin)), bus.name);
                    } else if (busType == 'spi_ads7038h') {
                      List<int> activePins = [spiSckPin, spiMosiPin, spiMisoPin, spiCsPin].where((p) => p >= 0).toList();
                      int newStartPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a < b ? a : b);
                      int newEndPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a > b ? a : b);
                      state.updateDigitalBus(DigitalBus(name: nameController.text.trim(), startPin: newStartPin, endPin: newEndPin, format: DigitalBusFormat.hex, color: bus.color, yScale: bus.yScale, yOffset: bus.yOffset, isExpanded: bus.isExpanded, decoder: Ads7038hDecoder(sckPin: spiSckPin, mosiPin: spiMosiPin, misoPin: spiMisoPin, csPin: spiCsPin)), bus.name);
                    } else if (busType == 'spi') {
                      List<int> activePins = [spiSckPin, spiMosiPin, spiMisoPin, spiCsPin, spiIo2Pin, spiIo3Pin].where((p) => p >= 0).toList();
                      int newStartPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a < b ? a : b);
                      int newEndPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a > b ? a : b);
                      state.updateDigitalBus(DigitalBus(name: nameController.text.trim(), startPin: newStartPin, endPin: newEndPin, format: DigitalBusFormat.hex, color: bus.color, yScale: bus.yScale, yOffset: bus.yOffset, isExpanded: bus.isExpanded, decoder: SpiDecoder(sckPin: spiSckPin, mosiPin: spiMosiPin, misoPin: spiMisoPin, csPin: spiCsPin, io2Pin: spiIo2Pin, io3Pin: spiIo3Pin, protocolFile: spiProtocolFile, cpol: spiCpol, cpha: spiCpha, dataBits: spiDataBits, lsbFirst: spiLsbFirst)), bus.name);
                    }
                    Navigator.of(ctx).pop();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                  child: const Text('确定', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      }
    );
  }

  void _showAddBusDialog(BuildContext context, OscilloscopeState state) {
    int index = 0;
    while (state.digitalChannel.buses.any((b) => b.name == 'BUS$index')) {
      index++;
    }
    TextEditingController nameController = TextEditingController(text: 'BUS$index');

    String busType = 'normal';
    int start = 0;
    int end = 1;
    DigitalBusFormat format = DigitalBusFormat.hex;
    
    int rxPin = 2;
    int txPin = 3;
    int baudRate = 0;
    int dataBits = 8;
    String parity = 'none';
    int stopBits = 1;
    bool lsbFirst = true;
    
    int sclPin = 0;
    int sdaPin = 1;
    
    int spiSckPin = 0;
    int spiMosiPin = 1;
    int spiMisoPin = 2;
    int spiCsPin = 3;
    int spiIo2Pin = -1;
    int spiIo3Pin = -1;
    String? spiProtocolFile;
    int spiCpol = 0;
    int spiCpha = 0;
    int spiDataBits = 8;
    bool spiLsbFirst = false;
    
    Color getPinColor(int pin) {
      int groupIndex = pin ~/ 8;
      return [
        const Color(0xFF1A2634), // dark blue tint
        const Color(0xFF1A3426), // dark green tint
        const Color(0xFF341A26), // dark pink tint
        const Color(0xFF34261A), // dark orange tint
      ][groupIndex];
    }
    
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2A2A2A),
              title: const Text('添加总线/分析器', style: TextStyle(color: Colors.white, fontSize: 14)),
              content: SizedBox(
                width: 400,
                child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('总线类型: ', style: TextStyle(color: Colors.white)),
                        DropdownButton<String>(
                          value: busType,
                          dropdownColor: const Color(0xFF2A2A2A),
                          style: const TextStyle(color: Colors.white),
                          items: const [
                            DropdownMenuItem(value: 'normal', child: Text('普通总线')),
                            DropdownMenuItem(value: 'uart', child: Text('UART 协议分析器')),
                            DropdownMenuItem(value: 'i2c', child: Text('I2C 协议分析器')),
                            DropdownMenuItem(value: 'spi', child: Text('SPI 协议分析器')),
                            DropdownMenuItem(value: 'spi_ads7038h', child: Text('ADS7038H 专属分析器')),
                          ],
                          onChanged: (v) => setState(() => busType = v!),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('总线名称: ', style: TextStyle(color: Colors.white)),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: nameController,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '输入名称',
                              hintStyle: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (busType == 'normal') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Start Pin (LSB): ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: start,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(31, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) {
                              setState(() {
                                start = v!;
                                if (end <= start) {
                                  end = start + 1;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('End Pin (MSB): ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: end,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32 - (start + 1), (i) {
                              int pin = start + 1 + i;
                              return DropdownMenuItem(
                                value: pin, 
                                child: Container(
                                  color: getPinColor(pin),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$pin'),
                                )
                              );
                            }),
                            onChanged: (v) => setState(() => end = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Format: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<DigitalBusFormat>(
                            value: format,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: DigitalBusFormat.hex, child: Text('HEX')),
                              DropdownMenuItem(value: DigitalBusFormat.decimal, child: Text('DEC')),
                              DropdownMenuItem(value: DigitalBusFormat.binary, child: Text('BIN')),
                              DropdownMenuItem(value: DigitalBusFormat.ascii, child: Text('ASCII')),
                            ],
                            onChanged: (v) => setState(() => format = v!),
                          ),
                        ],
                      ),
                    ],
                    if (busType == 'uart') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('RX 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: rxPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => rxPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('TX 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: txPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => txPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('波特率: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: baudRate,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('Auto')),
                              DropdownMenuItem(value: 9600, child: Text('9600')),
                              DropdownMenuItem(value: 19200, child: Text('19200')),
                              DropdownMenuItem(value: 38400, child: Text('38400')),
                              DropdownMenuItem(value: 57600, child: Text('57600')),
                              DropdownMenuItem(value: 115200, child: Text('115200')),
                              DropdownMenuItem(value: 1000000, child: Text('1000000')),
                            ],
                            onChanged: (v) => setState(() => baudRate = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('数据位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: dataBits,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [5, 6, 7, 8, 9].map((b) => DropdownMenuItem(value: b, child: Text(b.toString()))).toList(),
                            onChanged: (v) => setState(() => dataBits = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('校验位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<String>(
                            value: parity,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: 'none', child: Text('None')),
                              DropdownMenuItem(value: 'even', child: Text('Even')),
                              DropdownMenuItem(value: 'odd', child: Text('Odd')),
                            ],
                            onChanged: (v) => setState(() => parity = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('停止位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: stopBits,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [1, 2].map((b) => DropdownMenuItem(value: b, child: Text(b.toString()))).toList(),
                            onChanged: (v) => setState(() => stopBits = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('位序: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<bool>(
                            value: lsbFirst,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: true, child: Text('LSB First')),
                              DropdownMenuItem(value: false, child: Text('MSB First')),
                            ],
                            onChanged: (v) => setState(() => lsbFirst = v!),
                          ),
                        ],
                      ),
                    ],
                    if (busType == 'i2c') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('SCL 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: sclPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) => setState(() => sclPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('SDA 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: sdaPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) => setState(() => sdaPin = v!),
                          ),
                        ],
                      ),
                    ],
                    if (busType == 'spi' || busType == 'spi_ads7038h') ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CS 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiCsPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiCsPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('SCLK 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiSckPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: List.generate(32, (i) => DropdownMenuItem(
                              value: i, 
                              child: Container(
                                color: getPinColor(i),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                child: Text('D$i'),
                              )
                            )),
                            onChanged: (v) => setState(() => spiSckPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('MOSI/IO0 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiMosiPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiMosiPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('MISO/IO1 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiMisoPin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiMisoPin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('IO2 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiIo2Pin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiIo2Pin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('IO3 引脚: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiIo3Pin,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: -1, child: Text('None')),
                              ...List.generate(32, (i) => DropdownMenuItem(
                                value: i, 
                                child: Container(
                                  color: getPinColor(i),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  child: Text('D$i'),
                                )
                              ))
                            ],
                            onChanged: (v) => setState(() => spiIo3Pin = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('协议文件 (可选): ', style: TextStyle(color: Colors.white)),
                          DropdownButton<String?>(
                            value: spiProtocolFile,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [
                              const DropdownMenuItem(value: null, child: Text('无')),
                              ...state.availableSpiRegfiles.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name)))
                            ],
                            onChanged: (v) => setState(() => spiProtocolFile = v),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CPOL: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiCpol,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('0 (Idle Low)')),
                              DropdownMenuItem(value: 1, child: Text('1 (Idle High)')),
                            ],
                            onChanged: (v) => setState(() => spiCpol = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('CPHA: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiCpha,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('0 (1st Edge)')),
                              DropdownMenuItem(value: 1, child: Text('1 (2nd Edge)')),
                            ],
                            onChanged: (v) => setState(() => spiCpha = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('数据位: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<int>(
                            value: spiDataBits,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: [4, 8, 16, 24, 32].map((b) => DropdownMenuItem(value: b, child: Text(b.toString()))).toList(),
                            onChanged: (v) => setState(() => spiDataBits = v!),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('位序: ', style: TextStyle(color: Colors.white)),
                          DropdownButton<bool>(
                            value: spiLsbFirst,
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: const TextStyle(color: Colors.white),
                            items: const [
                              DropdownMenuItem(value: false, child: Text('MSB First')),
                              DropdownMenuItem(value: true, child: Text('LSB First')),
                            ],
                            onChanged: (v) => setState(() => spiLsbFirst = v!),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (busType == 'normal') {
                      state.addDigitalBus(nameController.text.trim(), start, end, format);
                    } else if (busType == 'uart') {
                      int startPin = rxPin >= 0 ? rxPin : (txPin >= 0 ? txPin : 0);
                      int endPin = txPin >= 0 ? txPin : (rxPin >= 0 ? rxPin : 0);
                      state.addDigitalBus(nameController.text.trim(), startPin, endPin, DigitalBusFormat.hex, decoder: UartDecoder(rxPin: rxPin, txPin: txPin, baudRate: baudRate, dataBits: dataBits, parity: parity, stopBits: stopBits, lsbFirst: lsbFirst));
                    } else if (busType == 'i2c') {
                      int startPin = sclPin < sdaPin ? sclPin : sdaPin;
                      int endPin = sclPin > sdaPin ? sclPin : sdaPin;
                      state.addDigitalBus(nameController.text.trim(), startPin, endPin, DigitalBusFormat.hex, decoder: I2cDecoder(sclPin: sclPin, sdaPin: sdaPin));
                    } else if (busType == 'spi_ads7038h') {
                      List<int> activePins = [spiSckPin, spiMosiPin, spiMisoPin, spiCsPin].where((p) => p >= 0).toList();
                      int newStartPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a < b ? a : b);
                      int newEndPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a > b ? a : b);
                      state.addDigitalBus(nameController.text.trim(), newStartPin, newEndPin, DigitalBusFormat.hex, decoder: Ads7038hDecoder(sckPin: spiSckPin, mosiPin: spiMosiPin, misoPin: spiMisoPin, csPin: spiCsPin));
                    } else if (busType == 'spi') {
                      List<int> activePins = [spiSckPin, spiMosiPin, spiMisoPin, spiCsPin, spiIo2Pin, spiIo3Pin].where((p) => p >= 0).toList();
                      int newStartPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a < b ? a : b);
                      int newEndPin = activePins.isEmpty ? 0 : activePins.reduce((a, b) => a > b ? a : b);
                      state.addDigitalBus(nameController.text.trim(), newStartPin, newEndPin, DigitalBusFormat.hex, decoder: SpiDecoder(sckPin: spiSckPin, mosiPin: spiMosiPin, misoPin: spiMisoPin, csPin: spiCsPin, io2Pin: spiIo2Pin, io3Pin: spiIo3Pin, protocolFile: spiProtocolFile, cpol: spiCpol, cpha: spiCpha, dataBits: spiDataBits, lsbFirst: spiLsbFirst));
                    }
                    Navigator.of(ctx).pop();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                  child: const Text('确定', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      }
    );
  }


  Future<bool> _saveBusSetup(BuildContext context, OscilloscopeState state) async {
    if (state.digitalChannel.buses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前没有总线可以保存')));
      return false;
    }

    Directory dir = Directory('bussetup');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    List<FileSystemEntity> files = await dir.list().toList();
    List<File> busFiles = files.whereType<File>().where((f) => f.path.endsWith('.bussetup')).toList();

    if (!context.mounted) return false;

    TextEditingController controller = TextEditingController();
    
    bool? result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2A2A2A),
              title: const Text('保存总线设置', style: TextStyle(color: Colors.white, fontSize: 14)),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busFiles.isNotEmpty) ...[
                      const Align(alignment: Alignment.centerLeft, child: Text('已有配置文件:', style: TextStyle(color: Colors.grey, fontSize: 12))),
                      const SizedBox(height: 8),
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade800),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ListView.builder(
                          itemCount: busFiles.length,
                          itemBuilder: (context, index) {
                            String filename = busFiles[index].path.split(RegExp(r'[/\\]')).last;
                            String nameWithoutExt = filename.substring(0, filename.length - 9); // '.bussetup'.length == 9
                            return ListTile(
                              title: Text(filename, style: const TextStyle(color: Colors.white, fontSize: 12)),
                              onTap: () {
                                setState(() {
                                  controller.text = nameWithoutExt;
                                });
                              },
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: controller,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: '输入文件名 (不含后缀)',
                        hintStyle: TextStyle(color: Colors.grey),
                        labelText: '文件名',
                        labelStyle: TextStyle(color: Colors.blueAccent),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消', style: TextStyle(color: Colors.grey)),
                ),
                TextButton(
                  onPressed: () async {
                    String filename = controller.text.trim();
                    if (filename.isEmpty) return;
                    
                    File file = File('${dir.path}/$filename.bussetup');
                    if (await file.exists()) {
                      if (!context.mounted) return;
                      bool? confirm = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          backgroundColor: const Color(0xFF2A2A2A),
                          title: const Text('覆盖确认', style: TextStyle(color: Colors.white)),
                          content: Text('文件 "$filename.bussetup" 已存在，是否覆盖？', style: const TextStyle(color: Colors.white)),
                          actions: [
                            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('取消', style: TextStyle(color: Colors.grey))),
                            ElevatedButton(
                              onPressed: () => Navigator.of(c).pop(true), 
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                              child: const Text('覆盖', style: TextStyle(color: Colors.white))
                            ),
                          ]
                        )
                      );
                      if (confirm != true) return;
                    }

                    try {
                      List<Map<String, dynamic>> busesJson = state.digitalChannel.buses.map((b) => b.toJson()).toList();
                      Map<String, dynamic> fileContent = {
                        "version": 2,
                        "xScale": state.xScale,
                        "xScrollOffset": 0.0,
                        "buses": busesJson,
                      };
                      await file.writeAsString(jsonEncode(fileContent));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存成功: ${file.path}')));
                      }
                      if (ctx.mounted) {
                        Navigator.of(ctx).pop(true);
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
                      }
                    }
                  },
                  child: const Text('保存', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      }
    );
    return result ?? false;
  }

  void _importBusSetup(BuildContext context, OscilloscopeState state) async {
    Directory dir = Directory('bussetup');
    if (!await dir.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('找不到总线设置目录，请先保存。')));
      }
      return;
    }
    List<FileSystemEntity> files = await dir.list().toList();
    List<File> busFiles = files.whereType<File>().where((f) => f.path.endsWith('.bussetup')).toList();
    if (busFiles.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有找到任何 .bussetup 文件。')));
      }
      return;
    }
    
    if (!context.mounted) return;
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('选择要导入的总线设置', style: TextStyle(color: Colors.white, fontSize: 14)),
        content: SizedBox(
          width: 300,
          height: 400,
          child: ListView.builder(
            itemCount: busFiles.length,
            itemBuilder: (context, index) {
              File file = busFiles[index];
              String filename = file.path.split(RegExp(r'[/\\]')).last;
              return ListTile(
                title: Text(filename, style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _processImport(context, state, file);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
        ],
      )
    );
  }

  void _processImport(BuildContext context, OscilloscopeState state, File file) async {
    try {
      String content = await file.readAsString();
      dynamic decoded = jsonDecode(content);
      
      List<DigitalBus> importedBuses = [];
      double? importedXScale;
      double? importedXScrollOffset;
      
      if (decoded is List) {
        importedBuses = decoded.map((j) => DigitalBus.fromJson(j)).toList();
      } else if (decoded is Map) {
        if (decoded['buses'] != null) {
          importedBuses = (decoded['buses'] as List).map((j) => DigitalBus.fromJson(j)).toList();
        }
        importedXScale = decoded['xScale']?.toDouble();
        importedXScrollOffset = decoded['xScrollOffset']?.toDouble();
      }

      if (state.digitalChannel.buses.isNotEmpty) {
        if (!context.mounted) return;
        int? importMode = await showDialog<int>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2A2A),
            title: const Text('导入选项', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: const Text('当前已有总线配置，请选择导入方式：', style: TextStyle(color: Colors.white)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null), // cancel
                child: const Text('取消', style: TextStyle(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(0), // append
                child: const Text('追加', style: TextStyle(color: Colors.cyan)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(1), // clear
                child: const Text('清除并覆盖', style: TextStyle(color: Colors.redAccent)),
              ),
              TextButton(
                onPressed: () async {
                  bool saved = await _saveBusSetup(ctx, state);
                  if (saved && ctx.mounted) {
                    Navigator.of(ctx).pop(2);
                  }
                }, // backup and clear
                child: const Text('保存原有并覆盖', style: TextStyle(color: Colors.orange)),
              ),
            ],
          ),
        );
        
        if (importMode == null) return;
        
        if (importMode == 2 || importMode == 1) {
           state.clearDigitalBuses();
        }
      }
      
      List<DigitalBus> nonConflicting = [];
      List<Map<String, DigitalBus>> conflicts = [];
      
      for (DigitalBus newBus in importedBuses) {
        int existingIndex = state.digitalChannel.buses.indexWhere((b) => b.name == newBus.name);
        if (existingIndex >= 0) {
          conflicts.add({
            'old': state.digitalChannel.buses[existingIndex],
            'new': newBus
          });
        } else {
          nonConflicting.add(newBus);
        }
      }

      // 自动添加不冲突的总线
      for (var bus in nonConflicting) {
        state.updateDigitalBus(bus);
      }

      // 如果有冲突，统一弹出一个对话框让用户选择
      if (conflicts.isNotEmpty) {
        if (!context.mounted) return;
        List<DigitalBus>? toUpdate = await _showMultiConflictDialog(context, conflicts);
        if (toUpdate != null) {
          for (var bus in toUpdate) {
            state.updateDigitalBus(bus);
          }
          if (importedXScale != null) state.setTimebase(importedXScale);
          if (importedXScrollOffset != null) state.setXScrollOffset(importedXScrollOffset);
        }
      } else {
        if (importedXScale != null) state.setTimebase(importedXScale);
        if (importedXScrollOffset != null) state.setXScrollOffset(importedXScrollOffset);
      }
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('导入完成')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  Future<List<DigitalBus>?> _showMultiConflictDialog(BuildContext context, List<Map<String, DigitalBus>> conflicts) async {
    return await showDialog<List<DigitalBus>>(
      context: context,
      builder: (ctx) {
        List<bool> selected = List.generate(conflicts.length, (i) => true);
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2A2A2A),
              title: const Text('发现同名总线', style: TextStyle(color: Colors.orangeAccent, fontSize: 16)),
              content: SizedBox(
                width: 400,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('以下总线在当前配置中已存在，请选择要覆盖更新的项目：', style: TextStyle(color: Colors.white, fontSize: 13)),
                      const SizedBox(height: 12),
                      ...List.generate(conflicts.length, (index) {
                        DigitalBus oldBus = conflicts[index]['old']!;
                        DigitalBus newBus = conflicts[index]['new']!;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            border: Border.all(color: Colors.grey.shade800),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Checkbox(
                                value: selected[index],
                                activeColor: Colors.orange,
                                onChanged: (v) {
                                  setState(() {
                                    selected[index] = v ?? false;
                                  });
                                }
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(oldBus.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 4),
                                    Text('当前: D${oldBus.startPin} - D${oldBus.endPin} (${oldBus.format.name})', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                    Text('导入: D${newBus.startPin} - D${newBus.endPin} (${newBus.format.name})', style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ],
                          )
                        );
                      }),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('取消', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    List<DigitalBus> toUpdate = [];
                    for (int i = 0; i < conflicts.length; i++) {
                      if (selected[i]) {
                        toUpdate.add(conflicts[i]['new']!);
                      }
                    }
                    Navigator.of(ctx).pop(toUpdate);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  child: const Text('确定更新', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      }
    );
  }

  void _deleteBusSetup(BuildContext context) async {
    Directory dir = Directory('bussetup');
    if (!await dir.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('找不到总线设置目录，暂无文件可删除。')));
      }
      return;
    }
    List<FileSystemEntity> files = await dir.list().toList();
    List<File> busFiles = files.whereType<File>().where((f) => f.path.endsWith('.bussetup')).toList();
    if (busFiles.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有任何总线设置文件可以删除。')));
      }
      return;
    }
    
    if (!context.mounted) return;
    
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2A2A2A),
              title: const Text('删除总线设置文件', style: TextStyle(color: Colors.white, fontSize: 14)),
              content: SizedBox(
                width: 300,
                height: 400,
                child: busFiles.isEmpty 
                  ? const Center(child: Text('暂无文件可删除', style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                    itemCount: busFiles.length,
                    itemBuilder: (context, index) {
                      File file = busFiles[index];
                      String filename = file.path.split(RegExp(r'[/\\]')).last;
                      return ListTile(
                        title: Text(filename, style: const TextStyle(color: Colors.white)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.redAccent),
                          onPressed: () async {
                            bool? confirm = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                backgroundColor: const Color(0xFF2A2A2A),
                                title: const Text('确认删除', style: TextStyle(color: Colors.white)),
                                content: Text('确定要删除文件 "$filename" 吗？', style: const TextStyle(color: Colors.white)),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(c).pop(false), 
                                    child: const Text('取消', style: TextStyle(color: Colors.grey))
                                  ),
                                  ElevatedButton(
                                    onPressed: () => Navigator.of(c).pop(true), 
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                    child: const Text('删除', style: TextStyle(color: Colors.white))
                                  ),
                                ]
                              )
                            );
                            if (confirm == true) {
                              try {
                                await file.delete();
                                setState(() {
                                  busFiles.removeAt(index);
                                });
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已删除: $filename')));
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
                                }
                              }
                            }
                          },
                        ),
                      );
                    },
                  ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭', style: TextStyle(color: Colors.grey)),
                ),
              ],
            );
          }
        );
      }
    );
  }
}
