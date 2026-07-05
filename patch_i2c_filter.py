import sys
import re

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add _selectedI2cProtocol
content = content.replace("  String? _lastI2cFrameTypeForCache;", "  String? _lastI2cFrameTypeForCache;\n  String? _selectedI2cProtocol;\n  String? _lastI2cProtocolForCache;")

# 2. Update _getFilteredI2cDevices
search_get_filtered_dev = r"  List<int> _getFilteredI2cDevices\(DigitalBus bus, OscilloscopeState state, String frameType\) \{.*?return list;\n  \}"
replace_get_filtered_dev = '''  List<int> _getFilteredI2cDevices(DigitalBus bus, OscilloscopeState state, String frameType) {
    if (bus.decoder == null || bus.decoder!.name != 'I2C') return [];
    Set<int> addrs = {};
    for (var frame in bus.decoder!.frames) {
      bool isRead = frame.summary.startsWith('Read');
      bool isWrite = frame.summary.startsWith('Write');
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
          if (regfile.addresses != null && regfile.addresses!.isNotEmpty) {
             addrs = addrs.intersection(regfile.addresses!.toSet());
          }
       }
    }
    
    var list = addrs.toList();
    list.sort();
    return list;
  }'''
content = re.sub(search_get_filtered_dev, replace_get_filtered_dev, content, flags=re.DOTALL)

# 3. Update _updateI2cCaches
search_update_caches = r"  void _updateI2cCaches\(OscilloscopeState state, DigitalBus bus\) \{.*?_i2cRegisterAddress = null;\n    \}\n  \}"
replace_update_caches = '''  void _updateI2cCaches(OscilloscopeState state, DigitalBus bus) {
    if (_lastBusNameForCache == bus.name && _lastI2cFrameTypeForCache == _i2cFrameType && _lastDeviceAddressForCache == _i2cDeviceAddress && _lastI2cProtocolForCache == _selectedI2cProtocol) {
      return;
    }
    
    _lastBusNameForCache = bus.name;
    _lastI2cFrameTypeForCache = _i2cFrameType;
    _lastDeviceAddressForCache = _i2cDeviceAddress;
    _lastI2cProtocolForCache = _selectedI2cProtocol;

    _availableI2cFrameTypes = _getAvailableI2cFrameTypes(bus);
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

    _cachedI2cRegisters = _getFilteredI2cRegisters(bus, state, _i2cFrameType, _i2cDeviceAddress);
    if (_i2cRegisterAddress != null && !_cachedI2cRegisters.contains(_i2cRegisterAddress)) {
      _i2cRegisterAddress = null;
    }
  }'''
content = re.sub(search_update_caches, replace_update_caches, content, flags=re.DOTALL)

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
