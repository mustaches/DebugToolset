import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/network_terminal_state.dart';

class NetworkConfigPanel extends StatelessWidget {
  const NetworkConfigPanel({super.key});

  // 与串口终端配置框一致的样式：28 高、灰色细边框、圆角 4、无下划线
  Widget _buildBox({required double width, required Widget child}) {
    return Container(
      width: width,
      height: 28,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade600),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      // 与串口面板一致：stretch 让输入框撑满盒高，配合 textAlignVertical 居中
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: child)],
      ),
    );
  }

  InputDecoration _boxDecoration() {
    return const InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 8),
      border: InputBorder.none,
    );
  }

  @override
  Widget build(BuildContext context) {
    final networkState = context.watch<NetworkTerminalState>();
    final isSsh = networkState.protocol == NetworkProtocol.ssh;

    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Protocol Selector（Theme 覆盖 shrinkWrap：去掉 padded 触控区带来的 48px 最小布局高度）
          Theme(
            data: Theme.of(context).copyWith(
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: ToggleButtons(
              isSelected: [
                networkState.protocol == NetworkProtocol.tcp,
                isSsh,
              ],
              onPressed: (index) {
                networkState.setProtocol(
                  index == 0 ? NetworkProtocol.tcp : NetworkProtocol.ssh,
                );
              },
              borderRadius: BorderRadius.circular(4),
              // minHeight 不含上下各 1px 边框，26 + 2 = 28，与配置输入框同高
              constraints: const BoxConstraints(minHeight: 26, minWidth: 60),
              children: const [
                Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('TCP')),
                Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('SSH')),
              ],
            ),
          ),
          const SizedBox(width: 16),

          // Config Fields
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('主机: ', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 4),
                  _buildBox(
                    width: 140,
                    child: TextField(
                      enabled: !networkState.isConnected,
                      decoration: _boxDecoration(),
                      controller: TextEditingController(text: networkState.host)
                        ..selection = TextSelection.collapsed(offset: networkState.host.length),
                      onChanged: (val) => networkState.updateNetworkConfig(val, networkState.port),
                      style: const TextStyle(fontSize: 13),
                      textAlignVertical: TextAlignVertical.center,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text('端口: ', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 4),
                  _buildBox(
                    width: 70,
                    child: TextField(
                      enabled: !networkState.isConnected,
                      decoration: _boxDecoration(),
                      controller: TextEditingController(text: networkState.port.toString())
                        ..selection = TextSelection.collapsed(offset: networkState.port.toString().length),
                      onChanged: (val) {
                        int? p = int.tryParse(val);
                        if (p != null) networkState.updateNetworkConfig(networkState.host, p);
                      },
                      style: const TextStyle(fontSize: 13),
                      textAlignVertical: TextAlignVertical.center,
                    ),
                  ),
                  if (isSsh) ...[
                    const SizedBox(width: 12),
                    const Text('用户名: ', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 4),
                    _buildBox(
                      width: 100,
                      child: TextField(
                        enabled: !networkState.isConnected,
                        decoration: _boxDecoration(),
                        controller: TextEditingController(text: networkState.username)
                          ..selection = TextSelection.collapsed(offset: networkState.username.length),
                        onChanged: (val) => networkState.updateAuthConfig(val, networkState.password),
                        style: const TextStyle(fontSize: 13),
                        textAlignVertical: TextAlignVertical.center,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text('密码: ', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 4),
                    _buildBox(
                      width: 100,
                      child: TextField(
                        enabled: !networkState.isConnected,
                        obscureText: true,
                        decoration: _boxDecoration(),
                        controller: TextEditingController(text: networkState.password)
                          ..selection = TextSelection.collapsed(offset: networkState.password.length),
                        onChanged: (val) => networkState.updateAuthConfig(networkState.username, val),
                        style: const TextStyle(fontSize: 13),
                        textAlignVertical: TextAlignVertical.center,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Connect Button（与配置输入框同高，紧贴其右侧）
          IconButton.filled(
            onPressed: () {
              networkState.toggleConnection();
            },
            icon: Icon(networkState.isConnected ? Icons.link_off : Icons.link, size: 16),
            tooltip: networkState.isConnected ? '断开' : '连接',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            style: IconButton.styleFrom(
              backgroundColor: networkState.isConnected ? Colors.red.shade700 : Colors.green.shade700,
              foregroundColor: Colors.white,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],
      ),
    );
  }
}
