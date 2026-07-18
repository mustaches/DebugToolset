import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../modules/text_editor/utils/diff_utils.dart';

/// State for the Text Editor / Diff-Patch module.
///
/// Holds the original and modified file contents, tracks the current diff
/// result, and exposes operations to load files, compare them, save a patch,
/// and apply a patch to a target file.
class TextEditorState extends ChangeNotifier {
  String? _originalPath;
  String? _modifiedPath;
  String _originalContent = '';
  String _modifiedContent = '';
  List<DiffLine> _diffResult = [];
  bool _hasCompared = false;
  String? _lastError;

  String? get originalPath => _originalPath;
  String? get modifiedPath => _modifiedPath;
  String get originalContent => _originalContent;
  String get modifiedContent => _modifiedContent;
  List<DiffLine> get diffResult => List.unmodifiable(_diffResult);
  bool get hasCompared => _hasCompared;
  String? get lastError => _lastError;

  bool get hasContent => _originalContent.isNotEmpty || _modifiedContent.isNotEmpty;

  /// Loads the original file from disk.
  Future<void> loadOriginalFile(String path) async {
    _originalPath = path;
    _originalContent = await File(path).readAsString();
    _hasCompared = false;
    _diffResult = [];
    _lastError = null;
    notifyListeners();
  }

  /// Loads the modified file from disk.
  Future<void> loadModifiedFile(String path) async {
    _modifiedPath = path;
    _modifiedContent = await File(path).readAsString();
    _hasCompared = false;
    _diffResult = [];
    _lastError = null;
    notifyListeners();
  }

  /// Updates the original content from the in-place editor.
  void setOriginalContent(String content) {
    _originalContent = content;
    _hasCompared = false;
    _lastError = null;
    notifyListeners();
  }

  /// Updates the modified content from the in-place editor.
  void setModifiedContent(String content) {
    _modifiedContent = content;
    _hasCompared = false;
    _lastError = null;
    notifyListeners();
  }

  /// Computes a line-based diff between original and modified contents.
  void compare() {
    final originalLines = splitLines(_originalContent);
    final modifiedLines = splitLines(_modifiedContent);
    _diffResult = computeDiff(originalLines, modifiedLines);
    _hasCompared = true;
    _lastError = null;
    notifyListeners();
  }

  /// Discards the current diff result and returns to the split editor view.
  void discardDiff() {
    _hasCompared = false;
    _diffResult = [];
    _lastError = null;
    notifyListeners();
  }

  /// Saves the current diff as a unified diff patch file.
  Future<void> savePatch(String outputPath) async {
    final patch = generateUnifiedDiff(
      splitLines(_originalContent),
      splitLines(_modifiedContent),
      originalLabel: '--- ${_originalPath != null ? p.basename(_originalPath!) : 'original'}',
      modifiedLabel: '+++ ${_modifiedPath != null ? p.basename(_modifiedPath!) : 'modified'}',
    );

    if (patch.isEmpty) {
      throw Exception('没有差异可保存');
    }

    await File(outputPath).writeAsString(patch);
  }

  /// Applies a patch file to a target file and writes the result to
  /// [outputPath].
  Future<void> applyPatch(
    String targetFilePath,
    String patchFilePath,
    String outputPath,
  ) async {
    final patchContent = await File(patchFilePath).readAsString();
    await applyUnifiedDiffPatch(targetFilePath, patchContent, outputPath);
  }

  /// Reverts a previously applied patch: reads [patchFilePath], reverses it,
  /// and applies the reversed patch to [targetFilePath], writing the restored
  /// result to [outputPath].
  Future<void> revertPatch(
    String targetFilePath,
    String patchFilePath,
    String outputPath,
  ) async {
    await revertUnifiedDiffPatch(targetFilePath, patchFilePath, outputPath);
  }

  /// Clears all loaded content and diff results.
  void clear() {
    _originalPath = null;
    _modifiedPath = null;
    _originalContent = '';
    _modifiedContent = '';
    _diffResult = [];
    _hasCompared = false;
    _lastError = null;
    notifyListeners();
  }
}
