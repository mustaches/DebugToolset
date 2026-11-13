/// 从 Vivado 器件数据库读取 Select Device 所需的器件与筛选属性。
library;

import 'dart:convert' show LineSplitter, Utf8Decoder;
import 'dart:io';

import 'vivado_runner.dart';

class VivadoPart {
  final String name;
  final String category;
  final String family;
  final String familyDisplay;
  final String package;
  final String speed;
  final String temperature;
  final String staticPower;

  const VivadoPart({
    required this.name,
    required this.category,
    required this.family,
    required this.familyDisplay,
    required this.package,
    required this.speed,
    required this.temperature,
    required this.staticPower,
  });
}

const _partMarker = 'DTS_PART\t';

List<VivadoPart> parseVivadoParts(String output) {
  final parts = <VivadoPart>[];
  for (final line in const LineSplitter().convert(output)) {
    if (!line.startsWith(_partMarker)) continue;
    final fields = line.substring(_partMarker.length).split('\t');
    if (fields.length != 8 || fields[0].isEmpty) continue;
    parts.add(
      VivadoPart(
        name: fields[0],
        category: fields[1],
        family: fields[2],
        familyDisplay: fields[3].isEmpty ? fields[2] : fields[3],
        package: fields[4],
        speed: fields[5],
        temperature: fields[6],
        staticPower: fields[7],
      ),
    );
  }
  return parts;
}

final Map<String, List<VivadoPart>> _partsCache = {};

Future<List<VivadoPart>> listVivadoParts(
  VivadoToolchain toolchain, {
  bool useCache = true,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final cached = _partsCache[toolchain.executable];
  if (useCache && cached != null) return cached;
  final dir = await Directory.systemTemp.createTemp('dts_vivado_parts_');
  try {
    final script = File('${dir.path}${Platform.pathSeparator}list_parts.tcl');
    await script.writeAsString(r'''
proc dts_prop {p props} {
  foreach prop $props {
    if {![catch {set value [get_property $prop $p]}] && $value ne ""} {
      return $value
    }
  }
  return ""
}
puts "DTS_PARTS_BEGIN"
foreach p [get_parts] {
  set lower [string tolower $p]
  if {[string match "xqr*" $lower]} {
    set category "Radiation Tolerant"
  } elseif {[string match "xq*" $lower]} {
    set category "Military/Hi-Reliability"
  } elseif {[string match "xa*" $lower]} {
    set category "Automotive"
  } else {
    set category "General Purpose"
  }
  set speed [dts_prop $p {SPEED}]
  set staticPower [expr {[string match "*L*" [string toupper $speed]] ? "L" : "S"}]
  set temperature [dts_prop $p {TEMPERATURE_GRADE_LETTER}]
  if {$temperature eq ""} {set temperature "C"}
  set row [list $p]
  lappend row $category
  lappend row [dts_prop $p {FAMILY}]
  lappend row [dts_prop $p {ARCHITECTURE_FULL_NAME FAMILY}]
  lappend row [dts_prop $p {PACKAGE}]
  lappend row $speed
  lappend row $temperature
  lappend row $staticPower
  puts "DTS_PART\t[join $row \t]"
}
puts "DTS_PARTS_END"
''');
    final proc = await Process.start(
      toolchain.executable,
      ['-mode', 'batch', '-source', script.path],
      workingDirectory: dir.path,
      runInShell: toolchain.executable.toLowerCase().endsWith('.bat'),
    );
    const decoder = Utf8Decoder(allowMalformed: true);
    final out = StringBuffer();
    final err = StringBuffer();
    final outDone = proc.stdout.transform(decoder).forEach(out.write);
    final errDone = proc.stderr.transform(decoder).forEach(err.write);
    final code = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc.kill();
        return -2;
      },
    );
    await Future.wait([outDone, errDone]);
    final parts = parseVivadoParts(out.toString());
    if (code != 0) {
      throw StateError('Vivado 器件枚举失败（退出码 $code）：${err.toString().trim()}');
    }
    if (parts.isEmpty) throw StateError('Vivado 未返回可用器件');
    if (useCache) _partsCache[toolchain.executable] = parts;
    return parts;
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}
