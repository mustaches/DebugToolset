/// IP 与 demo_prj 对话框配置的 JSON 模型和文件读写。
library;

import 'dart:convert';
import 'dart:io';

import 'ip_target.dart';

const kIpGenConfigVersion = 1;

class VivadoPartFilters {
  final String category;
  final String family;
  final String package;
  final String speed;
  final String temperature;
  final String staticPower;
  final String search;

  const VivadoPartFilters({
    this.category = '',
    this.family = '',
    this.package = '',
    this.speed = '',
    this.temperature = '',
    this.staticPower = '',
    this.search = '',
  });

  Map<String, Object?> toJson() => {
    'category': category,
    'family': family,
    'package': package,
    'speed': speed,
    'temperature': temperature,
    'staticPower': staticPower,
    'search': search,
  };

  factory VivadoPartFilters.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    String text(String key) => map[key] is String ? map[key] as String : '';
    return VivadoPartFilters(
      category: text('category'),
      family: text('family'),
      package: text('package'),
      speed: text('speed'),
      temperature: text('temperature'),
      staticPower: text('staticPower'),
      search: text('search'),
    );
  }
}

class IpGenConfig {
  final IpGenOptions options;
  final VivadoPartFilters filters;

  const IpGenConfig({
    required this.options,
    this.filters = const VivadoPartFilters(),
  });

  Map<String, Object?> toJson() => {
    'version': kIpGenConfigVersion,
    'vendor': options.vendor.name,
    'series': options.series.name,
    'vivadoExecutable': options.vivadoExecutable,
    'targetPart': options.targetPart,
    'targetFamily': options.targetFamily,
    'vinType': options.vinType,
    'pixBits': options.pixBits,
    'maxWidth': options.maxWidth,
    'gstrategy': options.gstrategy,
    'fold': options.fold,
    'dspPipe': options.dspPipe,
    'useBram': options.useBram,
    'yuvStandard': options.yuvStandard,
    'projectName': options.projectName,
    'filters': filters.toJson(),
  };
}

String encodeIpGenConfig(IpGenConfig config) {
  return const JsonEncoder.withIndent('  ').convert(config.toJson());
}

String _string(Map json, String key, [String fallback = '']) {
  return json[key] is String ? json[key] as String : fallback;
}

int _intIn(Map json, String key, List<int> allowed, int fallback) {
  final value = json[key];
  return value is int && allowed.contains(value) ? value : fallback;
}

IpGenConfig decodeIpGenConfig(String text, {bool requireVivado = false}) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('配置文件顶层必须是 JSON 对象');
  if (decoded['version'] != kIpGenConfigVersion) {
    throw FormatException('不支持的配置版本：${decoded['version']}');
  }
  var vendor =
      IpVendor.values.asNameMap()[_string(decoded, 'vendor', 'vivado')] ??
      IpVendor.vivado;
  if (requireVivado || !vendor.enabled) vendor = IpVendor.vivado;
  final series =
      VivadoSeries.values.asNameMap()[_string(decoded, 'series')] ??
      VivadoSeries.zynqUltrascalePlus;
  final projectName = _string(decoded, 'projectName', 'demo_prj');
  final options = IpGenOptions(
    vendor: vendor,
    series: series,
    targetPart: _string(decoded, 'targetPart'),
    targetFamily: _string(decoded, 'targetFamily'),
    vivadoExecutable: _string(decoded, 'vivadoExecutable'),
    vinType: _string(decoded, 'vinType', 'none'),
    pixBits: _intIn(decoded, 'pixBits', const [0, 8, 10, 12, 14, 16], 0),
    maxWidth: _intIn(decoded, 'maxWidth', kIpMaxWidthOptions, 3840),
    gstrategy: _intIn(decoded, 'gstrategy', const [0, 1, 2], 2),
    fold: _intIn(decoded, 'fold', const [1, 2, 4], 2),
    dspPipe: _intIn(decoded, 'dspPipe', const [0, 1, 2, 3], 3),
    yuvStandard:
        const [
          'auto',
          'bt601',
          'bt709',
          'bt2020',
        ].contains(_string(decoded, 'yuvStandard', 'auto'))
        ? _string(decoded, 'yuvStandard', 'auto')
        : 'auto',
    useBram: decoded['useBram'] != false,
    projectName: RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(projectName)
        ? projectName
        : 'demo_prj',
  );
  return IpGenConfig(
    options: options,
    filters: VivadoPartFilters.fromJson(decoded['filters']),
  );
}

Directory ipConfigDirectory(String extension) {
  if (extension != 'ipcfg' && extension != 'prjcfg') {
    throw ArgumentError.value(extension, 'extension', '仅支持 ipcfg/prjcfg');
  }
  return Directory(
    '${Directory.current.path}${Platform.pathSeparator}IspFlow${Platform.pathSeparator}export_config${Platform.pathSeparator}$extension',
  );
}

String ensureIpConfigExtension(String path, String extension) {
  return path.toLowerCase().endsWith('.$extension') ? path : '$path.$extension';
}

Future<String> saveIpGenConfigFile(
  IpGenConfig config,
  String path,
  String extension,
) async {
  final output = ensureIpConfigExtension(path, extension);
  final file = File(output);
  await file.parent.create(recursive: true);
  await file.writeAsString('${encodeIpGenConfig(config)}\n');
  return output;
}

Future<IpGenConfig> readIpGenConfigFile(
  String path, {
  bool requireVivado = false,
}) async {
  return decodeIpGenConfig(
    await File(path).readAsString(),
    requireVivado: requireVivado,
  );
}
