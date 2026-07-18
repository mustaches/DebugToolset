import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../../providers/text_editor_state.dart';
import '../utils/file_type_groups.dart';

/// Dialog that guides the user through applying or reverting a patch file.
///
/// The user selects:
/// 1. The target file (file to be patched or already patched).
/// 2. The patch file (.patch / unified diff).
/// 3. The output file where the result will be saved.
class PatchApplyDialog extends StatefulWidget {
  final bool revertMode;

  const PatchApplyDialog({super.key, this.revertMode = false});

  @override
  State<PatchApplyDialog> createState() => _PatchApplyDialogState();
}

class _PatchApplyDialogState extends State<PatchApplyDialog> {
  String? _targetPath;
  String? _patchPath;
  String? _outputPath;
  bool _isApplying = false;
  String? _error;

  Future<void> _pickTargetFile() async {
    final file = await openFile(acceptedTypeGroups: kTextEditorFileGroups);
    if (file == null || !mounted) return;

    setState(() {
      _targetPath = file.path;
      _error = null;
    });

    // If a patch file is already selected, re-validate it against the new target.
    if (_patchPath != null) {
      await _validateAndAutoFill();
    }
  }

  Future<void> _pickPatchFile() async {
    const XTypeGroup patchType = XTypeGroup(
      label: 'Patch Files (*.patch, *.diff)',
      extensions: ['patch', 'diff'],
    );
    const XTypeGroup allType = XTypeGroup(label: 'All Files', extensions: []);

    final file = await openFile(acceptedTypeGroups: [patchType, allType]);
    if (file == null || !mounted) return;

    setState(() {
      _patchPath = file.path;
      _error = null;
      _outputPath = null; // Reset output until validation succeeds.
    });

    await _validateAndAutoFill();
  }

  Future<void> _pickOutputFile() async {
    final initialName = _outputPath != null ? p.basename(_outputPath!) : _defaultOutputName();

    const XTypeGroup allType = XTypeGroup(label: 'All Files', extensions: []);
    final location = await getSaveLocation(
      acceptedTypeGroups: [allType],
      suggestedName: initialName ?? 'output.txt',
    );
    if (location != null && mounted) {
      setState(() {
        _outputPath = location.path;
        _error = null;
      });
    }
  }

  /// Parses the first `---` and `+++` lines from the selected patch file.
  /// Returns `(originalName, modifiedName)` or `null` if the header is invalid.
  Future<(String?, String?)?> _parsePatchHeader() async {
    if (_patchPath == null) return null;

    try {
      final lines = await File(_patchPath!).readAsLines();
      String? originalName;
      String? modifiedName;

      for (final line in lines) {
        if (line.startsWith('---')) {
          originalName = line.substring(3).split('\t').first.trim();
        } else if (line.startsWith('+++')) {
          modifiedName = line.substring(3).split('\t').first.trim();
        }
        if (originalName != null && modifiedName != null) break;
      }

      if (originalName == null || modifiedName == null) return null;
      return (originalName, modifiedName);
    } catch (_) {
      return null;
    }
  }

  /// Validates that the selected patch matches the selected target file and
  /// auto-fills the output path. In normal mode the target should match the
  /// `---` header and the output is derived from the `+++` header; in revert
  /// mode the target should match the `+++` header and the output is derived
  /// from the `---` header.
  Future<void> _validateAndAutoFill() async {
    if (_patchPath == null) return;

    final header = await _parsePatchHeader();
    if (!mounted) return;
    if (header == null) {
      await _showWarning('无法读取补丁文件头，请确认选择了一个有效的统一 diff 补丁。');
      if (!mounted) return;
      _clearPatchAndReopen();
      return;
    }

    final (patchOriginalName, patchModifiedName) = header;

    // In revert mode we are patching the modified file back to the original.
    final expectedTargetName = widget.revertMode ? patchModifiedName : patchOriginalName;
    final expectedOutputName = widget.revertMode ? patchOriginalName : patchModifiedName;
    final targetRoleLabel = widget.revertMode ? '修改后文件' : '原文件';

    if (_targetPath != null && expectedTargetName != null) {
      final expectedTargetBasename = p.basename(expectedTargetName);
      final targetBasename = p.basename(_targetPath!);

      if (expectedTargetBasename != targetBasename) {
        await _showWarning(
          '补丁不匹配：补丁中的$targetRoleLabel是 "$expectedTargetBasename"，而选定的目标文件是 "$targetBasename"。',
        );
        if (!mounted) return;
        _clearPatchAndReopen();
        return;
      }
    }

    // Auto-fill output path based on the expected output file name.
    if (_targetPath != null && expectedOutputName != null && mounted) {
      final outputBasename = p.basename(expectedOutputName);
      final targetDir = p.dirname(_targetPath!);
      setState(() {
        _outputPath = p.join(targetDir, outputBasename);
      });
    }
  }

  String? _defaultOutputName() {
    if (_targetPath != null) {
      final base = p.basenameWithoutExtension(_targetPath!);
      final ext = p.extension(_targetPath!);
      final suffix = widget.revertMode ? '_reverted' : '_patched';
      return '$base$suffix$ext';
    }
    return widget.revertMode ? 'reverted.txt' : 'patched.txt';
  }

  void _clearPatchAndReopen() {
    setState(() {
      _patchPath = null;
      _outputPath = null;
    });
    _pickPatchFile();
  }

  Future<void> _showWarning(String message) async {
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orangeAccent, size: 20),
            SizedBox(width: 10),
            Text('补丁不匹配', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('确定', style: TextStyle(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _apply() async {
    if (_targetPath == null || _patchPath == null || _outputPath == null) {
      setState(() => _error = '请先选择目标文件、补丁文件和输出文件');
      return;
    }

    setState(() {
      _isApplying = true;
      _error = null;
    });

    try {
      final state = context.read<TextEditorState>();
      if (widget.revertMode) {
        await state.revertPatch(_targetPath!, _patchPath!, _outputPath!);
      } else {
        await state.applyPatch(_targetPath!, _patchPath!, _outputPath!);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = widget.revertMode ? '回退补丁失败: $e' : '应用补丁失败: $e';
        _isApplying = false;
      });
    }
  }

  Widget _buildFileRow({
    required String label,
    required String? path,
    required VoidCallback onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12))),
          Expanded(
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: Text(
                path ?? '未选择',
                style: TextStyle(
                  color: path != null ? Colors.white : Colors.grey,
                  fontSize: 12,
                  fontFamily: 'Consolas',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: onPick,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF333333),
              foregroundColor: Colors.cyanAccent,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('浏览', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: Row(
        children: [
          Icon(
            widget.revertMode ? Icons.undo : Icons.healing,
            color: Colors.cyanAccent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Text(
            widget.revertMode ? '回退补丁' : '应用补丁',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildFileRow(
              label: '目标文件:',
              path: _targetPath,
              onPick: _pickTargetFile,
            ),
            _buildFileRow(
              label: '补丁文件:',
              path: _patchPath,
              onPick: _pickPatchFile,
            ),
            _buildFileRow(
              label: '输出文件:',
              path: _outputPath,
              onPick: _pickOutputFile,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isApplying ? null : () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: _isApplying ? null : _apply,
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
          ),
          child: _isApplying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(widget.revertMode ? '回退' : '应用'),
        ),
      ],
    );
  }
}

/// Shows the patch application dialog and returns `true` if the patch was
/// applied successfully. Set [revertMode] to `true` to reverse a patch instead.
Future<bool> showPatchApplyDialog(BuildContext context, {bool revertMode = false}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => PatchApplyDialog(revertMode: revertMode),
  );
  return result == true;
}
