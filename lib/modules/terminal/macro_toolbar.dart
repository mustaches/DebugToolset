import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/macro_state.dart';
import '../../providers/terminal_state.dart';
import 'macro_editor_dialog.dart';

class MacroToolbar extends StatefulWidget {
  final Function(String command, bool isHex, String eolMode) onPlayCommand;
  
  const MacroToolbar({super.key, required this.onPlayCommand});

  @override
  State<MacroToolbar> createState() => _MacroToolbarState();
}

class _MacroToolbarState extends State<MacroToolbar> {
  String? _selectedFile;
  List<String> _files = [];
  late TextEditingController _loopIntervalCtrl;
  late TextEditingController _loopCountCtrl;

  @override
  void initState() {
    super.initState();
    // Use read instead of watch in initState
    _loopIntervalCtrl = TextEditingController(text: context.read<MacroState>().loopIntervalMs.toString());
    _loopCountCtrl = TextEditingController(text: context.read<MacroState>().loopCount.toString());
    _refreshFiles();
  }

  @override
  void dispose() {
    _loopIntervalCtrl.dispose();
    _loopCountCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshFiles() async {
    final macroState = context.read<MacroState>();
    final files = await macroState.getSequenceFiles();
    if (!mounted) return;
    setState(() {
      _files = files;
      if (_selectedFile != null && !_files.contains(_selectedFile)) {
        _selectedFile = null;
      }
      if (_selectedFile == null && _files.isNotEmpty) {
        _selectedFile = _files.first;
      }
    });
  }

  void _showSaveDialog(BuildContext context, MacroState macroState) {
    final TextEditingController filenameController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('保存宏序列', style: TextStyle(fontSize: 16)),
          content: TextField(
            controller: filenameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '文件名 (不含后缀)',
              hintText: '如 init_screen',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                macroState.cancelRecording();
                Navigator.of(context).pop();
              },
              child: const Text('放弃录制', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () async {
                String name = filenameController.text.trim();
                if (name.isNotEmpty) {
                  await macroState.stopRecordingAndSave(name);
                  await _refreshFiles();
                  if (context.mounted) Navigator.of(context).pop();
                }
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  void _editMacro() async {
    if (_selectedFile == null) return;
    final macroState = context.read<MacroState>();
    final steps = await macroState.loadMacroSteps(_selectedFile!);
    
    if (!mounted) return;
    final result = await showDialog<List<MacroStep>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => MacroEditorDialog(filename: _selectedFile!, steps: steps),
    );
    
    if (result != null) {
      await macroState.updateMacro(_selectedFile!, result);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('宏序列已更新')));
    }
  }

  void _deleteMacro() async {
    if (_selectedFile == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('您确定要删除宏 "$_selectedFile" 吗？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true), 
            child: const Text('删除')
          ),
        ],
      )
    );
    
    if (confirm == true) {
      if (!mounted) return;
      final macroState = context.read<MacroState>();
      await macroState.deleteMacro(_selectedFile!);
      _selectedFile = null;
      await _refreshFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    final macroState = context.watch<MacroState>();
    final terminalState = context.read<TerminalState>();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // ==============================
          // 左侧：文件管理与操作区
          // ==============================
          Expanded(
            child: Row(
              children: [
                const Tooltip(
                  message: '宏脚本',
                  child: Icon(Icons.integration_instructions_outlined, size: 20, color: Colors.blueGrey),
                ),
                const SizedBox(width: 8),
                
                // 组合下拉框与操作按钮
                Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 130,
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedFile,
                            isExpanded: true,
                            isDense: true,
                            iconSize: 18,
                            hint: const Text('请选择宏文件...', style: TextStyle(fontSize: 12)),
                            items: _files.map((file) => DropdownMenuItem(
                              value: file,
                              child: Text(file, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                            )).toList(),
                            onChanged: macroState.isPlaying || macroState.isRecording ? null : (val) {
                              setState(() => _selectedFile = val);
                            },
                          ),
                        ),
                      ),
                      Container(width: 1, height: 20, color: Theme.of(context).dividerColor, margin: const EdgeInsets.symmetric(horizontal: 4)),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 14),
                        tooltip: '刷新列表',
                        splashRadius: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: macroState.isPlaying || macroState.isRecording ? null : _refreshFiles,
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 14, color: Colors.blueAccent),
                        tooltip: '编辑脚本',
                        splashRadius: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: macroState.isPlaying || macroState.isRecording || _selectedFile == null ? null : _editMacro,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, size: 14, color: Colors.redAccent),
                        tooltip: '删除脚本',
                        splashRadius: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: macroState.isPlaying || macroState.isRecording || _selectedFile == null ? null : _deleteMacro,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // ==============================
          // 右侧：播放设置与主要控制按钮
          // ==============================
          Row(
            children: [
              // 循环参数设置面板（仅在循环开启时显示）
              if (macroState.isLooping) ...[
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Text('间隔:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 45,
                        child: TextField(
                          controller: _loopIntervalCtrl,
                          decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                          keyboardType: TextInputType.number,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                          enabled: !macroState.isPlaying,
                          onChanged: (val) {
                            int? parsed = int.tryParse(val);
                            if (parsed != null && parsed >= 0) context.read<MacroState>().setLoopInterval(parsed);
                          },
                        ),
                      ),
                      const Text('ms', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      Container(width: 1, height: 16, color: Theme.of(context).dividerColor, margin: const EdgeInsets.symmetric(horizontal: 8)),
                      const Text('次数:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 35,
                        child: TextField(
                          controller: _loopCountCtrl,
                          decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: '∞'),
                          keyboardType: TextInputType.number,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                          enabled: !macroState.isPlaying,
                          onChanged: (val) {
                            int? parsed = int.tryParse(val);
                            if (parsed != null && parsed >= 0) context.read<MacroState>().setLoopCount(parsed);
                          },
                        ),
                      ),
                      if (macroState.loopCount == 0)
                        const Text('(无限)', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              
              // 循环开关图标按钮
              Tooltip(
                message: macroState.isLooping ? '关闭循环' : '开启循环',
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: macroState.isPlaying ? null : () => macroState.toggleLooping(!macroState.isLooping),
                  child: Padding(
                    padding: const EdgeInsets.all(6.0),
                    child: Icon(
                      Icons.repeat,
                      size: 20,
                      color: macroState.isLooping ? Colors.blueAccent : Colors.grey.shade400,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              
              // 播放与停止播放按钮
              if (!macroState.isPlaying)
                IconButton.filled(
                  icon: const Icon(Icons.play_arrow, size: 18),
                  tooltip: '播放',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: macroState.isRecording || _selectedFile == null ? null : () {
                    macroState.playMacro(_selectedFile!, widget.onPlayCommand, terminalState.addSystemLog, () => terminalState.isConnected);
                  },
                )
              else
                IconButton.filled(
                  icon: const Icon(Icons.stop, size: 18),
                  tooltip: '停止播放',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: macroState.stopPlayback,
                ),
                
              const SizedBox(width: 8),
              
              // 录制与保存按钮
              if (!macroState.isRecording)
                IconButton.outlined(
                  icon: const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 18),
                  tooltip: '录制宏',
                  style: IconButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    side: const BorderSide(color: Colors.redAccent),
                  ),
                  onPressed: macroState.isPlaying ? null : macroState.startRecording,
                )
              else
                IconButton.filled(
                  icon: Badge(
                    label: Text('${macroState.currentRecording.length}'),
                    child: const Icon(Icons.save, size: 18),
                  ),
                  tooltip: '完成录制并保存',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () => _showSaveDialog(context, macroState),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
