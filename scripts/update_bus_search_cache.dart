import 'dart:io';

void main() {
  // Update OscilloscopeState
  File stateFile = File('lib/providers/oscilloscope_state.dart');
  String stateCode = stateFile.readAsStringSync();
  if (!stateCode.contains('lastSearchConfig')) {
    stateCode = stateCode.replaceFirst('  List<BusSearchMatch> searchMatches = [];', '  List<BusSearchMatch> searchMatches = [];\n  Map<String, dynamic>? lastSearchConfig;');
    stateCode = stateCode.replaceFirst('  void clearSearchMatches() {', '  void clearSearchMatches() {\n    lastSearchConfig = null;');
    stateFile.writeAsStringSync(stateCode);
  }

  // Update BusSearchDialog
  File dialogFile = File('lib/modules/oscilloscope/widgets/bus_search_dialog.dart');
  String dialogCode = dialogFile.readAsStringSync();
  
  String newInitState = '''
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
''';

  String oldInitState = '''
  @override
  void initState() {
    super.initState();
    final state = context.read<OscilloscopeState>();
    if (state.digitalChannel.buses.isNotEmpty) {
      _selectedBusName = state.digitalChannel.buses.first.name;
    }
  }
''';

  if (dialogCode.contains(oldInitState)) {
     dialogCode = dialogCode.replaceFirst(oldInitState, newInitState);
  }

  String newSaveConfig = '''
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
''';

  if (!dialogCode.contains('lastSearchConfig = {')) {
     dialogCode = dialogCode.replaceFirst('    int matchCount = state.searchAdvancedBusValue(', newSaveConfig);
  }

  dialogFile.writeAsStringSync(dialogCode);
}
