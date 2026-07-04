import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  bool _isBigEndian = true;
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

  @override
  void initState() {
    super.initState();
    final state = context.read<OscilloscopeState>();
    if (state.searchMatches.isNotEmpty && state.lastSearchConfig != null) {
      var conf = state.lastSearchConfig!;
      _selectedBusName = conf['busName'];
      _format = conf['format'] ?? 'Hex';
      _condition = conf['condition'] ?? 'Data Content Match';
      _channel = conf['channel'] ?? 'Any';
      _isBigEndian = conf['isBigEndian'] ?? true;
      _valueController.text = conf['value'] ?? '';
      _i2cFrameType = conf['i2cFrameType'] ?? 'Any';
      _i2cDeviceAddress = conf['i2cDeviceAddress'];
      _i2cRegisterAddress = conf['i2cRegisterAddress'];
    } else if (state.digitalChannel.buses.isNotEmpty) {
      _selectedBusName = state.digitalChannel.buses.first.name;
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

    if (isI2c) {
       _updateCaches(state, currentBus);
    }

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

    return AlertDialog(
      backgroundColor: const Color(0xFF222222),
      title: const Text('Search Bus Value', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Target Bus', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              if (buses.isEmpty)
                const Text('No digital buses loaded.', style: TextStyle(color: Colors.redAccent))
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
                  items: buses.map((b) => DropdownMenuItem(
                    value: b.name,
                    child: Text(b.name + (b.decoder != null ? ' (${b.decoder!.name})' : '')),
                  )).toList(),
                  onChanged: (val) {
                     setState(() {
                       _selectedBusName = val;
                       _lastBusNameForCache = null;
                     });
                  },
                ),
              const SizedBox(height: 16),
              
              if (isI2c) ...[
                 // I2C Specific UI
                 const Text('Frame Type', style: TextStyle(color: Colors.white70)),
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
                   items: const [
                     DropdownMenuItem(value: 'Any', child: Text('Write or Read')),
                     DropdownMenuItem(value: 'Write Only', child: Text('Write Only')),
                     DropdownMenuItem(value: 'Read Only', child: Text('Read Only')),
                   ],
                   onChanged: (val) => setState(() => _i2cFrameType = val!),
                 ),
                 const SizedBox(height: 16),
                 
                 const Text('Device Address', style: TextStyle(color: Colors.white70)),
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
                   hint: const Text('Select a Device', style: TextStyle(color: Colors.white38)),
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
                      String label = isMemory ? '片内首地址 (Internal Addr)' : '寄存器地址 (Register Addr)';
                      
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                           Text(label, style: const TextStyle(color: Colors.white70)),
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
                               const DropdownMenuItem<int?>(value: null, child: Text('Any (留空)')),
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
                if (decoderType == 'UART') ...[
                  const Text('Channel', style: TextStyle(color: Colors.white70)),
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
                    items: const [
                      DropdownMenuItem(value: 'Any', child: Text('Any')),
                      DropdownMenuItem(value: 'TXD', child: Text('TXD Only')),
                      DropdownMenuItem(value: 'RXD', child: Text('RXD Only')),
                    ],
                    onChanged: (val) => setState(() => _channel = val ?? 'Any'),
                  ),
                  const SizedBox(height: 16),
                ],
                const Text('Match Condition', style: TextStyle(color: Colors.white70)),
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
                  items: conditions.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (val) => setState(() => _condition = val!),
                ),
              ] else ...[
                const Text('Endianness', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                DropdownButtonFormField<bool>(
                  initialValue: _isBigEndian,
                  dropdownColor: const Color(0xFF333333),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Color(0xFF1E1E1E),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: const [
                    DropdownMenuItem(value: true, child: Text('Big Endian (MSB First)')),
                    DropdownMenuItem(value: false, child: Text('Little Endian (LSB First)')),
                  ],
                  onChanged: (val) => setState(() => _isBigEndian = val ?? true),
                ),
                if (currentBus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      'Hint: LSB is physically on pin ${!_isBigEndian ? currentBus.startPin : currentBus.endPin}',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ),
              ],
              
              if (!disableInput) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(isI2c ? 'Data Format' : 'Format', style: const TextStyle(color: Colors.white70)),
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
                            onChanged: (val) => setState(() => _format = val!),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(isI2c ? 'Data Content' : 'Value', style: const TextStyle(color: Colors.white70)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _valueController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              filled: true,
                              fillColor: Color(0xFF1E1E1E),
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              hintText: 'e.g. 12 34 (leave blank for Any)',
                              hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
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
          child: const Text('Close', style: TextStyle(color: Colors.white70)),
        ),
        ElevatedButton(
          onPressed: buses.isEmpty ? null : _onSearch,
          child: const Text('Search All'),
        ),
      ],
    );
  }
}
