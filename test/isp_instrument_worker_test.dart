import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instrument_worker.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';

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

  group('整图统计指标不条带拆分', () {
    // NIQE/BRISQUE/PIQE 是整图统计：高帧（height >= 池大小*64）若被
    // 条带拆分，merge 只会错误地返回第一条带的分值。回归：analyze()
    // 的 niqe 结果必须与直接整幅计算一致。
    test('analyze(niqe) 高帧结果与整幅直接计算一致', () async {
      final analyzer = InstrumentAnalyzer();
      addTearDown(() => analyzer.dispose());
      // 96×768：高 768 >= 8*64，且上下半幅纹理不同（拆分后分值会不同）。
      const w = 96, h = 768;
      final rgba = Uint8List(w * h * 4);
      var seed = 1;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          if (y < h ~/ 2) {
            // 上半幅平滑渐变，下半幅伪随机噪声。
            rgba[i] = (x * 2) % 256;
            rgba[i + 1] = (y ~/ 2) % 256;
            rgba[i + 2] = 128;
          } else {
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
            rgba[i] = seed & 0xFF;
            rgba[i + 1] = (seed >> 8) & 0xFF;
            rgba[i + 2] = (seed >> 3) & 0xFF;
          }
          rgba[i + 3] = 255;
        }
      }
      final expected = niqeScore(rgba, w, h);
      final result = await analyzer.analyze(rgba, w, h, 'niqe');
      expect(result['kind'], 'niqe');
      expect(result['niqe'] as double, closeTo(expected, 1e-12),
          reason: '整图统计指标不得条带拆分（拆分后 merge 只返回首片分值）');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
