import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class UartFieldDef {
  final int byteOffset;
  final String name;
  final String? value;
  final Map<int, String>? valueMap;
  final String? description;

  UartFieldDef({
    required this.byteOffset,
    required this.name,
    this.value,
    this.valueMap,
    this.description,
  });

  factory UartFieldDef.fromJson(Map<String, dynamic> json) {
    Map<int, String>? vMap;
    if (json['valueMap'] != null) {
      vMap = {};
      (json['valueMap'] as Map<String, dynamic>).forEach((k, v) {
        int? keyInt;
        if (k.toLowerCase().startsWith('0x')) {
          keyInt = int.tryParse(k.substring(2), radix: 16);
        } else {
          keyInt = int.tryParse(k);
        }
        if (keyInt != null) {
          vMap![keyInt] = v.toString();
        }
      });
    }

    return UartFieldDef(
      byteOffset: json['byteOffset'] as int,
      name: json['name'] as String,
      value: json['value']?.toString(),
      valueMap: vMap,
      description: json['description']?.toString(),
    );
  }

  String decode(int byteVal) {
    if (valueMap != null && valueMap!.containsKey(byteVal)) {
      return valueMap![byteVal]!;
    }
    return '';
  }
}

class UartPacketDef {
  final int length;
  final List<UartFieldDef> payload;

  UartPacketDef({
    required this.length,
    required this.payload,
  });

  factory UartPacketDef.fromJson(Map<String, dynamic> json) {
    List<UartFieldDef> pList = [];
    if (json['payload'] != null) {
      for (var p in json['payload']) {
        pList.add(UartFieldDef.fromJson(p));
      }
    }
    return UartPacketDef(
      length: json['length'] as int? ?? 0,
      payload: pList,
    );
  }
}

class UartCommandDef {
  final String name;
  final UartPacketDef? tx;
  final UartPacketDef? rx;

  UartCommandDef({
    required this.name,
    this.tx,
    this.rx,
  });

  factory UartCommandDef.fromJson(Map<String, dynamic> json) {
    return UartCommandDef(
      name: json['name'] as String? ?? 'Unknown',
      tx: json['tx'] != null ? UartPacketDef.fromJson(json['tx']) : null,
      rx: json['rx'] != null ? UartPacketDef.fromJson(json['rx']) : null,
    );
  }
}

class UartProtocolFile {
  final String name;
  final String? description;
  final int baudRate;
  final List<int> header;
  final Map<int, UartCommandDef> commands;
  String? filename;

  UartProtocolFile({
    required this.name,
    this.description,
    required this.baudRate,
    required this.header,
    required this.commands,
    this.filename,
  });

  factory UartProtocolFile.fromJson(Map<String, dynamic> json) {
    List<int> head = [];
    if (json['header'] != null && json['header'] is List) {
      for (var h in json['header']) {
        if (h is int) {
          head.add(h);
        } else if (h is String) {
          int? val = h.toLowerCase().startsWith('0x')
              ? int.tryParse(h.substring(2), radix: 16)
              : int.tryParse(h);
          if (val != null) head.add(val);
        }
      }
    }

    Map<int, UartCommandDef> cmds = {};
    if (json['commands'] != null) {
      (json['commands'] as Map<String, dynamic>).forEach((k, v) {
        int? cmdId;
        if (k.toLowerCase().startsWith('0x')) {
          cmdId = int.tryParse(k.substring(2), radix: 16);
        } else {
          cmdId = int.tryParse(k);
        }
        if (cmdId != null) {
          cmds[cmdId] = UartCommandDef.fromJson(v);
        }
      });
    }

    return UartProtocolFile(
      name: json['name'] as String? ?? 'Unknown',
      description: json['description']?.toString(),
      baudRate: json['baudRate'] as int? ?? 115200,
      header: head,
      commands: cmds,
    );
  }

  static Future<List<UartProtocolFile>> loadFromDirectory(String dirPath) async {
    List<UartProtocolFile> loaded = [];
    try {
      Directory dir = Directory(dirPath);
      if (!await dir.exists()) return loaded;

      var entities = await dir.list().toList();
      for (var entity in entities) {
        if (entity is File && p.extension(entity.path).toLowerCase() == '.uartprotocol') {
          try {
            String content = await entity.readAsString();
            var json = jsonDecode(content);
            var proto = UartProtocolFile.fromJson(json);
            proto.filename = p.basename(entity.path);
            loaded.add(proto);
          } catch (e) {
            debugPrint('Failed to load UartProtocol ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Error accessing UartProtocol directory: $e');
    }
    return loaded;
  }
}
