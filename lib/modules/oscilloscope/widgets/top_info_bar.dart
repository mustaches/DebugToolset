import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';
import '../../../utils/hover_builder.dart';

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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: const Icon(Icons.menu, color: Colors.grey, size: 20),
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
            label: state.isPaused ? 'STOP' : 'RUN',
            color: state.isPaused ? Colors.red : Colors.green,
            onTap: () => state.togglePause(),
            isDoubleLine: true,
            topText: 'RUN',
            bottomText: 'STOP',
            activeBottom: state.isPaused,
          ),

          _buildActionButton(
            label: 'SAVE',
            color: Colors.blueAccent,
            onTap: () => _handleSave(context, state),
            icon: Icons.save,
          ),
          _buildActionButton(
            label: 'LOAD',
            color: Colors.orangeAccent,
            onTap: () => _handleLoad(context, state),
            icon: Icons.folder_open,
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
    bool isDoubleLine = false,
    String? topText,
    String? bottomText,
    bool activeBottom = false,
  }) {
    return HoverBuilder(
      builder: (context, isHovered) {
        return InkWell(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2.0, vertical: 4.0),
            padding: const EdgeInsets.symmetric(horizontal: 10.0),
            decoration: BoxDecoration(
              color: isHovered ? const Color(0xFF333333) : const Color(0xFF252525),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isHovered ? color : color.withValues(alpha: 0.5), 
                width: 1.5
              ),
              boxShadow: isHovered ? [BoxShadow(color: color.withValues(alpha: 0.2), blurRadius: 4)] : null,
            ),
            alignment: Alignment.center,
            child: isDoubleLine
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(topText!, style: TextStyle(color: !activeBottom || isHovered ? color : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
                    Text(bottomText!, style: TextStyle(color: activeBottom || isHovered ? color : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) Icon(icon, color: color, size: 14),
                    Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ),
          ),
        );
      }
    );
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
}
