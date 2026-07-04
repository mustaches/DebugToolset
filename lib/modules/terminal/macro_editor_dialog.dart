import 'package:flutter/material.dart';
import '../../providers/macro_state.dart';
import '../../utils/terminal_input_formatter.dart';

class MacroEditorDialog extends StatefulWidget {
  final String filename;
  final List<MacroStep> steps;

  const MacroEditorDialog({super.key, required this.filename, required this.steps});

  @override
  State<MacroEditorDialog> createState() => _MacroEditorDialogState();
}

class _MacroEditorDialogState extends State<MacroEditorDialog> {
  late List<_MutableMacroStep> _editableSteps;

  @override
  void initState() {
    super.initState();
    _editableSteps = widget.steps.map((e) => _MutableMacroStep.from(e)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('编辑宏序列: ${widget.filename}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 800,
        height: 500,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: _editableSteps.length,
                itemBuilder: (context, index) {
                  final step = _editableSteps[index];
                  return Card(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          Text('${index + 1}. ', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                          const SizedBox(width: 8),
                          
                          // Command Field
                          Expanded(
                            flex: 4,
                            child: TextField(
                              controller: step.commandCtrl,
                              decoration: const InputDecoration(labelText: '发送指令', isDense: true, border: OutlineInputBorder()),
                              style: const TextStyle(fontFamily: 'Consolas', fontSize: 14),
                              inputFormatters: step.isHex ? [HexInputFormatter()] : [AsciiInputFormatter()],
                            ),
                          ),
                          const SizedBox(width: 16),
                          
                          // EOL Mode
                          SizedBox(
                            width: 85,
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: step.eolMode,
                              decoration: const InputDecoration(
                                labelText: '结束符', 
                                isDense: true, 
                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                border: OutlineInputBorder(),
                              ),
                              items: ['None', 'CR', 'LF', 'CRLF'].map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 12)))).toList(),
                              onChanged: step.isHex ? null : (val) {
                                if (val != null) setState(() => step.eolMode = val);
                              },
                            ),
                          ),
                          const SizedBox(width: 16),
                          
                          // Hex Toggle
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Hex', style: TextStyle(fontSize: 10)),
                              Checkbox(
                                value: step.isHex,
                                visualDensity: VisualDensity.compact,
                                onChanged: (val) {
                                  if (val != null) setState(() => step.isHex = val);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          
                          // Delay Field
                          SizedBox(
                            width: 90,
                            child: TextField(
                              controller: step.delayCtrl,
                              decoration: const InputDecoration(labelText: '延迟(ms)', isDense: true, border: OutlineInputBorder()),
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 16),
                          
                          // Actions
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.blueAccent),
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(4),
                                    tooltip: '上移',
                                    onPressed: index > 0 ? () {
                                      setState(() {
                                        final item = _editableSteps.removeAt(index);
                                        _editableSteps.insert(index - 1, item);
                                      });
                                    } : null,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.arrow_downward, size: 16, color: Colors.blueAccent),
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(4),
                                    tooltip: '下移',
                                    onPressed: index < _editableSteps.length - 1 ? () {
                                      setState(() {
                                        final item = _editableSteps.removeAt(index);
                                        _editableSteps.insert(index + 1, item);
                                      });
                                    } : null,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, size: 16, color: Colors.red),
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(4),
                                    tooltip: '删除此条',
                                    onPressed: () {
                                      setState(() => _editableSteps.removeAt(index));
                                    },
                                  ),
                                ],
                              ),
                            ],
                          )
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('添加新指令'),
              onPressed: () {
                setState(() {
                  _editableSteps.add(_MutableMacroStep(command: '', isHex: false, eolMode: 'CRLF', delayMs: 1000));
                });
              },
            )
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          onPressed: () {
            List<MacroStep> result = _editableSteps.map((e) => MacroStep(
              command: e.commandCtrl.text,
              isHex: e.isHex,
              eolMode: e.eolMode,
              delayMs: int.tryParse(e.delayCtrl.text) ?? 0,
            )).toList();
            Navigator.pop(context, result);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _MutableMacroStep {
  TextEditingController commandCtrl;
  bool isHex;
  String eolMode;
  TextEditingController delayCtrl;

  _MutableMacroStep({required String command, required this.isHex, required this.eolMode, required int delayMs})
      : commandCtrl = TextEditingController(text: command),
        delayCtrl = TextEditingController(text: delayMs.toString());

  factory _MutableMacroStep.from(MacroStep step) {
    return _MutableMacroStep(
      command: step.command,
      isHex: step.isHex,
      eolMode: step.eolMode,
      delayMs: step.delayMs,
    );
  }
}
