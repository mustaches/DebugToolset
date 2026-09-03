import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/brisque.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 128x128 测试帧（渐变 + 正弦纹理 + 高斯斑，与自然图统计相去不远）。
  Uint8List sampleFrame() {
    const w = 128, h = 128;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final v = (80 +
                60 * math.sin(x / 9.0) * math.cos(y / 13.0) +
                40 * math.exp(-((x - 64) * (x - 64) + (y - 64) * (y - 64)) / 800.0) +
                x * 0.3)
            .clamp(0, 255)
            .round();
        rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  group('brisqueScore 分析函数', () {
    test('与 Python 参考实现对拍一致（±0.5）', () {
      // 同图在 numpy 复刻参考实现（scratch/brisque_reference.py，同款
      // SVM 模型与归一化参数）下为 90.563；Dart 实测 90.984。
      final s = brisqueScore(sampleFrame(), 128, 128);
      expect(s.isNaN, isFalse);
      expect(s, inInclusiveRange(89.0, 92.0),
          reason: '应与参考实现一致（参考值 90.56，Dart 90.98）');
    });

    test('噪声图分值更差（更大）', () {
      final smooth = sampleFrame();
      final noisy = Uint8List.fromList(smooth);
      for (var i = 0; i < 128 * 128; i++) {
        final n = ((i * 31) % 61) - 30;
        for (var c = 0; c < 3; c++) {
          noisy[i * 4 + c] = (noisy[i * 4 + c] + n).clamp(0, 255);
        }
      }
      final sSmooth = brisqueScore(smooth, 128, 128);
      final sNoisy = brisqueScore(noisy, 128, 128);
      expect(sSmooth.isNaN, isFalse);
      expect(sNoisy.isNaN, isFalse);
      expect(sNoisy, greaterThan(sSmooth), reason: '噪声破坏 NSS 统计，BRISQUE 应更差');
    });

    test('完全平坦的图：AGGD 退化，返回 NaN', () {
      final flat = Uint8List(128 * 128 * 4);
      for (var i = 0; i < flat.length; i += 4) {
        flat[i] = flat[i + 1] = flat[i + 2] = 128;
        flat[i + 3] = 255;
      }
      expect(brisqueScore(flat, 128, 128).isNaN, isTrue);
    });

    test('图像太小（<4）返回 NaN', () {
      expect(brisqueScore(Uint8List(0), 0, 0).isNaN, isTrue);
      expect(brisqueScore(Uint8List(3 * 3 * 4), 3, 3).isNaN, isTrue);
    });
  });

  group('brisque 节点注册', () {
    test('BRISQUE 数字表是单输入评价算法节点（四域互斥组）', () {
      final type = IspNodeRegistry.byId('brisque');
      expect(type, isNotNull);
      expect(type!.displayName, 'BRISQUE 数字表');
      expect(type.outputs, isEmpty);
      expect(type.inputs.length, 4);
      expect(instrumentTypes.contains('brisque'), isTrue);
      expect(sinkNodeTypes.contains('brisque'), isTrue);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
    });
  });

  group('IspStudioState BRISQUE 分析', () {
    test('运行预览后拿到 BRISQUE 分值', () async {
      final image = img.Image(width: 128, height: 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          final v = (80 +
                  60 * math.sin(x / 9.0) * math.cos(y / 13.0) +
                  40 *
                      math.exp(
                          -((x - 64) * (x - 64) + (y - 64) * (y - 64)) /
                              800.0) +
                  x * 0.3)
              .clamp(0, 255)
              .round();
          image.setPixelRgb(x, y, v, v, v);
        }
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${Directory.systemTemp.path}/isp_brisque_$stamp.bmp');
      await file.writeAsBytes(img.encodeBmp(image));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('image_source', 0, 0);
        final brisqueId = state.graph.addNode('brisque', 300, 0);
        expect(
            state.graph.connect(srcId, 'out_rgb', brisqueId, 'in'), isNull);
        state.setParam(srcId, 'filePath', file.path);

        await state.runPreview();
        final result = state.instrumentResults[brisqueId];
        expect(result, isNotNull, reason: 'BRISQUE 数字表应有分析结果');
        expect(result!['kind'], 'brisque');
        final v = result['brisque'] as double;
        expect(v.isNaN, isFalse);
        expect(v, inInclusiveRange(0, 100));
      } finally {
        await file.delete();
      }
    });
  });

  group('BRISQUE 数字表节点显示', () {
    testWidgets('显示分值、标签与「越小越好」提示', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final brisqueId = state.graph.addNode('brisque', 0, 0);
      state.instrumentResults[brisqueId] = {'kind': 'brisque', 'brisque': 23.4567};
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('23.46'), findsOneWidget);
      expect(find.text('BRISQUE'), findsOneWidget);
      expect(find.text('越小越好'), findsOneWidget);
    });
  });
}
