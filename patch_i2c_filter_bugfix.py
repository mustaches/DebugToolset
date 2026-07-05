import sys
import re

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# Modify _getAvailableI2cFrameTypes to take OscilloscopeState state
search_get_avail = r"  List<String> _getAvailableI2cFrameTypes\(DigitalBus bus\) \{.*?return types;\n    \}"
replace_get_avail = '''  List<String> _getAvailableI2cFrameTypes(DigitalBus bus, OscilloscopeState state) {
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
  }'''
content = re.sub(search_get_avail, replace_get_avail, content, flags=re.DOTALL)

# Modify _getFilteredI2cDevices to include addressMap
search_get_filtered_dev = r"          if \(regfile\.addresses != null && regfile\.addresses!\.isNotEmpty\) \{\n             addrs = addrs\.intersection\(regfile\.addresses!\.toSet\(\)\);\n          \}"
replace_get_filtered_dev = '''          List<int> validAddrs = [];
          if (regfile.addresses != null) validAddrs.addAll(regfile.addresses!);
          if (regfile.addressMap != null) validAddrs.addAll(regfile.addressMap!.keys);
          if (validAddrs.isNotEmpty) {
             addrs = addrs.intersection(validAddrs.toSet());
          }'''
content = content.replace(search_get_filtered_dev, replace_get_filtered_dev)

# Update call to _getAvailableI2cFrameTypes in _updateI2cCaches
search_call = r"_availableI2cFrameTypes = _getAvailableI2cFrameTypes\(bus\);"
replace_call = r"_availableI2cFrameTypes = _getAvailableI2cFrameTypes(bus, state);"
content = content.replace(search_call, replace_call)


with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
