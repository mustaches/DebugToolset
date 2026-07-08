import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../../providers/oscilloscope_state.dart';
import '../models/protocol_decoder.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

class BusSearchDialog extends StatefulWidget {
  const BusSearchDialog({super.key});

  @override
  State<BusSearchDialog> createState() => _BusSearchDialogState();
}

class _BusSearchDialogState extends State<BusSearchDialog> {
  String? _selectedBusName;
  String _format = 'Hex';
  String _condition = 'Data Content Match'; // Used by UART and raw
  String _channel = 'Any'; // Used by UART
  String _uartField = 'CMD'; // Used by UART with protocol
  bool _isBigEndian = false;
  final TextEditingController _valueController = TextEditingController();
  String? _message;
  bool _isError = false;

  // I2C Specific Fields
  String _i2cFrameType = 'Any';
  int? _i2cDeviceAddress;
  int? _i2cRegisterAddress;

  List<int> _cachedI2cDevices = [];
  List<int> _cachedI2cRegisters = [];
  String? _lastBusNameForCache;
  int? _lastDeviceAddressForCache;

  // SPI Specific Fields
  String _spiFrameType = 'Any';
  int? _spiCommand;
  int? _spiAddress;

  List<String> _availableI2cFrameTypes = ['Any'];
  String? _lastI2cFrameTypeForCache;
  String? _selectedI2cProtocol;
  String? _lastI2cProtocolForCache;
  List<String> _availableSpiFrameTypes = ['Any'];
  List<int> _cachedSpiCommands = [];
  List<int> _cachedSpiAddresses = [];
  String? _lastSpiBusNameForCache;
  String? _lastSpiFrameTypeForCache;
  int? _lastSpiCommandForCache;
  List<String> _cachedUartProtocols = [];

  String? _lastUartBusNameForCache;
  String? _lastUartChannelForCache;
  String? _lastUartProtocolFileForCache;
  int _lastUartTotalPointsForCache = -1;
  Map<String, Map<int, String>> _cachedUartFieldValues = {};
  List<String> _cachedUartFields = [];

  @override
  void initState() {
    super.initState();
    _loadUartProtocols();
    final state = context.read<OscilloscopeState>();
    if (state.searchMatches.isNotEmpty && state.lastSearchConfig != null) {
      var conf = state.lastSearchConfig!;
      _selectedBusName = conf['busName'];
      _format = conf['format'] ?? 'Hex';
      _condition = conf['condition'] ?? 'Data Content Match';
      _channel = conf['channel'] ?? 'Any';
      _uartField = conf['uartField'] ?? 'CMD';
      _isBigEndian = conf['isBigEndian'] ?? false;
      _valueController.text = conf['value'] ?? '';
      _i2cFrameType = conf['i2cFrameType'] ?? 'Any';
      _i2cDeviceAddress = conf['i2cDeviceAddress'];
      _i2cRegisterAddress = conf['i2cRegisterAddress'];
      _spiFrameType = conf['spiFrameType'] ?? 'Any';
      _spiCommand = conf['spiCommand'];
      _spiAddress = conf['spiAddress'];
    } else if (state.digitalChannel.buses.isNotEmpty) {
      _selectedBusName = state.digitalChannel.buses.first.name;
    }
  }

  Future<void> _loadUartProtocols() async {
    final Directory dir = Directory('DeviceProtocol/Uart');
    if (await dir.exists()) {
      var files = await dir.list().where((e) => e.path.endsWith('.UartProtocol')).toList();
      if (mounted) {
        setState(() {
          _cachedUartProtocols = files.map((f) => p.basename(f.path)).toList();
        });
      }
    }
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  void _updateUartCaches(OscilloscopeState state, DigitalBus? bus) {
    if (bus == null || bus.decoder?.name != 'UART' || (bus.decoder as UartDecoder).protocolFile == null) {
      _cachedUartFields.clear();
      _cachedUartFieldValues.clear();
      return;
    }

    String protocolFile = (bus.decoder as UartDecoder).protocolFile!;
    int currentPoints = state.digitalChannel.totalPointsAdded;

    if (_lastUartBusNameForCache == bus.name &&
        _lastUartChannelForCache == _channel &&
        _lastUartProtocolFileForCache == protocolFile &&
        _lastUartTotalPointsForCache == currentPoints) {
      return; // Cache is valid
    }

    _lastUartBusNameForCache = bus.name;
    _lastUartChannelForCache = _channel;
    _lastUartProtocolFileForCache = protocolFile;
    _lastUartTotalPointsForCache = currentPoints;

    _cachedUartFields = [];
    _cachedUartFieldValues = {};

    var protocol = state.availableUartProtocols[protocolFile];
    if (protocol != null) {
      Map<String, Map<int, String>> definedValues = {'CMD': {}};
      for (var cmdId in protocol.commands.keys) {
        definedValues['CMD']![cmdId] = protocol.commands[cmdId]!.name;
      }

      for (var cmd in protocol.commands.values) {
        var txPayload = cmd.tx?.payload ?? [];
        var rxPayload = cmd.rx?.payload ?? [];
        for (var f in [...txPayload, ...rxPayload]) {
          if (f.valueMap != null && f.valueMap!.isNotEmpty) {
            if (definedValues[f.name] == null) definedValues[f.name] = {};
            definedValues[f.name]!.addAll(f.valueMap!);
          }
        }
      }

      UartDecoder uDecoder = bus.decoder as UartDecoder;
      for (var frame in uDecoder.frames) {
        bool isTx = frame.summary.startsWith('Tx');
        if (_channel == 'TXD' && !isTx) continue;
        if (_channel == 'RXD' && isTx) continue;

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
        
        if (!_cachedUartFields.contains('CMD')) _cachedUartFields.add('CMD');
        if (_cachedUartFieldValues['CMD'] == null) _cachedUartFieldValues['CMD'] = {};
        _cachedUartFieldValues['CMD']![cmdId] = definedValues['CMD']?[cmdId] ?? '';

        var cmdDef = protocol.commands[cmdId];
        if (cmdDef == null) continue;

        var packetDef = isTx ? cmdDef.tx : cmdDef.rx;
        if (packetDef == null) continue;

        for (var fieldDef in packetDef.payload) {
          if (fieldDef.byteOffset < dataPackets.length) {
            if (!_cachedUartFields.contains(fieldDef.name)) _cachedUartFields.add(fieldDef.name);
            var p = dataPackets[fieldDef.byteOffset];
            int val = p.rawValue!;
            if (_cachedUartFieldValues[fieldDef.name] == null) _cachedUartFieldValues[fieldDef.name] = {};
            _cachedUartFieldValues[fieldDef.name]![val] = definedValues[fieldDef.name]?[val] ?? '';
          }
        }
      }
      _cachedUartFields.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (_cachedUartFields.isEmpty) _cachedUartFields.add('CMD');
    }
  }

  List<String> _getAvailableSpiFrameTypes(DigitalBus bus, OscilloscopeState state, String? protocolName) {
    if (bus.decoder == null || !bus.decoder!.isEnabled || (bus.decoder!.name != 'SPI' && bus.decoder!.name != 'SPI_ADS7038H')) return ['Any'];
    
    if (protocolName == null) {
      return ['Any', 'MISO', 'MOSI'];
    }
    
    Set<String> types = {'Any'};
    dynamic regfile;
    for (var r in state.availableSpiRegfiles) {
      if (r.name == protocolName) {
        regfile = r;
        break;
      }
    }
    
    bool hasRead = false;
    bool hasWrite = false;
    for (var frame in bus.decoder!.frames) {
      int? cmd;
      for (var p in frame.packets) {
        if (p.type == PacketType.data && p.data.startsWith('CMD:') && p.rawValue != null) {
          cmd = p.rawValue;
          break;
        }
      }
      if (cmd != null && regfile != null) {
        var cmdDef = (regfile.commands != null && regfile.commands!.containsKey(cmd)) 
            ? regfile.commands![cmd] 
            : regfile.registers[cmd];
        if (cmdDef != null) {
          String access = cmdDef.access ?? '';
          if (access.contains('R')) hasRead = true;
          if (access.contains('W')) hasWrite = true;
        }
      }
    }
    
    if (hasRead) types.add('Read Only');
    if (hasWrite) types.add('Write Only');
    if (!hasRead && !hasWrite) {
       types.add('Read Only'); types.add('Write Only');
    }
    return types.toList()..sort();
  }

  List<int> _getFilteredSpiCommands(DigitalBus bus, OscilloscopeState state, String frameType, String? protocolName) {
    if (bus.decoder == null || !bus.decoder!.isEnabled || (bus.decoder!.name != 'SPI' && bus.decoder!.name != 'SPI_ADS7038H')) return [];
    Set<int> cmds = {};
    dynamic regfile;
    if (protocolName != null) {
      for (var r in state.availableSpiRegfiles) {
        if (r.name == protocolName) {
          regfile = r;
          break;
        }
      }
    }

    for (var frame in bus.decoder!.frames) {
      int? cmd;
      for (var p in frame.packets) {
        if (p.type == PacketType.data && p.data.startsWith('CMD:') && p.rawValue != null) {
          cmd = p.rawValue;
          break;
        }
      }
      if (cmd != null) {
        if (frameType != 'Any' && regfile != null) {
           var cmdDef = (regfile.commands != null && regfile.commands!.containsKey(cmd)) 
               ? regfile.commands![cmd] 
               : regfile.registers[cmd];
           if (cmdDef != null) {
             String access = cmdDef.access ?? '';
             if (frameType == 'Read Only' && !access.contains('R')) continue;
             if (frameType == 'Write Only' && !access.contains('W')) continue;
           }
        }
        cmds.add(cmd);
      }
    }
    return cmds.toList()..sort();
  }

  List<int> _getFilteredSpiAddresses(DigitalBus bus, OscilloscopeState state, String frameType, int? selectedCmd, String? protocolName) {
    if (bus.decoder == null || !bus.decoder!.isEnabled || (bus.decoder!.name != 'SPI' && bus.decoder!.name != 'SPI_ADS7038H')) return [];
    Set<int> addrs = {};
    for (var frame in bus.decoder!.frames) {
      int? cmd;
      int? addr;
      bool hasCmd = false;
      for (var p in frame.packets) {
        if (p.type == PacketType.data && p.data.startsWith('CMD:') && p.rawValue != null) {
          cmd = p.rawValue;
          hasCmd = true;
        } else if (hasCmd && p.type == PacketType.data && p.data.startsWith('ADDR:') && p.rawValue != null) {
          addr = p.rawValue;
          break;
        }
      }
      
      if (addr != null) {
        if (selectedCmd != null && cmd != selectedCmd) continue;
        addrs.add(addr);
      }
    }
    return addrs.toList()..sort();
  }

  List<String> _getAvailableI2cFrameTypes(DigitalBus bus, OscilloscopeState state) {
    if (bus.decoder == null || bus.decoder!.name != 'I2C') return ['Any', 'Read Only', 'Write Only'];
    bool hasRead = false;
    bool hasWrite = false;
    
    Set<int>? validAddrs;
    if (_selectedI2cProtocol != null) {
       var regfiles = state.availableRegfiles.where((r) => r.name == _selectedI2cProtocol);
       if (regfiles.isNotEmpty) {
          var regfile = regfiles.first;
          validAddrs = {};
          if (regfile.addresses != null) validAddrs.addAll(regfile.addresses!);
          if (regfile.addressMap != null) validAddrs.addAll(regfile.addressMap!.keys);
          if (validAddrs.isEmpty) validAddrs = null;
       }
    }

    for (var frame in bus.decoder!.frames) {
      if (validAddrs != null) {
         bool matchAddr = false;
         for (var p in frame.packets) {
            if (p.type == PacketType.address && p.rawValue != null) {
               if (validAddrs.contains(p.rawValue!)) {
                  matchAddr = true;
               }
               break;
            }
         }
         if (!matchAddr) continue;
      }
      
      if (frame.summary.startsWith('R')) hasRead = true;
      if (frame.summary.startsWith('W')) hasWrite = true;
      if (hasRead && hasWrite) break;
    }
    List<String> types = ['Any'];
    if (hasRead) types.add('Read Only');
    if (hasWrite) types.add('Write Only');
    if (!hasRead && !hasWrite) {
      types.add('Read Only'); types.add('Write Only');
    }
    return types;
  }

  List<int> _getFilteredI2cDevices(DigitalBus bus, OscilloscopeState state, String frameType) {
    if (bus.decoder == null || bus.decoder!.name != 'I2C') return [];
    Set<int> addrs = {};
    for (var frame in bus.decoder!.frames) {
      bool isRead = frame.summary.startsWith('R');
      bool isWrite = frame.summary.startsWith('W');
      if (frameType == 'Read Only' && !isRead) continue;
      if (frameType == 'Write Only' && !isWrite) continue;
      
      for (var p in frame.packets) {
        if (p.type == PacketType.address && p.rawValue != null) {
          addrs.add(p.rawValue!);
          break;
        }
      }
    }
    
    if (_selectedI2cProtocol != null) {
       var regfiles = state.availableRegfiles.where((r) => r.name == _selectedI2cProtocol);
       if (regfiles.isNotEmpty) {
          var regfile = regfiles.first;
            List<int> validAddrs = [];
            if (regfile.addresses != null) validAddrs.addAll(regfile.addresses!);
            if (regfile.addressMap != null) validAddrs.addAll(regfile.addressMap!.keys);
            if (validAddrs.isNotEmpty) {
               if (addrs.isEmpty) {
                   addrs = validAddrs.toSet();
               } else {
                   addrs = addrs.intersection(validAddrs.toSet());
               }
            }
       }
    }
    
    var list = addrs.toList();
    list.sort();
    return list;
  }

  List<int> _getFilteredI2cRegisters(DigitalBus bus, OscilloscopeState state, String frameType, int? deviceAddr) {
    if (bus.decoder == null || bus.decoder!.name != 'I2C') return [];
    Set<int> addrs = {};
    for (var frame in bus.decoder!.frames) {
      bool isReadFrame = frame.summary.startsWith('R');
      bool isWriteFrame = frame.summary.startsWith('W');
      if (frameType == 'Read Only' && !isReadFrame) continue;
      if (frameType == 'Write Only' && !isWriteFrame) continue;
      
      int? currentAddr;
      bool isWrite = false;
      for (int i = 0; i < frame.packets.length; i++) {
        var p = frame.packets[i];
        if (p.type == PacketType.address && p.rawValue != null) {
          currentAddr = p.rawValue;
          if (i + 1 < frame.packets.length && frame.packets[i+1].type == PacketType.readWrite) {
             isWrite = frame.packets[i+1].data == 'WRITE';
             i++; // Skip RW packet
          }
        } else if (p.type == PacketType.data && currentAddr != null) {
          if (deviceAddr == null || currentAddr == deviceAddr) {
             if (isWrite && p.rawValue != null) {
                 addrs.add(p.rawValue!);
                 break;
             }
          }
        }
      }
    }

    if (_selectedI2cProtocol != null) {
       var regfiles = state.availableRegfiles.where((r) => r.name == _selectedI2cProtocol);
       if (regfiles.isNotEmpty) {
          var regfile = regfiles.first;
          if (regfile.registers.isNotEmpty) {
             if (addrs.isEmpty) {
                 addrs = regfile.registers.keys.toSet();
             } else {
                 addrs = addrs.intersection(regfile.registers.keys.toSet());
             }
          }
       }
    }
    
    var list = addrs.toList();
    list.sort();
    return list;
  }

  void _updateI2cCaches(OscilloscopeState state, DigitalBus bus) {
    if (_lastBusNameForCache == bus.name && _lastI2cFrameTypeForCache == _i2cFrameType && _lastDeviceAddressForCache == _i2cDeviceAddress && _lastI2cProtocolForCache == _selectedI2cProtocol) {
      return;
    }
    
    _lastBusNameForCache = bus.name;
    _lastI2cFrameTypeForCache = _i2cFrameType;
    _lastDeviceAddressForCache = _i2cDeviceAddress;
    _lastI2cProtocolForCache = _selectedI2cProtocol;

    _availableI2cFrameTypes = _getAvailableI2cFrameTypes(bus, state);
    if (!_availableI2cFrameTypes.contains(_i2cFrameType)) {
      _i2cFrameType = 'Any';
    }

    _cachedI2cDevices = _getFilteredI2cDevices(bus, state, _i2cFrameType);
    if (_i2cDeviceAddress != null && !_cachedI2cDevices.contains(_i2cDeviceAddress)) {
      _i2cDeviceAddress = null;
    }
    if (_i2cDeviceAddress == null && _cachedI2cDevices.length == 1) {
      _i2cDeviceAddress = _cachedI2cDevices.first;
    }

    if (_i2cDeviceAddress != null && _selectedI2cProtocol == null) {
       var mounted = state.getRegfileFor(bus.name, _i2cDeviceAddress!);
       if (mounted != null) {
          _selectedI2cProtocol = mounted.name;
          _lastI2cProtocolForCache = mounted.name;
       }
    }

    _cachedI2cRegisters = _getFilteredI2cRegisters(bus, state, _i2cFrameType, _i2cDeviceAddress);
    if (_i2cRegisterAddress != null && !_cachedI2cRegisters.contains(_i2cRegisterAddress)) {
      _i2cRegisterAddress = null;
    }
  }

  void _updateSpiCaches(OscilloscopeState state, DigitalBus? bus) {
    if (bus == null || (bus.decoder?.name != 'SPI' && bus.decoder?.name != 'SPI_ADS7038H')) return;

    String? protocolFile;
    if (bus.decoder?.name == 'SPI') {
      protocolFile = (bus.decoder as SpiDecoder).protocolFile;
    } else if (bus.decoder?.name == 'SPI_ADS7038H') {
      protocolFile = (bus.decoder as Ads7038hDecoder).protocolFile;
    }

    if (_lastSpiBusNameForCache == bus.name && _lastSpiFrameTypeForCache == _spiFrameType && _lastSpiCommandForCache == _spiCommand) {
      return;
    }

    _lastSpiBusNameForCache = bus.name;
    _lastSpiFrameTypeForCache = _spiFrameType;
    _lastSpiCommandForCache = _spiCommand;

    _availableSpiFrameTypes = _getAvailableSpiFrameTypes(bus, state, protocolFile);
    if (!_availableSpiFrameTypes.contains(_spiFrameType)) {
      _spiFrameType = 'Any';
    }

    _cachedSpiCommands = _getFilteredSpiCommands(bus, state, _spiFrameType, protocolFile);
    if (_spiCommand != null && !_cachedSpiCommands.contains(_spiCommand)) {
      _spiCommand = null;
    }
    if (_spiCommand == null && _cachedSpiCommands.length == 1) {
      _spiCommand = _cachedSpiCommands.first;
    }

    _cachedSpiAddresses = _getFilteredSpiAddresses(bus, state, _spiFrameType, _spiCommand, protocolFile);
    if (_spiAddress != null && !_cachedSpiAddresses.contains(_spiAddress)) {
      _spiAddress = null;
    }
  }

  void _updateCaches(OscilloscopeState state, DigitalBus? bus) {
    if (bus == null) return;
    if (bus.decoder?.name == 'I2C') {
       _updateI2cCaches(state, bus);
    } else if (bus.decoder?.name == 'SPI' || bus.decoder?.name == 'SPI_ADS7038H') {
       _updateSpiCaches(state, bus);
    }
  }

  void _onSearch() {
    final state = context.read<OscilloscopeState>();
    if (_selectedBusName == null) {
      setState(() {
        _message = 'Please select a bus';
        _isError = true;
      });
      return;
    }
    
    final bus = state.digitalChannel.buses.firstWhere(
      (b) => b.name == _selectedBusName,
      orElse: () => throw Exception('Bus not found'),
    );
    
    bool isI2c = bus.decoder != null && bus.decoder!.name == 'I2C';

    if (isI2c && _i2cDeviceAddress == null) {
       setState(() {
         _message = 'Please select a Device Address';
         _isError = true;
       });
       return;
    }

    String internalCondition = 'Data';
    if (!isI2c) {
       if (_condition == 'Device Address Match') internalCondition = 'Device Address';
       if (_condition == 'Write Device Address Match') internalCondition = 'Write Address';
       if (_condition == 'Read Device Address Match') internalCondition = 'Read Address';
       if (_condition == 'Data Content Match' || _condition == 'Data Match') internalCondition = 'Data';
       if (_condition == 'Communication Error') internalCondition = 'Error';
    }

    state.lastSearchConfig = {
      'busName': _selectedBusName,
      'format': _format,
      'condition': _condition,
      'channel': _channel,
      'uartField': _uartField,
      'isBigEndian': _isBigEndian,
      'value': _valueController.text,
      'i2cFrameType': _i2cFrameType,
      'i2cDeviceAddress': _i2cDeviceAddress,
      'i2cRegisterAddress': _i2cRegisterAddress,
      'spiFrameType': _spiFrameType,
      'spiCommand': _spiCommand,
      'spiAddress': _spiAddress,
    };

    bool isSpi = bus.decoder != null && (bus.decoder!.name == 'SPI' || bus.decoder!.name == 'SPI_ADS7038H');

    int matchCount = state.searchAdvancedBusValue(

      bus: bus,
      format: _format,
      targetValueStr: _valueController.text,
      isBigEndian: _isBigEndian,
      condition: internalCondition,
      channel: _channel,
      i2cFrameType: isI2c ? _i2cFrameType : null,
      i2cDeviceAddress: isI2c ? _i2cDeviceAddress : null,
      i2cRegisterAddress: isI2c ? _i2cRegisterAddress : null,
      spiFrameType: isSpi ? _spiFrameType : null,
      spiCommand: isSpi ? _spiCommand : null,
      spiAddress: isSpi ? _spiAddress : null,
      uartField: (!isI2c && !isSpi && bus.decoder != null && bus.decoder!.name == 'UART' && (bus.decoder as UartDecoder).protocolFile != null) ? _uartField : null,
    );

    if (matchCount > 0) {
      setState(() {
         _message = 'Found $matchCount matches.';
         _isError = false;
      });
    } else {
      setState(() {
         _message = 'No matches found.';
         _isError = true;
      });
    }
  }

  Widget _buildLabel(String cn, String en) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: cn),
          TextSpan(text: ' ($en)', style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ),
      style: const TextStyle(color: Colors.white70),
    );
  }

  Widget _buildItemText(String cn, String en) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: cn),
          TextSpan(text: ' ($en)', style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();
    final buses = state.digitalChannel.buses;
    
    DigitalBus? currentBus;
    if (_selectedBusName != null) {
      try {
        currentBus = buses.firstWhere((b) => b.name == _selectedBusName);
      } catch (_) {}
    }

    bool hasDecoder = currentBus?.decoder != null && currentBus!.decoder!.isEnabled;
    String decoderType = currentBus?.decoder?.name ?? '';
    bool isI2c = hasDecoder && decoderType == 'I2C';
    bool isRawUart = hasDecoder && decoderType == 'UART' && (currentBus.decoder as UartDecoder).protocolFile == null;
    bool isUartWithProtocol = hasDecoder && decoderType == 'UART' && (currentBus.decoder as UartDecoder).protocolFile != null;
    bool isSpi = hasDecoder && (decoderType == 'SPI' || decoderType == 'SPI_ADS7038H');

    if (isI2c || isSpi) {
       _updateCaches(state, currentBus);
    }
    
    if (isUartWithProtocol) {
       _updateUartCaches(state, currentBus);
    }
    
    List<String> uartFields = isUartWithProtocol ? _cachedUartFields : ['CMD'];
    Map<String, Map<int, String>> fieldValues = isUartWithProtocol ? _cachedUartFieldValues : {};
    String currentUartField = uartFields.contains(_uartField) ? _uartField : (uartFields.isNotEmpty ? uartFields.first : 'CMD');

    List<String> conditions = [];
    if (hasDecoder && !isI2c) {
       if (decoderType == 'UART') {
          conditions = ['Data Match', 'Communication Error'];
       }
    }

    if (!isI2c && !conditions.contains(_condition)) {
       if (conditions.isNotEmpty) {
          _condition = conditions.first;
       } else {
          _condition = 'Data Content Match';
       }
    }

    bool disableInput = hasDecoder && !isI2c && _condition == 'Communication Error';

    Map<String, String> conditionCn = {
      'Data Match': '数据匹配',
      'Communication Error': '通信错误',
      'Device Address Match': '设备地址匹配',
      'Write Device Address Match': '写设备地址匹配',
      'Read Device Address Match': '读设备地址匹配',
      'Data Content Match': '数据内容匹配',
    };

    return AlertDialog(
      backgroundColor: const Color(0xFF222222),
      title: Text.rich(
        const TextSpan(
          children: [
            TextSpan(text: '搜索总线数据 '),
            TextSpan(text: '(Search Bus Value)', style: TextStyle(fontSize: 14, color: Colors.white54)),
          ],
        ),
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: SizedBox(
        width: 1000,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildLabel('目标总线', 'Target Bus'),
                        const SizedBox(height: 8),
                        if (buses.isEmpty)
                          const Text('未加载任何数字总线 (No digital buses loaded.)', style: TextStyle(color: Colors.redAccent))
                        else
                          DropdownButtonFormField<String>(
                            initialValue: _selectedBusName,
                            dropdownColor: const Color(0xFF333333),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              filled: true,
                              fillColor: Color(0xFF1E1E1E),
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            items: buses.map((b) {
                              String typeStr = b.decoder != null ? b.decoder!.name : '普通';
                              return DropdownMenuItem(
                                value: b.name,
                                child: _buildItemText(b.name, typeStr),
                              );
                            }).toList(),
                            onChanged: (val) {
                               setState(() {
                                 _selectedBusName = val;
                                 _lastBusNameForCache = null;
                               });
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!hasDecoder) ...[
                          _buildLabel('位序', 'Bit Order'),
                          const SizedBox(height: 8),
                          Builder(builder: (context) {
                            int startPin = currentBus?.startPin ?? 0;
                            int endPin = currentBus?.endPin ?? 0;
                            return DropdownButtonFormField<bool>(
                              initialValue: _isBigEndian,
                              dropdownColor: const Color(0xFF333333),
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xFF1E1E1E),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: [
                                DropdownMenuItem(value: false, child: _buildItemText('MSB(D$endPin)-LSB(D$startPin)', '与总线配置相同')),
                                DropdownMenuItem(value: true, child: _buildItemText('MSB(D$startPin)-LSB(D$endPin)', '与总线配置相反')),
                              ],
                              onChanged: (val) => setState(() => _isBigEndian = val ?? true),
                            );
                          }),
                        ] else ...[
                          _buildLabel('挂载解析器', 'Mounted Protocol'),
                          const SizedBox(height: 8),
                          Builder(builder: (context) {
                             String? initialProtocolFile;
                             if (decoderType == 'UART') {
                                initialProtocolFile = (currentBus!.decoder as UartDecoder).protocolFile;
                             } else if (decoderType == 'SPI') {
                                initialProtocolFile = (currentBus!.decoder as SpiDecoder).protocolFile;
                             } else if (decoderType == 'SPI_ADS7038H') {
                                initialProtocolFile = (currentBus!.decoder as Ads7038hDecoder).protocolFile;
                             } else if (decoderType == 'I2C') {
                                initialProtocolFile = _selectedI2cProtocol;
                             }
                             return DropdownButtonFormField<String?>(
                               initialValue: initialProtocolFile,
                               dropdownColor: const Color(0xFF333333),
                               style: const TextStyle(color: Colors.white),
                               decoration: const InputDecoration(
                                 filled: true,
                                 fillColor: Color(0xFF1E1E1E),
                                 border: OutlineInputBorder(),
                                 contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                               ),
                               items: [
                                  DropdownMenuItem(value: null, child: _buildItemText('无', 'None')),
                                  if (decoderType == 'UART') ..._cachedUartProtocols.map((name) => DropdownMenuItem(value: name, child: Text(name))),
                                  if (isSpi) ...state.availableSpiRegfiles.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name))),
                                  if (decoderType == 'I2C') ...state.availableRegfiles.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name))),
                               ],
                               onChanged: (val) {
                                  setState(() {
                                     if (decoderType == 'UART') {
                                        (currentBus!.decoder as UartDecoder).protocolFile = val;
                                        state.forceUpdate();
                                     } else if (decoderType == 'SPI') {
                                        (currentBus!.decoder as SpiDecoder).protocolFile = val;
                                        state.forceUpdate();
                                     } else if (decoderType == 'SPI_ADS7038H') {
                                        (currentBus!.decoder as Ads7038hDecoder).protocolFile = val;
                                        state.forceUpdate();
                                     } else if (decoderType == 'I2C') {
                                        _selectedI2cProtocol = val;
                                        _lastI2cFrameTypeForCache = null;
                                        _lastDeviceAddressForCache = null;
                                        _lastI2cProtocolForCache = null;
                                        if (_i2cDeviceAddress != null) {
                                           if (val != null) {
                                              var regfiles = state.availableRegfiles.where((r) => r.name == val);
                                              if (regfiles.isNotEmpty) {
                                                 var regfile = regfiles.first;
                                                 List<int> validAddrs = [];
                                                 if (regfile.addresses != null) validAddrs.addAll(regfile.addresses!);
                                                 if (regfile.addressMap != null) validAddrs.addAll(regfile.addressMap!.keys);
                                                 if (validAddrs.isEmpty || validAddrs.contains(_i2cDeviceAddress!)) {
                                                    state.mountI2cDevice(currentBus!.name, _i2cDeviceAddress!, regfile);
                                                 }
                                              }
                                           } else {
                                              state.mountI2cDevice(currentBus!.name, _i2cDeviceAddress!, null);
                                           }
                                        }
                                     }
                                  });
                               }
                             );
                          }),

                        ]
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              if (isI2c) ...[
                 // I2C Specific UI
                 Row(
                   crossAxisAlignment: CrossAxisAlignment.start,
                   children: [
                     Expanded(
                       flex: 1,
                       child: Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           _buildLabel('帧类型', 'Frame Type'),
                           const SizedBox(height: 8),
                           DropdownButtonFormField<String>(
                             initialValue: _availableI2cFrameTypes.contains(_i2cFrameType) ? _i2cFrameType : 'Any',
                             dropdownColor: const Color(0xFF333333),
                             style: const TextStyle(color: Colors.white),
                             decoration: const InputDecoration(
                               filled: true,
                               fillColor: Color(0xFF1E1E1E),
                               border: OutlineInputBorder(),
                               contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                             ),
                             items: _availableI2cFrameTypes.map((type) {
                                String labelCn = type == 'Any' ? '读或写' : (type == 'Write Only' ? '仅写' : '仅读');
                                String labelEn = type == 'Any' ? 'Write or Read' : type;
                                return DropdownMenuItem(value: type, child: _buildItemText(labelCn, labelEn));
                             }).toList(),
                             onChanged: (val) {
                               setState(() {
                                 _i2cFrameType = val!;
                                 _lastI2cFrameTypeForCache = null;
                               });
                             },
                           ),
                         ],
                       ),
                     ),
                     const SizedBox(width: 16),
                     
                     Expanded(
                       flex: 2,
                       child: Row(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Expanded(
                             flex: 1,
                             child: Column(
                               crossAxisAlignment: CrossAxisAlignment.start,
                               children: [
                                 _buildLabel('设备地址', 'Device Address'),
                                 const SizedBox(height: 8),
                                 DropdownButtonFormField<int?>(
                                   initialValue: _i2cDeviceAddress,
                                   dropdownColor: const Color(0xFF333333),
                                   style: const TextStyle(color: Colors.white),
                                   decoration: const InputDecoration(
                                     filled: true,
                                     fillColor: Color(0xFF1E1E1E),
                                     border: OutlineInputBorder(),
                                     contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                   ),
                                   items: [
                                     if (_i2cDeviceAddress != null && !_cachedI2cDevices.contains(_i2cDeviceAddress))
                                       DropdownMenuItem<int?>(
                                         value: _i2cDeviceAddress,
                                         child: Text('0x (无匹配/No match)', style: const TextStyle(color: Colors.grey)),
                                       ),
                                     ..._cachedI2cDevices.map((addr) {
                                       String hex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, "0")}';
                                       String alias = '';
                                       if (currentBus != null && currentBus.decoder is I2cDecoder) {
                                           var i2cDec = currentBus.decoder as I2cDecoder;
                                           if (i2cDec.deviceAliases.containsKey(addr)) {
                                               alias = ' (${i2cDec.deviceAliases[addr]})';
                                           }
                                       }
                                       return DropdownMenuItem<int?>(value: addr, child: Text(hex + alias));
                                     })
                                   ],
                                   onChanged: (_cachedI2cDevices.isEmpty) ? null : (val) {
                                      setState(() {
                                         _i2cDeviceAddress = val;
                                         _lastDeviceAddressForCache = null;
                                         if (_selectedI2cProtocol != null && val != null) {
                                            var regfiles = state.availableRegfiles.where((r) => r.name == _selectedI2cProtocol);
                                            if (regfiles.isNotEmpty) {
                                               state.mountI2cDevice(currentBus!.name, val, regfiles.first);
                                            }
                                         }
                                      });
                                   },
                                   hint: const Text('选择设备 (Select a Device)', style: TextStyle(color: Colors.white38)),
                                 ),
                               ],
                             ),
                           ),
                           const SizedBox(width: 16),
                           
                           Expanded(
                             flex: 1,
                             child: Builder(
                               builder: (context) {
                                  bool isMemory = false;
                                  if (currentBus != null && _i2cDeviceAddress != null) {
                                     var regfile = state.getRegfileFor(currentBus.name, _i2cDeviceAddress!);
                                     if (regfile != null && regfile.hasSubaddress == true) isMemory = true;
                                     if (_i2cDeviceAddress! >= 0x50 && _i2cDeviceAddress! <= 0x57) isMemory = true;
                                  }
                                  String labelCn = isMemory ? '片内首地址' : '寄存器地址';
                                  String labelEn = isMemory ? 'Internal Addr' : 'Register Addr';
                                  
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                       _buildLabel(labelCn, labelEn),
                                       const SizedBox(height: 8),
                                       DropdownButtonFormField<int?>(
                                         initialValue: _i2cRegisterAddress,
                                         dropdownColor: const Color(0xFF333333),
                                         style: const TextStyle(color: Colors.white),
                                         decoration: const InputDecoration(
                                           filled: true,
                                           fillColor: Color(0xFF1E1E1E),
                                           border: OutlineInputBorder(),
                                           contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                         ),
                                         items: [
                                            if (_i2cRegisterAddress != null && !_cachedI2cRegisters.contains(_i2cRegisterAddress))
                                              DropdownMenuItem<int?>(
                                                value: _i2cRegisterAddress,
                                                child: Text('0x (无匹配/No match)', style: const TextStyle(color: Colors.grey)),
                                              ),
                                           DropdownMenuItem<int?>(value: null, child: _buildItemText('不限', 'Any (leave blank)')),
                                           ..._cachedI2cRegisters.map((addr) {
                                             String hex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, "0")}';
                                             String alias = '';
                                             if (currentBus != null && _selectedI2cProtocol != null) {
                                                var regfiles = state.availableRegfiles.where((r) => r.name == _selectedI2cProtocol);
                                                if (regfiles.isNotEmpty) {
                                                   var regfile = regfiles.first;
                                                   if (regfile.registers.containsKey(addr)) {
                                                      alias = ' (${regfile.registers[addr]!.name})';
                                                   }
                                                }
                                             } else if (currentBus != null && _i2cDeviceAddress != null) {
                                                var regfile = state.getRegfileFor(currentBus.name, _i2cDeviceAddress!);
                                                if (regfile != null && regfile.registers.containsKey(addr)) {
                                                   alias = ' (${regfile.registers[addr]!.name})';
                                                }
                                             }
                                             return DropdownMenuItem<int?>(value: addr, child: Text(hex + alias));
                                           })
                                         ],
                                         onChanged: (_cachedI2cDevices.isEmpty) ? null : (val) => setState(() => _i2cRegisterAddress = val),
                                       ),
                                    ],
                                  );
                               }
                             ),
                           ),
                         ],
                       ),
                     ),
                   ],
                 ),
                 const SizedBox(height: 16),
                 Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildLabel('数据格式', 'Data Format'),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: _format,
                            dropdownColor: const Color(0xFF333333),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              filled: true,
                              fillColor: Color(0xFF1E1E1E),
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'Hex', child: Text('Hex')),
                              DropdownMenuItem(value: 'Dec', child: Text('Dec')),
                              DropdownMenuItem(value: 'Bin', child: Text('Bin')),
                              DropdownMenuItem(value: 'ASCII', child: Text('ASCII')),
                            ],
                            onChanged: (val) {
                               setState(() {
                                 _format = val!;
                                 _valueController.clear();
                               });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildLabel('数据内容', 'Data Content'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _valueController,
                            style: const TextStyle(color: Colors.white),
                            inputFormatters: [
                              if (_format == 'Hex')
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                              if (_format == 'Dec')
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                              if (_format == 'Bin')
                                FilteringTextInputFormatter.allow(RegExp(r'[01 ]')),
                            ],
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFF1E1E1E),
                              border: const OutlineInputBorder(),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              hintText: _format == 'ASCII' ? 'e.g. hello (留空不限)' : 'e.g. 12 34 (空格分隔，大小受限于位宽)',
                              hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                            ),
                            onSubmitted: (_) => _onSearch(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ] else if (isSpi) ...[
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('SPI指令', 'SPI Command'),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<int?>(
                              initialValue: _spiCommand,
                              dropdownColor: const Color(0xFF333333),
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xFF1E1E1E),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: [
                                if (_spiCommand != null && !_cachedSpiCommands.contains(_spiCommand))
                                  DropdownMenuItem<int?>(
                                    value: _spiCommand,
                                    child: const Text('0x (无匹配/No match)', style: TextStyle(color: Colors.grey)),
                                  ),
                                DropdownMenuItem<int?>(
                                   value: null, 
                                   child: _buildItemText('不限', 'Any (leave blank)')
                                ),
                                ..._cachedSpiCommands.map((cmd) {
                                  String hex = '0x${cmd.toRadixString(16).toUpperCase().padLeft(2, "0")}';
                                  String alias = '';
                                  if (currentBus != null) {
                                      String? protocolFile;
                                      if (currentBus.decoder?.name == 'SPI') {
                                        protocolFile = (currentBus.decoder as SpiDecoder).protocolFile;
                                      } else if (currentBus.decoder?.name == 'SPI_ADS7038H') {
                                        protocolFile = (currentBus.decoder as Ads7038hDecoder).protocolFile;
                                      }
                                      if (protocolFile != null) {
                                          var regfiles = state.availableSpiRegfiles.where((r) => r.name == protocolFile);
                                          if (regfiles.isNotEmpty) {
                                              var regfile = regfiles.first;
                                              if (regfile.commands != null && regfile.commands!.containsKey(cmd)) {
                                                  alias = ' (${regfile.commands![cmd]!.name})';
                                              } else if (regfile.registers.containsKey(cmd)) {
                                                  alias = ' (${regfile.registers[cmd]!.name})';
                                              }
                                          }
                                      }
                                  }
                                  return DropdownMenuItem<int?>(value: cmd, child: Text(hex + alias));
                                })
                              ],
                              onChanged: (_cachedSpiCommands.isEmpty) ? null : (val) {
                                 setState(() {
                                    _spiCommand = val;
                                    _lastSpiCommandForCache = null;
                                 });
                              },
                              hint: const Text('选择指令 (Select a Command)', style: TextStyle(color: Colors.white38)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 1,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildLabel('数据格式', 'Data Format'),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    initialValue: _format,
                                    dropdownColor: const Color(0xFF333333),
                                    style: const TextStyle(color: Colors.white),
                                    decoration: const InputDecoration(
                                      filled: true,
                                      fillColor: Color(0xFF1E1E1E),
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    ),
                                    items: const [
                                      DropdownMenuItem(value: 'Hex', child: Text('Hex')),
                                      DropdownMenuItem(value: 'Dec', child: Text('Dec')),
                                      DropdownMenuItem(value: 'Bin', child: Text('Bin')),
                                      DropdownMenuItem(value: 'ASCII', child: Text('ASCII')),
                                    ],
                                    onChanged: (val) {
                                       setState(() {
                                         _format = val!;
                                         _valueController.clear();
                                       });
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildLabel('MISO数据', 'MISO Data'),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _valueController,
                                    style: const TextStyle(color: Colors.white),
                                    inputFormatters: [
                                      if (_format == 'Hex')
                                        FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                                      if (_format == 'Dec')
                                        FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                                      if (_format == 'Bin')
                                        FilteringTextInputFormatter.allow(RegExp(r'[01 ]')),
                                    ],
                                    decoration: InputDecoration(
                                      filled: true,
                                      fillColor: const Color(0xFF1E1E1E),
                                      border: const OutlineInputBorder(),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      hintText: _format == 'ASCII' ? 'e.g. hello (留空不限)' : 'e.g. 12 34 (空格分隔，大小受限于位宽)',
                                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                                    ),
                                    onSubmitted: (_) => _onSearch(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ] else if (hasDecoder) ...[
                if (isRawUart) ...[
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('通道', 'Channel'),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: _channel,
                              dropdownColor: const Color(0xFF333333),
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xFF1E1E1E),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: [
                                DropdownMenuItem(value: 'Any', child: _buildItemText('不限', 'Any')),
                                DropdownMenuItem(value: 'TXD', child: _buildItemText('仅 TXD', 'TXD Only')),
                                DropdownMenuItem(value: 'RXD', child: _buildItemText('仅 RXD', 'RXD Only')),
                              ],
                              onChanged: (val) => setState(() => _channel = val ?? 'Any'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('格式', 'Format'),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: _format,
                              dropdownColor: const Color(0xFF333333),
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xFF1E1E1E),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'Hex', child: Text('Hex')),
                                DropdownMenuItem(value: 'Dec', child: Text('Dec')),
                                DropdownMenuItem(value: 'Bin', child: Text('Bin')),
                                DropdownMenuItem(value: 'ASCII', child: Text('ASCII')),
                              ],
                              onChanged: (val) {
                                 setState(() {
                                   _format = val!;
                                   _valueController.clear();
                                 });
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('数值', 'Value'),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _valueController,
                              style: const TextStyle(color: Colors.white),
                              inputFormatters: [
                                if (_format == 'Hex')
                                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                                if (_format == 'Dec')
                                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                                if (_format == 'Bin')
                                  FilteringTextInputFormatter.allow(RegExp(r'[01 ]')),
                              ],
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: const Color(0xFF1E1E1E),
                                border: const OutlineInputBorder(),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                hintText: _format == 'ASCII' ? 'e.g. hello (留空不限)' : 'e.g. 12 34 (空格分隔，大小受限于位宽)',
                                hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                              ),
                              onSubmitted: (_) => _onSearch(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                ] else if (isUartWithProtocol) ...[
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('通道', 'Channel'),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: _channel,
                              dropdownColor: const Color(0xFF333333),
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xFF1E1E1E),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: [
                                DropdownMenuItem(value: 'Any', child: _buildItemText('不限', 'Any')),
                                DropdownMenuItem(value: 'TXD', child: _buildItemText('仅 TXD', 'TXD Only')),
                                DropdownMenuItem(value: 'RXD', child: _buildItemText('仅 RXD', 'RXD Only')),
                              ],
                              onChanged: (val) => setState(() => _channel = val ?? 'Any'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('字段', 'Field'),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: currentUartField,
                              dropdownColor: const Color(0xFF333333),
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Color(0xFF1E1E1E),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: uartFields.map((f) => DropdownMenuItem(value: f, child: _buildItemText(f, 'Field'))).toList(),
                              onChanged: (val) {
                                 setState(() {
                                   _uartField = val!;
                                   _valueController.clear();
                                 });
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('数值', 'Value'),
                            const SizedBox(height: 8),
                            if (fieldValues[currentUartField] != null && fieldValues[currentUartField]!.isNotEmpty)
                              DropdownButtonFormField<String>(
                                key: ValueKey(currentUartField),
                                initialValue: (fieldValues[currentUartField]?.containsKey(int.tryParse(_valueController.text, radix: 16) ?? -1) ?? false) 
                                       ? _valueController.text.toUpperCase().padLeft(2, '0') : null,
                                dropdownColor: const Color(0xFF333333),
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  filled: true,
                                  fillColor: Color(0xFF1E1E1E),
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  hintText: '请选择数值',
                                  hintStyle: TextStyle(color: Colors.white38),
                                ),
                                items: fieldValues[currentUartField]!.entries.map((e) => DropdownMenuItem(
                                  value: e.key.toRadixString(16).toUpperCase().padLeft(2, '0'),
                                  child: Text(e.value.isEmpty ? '0x${e.key.toRadixString(16).toUpperCase().padLeft(2, '0')}' : '0x${e.key.toRadixString(16).toUpperCase().padLeft(2, '0')} (${e.value})'),
                                )).toList(),
                                onChanged: (val) {
                                   setState(() {
                                     _valueController.text = val!;
                                   });
                                },
                              )
                            else
                              TextField(
                                controller: _valueController,
                                style: const TextStyle(color: Colors.white),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                                ],
                                decoration: const InputDecoration(
                                  filled: true,
                                  fillColor: Color(0xFF1E1E1E),
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  hintText: 'e.g. 12 34 (Hex format)',
                                  hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
                                ),
                                onSubmitted: (_) => _onSearch(),
                              ),
                          ],
                        ),
                      ),
                    ],
                  )
                ] else ...[
                  if (decoderType == 'UART') ...[
                    _buildLabel('通道', 'Channel'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _channel,
                      dropdownColor: const Color(0xFF333333),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        filled: true,
                        fillColor: Color(0xFF1E1E1E),
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: [
                        DropdownMenuItem(value: 'Any', child: _buildItemText('不限', 'Any')),
                        DropdownMenuItem(value: 'TXD', child: _buildItemText('仅 TXD', 'TXD Only')),
                        DropdownMenuItem(value: 'RXD', child: _buildItemText('仅 RXD', 'RXD Only')),
                      ],
                      onChanged: (val) => setState(() => _channel = val ?? 'Any'),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _buildLabel('匹配条件', 'Match Condition'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _condition,
                    dropdownColor: const Color(0xFF333333),
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF1E1E1E),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: conditions.map((c) => DropdownMenuItem(value: c, child: _buildItemText(conditionCn[c] ?? c, c))).toList(),
                    onChanged: (val) => setState(() => _condition = val!),
                  ),
                ]
              ],
              
              if (!disableInput && !isRawUart && !isUartWithProtocol && !isI2c && !(hasDecoder && (currentBus.decoder?.name == 'SPI' || currentBus.decoder?.name == 'SPI_ADS7038H'))) ...[
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildLabel(isI2c ? '数据格式' : '格式', isI2c ? 'Data Format' : 'Format'),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: _format,
                            dropdownColor: const Color(0xFF333333),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              filled: true,
                              fillColor: Color(0xFF1E1E1E),
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'Hex', child: Text('Hex')),
                              DropdownMenuItem(value: 'Dec', child: Text('Dec')),
                              DropdownMenuItem(value: 'Bin', child: Text('Bin')),
                              DropdownMenuItem(value: 'ASCII', child: Text('ASCII')),
                            ],
                            onChanged: (val) {
                               setState(() {
                                 _format = val!;
                                 _valueController.clear();
                               });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildLabel(isI2c ? '数据内容' : '数值', isI2c ? 'Data Content' : 'Value'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _valueController,
                            style: const TextStyle(color: Colors.white),
                            inputFormatters: [
                              if (_format == 'Hex')
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                              if (_format == 'Dec')
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                              if (_format == 'Bin')
                                FilteringTextInputFormatter.allow(RegExp(r'[01 ]')),
                            ],
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFF1E1E1E),
                              border: const OutlineInputBorder(),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              hintText: _format == 'ASCII' ? 'e.g. hello (留空不限)' : 'e.g. 12 34 (空格分隔，大小受限于位宽)',
                              hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                            ),
                            onSubmitted: (_) => _onSearch(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
              
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildLabel('标线颜色', 'Marker Color'),
                  const SizedBox(width: 16),
                  InkWell(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            backgroundColor: const Color(0xFF222222),
                            title: const Text('选择颜色 (Select Color)', style: TextStyle(color: Colors.white)),
                            content: SingleChildScrollView(
                              child: BlockPicker(
                                pickerColor: state.searchMatchColor,
                                onColorChanged: (Color color) {
                                  state.setSearchMatchColor(color);
                                  setState(() {});
                                },
                              ),
                            ),
                            actions: <Widget>[
                              TextButton(
                                child: const Text('完成 (Done)', style: TextStyle(color: Colors.white)),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                },
                              ),
                            ],
                          );
                        },
                      );
                    },
                    child: Container(
                      width: 48,
                      height: 24,
                      decoration: BoxDecoration(
                        color: state.searchMatchColor,
                        border: Border.all(color: Colors.white38),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
              
              if (_message != null) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(_message!, style: TextStyle(color: _isError ? Colors.redAccent : Colors.greenAccent, fontSize: 13))),
                    if (!_isError && state.searchMatches.length > 1)
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios, size: 14, color: Colors.white),
                            onPressed: () => state.jumpToPrevSearchMatch(),
                            tooltip: 'Previous Match (Shift+F3)',
                          ),
                          Text('${state.currentSearchMatchIndex + 1}/${state.searchMatches.length}', style: const TextStyle(color: Colors.white)),
                          IconButton(
                            icon: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white),
                            onPressed: () => state.jumpToNextSearchMatch(),
                            tooltip: 'Next Match (F3)',
                          ),
                        ],
                      )
                  ],
                )
              ]
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: _buildItemText('关闭', 'Close'),
        ),
        ElevatedButton(
          onPressed: buses.isEmpty ? null : _onSearch,
          child: _buildItemText('全局搜索', 'Search All'),
        ),
      ],
    );
  }
}
