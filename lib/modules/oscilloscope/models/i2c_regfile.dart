import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class I2cBitField {
  final String name;
  final int startBit;
  final int endBit;
  final Map<int, String>? valueMap;
  final String? description;
  final String? access;

  I2cBitField({
    required this.name,
    required this.startBit,
    required this.endBit,
    this.valueMap,
    this.description,
    this.access,
  });

  factory I2cBitField.fromJson(Map<String, dynamic> json) {
    Map<int, String>? vMap;
    if (json['valueMap'] != null) {
      vMap = {};
      (json['valueMap'] as Map<String, dynamic>).forEach((k, v) {
        vMap![int.parse(k)] = v.toString();
      });
    }
    return I2cBitField(
      name: json['name'] ?? 'Unknown',
      startBit: json['startBit'] ?? 0,
      endBit: json['endBit'] ?? 0,
      valueMap: vMap,
      description: json['description']?.toString(),
      access: json['access']?.toString(),
    );
  }

  String decode(int regValue) {
    int mask = (1 << (endBit - startBit + 1)) - 1;
    int extracted = (regValue >> startBit) & mask;
    if (valueMap != null && valueMap!.containsKey(extracted)) {
      return valueMap![extracted]!;
    }
    if (startBit == endBit) {
       return extracted == 1 ? name : ''; // For boolean flags
    }
    return '$name=$extracted';
  }
}

class I2cRegisterDef {
  final String name;
  final List<I2cBitField> fields;
  final String? description;
  final String? access;
  final Map<String, dynamic> rawJson;

  I2cRegisterDef({
    required this.name,
    this.fields = const [],
    this.description,
    this.access,
    this.rawJson = const {},
  });

  factory I2cRegisterDef.fromJson(Map<String, dynamic> json) {
    List<I2cBitField> fList = [];
    if (json['fields'] != null) {
      for (var f in json['fields']) {
        fList.add(I2cBitField.fromJson(f));
      }
    }
    return I2cRegisterDef(
      name: json['name'] ?? 'Unknown',
      fields: fList,
      description: json['description']?.toString(),
      access: json['access']?.toString(),
      rawJson: json,
    );
  }

  List<String> decodeFields(int regValue) {
    List<String> decoded = [];
    for (var field in fields) {
      String res = field.decode(regValue);
      if (res.isNotEmpty) {
        decoded.add(res);
      }
    }
    return decoded;
  }
}

class I2cRegfile {
  final String name;
  final Map<int, I2cRegisterDef> registers;
  final List<int>? addresses;
  final Map<int, String>? addressMap;
  final bool? hasSubaddress;

  I2cRegfile({
    required this.name,
    required this.registers,
    this.addresses,
    this.addressMap,
    this.hasSubaddress,
  });

  factory I2cRegfile.fromJson(Map<String, dynamic> json) {
    Map<int, I2cRegisterDef> regs = {};
    if (json['registers'] != null) {
      (json['registers'] as Map<String, dynamic>).forEach((k, v) {
        // key could be "0x0A" or "10"
        int? addr;
        if (k.toLowerCase().startsWith('0x')) {
          addr = int.tryParse(k.substring(2), radix: 16);
        } else {
          addr = int.tryParse(k);
        }
        if (addr != null) {
          regs[addr] = I2cRegisterDef.fromJson(v);
        }
      });
    }
    List<int>? addresses;
    if (json.containsKey('addresses') && json['addresses'] is List) {
      addresses = [];
      for (var a in json['addresses']) {
        if (a is int) {
          addresses.add(a);
        } else if (a is String) {
          int? parsed = a.toLowerCase().startsWith('0x') 
              ? int.tryParse(a.substring(2), radix: 16) 
              : int.tryParse(a);
          if (parsed != null) addresses.add(parsed);
        }
      }
    }
    Map<int, String>? addressMap;
    if (json.containsKey('addressMap') && json['addressMap'] is Map) {
      addressMap = {};
      (json['addressMap'] as Map<String, dynamic>).forEach((k, v) {
        int? parsed = k.toLowerCase().startsWith('0x') 
              ? int.tryParse(k.substring(2), radix: 16) 
              : int.tryParse(k);
        if (parsed != null && v is String) {
          addressMap![parsed] = v;
        }
      });
    }
    
    return I2cRegfile(
      name: json['name'] ?? 'Unknown',
      registers: regs,
      addresses: addresses,
      addressMap: addressMap,
      hasSubaddress: json['hasSubaddress'] as bool?,
    );
  }

  static Future<List<I2cRegfile>> loadFromDirectory(String dirPath) async {
    List<I2cRegfile> loaded = [];
    try {
      Directory dir = Directory(dirPath);
      if (!await dir.exists()) return loaded;

      var entities = await dir.list().toList();
      for (var entity in entities) {
        if (entity is File && p.extension(entity.path).toLowerCase() == '.regfile') {
          try {
            String content = await entity.readAsString();
            var json = jsonDecode(content);
            loaded.add(I2cRegfile.fromJson(json));
          } catch (e) {
            debugPrint('Failed to load Regfile ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
       debugPrint('Error accessing Regfile directory: $e');
    }
    return loaded;
  }
}
