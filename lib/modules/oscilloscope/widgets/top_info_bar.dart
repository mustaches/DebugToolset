import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';
import '../../../utils/hover_builder.dart';
import 'lxi_connection_dialog.dart';

class TopInfoBar extends StatelessWidget {
  const TopInfoBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();

    return Container(
      height: 44, // very compact height
      decoration: BoxDecoration(
        color: const Color(0xFF161616), // Darker theme
        border: Border(bottom: BorderSide(color: Colors.grey.shade800, width: 1.0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
         children: [
          // 1. Rigol style Navigation Button
          MenuAnchor(
            style: MenuStyle(
              backgroundColor: WidgetStateProperty.all(const Color(0xFF252525)),
              surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
              elevation: WidgetStateProperty.all(8.0),
              padding: WidgetStateProperty.all(EdgeInsets.zero),
              shape: WidgetStateProperty.all(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(color: Colors.grey.shade800, width: 1.5),
                ),
              ),
            ),
            builder: (BuildContext context, MenuController controller, Widget? child) {
              return HoverBuilder(
                builder: (context, isHovered) {
                  return InkWell(
                    onTap: () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8.0),
                      margin: const EdgeInsets.symmetric(horizontal: 4.0),
                      decoration: BoxDecoration(
                        color: isHovered || controller.isOpen ? const Color(0xFF333333) : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(
                        Icons.menu,
                        color: isHovered || controller.isOpen ? Colors.white : Colors.grey,
                        size: 20,
                      ),
                    ),
                  );
                }
              );
            },
            menuChildren: [
              SubmenuButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.hovered)) {
                      return const Color(0xFF333333);
                    }
                    return Colors.transparent;
                  }),
                  foregroundColor: WidgetStateProperty.all(Colors.white),
                  textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
                  padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                ),
                menuChildren: [
                  _buildSubmenuItem(context, state, 'Auto', 'Auto'),
                  _buildSubmenuItem(context, state, '1280x800', '1280*800'),
                  _buildSubmenuItem(context, state, '1366x768', '1366*768'),
                  _buildSubmenuItem(context, state, '1920x1080', '1920*1080'),
                ],
                child: const Text('分辨率设置'),
              ),
              MenuItemButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.hovered)) {
                      return const Color(0xFF333333);
                    }
                    return Colors.transparent;
                  }),
                  foregroundColor: WidgetStateProperty.all(Colors.white70),
                  textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
                  padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                ),
                onPressed: () {},
                child: const Text('系统设置'),
              ),
              MenuItemButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.hovered)) {
                      return const Color(0xFF333333);
                    }
                    return Colors.transparent;
                  }),
                  foregroundColor: WidgetStateProperty.all(Colors.white70),
                  textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
                  padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                ),
                onPressed: () {
                  showDialog(
                    context: state.oscNavigatorKey.currentContext ?? context,
                    useRootNavigator: false,
                    builder: (context) => const LxiConnectionDialog(),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'LXI_Logo/LXI_Logo_2.png',
                      height: 12,
                      color: Colors.white70,
                      colorBlendMode: BlendMode.srcIn,
                    ),
                    const Text(' 仪器设置'),
                  ],
                ),
              ),
              MenuItemButton(
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.hovered)) {
                      return const Color(0xFF333333);
                    }
                    return Colors.transparent;
                  }),
                  foregroundColor: WidgetStateProperty.all(Colors.white70),
                  textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
                  padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                ),
                onPressed: () {},
                child: const Text('关于'),
              ),
            ],
          ),
          
          // 2. Trigger Status (T'D / STOP)
          _buildInfoBlock(
            child: Text(
              state.isPaused ? 'STOP' : 'T\'D',
              style: TextStyle(
                color: state.isPaused ? Colors.redAccent : Colors.greenAccent, 
                fontWeight: FontWeight.w900, 
                fontSize: 14,
                letterSpacing: 1.0,
              ),
            ),
          ),

          // 3. Horizontal Timebase
          InkWell(
            onTap: () => _showTimebaseDialog(context, state),
            child: _buildInfoBlock(
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: Colors.orange.shade700, borderRadius: BorderRadius.circular(2)),
                    child: const Text('H', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 6),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${state.xScale.toStringAsFixed(2)} x/div', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                      const Text('+0.00s', style: TextStyle(color: Colors.grey, fontSize: 9)),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 4. Acquisition (Sample Rate / Depth)
          _buildInfoBlock(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: Colors.orange.shade700, borderRadius: BorderRadius.circular(2)),
                  child: const Text('A', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 6),
                const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('5.00MSa/s', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                    Text('Norm    10.00kpts', style: TextStyle(color: Colors.grey, fontSize: 9)),
                  ],
                ),
              ],
            ),
          ),

          // 5. Trigger Settings
          _buildInfoBlock(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: Colors.orange.shade700, borderRadius: BorderRadius.circular(2)),
                  child: const Text('T', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.show_chart, color: Colors.white, size: 14),
                const SizedBox(width: 6),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(color: Colors.yellow, padding: const EdgeInsets.symmetric(horizontal: 2), child: const Text('1', style: TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.bold))),
                        const SizedBox(width: 4),
                        const Text('A  DC', style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Text('${state.triggerLevel} lvl', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w500)),
                  ],
                ),
              ],
            ),
          ),

          // Memory / Buffer Status
          _buildInfoBlock(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: Colors.blue.shade700, borderRadius: BorderRadius.circular(2)),
                  child: const Icon(Icons.memory, color: Colors.white, size: 12),
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Write Ptr: ${state.digitalChannel.head}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                    Text('${state.digitalChannel.count * 4} / ${OscilloscopeState.maxPointsPerChannel * 4} Bytes', style: const TextStyle(color: Colors.greenAccent, fontSize: 9)),
                  ],
                ),
              ],
            ),
          ),

          const Spacer(),

          _buildActionButton(
            label: '',
            color: Colors.purpleAccent,
            isActive: state.isDemoMode,
            onTap: () => state.toggleDemoMode(),
            icon: Icons.auto_awesome,
            iconSize: 16.0,
            width: 36.0,
            tooltip: '演示模式',
          ),
          Container(
            height: 24,
            width: 1,
            color: Colors.grey.shade800,
            margin: const EdgeInsets.symmetric(horizontal: 4),
          ),
          _buildActionButton(
            label: '',
            color: Colors.greenAccent,
            isActive: state.connectionSource == 'LXI' && state.isLxiConnected,
            onTap: () {
              showDialog(
                context: state.oscNavigatorKey.currentContext ?? context,
                useRootNavigator: false,
                builder: (context) => const LxiConnectionDialog(),
              );
            },
            customIconAsset: 'LXI_Logo/LXI_Logo_2.png',
            iconSize: 14.0,
            width: 36.0,
            tooltip: 'LXI 仪器设置与连接',
          ),
          Container(
            height: 24,
            width: 1,
            color: Colors.grey.shade800,
            margin: const EdgeInsets.symmetric(horizontal: 4),
          ),
          _buildActionButton(
            label: '',
            color: Colors.blueAccent,
            onTap: () => _handleSave(context, state),
            icon: Icons.save,
            iconSize: 20.0,
            width: 36.0,
            tooltip: '保存波形数据',
          ),
          _buildActionButton(
            label: '',
            color: Colors.orangeAccent,
            onTap: () => _handleLoad(context, state),
            icon: Icons.download,
            iconSize: 20.0,
            width: 36.0,
            tooltip: '加载波形数据',
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBlock({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      margin: const EdgeInsets.only(right: 2.0, top: 4.0, bottom: 4.0),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade800),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _buildActionButton({
    required String label, 
    required Color color, 
    required VoidCallback onTap, 
    IconData? icon,
    String? customIconAsset,
    double? width,
    double? iconSize,
    bool isDoubleLine = false,
    String? topText,
    String? bottomText,
    bool activeBottom = false,
    bool isActive = false,
    String? tooltip,
  }) {
    final buttonWidget = HoverBuilder(
      builder: (context, isHovered) {
        final displayColor = (isHovered || isActive) ? color : Colors.grey;
        return InkWell(
          onTap: onTap,
          child: Container(
            width: width,
            margin: const EdgeInsets.symmetric(horizontal: 1.0, vertical: 4.0),
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            decoration: BoxDecoration(
              color: isHovered ? const Color(0xFF222222) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: isDoubleLine
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(topText!, style: TextStyle(color: !activeBottom || isHovered ? displayColor : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
                    Text(bottomText!, style: TextStyle(color: activeBottom || isHovered ? displayColor : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (customIconAsset != null)
                      Image.asset(
                        customIconAsset,
                        height: iconSize ?? 16,
                        color: displayColor,
                        colorBlendMode: BlendMode.srcIn,
                      ),
                    if (customIconAsset == null && icon != null) Icon(icon, color: displayColor, size: iconSize ?? 14),
                    if (label.isNotEmpty) Text(label, style: TextStyle(color: displayColor, fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ),
          ),
        );
      }
    );

    if (tooltip != null) {
      return Tooltip(
        message: tooltip,
        preferBelow: true,
        verticalOffset: 16,
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2C),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade800, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
        waitDuration: const Duration(milliseconds: 500),
        child: buttonWidget,
      );
    }
    return buttonWidget;
  }

  void _showTimebaseDialog(BuildContext context, OscilloscopeState state) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('时基设置 (Timebase)', style: TextStyle(color: Colors.white, fontSize: 14)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Scale: ${state.xScale.toStringAsFixed(1)}', style: const TextStyle(color: Colors.white)),
              Slider(
                value: state.xScale,
                min: 0.1,
                max: 10.0,
                onChanged: (v) => state.setTimebase(v),
              ),
            ],
          ),
        );
      }
    );
  }

  void _handleSave(BuildContext context, OscilloscopeState state) async {
    String defaultName = "cap_${DateTime.now().millisecondsSinceEpoch}.waveform";
    String? filename = await showDialog<String>(
      context: context,
      builder: (ctx) {
        TextEditingController ctrl = TextEditingController(text: defaultName);
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('Save Waveform', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: ctrl,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Filename',
              labelStyle: TextStyle(color: Colors.grey),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
          ],
        );
      }
    );
    
    if (filename != null && filename.isNotEmpty) {
      if (!filename.endsWith('.waveform')) filename += '.waveform';
      try {
        await state.saveWaveform('waveform/$filename');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Saved to waveform/$filename', style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.green.shade800,
          ));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to save: $e', style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.red.shade800,
          ));
        }
      }
    }
  }

  void _handleLoad(BuildContext context, OscilloscopeState state) async {
    List<File> files = [];
    try {
      var dir = Directory('waveform');
      if (dir.existsSync()) {
        for (var entity in dir.listSync()) {
          if (entity is File && entity.path.endsWith('.waveform')) {
            files.add(entity);
          }
        }
      }
    } catch (_) {}

    String? selectedPath = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('Load Waveform', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            height: 300,
            child: files.isEmpty 
              ? const Center(child: Text('No saved waveforms found.', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    var file = files[index];
                    return ListTile(
                      leading: const Icon(Icons.insert_chart, color: Colors.orangeAccent),
                      title: Text(file.path.split(Platform.pathSeparator).last, style: const TextStyle(color: Colors.white)),
                      subtitle: Text('${(file.lengthSync() / 1024).toStringAsFixed(1)} KB', style: const TextStyle(color: Colors.grey)),
                      onTap: () => Navigator.pop(ctx, file.path),
                    );
                  },
                ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ],
        );
      }
    );

    if (selectedPath != null) {
      try {
        await state.loadWaveform(selectedPath);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Loaded $selectedPath', style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.green.shade800,
          ));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to load: $e', style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.red.shade800,
          ));
        }
      }
    }
  }

  Widget _buildSubmenuItem(BuildContext context, OscilloscopeState state, String resolutionValue, String displayLabel) {
    bool isSelected = state.displayResolution == resolutionValue;
    return MenuItemButton(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return const Color(0xFF333333);
          }
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.all(Colors.white),
        textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
        padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      ),
      onPressed: () => state.setDisplayResolution(resolutionValue),
      child: SizedBox(
        width: 110,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(displayLabel, style: const TextStyle(color: Colors.white)),
            if (isSelected)
              const Icon(Icons.check, color: Colors.greenAccent, size: 14),
          ],
        ),
      ),
    );
  }
}
