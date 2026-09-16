import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import '../utils/terminal_font_prefs.dart';
import 'terminal_session.dart';
import 'terminal_state.dart' show TerminalLine;

enum NetworkProtocol { tcp, ssh }

class NetworkTerminalState extends ChangeNotifier implements TerminalSession {
  NetworkTerminalState() {
    _loadFontDefaults();
  }

  /// 启动时读取用户保存的默认字体设置（terminal_font_settings.json 的 network 节）
  Future<void> _loadFontDefaults() async {
    final prefs = await TerminalFontPrefs.load('network');
    if (prefs == null) return;
    _fontSize = prefs.fontSize.clamp(8.0, 24.0);
    _lineHeight = prefs.lineHeight.clamp(0.5, 2.0);
    if (TerminalSession.fontFamilies.contains(prefs.fontFamily)) {
      _fontFamily = prefs.fontFamily;
    }
    notifyListeners();
  }

  int _maxLines = 20000;
  @override
  int get maxLines => _maxLines;

  // --- 输出区字体设置 ---
  double _fontSize = 12;
  double _lineHeight = 0.70;
  String _fontFamily = 'Consolas';

  @override
  double get fontSize => _fontSize;
  @override
  double get lineHeight => _lineHeight;
  @override
  String get fontFamily => _fontFamily;

  @override
  void setFontSize(double size) {
    final v = size.clamp(8.0, 24.0);
    if (_fontSize != v) {
      _fontSize = v;
      notifyListeners();
    }
  }

  @override
  void setLineHeight(double height) {
    final v = height.clamp(0.5, 2.0);
    if (_lineHeight != v) {
      _lineHeight = v;
      notifyListeners();
    }
  }

  @override
  void setFontFamily(String family) {
    if (TerminalSession.fontFamilies.contains(family) && _fontFamily != family) {
      _fontFamily = family;
      notifyListeners();
    }
  }

  @override
  void saveFontSettingsAsDefault() {
    TerminalFontPrefs.save(
      'network',
      TerminalFontPrefs(
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        fontFamily: _fontFamily,
      ),
    );
  }

  // --- Connection State ---
  bool _isConnected = false;
  DateTime? _connectionStartTime;
  bool _showTimestamp = false;

  @override
  FocusNode? commandFocusNode;

  @override
  bool get isConnected => _isConnected;
  @override
  DateTime? get connectionStartTime => _connectionStartTime;
  @override
  bool get showTimestamp => _showTimestamp;

  // Network config
  NetworkProtocol _protocol = NetworkProtocol.tcp;
  String _host = '192.168.1.100';
  int _port = 8080;
  String _username = '';
  String _password = '';

  NetworkProtocol get protocol => _protocol;
  String get host => _host;
  int get port => _port;
  String get username => _username;
  String get password => _password;

  // Logs
  final ListQueue<TerminalLine> _rawDataLog = ListQueue<TerminalLine>();
  final ListQueue<TerminalLine> _systemLog = ListQueue<TerminalLine>();
  int _systemLogSequence = 1;

  List<TerminalLine> get rawDataLog => _rawDataLog.toList();
  List<TerminalLine> get systemLog => _systemLog.toList();

  // 错误级系统日志计数：视图据此在面板隐藏时自动展开系统交互状态
  int _systemLogErrorCount = 0;
  int get systemLogErrorCount => _systemLogErrorCount;

  final List<String> _asciiCommandHistory = [];
  int _asciiHistoryIndex = -1;

  final List<String> _hexCommandHistory = [];
  int _hexHistoryIndex = -1;

  @override
  void setMaxLines(int limit) {
    if (TerminalSession.rollbackDepths.contains(limit) && _maxLines != limit) {
      _maxLines = limit;
      _trimLog(_rawDataLog);
      notifyListeners();
    }
  }

  void setProtocol(NetworkProtocol protocol) {
    if (_isConnected || _protocol == protocol) return;
    // 端口仍停留在另一协议的默认值时跟随切换
    if (_port == 22 || _port == 8080) {
      _port = protocol == NetworkProtocol.ssh ? 22 : 8080;
    }
    _protocol = protocol;
    notifyListeners();
  }

  void updateNetworkConfig(String host, int port) {
    _host = host;
    _port = port;
    notifyListeners();
  }

  void updateAuthConfig(String username, String password) {
    _username = username;
    _password = password;
    notifyListeners();
  }

  void toggleShowTimestamp(bool val) {
    _showTimestamp = val;
    notifyListeners();
  }

  bool _hexDisplay = false;
  bool get hexDisplay => _hexDisplay;

  void toggleHexDisplay(bool val) {
    _hexDisplay = val;
    notifyListeners();
  }

  // Connection objects
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  SSHClient? _sshClient;
  SSHSession? _sshSession;
  StreamSubscription<Uint8List>? _sshStdoutSub;
  StreamSubscription<Uint8List>? _sshStderrSub;

  void toggleConnection() {
    if (_isConnected) {
      _disconnect();
    } else {
      _connect();
    }
  }

  Future<void> _connect() async {
    if (_host.isEmpty) {
      addSystemLog('\x1b[1;91m[SYSTEM] 请填写主机地址\x1b[0m');
      return;
    }
    try {
      if (_protocol == NetworkProtocol.tcp) {
        addSystemLog('\x1b[90m[SYSTEM] 正在连接 $_host:$_port (TCP)...\x1b[0m');
        _socket = await Socket.connect(_host, _port, timeout: const Duration(seconds: 5));
        _isConnected = true;
        _connectionStartTime = DateTime.now();
        addSystemLog('\x1b[1;32m[SYSTEM] Connected to $_host:$_port (TCP)\x1b[0m');
        _socketSub = _socket!.listen((Uint8List data) {
          _handleIncomingData(data);
        }, onError: (e) {
          // 主动断开时 _isConnected 已置 false，流收尾触发的回调直接忽略
          if (!_isConnected) return;
          addSystemLog('\x1b[1;91m[SYSTEM] 连接中断: $e\x1b[0m');
          _disconnect();
        }, onDone: () {
          if (!_isConnected) return;
          addSystemLog('\x1b[1;33m[SYSTEM] 对端已关闭连接\x1b[0m');
          _disconnect();
        });
      } else {
        if (_username.isEmpty) {
          addSystemLog('\x1b[1;91m[SYSTEM] SSH 需要填写用户名\x1b[0m');
          return;
        }
        addSystemLog('\x1b[90m[SYSTEM] 正在连接 $_host:$_port (SSH)...\x1b[0m');
        final sshSocket = await SSHSocket.connect(_host, _port, timeout: const Duration(seconds: 5));
        _sshClient = SSHClient(
          sshSocket,
          username: _username,
          onPasswordRequest: () => _password,
        );
        _sshSession = await _sshClient!.shell(
          pty: const SSHPtyConfig(width: 120, height: 32),
        );
        _isConnected = true;
        _connectionStartTime = DateTime.now();
        addSystemLog('\x1b[1;32m[SYSTEM] Connected to $_username@$_host:$_port (SSH)\x1b[0m');
        _sshStdoutSub = _sshSession!.stdout.listen((Uint8List data) {
          _handleIncomingData(data);
        });
        _sshStderrSub = _sshSession!.stderr.listen((Uint8List data) {
          _handleIncomingData(data);
        });
        _sshSession!.done.then((_) {
          if (_isConnected) {
            addSystemLog('\x1b[1;33m[SYSTEM] SSH 会话已结束\x1b[0m');
            _disconnect();
          }
        });
      }
    } catch (e) {
      addSystemLog('\x1b[1;91m[SYSTEM] 无法连接到 $_host:$_port: $e\x1b[0m');
      _cleanupHandles();
    }
    notifyListeners();
  }

  void _disconnect() {
    if (!_isConnected) return;

    _isConnected = false;
    _connectionStartTime = null;
    _cleanupHandles();

    addSystemLog('\x1b[1;33m[SYSTEM] Disconnected\x1b[0m');
    notifyListeners();
  }

  void _cleanupHandles() {
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    _sshStdoutSub?.cancel();
    _sshStdoutSub = null;
    _sshStderrSub?.cancel();
    _sshStderrSub = null;
    _sshSession?.close();
    _sshSession = null;
    _sshClient?.close();
    _sshClient = null;
  }

  @override
  void sendCommand(String command, {bool isHex = false, String eolMode = 'None'}) {
    if (!_isConnected) return;

    String displayCommand = command;
    if (isHex) {
      displayCommand = '[HEX] ${command.toUpperCase()}';
    } else {
      String suffix = '';
      if (eolMode == 'CRLF') {
        suffix = '\\r\\n';
      } else if (eolMode == 'CR') {
        suffix = '\\r';
      } else if (eolMode == 'LF') {
        suffix = '\\n';
      }
      displayCommand = command + suffix;
    }

    final echoStr = '\x1b[1;36m> $displayCommand\x1b[0m';
    addRawData(echoStr);

    List<int> bytes = [];
    if (isHex) {
      String hexStr = command.replaceAll(' ', '');
      for (int i = 0; i < hexStr.length; i += 2) {
        if (i + 1 < hexStr.length) {
          bytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
        } else {
          bytes.add(int.parse('${hexStr.substring(i, i + 1)}0', radix: 16));
        }
      }
    } else {
      bytes = command.codeUnits.toList();
      if (eolMode == 'CRLF') { bytes.add(13); bytes.add(10); }
      else if (eolMode == 'CR') { bytes.add(13); }
      else if (eolMode == 'LF') { bytes.add(10); }
    }

    sendData(bytes);
  }

  void sendData(List<int> data) {
    if (!_isConnected) {
      addSystemLog('\x1b[1;91m[SYSTEM] 发送失败: 未连接\x1b[0m');
      return;
    }
    try {
      if (_protocol == NetworkProtocol.tcp) {
        _socket?.add(Uint8List.fromList(data));
      } else {
        _sshSession?.write(Uint8List.fromList(data));
      }
    } catch (e) {
      addSystemLog('\x1b[1;91m[SYSTEM] 发送异常：连接可能已中断！\x1b[0m');
      addSystemLog('\x1b[90m$e\x1b[0m');
      _disconnect();
    }
  }

  void _handleIncomingData(Uint8List data) {
    if (_rawDataLog.isEmpty) {
      _rawDataLog.addLast(TerminalLine(''));
    }

    if (_hexDisplay) {
      StringBuffer sb = StringBuffer();
      for (int byte in data) {
        String hexStr = byte.toRadixString(16).padLeft(2, '0').toUpperCase();
        sb.write('$hexStr ');
        if (byte == 0x0A) { // 换行符
          _rawDataLog.last.content += sb.toString();
          sb.clear();
          _rawDataLog.addLast(TerminalLine(''));
          if (_rawDataLog.length > _maxLines) _rawDataLog.removeFirst();
        }
      }
      if (sb.isNotEmpty) {
        _rawDataLog.last.content += sb.toString();
      }
    } else {
      String text = String.fromCharCodes(data);
      for (int i = 0; i < text.length; i++) {
        String char = text[i];
        if (char == '\n') {
          _rawDataLog.addLast(TerminalLine(''));
          if (_rawDataLog.length > _maxLines) _rawDataLog.removeFirst();
        } else if (char == '\r') {
          continue; // 忽略单独的 \r，避免产生未知字符占位框，依赖 \n 换行
        } else if (char == '\b') {
          if (_rawDataLog.last.content.isNotEmpty) {
            _rawDataLog.last.content = _rawDataLog.last.content.substring(0, _rawDataLog.last.content.length - 1);
          }
        } else if (char == '\t') {
          _rawDataLog.last.content += '    '; // 制表符转为4个空格
        } else {
          int codeUnit = char.codeUnitAt(0);
          // 过滤掉不可见的控制字符(0x00~0x1F)，但保留 ANSI 转义符(0x1B)
          if (codeUnit < 0x20 && codeUnit != 0x1B) continue;
          _rawDataLog.last.content += char;
        }
      }
    }
    notifyListeners();
  }

  void addRawData(String data) {
    if (_rawDataLog.isEmpty || _rawDataLog.last.content.isNotEmpty) {
      _rawDataLog.addLast(TerminalLine(data));
    } else {
      _rawDataLog.last.content += data;
    }
    _rawDataLog.addLast(TerminalLine(''));
    if (_rawDataLog.length > _maxLines) _rawDataLog.removeFirst();
    notifyListeners();
  }

  @override
  void addSystemLog(String data) {
    // 序列号为4位十进制数，最小值为0001，最大值为9999
    String seqStr = _systemLogSequence.toString().padLeft(4, '0');
    String formattedLog = '\x1b[90m[$seqStr]\x1b[0m $data';

    _systemLogSequence++;
    if (_systemLogSequence > 9999) _systemLogSequence = 1;

    // 亮红（1;91）前缀的是错误级日志，计数供视图自动展开面板
    if (data.contains('\x1b[1;91m')) _systemLogErrorCount++;

    _systemLog.addLast(TerminalLine(formattedLog));
    if (_systemLog.length > 2000) _systemLog.removeFirst();
    notifyListeners();
  }

  void _trimLog(ListQueue<TerminalLine> log) {
    while (log.length > _maxLines) {
      log.removeFirst();
    }
  }

  void clearTerminalOutput() {
    _rawDataLog.clear();
    notifyListeners();
  }

  void clearSystemLog() {
    _systemLog.clear();
    notifyListeners();
  }

  @override
  void addCommandToHistory(String command, {bool isHex = false}) {
    if (command.trim().isEmpty) return;

    final history = isHex ? _hexCommandHistory : _asciiCommandHistory;
    if (history.isEmpty || history.last != command) {
      history.add(command);
    }

    if (isHex) {
      _hexHistoryIndex = history.length;
    } else {
      _asciiHistoryIndex = history.length;
    }
  }

  @override
  String? getLatestCommand({bool isHex = false}) {
    final history = isHex ? _hexCommandHistory : _asciiCommandHistory;
    if (history.isEmpty) return null;
    if (isHex) {
      _hexHistoryIndex = history.length;
    } else {
      _asciiHistoryIndex = history.length;
    }
    return history.last;
  }

  @override
  String? getPreviousCommand({bool isHex = false}) {
    final history = isHex ? _hexCommandHistory : _asciiCommandHistory;
    int index = isHex ? _hexHistoryIndex : _asciiHistoryIndex;

    if (history.isEmpty) return null;
    if (index > 0) {
      index--;
      if (isHex) {
        _hexHistoryIndex = index;
      } else {
        _asciiHistoryIndex = index;
      }
      return history[index];
    }
    return history.first;
  }

  @override
  String? getNextCommand({bool isHex = false}) {
    final history = isHex ? _hexCommandHistory : _asciiCommandHistory;
    int index = isHex ? _hexHistoryIndex : _asciiHistoryIndex;

    if (history.isEmpty) return null;
    if (index < history.length - 1) {
      index++;
      if (isHex) {
        _hexHistoryIndex = index;
      } else {
        _asciiHistoryIndex = index;
      }
      return history[index];
    } else {
      if (isHex) {
        _hexHistoryIndex = history.length;
      } else {
        _asciiHistoryIndex = history.length;
      }
      return '';
    }
  }
}
