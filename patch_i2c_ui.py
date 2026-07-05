import sys
import re

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update the initial value logic for Mounted Protocol
search_protocol = r"                             if \(decoderType == 'UART'\) \{.*?initialProtocolFile = state\.mountedRegfiles\[currentBus\.name\]\?\[_i2cDeviceAddress\]\?\.name;\n                                 \}\n                             \}"
replace_protocol = '''                             if (decoderType == 'UART') {
                                initialProtocolFile = (currentBus!.decoder as UartDecoder).protocolFile;
                             } else if (decoderType == 'SPI') {
                                initialProtocolFile = (currentBus!.decoder as SpiDecoder).protocolFile;
                             } else if (decoderType == 'I2C') {
                                initialProtocolFile = _selectedI2cProtocol;
                             }'''
content = re.sub(search_protocol, replace_protocol, content, flags=re.DOTALL)

# 2. Update the onChanged logic for Mounted Protocol
search_on_changed = r"                               onChanged: \(decoderType == 'I2C' && _i2cDeviceAddress == null\) \? null : \(val\) \{.*?\}\n                             \);"
replace_on_changed = '''                               onChanged: (val) {
                                  setState(() {
                                     if (decoderType == 'UART') {
                                        (currentBus!.decoder as UartDecoder).protocolFile = val;
                                        state.forceUpdate();
                                     } else if (decoderType == 'SPI') {
                                        (currentBus!.decoder as SpiDecoder).protocolFile = val;
                                        state.forceUpdate();
                                     } else if (decoderType == 'I2C') {
                                        _selectedI2cProtocol = val;
                                        _lastI2cFrameTypeForCache = null;
                                        _lastDeviceAddressForCache = null;
                                        _lastI2cProtocolForCache = null;
                                     }
                                  });
                               }
                             );'''
content = re.sub(search_on_changed, replace_on_changed, content, flags=re.DOTALL)

# 3. Remove the warning message if _i2cDeviceAddress == null
search_warning = r"                          if \(decoderType == 'I2C' && _i2cDeviceAddress == null\)\n                             const Padding\(\n                               padding: EdgeInsets\.only\(top: 4\.0\),\n                               child: Text\('请先在下方选择设备地址', style: TextStyle\(color: Colors\.redAccent, fontSize: 11\)\),\n                             \),"
content = re.sub(search_warning, "", content)

# 4. In _onSearch, mount the regfile if selectedI2cProtocol is not null, so the searchAdvancedBusValue can find it
search_onsearch = r"      bool isRawUart = hasDecoder && decoderType == 'UART' && \(currentBus\.decoder as UartDecoder\)\.protocolFile == null;"
replace_onsearch = '''      bool isRawUart = hasDecoder && decoderType == 'UART' && (currentBus.decoder as UartDecoder).protocolFile == null;
      if (isI2c && _i2cDeviceAddress != null && _selectedI2cProtocol != null) {
          var regfile = state.availableRegfiles.firstWhere((r) => r.name == _selectedI2cProtocol);
          state.mountI2cDevice(currentBus!.name, _i2cDeviceAddress!, regfile);
      }'''
content = content.replace(search_onsearch, replace_onsearch)

# 5. When selecting Device Address, mount it if we have a protocol selected
search_devaddr_onchanged = r"                                   onChanged: \(_cachedI2cDevices\.isEmpty\) \? null : \(val\) \{\n                                      setState\(\(\) \{\n                                         _i2cDeviceAddress = val;\n                                         _lastDeviceAddressForCache = null;\n                                      \}\);\n                                   \},"
replace_devaddr_onchanged = '''                                   onChanged: (_cachedI2cDevices.isEmpty) ? null : (val) {
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
                                   },'''
content = re.sub(search_devaddr_onchanged, replace_devaddr_onchanged, content)


with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
