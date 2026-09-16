import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import '../utils/serial_port_primer.dart';
import '../utils/terminal_font_prefs.dart';
import 'terminal_session.dart';

class TerminalLine {
  String content;
  final DateTime timestamp;

  TerminalLine(this.content) : timestamp = DateTime.now();
}

class TerminalState extends ChangeNotifier implements TerminalSession {
  static const List<int> rollbackDepths = TerminalSession.rollbackDepths;

  TerminalState() {
    _loadFontDefaults();
  }

  /// 启动时读取用户保存的默认字体设置（terminal_font_settings.json 的 serial 节）
  Future<void> _loadFontDefaults() async {
    final prefs = await TerminalFontPrefs.load('serial');
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
      'serial',
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

  // Serial config
  String _serialPort = 'COM1';
  int _baudRate = 115200;
  int _dataBits = 8;
  double _stopBits = 1.0;
  String _parity = 'None';

  String get serialPort => _serialPort;
  int get baudRate => _baudRate;
  int get dataBits => _dataBits;
  double get stopBits => _stopBits;
  String get parity => _parity;

  // Logs
  final ListQueue<TerminalLine> _rawDataLog = ListQueue<TerminalLine>();
  final ListQueue<TerminalLine> _systemLog = ListQueue<TerminalLine>();
  int _systemLogSequence = 1;

  // Broadcast raw bytes for modules that need them (e.g., Oscilloscope)
  final StreamController<Uint8List> rawDataStreamController = StreamController<Uint8List>.broadcast();

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
    if (rollbackDepths.contains(limit) && _maxLines != limit) {
      _maxLines = limit;
      _trimLog(_rawDataLog);
      notifyListeners();
    }
  }

  void updateSerialConfig(String port, int baud) {
    _serialPort = port;
    _baudRate = baud;
    notifyListeners();
  }

  void updateSerialAdvancedConfig(int data, double stop, String p) {
    _dataBits = data;
    _stopBits = stop;
    _parity = p;
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

  // --- Input & History State ---
  final TextEditingController inputController = TextEditingController();
  final FocusNode inputFocusNode = FocusNode();
  final List<String> commandHistory = [];
  int historyIndex = -1;

  String _eolMode = 'CRLF';
  String get eolMode => _eolMode;
  void setEolMode(String val) {
    _eolMode = val;
    notifyListeners();
  }

  bool _isHexSendMode = false;
  bool get isHexSendMode => _isHexSendMode;
  void toggleHexSendMode(bool val) {
    _isHexSendMode = val;
    notifyListeners();
  }

  // Serial logic objects
  SerialPort? _port;
  SerialPortReader? _reader;

  void toggleConnection() {
    if (_isConnected) {
      _disconnect();
    } else {
      _connect();
    }
  }

  void _connect() {
    if (_serialPort.isEmpty) {
      addSystemLog('\x1b[1;91m[SYSTEM] 请先选择一个串口\x1b[0m');
      return;
    }
    try {
      _port = SerialPort(_serialPort);
      bool opened = _port!.openReadWrite();
      if (!opened) {
        // CP2105 等双口芯片的 Standard 口驱动默认波特率非法（1200），
        // 导致 libserialport 打开时内部 SetCommState 失败；先预置合法波特率再重试
        final err = SerialPort.lastError;
        if (primeSerialPortBaudRate(_serialPort, _baudRate)) {
          opened = _port!.openReadWrite();
          if (opened) {
            addSystemLog('\x1b[1;33m[SYSTEM] $_serialPort 首次打开失败，已通过预置波特率修复\x1b[0m');
          }
        }
        if (!opened) {
          addSystemLog('\x1b[1;91m[SYSTEM] 打开串口 $_serialPort 失败\x1b[0m');
          // SerialPort.lastError 在 Windows 上只是读取时刻的 GetLastError()，
          // 可能被失败后的其他系统调用覆盖（曾误报 code=0 操作成功完成）；
          // 改为立即探测端口独占打开的结果，拿不到时再回退 lastError
          final probeCode = probeSerialPortError(_serialPort);
          if (probeCode != null) {
            addSystemLog('\x1b[97m[SYSTEM] 错误详情: ${win32ErrorMessage(probeCode) ?? '未知错误'} (code=$probeCode)\x1b[0m');
          } else if (err != null && err.errorCode != 0) {
            addSystemLog('\x1b[97m[SYSTEM] 错误详情: ${win32ErrorMessage(err.errorCode) ?? err.message} (code=${err.errorCode})\x1b[0m');
          }
          _port = null;
          return;
        }
      }

      final config = _port!.config;
      config.baudRate = _baudRate;
      config.bits = _dataBits;

      switch (_stopBits) {
        case 1.0: config.stopBits = 1; break;
        case 2.0: config.stopBits = 2; break;
        case 1.5: config.stopBits = 3; break;
      }

      switch (_parity) {
        case 'None': config.parity = SerialPortParity.none; break;
        case 'Odd': config.parity = SerialPortParity.odd; break;
        case 'Even': config.parity = SerialPortParity.even; break;
        case 'Mark': config.parity = SerialPortParity.mark; break;
        case 'Space': config.parity = SerialPortParity.space; break;
      }

      _port!.config = config;

      _isConnected = true;
      _connectionStartTime = DateTime.now();
      addSystemLog('\x1b[1;32m[SYSTEM] Connected to $_serialPort ($_baudRate, $_dataBits${_parity.substring(0,1)}$_stopBits)\x1b[0m');

      _reader = SerialPortReader(_port!);
      _reader!.stream.listen((Uint8List data) {
        _handleIncomingData(data);
      }, onError: (e) {
        // 主动断开时 _isConnected 已置 false，流收尾触发的回调直接忽略
        if (!_isConnected) return;
        addSystemLog('\x1b[1;91m[SYSTEM] 致命错误: 设备通信中断，可能已被意外拔出！\x1b[0m');
        addSystemLog('\x1b[90m${describeSerialError(e)}\x1b[0m');
        _disconnect();
      }, onDone: () {
        if (!_isConnected) return;
        addSystemLog('\x1b[1;33m[SYSTEM] 串口已物理断开\x1b[0m');
        _disconnect();
      });

    } catch (e) {
      addSystemLog('\x1b[1;91m[SYSTEM] 无法连接到 $_serialPort: ${describeSerialError(e)}\x1b[0m');
      _disconnect();
    }
    notifyListeners();
  }

  void _disconnect() {
    if (!_isConnected) return;
    
    _isConnected = false;
    _connectionStartTime = null;

    try {
      if (_reader != null) {
        _reader!.close();
        _reader = null;
      }
      if (_port != null) {
        if (_port!.isOpen) _port!.close();
        _port!.dispose();
        _port = null;
      }
    } catch (e) {
      addSystemLog('\x1b[1;33m[SYSTEM] 端口释放异常 (忽略): $e\x1b[0m');
    }

    addSystemLog('\x1b[1;33m[SYSTEM] Disconnected\x1b[0m');
    notifyListeners();
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
    if (_port == null || !_port!.isOpen) {
      addSystemLog('\x1b[1;91m[SYSTEM] 发送失败：端口已失效或被拔出\x1b[0m');
      _disconnect();
      return;
    }
    try {
      _port!.write(Uint8List.fromList(data));
    } catch (e) {
      addSystemLog('\x1b[1;91m[SYSTEM] 发送异常：设备可能已被意外拔出！\x1b[0m');
      addSystemLog('\x1b[90m${describeSerialError(e)}\x1b[0m');
      _disconnect();
    }
  }

  void _handleIncomingData(Uint8List data) {
    // Broadcast raw bytes to listeners (e.g., Oscilloscope)
    rawDataStreamController.add(data);

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
