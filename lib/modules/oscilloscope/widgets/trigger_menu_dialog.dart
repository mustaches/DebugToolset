import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';

class TriggerMenuDialog extends StatelessWidget {
  const TriggerMenuDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();

    return Dialog(
      backgroundColor: const Color(0xFF161616),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade800, width: 2),
      ),
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Trigger Menu',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            
            // Mode Selection
            _buildDropdownRow(
              label: 'Mode',
              value: state.triggerMode,
              items: TriggerMode.values,
              onChanged: (val) {
                if (val != null) state.setTriggerMode(val);
              },
              itemBuilder: (item) => item.toString().split('.').last.toUpperCase(),
            ),
            const SizedBox(height: 12),



            // Source Channel Selection
            _buildSourceSelector(state),
            const SizedBox(height: 12),

            // Edge/Slope Selection
            _buildDropdownRow(
              label: 'Edge',
              value: state.triggerEdge,
              items: TriggerEdge.values,
              onChanged: (val) {
                if (val != null) state.setTriggerEdge(val);
              },
              itemBuilder: (item) {
                switch(item) {
                  case TriggerEdge.rising: return 'Rising (↑)';
                  case TriggerEdge.falling: return 'Falling (↓)';
                  case TriggerEdge.both: return 'Both (↕)';
                }
              },
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
              value: value,
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

  Widget _buildSourceSelector(OscilloscopeState state) {
    List<int> indices = List.generate(4, (i) => i);

    return _buildDropdownRow(
      label: 'Source',
      value: state.triggerSourceType == TriggerSourceType.analog ? state.triggerSourceIndex : 0,
      items: indices,
      onChanged: (val) {
        if (val != null) state.setTriggerSource(TriggerSourceType.analog, val);
      },
      itemBuilder: (item) {
        return 'CH${item + 1}';
      },
    );
  }
}
