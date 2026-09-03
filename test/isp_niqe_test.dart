import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 192x192 帧（2×2 个 96×96 标准块）：[fill] 给定每像素灰度。
  Uint8List frame(int Function(int x, int y) fill) {
    const w = 192, h = 192;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final v = fill(x, y).clamp(0, 255);
        rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  group('niqeScore 分析函数', () {
    test('平滑渐变与噪声图都可计算，且噪声图分更差（更大）', () {
      final smooth = frame((x, y) => 80 + (x + y) ~/ 4);
      // 确定性伪噪声：纹理丰富但统计特性偏离自然图像。
      final noisy = frame((x, y) => 128 + ((x * 31 + y * 17) % 61) - 30);
      final sSmooth = niqeScore(smooth, 192, 192);
      final sNoisy = niqeScore(noisy, 192, 192);
      expect(sSmooth.isNaN, isFalse);
      expect(sNoisy.isNaN, isFalse);
      expect(sNoisy, greaterThan(sSmooth),
          reason: '噪声破坏自然图像统计，NIQE 应更差');
    });

    test('完全平坦的图：无有效 NSS 特征，返回 NaN', () {
      final flat = frame((x, y) => 128);
      expect(niqeScore(flat, 192, 192).isNaN, isTrue);
    });

    test('图像太小（<4）返回 NaN', () {
      // 4×4 微小图：不抛异常；块内邻积可能单侧为空（AGGD 退化），
      // 允许 NaN（微小图本就超出 NIQE 适用域）。
      final tiny = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        tiny[i * 4] = tiny[i * 4 + 1] = tiny[i * 4 + 2] = i * 16;
        tiny[i * 4 + 3] = 255;
      }
      expect(() => niqeScore(tiny, 4, 4), returnsNormally);
      expect(niqeScore(Uint8List(0), 0, 0).isNaN, isTrue);
      expect(niqeScore(Uint8List(3 * 3 * 4), 3, 3).isNaN, isTrue);
    });

    test('不足 96×96 时整幅单块兜底，可计算', () {
      const w = 64, h = 64;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final v = (80 + (x + y)).clamp(0, 255);
          rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
      }
      final s = niqeScore(rgba, w, h);
      expect(s.isNaN, isFalse);
      expect(s, greaterThanOrEqualTo(0));
    });
  });

  group('niqe 节点注册', () {
    test('NIQE 数字表是单输入评价算法节点（四域互斥组）', () {
      final type = IspNodeRegistry.byId('niqe');
      expect(type, isNotNull);
      expect(type!.displayName, 'NIQE 数字表');
      expect(type.outputs, isEmpty);
      expect(type.inputs.length, 4);
      expect(instrumentTypes.contains('niqe'), isTrue);
      expect(sinkNodeTypes.contains('niqe'), isTrue);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
    });
  });

  group('IspStudioState NIQE 分析', () {
    test('运行预览后拿到 NIQE 分值', () async {
      final image = img.Image(width: 128, height: 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          final v = (60 + x + y).clamp(0, 255);
          image.setPixelRgb(x, y, v, v, v);
        }
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${Directory.systemTemp.path}/isp_niqe_$stamp.bmp');
      await file.writeAsBytes(img.encodeBmp(image));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('image_source', 0, 0);
        final niqeId = state.graph.addNode('niqe', 300, 0);
        expect(state.graph.connect(srcId, 'out_rgb', niqeId, 'in'), isNull);
        state.setParam(srcId, 'filePath', file.path);

        await state.runPreview();
        final result = state.instrumentResults[niqeId];
        expect(result, isNotNull, reason: 'NIQE 数字表应有分析结果');
        expect(result!['kind'], 'niqe');
        final v = result['niqe'] as double;
        expect(v.isNaN, isFalse);
        expect(v, greaterThanOrEqualTo(0));
      } finally {
        await file.delete();
      }
    });
  });

  group('NIQE 数字表节点显示', () {
    testWidgets('显示分值、标签与「越小越好」提示', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final niqeId = state.graph.addNode('niqe', 0, 0);
      state.instrumentResults[niqeId] = {'kind': 'niqe', 'niqe': 3.5789};
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('3.58'), findsOneWidget);
      expect(find.text('NIQE'), findsOneWidget);
      expect(find.text('越小越好'), findsOneWidget);
    });

    testWidgets('NaN 结果显示占位符', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final niqeId = state.graph.addNode('niqe', 0, 0);
      state.instrumentResults[niqeId] = {'kind': 'niqe', 'niqe': double.nan};
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('—'), findsWidgets);
      expect(find.text('图像太小'), findsWidgets);
    });
  });
}
