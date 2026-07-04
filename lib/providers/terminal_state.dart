import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

enum ConnectionMode { serial, network }

class TerminalLine {
  String content;
  final DateTime timestamp;

  TerminalLine(this.content) : timestamp = DateTime.now();
}

class TerminalState extends ChangeNotifier {
  static const List<int> rollbackDepths = [2000, 5000, 10000, 20000, 50000, 100000, 200000];
  
  int _maxLines = 20000;
  int get maxLines => _maxLines;

  // --- Connection State ---
  ConnectionMode _connectionMode = ConnectionMode.serial;
  bool _isConnected = false;
  DateTime? _connectionStartTime;
  bool _showTimestamp = false;
  
  FocusNode? commandFocusNode;

  ConnectionMode get connectionMode => _connectionMode;
  bool get isConnected => _isConnected;
  DateTime? get connectionStartTime => _connectionStartTime;
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

  // Network config
  String _networkIp = '192.168.1.100';
  int _networkPort = 8080;

  String get networkIp => _networkIp;
  int get networkPort => _networkPort;

  // Logs
  final ListQueue<TerminalLine> _rawDataLog = ListQueue<TerminalLine>();
  final ListQueue<TerminalLine> _systemLog = ListQueue<TerminalLine>();
  int _systemLogSequence = 1;

  // Broadcast raw bytes for modules that need them (e.g., Oscilloscope)
  final StreamController<Uint8List> rawDataStreamController = StreamController<Uint8List>.broadcast();

  List<TerminalLine> get rawDataLog => _rawDataLog.toList();
  List<TerminalLine> get systemLog => _systemLog.toList();

  final List<String> _asciiCommandHistory = [];
  int _asciiHistoryIndex = -1;

  final List<String> _hexCommandHistory = [];
  int _hexHistoryIndex = -1;

  void setMaxLines(int limit) {
    if (rollbackDepths.contains(limit) && _maxLines != limit) {
      _maxLines = limit;
      _trimLog(_rawDataLog);
      notifyListeners();
    }
  }

  void setConnectionMode(ConnectionMode mode) {
    if (_connectionMode != mode) {
      _connectionMode = mode;
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

  void updateNetworkConfig(String ip, int port) {
    _networkIp = ip;
    _networkPort = port;
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
    if (_connectionMode == ConnectionMode.serial) {
      if (_serialPort.isEmpty) {
        addSystemLog('\x1b[1;31m[SYSTEM] 请先选择一个串口\x1b[0m');
        return;
      }
      try {
        _port = SerialPort(_serialPort);
        if (!_port!.openReadWrite()) {
          addSystemLog('\x1b[1;31m[SYSTEM] 打开串口 $_serialPort 失败\x1b[0m');
          _port = null;
          return;
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
          addSystemLog('\x1b[1;31m[SYSTEM] 致命错误: 设备通信中断，可能已被意外拔出！\x1b[0m');
          addSystemLog('\x1b[90m$e\x1b[0m');
          _disconnect();
        }, onDone: () {
          addSystemLog('\x1b[1;33m[SYSTEM] 串口已物理断开\x1b[0m');
          _disconnect();
        });

      } catch (e) {
        addSystemLog('\x1b[1;31m[SYSTEM] 无法连接到 $_serialPort: $e\x1b[0m');
        _disconnect();
      }
    } else {
      // TODO: Network TCP Connection Implementation
      _isConnected = true;
      _connectionStartTime = DateTime.now();
      addSystemLog('\x1b[1;32m[SYSTEM] Connected to $_networkIp:$_networkPort (Mock)\x1b[0m');
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

    addSystemLog('\x1b[1;31m[SYSTEM] Disconnected\x1b[0m');
    notifyListeners();
  }

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
      addSystemLog('\x1b[1;31m[SYSTEM] 发送失败: 未连接\x1b[0m');
      return;
    }
    if (_connectionMode == ConnectionMode.serial) {
      if (_port == null || !_port!.isOpen) {
        addSystemLog('\x1b[1;31m[SYSTEM] 发送失败：端口已失效或被拔出\x1b[0m');
        _disconnect();
        return;
      }
      try {
        _port!.write(Uint8List.fromList(data));
      } catch (e) {
        addSystemLog('\x1b[1;31m[SYSTEM] 发送异常：设备可能已被意外拔出！\x1b[0m');
        addSystemLog('\x1b[90m$e\x1b[0m');
        _disconnect();
      }
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

  void addSystemLog(String data) {
    // 序列号为4位十进制数，最小值为0001，最大值为9999
    String seqStr = _systemLogSequence.toString().padLeft(4, '0');
    String formattedLog = '\x1b[90m[$seqStr]\x1b[0m $data';
    
    _systemLogSequence++;
    if (_systemLogSequence > 9999) _systemLogSequence = 1;

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
