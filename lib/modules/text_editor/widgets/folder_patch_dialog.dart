import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../providers/text_editor_state.dart';

/// Shows the folder patch apply/revert dialog. Returns true when a patch was
/// successfully applied.
Future<bool> showFolderPatchDialog(BuildContext context,
    {bool revertMode = false}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => FolderPatchDialog(revertMode: revertMode),
  );
  return result ?? false;
}

/// Dialog that applies (or reverts) a multi-file unified diff patch against
/// a target folder, modifying files in place after a confirmation.
class FolderPatchDialog extends StatefulWidget {
  final bool revertMode;

  const FolderPatchDialog({super.key, this.revertMode = false});

  @override
  State<FolderPatchDialog> createState() => _FolderPatchDialogState();
}

class _FolderPatchDialogState extends State<FolderPatchDialog> {
  String? _patchPath;
  String? _targetDir;
  bool _busy = false;
  String? _error;
  List<String>? _appliedFiles;

  Future<void> _pickPatch() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Patch Files (*.patch, *.diff)',
          extensions: ['patch', 'diff']),
    ]);
    if (file != null) {
      setState(() {
        _patchPath = file.path;
        _error = null;
      });
    }
  }

  Future<void> _pickTargetDir() async {
    final dir = await getDirectoryPath();
    if (dir != null) {
      setState(() {
        _targetDir = dir;
        _error = null;
      });
    }
  }

  Future<void> _run() async {
    final patchPath = _patchPath;
    final targetDir = _targetDir;
    if (patchPath == null || targetDir == null) return;

    final action = widget.revertMode ? '回退' : '应用';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF252525),
        title: Text('确认$action补丁',
            style: const TextStyle(fontSize: 14, color: Colors.white)),
        content: Text(
          '将$action补丁到：\n$targetDir\n\n'
          '该操作会就地修改目标文件夹中的文件（新增 / 修改 / 删除），是否继续？',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确认$action',
                style: const TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final state = context.read<TextEditorState>();
      final files = await state.applyFolderPatchTo(
        patchPath,
        targetDir,
        revert: widget.revertMode,
      );
      setState(() {
        _busy = false;
        _appliedFiles = files;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '$action失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.revertMode ? '回退' : '应用';
    final canRun = _patchPath != null && _targetDir != null && !_busy;

    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      child: SizedBox(
        width: 560,
        height: 420,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('$action文件夹补丁',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () =>
                        Navigator.of(context).pop(_appliedFiles != null),
                    tooltip: '关闭',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _pickerRow(
                label: '补丁文件',
                value: _patchPath == null
                    ? '（未选择）'
                    : p.basename(_patchPath!),
                buttonLabel: '选择补丁',
                onPressed: _busy ? null : _pickPatch,
              ),
              const SizedBox(height: 8),
              _pickerRow(
                label: '目标文件夹',
                value: _targetDir ?? '（未选择）',
                buttonLabel: '选择文件夹',
                onPressed: _busy ? null : _pickTargetDir,
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Text(_error!,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.redAccent)),
              if (_appliedFiles != null) ...[
                Text(
                  '$action成功，共处理 ${_appliedFiles!.length} 个文件：',
                  style: const TextStyle(fontSize: 12, color: Colors.green),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Container(
                    color: const Color(0xFF252525),
                    child: ListView.builder(
                      itemCount: _appliedFiles!.length,
                      itemExtent: 22,
                      itemBuilder: (context, index) => Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          _appliedFiles![index],
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'Consolas',
                              color: Colors.white70),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_appliedFiles != null)
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0A4A5A),
                        foregroundColor: Colors.cyanAccent,
                      ),
                      child: const Text('完成'),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: canRun ? _run : null,
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : Icon(
                              widget.revertMode
                                  ? Icons.undo
                                  : Icons.healing,
                              size: 16),
                      label: Text(_busy ? '处理中…' : '$action补丁'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0A4A5A),
                        foregroundColor: Colors.cyanAccent,
                        disabledBackgroundColor: const Color(0xFF2A2A2A),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pickerRow({
    required String label,
    required String value,
    required String buttonLabel,
    required VoidCallback? onPressed,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
                fontSize: 12, fontFamily: 'Consolas', color: Colors.white70),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF333333),
            foregroundColor: Colors.cyanAccent,
            minimumSize: const Size(0, 30),
          ),
          child: Text(buttonLabel, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}
