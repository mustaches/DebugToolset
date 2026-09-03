import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 320x240 彩色测试帧（渐变 + 纹理 + 色偏，与 Python 参考对拍同款；
  /// numpy astype(uint8) 为截断取整，Dart toInt 同为截断）。
  Uint8List sampleFrame() {
    const w = 320, h = 240;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final r = (80 + 60 * math.sin(x / 9.0) * math.cos(y / 13.0) + x * 0.3)
            .clamp(0.0, 255.0);
        final g = (100 + 50 * math.cos(x / 17.0 + y / 11.0) + y * 0.2)
            .clamp(0.0, 255.0);
        final b = (60 +
                70 * math.sin((x + y) / 23.0) +
                40 *
                    math.exp(
                        -((x - 160) * (x - 160) + (y - 120) * (y - 120)) /
                            2000.0))
            .clamp(0.0, 255.0);
        rgba[i] = r.toInt();
        rgba[i + 1] = g.toInt();
        rgba[i + 2] = b.toInt();
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  group('ilniqeScore 分析函数', () {
    test('与 Python 参考实现对拍一致（±1.5）', () {
      // 官方 MATLAB 实现的 Python 复刻（IceClear/IL-NIQE，同款官方
      // templateModel.mat）对该图的分值为 145.844
      // （scratch/ilniqe_ref/run_ilniqe_ref.py 实跑）；Dart 实测
      // 144.630。残差来自参考实现 resize 阶段的 float32 中间精度。
      final s = ilniqeScore(sampleFrame(), 320, 240);
      expect(s.isNaN, isFalse);
      expect(s, inInclusiveRange(143.0, 148.0),
          reason: '应与参考实现一致（参考值 145.844，Dart 144.630）');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('多核并行版与串行版位级一致', () async {
      // ilniqeScoreParallel 的 worker 调用与串行完全相同的函数
      // （滤波器/块各自独立），结果必须位级一致。
      final frame = sampleFrame();
      final s = ilniqeScore(frame, 320, 240);
      final p6 = await ilniqeScoreParallel(frame, 320, 240, workers: 6);
      final p3 = await ilniqeScoreParallel(frame, 320, 240, workers: 3);
      expect(p6, s, reason: 'workers=6 应与串行位级一致');
      expect(p3, s, reason: 'workers=3 应与串行位级一致');
      // workers<=1 退化为串行。
      expect(await ilniqeScoreParallel(frame, 320, 240, workers: 1), s);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('平坦图不抛异常；过小图返回 NaN', () {
      final flat = Uint8List(64 * 64 * 4);
      for (var i = 0; i < flat.length; i += 4) {
        flat[i] = flat[i + 1] = flat[i + 2] = 128;
        flat[i + 3] = 255;
      }
      expect(() => ilniqeScore(flat, 64, 64), returnsNormally);
      expect(ilniqeScore(Uint8List(0), 0, 0).isNaN, isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('ilniqe 节点注册', () {
    test('ILNIQE 数字表是单输入评价算法节点（四域互斥组）', () {
      final type = IspNodeRegistry.byId('ilniqe');
      expect(type, isNotNull);
      expect(type!.displayName, 'ILNIQE 数字表');
      expect(type.outputs, isEmpty);
      expect(type.inputs.length, 4);
      expect(instrumentTypes.contains('ilniqe'), isTrue);
      expect(sinkNodeTypes.contains('ilniqe'), isTrue);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
    });
  });

  group('IspStudioState ILNIQE 分析', () {
    test('运行预览后拿到 ILNIQE 分值', () async {
      final frame = sampleFrame();
      final image = img.Image(width: 320, height: 240);
      for (var y = 0; y < 240; y++) {
        for (var x = 0; x < 320; x++) {
          final i = (y * 320 + x) * 4;
          image.setPixelRgb(x, y, frame[i], frame[i + 1], frame[i + 2]);
        }
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${Directory.systemTemp.path}/isp_ilniqe_$stamp.bmp');
      await file.writeAsBytes(img.encodeBmp(image));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('image_source', 0, 0);
        final ilniqeId = state.graph.addNode('ilniqe', 300, 0);
        expect(state.graph.connect(srcId, 'out_rgb', ilniqeId, 'in'), isNull);
        state.setParam(srcId, 'filePath', file.path);

        await state.runPreview();
        final result = state.instrumentResults[ilniqeId];
        expect(result, isNotNull, reason: 'ILNIQE 数字表应有分析结果');
        expect(result!['kind'], 'ilniqe');
        final v = result['ilniqe'] as double;
        expect(v.isNaN, isFalse);
        // 与单元测试同图同口径（内部归一化到 524，分辨率无关）。
        expect(v, inInclusiveRange(143.0, 148.0));
      } finally {
        await file.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('ILNIQE 数字表节点显示', () {
    testWidgets('显示分值、标签与「越小越好」提示', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final ilniqeId = state.graph.addNode('ilniqe', 0, 0);
      state.instrumentResults[ilniqeId] = {'kind': 'ilniqe', 'ilniqe': 12.345};
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('12.35'), findsOneWidget);
      expect(find.text('ILNIQE'), findsOneWidget);
      expect(find.text('越小越好'), findsOneWidget);
    });
  });
}
