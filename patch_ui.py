import sys
import re

filepath = 'g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# Replace the I2C block
search_i2c = re.search(r'              if \(isI2c\) \.\.\.\[.*?\] else if \(hasDecoder && currentBus!\.decoder\?\.name == \'SPI\'\) \.\.\.\[', content, re.DOTALL)

if search_i2c:
    old_i2c = search_i2c.group(0)
    
    new_i2c = '''              if (isI2c) ...[
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
                                       String hex = '0x';
                                       String alias = '';
                                       if (currentBus != null && currentBus!.decoder is I2cDecoder) {
                                           var i2cDec = currentBus!.decoder as I2cDecoder;
                                           if (i2cDec.deviceAliases.containsKey(addr)) {
                                               alias = ' ';
                                           }
                                       }
                                       return DropdownMenuItem<int?>(value: addr, child: Text(hex + alias));
                                     })
                                   ],
                                   onChanged: (_cachedI2cDevices.isEmpty) ? null : (val) {
                                      setState(() {
                                         _i2cDeviceAddress = val;
                                         _lastDeviceAddressForCache = null;
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
                                     var regfile = state.getRegfileFor(currentBus!.name, _i2cDeviceAddress!);
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
                                             String hex = '0x';
                                             String alias = '';
                                             if (currentBus != null && _i2cDeviceAddress != null) {
                                                var regfile = state.getRegfileFor(currentBus!.name, _i2cDeviceAddress!);
                                                if (regfile != null && regfile.registers.containsKey(addr)) {
                                                   alias = ' ';
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
              ] else if (hasDecoder && currentBus!.decoder?.name == 'SPI') ...['''
    content = content.replace(old_i2c, new_i2c)

# Now inject the format/value for SPI
search_spi_end = re.search(r'\] else if \(isRawUart\) \.\.\.\[', content, re.DOTALL)
if search_spi_end:
    old_end = search_spi_end.group(0)
    new_end = '''                 const SizedBox(height: 16),
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
              ] else if (isRawUart) ...['''
    content = content.replace("              ] else if (isRawUart) ...[", new_end)


with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
