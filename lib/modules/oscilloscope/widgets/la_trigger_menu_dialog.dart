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

  @override
  void dispose() {
    _targetValueController.dispose();
    _delaysController.dispose();
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
                          if (val < 5) val = 5;
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
                          value: config.triggerPositionPercentage,
                          min: 5,
                          max: 95,
                          divisions: 90,
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
                          if (val > 95) val = 95;
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
                          value: state.sampleRate,
                          dropdownColor: const Color(0xFF2A2A2A),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          onChanged: (val) {
                            if (val != null) state.setSampleRate(val);
                          },
                          items: const [1000.0, 10000.0, 100000.0, 500000.0, 1000000.0, 2000000.0, 5000000.0, 10000000.0, 20000000.0, 50000000.0, 100000000.0, 200000000.0, 500000000.0]
                              .map((e) => DropdownMenuItem(value: e, child: Text(_formatSampleRate(e))))
                              .toList(),
                        ),
                      ),
                    ),
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
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: state.memoryDepth,
                          dropdownColor: const Color(0xFF2A2A2A),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          onChanged: (val) {
                            if (val != null) state.setMemoryDepth(val);
                          },
                          items: const [1024, 4096, 16384, 65536, 262144, 1048576, 8388608, 16777216]
                              .map((e) => DropdownMenuItem(value: e, child: Text(_formatMemoryDepth(e))))
                              .toList(),
                        ),
                      ),
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
    return Column(
      children: [
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

  Widget _buildAdvancedBusTab(OscilloscopeState state, DigitalTriggerConfig config) {
    List<String> advBusTypes = ['I2C', 'SPI', 'UART'];
    if (config.advancedProtocolType == null || !advBusTypes.contains(config.advancedProtocolType)) {
      config.advancedProtocolType = advBusTypes.first;
    }
    
    return Column(
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
        const SizedBox(height: 16),
        const Center(
          child: Text(
            '高级总线触发解析逻辑尚未实装，敬请期待。\n(Advanced Bus logic placeholder)',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white30, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildProtocolTab(OscilloscopeState state, DigitalTriggerConfig config) {
    List<String> protocolTypes = ['CAN', 'LIN', 'USB'];
    if (config.protocolTriggerType == null || !protocolTypes.contains(config.protocolTriggerType)) {
      config.protocolTriggerType = protocolTypes.first;
    }

    return Column(
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
        const SizedBox(height: 16),
        const Center(
          child: Text(
            '协议触发解析逻辑尚未实装，敬请期待。\n(Protocol logic placeholder)',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white30, fontSize: 13),
          ),
        ),
      ],
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

  String _formatSampleRate(double rate) {
    if (rate >= 1e6) {
      return '${(rate / 1e6).toStringAsFixed(1)} MSa/s';
    } else if (rate >= 1e3) {
      return '${(rate / 1e3).toStringAsFixed(1)} kSa/s';
    } else {
      return '${rate.toStringAsFixed(0)} Sa/s';
    }
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
