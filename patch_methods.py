import sys

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# Add _availableI2cFrameTypes
search1 = "  List<String> _availableSpiFrameTypes = ['Any'];"
replace1 = "  List<String> _availableI2cFrameTypes = ['Any'];\n  String? _lastI2cFrameTypeForCache;\n  List<String> _availableSpiFrameTypes = ['Any'];"
content = content.replace(search1, replace1)

# Add I2C methods before _updateSpiCaches
search2 = "  void _updateSpiCaches(OscilloscopeState state, DigitalBus? bus) {"
replace2 = '''  List<String> _getAvailableI2cFrameTypes(DigitalBus bus) {
    if (bus.decoder == null || bus.decoder!.name != 'I2C') return ['Any', 'Read Only', 'Write Only'];
    bool hasRead = false;
    bool hasWrite = false;
    for (var frame in bus.decoder!.frames) {
      if (frame.summary.startsWith('Read')) hasRead = true;
      if (frame.summary.startsWith('Write')) hasWrite = true;
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
    var list = addrs.toList();
    list.sort();
    return list;
  }

  List<int> _getFilteredI2cRegisters(DigitalBus bus, OscilloscopeState state, String frameType, int? deviceAddr) {
    if (bus.decoder == null || bus.decoder!.name != 'I2C') return [];
    Set<int> addrs = {};
    for (var frame in bus.decoder!.frames) {
      bool isRead = frame.summary.startsWith('Read');
      bool isWrite = frame.summary.startsWith('Write');
      if (frameType == 'Read Only' && !isRead) continue;
      if (frameType == 'Write Only' && !isWrite) continue;
      
      int? currentAddr;
      for (var p in frame.packets) {
        if (p.type == PacketType.address && p.rawValue != null) {
          currentAddr = p.rawValue;
        } else if (p.type == PacketType.data && p.data.startsWith('ADDR:') && p.rawValue != null) {
          if (deviceAddr == null || currentAddr == deviceAddr) {
             addrs.add(p.rawValue!);
          }
          break;
        }
      }
    }
    var list = addrs.toList();
    list.sort();
    return list;
  }

  void _updateI2cCaches(OscilloscopeState state, DigitalBus bus) {
    if (_lastBusNameForCache == bus.name && _lastI2cFrameTypeForCache == _i2cFrameType && _lastDeviceAddressForCache == _i2cDeviceAddress) {
      return;
    }
    
    _lastBusNameForCache = bus.name;
    _lastI2cFrameTypeForCache = _i2cFrameType;
    _lastDeviceAddressForCache = _i2cDeviceAddress;

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
  }

  void _updateSpiCaches(OscilloscopeState state, DigitalBus? bus) {'''
content = content.replace(search2, replace2)

# Update _updateCaches logic
import re
# Find the exact _updateCaches block
update_caches_match = re.search(r'  void _updateCaches\(OscilloscopeState state, DigitalBus\? bus\) \{.*?(?=  void _onSearch)', content, re.DOTALL)
if update_caches_match:
    old_update = update_caches_match.group(0)
    new_update = '''  void _updateCaches(OscilloscopeState state, DigitalBus? bus) {
    if (bus == null) return;
    if (bus.decoder?.name == 'I2C') {
       _updateI2cCaches(state, bus);
    } else if (bus.decoder?.name == 'SPI') {
       _updateSpiCaches(state, bus);
    }
  }

'''
    content = content.replace(old_update, new_update)

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
