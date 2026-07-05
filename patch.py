import sys

def replace_in_file(filepath, replacements):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    for search, replace in replacements:
        content = content.replace(search, replace)
        
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

replacements = [
    (
        "      _i2cFrameType = conf['i2cFrameType'] ?? 'Any';\n      _i2cDeviceAddress = conf['i2cDeviceAddress'];\n      _i2cRegisterAddress = conf['i2cRegisterAddress'];",
        "      _i2cFrameType = conf['i2cFrameType'] ?? 'Any';\n      _i2cDeviceAddress = conf['i2cDeviceAddress'];\n      _i2cRegisterAddress = conf['i2cRegisterAddress'];\n      _spiFrameType = conf['spiFrameType'] ?? 'Any';\n      _spiCommand = conf['spiCommand'];\n      _spiAddress = conf['spiAddress'];"
    ),
    (
        "  String? _lastBusNameForCache;\n  int? _lastDeviceAddressForCache;",
        "  String? _lastBusNameForCache;\n  int? _lastDeviceAddressForCache;\n\n  // SPI Specific Fields\n  String _spiFrameType = 'Any';\n  int? _spiCommand;\n  int? _spiAddress;\n\n  List<String> _availableSpiFrameTypes = ['Any'];\n  List<int> _cachedSpiCommands = [];\n  List<int> _cachedSpiAddresses = [];\n  String? _lastSpiBusNameForCache;\n  String? _lastSpiFrameTypeForCache;\n  int? _lastSpiCommandForCache;\n  String? _selectedSpiProtocol;"
    ),
    (
        "  void _updateCaches(OscilloscopeState state, DigitalBus? bus) {",
        open('spi_methods.txt', 'r', encoding='utf-8').read() + "\n  void _updateCaches(OscilloscopeState state, DigitalBus? bus) {\n    _updateSpiCaches(state, bus);"
    ),
    (
        "] else if (hasDecoder) ...[",
        open('spi_ui_block.txt', 'r', encoding='utf-8').read()
    ),
    (
        "      'i2cDeviceAddress': _i2cDeviceAddress,\n      'i2cRegisterAddress': _i2cRegisterAddress,\n    };\n\n    int matchCount = state.searchAdvancedBusValue(\n\n      bus: bus,\n      format: _format,\n      targetValueStr: _valueController.text,\n      isBigEndian: _isBigEndian,\n      condition: internalCondition,\n      channel: _channel,\n      i2cFrameType: isI2c ? _i2cFrameType : null,\n      i2cDeviceAddress: isI2c ? _i2cDeviceAddress : null,\n      i2cRegisterAddress: isI2c ? _i2cRegisterAddress : null,\n      uartField: (!isI2c && bus.decoder != null && bus.decoder!.name == 'UART' && (bus.decoder as UartDecoder).protocolFile != null) ? _uartField : null,\n    );",
        "      'i2cDeviceAddress': _i2cDeviceAddress,\n      'i2cRegisterAddress': _i2cRegisterAddress,\n      'spiFrameType': _spiFrameType,\n      'spiCommand': _spiCommand,\n      'spiAddress': _spiAddress,\n    };\n\n    bool isSpi = bus.decoder != null && bus.decoder!.name == 'SPI';\n\n    int matchCount = state.searchAdvancedBusValue(\n\n      bus: bus,\n      format: _format,\n      targetValueStr: _valueController.text,\n      isBigEndian: _isBigEndian,\n      condition: internalCondition,\n      channel: _channel,\n      i2cFrameType: isI2c ? _i2cFrameType : null,\n      i2cDeviceAddress: isI2c ? _i2cDeviceAddress : null,\n      i2cRegisterAddress: isI2c ? _i2cRegisterAddress : null,\n      spiFrameType: isSpi ? _spiFrameType : null,\n      spiCommand: isSpi ? _spiCommand : null,\n      spiAddress: isSpi ? _spiAddress : null,\n      uartField: (!isI2c && !isSpi && bus.decoder != null && bus.decoder!.name == 'UART' && (bus.decoder as UartDecoder).protocolFile != null) ? _uartField : null,\n    );"
    )
]
replace_in_file('g:/DebugToolSet/lib/modules/oscilloscope/widgets/bus_search_dialog.dart', replacements)
