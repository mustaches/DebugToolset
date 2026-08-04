import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../../modules/text_editor/utils/diff_utils.dart';
import '../../modules/text_editor/utils/folder_diff.dart';

/// Which comparison mode the Text Editor / Diff-Patch module is in.
enum TextCompareMode {
  /// Compare two individual files.
  files,

  /// Compare two folder trees and extract a project patch.
  folder,
}

/// State for the Text Editor / Diff-Patch module.
///
/// Holds the original and modified file contents, tracks the current diff
/// result, and exposes operations to load files, compare them, save a patch,
/// and apply a patch to a target file. In folder mode it instead holds two
/// folder trees and their per-file comparison entries.
class TextEditorState extends ChangeNotifier {
  TextCompareMode _mode = TextCompareMode.files;
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
  TextCompareMode get mode => _mode;

  bool get hasContent => _originalContent.isNotEmpty || _modifiedContent.isNotEmpty;

  /// Switches between single-file and folder comparison, clearing all
  /// loaded content and results on both sides.
  void setMode(TextCompareMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    clear();
    clearFolder();
  }

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

  bool _isComparing = false;
  bool get isComparing => _isComparing;

  /// Computes a line-based diff between original and modified contents.
  /// Offloaded to a background Isolate so the UI thread never freezes.
  Future<void> compare() async {
    _isComparing = true;
    _lastError = null;
    notifyListeners();

    try {
      final originalLines = splitLines(_originalContent);
      final modifiedLines = splitLines(_modifiedContent);
      _diffResult = await compute(_runDiffInIsolate, (originalLines, modifiedLines));
      _hasCompared = true;
    } catch (e) {
      _lastError = '对比失败: $e';
    } finally {
      _isComparing = false;
      notifyListeners();
    }
  }

  static List<DiffLine> _runDiffInIsolate((List<String>, List<String>) args) {
    return computeDiffFast(args.$1, args.$2);
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

  // ------------------------------------------------------------------
  // Folder comparison mode
  // ------------------------------------------------------------------

  String? _originalDir;
  String? _modifiedDir;
  List<String> _originalFolderFiles = [];
  List<String> _modifiedFolderFiles = [];
  List<FolderDiffEntry> _folderEntries = [];
  bool _folderCompared = false;
  bool _isComparingFolder = false;

  // Progress of the running folder comparison (drives the progress dialog).
  int _folderCompareProcessed = 0;
  int _folderCompareTotal = 0;
  String? _folderComparePathA;
  String? _folderComparePathB;

  // The file currently opened from the folder trees.
  String? _selectedFolderFile;
  List<DiffLine> _folderFileDiff = [];
  bool _folderFileBinary = false;
  bool _folderFileInOriginal = false;
  bool _folderFileInModified = false;
  bool _isOpeningFolderFile = false;
  int _openFolderFileToken = 0;

  String? get originalDir => _originalDir;
  String? get modifiedDir => _modifiedDir;

  /// Sorted forward-slash relative paths of the files under [originalDir],
  /// loaded when the folder is opened (for the explorer-style tree view).
  List<String> get originalFolderFiles =>
      List.unmodifiable(_originalFolderFiles);

  /// Sorted forward-slash relative paths of the files under [modifiedDir].
  List<String> get modifiedFolderFiles =>
      List.unmodifiable(_modifiedFolderFiles);
  List<FolderDiffEntry> get folderEntries => List.unmodifiable(_folderEntries);
  bool get folderCompared => _folderCompared;
  bool get isComparingFolder => _isComparingFolder;

  /// Number of files already compared in the running folder comparison.
  int get folderCompareProcessed => _folderCompareProcessed;

  /// Total number of files to compare (0 until the trees are listed).
  int get folderCompareTotal => _folderCompareTotal;

  /// Absolute path of the file being compared on the original (left) side,
  /// or null when it does not exist there.
  String? get folderComparePathA => _folderComparePathA;

  /// Absolute path of the file being compared on the modified (right) side,
  /// or null when it does not exist there.
  String? get folderComparePathB => _folderComparePathB;

  /// Relative path of the file currently opened from the folder trees.
  String? get selectedFolderFile => _selectedFolderFile;

  /// Line diff of the opened folder file (original vs modified). A file that
  /// exists on only one side is diffed against an empty side, so it shows as
  /// all-insertions or all-deletions.
  List<DiffLine> get folderFileDiff => List.unmodifiable(_folderFileDiff);

  /// True when the opened folder file looks binary on either side.
  bool get folderFileBinary => _folderFileBinary;
  bool get folderFileInOriginal => _folderFileInOriginal;
  bool get folderFileInModified => _folderFileInModified;
  bool get isOpeningFolderFile => _isOpeningFolderFile;

  bool get hasFolderContent => _originalDir != null || _modifiedDir != null;

  /// Sets the original (left) folder and invalidates the comparison.
  /// Lists the folder's files in a background isolate for the tree view.
  Future<void> loadOriginalFolder(String dir) async {
    _originalDir = dir;
    _originalFolderFiles = [];
    _folderCompared = false;
    _folderEntries = [];
    _resetFolderFile();
    _lastError = null;
    notifyListeners();
    try {
      final files = await compute(listFolderFiles, dir);
      if (_originalDir == dir) {
        _originalFolderFiles = files;
        notifyListeners();
      }
    } catch (e) {
      if (_originalDir == dir) {
        _lastError = '读取文件夹失败: $e';
        notifyListeners();
      }
    }
  }

  /// Sets the modified (right) folder and invalidates the comparison.
  /// Lists the folder's files in a background isolate for the tree view.
  Future<void> loadModifiedFolder(String dir) async {
    _modifiedDir = dir;
    _modifiedFolderFiles = [];
    _folderCompared = false;
    _folderEntries = [];
    _resetFolderFile();
    _lastError = null;
    notifyListeners();
    try {
      final files = await compute(listFolderFiles, dir);
      if (_modifiedDir == dir) {
        _modifiedFolderFiles = files;
        notifyListeners();
      }
    } catch (e) {
      if (_modifiedDir == dir) {
        _lastError = '读取文件夹失败: $e';
        notifyListeners();
      }
    }
  }

  /// Recursively compares the two folder trees in a background isolate,
  /// reporting per-file progress through [folderCompareProcessed],
  /// [folderCompareTotal], [folderComparePathA] and [folderComparePathB].
  Future<void> compareFolders() async {
    final dirA = _originalDir;
    final dirB = _modifiedDir;
    if (dirA == null || dirB == null) {
      _lastError = '请先选择原文件夹和修改文件夹';
      notifyListeners();
      return;
    }
    _isComparingFolder = true;
    _folderCompareProcessed = 0;
    _folderCompareTotal = 0;
    _folderComparePathA = null;
    _folderComparePathB = null;
    _lastError = null;
    notifyListeners();

    final receivePort = ReceivePort();
    try {
      await Isolate.spawn(
        _compareIsolateEntry,
        (dirA, dirB, receivePort.sendPort),
      );
      await for (final message in receivePort) {
        if (message is (int, int, String, String?, String?)) {
          final (processed, total, _, pathA, pathB) = message;
          _folderCompareProcessed = processed;
          _folderCompareTotal = total;
          _folderComparePathA = pathA;
          _folderComparePathB = pathB;
          notifyListeners();
        } else if (message is List<FolderDiffEntry>) {
          _folderEntries = message;
          _folderCompared = true;
          _resetFolderFile();
          break;
        } else if (message is String) {
          _lastError = '文件夹对比失败: $message';
          break;
        }
      }
    } catch (e) {
      _lastError = '文件夹对比失败: $e';
    } finally {
      receivePort.close();
      _isComparingFolder = false;
      notifyListeners();
    }
  }

  /// Entry point of the folder-compare isolate. Sends progress records
  /// `(processed, total, relativePath, pathA, pathB)` while running, then the
  /// finished `List<FolderDiffEntry>`, or an error description string.
  static void _compareIsolateEntry((String, String, SendPort) args) {
    final (dirA, dirB, sendPort) = args;
    try {
      final entries = compareFolderTrees(
        dirA,
        dirB,
        onProgress: (processed, total, rel, pathA, pathB) {
          sendPort.send((processed, total, rel, pathA, pathB));
        },
      );
      sendPort.send(entries);
    } catch (e) {
      sendPort.send(e.toString());
    }
  }

  /// Discards the folder comparison result (the opened folders stay loaded),
  /// turning the toolbar button back into “比较差异”.
  void discardFolderCompare() {
    _folderCompared = false;
    _folderEntries = [];
    _resetFolderFile();
    notifyListeners();
  }

  /// Opens [relativePath] from the two opened folders: reads whichever
  /// version exists and computes the line diff between them — the same way
  /// the single-file comparison does it. Tapping the already-open file closes
  /// it again.
  Future<void> openFolderFile(String relativePath) async {
    if (_selectedFolderFile == relativePath) {
      _resetFolderFile();
      notifyListeners();
      return;
    }

    final token = ++_openFolderFileToken;
    _selectedFolderFile = relativePath;
    _folderFileDiff = [];
    _folderFileBinary = false;
    _folderFileInOriginal = false;
    _folderFileInModified = false;
    _isOpeningFolderFile = true;
    _lastError = null;
    notifyListeners();

    try {
      final dirA = _originalDir;
      final dirB = _modifiedDir;
      final fileA = dirA != null ? File(p.join(dirA, relativePath)) : null;
      final fileB = dirB != null ? File(p.join(dirB, relativePath)) : null;
      final existsA = fileA != null && fileA.existsSync();
      final existsB = fileB != null && fileB.existsSync();

      var linesA = const <String>[];
      var linesB = const <String>[];
      var binary = false;
      if (existsA) {
        final bytes = await fileA.readAsBytes();
        if (looksBinary(_headOf(bytes))) {
          binary = true;
        } else {
          linesA = splitLines(utf8.decode(bytes, allowMalformed: true));
        }
      }
      if (existsB) {
        final bytes = await fileB.readAsBytes();
        if (looksBinary(_headOf(bytes))) {
          binary = true;
        } else {
          linesB = splitLines(utf8.decode(bytes, allowMalformed: true));
        }
      }
      if (token != _openFolderFileToken) return;

      _folderFileInOriginal = existsA;
      _folderFileInModified = existsB;
      _folderFileBinary = binary;

      if (!binary && (existsA || existsB)) {
        // Reuse the diff already computed by the folder comparison when
        // available, otherwise compute it the same way compare() does.
        List<DiffLine>? diff;
        if (_folderCompared) {
          for (final entry in _folderEntries) {
            if (entry.relativePath == relativePath) {
              diff = entry.diff;
              break;
            }
          }
        }
        final List<DiffLine> resolved;
        if (diff != null) {
          resolved = diff;
        } else {
          resolved = await compute(_runDiffInIsolate, (linesA, linesB));
        }
        if (token != _openFolderFileToken) return;
        _folderFileDiff = resolved;
      }
    } catch (e) {
      if (token == _openFolderFileToken) {
        _lastError = '打开文件失败: $e';
      }
    } finally {
      if (token == _openFolderFileToken) {
        _isOpeningFolderFile = false;
        notifyListeners();
      }
    }
  }

  static Uint8List _headOf(Uint8List bytes, [int max = 8192]) {
    return bytes.length <= max ? bytes : Uint8List.sublistView(bytes, 0, max);
  }

  /// Clears the file opened from the folder trees (without touching the
  /// opened folders or the comparison result).
  void _resetFolderFile() {
    _openFolderFileToken++;
    _selectedFolderFile = null;
    _folderFileDiff = [];
    _folderFileBinary = false;
    _folderFileInOriginal = false;
    _folderFileInModified = false;
    _isOpeningFolderFile = false;
  }

  /// Generates a multi-file patch from the folder comparison and writes it
  /// to [outputPath].
  Future<void> saveFolderPatch(String outputPath) async {
    final dirA = _originalDir;
    final dirB = _modifiedDir;
    if (dirA == null || dirB == null) {
      throw Exception('请先选择原文件夹和修改文件夹');
    }
    final patch = generateFolderPatch(dirA, dirB, _folderEntries);
    if (patch.isEmpty) {
      throw Exception('没有差异可保存');
    }
    await File(outputPath).writeAsString(patch);
  }

  /// Applies (or with [revert], reverts) the multi-file patch [patchPath]
  /// against [targetDir], modifying files in place. Returns the list of
  /// affected relative paths.
  Future<List<String>> applyFolderPatchTo(
    String patchPath,
    String targetDir, {
    bool revert = false,
  }) {
    return applyFolderPatch(patchPath, targetDir, revert: revert);
  }

  /// Clears folder-mode state.
  void clearFolder() {
    _originalDir = null;
    _modifiedDir = null;
    _originalFolderFiles = [];
    _modifiedFolderFiles = [];
    _folderEntries = [];
    _folderCompared = false;
    _isComparingFolder = false;
    _resetFolderFile();
    _lastError = null;
    notifyListeners();
  }
}
