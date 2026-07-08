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

  @override
  void dispose() {
    _targetValueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();
    final isDigital = state.triggerSourceType == TriggerSourceType.digital;
    final config = state.digitalTrigger;

    // Initialize controller text if needed
    if (isDigital && _targetValueController.text.isEmpty && config.targetValues.isNotEmpty) {
      if (config.type == DigitalTriggerType.busValue) {
        _targetValueController.text = '0x${config.targetValues.first.toRadixString(16).toUpperCase()}';
      } else if (config.type == DigitalTriggerType.busSequence) {
        _targetValueController.text = config.targetValues.map((v) => '0x${v.toRadixString(16).toUpperCase()}').join(' ');
      }
    }

    return Dialog(
      backgroundColor: const Color(0xFF161616),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade800, width: 2),
      ),
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'LA Trigger Settings',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            
            _buildDropdownRow<TriggerSourceType>(
              label: 'Control',
              value: state.triggerSourceType,
              items: TriggerSourceType.values,
              onChanged: (val) {
                if (val != null) {
                  state.setTriggerSource(val, val == TriggerSourceType.analog ? state.triggerSourceIndex : 0);
                }
              },
              itemBuilder: (item) => item == TriggerSourceType.analog ? 'External (OSC)' : 'Digital Internal',
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
                  'Trigger is controlled by the Oscilloscope. Please use the OSC trigger panel to configure edge and level.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              _buildDropdownRow<DigitalTriggerType>(
                label: 'Condition',
                value: config.type,
                items: DigitalTriggerType.values,
                onChanged: (val) {
                  if (val != null) {
                    config.type = val;
                    state.setDigitalTrigger(config);
                  }
                },
                itemBuilder: (item) {
                  switch(item) {
                    case DigitalTriggerType.pinEdge: return 'Pin Edge';
                    case DigitalTriggerType.busValue: return 'Bus Value';
                    case DigitalTriggerType.busSequence: return 'Bus Sequence';
                  }
                },
              ),
              const SizedBox(height: 12),
              
              if (config.type == DigitalTriggerType.pinEdge) ...[
                _buildDropdownRow<int>(
                  label: 'Pin',
                  value: config.pinIndex,
                  items: List.generate(32, (i) => i),
                  onChanged: (val) {
                    if (val != null) {
                      config.pinIndex = val;
                      state.setDigitalTrigger(config);
                    }
                  },
                  itemBuilder: (item) => 'D$item',
                ),
                const SizedBox(height: 12),
                _buildDropdownRow<TriggerEdge>(
                  label: 'Edge',
                  value: config.edge,
                  items: TriggerEdge.values,
                  onChanged: (val) {
                    if (val != null) {
                      config.edge = val;
                      state.setDigitalTrigger(config);
                    }
                  },
                  itemBuilder: (item) {
                    switch(item) {
                      case TriggerEdge.rising: return 'Rising (↑)';
                      case TriggerEdge.falling: return 'Falling (↓)';
                      case TriggerEdge.both: return 'Both (↕)';
                    }
                  },
                ),
              ] else ...[
                _buildBusSelector(state, config),
                const SizedBox(height: 12),
                _buildTargetValueInput(state, config),
              ],
            ],
            
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFF333333),
                ),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownRow<T>({
    required String label,
    required T value,
    required List<T> items,
    required void Function(T?) onChanged,
    required String Function(T) itemBuilder,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
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
              value: items.contains(value) ? value : (items.isNotEmpty ? items.first : null),
              dropdownColor: const Color(0xFF2A2A2A),
              icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              onChanged: onChanged,
              items: items.map((item) {
                return DropdownMenuItem<T>(
                  value: item,
                  child: Text(itemBuilder(item)),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBusSelector(OscilloscopeState state, DigitalTriggerConfig config) {
    List<String> busNames = state.digitalChannel.buses.map((b) => b.name).toList();
    if (busNames.isEmpty) {
      return const Text('No buses configured. Add a bus first.', style: TextStyle(color: Colors.redAccent, fontSize: 12));
    }
    
    if (config.busName == null || !busNames.contains(config.busName)) {
      config.busName = busNames.first;
      // We don't call setDigitalTrigger here to avoid build cycle issues, it'll just use the first available.
    }

    return _buildDropdownRow<String>(
      label: 'Bus',
      value: config.busName ?? busNames.first,
      items: busNames,
      onChanged: (val) {
        if (val != null) {
          config.busName = val;
          state.setDigitalTrigger(config);
        }
      },
      itemBuilder: (item) => item,
    );
  }

  Widget _buildTargetValueInput(OscilloscopeState state, DigitalTriggerConfig config) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          'Target',
          style: TextStyle(color: Colors.white70, fontSize: 14),
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
                hintText: 'e.g. 0x55 or 0xAA 0xBB',
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
}
