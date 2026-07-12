import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';

class LATriggerMenuDialog extends StatefulWidget {
  const LATriggerMenuDialog({super.key});

  @override
  State<LATriggerMenuDialog> createState() => _LATriggerMenuDialogState();
}

class _LATriggerMenuDialogState extends State<LATriggerMenuDialog> {
  final TextEditingController _targetValueController = TextEditingController();
  final TextEditingController _delaysController = TextEditingController();
  
  // Protocol controllers
  final TextEditingController _i2cAddressController = TextEditingController();
  final TextEditingController _i2cDataController = TextEditingController();
  final TextEditingController _spiMosiDataController = TextEditingController();
  final TextEditingController _spiMisoDataController = TextEditingController();
  final TextEditingController _uartBaudController = TextEditingController();
  final TextEditingController _uartDataController = TextEditingController();
  final TextEditingController _canBaudController = TextEditingController();
  final TextEditingController _canIdController = TextEditingController();
  final TextEditingController _canDataController = TextEditingController();
  final TextEditingController _canDataOffsetController = TextEditingController();
  final TextEditingController _linBaudController = TextEditingController();
  final TextEditingController _linIdController = TextEditingController();
  final TextEditingController _linDataController = TextEditingController();
  final TextEditingController _usbPidController = TextEditingController();
  final TextEditingController _usbAddrController = TextEditingController();
  final TextEditingController _usbEpController = TextEditingController();
  final TextEditingController _usbDataController = TextEditingController();

  @override
  void dispose() {
    _targetValueController.dispose();
    _delaysController.dispose();
    _i2cAddressController.dispose();
    _i2cDataController.dispose();
    _spiMosiDataController.dispose();
    _spiMisoDataController.dispose();
    _uartBaudController.dispose();
    _uartDataController.dispose();
    _canBaudController.dispose();
    _canIdController.dispose();
    _canDataController.dispose();
    _canDataOffsetController.dispose();
    _linBaudController.dispose();
    _linIdController.dispose();
    _linDataController.dispose();
    _usbPidController.dispose();
    _usbAddrController.dispose();
    _usbEpController.dispose();
    _usbDataController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();
    final isDigital = state.triggerSourceType == TriggerSourceType.digital;
    final config = state.digitalTrigger;

    // Initialize controller text if needed
    if (isDigital && _targetValueController.text.isEmpty && config.targetValues.isNotEmpty) {
      if (!config.isBusSequence) {
        _targetValueController.text = '0x${config.targetValues.first.toRadixString(16).toUpperCase()}';
      } else {
        _targetValueController.text = config.targetValues.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
      }
    }
    
    if (isDigital && _delaysController.text.isEmpty && config.sequenceDelays.isNotEmpty) {
      _delaysController.text = config.sequenceDelays.join(' ');
    }

    // Protocol initializations
    if (isDigital && _i2cAddressController.text.isEmpty) {
      _i2cAddressController.text = '0x${config.i2cAddress.toRadixString(16).toUpperCase()}';
    }
    if (isDigital && _i2cDataController.text.isEmpty && config.i2cData.isNotEmpty) {
      _i2cDataController.text = config.i2cData.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
    }
    if (isDigital && _spiMosiDataController.text.isEmpty && config.spiMosiData.isNotEmpty) {
      _spiMosiDataController.text = config.spiMosiData.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
    }
    if (isDigital && _spiMisoDataController.text.isEmpty && config.spiMisoData.isNotEmpty) {
      _spiMisoDataController.text = config.spiMisoData.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
    }
    if (isDigital && _uartBaudController.text.isEmpty) {
      _uartBaudController.text = config.uartBaudRate.toString();
    }
    if (isDigital && _uartDataController.text.isEmpty && config.uartData.isNotEmpty) {
      _uartDataController.text = config.uartData.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
    }
    if (isDigital && _canBaudController.text.isEmpty) {
      _canBaudController.text = config.canBaudRate.toString();
    }
    if (isDigital && _canIdController.text.isEmpty) {
      _canIdController.text = '0x${config.canId.toRadixString(16).toUpperCase()}';
    }
    if (isDigital && _canDataController.text.isEmpty && config.canData.isNotEmpty) {
      _canDataController.text = config.canData.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
    }
    if (isDigital && _canDataOffsetController.text.isEmpty) {
      _canDataOffsetController.text = config.canDataOffset.toString();
    }
    if (isDigital && _linBaudController.text.isEmpty) {
      _linBaudController.text = config.linBaudRate.toString();
    }
    if (isDigital && _linIdController.text.isEmpty) {
      _linIdController.text = '0x${config.linId.toRadixString(16).toUpperCase()}';
    }
    if (isDigital && _linDataController.text.isEmpty && config.linData.isNotEmpty) {
      _linDataController.text = config.linData.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
    }
    if (isDigital && _usbPidController.text.isEmpty) {
      _usbPidController.text = '0x${config.usbPid.toRadixString(16).toUpperCase()}';
    }
    if (isDigital && _usbAddrController.text.isEmpty) {
      _usbAddrController.text = config.usbAddr.toString();
    }
    if (isDigital && _usbEpController.text.isEmpty) {
      _usbEpController.text = config.usbEp.toString();
    }
    if (isDigital && _usbDataController.text.isEmpty && config.usbData.isNotEmpty) {
      _usbDataController.text = config.usbData.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
    }

    return Dialog(
      backgroundColor: const Color(0xFF161616),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade800, width: 2),
      ),
      child: Container(
        width: 650, // Widened
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              const TextSpan(
                children: [
                  TextSpan(text: '逻辑触发 '),
                  TextSpan(text: '(LA Trigger)', style: TextStyle(fontSize: 12, color: Colors.white54, fontWeight: FontWeight.normal)),
                ],
              ),
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            
            _buildDropdownRow<TriggerSourceType>(
              cnLabel: '控制权',
              enLabel: 'Control',
              value: state.triggerSourceType,
              items: const [TriggerSourceType.digital, TriggerSourceType.analog],
              onChanged: (val) {
                if (val != null) {
                  state.setTriggerSource(val, val == TriggerSourceType.analog ? state.triggerSourceIndex : 0);
                }
              },
              itemBuilder: (item) => '', // Not used
              customItemWidgetBuilder: (item) {
                return Text(
                  item == TriggerSourceType.analog ? '示波器触发 (Ext OSC)' : '逻辑触发 (Digital)',
                  style: TextStyle(
                    color: item == TriggerSourceType.analog ? Colors.orangeAccent : Colors.cyanAccent,
                  ),
                );
              },
            ),
            
            if (!isDigital) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade700),
                ),
                child: const Text(
                  '触发已交由示波器控制。请在示波器触发面板配置相关参数。\n(Trigger is controlled by the Oscilloscope. Please use the OSC trigger panel.)',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              // Box for digital conditions
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade700),
                  borderRadius: BorderRadius.circular(4),
                  color: const Color(0xFF1E1E1E),
                ),
                child: Column(
                  children: [
                    // Tabs Header
                    Container(
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: Colors.grey.shade700)),
                        color: const Color(0xFF252525),
                      ),
                      child: Row(
                        children: [
                          _buildTabButton(state, config, DigitalTriggerType.singleChannel, '单通道', 'Single'),
                          _buildTabButton(state, config, DigitalTriggerType.bus, '总线', 'Bus'),
                          _buildTabButton(state, config, DigitalTriggerType.advancedBus, '高级总线', 'Adv. Bus'),
                          _buildTabButton(state, config, DigitalTriggerType.protocol, '协议', 'Protocol'),
                        ],
                      ),
                    ),
                    // Tab Content
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: _buildTabContent(state, config),
                    ),
                  ],
                ),
              ),
            ],
            
            const SizedBox(height: 24),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: '触发位置 '),
                      const TextSpan(text: '(Position)', style: TextStyle(fontSize: 11, color: Colors.white54)),
                      TextSpan(text: ' : ${config.triggerPositionPercentage.toInt()}%', style: const TextStyle(color: Colors.cyanAccent)),
                    ],
                  ),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove, color: Colors.white70, size: 16),
                      onPressed: () {
                          double val = config.triggerPositionPercentage - 1.0;
                          if (val < 1) val = 1;
                          config.triggerPositionPercentage = val;
                          state.setDigitalTrigger(config);
                      }
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2.0,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                        ),
                        child: Slider(
                          value: config.triggerPositionPercentage.clamp(1.0, 99.0),
                          min: 1,
                          max: 99,
                          divisions: 98,
                          activeColor: Colors.cyanAccent,
                          inactiveColor: Colors.grey.shade700,
                          onChanged: (val) {
                            config.triggerPositionPercentage = val;
                            state.setDigitalTrigger(config);
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, color: Colors.white70, size: 16),
                      onPressed: () {
                          double val = config.triggerPositionPercentage + 1.0;
                          if (val > 99) val = 99;
                          config.triggerPositionPercentage = val;
                          state.setDigitalTrigger(config);
                      }
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Checkbox(
                      value: config.enablePreTrigger,
                      activeColor: Colors.cyanAccent,
                      checkColor: Colors.black,
                      side: const BorderSide(color: Colors.white70),
                      onChanged: (val) {
                        if (val != null) {
                          config.enablePreTrigger = val;
                          state.setDigitalTrigger(config);
                        }
                      },
                    ),
                    const Text('预触发 (Pre-trigger)', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    const Spacer(),
                    const Text('采样率:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    const SizedBox(width: 4),
                    () {
                      final double rate = state.sampleRate;
                      double curValue;
                      String curUnit;
                      if (rate >= 1000000) {
                        curValue = double.parse((rate / 1000000).toStringAsFixed(1));
                        if (curValue == curValue.toInt().toDouble()) {
                          curValue = curValue.toInt().toDouble();
                        }
                        curUnit = 'MHz';
                      } else {
                        curValue = double.parse((rate / 1000).toStringAsFixed(1));
                        if (curValue == curValue.toInt().toDouble()) {
                          curValue = curValue.toInt().toDouble();
                        }
                        curUnit = 'KHz';
                      }
                      
                      final List<double> allowedValues = [1.0, 2.0, 2.5, 4.0, 5.0, 10.0, 20.0, 25.0, 40.0, 50.0, 100.0, 200.0, 250.0, 400.0, 500.0];
                      final List<double> dropdownValues = List<double>.from(allowedValues);
                      if (!dropdownValues.contains(curValue)) {
                        dropdownValues.add(curValue);
                        dropdownValues.sort();
                      }
                      
                      String formatDouble(double v) {
                        if (v == v.toInt().toDouble()) {
                          return '${v.toInt()}';
                        } else {
                          return '$v';
                        }
                      }
                      
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.grey.shade700),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<double>(
                                value: curValue,
                                dropdownColor: const Color(0xFF2A2A2A),
                                icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                onChanged: (val) {
                                  if (val != null) {
                                    double multiplier = curUnit == 'MHz' ? 1000000.0 : 1000.0;
                                    state.setSampleRate(val * multiplier);
                                  }
                                },
                                items: dropdownValues.map((v) => DropdownMenuItem(value: v, child: Text(formatDouble(v)))).toList(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.grey.shade700),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: curUnit,
                                dropdownColor: const Color(0xFF2A2A2A),
                                icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                onChanged: (val) {
                                  if (val != null) {
                                    double multiplier = val == 'MHz' ? 1000000.0 : 1000.0;
                                    state.setSampleRate(curValue * multiplier);
                                  }
                                },
                                items: const ['KHz', 'MHz'].map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                              ),
                            ),
                          ),
                        ],
                      );
                    }(),
                    const SizedBox(width: 12),
                    const Text('深度:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    const SizedBox(width: 4),
                    Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade700),
                      ),
                      child: () {
                        final List<int> allowedDepths = [32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728, 268435456];
                        int curDepth = state.memoryDepth;
                        if (!allowedDepths.contains(curDepth)) {
                          curDepth = allowedDepths.contains(OscilloscopeState.maxPointsPerChannel) ? OscilloscopeState.maxPointsPerChannel : allowedDepths.first;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            state.setMemoryDepth(curDepth);
                          });
                        }
                        return DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: curDepth,
                            dropdownColor: const Color(0xFF2A2A2A),
                            icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            onChanged: (val) {
                              if (val != null) state.setMemoryDepth(val);
                            },
                            items: allowedDepths
                                .map((e) => DropdownMenuItem(value: e, child: Text(_formatMemoryDepth(e))))
                                .toList(),
                          ),
                        );
                      }(),
                    ),
                  ],
                ),
              ],
            ),
            
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFF333333),
                ),
                child: const Text('关闭 (Close)'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(OscilloscopeState state, DigitalTriggerConfig config, DigitalTriggerType type, String cnLabel, String enLabel) {
    bool isSelected = config.type == type;
    return Expanded(
      child: InkWell(
        onTap: () {
          config.type = type;
          state.setDigitalTrigger(config);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? Colors.cyanAccent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Column(
            children: [
              Text(cnLabel, style: TextStyle(color: isSelected ? Colors.cyanAccent : Colors.white70, fontSize: 13, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
              Text(enLabel, style: TextStyle(color: isSelected ? Colors.cyanAccent.withAlpha(178) : Colors.white30, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  Color _getPinColor(int pin) {
    int groupIndex = pin ~/ 8;
    // Match the colors used in bottom_channel_bar
    Color baseColor = [
      Colors.blueAccent,
      Colors.greenAccent,
      Colors.orangeAccent,
      Colors.purpleAccent,
    ][groupIndex % 4];
    return baseColor.withAlpha(50); // Muted for background
  }

  Widget _buildTabContent(OscilloscopeState state, DigitalTriggerConfig config) {
    switch (config.type) {
      case DigitalTriggerType.singleChannel:
        return _buildSingleChannelTab(state, config);
      case DigitalTriggerType.bus:
        return _buildBusTab(state, config);
      case DigitalTriggerType.advancedBus:
        return _buildAdvancedBusTab(state, config);
      case DigitalTriggerType.protocol:
        return _buildProtocolTab(state, config);
    }
  }

  Widget _buildSingleChannelTab(OscilloscopeState state, DigitalTriggerConfig config) {
    return Row(
      children: [
        Expanded(
          child: _buildDropdownRow<int>(
            cnLabel: '通道',
            enLabel: 'Ch',
            value: config.pinIndex,
            items: List.generate(32, (i) => i),
            onChanged: (val) {
              if (val != null) {
                config.pinIndex = val;
                state.setDigitalTrigger(config);
              }
            },
            itemBuilder: (item) {
              String alias = state.digitalChannel.pinNames[item] ?? '';
              return alias.isNotEmpty ? '$alias (D$item)' : 'D$item';
            },
            itemColorBuilder: (item) => _getPinColor(item),
            compact: true,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildDropdownRow<TriggerEdge>(
            cnLabel: '边沿',
            enLabel: 'Edge',
            value: config.edge,
            items: TriggerEdge.values,
            onChanged: (val) {
              if (val != null) {
                config.edge = val;
                state.setDigitalTrigger(config);
              }
            },
            itemBuilder: (item) => '', // Not used when custom widget is provided
            customItemWidgetBuilder: (item) {
              return SizedBox(
                width: 32,
                height: 18,
                child: CustomPaint(
                  painter: EdgeIconPainter(item),
                ),
              );
            },
            compact: true,
          ),
        ),
      ],
    );
  }

  Widget _buildBusTab(OscilloscopeState state, DigitalTriggerConfig config) {
    final availableBuses = state.digitalChannel.buses;
    return Column(
      children: [
        if (availableBuses.isNotEmpty) ...[
          _buildDropdownRow<DigitalBus?>(
            cnLabel: '快速配置总线',
            enLabel: 'Quick Bus Config',
            value: null,
            items: [null, ...availableBuses],
            onChanged: (bus) {
              if (bus != null) {
                config.busLsbPin = bus.startPin;
                config.busMsbPin = bus.endPin;
                state.setDigitalTrigger(config);
              }
            },
            itemBuilder: (bus) => bus == null ? '选择已存在的总线...' : '${bus.name} (D${bus.startPin}-D${bus.endPin})',
            compact: false,
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(
              child: _buildDropdownRow<int>(
                cnLabel: '高位通道',
                enLabel: 'MSB',
                value: config.busMsbPin,
                items: List.generate(32, (i) => i),
                onChanged: (val) {
                  if (val != null) {
                    config.busMsbPin = val;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) {
                  String alias = state.digitalChannel.pinNames[item] ?? '';
                  return alias.isNotEmpty ? '$alias (D$item)' : 'D$item';
                },
                itemColorBuilder: (item) => _getPinColor(item),
                compact: true,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildDropdownRow<int>(
                cnLabel: '低位通道',
                enLabel: 'LSB',
                value: config.busLsbPin,
                items: List.generate(32, (i) => i),
                onChanged: (val) {
                  if (val != null) {
                    config.busLsbPin = val;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) {
                  String alias = state.digitalChannel.pinNames[item] ?? '';
                  return alias.isNotEmpty ? '$alias (D$item)' : 'D$item';
                },
                itemColorBuilder: (item) => _getPinColor(item),
                compact: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('大小端 (Endian):', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(width: 12),
            ChoiceChip(
              label: const Text('小端 (Little)'),
              selected: !config.isBigEndian,
              onSelected: (val) {
                if (val) { config.isBigEndian = false; state.setDigitalTrigger(config); }
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('大端 (Big)'),
              selected: config.isBigEndian,
              onSelected: (val) {
                if (val) { config.isBigEndian = true; state.setDigitalTrigger(config); }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('触发模式 (Mode):', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(width: 12),
            ChoiceChip(
              label: const Text('单一数值 (Value)'),
              selected: !config.isBusSequence,
              onSelected: (val) {
                if (val) { config.isBusSequence = false; state.setDigitalTrigger(config); }
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('序列匹配 (Sequence)'),
              selected: config.isBusSequence,
              onSelected: (val) {
                if (val) { config.isBusSequence = true; state.setDigitalTrigger(config); }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildTargetValueInput(state, config),
        
        if (config.isBusSequence) ...[
          const SizedBox(height: 12),
          _buildSequenceDelayInput(state, config),
        ],
      ],
    );
  }

  int _parseHexDec(String text, int defaultValue) {
    String t = text.trim();
    if (t.isEmpty) return defaultValue;
    try {
      if (t.toLowerCase().startsWith('0x')) {
        return int.parse(t.substring(2), radix: 16);
      } else if (t.toLowerCase().startsWith('0b')) {
        return int.parse(t.substring(2), radix: 2);
      } else {
        return int.parse(t);
      }
    } catch (_) {
      return defaultValue;
    }
  }

  List<int> _parseBytes(String text) {
    List<int> bytes = [];
    List<String> parts = text.trim().split(RegExp(r'[\s,]+'));
    for (String part in parts) {
      if (part.isEmpty) continue;
      try {
        if (part.toLowerCase().startsWith('0x')) {
          bytes.add(int.parse(part.substring(2), radix: 16));
        } else if (part.toLowerCase().startsWith('0b')) {
          bytes.add(int.parse(part.substring(2), radix: 2));
        } else {
          bytes.add(int.parse(part));
        }
      } catch (_) {}
    }
    return bytes;
  }

  Widget _buildTextInputRow({
    required String cnLabel,
    required String enLabel,
    required TextEditingController controller,
    required String hintText,
    required void Function(String) onSubmitted,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: cnLabel),
              TextSpan(text: ' ($enLabel)', style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(width: 16),
        Container(
          width: 200,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade700),
          ),
          child: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: hintText,
              hintStyle: const TextStyle(color: Colors.white30),
              contentPadding: const EdgeInsets.only(bottom: 14),
            ),
            onSubmitted: onSubmitted,
            onTapOutside: (_) => onSubmitted(controller.text),
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedBusTab(OscilloscopeState state, DigitalTriggerConfig config) {
    List<String> advBusTypes = ['I2C', 'SPI', 'UART'];
    if (config.advancedProtocolType == null || !advBusTypes.contains(config.advancedProtocolType)) {
      config.advancedProtocolType = advBusTypes.first;
    }
    
    return SizedBox(
      height: 220,
      child: SingleChildScrollView(
        child: Column(
          children: [
            _buildDropdownRow<String>(
              cnLabel: '总线协议',
              enLabel: 'Protocol',
              value: config.advancedProtocolType!,
              items: advBusTypes,
              onChanged: (val) {
                if (val != null) {
                  config.advancedProtocolType = val;
                  state.setDigitalTrigger(config);
                }
              },
              itemBuilder: (item) => item,
            ),
            const SizedBox(height: 12),
            if (config.advancedProtocolType == 'I2C') ...[
              _buildDropdownRow<int>(
                cnLabel: 'SCL引脚',
                enLabel: 'SCL Pin',
                value: config.i2cSclPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.i2cSclPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<int>(
                cnLabel: 'SDA引脚',
                enLabel: 'SDA Pin',
                value: config.i2cSdaPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.i2cSdaPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '触发条件',
                enLabel: 'Condition',
                value: config.i2cCondition,
                items: const ['Start', 'Stop', 'Restart', 'Nack', 'Address', 'Data', 'AddrData'],
                onChanged: (v) {
                  if (v != null) {
                    config.i2cCondition = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              if (['Address', 'AddrData'].contains(config.i2cCondition)) ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '设备地址',
                  enLabel: 'Address',
                  controller: _i2cAddressController,
                  hintText: '如: 0x50',
                  onSubmitted: (v) {
                    config.i2cAddress = _parseHexDec(v, 0x50);
                    state.setDigitalTrigger(config);
                  },
                ),
                const SizedBox(height: 8),
                _buildDropdownRow<String>(
                  cnLabel: '地址位数',
                  enLabel: 'Addr Mode',
                  value: config.i2cAddrMode,
                  items: const ['7bit', '10bit'],
                  onChanged: (v) {
                    if (v != null) {
                      config.i2cAddrMode = v;
                      state.setDigitalTrigger(config);
                    }
                  },
                  itemBuilder: (item) => item,
                ),
                const SizedBox(height: 8),
                _buildDropdownRow<String>(
                  cnLabel: '读写方向',
                  enLabel: 'Direction',
                  value: config.i2cDirection,
                  items: const ['Any', 'Read', 'Write'],
                  onChanged: (v) {
                    if (v != null) {
                      config.i2cDirection = v;
                      state.setDigitalTrigger(config);
                    }
                  },
                  itemBuilder: (item) => item,
                ),
              ],
              if (['Data', 'AddrData'].contains(config.i2cCondition)) ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '匹配数据',
                  enLabel: 'Data',
                  controller: _i2cDataController,
                  hintText: '如: 0xAA',
                  onSubmitted: (v) {
                    config.i2cData = _parseBytes(v);
                    state.setDigitalTrigger(config);
                  },
                ),
                const SizedBox(height: 8),
                _buildDropdownRow<int>(
                  cnLabel: '数据索引',
                  enLabel: 'Index',
                  value: config.i2cDataIndex,
                  items: const [-1, 0, 1, 2, 3, 4, 5, 6, 7],
                  onChanged: (v) {
                    if (v != null) {
                      config.i2cDataIndex = v;
                      state.setDigitalTrigger(config);
                    }
                  },
                  itemBuilder: (item) => item == -1 ? '任意 (Any)' : '字节 $item',
                ),
              ],
            ] else if (config.advancedProtocolType == 'SPI') ...[
              _buildDropdownRow<int>(
                cnLabel: 'CS引脚',
                enLabel: 'CS Pin',
                value: config.spiCsPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.spiCsPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<int>(
                cnLabel: 'SCK引脚',
                enLabel: 'SCK Pin',
                value: config.spiSckPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.spiSckPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<int>(
                cnLabel: 'MOSI引脚',
                enLabel: 'MOSI Pin',
                value: config.spiMosiPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.spiMosiPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<int>(
                cnLabel: 'MISO引脚',
                enLabel: 'MISO Pin',
                value: config.spiMisoPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.spiMisoPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<bool>(
                cnLabel: 'CS极性',
                enLabel: 'CS Polar',
                value: config.spiCsActiveLow,
                items: const [true, false],
                onChanged: (v) {
                  if (v != null) {
                    config.spiCsActiveLow = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item ? '低有效 (Low)' : '高有效 (High)',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '时钟采样边沿',
                enLabel: 'SCK Edge',
                value: config.spiClockEdge,
                items: const ['Rising', 'Falling'],
                onChanged: (v) {
                  if (v != null) {
                    config.spiClockEdge = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item == 'Rising' ? '上升沿 (Rising)' : '下降沿 (Falling)',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '触发条件',
                enLabel: 'Condition',
                value: config.spiCondition,
                items: const ['CsActive', 'CsInactive', 'MosiData', 'MisoData', 'BothData'],
                onChanged: (v) {
                  if (v != null) {
                    config.spiCondition = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              if (['MosiData', 'BothData'].contains(config.spiCondition)) ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: 'MOSI匹配值',
                  enLabel: 'MOSI Data',
                  controller: _spiMosiDataController,
                  hintText: '如: 0x9F 0x00',
                  onSubmitted: (v) {
                    config.spiMosiData = _parseBytes(v);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
              if (['MisoData', 'BothData'].contains(config.spiCondition)) ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: 'MISO匹配值',
                  enLabel: 'MISO Data',
                  controller: _spiMisoDataController,
                  hintText: '如: 0x00 0xAA',
                  onSubmitted: (v) {
                    config.spiMisoData = _parseBytes(v);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
            ] else if (config.advancedProtocolType == 'UART') ...[
              _buildDropdownRow<int>(
                cnLabel: 'RX引脚',
                enLabel: 'RX Pin',
                value: config.uartRxPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.uartRxPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<int>(
                cnLabel: 'TX引脚',
                enLabel: 'TX Pin',
                value: config.uartTxPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.uartTxPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildTextInputRow(
                cnLabel: '波特率',
                enLabel: 'Baud Rate',
                controller: _uartBaudController,
                hintText: '115200',
                onSubmitted: (v) {
                  config.uartBaudRate = _parseHexDec(v, 115200);
                  state.setDigitalTrigger(config);
                },
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<int>(
                cnLabel: '数据位数',
                enLabel: 'Data Bits',
                value: config.uartDataBits,
                items: const [5, 6, 7, 8, 9],
                onChanged: (v) {
                  if (v != null) {
                    config.uartDataBits = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => '$item bit',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '奇偶校验',
                enLabel: 'Parity',
                value: config.uartParity,
                items: const ['None', 'Odd', 'Even'],
                onChanged: (v) {
                  if (v != null) {
                    config.uartParity = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '触发条件',
                enLabel: 'Condition',
                value: config.uartCondition,
                items: const ['StartBit', 'StopBit', 'Data', 'Sequence', 'ParityError'],
                onChanged: (v) {
                  if (v != null) {
                    config.uartCondition = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              if (['Data', 'Sequence'].contains(config.uartCondition)) ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '匹配数据',
                  enLabel: 'UART Data',
                  controller: _uartDataController,
                  hintText: '如: 0x55 0xAA',
                  onSubmitted: (v) {
                    config.uartData = _parseBytes(v);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolTab(OscilloscopeState state, DigitalTriggerConfig config) {
    List<String> protocolTypes = ['CAN', 'LIN', 'USB'];
    if (config.protocolTriggerType == null || !protocolTypes.contains(config.protocolTriggerType)) {
      config.protocolTriggerType = protocolTypes.first;
    }

    return SizedBox(
      height: 220,
      child: SingleChildScrollView(
        child: Column(
          children: [
            _buildDropdownRow<String>(
              cnLabel: '特定协议',
              enLabel: 'Target Protocol',
              value: config.protocolTriggerType!,
              items: protocolTypes,
              onChanged: (val) {
                if (val != null) {
                  config.protocolTriggerType = val;
                  state.setDigitalTrigger(config);
                }
              },
              itemBuilder: (item) => item,
            ),
            const SizedBox(height: 12),
            if (config.protocolTriggerType == 'CAN') ...[
              _buildDropdownRow<int>(
                cnLabel: 'CAN信号引脚',
                enLabel: 'CAN Pin',
                value: config.canPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.canPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildTextInputRow(
                cnLabel: '波特率',
                enLabel: 'Baud Rate',
                controller: _canBaudController,
                hintText: '250000',
                onSubmitted: (v) {
                  config.canBaudRate = _parseHexDec(v, 250000);
                  state.setDigitalTrigger(config);
                },
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '触发条件',
                enLabel: 'Condition',
                value: config.canCondition,
                items: const ['SOF', 'ID', 'Data', 'Type', 'EOF', 'Error'],
                onChanged: (v) {
                  if (v != null) {
                    config.canCondition = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              if (config.canCondition == 'ID') ...[
                const SizedBox(height: 8),
                _buildDropdownRow<String>(
                  cnLabel: '运算符',
                  enLabel: 'Operator',
                  value: config.canIdOperator,
                  items: const ['=', '!=', '>', '<'],
                  onChanged: (v) {
                    if (v != null) {
                      config.canIdOperator = v;
                      state.setDigitalTrigger(config);
                    }
                  },
                  itemBuilder: (item) => item,
                ),
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '匹配帧ID',
                  enLabel: 'Frame ID',
                  controller: _canIdController,
                  hintText: '如: 0x100',
                  onSubmitted: (v) {
                    config.canId = _parseHexDec(v, 0x100);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
              if (config.canCondition == 'Type') ...[
                const SizedBox(height: 8),
                _buildDropdownRow<String>(
                  cnLabel: '帧类型',
                  enLabel: 'Frame Type',
                  value: config.canFrameType,
                  items: const ['Data', 'Remote', 'Error', 'Overload'],
                  onChanged: (v) {
                    if (v != null) {
                      config.canFrameType = v;
                      state.setDigitalTrigger(config);
                    }
                  },
                  itemBuilder: (item) => item,
                ),
              ],
              if (config.canCondition == 'Data') ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '匹配数据',
                  enLabel: 'CAN Data',
                  controller: _canDataController,
                  hintText: '如: 0x11 0x22',
                  onSubmitted: (v) {
                    config.canData = _parseBytes(v);
                    state.setDigitalTrigger(config);
                  },
                ),
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '数据偏移',
                  enLabel: 'Offset',
                  controller: _canDataOffsetController,
                  hintText: '0',
                  onSubmitted: (v) {
                    config.canDataOffset = _parseHexDec(v, 0);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
            ] else if (config.protocolTriggerType == 'LIN') ...[
              _buildDropdownRow<int>(
                cnLabel: 'LIN信号引脚',
                enLabel: 'LIN Pin',
                value: config.linPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.linPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildTextInputRow(
                cnLabel: '波特率',
                enLabel: 'Baud Rate',
                controller: _linBaudController,
                hintText: '19200',
                onSubmitted: (v) {
                  config.linBaudRate = _parseHexDec(v, 19200);
                  state.setDigitalTrigger(config);
                },
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '触发条件',
                enLabel: 'Condition',
                value: config.linCondition,
                items: const ['Sync', 'ID', 'Data', 'ChecksumError'],
                onChanged: (v) {
                  if (v != null) {
                    config.linCondition = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              if (config.linCondition == 'ID') ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '帧ID',
                  enLabel: 'Frame ID',
                  controller: _linIdController,
                  hintText: '如: 0x3C',
                  onSubmitted: (v) {
                    config.linId = _parseHexDec(v, 0x3C);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
              if (config.linCondition == 'Data') ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '匹配数据',
                  enLabel: 'LIN Data',
                  controller: _linDataController,
                  hintText: '如: 0x01 0x02',
                  onSubmitted: (v) {
                    config.linData = _parseBytes(v);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
            ] else if (config.protocolTriggerType == 'USB') ...[
              _buildDropdownRow<int>(
                cnLabel: 'D+引脚',
                enLabel: 'D+ Pin',
                value: config.usbDpPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.usbDpPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<int>(
                cnLabel: 'D-引脚',
                enLabel: 'D- Pin',
                value: config.usbDnPin,
                items: List.generate(32, (i) => i),
                onChanged: (v) {
                  if (v != null) {
                    config.usbDnPin = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => 'D$item',
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '传输速度',
                enLabel: 'USB Speed',
                value: config.usbSpeed,
                items: const ['LowSpeed', 'FullSpeed'],
                onChanged: (v) {
                  if (v != null) {
                    config.usbSpeed = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              const SizedBox(height: 8),
              _buildDropdownRow<String>(
                cnLabel: '触发条件',
                enLabel: 'Condition',
                value: config.usbCondition,
                items: const ['SOP', 'EOP', 'Reset', 'PID', 'Token', 'Data'],
                onChanged: (v) {
                  if (v != null) {
                    config.usbCondition = v;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) => item,
              ),
              if (config.usbCondition == 'PID') ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: 'PID值',
                  enLabel: 'PID Value',
                  controller: _usbPidController,
                  hintText: '如: 0x2D',
                  onSubmitted: (v) {
                    config.usbPid = _parseHexDec(v, 0x2D);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
              if (config.usbCondition == 'Token') ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '设备地址',
                  enLabel: 'USB Addr',
                  controller: _usbAddrController,
                  hintText: '1',
                  onSubmitted: (v) {
                    config.usbAddr = _parseHexDec(v, 1);
                    state.setDigitalTrigger(config);
                  },
                ),
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '端点',
                  enLabel: 'Endpoint',
                  controller: _usbEpController,
                  hintText: '0',
                  onSubmitted: (v) {
                    config.usbEp = _parseHexDec(v, 0);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
              if (config.usbCondition == 'Data') ...[
                const SizedBox(height: 8),
                _buildTextInputRow(
                  cnLabel: '匹配数据',
                  enLabel: 'USB Data',
                  controller: _usbDataController,
                  hintText: '如: 0xAA 0xBB',
                  onSubmitted: (v) {
                    config.usbData = _parseBytes(v);
                    state.setDigitalTrigger(config);
                  },
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
  Widget _buildDropdownRow<T>({
    required String cnLabel,
    required String enLabel,
    required T value,
    required List<T> items,
    required void Function(T?) onChanged,
    required String Function(T) itemBuilder,
    Color? Function(T)? itemColorBuilder,
    Widget Function(T)? customItemWidgetBuilder,
    bool compact = false,
  }) {
    return Row(
      mainAxisAlignment: compact ? MainAxisAlignment.start : MainAxisAlignment.spaceBetween,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: cnLabel),
              TextSpan(text: ' ($enLabel)', style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        if (compact) const SizedBox(width: 8),
        if (compact)
          Expanded(
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<T>(
                  isExpanded: compact,
                  value: items.contains(value) ? value : (items.isNotEmpty ? items.first : null),
                  dropdownColor: const Color(0xFF2A2A2A),
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: onChanged,
                  items: items.map((item) {
                    Color? itemColor = itemColorBuilder != null ? itemColorBuilder(item) : null;
                    Widget childWidget = customItemWidgetBuilder != null
                        ? customItemWidgetBuilder(item)
                        : Text(itemBuilder(item), overflow: TextOverflow.ellipsis);
                        
                    return DropdownMenuItem<T>(
                      value: item,
                      child: itemColor != null
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              color: itemColor,
                              child: childWidget,
                            )
                          : childWidget,
                    );
                  }).toList(),
                ),
              ),
            ),
          )
        else
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                isExpanded: compact,
                value: items.contains(value) ? value : (items.isNotEmpty ? items.first : null),
                dropdownColor: const Color(0xFF2A2A2A),
                icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                onChanged: onChanged,
                items: items.map((item) {
                  Color? itemColor = itemColorBuilder != null ? itemColorBuilder(item) : null;
                  Widget childWidget = customItemWidgetBuilder != null
                      ? customItemWidgetBuilder(item)
                      : Text(itemBuilder(item), overflow: TextOverflow.ellipsis);
                      
                  return DropdownMenuItem<T>(
                    value: item,
                    child: itemColor != null
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            color: itemColor,
                            child: childWidget,
                          )
                        : childWidget,
                  );
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTargetValueInput(OscilloscopeState state, DigitalTriggerConfig config) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text.rich(
          const TextSpan(
            children: [
              TextSpan(text: '目标值'),
              TextSpan(text: ' (Target)', style: TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: TextField(
              controller: _targetValueController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: '例: 0x55 或 0xAA 0xBB',
                hintStyle: TextStyle(color: Colors.white30),
                contentPadding: EdgeInsets.only(bottom: 14),
              ),
              onSubmitted: (val) => _applyTargetValue(state, config, val),
              onTapOutside: (_) => _applyTargetValue(state, config, _targetValueController.text),
            ),
          ),
        ),
      ],
    );
  }

  void _applyTargetValue(OscilloscopeState state, DigitalTriggerConfig config, String text) {
    if (text.trim().isEmpty) return;
    
    List<int> values = [];
    List<String> parts = text.trim().split(RegExp(r'\s+'));
    for (String part in parts) {
      try {
        if (part.toLowerCase().startsWith('0x')) {
          values.add(int.parse(part.substring(2), radix: 16));
        } else if (part.toLowerCase().startsWith('0b')) {
          values.add(int.parse(part.substring(2), radix: 2));
        } else {
          values.add(int.parse(part));
        }
      } catch (_) {
        // Ignore invalid parts
      }
    }
    
    if (values.isNotEmpty) {
      config.targetValues = values;
      state.setDigitalTrigger(config);
    }
  }
  
  Widget _buildSequenceDelayInput(OscilloscopeState state, DigitalTriggerConfig config) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text.rich(
          const TextSpan(
            children: [
              TextSpan(text: '容限延时'),
              TextSpan(text: ' (Delays)', style: TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: TextField(
              controller: _delaysController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: '例: 10 20 (各值之间的点数上限)',
                hintStyle: TextStyle(color: Colors.white30),
                contentPadding: EdgeInsets.only(bottom: 14),
              ),
              onSubmitted: (val) => _applyDelays(state, config, val),
              onTapOutside: (_) => _applyDelays(state, config, _delaysController.text),
            ),
          ),
        ),
      ],
    );
  }
  
  void _applyDelays(OscilloscopeState state, DigitalTriggerConfig config, String text) {
    if (text.trim().isEmpty) return;
    
    List<int> delays = [];
    List<String> parts = text.trim().split(RegExp(r'\s+'));
    for (String part in parts) {
      try {
        delays.add(int.parse(part));
      } catch (_) {
        // Ignore invalid
      }
    }
    
    config.sequenceDelays = delays;
    state.setDigitalTrigger(config);
  }

  String _formatMemoryDepth(int depth) {
    if (depth >= 1048576) {
      return '${(depth / 1048576).toStringAsFixed(1)} Mpts';
    } else if (depth >= 1024) {
      return '${(depth / 1024).toStringAsFixed(1)} kpts';
    } else {
      return '$depth pts';
    }
  }
}

class EdgeIconPainter extends CustomPainter {
  final TriggerEdge edge;
  final Color color;
  EdgeIconPainter(this.edge, {this.color = Colors.cyanAccent});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    double midY = size.height / 2;
    
    if (edge == TriggerEdge.rising) {
      path.moveTo(2, size.height - 2);
      path.lineTo(size.width / 2, size.height - 2);
      path.lineTo(size.width / 2, 2);
      path.lineTo(size.width - 2, 2);
      
      // arrow head at middle of vertical line (pointing up)
      path.moveTo(size.width / 2 - 3, midY + 2);
      path.lineTo(size.width / 2, midY - 2);
      path.lineTo(size.width / 2 + 3, midY + 2);
    } else if (edge == TriggerEdge.falling) {
      path.moveTo(2, 2);
      path.lineTo(size.width / 2, 2);
      path.lineTo(size.width / 2, size.height - 2);
      path.lineTo(size.width - 2, size.height - 2);
      
      // arrow head at middle of vertical line (pointing down)
      path.moveTo(size.width / 2 - 3, midY - 2);
      path.lineTo(size.width / 2, midY + 2);
      path.lineTo(size.width / 2 + 3, midY - 2);
    } else { // both
      path.moveTo(2, size.height - 2);
      path.lineTo(size.width * 0.35, size.height - 2);
      path.lineTo(size.width * 0.35, 2);
      path.lineTo(size.width * 0.65, 2);
      path.lineTo(size.width * 0.65, size.height - 2);
      path.lineTo(size.width - 2, size.height - 2);
      
      // arrow up
      path.moveTo(size.width * 0.35 - 3, midY + 2);
      path.lineTo(size.width * 0.35, midY - 2);
      path.lineTo(size.width * 0.35 + 3, midY + 2);
      
      // arrow down
      path.moveTo(size.width * 0.65 - 3, midY - 2);
      path.lineTo(size.width * 0.65, midY + 2);
      path.lineTo(size.width * 0.65 + 3, midY - 2);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant EdgeIconPainter oldDelegate) => oldDelegate.edge != edge;
}
