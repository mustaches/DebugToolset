import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';

class LxiConnectionDialog extends StatefulWidget {
  const LxiConnectionDialog({super.key});

  @override
  State<LxiConnectionDialog> createState() => _LxiConnectionDialogState();
}

class _LxiConnectionDialogState extends State<LxiConnectionDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _scpiController = TextEditingController();
  bool _isStreaming = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    
    final state = context.read<OscilloscopeState>();
    _ipController.text = state.lxiIp;
    _portController.text = state.lxiPort.toString();
    _isStreaming = state.lxiContinuousStreaming;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _scpiController.dispose();
    super.dispose();
  }

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
        width: 800,
        height: 600,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Title row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.settings_ethernet, color: Colors.greenAccent, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'LXI CORE 2011 DEVICE 连接与控制',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(Icons.close, color: Colors.grey.shade400, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Divider(color: Colors.grey.shade800),
            
            // Tab Header
            TabBar(
              controller: _tabController,
              indicatorColor: Colors.greenAccent,
              labelColor: Colors.greenAccent,
              unselectedLabelColor: Colors.grey,
              tabs: const [
                Tab(icon: Icon(Icons.settings), text: '连接与配置 (LXI Connect)'),
                Tab(icon: Icon(Icons.terminal), text: 'SCPI 指令终端 (SCPI Console)'),
              ],
            ),
            const SizedBox(height: 12),
            
            // Tab Contents
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildConnectTab(state),
                  _buildConsoleTab(state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectTab(OscilloscopeState state) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left Column: Manual Form & Details
        Expanded(
          flex: 4,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('手动连接设备', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),

                  const Text('目标仪器型号 (LXI Device Model)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: state.lxiDeviceModel,
                        dropdownColor: const Color(0xFF222222),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(value: 'MSO8000A', child: Text('RIGOL MSO8000A')),
                          DropdownMenuItem(value: 'MSO8000', child: Text('RIGOL MSO8000')),
                          DropdownMenuItem(value: 'MSO9000', child: Text('RIGOL MSO9000')),
                          DropdownMenuItem(value: 'DS9000', child: Text('RIGOL DS9000')),
                          DropdownMenuItem(value: 'MHO5000', child: Text('RIGOL MHO5000')),
                          DropdownMenuItem(value: 'DHO5000', child: Text('RIGOL DHO5000')),
                          DropdownMenuItem(value: 'MHO900', child: Text('RIGOL MHO900')),
                          DropdownMenuItem(value: 'MHO98', child: Text('RIGOL MHO98')),
                          DropdownMenuItem(value: 'MHO2000', child: Text('RIGOL MHO2000')),
                          DropdownMenuItem(value: 'DS80000', child: Text('RIGOL DS80000')),
                          DropdownMenuItem(value: 'DS70000', child: Text('RIGOL DS70000')),
                          DropdownMenuItem(value: 'DHO1000', child: Text('RIGOL DHO1000')),
                          DropdownMenuItem(value: 'DHO4000', child: Text('RIGOL DHO4000')),
                          DropdownMenuItem(value: 'DS1000ZE', child: Text('RIGOL DS1000ZE')),
                          DropdownMenuItem(value: 'DS8000R', child: Text('RIGOL DS8000R')),
                          DropdownMenuItem(value: 'MSO7000', child: Text('RIGOL MSO7000')),
                          DropdownMenuItem(value: 'DS6000', child: Text('RIGOL DS6000')),
                          DropdownMenuItem(value: 'MSO5000', child: Text('RIGOL MSO5000')),
                          DropdownMenuItem(value: 'MSO5000E', child: Text('RIGOL MSO5000E')),
                          DropdownMenuItem(value: 'DS4000E', child: Text('RIGOL DS4000E')),
                          DropdownMenuItem(value: 'MSO4000', child: Text('RIGOL MSO4000')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            state.setLxiDeviceModel(val);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // IP Input
                  const Text('仪器 IP 地址 (Host IP)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _ipController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF1E1E1E),
                      hintText: 'e.g. 192.168.1.100',
                      hintStyle: TextStyle(color: Colors.white24),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Port Input
                  const Text('TCP 端口号 (Port)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _portController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF1E1E1E),
                      hintText: 'SCPI默认为5025',
                      hintStyle: TextStyle(color: Colors.white24),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Mode Toggle
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('连续波形数据流模式', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Text('开启后自动订阅FPGA的二进制帧', style: TextStyle(color: Colors.grey, fontSize: 10)),
                        ],
                      ),
                      Switch(
                        value: _isStreaming,
                        activeThumbColor: Colors.greenAccent,
                        activeTrackColor: Colors.greenAccent.withValues(alpha: 0.5),
                        onChanged: (val) {
                          setState(() {
                            _isStreaming = val;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: state.isLxiConnected
                              ? null
                              : () async {
                                  try {
                                    final ip = _ipController.text.trim();
                                    final port = int.tryParse(_portController.text.trim()) ?? 5025;
                                    await state.connectLxi(ip, port, streaming: _isStreaming);
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('LXI 仪器连接成功！')),
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('LXI 连接失败: $e')),
                                      );
                                    }
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.greenAccent.shade700,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade800,
                            disabledForegroundColor: Colors.white24,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          child: const Text('连接设备 (Connect)', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: !state.isLxiConnected
                              ? null
                              : () async {
                                  await state.disconnectLxi();
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('LXI 仪器已断开连接')),
                                    );
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.shade700,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade800,
                            disabledForegroundColor: Colors.white24,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          child: const Text('断开连接 (Disconnect)', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 24),
                  Divider(color: Colors.grey.shade800),
                  const SizedBox(height: 12),

                  // Connection info details
                  const Text('仪器 LXI 识别状态', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade800),
                    ),
                    child: Text(
                      state.lxiInstrumentInfo,
                      style: TextStyle(
                        color: state.isLxiConnected ? Colors.greenAccent : Colors.amberAccent,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        
        VerticalDivider(color: Colors.grey.shade800, width: 1),
        
        // Right Column: mDNS Auto Discovery
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.only(left: 12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('LXI 自动搜索 (mDNS)', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: state.isSearchingLxi
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.greenAccent))
                          : const Icon(Icons.refresh, color: Colors.greenAccent, size: 20),
                      onPressed: state.isSearchingLxi
                          ? null
                          : () => state.startLxiDiscovery(),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text('搜索局域网中的 _lxi._tcp 服务设备', style: TextStyle(color: Colors.grey, fontSize: 11)),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade800),
                    ),
                    child: state.discoveredLxiDevices.isEmpty
                        ? Center(
                            child: Text(
                              state.isSearchingLxi ? '正在扫描局域网设备...' : '无已发现设备\n点击刷新进行搜索',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          )
                        : ListView.builder(
                            itemCount: state.discoveredLxiDevices.length,
                            itemBuilder: (context, index) {
                              final dev = state.discoveredLxiDevices[index];
                              return ListTile(
                                leading: const Icon(Icons.devices, color: Colors.greenAccent, size: 20),
                                title: Text(dev.ip, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                                subtitle: Text(dev.name, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                trailing: const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.grey),
                                onTap: () {
                                  setState(() {
                                    _ipController.text = dev.ip;
                                  });
                                  _tabController.animateTo(0);
                                },
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConsoleTab(OscilloscopeState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // SCPI Console log output
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF101010),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade800),
            ),
            padding: const EdgeInsets.all(12),
            child: state.scpiConsoleLogs.isEmpty
                ? const Center(
                    child: Text(
                      'SCPI 命令行日志为空\n在下方输入并发送 SCPI 指令',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: state.scpiConsoleLogs.length,
                    itemBuilder: (context, index) {
                      // Reverse layout to show latest at bottom/top depending on taste, standard terminal shows oldest at top, latest at bottom
                      // Here we display newest at bottom, so reverse indexing:
                      final logIdx = state.scpiConsoleLogs.length - 1 - index;
                      final log = state.scpiConsoleLogs[logIdx];
                      
                      Color logColor = Colors.white70;
                      if (log.contains('->')) {
                        logColor = Colors.greenAccent;
                      } else if (log.contains('<-')) {
                        logColor = Colors.cyanAccent;
                      } else if (log.contains('Error')) {
                        logColor = Colors.redAccent;
                      }
                      
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: Text(
                          log,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: logColor,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 12),
        
        // Quick Macro Keys
        Wrap(
          spacing: 8.0,
          runSpacing: 4.0,
          children: [
            _buildMacroBtn(state, '*IDN?', '标识识别'),
            _buildMacroBtn(state, '*RST', '系统复位'),
            _buildMacroBtn(state, ':RUN', '启动采集'),
            _buildMacroBtn(state, ':STOP', '停止采集'),
            _buildMacroBtn(state, ':SINGLE', '单次触发'),
            _buildMacroBtn(state, ':WAV:DATA?', '获取波形数据'),
          ],
        ),
        const SizedBox(height: 12),

        // Input row
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _scpiController,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF1E1E1E),
                  hintText: '输入 SCPI 指令 (如 *IDN?)...',
                  hintStyle: TextStyle(color: Colors.white24, fontSize: 12),
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                onSubmitted: (val) {
                  if (val.trim().isNotEmpty) {
                    state.sendScpiCommand(val.trim());
                    _scpiController.clear();
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                final val = _scpiController.text.trim();
                if (val.isNotEmpty) {
                  state.sendScpiCommand(val);
                  _scpiController.clear();
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              ),
              child: const Icon(Icons.send, size: 18),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMacroBtn(OscilloscopeState state, String cmd, String tooltip) {
    return ActionChip(
      backgroundColor: const Color(0xFF2A2A2A),
      label: Text(cmd, style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace')),
      tooltip: tooltip,
      onPressed: () {
        state.sendScpiCommand(cmd);
      },
    );
  }
}
