import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../providers/oscilloscope_state.dart';


class WaveformStorage {
  static const String _magicBytes = "WAVEFORM1.0\n";
  
  static Future<void> saveWaveform(String filepath, OscilloscopeState state) async {
    // 1. Prepare JSON metadata
    Map<String, dynamic> metadata = {
      'xScale': state.xScale,
      'triggerLevel': state.triggerLevel,
      'sampleRate': state.sampleRate,
      'analogChannels': [],
      'digitalChannel': {
        'count': state.digitalChannel.count,
        'enabledPins': state.digitalChannel.enabledPins.toList(),
        'pinYOffsets': state.digitalChannel.pinYOffsets.map((k, v) => MapEntry(k.toString(), v)),
        'pinYScales': state.digitalChannel.pinYScales.map((k, v) => MapEntry(k.toString(), v)),
        'pinNames': state.digitalChannel.pinNames.map((k, v) => MapEntry(k.toString(), v)),
        'buses': state.digitalChannel.buses.map((b) => b.toJson()).toList(),
      }
    };

    List<Float32List> analogBuffers = [];
    for (int i = 0; i < state.channels.length; i++) {
      var ch = state.channels[i];
      metadata['analogChannels'].add({
        'name': ch.name,
        'isVisible': ch.isVisible,
        'color': ch.color.toARGB32(),
        'yScale': ch.yScale,
        'yOffset': ch.yOffset,
        'count': ch.count,
        'totalPointsAdded': ch.totalPointsAdded,
      });
      analogBuffers.add(_getUnrolledFloat32List(ch));
    }

    Uint32List digitalBuffer = _getUnrolledUint32List(state.digitalChannel);

    String jsonStr = jsonEncode(metadata);
    List<int> jsonBytes = utf8.encode(jsonStr);
    
    // 2. Build Raw Payload
    BytesBuilder payloadBuilder = BytesBuilder(copy: false);
    for (var buffer in analogBuffers) {
      payloadBuilder.add(buffer.buffer.asUint8List(buffer.offsetInBytes, buffer.lengthInBytes));
    }
    payloadBuilder.add(digitalBuffer.buffer.asUint8List(digitalBuffer.offsetInBytes, digitalBuffer.lengthInBytes));

    // 3. Compress Payload
    List<int> compressedPayload = gzip.encode(payloadBuilder.takeBytes());
    
    // 4. Write to File
    // Format: MAGIC (12 bytes) + JSON_LEN (4 bytes) + JSON_BYTES + COMPRESSED_PAYLOAD
    File file = File(filepath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    
    var writer = file.openSync(mode: FileMode.write);
    try {
      writer.writeStringSync(_magicBytes);
      
      var lenBytes = ByteData(4);
      lenBytes.setUint32(0, jsonBytes.length, Endian.little);
      writer.writeFromSync(lenBytes.buffer.asUint8List());
      
      writer.writeFromSync(jsonBytes);
      writer.writeFromSync(compressedPayload);
    } finally {
      writer.closeSync();
    }
  }

  static Future<void> loadWaveform(String filepath, OscilloscopeState state) async {
    File file = File(filepath);
    if (!file.existsSync()) throw Exception("File not found");

    var reader = file.openSync(mode: FileMode.read);
    try {
      // 1. Check Magic Bytes
      var magicBuffer = reader.readSync(_magicBytes.length);
      String magic = utf8.decode(magicBuffer);
      if (magic != _magicBytes) {
        throw Exception("Invalid waveform file format");
      }

      // 2. Read JSON Length
      var lenBuffer = reader.readSync(4);
      int jsonLen = ByteData.sublistView(lenBuffer).getUint32(0, Endian.little);

      // 3. Read and Parse JSON
      var jsonBytes = reader.readSync(jsonLen);
      String jsonStr = utf8.decode(jsonBytes);
      Map<String, dynamic> metadata = jsonDecode(jsonStr);

      // 4. Read Compressed Payload
      var compressedPayload = reader.readSync(file.lengthSync() - reader.positionSync());
      List<int> decompressed = gzip.decode(compressedPayload);
      ByteData payloadData = ByteData.sublistView(Uint8List.fromList(decompressed));

      int currentOffset = 0;

      // 5. Restore State (Analog)
      List<dynamic> analogMetas = metadata['analogChannels'];
      for (int i = 0; i < state.channels.length && i < analogMetas.length; i++) {
        var chMeta = analogMetas[i];
        var ch = state.channels[i];
        
        ch.name = chMeta['name'];
        ch.isVisible = chMeta['isVisible'];
        ch.color = Color(chMeta['color']);
        ch.yScale = chMeta['yScale'];
        ch.yOffset = chMeta['yOffset'];
        
        int count = chMeta['count'];
        int bytesToRead = count * 4;
        
        Float32List unrolled = payloadData.buffer.asFloat32List(payloadData.offsetInBytes + currentOffset, count);
        currentOffset += bytesToRead;
        
        ch.restoreFromUnrolled(unrolled, chMeta['totalPointsAdded'] ?? count);
      }

      // 6. Restore State (Digital)
      var dMeta = metadata['digitalChannel'];
      var dCh = state.digitalChannel;
      
      dCh.enabledPins = Set<int>.from(dMeta['enabledPins'] ?? []);
      
      if (dMeta['pinYOffsets'] != null) {
        Map<String, dynamic> yOffs = dMeta['pinYOffsets'];
        yOffs.forEach((k, v) => dCh.pinYOffsets[int.parse(k)] = v.toDouble());
      }
      if (dMeta['pinYScales'] != null) {
        Map<String, dynamic> yScales = dMeta['pinYScales'];
        yScales.forEach((k, v) => dCh.pinYScales[int.parse(k)] = v.toDouble());
      }
      if (dMeta['pinNames'] != null) {
        Map<String, dynamic> pNames = dMeta['pinNames'];
        pNames.forEach((k, v) => dCh.pinNames[int.parse(k)] = v.toString());
      }
      if (dMeta['buses'] != null) {
        List<dynamic> bList = dMeta['buses'];
        dCh.buses = bList.map((b) => DigitalBus.fromJson(b)).toList();
      }

      int dCount = dMeta['count'];
      int dBytesToRead = dCount * 4;
      Uint32List dUnrolled = payloadData.buffer.asUint32List(payloadData.offsetInBytes + currentOffset, dCount);
      currentOffset += dBytesToRead;

      dCh.restoreFromUnrolled(dUnrolled, dCount);
      
      // 7. Update UI Scale and Sample Rate
      if (metadata['xScale'] != null) {
        state.setXScale(metadata['xScale']);
      }
      if (metadata['sampleRate'] != null) {
        state.setSampleRate(metadata['sampleRate'].toDouble());
      }
      
      // Trigger decode after load
      state.decodeAllProtocols();

    } finally {
      reader.closeSync();
    }
  }

  static Float32List _getUnrolledFloat32List(ChannelData ch) {
    Float32List result = Float32List(ch.count);
    if (ch.count == 0) return result;
    
    if (ch.count < ch.maxPoints || ch.head == 0) {
      result.setAll(0, Float32List.sublistView(ch.points, 0, ch.count));
    } else {
      int tailLen = ch.maxPoints - ch.head;
      result.setAll(0, Float32List.sublistView(ch.points, ch.head, ch.maxPoints));
      result.setAll(tailLen, Float32List.sublistView(ch.points, 0, ch.head));
    }
    return result;
  }

  static Uint32List _getUnrolledUint32List(DigitalChannelData ch) {
    Uint32List result = Uint32List(ch.count);
    if (ch.count == 0) return result;
    
    if (ch.count < ch.maxPoints || ch.head == 0) {
      result.setAll(0, Uint32List.sublistView(ch.states, 0, ch.count));
    } else {
      int tailLen = ch.maxPoints - ch.head;
      result.setAll(0, Uint32List.sublistView(ch.states, ch.head, ch.maxPoints));
      result.setAll(tailLen, Uint32List.sublistView(ch.states, 0, ch.head));
    }
    return result;
  }
}
