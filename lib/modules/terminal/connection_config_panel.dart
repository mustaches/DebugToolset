import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import '../../providers/terminal_state.dart';

class ConnectionConfigPanel extends StatelessWidget {
  const ConnectionConfigPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final terminalState = context.watch<TerminalState>();

    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Mode Selector
          ToggleButtons(
            isSelected: [
              terminalState.connectionMode == ConnectionMode.serial,
              terminalState.connectionMode == ConnectionMode.network,
            ],
            onPressed: (index) {
              if (terminalState.isConnected) return; // Cannot change mode while connected
              terminalState.setConnectionMode(
                index == 0 ? ConnectionMode.serial : ConnectionMode.network,
              );
            },
            borderRadius: BorderRadius.circular(4),
            constraints: const BoxConstraints(minHeight: 32, minWidth: 60),
            children: const [
              Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('串口')),
              Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('网口')),
            ],
          ),
          const SizedBox(width: 16),
          
          // Config Fields based on mode
          Expanded(
            child: terminalState.connectionMode == ConnectionMode.serial
                ? _buildSerialConfig(context, terminalState)
                : _buildNetworkConfig(context, terminalState),
          ),
          
          const SizedBox(width: 8),
          
          // Timestamp Checkbox
          Row(
            children: [
              Checkbox(
                value: terminalState.showTimestamp,
                onChanged: (val) {
                  if (val != null) terminalState.toggleShowTimestamp(val);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const Text('显示时间戳', style: TextStyle(fontSize: 12)),
            ],
          ),
          
          const SizedBox(width: 16),
          
          // Connect Button
          IconButton.filled(
            onPressed: () {
              terminalState.toggleConnection();
            },
            icon: Icon(terminalState.isConnected ? Icons.link_off : Icons.link, size: 20),
            tooltip: terminalState.isConnected ? '断开' : '连接',
            style: IconButton.styleFrom(
              backgroundColor: terminalState.isConnected ? Colors.red.shade700 : Colors.green.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSerialConfig(BuildContext context, TerminalState state) {
    const double inputHeight = 28.0;

    Widget buildBox({required double width, required Widget child}) {
      return Container(
        width: width,
        height: inputHeight,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade600),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: child,
      );
    }

    Widget buildDropdown<T>(T value, List<T> items, ValueChanged<T?> onChanged, bool enabled) {
      return DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          iconSize: 16,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          items: items.map((e) => DropdownMenuItem(value: e, child: Text(e.toString(), style: const TextStyle(fontSize: 13)))).toList(),
          onChanged: enabled ? onChanged : null,
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('端口: ', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          buildBox(
            width: 100, // 增加了一点宽度以容纳下拉箭头
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    enabled: !state.isConnected,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      border: InputBorder.none,
                    ),
                    controller: TextEditingController(text: state.serialPort)..selection = TextSelection.collapsed(offset: state.serialPort.length),
                    onChanged: (val) => state.updateSerialConfig(val, state.baudRate),
                    style: const TextStyle(fontSize: 13),
                    textAlignVertical: TextAlignVertical.center,
                  ),
                ),
                SizedBox(
                  width: 24,
                  child: PopupMenuButton<String>(
                    enabled: !state.isConnected,
                    icon: const Icon(Icons.arrow_drop_down, size: 16),
                    padding: EdgeInsets.zero,
                    itemBuilder: (context) {
                      List<String> ports = [];
                      try {
                        ports = SerialPort.availablePorts;
                      } catch (e) {
                        // ignore error if serial port query fails
                      }
                      if (ports.isEmpty) {
                        return [const PopupMenuItem(value: '', enabled: false, child: Text('无可用端口', style: TextStyle(fontSize: 13)))];
                      }
                      return ports.map((p) => PopupMenuItem(value: p, child: Text(p, style: const TextStyle(fontSize: 13)))).toList();
                    },
                    onSelected: (val) {
                      if (val.isNotEmpty) state.updateSerialConfig(val, state.baudRate);
                    },
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(width: 12),
          const Text('波特率: ', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          buildBox(
            width: 110,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    enabled: !state.isConnected,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      border: InputBorder.none,
                    ),
                    controller: TextEditingController(text: state.baudRate.toString())..selection = TextSelection.collapsed(offset: state.baudRate.toString().length),
                    onChanged: (val) {
                      int? parsed = int.tryParse(val);
                      if (parsed != null) state.updateSerialConfig(state.serialPort, parsed);
                    },
                    style: const TextStyle(fontSize: 13),
                    textAlignVertical: TextAlignVertical.center,
                  ),
                ),
                SizedBox(
                  width: 24,
                  child: PopupMenuButton<int>(
                    enabled: !state.isConnected,
                    icon: const Icon(Icons.arrow_drop_down, size: 16),
                    padding: EdgeInsets.zero,
                    itemBuilder: (context) => [9600, 19200, 38400, 57600, 115200, 921600]
                        .map((e) => PopupMenuItem(value: e, child: Text(e.toString(), style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onSelected: (val) {
                      state.updateSerialConfig(state.serialPort, val);
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),
          const Text('数据位: ', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          buildBox(
            width: 50,
            child: buildDropdown<int>(
              state.dataBits,
              [5, 6, 7, 8],
              (val) {
                if (val != null) state.updateSerialAdvancedConfig(val, state.stopBits, state.parity);
              },
              !state.isConnected,
            ),
          ),

          const SizedBox(width: 12),
          const Text('校验: ', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          buildBox(
            width: 75,
            child: buildDropdown<String>(
              state.parity,
              ['None', 'Odd', 'Even', 'Mark', 'Space'],
              (val) {
                if (val != null) state.updateSerialAdvancedConfig(state.dataBits, state.stopBits, val);
              },
              !state.isConnected,
            ),
          ),

          const SizedBox(width: 12),
          const Text('停止位: ', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          buildBox(
            width: 60,
            child: buildDropdown<double>(
              state.stopBits,
              [1.0, 1.5, 2.0],
              (val) {
                if (val != null) state.updateSerialAdvancedConfig(state.dataBits, val, state.parity);
              },
              !state.isConnected,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkConfig(BuildContext context, TerminalState state) {
    return Row(
      children: [
        const Text('IP: ', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
        SizedBox(
          width: 140,
          child: TextField(
            enabled: !state.isConnected,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.all(8), border: OutlineInputBorder()),
            controller: TextEditingController(text: state.networkIp),
            onChanged: (val) => state.updateNetworkConfig(val, state.networkPort),
          ),
        ),
        const SizedBox(width: 16),
        const Text('Port: ', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: TextField(
            enabled: !state.isConnected,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.all(8), border: OutlineInputBorder()),
            controller: TextEditingController(text: state.networkPort.toString()),
            onChanged: (val) {
              int? p = int.tryParse(val);
              if (p != null) state.updateNetworkConfig(state.networkIp, p);
            },
          ),
        ),
      ],
    );
  }
}
