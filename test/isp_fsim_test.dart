import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 16x16 竖直阶跃边帧（左暗右亮，边缘在 [edgeX]）。
  Uint8List stepEdge(int edgeX, {int lo = 40, int hi = 220, int rOff = 0}) {
    const w = 16, h = 16;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final v = x < edgeX ? lo : hi;
        rgba[i] = (v + rOff).clamp(0, 255);
        rgba[i + 1] = v;
        rgba[i + 2] = v;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  group('fsimRgba 分析函数', () {
    test('完全相同为 1.0（总体与分通道）', () {
      final a = stepEdge(8);
      final (fs, fr, fg, fb) = fsimRgba(a, Uint8List.fromList(a), 16, 16);
      expect(fs, 1.0);
      expect(fr, 1.0);
      expect(fg, 1.0);
      expect(fb, 1.0);
    });

    test('只改 R 通道：R 通道值下降，G/B 仍为 1.0', () {
      final a = stepEdge(8);
      final b = stepEdge(8, rOff: 60);
      final (fs, fr, fg, fb) = fsimRgba(a, b, 16, 16);
      expect(fr, lessThan(1.0));
      expect(fg, 1.0);
      expect(fb, 1.0);
      expect(fs, lessThan(1.0));
    });

    test('边缘错位：结构差异使 FSIM 明显下降', () {
      final a = stepEdge(8);
      final b = stepEdge(6); // 边缘左移 2 列
      final (fs, _, _, _) = fsimRgba(a, b, 16, 16);
      expect(fs, lessThan(0.9));
      expect(fs, greaterThan(0.1));
    });

    test('平坦图仅亮度差异：FSIM 不敏感（无特征可比较，为 1.0）', () {
      Uint8List solid(int v) {
        final rgba = Uint8List(16 * 16 * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
        return rgba;
      }

      // 两图均无特征（PC/GM 全 0）：按定义返回 1.0，这是 FSIM 的
      // 设计行为（特征相似度不评价纯亮度偏移，与论文一致）。
      final (fs, _, _, _) = fsimRgba(solid(100), solid(160), 16, 16);
      expect(fs, 1.0);
    });

    test('噪声越大 FSIM 越低（单调性）', () {
      final a = stepEdge(8);
      Uint8List noisy(int amp) {
        final out = Uint8List.fromList(a);
        for (var i = 0; i < 16 * 16; i++) {
          final n = ((i * 31) % (2 * amp + 1)) - amp;
          for (var c = 0; c < 3; c++) {
            out[i * 4 + c] = (out[i * 4 + c] + n).clamp(0, 255);
          }
        }
        return out;
      }

      final (fs5, _, _, _) = fsimRgba(a, noisy(5), 16, 16);
      final (fs30, _, _, _) = fsimRgba(a, noisy(30), 16, 16);
      expect(fs5, greaterThan(fs30));
      expect(fs30, lessThan(0.9));
    });

    test('空帧返回 1.0', () {
      expect(fsimRgba(Uint8List(0), Uint8List(0), 0, 0), (1.0, 1.0, 1.0, 1.0));
    });

    test('dualMetricInIsolate 并行路径与 fsimRgba 一致（≥1M 像素触发）',
        () async {
      // 1024×1024 确定性测试图（w·h = 1M 像素，恰触发并行阈值）。
      Uint8List bigFrame({int noiseAmp = 0}) {
        const w = 1024, h = 1024;
        final rgba = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          final x = i % w, y = i ~/ w;
          final n =
              noiseAmp > 0 ? ((i * 31) % (2 * noiseAmp + 1)) - noiseAmp : 0;
          rgba[i * 4] = (((x * 5 + y * 3) & 0xFF) + n).clamp(0, 255);
          rgba[i * 4 + 1] = (((x * 2 + y * 11) & 0xFF) + n).clamp(0, 255);
          rgba[i * 4 + 2] = (((x * 13 + y * 7) & 0xFF) + n).clamp(0, 255);
          rgba[i * 4 + 3] = 255;
        }
        return rgba;
      }

      final a = bigFrame();
      final b = bigFrame(noiseAmp: 8);
      final res = await dualMetricInIsolate({
        'kind': 'fsim',
        'ref': a,
        'test': b,
        'width': 1024,
        'height': 1024,
      });
      final (v, fr, fg, fb) = fsimRgba(a, b, 1024, 1024);
      expect(res['fsim'] as double, closeTo(v, 1e-9));
      expect(res['fsimR'] as double, closeTo(fr, 1e-9));
      expect(res['fsimG'] as double, closeTo(fg, 1e-9));
      expect(res['fsimB'] as double, closeTo(fb, 1e-9));
    });
  });

  group('fsim 节点注册', () {
    test('FSIM 数字表是双输入评价算法节点（参考/测试两组四域端口）', () {
      final type = IspNodeRegistry.byId('fsim');
      expect(type, isNotNull);
      expect(type!.displayName, 'FSIM 数字表');
      expect(type.outputs, isEmpty);
      expect(type.inputs.length, 8);
      expect(instrumentTypes.contains('fsim'), isTrue);
      expect(sinkNodeTypes.contains('fsim'), isTrue);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
      expect(type.inputPort('in_test_mono')!.type, IspPortType.mono);
    });
  });

  group('IspStudioState FSIM 分析', () {
    test('相同图片为 1.0，换结构不同的测试图后小于 1', () async {
      img.Image stepImage(int edgeX) {
        final image = img.Image(width: 16, height: 16);
        for (var y = 0; y < 16; y++) {
          for (var x = 0; x < 16; x++) {
            final v = x < edgeX ? 40 : 220;
            image.setPixelRgb(x, y, v, v, v);
          }
        }
        return image;
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final fileA = File('${Directory.systemTemp.path}/isp_fsim_a_$stamp.bmp');
      final fileB = File('${Directory.systemTemp.path}/isp_fsim_b_$stamp.bmp');
      final fileC = File('${Directory.systemTemp.path}/isp_fsim_c_$stamp.bmp');
      await fileA.writeAsBytes(img.encodeBmp(stepImage(8)));
      await fileB.writeAsBytes(img.encodeBmp(stepImage(8)));
      await fileC.writeAsBytes(img.encodeBmp(stepImage(5)));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final refId = state.graph.addNode('image_source', 0, 0);
        final testId = state.graph.addNode('image_source', 0, 200);
        final fsimId = state.graph.addNode('fsim', 300, 100);
        expect(state.graph.connect(refId, 'out_rgb', fsimId, 'in'), isNull);
        expect(
            state.graph.connect(testId, 'out_rgb', fsimId, 'in_test'), isNull);
        state.setParam(refId, 'filePath', fileA.path);
        state.setParam(testId, 'filePath', fileB.path);

        await state.runPreview();
        var result = state.instrumentResults[fsimId];
        expect(result, isNotNull, reason: 'FSIM 数字表应有分析结果');
        expect(result!['kind'], 'fsim');
        expect(result['fsim'], 1.0, reason: '两图完全相同');

        // 换图用新路径而非覆盖同路径（图片解码缓存按 mtime/大小校验，
        // 秒级 mtime 精度下同秒内覆盖会读到旧图）。
        state.setParam(testId, 'filePath', fileC.path);
        await state.runPreview();
        result = state.instrumentResults[fsimId];
        expect(result, isNotNull);
        final fs = result!['fsim'] as double;
        expect(fs, lessThan(1.0));
        expect(fs, greaterThan(0.05), reason: '仅边缘错位，整体结构仍相近');
      } finally {
        await fileA.delete();
        await fileB.delete();
        await fileC.delete();
      }
    });
  });

  group('FSIM 数字表节点显示', () {
    testWidgets('显示总体值与 R/G/B 分通道值，标签为 FSIM', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final fsimId = state.graph.addNode('fsim', 0, 0);
      state.instrumentResults[fsimId] = {
        'kind': 'fsim',
        'fsim': 0.9721,
        'fsimR': 0.9800,
        'fsimG': 0.9700,
        'fsimB': 0.9663,
      };
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('0.9721'), findsOneWidget);
      expect(find.text('FSIM'), findsOneWidget);
      expect(find.textContaining('R 0.9800'), findsOneWidget);
    });
  });
}
