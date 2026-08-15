import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instrument_worker.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';

void main() {
  group('InstrumentAnalyzer.analyzeDedicated', () {
    test('waveform 返回预渲染 bmp 且尺寸匹配', () async {
      final analyzer = InstrumentAnalyzer();
      addTearDown(() => analyzer.dispose());
      // 8x8 渐变帧
      final rgba = Uint8List(8 * 8 * 4);
      for (var i = 0; i < 8 * 8; i++) {
        rgba[i * 4] = (i * 7) % 256;
        rgba[i * 4 + 1] = (i * 13) % 256;
        rgba[i * 4 + 2] = (i * 29) % 256;
        rgba[i * 4 + 3] = 255;
      }
      final result = await analyzer.analyzeDedicated(rgba, 8, 8, 'waveform',
          visible: {'y'});
      expect(result['kind'], 'waveform');
      expect(result['columns'], 8);
      final bmp = result['bmp'] as Uint8List;
      expect(bmp.length, 8 * kWaveformLevels * 4);
    });

    test('vectorscope 返回预渲染 bmp 且尺寸匹配', () async {
      final analyzer = InstrumentAnalyzer();
      addTearDown(() => analyzer.dispose());
      final rgba = Uint8List(8 * 8 * 4);
      for (var i = 0; i < 8 * 8; i++) {
        rgba[i * 4] = (i * 7) % 256;
        rgba[i * 4 + 1] = (i * 13) % 256;
        rgba[i * 4 + 2] = (i * 29) % 256;
        rgba[i * 4 + 3] = 255;
      }
      final result =
          await analyzer.analyzeDedicated(rgba, 8, 8, 'vectorscope');
      expect(result['kind'], 'vectorscope');
      final bmp = result['bmp'] as Uint8List;
      expect(bmp.length, kVectorscopeSize * kVectorscopeSize * 4);
    });

    test('双类型并发调用不抛异常且都返回 bmp', () async {
      final analyzer = InstrumentAnalyzer();
      addTearDown(() => analyzer.dispose());
      final rgba = Uint8List(8 * 8 * 4);
      for (var i = 0; i < 8 * 8; i++) {
        rgba[i * 4] = (i * 7) % 256;
        rgba[i * 4 + 1] = (i * 13) % 256;
        rgba[i * 4 + 2] = (i * 29) % 256;
        rgba[i * 4 + 3] = 255;
      }
      final results = await Future.wait([
        analyzer.analyzeDedicated(rgba, 8, 8, 'waveform', visible: {'y'}),
        analyzer.analyzeDedicated(rgba, 8, 8, 'vectorscope'),
      ]);
      expect(results[0]['bmp'], isNotNull);
      expect(results[1]['bmp'], isNotNull);
    });
  });

  group('InstrumentAnalyzer.analyzeVectorscopeParallel', () {
    test('隔行条带并行返回预渲染 bmp 且尺寸匹配', () async {
      final analyzer = InstrumentAnalyzer();
      addTearDown(() => analyzer.dispose());
      // 128x96 噪声渐变帧（高于条带拆分下限）。
      const w = 128, h = 96;
      final rgba = Uint8List(w * h * 4);
      var seed = 3;
      for (var i = 0; i < w * h; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        rgba[i * 4] = seed & 0xFF;
        rgba[i * 4 + 1] = (seed >> 8) & 0xFF;
        rgba[i * 4 + 2] = (i * 5) % 256;
        rgba[i * 4 + 3] = 255;
      }
      final result = await analyzer.analyzeVectorscopeParallel(rgba, w, h);
      expect(result['kind'], 'vectorscope');
      final bmp = result['bmp'] as Uint8List;
      expect(bmp.length, kVectorscopeSize * kVectorscopeSize * 4);
      expect(bmp.any((v) => v > 0), isTrue); // 非全黑
    });

    test('过矮的帧回退单 worker 路径', () async {
      final analyzer = InstrumentAnalyzer();
      addTearDown(() => analyzer.dispose());
      final rgba = Uint8List(8 * 4 * 4);
      for (var i = 0; i < 8 * 4; i++) {
        rgba[i * 4] = (i * 31) % 256;
        rgba[i * 4 + 1] = (i * 17) % 256;
        rgba[i * 4 + 2] = (i * 11) % 256;
        rgba[i * 4 + 3] = 255;
      }
      final result = await analyzer.analyzeVectorscopeParallel(rgba, 8, 4);
      expect(result['kind'], 'vectorscope');
      expect((result['bmp'] as Uint8List).length,
          kVectorscopeSize * kVectorscopeSize * 4);
    });
  });
}
