import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class MacroStep {
  final String command;
  final bool isHex;
  final String eolMode;
  final int delayMs; // 执行此命令前的延迟时间（毫秒）

  MacroStep({required this.command, required this.isHex, required this.eolMode, required this.delayMs});

  Map<String, dynamic> toJson() => {
    'command': command,
    'isHex': isHex,
    'eolMode': eolMode,
    'delayMs': delayMs,
  };

  factory MacroStep.fromJson(Map<String, dynamic> json) => MacroStep(
    command: json['command'],
    isHex: json['isHex'] ?? false,
    eolMode: json['eolMode'] ?? 'None',
    delayMs: json['delayMs'] ?? 0,
  );
}

class MacroState extends ChangeNotifier {
  late Directory _sequenceDir;

  bool _isRecording = false;
  List<MacroStep> _currentRecording = [];
  DateTime? _lastActionTime;

  bool _isPlaying = false;
  bool _isLooping = false;
  String? _currentlyPlayingFile;
  bool _shouldStopPlayback = false;

  int _loopIntervalMs = 1000;
  int get loopIntervalMs => _loopIntervalMs;

  int _loopCount = 0;
  int get loopCount => _loopCount;

  Completer<void>? _delayCompleter;
  Timer? _delayTimer;

  bool get isRecording => _isRecording;
  bool get isPlaying => _isPlaying;
  bool get isLooping => _isLooping;
  String? get currentlyPlayingFile => _currentlyPlayingFile;
  List<MacroStep> get currentRecording => _currentRecording;

  MacroState() {
    _initDirectory();
  }

  Future<void> _initDirectory() async {
    _sequenceDir = Directory('sequence');
    if (!await _sequenceDir.exists()) {
      await _sequenceDir.create();
    }
  }

  Future<List<String>> getSequenceFiles() async {
    if (!await _sequenceDir.exists()) return [];
    final files = _sequenceDir.listSync().whereType<File>().where((f) => f.path.endsWith('.sequence'));
    return files.map((f) => f.path.split(Platform.pathSeparator).last).toList();
  }

  Future<void> deleteMacro(String filename) async {
    final file = File('${_sequenceDir.path}${Platform.pathSeparator}$filename');
    if (await file.exists()) {
      await file.delete();
      notifyListeners();
    }
  }

  Future<void> updateMacro(String filename, List<MacroStep> steps) async {
    final file = File('${_sequenceDir.path}${Platform.pathSeparator}$filename');
    final jsonStr = jsonEncode(steps.map((e) => e.toJson()).toList());
    await file.writeAsString(jsonStr);
    notifyListeners();
  }

  Future<List<MacroStep>> loadMacroSteps(String filename) async {
    final file = File('${_sequenceDir.path}${Platform.pathSeparator}$filename');
    if (!await file.exists()) return [];
    try {
      final jsonStr = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList.map((e) => MacroStep.fromJson(e)).toList();
    } catch (e) {
      return [];
    }
  }

  void toggleLooping(bool val) {
    _isLooping = val;
    notifyListeners();
  }

  void setLoopInterval(int val) {
    _loopIntervalMs = val;
    notifyListeners();
  }

  void setLoopCount(int val) {
    _loopCount = val;
    notifyListeners();
  }

  // --- 录制逻辑 ---

  void startRecording() {
    _isRecording = true;
    _currentRecording = [];
    _lastActionTime = null;
    notifyListeners();
  }

  void recordStep(String command, bool isHex, String eolMode) {
    if (!_isRecording) return;
    
    int delay = 0;
    DateTime now = DateTime.now();
    if (_lastActionTime != null) {
      delay = now.difference(_lastActionTime!).inMilliseconds;
    }
    _lastActionTime = now; // 更新为最新指令发出的时间
    
    _currentRecording.add(MacroStep(command: command, isHex: isHex, eolMode: eolMode, delayMs: delay));
    notifyListeners();
  }

  Future<void> stopRecordingAndSave(String filename) async {
    _isRecording = false;
    if (_currentRecording.isEmpty) {
      notifyListeners();
      return;
    }
    
    if (!filename.endsWith('.sequence')) {
      filename += '.sequence';
    }
    final file = File('${_sequenceDir.path}${Platform.pathSeparator}$filename');
    
    final jsonStr = jsonEncode(_currentRecording.map((e) => e.toJson()).toList());
    await file.writeAsString(jsonStr);
    
    _currentRecording.clear();
    _lastActionTime = null;
    notifyListeners();
  }

  void cancelRecording() {
    _isRecording = false;
    _currentRecording.clear();
    _lastActionTime = null;
    notifyListeners();
  }

  // --- 回放逻辑 ---

  Future<void> _interruptibleDelay(int milliseconds) async {
    if (milliseconds <= 0) return;
    _delayCompleter = Completer<void>();
    _delayTimer = Timer(Duration(milliseconds: milliseconds), () {
      if (!(_delayCompleter?.isCompleted ?? true)) {
        _delayCompleter?.complete();
      }
    });
    await _delayCompleter?.future;
    _delayTimer?.cancel();
    _delayCompleter = null;
    _delayTimer = null;
  }

  Future<void> playMacro(String filename, Function(String command, bool isHex, String eolMode) sendCallback, Function(String) logCallback, bool Function() isConnectedCallback) async {
    if (_isPlaying) return;
    
    if (!isConnectedCallback()) {
      logCallback('\x1b[33m[Warning] 请先连接设备。\x1b[0m');
      return;
    }
    
    final file = File('${_sequenceDir.path}${Platform.pathSeparator}$filename');
    if (!await file.exists()) {
      logCallback('\x1b[31m[Error] 宏文件不存在: $filename\x1b[0m');
      return;
    }

    try {
      final jsonStr = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      final steps = jsonList.map((e) => MacroStep.fromJson(e)).toList();

      if (steps.isEmpty) {
        logCallback('\x1b[33m[Warning] 宏文件为空\x1b[0m');
        return;
      }

      _isPlaying = true;
      _shouldStopPlayback = false;
      _currentlyPlayingFile = filename;
      notifyListeners();

      logCallback('\x1b[32m[SYSTEM] 开始播放宏: $filename${_isLooping ? " (循环 ${_loopCount == 0 ? '无限' : _loopCount} 次)" : ""}\x1b[0m');

      int currentIteration = 0;
      do {
        for (int i = 0; i < steps.length; i++) {
          if (_shouldStopPlayback) break;
          
          final step = steps[i];
          
          // 如果是第一次迭代的第一条指令，通常不需要延迟，但在循环时可能需要。
          // 这里严格遵循录制时的间隔时间。
          if (step.delayMs > 0) {
            await _interruptibleDelay(step.delayMs);
          }
          
          if (_shouldStopPlayback) break;
          
          if (!isConnectedCallback()) {
            logCallback('\x1b[33m[SYSTEM] 设备断开，宏播放已自动中止。\x1b[0m');
            _shouldStopPlayback = true;
            break;
          }
          
          sendCallback(step.command, step.isHex, step.eolMode);
        }

        currentIteration++;
        if (_isLooping && _loopCount > 0 && currentIteration >= _loopCount) {
          break; // 达到了指定次数
        }

        if (_isLooping && !_shouldStopPlayback && _loopIntervalMs > 0) {
           await _interruptibleDelay(_loopIntervalMs);
        }
      } while (_isLooping && !_shouldStopPlayback);

      if (_shouldStopPlayback) {
         logCallback('\x1b[33m[SYSTEM] 宏播放已手动中止: $filename\x1b[0m');
      } else {
         logCallback('\x1b[32m[SYSTEM] 宏播放完毕: $filename\x1b[0m');
      }

    } catch (e) {
      logCallback('\x1b[31m[Error] 宏解析失败: $e\x1b[0m');
    } finally {
      _isPlaying = false;
      _currentlyPlayingFile = null;
      _shouldStopPlayback = false;
      notifyListeners();
    }
  }

  void stopPlayback() {
    _shouldStopPlayback = true;
    if (!(_delayCompleter?.isCompleted ?? true)) {
      _delayCompleter?.complete();
    }
    _delayTimer?.cancel();
    notifyListeners();
  }
}
