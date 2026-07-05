import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'terminal_state.dart';
import '../modules/oscilloscope/models/protocol_decoder.dart';
import '../modules/oscilloscope/models/i2c_regfile.dart';
import '../modules/oscilloscope/models/uart_protocol_file.dart';
import '../utils/waveform_storage.dart';
import '../utils/demo_spi_generator.dart';
import 'dart:io';
import 'package:path/path.dart' as p;

enum TriggerMode { auto, normal, single }
enum TriggerSourceType { analog, digital }
enum TriggerEdge { rising, falling, both }
enum DigitalTriggerType { pinEdge, busValue, busSequence }

class DigitalTriggerConfig {
  DigitalTriggerType type;
  String? busName;
  int pinIndex; // for pinEdge type
  TriggerEdge edge; // for pinEdge type
  List<int> targetValues; // single value or sequence
  bool isBigEndian;
  bool enablePreTrigger;

  DigitalTriggerConfig({
    this.type = DigitalTriggerType.pinEdge,
    this.busName,
    this.pinIndex = 0,
    this.edge = TriggerEdge.rising,
    this.targetValues = const [],
    this.isBigEndian = false,
    this.enablePreTrigger = false,
  });
}


class BusSearchMatch {
  final double time;
  final int startIndex;
  final int endIndex;
  final String busName;

  BusSearchMatch({
    required this.time,
    required this.startIndex,
    required this.endIndex,
    required this.busName,
  });
}

class ChannelData {
  final int maxPoints;
  late Float32List points; // [y0, y1, ...]
  late Float32List chunkMins;
  late Float32List chunkMaxs;
  int head = 0; // The index of the next point to write (0 to maxPoints - 1)
  int count = 0; // Total points stored, maxes out at maxPoints
  int totalPointsAdded = 0; // Monotonically increasing counter for all points ever added
  bool isVisible = false;
  Color color;
  String? name; // Custom name for the channel
  
  double yScale = 0.1; // V/div scale factor (0.1 means 1 ADC unit = 0.1 pixels)
  double yOffset = 0.0; // Vertical offset

  ChannelData(this.maxPoints, this.color) {
    points = Float32List(maxPoints);
    int numChunks = (maxPoints / OscilloscopeState.chunkSize).ceil();
    chunkMins = Float32List(numChunks);
    chunkMaxs = Float32List(numChunks);
    for (int i = 0; i < numChunks; i++) {
      chunkMins[i] = double.infinity;
      chunkMaxs[i] = -double.infinity;
    }
  }

  void addPoint(double y) {
    points[head] = y;
    
    int chunkIdx = head ~/ OscilloscopeState.chunkSize;
    if (head % OscilloscopeState.chunkSize == 0) {
      chunkMins[chunkIdx] = y;
      chunkMaxs[chunkIdx] = y;
    } else {
      if (y < chunkMins[chunkIdx]) chunkMins[chunkIdx] = y;
      if (y > chunkMaxs[chunkIdx]) chunkMaxs[chunkIdx] = y;
    }

    head = (head + 1) % maxPoints;
    if (count < maxPoints) count++;
    totalPointsAdded++;
  }

  void clear() {
    head = 0;
    count = 0;
    totalPointsAdded = 0;
    for (int i = 0; i < chunkMins.length; i++) {
      chunkMins[i] = double.infinity;
      chunkMaxs[i] = -double.infinity;
    }
  }

  void restoreFromUnrolled(Float32List unrolled, int savedTotalPoints) {
    clear();
    
    int toCopy = math.min(unrolled.length, maxPoints);
    points.setAll(0, unrolled);
    
    count = toCopy;
    head = toCopy % maxPoints;
    totalPointsAdded = savedTotalPoints;
    
    // Re-calculate chunk mins and maxes
    for (int i = 0; i < toCopy; i++) {
      double y = unrolled[i];
      int chunkIdx = i ~/ OscilloscopeState.chunkSize;
      if (i % OscilloscopeState.chunkSize == 0) {
        chunkMins[chunkIdx] = y;
        chunkMaxs[chunkIdx] = y;
      } else {
        if (y < chunkMins[chunkIdx]) chunkMins[chunkIdx] = y;
        if (y > chunkMaxs[chunkIdx]) chunkMaxs[chunkIdx] = y;
      }
    }
  }
}

enum DigitalBusFormat { binary, decimal, hex, ascii }

class DigitalBus {
  String name;
  int startPin;
  int endPin;
  DigitalBusFormat format;
  double yOffset;
  double yScale;
  Color color;
  bool isExpanded;
  double savedCollapsedScale;
  Map<int, String> pinNames;
  ProtocolDecoder? decoder;

  DigitalBus({
    required this.name,
    required this.startPin,
    required this.endPin,
    required this.color,
    this.format = DigitalBusFormat.hex,
    this.yOffset = 100.0,
    this.yScale = 1.0,
    this.isExpanded = false,
    this.savedCollapsedScale = 1.0,
    Map<int, String>? pinNames,
    this.decoder,
  }) : pinNames = pinNames ?? {};

  bool containsPin(int pin) {
    int minPin = startPin < endPin ? startPin : endPin;
    int maxPin = startPin > endPin ? startPin : endPin;
    return pin >= minPin && pin <= maxPin;
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'startPin': startPin,
      'endPin': endPin,
      'format': format.index,
      'yOffset': yOffset,
      'yScale': yScale,
      'color': color.toARGB32(),
      'isExpanded': isExpanded,
      'savedCollapsedScale': savedCollapsedScale,
      'pinNames': pinNames.map((k, v) => MapEntry(k.toString(), v)),
      if (decoder != null) 'decoder': decoder!.toJson(),
    };
  }

  factory DigitalBus.fromJson(Map<String, dynamic> json) {
    Map<int, String> parsedPinNames = {};
    if (json['pinNames'] != null) {
      Map<String, dynamic> pnMap = json['pinNames'];
      pnMap.forEach((k, v) {
        parsedPinNames[int.parse(k)] = v.toString();
      });
    }

    return DigitalBus(
      name: json['name'] ?? 'Unknown',
      startPin: json['startPin'] ?? 0,
      endPin: json['endPin'] ?? 1,
      color: Color(json['color'] ?? 0xFF00FFFF),
      format: DigitalBusFormat.values[json['format'] ?? 0],
      yOffset: json['yOffset']?.toDouble() ?? 100.0,
      yScale: json['yScale']?.toDouble() ?? 1.0,
      isExpanded: json['isExpanded'] ?? false,
      savedCollapsedScale: json['savedCollapsedScale']?.toDouble() ?? 1.0,
      pinNames: parsedPinNames,
      decoder: json['decoder'] != null ? () {
        final dJson = json['decoder'];
        if (dJson['type'] == 'UART') return UartDecoder.fromJson(dJson);
        if (dJson['type'] == 'I2C') return I2cDecoder.fromJson(dJson);
        if (dJson['type'] == 'SPI') return SpiDecoder.fromJson(dJson);

        return null;
      }() : null,
    );
  }
}

class DigitalChannelData {
  final int maxPoints;
  late Uint32List states;
  late Uint32List chunkOrs;
  late Uint32List chunkAnds;
  int head = 0;
  int count = 0;
  int totalPointsAdded = 0;
  
  // Set of enabled pins (0-31) to draw. By default, none are shown until user selects them.
  Set<int> enabledPins = {}; 

  List<DigitalBus> buses = [];

  // The base Y offset for drawing each pin in the mixed canvas
  // Key: pin number, Value: baseline Y coordinate
  Map<int, double> pinYOffsets = {};
  Map<int, double> pinYScales = {}; // Multiplier for digital amplitude (1.0 to 5.0)
  Map<int, String> pinNames = {}; // Custom names for the digital pins

  DigitalChannelData(this.maxPoints) {
    states = Uint32List(maxPoints);
    int numChunks = (maxPoints / OscilloscopeState.chunkSize).ceil();
    chunkOrs = Uint32List(numChunks);
    chunkAnds = Uint32List(numChunks);
    for (int i = 0; i < numChunks; i++) {
      chunkOrs[i] = 0;
      chunkAnds[i] = 0xFFFFFFFF;
    }
    
    // Default Y offsets for pins
    for (int i = 0; i < 32; i++) {
      pinYOffsets[i] = 100.0 + i * 30.0; // stack them vertically
    }
  }

  void addPoint(int state) {
    states[head] = state;
    
    int chunkIdx = head ~/ OscilloscopeState.chunkSize;
    if (head % OscilloscopeState.chunkSize == 0) {
      chunkOrs[chunkIdx] = state;
      chunkAnds[chunkIdx] = state;
    } else {
      chunkOrs[chunkIdx] |= state;
      chunkAnds[chunkIdx] &= state;
    }

    head = (head + 1) % maxPoints;
    if (count < maxPoints) count++;
    totalPointsAdded++;
  }

  void clear() {
    head = 0;
    count = 0;
    totalPointsAdded = 0;
    for (int i = 0; i < chunkOrs.length; i++) {
      chunkOrs[i] = 0;
      chunkAnds[i] = 0xFFFFFFFF;
    }
  }

  void restoreFromUnrolled(Uint32List unrolled, int savedTotalPoints) {
    clear();
    
    int toCopy = math.min(unrolled.length, maxPoints);
    states.setAll(0, unrolled);
    
    count = toCopy;
    head = toCopy % maxPoints;
    totalPointsAdded = savedTotalPoints;
    
    // Re-calculate chunk ORs and ANDs
    for (int i = 0; i < toCopy; i++) {
      int state = unrolled[i];
      int chunkIdx = i ~/ OscilloscopeState.chunkSize;
      if (i % OscilloscopeState.chunkSize == 0) {
        chunkOrs[chunkIdx] = state;
        chunkAnds[chunkIdx] = state;
      } else {
        chunkOrs[chunkIdx] |= state;
        chunkAnds[chunkIdx] &= state;
      }
    }
  }
}

class OscilloscopeState extends ChangeNotifier {
  static const int maxChannels = 4;
  static const int maxPointsPerChannel = 8388608;
  static const int chunkSize = 4096;

  TerminalState? _terminalState;
  StreamSubscription<Uint8List>? _rawDataSubscription;

  bool _isPaused = false;
  bool get isPaused => _isPaused;

  bool _isDraggingMinimap = false;
  bool get isDraggingMinimap => _isDraggingMinimap;

  bool _isSingleShot = false;
  bool get isSingleShot => _isSingleShot;

  bool _isDemoMode = false;
  bool get isDemoMode => _isDemoMode;
  Timer? _demoTimer;
  Timer? _throttleTimer;
  int _lastNotifyTime = 0;
  int _demoCounter = 0;

  double _xScale = 1.0;
  double get xScale => _xScale;

  double _xScrollOffset = 0.0;
  double get xScrollOffset => _xScrollOffset;

  void setXScrollOffset(double offset) {
    _xScrollOffset = offset;
    if (_xScrollOffset < 0) _xScrollOffset = 0;
    
    double activeScale = _xScale;
    double minS = chartWidth / OscilloscopeState.maxPointsPerChannel;
    if (activeScale < minS) activeScale = minS;
    
    double maxScroll = latestX * activeScale - chartWidth;
    if (maxScroll < 0) maxScroll = 0;
    if (_xScrollOffset > maxScroll) _xScrollOffset = maxScroll;
    
    notifyListeners();
  }
  
  int get totalPointsAdded {
    int total = digitalChannel.totalPointsAdded;
    for (var ch in channels) {
      total += ch.totalPointsAdded;
    }
    return total;
  }

  int get maxCount {
    int count = digitalChannel.count;
    for (var ch in channels) {
      if (ch.count > count) {
        count = ch.count;
      }
    }
    return count;
  }

  double get latestX {
    int count = maxCount;
    return count > 0 ? (count - 1).toDouble() : 0.0;
  }

  int get minimapMaxPoints {
    if (_isPaused && maxCount > 0) {
      int mp = maxCount;
      if (mp < chartWidth) mp = chartWidth.toInt();
      return mp;
    }
    return maxPointsPerChannel;
  }

  int _triggerLevel = 2048;
  int get triggerLevel => _triggerLevel;

  int _selectedChannelIndex = 0;
  int get selectedChannelIndex => _selectedChannelIndex;

  TriggerMode _triggerMode = TriggerMode.auto;
  TriggerMode get triggerMode => _triggerMode;

  TriggerSourceType _triggerSourceType = TriggerSourceType.analog;
  TriggerSourceType get triggerSourceType => _triggerSourceType;

  int _triggerSourceIndex = 0; // 0-3 for analog, 0-31 for digital
  int get triggerSourceIndex => _triggerSourceIndex;

  TriggerEdge _triggerEdge = TriggerEdge.rising;
  TriggerEdge get triggerEdge => _triggerEdge;

  bool _isWaitingForTrigger = false;
  bool get isWaitingForTrigger => _isWaitingForTrigger;
  
  int _lastDigitalStateForTrigger = 0;
  double _lastAnalogStateForTrigger = 0.0;
  int _postTriggerCount = 0;

  void setTriggerMode(TriggerMode mode) {
    _triggerMode = mode;
    if (_triggerMode == TriggerMode.normal || _triggerMode == TriggerMode.single) {
      _armTrigger();
    } else {
      _isWaitingForTrigger = false;
      _isPaused = false;
    }
    notifyListeners();
  }

  void setTriggerSource(TriggerSourceType type, int index) {
    _triggerSourceType = type;
    _triggerSourceIndex = index;
    notifyListeners();
  }

  void setTriggerEdge(TriggerEdge edge) {
    _triggerEdge = edge;
    notifyListeners();
  }
  
  void forceTrigger() {
    if (_isWaitingForTrigger) {
      _isWaitingForTrigger = false;
      _postTriggerCount = 0;
      notifyListeners();
    }
  }

  void _armTrigger() {
    _isWaitingForTrigger = true;
    _postTriggerCount = 0;
    _isPaused = false;
    clearData();
  }


  double chartHeight = 600.0;
  double chartWidth = 800.0;

  void updateChartSize(double width, double height) {
    if (chartWidth != width || chartHeight != height) {
      chartWidth = width;
      chartHeight = height;
      notifyListeners();
    }
  }

  final List<ChannelData> channels = [
    ChannelData(maxPointsPerChannel, Colors.redAccent),
    ChannelData(maxPointsPerChannel, Colors.blueAccent),
    ChannelData(maxPointsPerChannel, Colors.greenAccent),
    ChannelData(maxPointsPerChannel, Colors.orangeAccent),
  ];

  late final DigitalChannelData digitalChannel = DigitalChannelData(maxPointsPerChannel);

  bool _showCursors = false;
  bool get showCursors => _showCursors;

  bool _showXCursors = true;
  bool get showXCursors => _showXCursors;

  bool _showYCursors = true;
  bool get showYCursors => _showYCursors;

  double _cursorX1 = 0.0; // Time in seconds
  double get cursorX1 => _cursorX1;

  double _cursorX2 = 0.001; // Time in seconds
  double get cursorX2 => _cursorX2;


  bool _linkCursors = false;
  bool get linkCursors => _linkCursors;

  void toggleLinkCursors() {
    _linkCursors = !_linkCursors;
    notifyListeners();
  }

  double _cursorY1 = 100.0;
  double get cursorY1 => _cursorY1;

  double _cursorY2 = 300.0;
  double get cursorY2 => _cursorY2;

  void toggleCursors() {
    _showCursors = !_showCursors;
    if (_showCursors) {
      _showXCursors = true;
      _showYCursors = false;
    }
    notifyListeners();
  }

  void toggleXCursors() {
    _showXCursors = !_showXCursors;
    notifyListeners();
  }

  void toggleYCursors() {
    _showYCursors = !_showYCursors;
    notifyListeners();
  }

  void setPaused(bool paused) {
    _isPaused = paused;
    notifyListeners();
  }

  void setDraggingMinimap(bool dragging) {
    if (_isDraggingMinimap != dragging) {
      _isDraggingMinimap = dragging;
      notifyListeners();
    }
  }

  void setXScale(double scale) {
    if (scale < 0.0001) scale = 0.0001;
    _xScale = scale;
    notifyListeners();
  }

  bool _snapToEdge = false;
  bool get snapToEdge => _snapToEdge;

  void toggleSnapToEdge() {
    _snapToEdge = !_snapToEdge;
    notifyListeners();
  }

  double _findNearestEdge(double t) {
    if (sampleRate <= 0) return t;
    int baseIdx = (t * sampleRate).round();
    
    double minScale = chartWidth / OscilloscopeState.maxPointsPerChannel;
    double activeScale = _xScale < minScale ? minScale : _xScale;
    
    int searchWindow = (4.0 / activeScale).ceil();
    if (searchWindow > 50000) searchWindow = 50000; // Limit search to prevent lag on extreme zoom out
    
    int maxIdx = digitalChannel.count - 1;
    int digitalStartIndex = digitalChannel.count == digitalChannel.maxPoints ? digitalChannel.head : 0;
    
    bool hasDigitalEdgeAt(int idx) {
      if (idx <= 0 || idx >= maxIdx) return false;
      int prevIdx = (digitalStartIndex + idx - 1) % digitalChannel.maxPoints;
      int currIdx = (digitalStartIndex + idx) % digitalChannel.maxPoints;
      
      return digitalChannel.states[prevIdx] != digitalChannel.states[currIdx];
    }
    
    bool hasAnalogZeroCrossingAt(int idx) {
      for (var ch in channels) {
        if (ch.isVisible && idx > 0 && idx < ch.count) {
          int analogStartIndex = ch.count == ch.maxPoints ? ch.head : 0;
          int prevIdx = (analogStartIndex + idx - 1) % ch.maxPoints;
          int currIdx = (analogStartIndex + idx) % ch.maxPoints;
          double prev = ch.points[prevIdx];
          double curr = ch.points[currIdx];
          if ((prev < 0 && curr >= 0) || (prev > 0 && curr <= 0)) return true;
        }
      }
      return false;
    }

    if (maxIdx > 0) {
      for (int offset = 0; offset <= searchWindow; offset++) {
        int rightIdx = baseIdx + offset;
        if (hasDigitalEdgeAt(rightIdx)) return rightIdx / sampleRate;
        int leftIdx = baseIdx - offset;
        if (offset > 0 && hasDigitalEdgeAt(leftIdx)) return leftIdx / sampleRate;
      }
    }
    
    for (int offset = 0; offset <= searchWindow; offset++) {
      int rightIdx = baseIdx + offset;
      if (hasAnalogZeroCrossingAt(rightIdx)) return rightIdx / sampleRate;
      int leftIdx = baseIdx - offset;
      if (offset > 0 && hasAnalogZeroCrossingAt(leftIdx)) return leftIdx / sampleRate;
    }

    return t;
  }

  void setCursorX1(double x) {
    if (_snapToEdge) x = _findNearestEdge(x);
    if (_linkCursors) {
      double diff = x - _cursorX1;
      _cursorX2 += diff;
    }
    _cursorX1 = x;
    notifyListeners();
  }

  void setCursorX2(double x) {
    if (_snapToEdge) x = _findNearestEdge(x);
    if (_linkCursors) {
      double diff = x - _cursorX2;
      _cursorX1 += diff;
    }
    _cursorX2 = x;
    notifyListeners();
  }

  bool get isCursorX1Visible {
    if (_sampleRate <= 0) return true;
    double activeScale = _xScale;
    double minS = chartWidth / maxPointsPerChannel;
    if (activeScale < minS) activeScale = minS;

    double latestX = 0;
    if (channels.isNotEmpty && channels[0].count > 0) {
      latestX = (channels[0].count - 1).toDouble();
    } else if (digitalChannel.count > 0) {
      latestX = (digitalChannel.count - 1).toDouble();
    }
    double translateX = chartWidth - latestX * activeScale + _xScrollOffset;
    double px1Raw = _cursorX1 * _sampleRate * activeScale + translateX;
    return px1Raw >= 0 && px1Raw <= chartWidth;
  }

  bool get isCursorX2Visible {
    if (_sampleRate <= 0) return true;
    double activeScale = _xScale;
    double minS = chartWidth / maxPointsPerChannel;
    if (activeScale < minS) activeScale = minS;

    double latestX = 0;
    if (channels.isNotEmpty && channels[0].count > 0) {
      latestX = (channels[0].count - 1).toDouble();
    } else if (digitalChannel.count > 0) {
      latestX = (digitalChannel.count - 1).toDouble();
    }
    double translateX = chartWidth - latestX * activeScale + _xScrollOffset;
    double px2Raw = _cursorX2 * _sampleRate * activeScale + translateX;
    return px2Raw >= 0 && px2Raw <= chartWidth;
  }

  void centerCursorX1() {
    if (_sampleRate <= 0) return;
    double activeScale = _xScale;
    double minS = chartWidth / maxPointsPerChannel;
    if (activeScale < minS) activeScale = minS;

    double latestX = 0;
    if (channels.isNotEmpty && channels[0].count > 0) {
      latestX = (channels[0].count - 1).toDouble();
    } else if (digitalChannel.count > 0) {
      latestX = (digitalChannel.count - 1).toDouble();
    }

    double newScrollOffset = latestX * activeScale - _cursorX1 * _sampleRate * activeScale - chartWidth / 2;
    setXScrollOffset(newScrollOffset);
  }

  void centerCursorX2() {
    if (_sampleRate <= 0) return;
    double activeScale = _xScale;
    double minS = chartWidth / maxPointsPerChannel;
    if (activeScale < minS) activeScale = minS;

    double latestX = 0;
    if (channels.isNotEmpty && channels[0].count > 0) {
      latestX = (channels[0].count - 1).toDouble();
    } else if (digitalChannel.count > 0) {
      latestX = (digitalChannel.count - 1).toDouble();
    }

    double newScrollOffset = latestX * activeScale - _cursorX2 * _sampleRate * activeScale - chartWidth / 2;
    setXScrollOffset(newScrollOffset);
  }

  void centerTime(double timeSeconds) {
    if (_sampleRate <= 0) return;
    double activeScale = _xScale;
    double minS = chartWidth / maxPointsPerChannel;
    if (activeScale < minS) activeScale = minS;

    double latestX = 0;
    if (channels.isNotEmpty && channels[0].count > 0) {
      latestX = (channels[0].count - 1).toDouble();
    } else if (digitalChannel.count > 0) {
      latestX = (digitalChannel.count - 1).toDouble();
    }

    double newScrollOffset = latestX * activeScale - timeSeconds * _sampleRate * activeScale - chartWidth / 2;
    setXScrollOffset(newScrollOffset);
  }

  void jumpToStart() {
    centerTime(0.0);
  }

  void jumpToTrigger() {
    int maxC = maxCount;
    if (maxC > 0 && _postTriggerCount <= maxC) {
      centerTime((maxC - _postTriggerCount) / _sampleRate);
    } else {
      centerTime(0.0);
    }
  }

  void jumpToEnd() {
    int maxC = maxCount;
    if (maxC > 0) {
      centerTime((maxC - 1) / _sampleRate);
    } else {
      centerTime(0.0);
    }
  }

  Timer? _scrollTimer;

  void startScrolling(double direction) {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      // 5% of chartWidth per tick
      double shift = chartWidth * 0.05 * -direction;
      setXScrollOffset(_xScrollOffset + shift);
    });
  }

  void stopScrolling() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
  }

  List<BusSearchMatch> searchMatches = [];
  Map<String, dynamic>? lastSearchConfig;
  int currentSearchMatchIndex = -1;
  
  Color _searchMatchColor = Colors.yellowAccent;
  Color get searchMatchColor => _searchMatchColor;
  void setSearchMatchColor(Color color) {
    _searchMatchColor = color;
    notifyListeners();
  }

  void jumpToNextSearchMatch() {
    if (searchMatches.isEmpty) return;
    currentSearchMatchIndex++;
    if (currentSearchMatchIndex >= searchMatches.length) {
      currentSearchMatchIndex = 0;
    }
    _applySearchMatch(searchMatches[currentSearchMatchIndex]);
  }

  void jumpToPrevSearchMatch() {
    if (searchMatches.isEmpty) return;
    currentSearchMatchIndex--;
    if (currentSearchMatchIndex < 0) {
      currentSearchMatchIndex = searchMatches.length - 1;
    }
    _applySearchMatch(searchMatches[currentSearchMatchIndex]);
  }

  void _applySearchMatch(BusSearchMatch match) {
    centerTime(match.time);
    setHighlight(match.busName, match.startIndex, match.endIndex);
    
    // Only open the event list if the bus actually has an enabled decoder
    try {
      var bus = digitalChannel.buses.firstWhere((b) => b.name == match.busName);
      if (bus.decoder != null && bus.decoder!.isEnabled) {
        if (_activeEventListBusName != match.busName) {
           _activeEventListBusName = match.busName;
        }
      }
    } catch (e) {
      // bus not found, ignore
    }
  }

  List<int> getDetectedI2cDevices(DigitalBus bus) {
    if (bus.decoder == null || !bus.decoder!.isEnabled || bus.decoder!.name != 'I2C') return [];
    Set<int> addrs = {};
    for (var p in bus.decoder!.packets) {
       if (p.type == PacketType.address && p.rawValue != null) {
          addrs.add(p.rawValue!);
       }
    }
    var list = addrs.toList();
    list.sort();
    return list;
  }

  List<int> getDetectedI2cRegisters(DigitalBus bus, int deviceAddress) {
    if (bus.decoder == null || !bus.decoder!.isEnabled || bus.decoder!.name != 'I2C') return [];
    Set<int> regs = {};
    for (var frame in bus.decoder!.frames) {
       int? currentAddr;
       bool isWrite = false;
       for (int i = 0; i < frame.packets.length; i++) {
          var p = frame.packets[i];
          if (p.type == PacketType.address) {
             currentAddr = p.rawValue;
             if (i + 1 < frame.packets.length && frame.packets[i+1].type == PacketType.readWrite) {
                 isWrite = frame.packets[i+1].data == 'WRITE';
                 i++; // Skip RW packet
             }
          } else if (p.type == PacketType.data && currentAddr == deviceAddress) {
             if (isWrite && p.rawValue != null) {
                 regs.add(p.rawValue!);
                 break; 
             }
          }
       }
    }
    var list = regs.toList();
    list.sort();
    return list;
  }

  void clearSearchMatches() {
    lastSearchConfig = null;
    searchMatches.clear();
    currentSearchMatchIndex = -1;
    _highlightedBusName = null;
    notifyListeners();
  }

  int searchAdvancedBusValue({
    required DigitalBus bus,
    required String format, 
    required String targetValueStr,
    required bool isBigEndian, 
    required String condition, 
    required String channel, 
    String? i2cFrameType, // 'Any', 'Write Only', 'Read Only'
    int? i2cDeviceAddress,
    int? i2cRegisterAddress,
    String? spiFrameType,
    int? spiCommand,
    int? spiAddress,
    String? uartField,
  }) {
    searchMatches.clear();
    currentSearchMatchIndex = -1;
    if (digitalChannel.count == 0 || _sampleRate <= 0) return 0;

    List<int> targetSequence = [];
    if (format == 'ASCII') {
       for (int i = 0; i < targetValueStr.length; i++) {
          targetSequence.add(targetValueStr.codeUnitAt(i));
       }
    } else {
       String input = targetValueStr.trim();
       if (input.isNotEmpty && condition != 'Error') {
         List<String> parts = input.split(RegExp(r'\s+'));
         for (String part in parts) {
           try {
              if (format == 'Hex' && !part.toLowerCase().startsWith('0x')) {
                part = '0x$part';
              } else if (format == 'Bin' && !part.toLowerCase().startsWith('0b')) {
                part = '0b$part';
              }

              if (part.toLowerCase().startsWith('0x')) {
                targetSequence.add(int.parse(part.substring(2), radix: 16));
              } else if (part.toLowerCase().startsWith('0b')) {
               targetSequence.add(int.parse(part.substring(2), radix: 2));
             } else {
               targetSequence.add(int.parse(part));
             }
           } catch (e) {
             // skip invalid parts or return 0
           }
         }
       }
    }

    bool hasDecoder = bus.decoder != null && bus.decoder!.isEnabled;
    String decoderType = bus.decoder?.name ?? '';

    if (hasDecoder) {
      if (decoderType == 'UART') {
        UartDecoder uDecoder = bus.decoder as UartDecoder;
        UartProtocolFile? protocol;
        if (uDecoder.protocolFile != null) {
          protocol = availableUartProtocols[uDecoder.protocolFile!];
        }

        if (protocol != null && uartField != null && uartField != 'Any') {
          // Search by UART field within parsed frames
          for (var frame in uDecoder.frames) {
            bool isTx = frame.summary.startsWith('Tx');
            if (channel == 'TXD' && !isTx) continue;
            if (channel == 'RXD' && isTx) continue;

            List<ProtocolPacket> dataPackets = frame.packets.where((p) => p.type == PacketType.data && p.rawValue != null).toList();
            
            bool headerMatch = true;
            for (int j = 0; j < protocol.header.length; j++) {
              if (j >= dataPackets.length || dataPackets[j].rawValue != protocol.header[j]) {
                headerMatch = false;
                break;
              }
            }
            if (!headerMatch || dataPackets.length <= protocol.header.length) continue;
            
            int cmdId = dataPackets[protocol.header.length].rawValue!;
            var cmdDef = protocol.commands[cmdId];
            if (cmdDef == null) continue;
            
            var packetDef = isTx ? cmdDef.tx : cmdDef.rx;
            
            if (uartField == 'CMD') {
               if (protocol.header.length < dataPackets.length) {
                 var p = dataPackets[protocol.header.length];
                 if (targetSequence.isEmpty || targetSequence.first == p.rawValue) {
                    searchMatches.add(BusSearchMatch(time: p.startIndex / _sampleRate, startIndex: p.startIndex, endIndex: p.endIndex, busName: bus.name));
                 }
               }
               continue;
            }

            if (packetDef == null) continue;

            for (var fieldDef in packetDef.payload) {
              if (fieldDef.name == uartField) {
                 if (fieldDef.byteOffset < dataPackets.length) {
                    var p = dataPackets[fieldDef.byteOffset];
                    if (targetSequence.isEmpty || targetSequence.first == p.rawValue) {
                       searchMatches.add(BusSearchMatch(time: p.startIndex / _sampleRate, startIndex: p.startIndex, endIndex: p.endIndex, busName: bus.name));
                    }
                 }
                 break;
              }
            }
          }
        } else {
          // Normal packet-by-packet search
          List<ProtocolPacket> packets = uDecoder.packets;
          for (int i = 0; i < packets.length; i++) {
            var p = packets[i];
            if (channel == 'TXD' && !p.data.startsWith('Tx:')) continue;
            if (channel == 'RXD' && !p.data.startsWith('Rx:')) continue;

            if (condition == 'Error') {
               if (p.type == PacketType.error) {
                 searchMatches.add(BusSearchMatch(time: p.startIndex / _sampleRate, startIndex: p.startIndex, endIndex: p.endIndex, busName: bus.name));
               }
            } else if (condition == 'Data') {
               if (p.type == PacketType.data) {
                  if (targetSequence.isEmpty) {
                     searchMatches.add(BusSearchMatch(time: p.startIndex / _sampleRate, startIndex: p.startIndex, endIndex: p.endIndex, busName: bus.name));
                  } else {
                     bool match = true;
                     int seqIndex = 0;
                     int endIdx = p.endIndex;
                     for (int j = 0; j < packets.length - i; j++) {
                        var nextP = packets[i+j];
                        bool isStartTx = p.data.startsWith('Tx:');
                        bool isStartRx = p.data.startsWith('Rx:');
                        bool isNextTx = nextP.data.startsWith('Tx:');
                        bool isNextRx = nextP.data.startsWith('Rx:');
                        
                        // Sequence must stay on the same channel (TX or RX) as the starting packet
                        if (isStartTx && !isNextTx) continue;
                        if (isStartRx && !isNextRx) continue;

                        if (nextP.type != PacketType.data || nextP.rawValue != targetSequence[seqIndex]) {
                           match = false; break;
                        }
                        endIdx = nextP.endIndex;
                        seqIndex++;
                        if (seqIndex == targetSequence.length) break;
                     }
                     if (match && seqIndex == targetSequence.length) {
                        searchMatches.add(BusSearchMatch(time: p.startIndex / _sampleRate, startIndex: p.startIndex, endIndex: endIdx, busName: bus.name));
                     }
                  }
               }
            }
          }
        }
      } else if (decoderType == 'SPI') {
        dynamic protocol;
        String? protoFile = (bus.decoder as SpiDecoder).protocolFile;
        if (protoFile != null) {
           for (var r in availableSpiRegfiles) {
             if (r.name == protoFile) { protocol = r; break; }
           }
        }
        for (var frame in bus.decoder!.frames) {
          int? frameCmd;
          int? frameAddr;
          String access = '';
          
          bool hasCmd = false;
          for (var p in frame.packets) {
             if (p.type == PacketType.data && p.data.startsWith('CMD:') && p.rawValue != null) {
                frameCmd = p.rawValue;
                hasCmd = true;
                if (protocol != null && protocol.registers.containsKey(frameCmd)) {
                   access = protocol.registers[frameCmd]!.access ?? '';
                }
             } else if (hasCmd && p.type == PacketType.data && p.data.startsWith('ADDR:') && p.rawValue != null) {
                frameAddr = p.rawValue;
                break;
             }
          }
          
          // Conditions
          if (spiCommand != null && frameCmd != spiCommand) continue;
          if (spiFrameType == 'Write Only' && !access.contains('W')) continue;
          if (spiFrameType == 'Read Only' && !access.contains('R')) continue;
          if (spiFrameType == 'MOSI' && !frame.summary.startsWith('MOSI')) continue;
          if (spiFrameType == 'MISO' && !frame.summary.startsWith('MISO')) continue;
          if (spiAddress != null && frameAddr != spiAddress) continue;
          
          if (targetSequence.isNotEmpty) {
             bool foundSequence = false;
             int matchStartIndex = -1;
             int matchEndIndex = -1;
             
             List<ProtocolPacket> searchablePackets = [];
             for (var p in frame.packets) {
                if (p.type == PacketType.data && p.data.startsWith('DATA:') && p.rawValue != null) {
                   searchablePackets.add(p);
                } else if (p.type == PacketType.data && (p.data.startsWith('MOSI:') || p.data.startsWith('MISO:')) && p.rawValue != null) {
                   searchablePackets.add(p);
                }
             }
             
             if (targetSequence.length == 1) {
                for (var p in searchablePackets) {
                   if (p.rawValue == targetSequence[0]) {
                      foundSequence = true;
                      matchStartIndex = p.startIndex;
                      matchEndIndex = p.endIndex;
                      break;
                   }
                }
             } else {
                for (int i = 0; i <= searchablePackets.length - targetSequence.length; i++) {
                   bool match = true;
                   for (int j = 0; j < targetSequence.length; j++) {
                      if (searchablePackets[i+j].rawValue != targetSequence[j]) {
                         match = false;
                         break;
                      }
                   }
                   if (match) {
                      foundSequence = true;
                      matchStartIndex = searchablePackets[i].startIndex;
                      matchEndIndex = searchablePackets[i+targetSequence.length-1].endIndex;
                      break;
                   }
                }
             }
             
             if (!foundSequence) continue;
             searchMatches.add(BusSearchMatch(time: matchStartIndex / _sampleRate, startIndex: matchStartIndex, endIndex: matchEndIndex, busName: bus.name));
          } else {
             int matchStartIndex = frame.startIndex;
             int matchEndIndex = frame.endIndex;
             
             if (spiAddress != null) {
                for (var p in frame.packets) {
                   if (p.type == PacketType.data && p.data.startsWith('ADDR:') && p.rawValue == spiAddress) {
                      matchStartIndex = p.startIndex; matchEndIndex = p.endIndex; break;
                   }
                }
             } else if (spiCommand != null) {
                for (var p in frame.packets) {
                   if (p.type == PacketType.data && p.data.startsWith('CMD:') && p.rawValue == spiCommand) {
                      matchStartIndex = p.startIndex; matchEndIndex = p.endIndex; break;
                   }
                }
             }
             searchMatches.add(BusSearchMatch(time: matchStartIndex / _sampleRate, startIndex: matchStartIndex, endIndex: matchEndIndex, busName: bus.name));
          }
        }
      } else if (decoderType == 'I2C') {
        for (var frame in bus.decoder!.frames) {
          int? frameDevAddr;
          String rw = '';
          int? frameRegAddr;
          List<int> frameData = [];
          
          bool isWritePhase = false;
          bool isFirstData = true;

          for (int i = 0; i < frame.packets.length; i++) {
            var p = frame.packets[i];
            if (p.type == PacketType.address) {
               frameDevAddr = p.rawValue;
               isFirstData = true;
               if (i + 1 < frame.packets.length && frame.packets[i+1].type == PacketType.readWrite) {
                 rw = frame.packets[i+1].data;
                 isWritePhase = (rw == 'WRITE');
               }
            } else if (p.type == PacketType.data) {
               if (isWritePhase && isFirstData) {
                 frameRegAddr = p.rawValue;
                 isFirstData = false;
               } else {
                 if (p.rawValue != null) frameData.add(p.rawValue!);
               }
            }
          }
          
          // Conditions
          if (i2cDeviceAddress != null && frameDevAddr != i2cDeviceAddress) continue;
          if (i2cFrameType == 'Write Only' && rw != 'WRITE') continue;
          if (i2cFrameType == 'Read Only' && rw != 'READ') continue;
          if (i2cRegisterAddress != null && frameRegAddr != i2cRegisterAddress) continue;
          
          if (targetSequence.isNotEmpty) {
             bool foundSequence = false;
             int matchStartIndex = -1;
             int matchEndIndex = -1;
             
             List<ProtocolPacket> searchablePackets = [];
             bool isFirst = true;
             for (int idx = 0; idx < frame.packets.length; idx++) {
                var p = frame.packets[idx];
                if (p.type == PacketType.data && p.rawValue != null) {
                   if (isWritePhase && isFirst) {
                      isFirst = false;
                      // Include register address in searchable packets
                      searchablePackets.add(p);
                   } else {
                      searchablePackets.add(p);
                   }
                }
             }
             
             if (targetSequence.length == 1) {
                for (var p in searchablePackets) {
                   if (p.rawValue == targetSequence[0]) {
                      foundSequence = true;
                      matchStartIndex = p.startIndex;
                      matchEndIndex = p.endIndex;
                      break;
                   }
                }
             } else {
                for (int i = 0; i <= searchablePackets.length - targetSequence.length; i++) {
                   bool match = true;
                   for (int j = 0; j < targetSequence.length; j++) {
                      if (searchablePackets[i+j].rawValue != targetSequence[j]) {
                         match = false;
                         break;
                      }
                   }
                   if (match) {
                      foundSequence = true;
                      matchStartIndex = searchablePackets[i].startIndex;
                      matchEndIndex = searchablePackets[i+targetSequence.length-1].endIndex;
                      break;
                   }
                }
             }
             
             if (!foundSequence) continue;
             searchMatches.add(BusSearchMatch(time: matchStartIndex / _sampleRate, startIndex: matchStartIndex, endIndex: matchEndIndex, busName: bus.name));
          } else {
             int matchStartIndex = frame.startIndex;
             int matchEndIndex = frame.endIndex;
             
             if (i2cRegisterAddress != null) {
                for (var p in frame.packets) {
                   if (p.type == PacketType.data && p.rawValue == i2cRegisterAddress) {
                      matchStartIndex = p.startIndex; matchEndIndex = p.endIndex; break;
                   }
                }
             } else if (i2cDeviceAddress != null) {
                for (var p in frame.packets) {
                   if (p.type == PacketType.address && p.rawValue == i2cDeviceAddress) {
                      matchStartIndex = p.startIndex; matchEndIndex = p.endIndex; break;
                   }
                }
             }
             searchMatches.add(BusSearchMatch(time: matchStartIndex / _sampleRate, startIndex: matchStartIndex, endIndex: matchEndIndex, busName: bus.name));
          }
        }
      }
    } else {
      List<int> target = targetSequence.isNotEmpty ? targetSequence : [0];
      int numPins = (bus.startPin - bus.endPin).abs() + 1;
      int step = bus.startPin < bus.endPin ? 1 : -1;
      int startIndex = digitalChannel.count == digitalChannel.maxPoints ? digitalChannel.head : 0;
      
      List<Map<String, dynamic>> busChanges = [];
      int lastBusVal = -1;
      for (int i = 0; i < digitalChannel.count; i++) {
        int idx = (startIndex + i) % digitalChannel.maxPoints;
        int state = digitalChannel.states[idx];
        
        int busVal = 0;
        for (int p = 0; p < numPins; p++) {
          int physicalPin = bus.startPin + p * step;
          int bitVal = (state >> physicalPin) & 1;
          int targetBitPosition = isBigEndian ? (numPins - 1 - p) : p;
          busVal |= (bitVal << targetBitPosition);
        }
        
        if (busVal != lastBusVal) {
          busChanges.add({'index': i, 'val': busVal});
          lastBusVal = busVal;
        }
      }
      
      if (busChanges.isNotEmpty) {
         for (int i = 0; i <= busChanges.length - target.length; i++) {
            bool match = true;
            for (int j = 0; j < target.length; j++) {
               if (busChanges[i + j]['val'] != target[j]) {
                  match = false;
                  break;
               }
            }
            if (match) {
               int matchStartIndex = busChanges[i]['index'];
               int matchEndIndex;
               if (i + target.length < busChanges.length) {
                  matchEndIndex = busChanges[i + target.length]['index'] - 1;
               } else {
                  matchEndIndex = digitalChannel.count - 1;
               }
               searchMatches.add(BusSearchMatch(
                 time: matchStartIndex / _sampleRate,
                 startIndex: matchStartIndex,
                 endIndex: matchEndIndex,
                 busName: bus.name
               ));
            }
         }
      }
    }

    if (searchMatches.isNotEmpty) {
       currentSearchMatchIndex = 0;
       _applySearchMatch(searchMatches[0]);
    }
    notifyListeners();
    return searchMatches.length;
  }
  void forceUpdate() {
    notifyListeners();
  }



  void setCursorY1(double y) {
    _cursorY1 = y;
    notifyListeners();
  }

  void setCursorY2(double y) {
    _cursorY2 = y;
    notifyListeners();
  }


  double _sampleRate = 500000.0;
  double get sampleRate => _sampleRate;

  String? _activeEventListBusName;
  String? get activeEventListBusName => _activeEventListBusName;

  void toggleEventList(String? busName) {
    if (_activeEventListBusName == busName) {
      _activeEventListBusName = null;
    } else {
      _activeEventListBusName = busName;
    }
    notifyListeners();
  }
  
  String? _highlightedBusName;
  String? get highlightedBusName => _highlightedBusName;
  
  int? _highlightedStartIndex;
  int? get highlightedStartIndex => _highlightedStartIndex;

  int? _highlightedEndIndex;
  int? get highlightedEndIndex => _highlightedEndIndex;
  
  int _highlightTriggerSequence = 0;
  int get highlightTriggerSequence => _highlightTriggerSequence;

  bool _showRegisterInfoPanel = true;
  bool get showRegisterInfoPanel => _showRegisterInfoPanel;

  void setHighlight(String? busName, int? start, int? end) {
    _highlightedBusName = busName;
    _highlightedStartIndex = start;
    _highlightedEndIndex = end;
    _highlightTriggerSequence++;
    
    _showRegisterInfoPanel = false;
    if (busName != null) {
      try {
        var bus = digitalChannel.buses.firstWhere((b) => b.name == busName);
        if (bus.decoder != null && bus.decoder!.isEnabled) {
          _showRegisterInfoPanel = true;
        }
      } catch (_) {
        // bus not found, ignore
      }
    }
    
    notifyListeners();
  }
  
  void closeRegisterInfoPanel() {
    _showRegisterInfoPanel = false;
    notifyListeners();
  }
  
  void setSampleRate(double rate) {
    _sampleRate = rate;
    decodeAllProtocols();
    notifyListeners();
  }

  void decodeAllProtocols() {
    int absoluteOffset = digitalChannel.totalPointsAdded - digitalChannel.count;
    for (var bus in digitalChannel.buses) {
      if (bus.decoder != null && bus.decoder!.isEnabled) {
        bus.decoder!.lastDecodeAbsoluteOffset = absoluteOffset;
        
        if (bus.decoder is SpiDecoder) {
          String? pf = (bus.decoder as SpiDecoder).protocolFile;
          if (pf != null && pf.isNotEmpty) {
            try {
              var regfile = availableSpiRegfiles.firstWhere((r) => r.name == pf);
              (bus.decoder as SpiDecoder).protocolData = { 'registers': regfile.registers };
            } catch (_) {}
          } else {
            (bus.decoder as SpiDecoder).protocolData = null;
          }
        }

        bus.decoder!.decode(digitalChannel.states, digitalChannel.head, digitalChannel.count, _sampleRate);
      }
    }
  }

  void setI2cDeviceAlias(String busName, int address, String alias) {
     var busIndex = digitalChannel.buses.indexWhere((b) => b.name == busName);
     if (busIndex < 0) return;
     var bus = digitalChannel.buses[busIndex];
     if (bus.decoder is I2cDecoder) {
         if (alias.isEmpty) {
             (bus.decoder as I2cDecoder).deviceAliases.remove(address);
         } else {
             (bus.decoder as I2cDecoder).deviceAliases[address] = alias;
         }
         decodeAllProtocols();
         notifyListeners();
     }
  }

  List<I2cRegfile> availableRegfiles = [];
  List<I2cRegfile> availableSpiRegfiles = [];
  Map<String, UartProtocolFile> availableUartProtocols = {};
  // busName -> (address -> Regfile)
  Map<String, Map<int, I2cRegfile>> mountedRegfiles = {};

  Future<void> loadRegfiles() async {
    String dirPath = p.join(Directory.current.path, 'DeviceProtocol', 'I2C');
    availableRegfiles = await I2cRegfile.loadFromDirectory(dirPath);

    String uartDirPath = p.join(Directory.current.path, 'DeviceProtocol', 'Uart');
    List<UartProtocolFile> uartFiles = await UartProtocolFile.loadFromDirectory(uartDirPath);
    availableUartProtocols.clear();
    for (var u in uartFiles) {
      if (u.filename != null) {
        availableUartProtocols[u.filename!] = u;
      }
    }

    String spiDirPath = p.join(Directory.current.path, 'DeviceProtocol', 'SPI');
    availableSpiRegfiles = await I2cRegfile.loadFromDirectory(spiDirPath);

    notifyListeners();
  }

  void mountI2cDevice(String busName, int address, I2cRegfile? regfile) {
    if (!mountedRegfiles.containsKey(busName)) {
      mountedRegfiles[busName] = {};
    }
    if (regfile == null) {
      mountedRegfiles[busName]!.remove(address);
    } else {
      mountedRegfiles[busName]![address] = regfile;
    }
    notifyListeners();
  }

  I2cRegfile? getRegfileFor(String busName, int address) {
    if (mountedRegfiles[busName]?.containsKey(address) == true) {
      return mountedRegfiles[busName]![address];
    }
    for (var rf in availableRegfiles) {
      if (rf.addresses != null && rf.addresses!.contains(address)) {
        return rf;
      }
    }
    return null;
  }


  OscilloscopeState(TerminalState terminalState) {
    updateTerminalState(terminalState);
    loadRegfiles();
  }

  void updateTerminalState(TerminalState terminalState) {
    if (_terminalState == terminalState) return;
    
    _rawDataSubscription?.cancel();
    _terminalState = terminalState;
    _rawDataSubscription = _terminalState!.rawDataStreamController.stream.listen((data) {
      if (!_isDemoMode) {
        _handleIncomingRawData(data);
      }
    });
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _rawDataSubscription?.cancel();
    _demoTimer?.cancel();
    super.dispose();
  }

  void togglePause() {
    _isPaused = !_isPaused;
    if (_isPaused) {
      _isSingleShot = false;
      decodeAllProtocols();
    } else {
      if (_triggerMode == TriggerMode.single) {
        _triggerMode = TriggerMode.auto;
      }
      if (_triggerMode == TriggerMode.normal) {
        _armTrigger();
      } else {
        _isWaitingForTrigger = false;
      }
    }
    notifyListeners();
  }

  void singleShot() {
    _isSingleShot = true;
    setTriggerMode(TriggerMode.single);
  }

  void toggleDemoMode() {
    _isDemoMode = !_isDemoMode;
    if (_isDemoMode) {
      _startDemoStream();
    } else {
      _demoTimer?.cancel();
    }
    notifyListeners();
  }

  int resetCount = 0;

  void resetToDefault() {
    resetCount++;
    _xScale = 1.0;
    _xScrollOffset = 0.0;
    _triggerLevel = 2048;
    _showCursors = false;
    for (var ch in channels) {
      ch.yScale = 0.1;
      ch.yOffset = 0.0;
    }
    notifyListeners();
  }

  void _startDemoStream() {
    _demoTimer?.cancel();
    _demoCounter = 0;
    
    // Virtual sample rate: 500 kSPS (2 us per point) to support 22kHz signals
    const double fs = 500000.0;
    const double dt = 1.0 / fs;
    const int pointsPerTick = 4000; // 8ms worth of data per 16ms tick (slowed down for rendering if needed, or we can send real-time)

    int voltageToADC(double v) {
      // Assuming front-end is fixed to +/- 10V span
      int adc = ((v + 10.0) / 20.0 * 4095).round();
      if (adc < 0) return 0;
      if (adc > 4095) return 4095;
      return adc;
    }

    // Precompute I2C test waveform for D0 (SCL) and D1 (SDA)
    List<int> i2cSequence = [];
    void addI2CBit(int scl, int sda, int duration) {
      int state = (sda << 1) | (scl << 0);
      for (int i = 0; i < duration; i++) {
        i2cSequence.add(state);
      }
    }
    void i2cStart() {
      addI2CBit(1, 1, 1);
      addI2CBit(1, 0, 2);
      addI2CBit(0, 0, 2);
    }
    void i2cStop() {
      addI2CBit(0, 0, 2);
      addI2CBit(1, 0, 2);
      addI2CBit(1, 1, 1);
    }
    void i2cBit(int bit) {
      addI2CBit(0, bit, 2);
      addI2CBit(1, bit, 3);
    }
    void i2cByte(int byte) {
      for (int i = 7; i >= 0; i--) {
        i2cBit((byte >> i) & 1);
      }
    }

    addI2CBit(1, 1, 10); // Idle
    
    void writeI2cReg(int devAddr8, int regAddr, int regValue) {
      i2cStart();
      i2cByte(devAddr8);
      i2cBit(0); // ACK
      i2cByte(regAddr);
      i2cBit(0); // ACK
      i2cByte(regValue);
      i2cBit(0); // ACK
      i2cStop();
      addI2CBit(1, 1, 15); // Idle between transactions
    }

    // 1. Configure TCA9548A MUX to enable Channel 3
    // Mux Address is 0x70 -> Write Address is 0xE0
    // Mux uses a direct control register write (no reg addr)
    i2cStart();
    i2cByte(0xE0); // Dev Addr Write
    i2cBit(0); // ACK
    i2cByte(0x08); // Enable CH3 (bit 3)
    i2cBit(0); // ACK
    i2cStop();
    addI2CBit(1, 1, 30); // Idle

    // 2. SN65DP159 Initial Power-up Configuration
    // DP159 Address is 0x5E -> Write Address is 0xBC
    List<List<int>> dp159Init = [
      // Page 0
      [0xFF, 0x00],
      [0x09, 0x36],
      [0x0A, 0x7B],
      [0x0D, 0x80],
      [0x0C, 0x6D],
      [0x10, 0x00],
      [0x16, 0xF1],
      // Select Page 1
      [0xFF, 0x01],
      // CONFIGURE PLL BLOCK
      [0x00, 0x02],
      [0x04, 0x80],
      [0x05, 0x00],
      [0x08, 0x00],
      [0x0D, 0x02],
      [0x0E, 0x03],
      [0x01, 0x01],
      [0x02, 0x3F],
      [0x0B, 0x33],
      [0xA1, 0x02],
      [0xA4, 0x02],
      // CONFIGURE TX BLOCK
      [0x10, 0xF0],
      [0x11, 0x30],
      [0x14, 0x00],
      [0x12, 0x03],
      [0x13, 0xFF],
      [0x13, 0x00],
      // CONFIGURE RX BLOCK
      [0x30, 0xE0],
      [0x32, 0x00],
      [0x31, 0x00],
      [0x4D, 0x08],
      [0x4C, 0x01],
      [0x34, 0x01],
      [0x32, 0xF0],
      [0x32, 0x00],
      [0x33, 0xF0],
      // Select Page 0
      [0xFF, 0x00],
      [0x0A, 0x3B],
      // Select Page 1
      [0xFF, 0x01],
    ];

    for (var reg in dp159Init) {
      writeI2cReg(0xBC, reg[0], reg[1]);
    }

    addI2CBit(1, 1, 100); // Idle

    // 3. Configure TCA9548A MUX to enable Channel 1 (EEPROM)
    i2cStart();
    i2cByte(0xE0); // Dev Addr Write
    i2cBit(0); // ACK
    i2cByte(0x02); // Enable CH1 (bit 1)
    i2cBit(0); // ACK
    i2cStop();
    addI2CBit(1, 1, 30); // Idle
    
    // 4. EEPROM Operations
    // 4. EEPROM Operations (Removed old mock)

    // 5. Test Page Writes to 24C16 (128 pages * 16 bytes = 2048 random bytes full chip)
    var rand = math.Random(12345);
    for (int block = 0; block < 8; block++) {
      int devAddrWrite = 0xA0 | (block << 1); // 0x50, 0x51, ... 0x57 shifted left
      for (int page = 0; page < 16; page++) {
        int wordAddr = page * 16;
        
        i2cStart();
        i2cByte(devAddrWrite); 
        i2cBit(0); // ACK
        i2cByte(wordAddr); 
        i2cBit(0); // ACK
        
        for (int i = 0; i < 16; i++) {
          i2cByte(rand.nextInt(256));
          i2cBit(0); // ACK
        }
        i2cStop();
        
        // Small delay between page writes (simulating EEPROM write cycle time tWR)
        addI2CBit(1, 1, 50); 
      }
    }

    addI2CBit(1, 1, 200); // Long Idle before repeating

    // Precompute UART test waveform for D2 (RXD) and D3 (TXD)
    List<int> uartSequence = [];
    int uartBaud = 115200;
    double samplesPerBitUart = fs / uartBaud;
    int uartTotalSamples = (0.2 * fs).toInt(); // 200ms period
    int uartIdle = (1 << 2) | (1 << 3);
    for (int i = 0; i < uartTotalSamples; i++) {
      uartSequence.add(uartIdle);
    }
    void drawUartBytes(List<int> bytes, int startSample, int pin) {
      double currentStart = startSample.toDouble();
      for (int byte in bytes) {
         int bits = (byte << 1) | 0x200;
         for (int bit = 0; bit < 10; bit++) {
            int bitVal = (bits >> bit) & 1;
            int bitStart = (currentStart + bit * samplesPerBitUart).toInt();
            int bitEnd = (currentStart + (bit + 1) * samplesPerBitUart).toInt();
            for (int idx = bitStart; idx < bitEnd; idx++) {
              if (idx < uartTotalSamples) {
                 if (bitVal == 1) {
                     uartSequence[idx] |= (1 << pin);
                 } else {
                     uartSequence[idx] &= ~(1 << pin);
                 }
              }
            }
         }
         currentStart += 10 * samplesPerBitUart;
      }
    }
    List<int> calculateChecksum(List<int> bytes) {
      int sum = 0;
      for (int i = 2; i < bytes.length; i++) {
        sum += bytes[i];
      }
      bytes.add(sum & 0xFF);
      return bytes;
    }

    // 1. External Circuit Enable
    List<int> tx1 = calculateChecksum([0x55, 0xAA, 0x70, 0xAB, 0xCD, 0x00, 0x00]);
    List<int> rx1 = calculateChecksum([0x55, 0xAA, 0x70, 0x01, 0x00, 0x00, 0x00]);

    // 2. Single Measurement
    List<int> tx2 = calculateChecksum([0x55, 0xAA, 0x88, 0xFF, 0xFF, 0xFF, 0xFF]);
    List<int> rx2 = calculateChecksum([0x55, 0xAA, 0x88, 0x01, 0xFF, 0x01, 0x23]);

    // 3. Angle Measurement
    List<int> tx3 = calculateChecksum([0x55, 0xAA, 0x8A, 0xFF, 0xFF, 0xFF, 0xFF]);
    List<int> rx3 = calculateChecksum([0x55, 0xAA, 0x8A, 0x01, 0xFF, 0x00, 0x45]);

    int currentPos = (0.005 * fs).toInt(); // Start at 5ms

    void drawInteraction(List<int> tx, List<int> rx) {
      drawUartBytes(tx, currentPos, 3);
      currentPos += (tx.length * 10 * samplesPerBitUart).toInt();
      
      // Gap before response (2ms)
      currentPos += (0.002 * fs).toInt();
      
      drawUartBytes(rx, currentPos, 2);
      currentPos += (rx.length * 10 * samplesPerBitUart).toInt();
      
      // Gap before next command (15ms)
      currentPos += (0.015 * fs).toInt();
    }

    drawInteraction(tx1, rx1);
    drawInteraction(tx2, rx2);
    drawInteraction(tx3, rx3);

    // SPI Sequence
    List<int> spiSequence = generateW25Q64JwSpiSequence();

    _demoTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_isPaused) return;

      List<int> buffer = [];
      for (int i = 0; i < pointsPerTick; i++) {
        double t = _demoCounter * dt;
        _demoCounter++;
        
        buffer.add(0xAA);
        buffer.add(0x55);
        buffer.add(0x1F); // All 4 analog + 1 digital
        
        // CH1: 1kHz Sine, Vpp=5V
        double v1 = 2.5 * math.sin(2 * math.pi * 1000 * t);
        int ch1 = voltageToADC(v1);
        buffer.add(ch1 & 0xFF);
        buffer.add((ch1 >> 8) & 0xFF);
        
        // CH2: 10kHz Sine, Vpp=10V
        double v2 = 5.0 * math.sin(2 * math.pi * 10000 * t);
        int ch2 = voltageToADC(v2);
        buffer.add(ch2 & 0xFF);
        buffer.add((ch2 >> 8) & 0xFF);
        
        // CH3: 22.4832kHz Square, Vpp=3.321V, 15% duty cycle
        double period3 = 1.0 / 22483.2;
        double phase3 = (t % period3) / period3;
        double v3 = (phase3 < 0.15) ? (3.321 / 2) : (-3.321 / 2);
        int ch3 = voltageToADC(v3);
        buffer.add(ch3 & 0xFF);
        buffer.add((ch3 >> 8) & 0xFF);
        
        // CH4: 2kHz Square, Vpp=1V, 50% duty cycle
        double period4 = 1.0 / 2000.0;
        double phase4 = (t % period4) / period4;
        double v4 = (phase4 < 0.50) ? 0.5 : -0.5;
        int ch4 = voltageToADC(v4);
        buffer.add(ch4 & 0xFF);
        buffer.add((ch4 >> 8) & 0xFF);
        
        // Digital channels: I2C simulation on D0, D1
        int digital = 0;
        if (i2cSequence.isNotEmpty) {
          digital |= i2cSequence[_demoCounter % i2cSequence.length];
        }
        
        // UART simulation on D2, D3
        if (uartSequence.isNotEmpty) {
          digital |= uartSequence[_demoCounter % uartSequence.length];
        }
        
        // 8-bit binary counter, incrementing every 20 ticks
        int counter8bit = (_demoCounter ~/ 20) % 256;
        // 8-bit Gray code
        int grayCode8bit = counter8bit ^ (counter8bit >> 1);
        
        // Put Gray code into D8~D15
        digital |= (grayCode8bit << 8);
        
        // Put binary counter into D16~D23
        digital |= (counter8bit << 16);
        
        // SPI sequence on D24~D29
        if (spiSequence.isNotEmpty) {
          int spiState = spiSequence[_demoCounter % spiSequence.length];
          // spiState has bits 0-5. We shift them to 24-29.
          digital |= (spiState << 24);
        }
        
        buffer.add(digital & 0xFF);
        buffer.add((digital >> 8) & 0xFF);
        buffer.add((digital >> 16) & 0xFF);
        buffer.add((digital >> 24) & 0xFF);
      }
      _handleIncomingRawData(Uint8List.fromList(buffer));
    });
  }

  void clearData() {
    for (var ch in channels) {
      ch.clear();
    }
    digitalChannel.clear();
    _xScrollOffset = 0.0;
    
    // Clear search data
    searchMatches.clear();
    currentSearchMatchIndex = -1;
    lastSearchConfig = null;
    
    // Close event list and protocol panels
    _activeEventListBusName = null;
    _highlightedBusName = null;
    _highlightedStartIndex = null;
    _highlightedEndIndex = null;
    _showRegisterInfoPanel = false;
    
    decodeAllProtocols();
    notifyListeners();
  }

  void toggleChannelVisibility(int index) {
    if (index >= 0 && index < channels.length) {
      channels[index].isVisible = !channels[index].isVisible;
      notifyListeners();
    }
  }

  void setAllChannelsVisibility(bool visible) {
    for (var ch in channels) {
      ch.isVisible = visible;
    }
    notifyListeners();
  }

  void toggleDigitalPinVisibility(int pin) {
    if (digitalChannel.enabledPins.contains(pin)) {
      digitalChannel.enabledPins.remove(pin);
    } else {
      digitalChannel.enabledPins.add(pin);
    }
    
    decodeAllProtocols();
    notifyListeners();
  }

  void setDigitalPinGroupVisibility(int startPin, int endPin, bool visible) {
    for (int i = startPin; i <= endPin; i++) {
      if (visible) {
        digitalChannel.enabledPins.add(i);
      } else {
        digitalChannel.enabledPins.remove(i);
      }
    }
    notifyListeners();
  }

  void setChannelName(int index, String? name) {
    if (index >= 0 && index < channels.length) {
      channels[index].name = name;
      notifyListeners();
    }
  }

  void setDigitalPinName(int pin, String? name) {
    if (name == null || name.isEmpty) {
      digitalChannel.pinNames.remove(pin);
    } else {
      digitalChannel.pinNames[pin] = name;
    }
    notifyListeners();
  }

  void setDigitalBusPinName(String busName, int pin, String? name) {
    int index = digitalChannel.buses.indexWhere((b) => b.name == busName);
    if (index >= 0) {
      if (name == null || name.isEmpty) {
        digitalChannel.buses[index].pinNames.remove(pin);
      } else {
        digitalChannel.buses[index].pinNames[pin] = name;
      }
      notifyListeners();
    }
  }

  void setTimebase(double x) {
    _xScale = x;
    notifyListeners();
  }

  void zoomFromCenter(double zoomFactor) {
    double oldScale = _xScale;
    double newScale = oldScale * zoomFactor;
    if (newScale < 0.01) newScale = 0.01;
    if (newScale > 500.0) newScale = 500.0;
    
    double oldMinScale = chartWidth / OscilloscopeState.maxPointsPerChannel;
    double oldActiveScale = oldScale < oldMinScale ? oldMinScale : oldScale;
    
    double latestX = 0;
    if (channels.isNotEmpty && channels[0].count > 0) {
      latestX = (channels[0].count - 1).toDouble();
    } else if (digitalChannel.count > 0) {
      latestX = (digitalChannel.count - 1).toDouble();
    }
    
    double oldTranslateX = chartWidth - latestX * oldActiveScale + _xScrollOffset;
    
    double mouseX = chartWidth / 2; // Center of screen
    double indexUnderCursor = (mouseX - oldTranslateX) / oldActiveScale;
    
    double newActiveScale = newScale < oldMinScale ? oldMinScale : newScale;
    double newTranslateX = mouseX - indexUnderCursor * newActiveScale;
    double newScrollOffset = newTranslateX - chartWidth + latestX * newActiveScale;
    
    double maxScroll = 0;
    if (latestX * newActiveScale > chartWidth) {
      maxScroll = latestX * newActiveScale - chartWidth;
    }
    
    if (newScrollOffset > maxScroll) newScrollOffset = maxScroll;
    if (newScrollOffset < 0) newScrollOffset = 0;
    
    _xScale = newScale;
    _xScrollOffset = newScrollOffset;
    notifyListeners();
  }

  void setChannelScale(int index, double y) {
    if (index >= 0 && index < channels.length) {
      channels[index].yScale = y;
      notifyListeners();
    }
  }

  void setChannelOffset(int index, double offset) {
    if (index >= 0 && index < channels.length) {
      channels[index].yOffset = offset;
      notifyListeners();
    }
  }

  void setDigitalPinOffset(int pin, double offset) {
    digitalChannel.pinYOffsets[pin] = offset;
    notifyListeners();
  }

  void setDigitalPinScale(int pin, double scale) {
    digitalChannel.pinYScales[pin] = scale;
    notifyListeners();
  }

  void clearDigitalBuses() {
    digitalChannel.buses.clear();
    digitalChannel.enabledPins.clear();
    _activeEventListBusName = null;
    _highlightedBusName = null;
    _highlightedStartIndex = null;
    _highlightedEndIndex = null;
    if (lastSearchConfig != null) {
      clearSearchMatches();
    }
    notifyListeners();
  }

  void addDigitalBus(String name, int startPin, int endPin, DigitalBusFormat format, {ProtocolDecoder? decoder}) {
    String finalName = name;
    int index = 1;
    while (digitalChannel.buses.any((b) => b.name == finalName)) {
      finalName = '${name}_$index';
      index++;
    }
    
    List<Color> busColors = [
      Colors.cyanAccent,
      Colors.pinkAccent,
      Colors.amberAccent,
      Colors.lightGreenAccent,
      Colors.deepPurpleAccent,
      Colors.tealAccent,
    ];
    Color newColor = busColors[digitalChannel.buses.length % busColors.length];
    
    DigitalBus newBus = DigitalBus(
      name: finalName,
      startPin: startPin,
      endPin: endPin,
      color: newColor,
      format: format,
      decoder: decoder,
    );
    digitalChannel.buses.add(newBus);
    
    if (decoder != null) {
      void setAlias(int pin, String name) {
        if (pin >= 0) {
          digitalChannel.pinNames[pin] = name;
          newBus.pinNames[pin] = name;
        }
      }

      if (decoder is SpiDecoder) {
        setAlias(decoder.csPin, 'CS');
        setAlias(decoder.sckPin, 'SCLK');
        setAlias(decoder.mosiPin, 'MOSI(IO0)');
        setAlias(decoder.misoPin, 'MISO(IO1)');
        setAlias(decoder.io2Pin, 'IO2');
        setAlias(decoder.io3Pin, 'IO3');
      } else if (decoder is I2cDecoder) {
        setAlias(decoder.sclPin, 'SCL');
        setAlias(decoder.sdaPin, 'SDA');
      } else if (decoder is UartDecoder) {
        setAlias(decoder.txPin, 'TX');
        setAlias(decoder.rxPin, 'RX');
      }
      decodeAllProtocols();
    }
    notifyListeners();
  }

  void updateDigitalBus(DigitalBus newBus, [String? oldName]) {
    String searchName = oldName ?? newBus.name;
    int index = digitalChannel.buses.indexWhere((b) => b.name == searchName);
    if (index >= 0) {
      digitalChannel.buses[index] = newBus;
    } else {
      digitalChannel.buses.add(newBus);
    }
    
    // Auto-enable the pins in this bus
    int minPin = newBus.startPin < newBus.endPin ? newBus.startPin : newBus.endPin;
    int maxPin = newBus.startPin > newBus.endPin ? newBus.startPin : newBus.endPin;
    for (int p = minPin; p <= maxPin; p++) {
      digitalChannel.enabledPins.add(p);
    }
    
    if (newBus.decoder != null) {
      void setAlias(int pin, String name) {
        if (pin >= 0) {
          digitalChannel.pinNames[pin] = name;
          newBus.pinNames[pin] = name;
        }
      }

      var decoder = newBus.decoder!;
      if (decoder is SpiDecoder) {
        setAlias(decoder.csPin, 'CS');
        setAlias(decoder.sckPin, 'SCLK');
        setAlias(decoder.mosiPin, 'MOSI(IO0)');
        setAlias(decoder.misoPin, 'MISO(IO1)');
        setAlias(decoder.io2Pin, 'IO2');
        setAlias(decoder.io3Pin, 'IO3');
      } else if (decoder is I2cDecoder) {
        setAlias(decoder.sclPin, 'SCL');
        setAlias(decoder.sdaPin, 'SDA');
      } else if (decoder is UartDecoder) {
        setAlias(decoder.txPin, 'TX');
        setAlias(decoder.rxPin, 'RX');
      }
      decodeAllProtocols();
    }
    
    if (lastSearchConfig != null && (lastSearchConfig!['busName'] == newBus.name || lastSearchConfig!['busName'] == oldName)) {
      clearSearchMatches();
    }
    
    notifyListeners();
  }

  void removeDigitalBus(String name) {
    digitalChannel.buses.removeWhere((b) => b.name == name);
    if (_activeEventListBusName == name) {
      _activeEventListBusName = null;
    }
    if (_highlightedBusName == name) {
      _highlightedBusName = null;
      _highlightedStartIndex = null;
      _highlightedEndIndex = null;
    }
    if (lastSearchConfig != null && lastSearchConfig!['busName'] == name) {
      clearSearchMatches();
    }
    notifyListeners();
  }

  void renameDigitalBus(String oldName, String newName) {
    if (newName.isEmpty || oldName == newName) return;
    if (digitalChannel.buses.any((b) => b.name == newName)) return; // Name already exists
    
    var bus = digitalChannel.buses.firstWhere((b) => b.name == oldName, orElse: () => throw Exception('Bus not found'));
    bus.name = newName;
    
    if (lastSearchConfig != null && lastSearchConfig!['busName'] == oldName) {
      clearSearchMatches();
    }
    
    notifyListeners();
  }

  void updateDigitalBusFormat(String name, DigitalBusFormat format) {
    var bus = digitalChannel.buses.firstWhere((b) => b.name == name, orElse: () => throw Exception('Bus not found'));
    bus.format = format;
    if (bus.decoder != null) {
      if (format == DigitalBusFormat.hex) {
        bus.decoder!.dataFormat = ProtocolDataFormat.hex;
      } else if (format == DigitalBusFormat.decimal) {
        bus.decoder!.dataFormat = ProtocolDataFormat.decimal;
      } else if (format == DigitalBusFormat.ascii) {
        bus.decoder!.dataFormat = ProtocolDataFormat.ascii;
      }
      decodeAllProtocols();
    }
    notifyListeners();
  }

  void updateDigitalBusPins(String name, int startPin, int endPin) {
    var bus = digitalChannel.buses.firstWhere((b) => b.name == name, orElse: () => throw Exception('Bus not found'));
    bus.startPin = startPin;
    bus.endPin = endPin;
    notifyListeners();
  }

  void setDigitalBusOffset(String name, double offset) {
    var bus = digitalChannel.buses.firstWhere((b) => b.name == name, orElse: () => throw Exception('Bus not found'));
    bus.yOffset = offset;
    notifyListeners();
  }

  void setDigitalBusScale(String name, double scale) {
    var bus = digitalChannel.buses.firstWhere((b) => b.name == name, orElse: () => throw Exception('Bus not found'));
    // Do not allow scale changes if expanded
    if (!bus.isExpanded) {
      bus.yScale = scale;
      notifyListeners();
    }
  }

  void toggleDigitalBusExpanded(String name) {
    var bus = digitalChannel.buses.firstWhere((b) => b.name == name, orElse: () => throw Exception('Bus not found'));
    bus.isExpanded = !bus.isExpanded;
    double digitalAmplitude = 20.0;
    if (bus.isExpanded) {
      double currentAmplitudeOld = digitalAmplitude * bus.yScale;
      bus.savedCollapsedScale = bus.yScale;
      bus.yScale = 1.0; // Force scale to 1.0 when expanded
      bus.yOffset = bus.yOffset - currentAmplitudeOld / 2;
    } else {
      bus.yScale = bus.savedCollapsedScale; // Restore scale when collapsed
      double currentAmplitudeNew = digitalAmplitude * bus.yScale;
      bus.yOffset = bus.yOffset + currentAmplitudeNew / 2;
    }
    notifyListeners();
  }

  void setDigitalBusColor(String name, Color color) {
    var bus = digitalChannel.buses.firstWhere((b) => b.name == name, orElse: () => throw Exception('Bus not found'));
    bus.color = color;
    notifyListeners();
  }

  void autoSetup() {
    List<int> activeAnalog = [];
    for (int i = 0; i < channels.length; i++) {
      if (channels[i].isVisible) activeAnalog.add(i);
    }
    
    // Determine which pins are in buses
    Set<int> pinsInBuses = {};
    for (var bus in digitalChannel.buses) {
      int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
      int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
      for (int p = minPin; p <= maxPin; p++) {
        pinsInBuses.add(p);
      }
    }

    List<int> activeDigital = digitalChannel.enabledPins.where((p) => !pinsInBuses.contains(p)).toList();
    activeDigital.sort((a, b) => b.compareTo(a)); // D31 at top, D0 at bottom

    int totalChannels = activeAnalog.length + digitalChannel.buses.length + activeDigital.length;
    if (totalChannels == 0) return;

    double sliceHeight = chartHeight / totalChannels;
    double currentY = 0;

    for (int chIdx in activeAnalog) {
      double center = currentY + sliceHeight / 2;
      ChannelData ch = channels[chIdx];
      double minY = double.infinity;
      double maxY = -double.infinity;
      
      int count = ch.count;
      for (int i = 0; i < count; i++) {
        if (ch.points[i] < minY) minY = ch.points[i];
        if (ch.points[i] > maxY) maxY = ch.points[i];
      }

      if (count > 0 && minY <= maxY) {
        double ptp = maxY - minY;
        if (ptp == 0) ptp = 1.0; // avoid div by zero if flatline
        
        double targetAmplitude = sliceHeight - 10.0;
        if (targetAmplitude < 10.0) targetAmplitude = 10.0;
        ch.yScale = targetAmplitude / ptp;

        double dataCenter = (minY + maxY) / 2;
        ch.yOffset = center - chartHeight / 2 + dataCenter * ch.yScale;
      } else {
        ch.yScale = 1.0;
        ch.yOffset = center - chartHeight / 2;
      }

      currentY += sliceHeight;
    }

    for (int pin in activeDigital) {
      double center = currentY + sliceHeight / 2;
      double targetAmplitude = sliceHeight - 10.0;
      double scale = targetAmplitude / 20.0; // 20.0 is digitalAmplitude base

      if (scale < 1.0) scale = 1.0;
      if (scale > 5.0) scale = 5.0;
      digitalChannel.pinYScales[pin] = scale;

      double actualAmplitude = 20.0 * scale;
      digitalChannel.pinYOffsets[pin] = center + actualAmplitude / 2;

      currentY += sliceHeight;
    }

    for (var bus in digitalChannel.buses) {
      double center = currentY + sliceHeight / 2;
      double targetAmplitude = sliceHeight - 10.0;
      double scale = targetAmplitude / 20.0;

      if (scale < 1.0) scale = 1.0;
      if (scale > 5.0) scale = 5.0;
      bus.yScale = scale;

      double actualAmplitude = 20.0 * scale;
      bus.yOffset = center + actualAmplitude / 2;

      currentY += sliceHeight;
    }

    // Adjust X-axis to fit all data horizontally
    double latestX = 0;
    if (channels.isNotEmpty && channels[0].count > 0) {
      latestX = (channels[0].count - 1).toDouble();
    } else if (digitalChannel.count > 0) {
      latestX = (digitalChannel.count - 1).toDouble();
    }

    if (latestX > 0) {
      double newScale = chartWidth / latestX;
      double minScale = chartWidth / OscilloscopeState.maxPointsPerChannel;
      if (newScale < minScale) newScale = minScale;
      if (newScale > 500.0) newScale = 500.0;
      
      _xScale = newScale;
      _xScrollOffset = 0.0;
    }

    notifyListeners();
  }

  void selectChannel(int index) {
    if (index >= 0 && index < channels.length) {
      _selectedChannelIndex = index;
      notifyListeners();
    }
  }

  void setTriggerLevel(int level) {
    _triggerLevel = level;
    notifyListeners();
  }

  // State machine for parsing binary data
  int _parseState = 0;
  int _channelMask = 0;
  int _expectedPayloadBytes = 0;
  final List<int> _payloadBuffer = [];

  // Variables for Control/Special Frames
  int _cmdId = 0;
  int _cmdPayloadLenL = 0;
  int _cmdPayloadLenH = 0;

  // MSO state
  int latestDigitalState = 0;

  void _handleIncomingRawData(Uint8List data) {
    if (_isPaused && !_isDemoMode) return; // If demo mode is running, pause is handled inside the timer
    // Wait, if demo mode is running, the timer respects _isPaused. So if _isPaused, we don't process raw data either.
    if (_isPaused) return;

    // If demo mode is running, ignore real incoming data
    // This requires us to somehow know if the data came from demo or real.
    // _handleIncomingRawData is called by the subscription or the demo timer.
    // But since the demo timer directly calls this, the subscription might inject garbage.
    // So we should check _isDemoMode in the subscription listener instead.
    
    bool hasNewPoints = false;

    // Binary Protocol:
    // 0: Wait for 0xAA
    // 1: Wait for 0x55
    // 2: Read channel mask (M)
    // 3: Read M * 2 bytes (uint16 values)

    for (int byte in data) {
      switch (_parseState) {
        case 0:
          if (byte == 0xAA) _parseState = 1;
          break;
        case 1:
          if (byte == 0x55) {
            _parseState = 2;
          } else {
            _parseState = 0; // reset
          }
          break;
        case 2:
          _channelMask = byte;
          if (_channelMask == 0x80 || _channelMask == 0x40 || _channelMask == 0x20) {
            // It's a Control / Special Data frame
            _parseState = 4; // go to read CMD_ID
          } else if (_channelMask > 0 && _channelMask < (1 << (maxChannels + 1))) {
            // It's a regular Waveform Data frame
            _expectedPayloadBytes = 0;
            // 模拟通道 (Bit 0-3)
            for (int i = 0; i < maxChannels; i++) {
              if ((_channelMask & (1 << i)) != 0) {
                _expectedPayloadBytes += 2;
              }
            }
            // 数字通道 (Bit 4)
            if ((_channelMask & (1 << 4)) != 0) {
              _expectedPayloadBytes += 4;
            }
            _payloadBuffer.clear();
            _parseState = 3;
          } else {
            // Invalid mask
            _parseState = 0;
          }
          break;
        case 3:
          _payloadBuffer.add(byte);
          if (_payloadBuffer.length == _expectedPayloadBytes) {
            _processFrame();
            hasNewPoints = true;
            _parseState = 0; // wait for next frame
          }
          break;
        case 4:
          _cmdId = byte;
          _parseState = 5;
          break;
        case 5:
          _cmdPayloadLenL = byte;
          _parseState = 6;
          break;
        case 6:
          _cmdPayloadLenH = byte;
          _expectedPayloadBytes = (_cmdPayloadLenH << 8) | _cmdPayloadLenL;
          _payloadBuffer.clear();
          if (_expectedPayloadBytes == 0) {
             _routeControlFrame();
             _parseState = 0;
          } else {
             _parseState = 7;
          }
          break;
        case 7:
          _payloadBuffer.add(byte);
          if (_payloadBuffer.length == _expectedPayloadBytes) {
             _routeControlFrame();
             _parseState = 0;
          }
          break;
      }
    }

    if (hasNewPoints && !_isWaitingForTrigger) {
      if (_triggerMode == TriggerMode.single || _triggerMode == TriggerMode.normal) {
        int requiredPoints = (chartWidth / xScale).ceil();
        if (requiredPoints < 4000) requiredPoints = 4000;
        if (requiredPoints > maxPointsPerChannel) requiredPoints = maxPointsPerChannel;

        if (_postTriggerCount >= requiredPoints) {
          decodeAllProtocols();
          if (_triggerMode == TriggerMode.single) {
            _isPaused = true;
            _isSingleShot = false;
          } else if (_triggerMode == TriggerMode.normal) {
            // Re-arm for the next screen in normal mode
            _armTrigger();
          }
        }
      }
      // Limit notifyListeners rate to 60fps max for UI performance
      int now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastNotifyTime > 16) {
        _lastNotifyTime = now;
        notifyListeners();
      }
      
      _throttleTimer?.cancel();
      _throttleTimer = Timer(const Duration(milliseconds: 32), () {
        notifyListeners();
      });
    }
  }

  void _processFrame() {
    if (_payloadBuffer.length != _expectedPayloadBytes) return;
    
    final byteData = ByteData.view(Uint8List.fromList(_payloadBuffer).buffer);
    
    int readOffset = 0;
    List<double> currentAnalog = List.filled(maxChannels, 0.0);
    int currentDigital = 0;

    for (int i = 0; i < maxChannels; i++) {
      if ((_channelMask & (1 << i)) != 0) {
        currentAnalog[i] = byteData.getUint16(readOffset, Endian.little).toDouble() - 2048.0;
        readOffset += 2;
      }
    }
    
    if ((_channelMask & (1 << 4)) != 0) {
      currentDigital = byteData.getUint32(readOffset, Endian.little);
    }

    if (_isWaitingForTrigger) {
      bool triggerMet = false;
      if (_triggerSourceType == TriggerSourceType.analog) {
        double prev = _lastAnalogStateForTrigger;
        double curr = currentAnalog[_triggerSourceIndex];
        double lvl = _triggerLevel - 2048.0;
        
        if (_triggerEdge == TriggerEdge.rising && prev < lvl && curr >= lvl) triggerMet = true;
        if (_triggerEdge == TriggerEdge.falling && prev > lvl && curr <= lvl) triggerMet = true;
        if (_triggerEdge == TriggerEdge.both && ((prev < lvl && curr >= lvl) || (prev > lvl && curr <= lvl))) triggerMet = true;
        
        _lastAnalogStateForTrigger = curr;
      } else {
        int prev = _lastDigitalStateForTrigger;
        int curr = currentDigital;
        int bitMask = 1 << _triggerSourceIndex;
        
        bool prevBit = (prev & bitMask) != 0;
        bool currBit = (curr & bitMask) != 0;
        
        if (_triggerEdge == TriggerEdge.rising && !prevBit && currBit) triggerMet = true;
        if (_triggerEdge == TriggerEdge.falling && prevBit && !currBit) triggerMet = true;
        if (_triggerEdge == TriggerEdge.both && prevBit != currBit) triggerMet = true;
        
        _lastDigitalStateForTrigger = curr;
      }

      if (triggerMet) {
        _isWaitingForTrigger = false;
        _postTriggerCount = 0;
      } else {
        return; // Discard data
      }
    }

    // Add points if trigger is met or auto mode
    for (int i = 0; i < maxChannels; i++) {
      if ((_channelMask & (1 << i)) != 0) {
        channels[i].addPoint(currentAnalog[i]);
      }
    }
    if ((_channelMask & (1 << 4)) != 0) {
      latestDigitalState = currentDigital;
      digitalChannel.addPoint(currentDigital);
      _lastDigitalStateForTrigger = currentDigital;
    }
    
    _postTriggerCount++;
  }

  void _routeControlFrame() {
    // Determine direction and route accordingly
    switch (_channelMask) {
      case 0x80:
        // Host to Device: The device echoed it back, or it's a loopback debug. 
        // We generally don't process it here unless for verification.
        debugPrint("Received loopback Host->Device cmd: 0x${_cmdId.toRadixString(16)}");
        break;
      case 0x40:
        // Device to Host: Command Response & State Report
        _processCommandResponse(_cmdId, Uint8List.fromList(_payloadBuffer));
        break;
      case 0x20:
        // Device to Host: Special Data Block Report
        _processSpecialDataBlock(_cmdId, Uint8List.fromList(_payloadBuffer));
        break;
    }
  }

  void _processCommandResponse(int cmdId, Uint8List payload) {
    // TODO: Parse the hardware state reporting. 
    // Example: 0x01 (Sample Rate), 0x02 (Channel Config), 0x10 (Hardware Info)
    debugPrint("Process CMD Response: 0x${cmdId.toRadixString(16)}, Len: ${payload.length}");
  }

  void _processSpecialDataBlock(int cmdId, Uint8List payload) {
    // TODO: Process special bulk data reports from device
    debugPrint("Process Special Data: 0x${cmdId.toRadixString(16)}, Len: ${payload.length}");
  }

  Future<void> saveWaveform(String filepath) async {
    await WaveformStorage.saveWaveform(filepath, this);
  }
  
  Future<void> loadWaveform(String filepath) async {
    bool wasPaused = _isPaused;
    if (!_isPaused) {
      _isPaused = true;
      notifyListeners();
    }
    
    try {
      await WaveformStorage.loadWaveform(filepath, this);
      notifyListeners();
    } catch (e) {
      if (!wasPaused) {
        _isPaused = false;
        notifyListeners();
      }
      rethrow;
    }
  }
}
