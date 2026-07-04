import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../../providers/oscilloscope_state.dart';
import '../models/protocol_decoder.dart';

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
  List<String> _cachedUartProtocols = [];

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

  void _updateCaches(OscilloscopeState state, DigitalBus? bus) {
    if (bus == null || bus.decoder?.name != 'I2C') {
      _cachedI2cDevices.clear();
      _cachedI2cRegisters.clear();
      _i2cDeviceAddress = null;
      _i2cRegisterAddress = null;
      return;
    }

    if (_lastBusNameForCache != bus.name) {
      _cachedI2cDevices = state.getDetectedI2cDevices(bus);
      _lastBusNameForCache = bus.name;
      if (!_cachedI2cDevices.contains(_i2cDeviceAddress)) {
         _i2cDeviceAddress = _cachedI2cDevices.isNotEmpty ? _cachedI2cDevices.first : null;
      }
    }

    if (_lastDeviceAddressForCache != _i2cDeviceAddress) {
       if (_i2cDeviceAddress != null) {
          _cachedI2cRegisters = state.getDetectedI2cRegisters(bus, _i2cDeviceAddress!);
       } else {
          _cachedI2cRegisters.clear();
       }
       _lastDeviceAddressForCache = _i2cDeviceAddress;
       _i2cRegisterAddress = null; // Reset register selection when device changes
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
    };

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
      uartField: (!isI2c && bus.decoder != null && bus.decoder!.name == 'UART' && (bus.decoder as UartDecoder).protocolFile != null) ? _uartField : null,
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
    bool isRawUart = hasDecoder && decoderType == 'UART' && (currentBus!.decoder as UartDecoder).protocolFile == null;
    bool isUartWithProtocol = hasDecoder && decoderType == 'UART' && (currentBus!.decoder as UartDecoder).protocolFile != null;

    if (isI2c) {
       _updateCaches(state, currentBus);
    }
    
    List<String> uartFields = ['CMD'];
    Map<String, Map<int, String>> fieldValues = {};
    if (isUartWithProtocol) {
      var protocol = state.availableUartProtocols[(currentBus!.decoder as UartDecoder).protocolFile];
      if (protocol != null) {
        Map<int, String> cmdValues = {};
        for (var cmdId in protocol.commands.keys) {
          cmdValues[cmdId] = protocol.commands[cmdId]!.name;
        }
        fieldValues['CMD'] = cmdValues;

        for (var cmd in protocol.commands.values) {
          var txPayload = cmd.tx?.payload ?? [];
          var rxPayload = cmd.rx?.payload ?? [];
          for (var f in [...txPayload, ...rxPayload]) {
            if (!uartFields.contains(f.name)) {
               uartFields.add(f.name);
            }
            if (f.valueMap != null && f.valueMap!.isNotEmpty) {
               if (fieldValues[f.name] == null) fieldValues[f.name] = {};
               fieldValues[f.name]!.addAll(f.valueMap!);
            }
          }
        }
      }
      uartFields.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
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
                             } else if (decoderType == 'I2C') {
                                if (currentBus != null && _i2cDeviceAddress != null) {
                                   initialProtocolFile = state.mountedRegfiles[currentBus!.name]?[_i2cDeviceAddress!]?.name;
                                }
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
                                  if (decoderType == 'SPI') ...state.availableSpiRegfiles.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name))),
                                  if (decoderType == 'I2C') ...state.availableRegfiles.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name))),
                               ],
                               onChanged: (decoderType == 'I2C' && _i2cDeviceAddress == null) ? null : (val) {
                                  setState(() {
                                     if (decoderType == 'UART') {
                                        (currentBus!.decoder as UartDecoder).protocolFile = val;
                                        state.forceUpdate();
                                     } else if (decoderType == 'SPI') {
                                        (currentBus!.decoder as SpiDecoder).protocolFile = val;
                                        state.forceUpdate();
                                     } else if (decoderType == 'I2C' && _i2cDeviceAddress != null) {
                                        var regfile = val == null ? null : state.availableRegfiles.firstWhere((r) => r.name == val);
                                        state.mountI2cDevice(currentBus!.name, _i2cDeviceAddress!, regfile);
                                     }
                                  });
                               }
                             );
                          }),
                          if (decoderType == 'I2C' && _i2cDeviceAddress == null)
                             const Padding(
                               padding: EdgeInsets.only(top: 4.0),
                               child: Text('请先在下方选择设备地址', style: TextStyle(color: Colors.redAccent, fontSize: 11)),
                             ),
                        ]
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              if (isI2c) ...[
                 // I2C Specific UI
                 _buildLabel('帧类型', 'Frame Type'),
                 const SizedBox(height: 8),
                 DropdownButtonFormField<String>(
                   initialValue: _i2cFrameType,
                   dropdownColor: const Color(0xFF333333),
                   style: const TextStyle(color: Colors.white),
                   decoration: const InputDecoration(
                     filled: true,
                     fillColor: Color(0xFF1E1E1E),
                     border: OutlineInputBorder(),
                     contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                   ),
                   items: [
                     DropdownMenuItem(value: 'Any', child: _buildItemText('读或写', 'Write or Read')),
                     DropdownMenuItem(value: 'Write Only', child: _buildItemText('仅写', 'Write Only')),
                     DropdownMenuItem(value: 'Read Only', child: _buildItemText('仅读', 'Read Only')),
                   ],
                   onChanged: (val) => setState(() => _i2cFrameType = val!),
                 ),
                 const SizedBox(height: 16),
                 
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
                   items: _cachedI2cDevices.map((addr) {
                     String hex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, '0')}';
                     String alias = '';
                     if (currentBus != null && currentBus.decoder is I2cDecoder) {
                         var i2cDec = currentBus.decoder as I2cDecoder;
                         if (i2cDec.deviceAliases.containsKey(addr)) {
                             alias = ' ${i2cDec.deviceAliases[addr]}';
                         }
                     }
                     return DropdownMenuItem<int?>(value: addr, child: Text(hex + alias));
                   }).toList(),
                   onChanged: (val) {
                      setState(() {
                         _i2cDeviceAddress = val;
                         _lastDeviceAddressForCache = null;
                      });
                   },
                   hint: const Text('选择设备 (Select a Device)', style: TextStyle(color: Colors.white38)),
                 ),
                 const SizedBox(height: 16),
                 
                 Builder(
                   builder: (context) {
                      bool isMemory = false;
                      if (currentBus != null && _i2cDeviceAddress != null) {
                         var regfile = state.getRegfileFor(currentBus.name, _i2cDeviceAddress!);
                         if (regfile != null && regfile.hasSubaddress == true) isMemory = true;
                         // Also check common EEPROM addresses
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
                               DropdownMenuItem<int?>(value: null, child: _buildItemText('不限', 'Any (leave blank)')),
                               ..._cachedI2cRegisters.map((addr) {
                                 String hex = '0x${addr.toRadixString(16).toUpperCase().padLeft(2, '0')}';
                                 String alias = '';
                                 if (currentBus != null && _i2cDeviceAddress != null) {
                                    var regfile = state.getRegfileFor(currentBus.name, _i2cDeviceAddress!);
                                    if (regfile != null && regfile.registers.containsKey(addr)) {
                                       alias = ' ${regfile.registers[addr]!.name}';
                                    }
                                 }
                                 return DropdownMenuItem<int?>(value: addr, child: Text(hex + alias));
                               })
                             ],
                             onChanged: (val) => setState(() => _i2cRegisterAddress = val),
                           ),
                        ],
                      );
                   }
                 )
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
                                initialValue: (fieldValues[currentUartField]?.containsKey(int.tryParse(_valueController.text) ?? -1) ?? false) 
                                       ? (int.tryParse(_valueController.text) ?? -1).toString() : null,
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
                                  value: e.key.toString(),
                                  child: Text('0x${e.key.toRadixString(16).toUpperCase().padLeft(2, '0')} (${e.value})'),
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
              
              if (!disableInput && !isRawUart && !isUartWithProtocol) ...[
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
                            tooltip: 'Previous Match',
                          ),
                          Text('${state.currentSearchMatchIndex + 1}/${state.searchMatches.length}', style: const TextStyle(color: Colors.white)),
                          IconButton(
                            icon: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white),
                            onPressed: () => state.jumpToNextSearchMatch(),
                            tooltip: 'Next Match',
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
