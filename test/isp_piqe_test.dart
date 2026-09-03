import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/piqe.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 256x192 高纹理彩色测试帧（与 Python 参考对拍同款图案）。
  Uint8List busyFrame({bool noisy = false}) {
    const w = 256, h = 192;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        var r = (128 +
                70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
                40 * math.sin((x + 2 * y) / 5.3))
            .clamp(0.0, 255.0)
            .toInt();
        var g = (128 +
                70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
                40 * math.cos((2 * x - y) / 6.7))
            .clamp(0.0, 255.0)
            .toInt();
        var b = (128 +
                70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
            .clamp(0.0, 255.0)
            .toInt();
        if (noisy) {
          // 与 Python 参考同款的确定性噪声（元素序按 RGB 三通道计）。
          final base = (y * w + x) * 3;
          r = (r + (base * 31) % 61 - 30).clamp(0, 255);
          g = (g + ((base + 1) * 31) % 61 - 30).clamp(0, 255);
          b = (b + ((base + 2) * 31) % 61 - 30).clamp(0, 255);
        }
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  group('piqeScore 分析函数', () {
    test('与 Python 参考实现对拍一致（±0.01）', () {
      // pypiqe（MATLAB piqe 的逐行复刻，michael-rutherford/pypiqe）
      // 对同图的基线：纹理图 88.708635，加噪图 7.286913
      // （scratch/piqe_ref 实跑）。
      final sBusy = piqeScore(busyFrame(), 256, 192);
      expect(sBusy, closeTo(88.708635, 0.01));
      final sNoisy = piqeScore(busyFrame(noisy: true), 256, 192);
      expect(sNoisy, closeTo(7.286913, 0.01));
    });

    test('平坦图按定义得 100（无活跃块）', () {
      final flat = Uint8List(64 * 64 * 4);
      for (var i = 0; i < flat.length; i += 4) {
        flat[i] = flat[i + 1] = flat[i + 2] = 128;
        flat[i + 3] = 255;
      }
      expect(piqeScore(flat, 64, 64), 100.0);
    });

    test('空帧返回 NaN', () {
      expect(piqeScore(Uint8List(0), 0, 0).isNaN, isTrue);
    });
  });

  group('piqe 节点注册', () {
    test('PIQE 数字表是单输入评价算法节点（四域互斥组）', () {
      final type = IspNodeRegistry.byId('piqe');
      expect(type, isNotNull);
      expect(type!.displayName, 'PIQE 数字表');
      expect(type.outputs, isEmpty);
      expect(type.inputs.length, 4);
      expect(instrumentTypes.contains('piqe'), isTrue);
      expect(sinkNodeTypes.contains('piqe'), isTrue);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
    });
  });

  group('IspStudioState PIQE 分析', () {
    test('运行预览后拿到 PIQE 分值', () async {
      final frame = busyFrame();
      final image = img.Image(width: 256, height: 192);
      for (var y = 0; y < 192; y++) {
        for (var x = 0; x < 256; x++) {
          final i = (y * 256 + x) * 4;
          image.setPixelRgb(x, y, frame[i], frame[i + 1], frame[i + 2]);
        }
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${Directory.systemTemp.path}/isp_piqe_$stamp.bmp');
      await file.writeAsBytes(img.encodeBmp(image));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('image_source', 0, 0);
        final piqeId = state.graph.addNode('piqe', 300, 0);
        expect(state.graph.connect(srcId, 'out_rgb', piqeId, 'in'), isNull);
        state.setParam(srcId, 'filePath', file.path);

        await state.runPreview();
        final result = state.instrumentResults[piqeId];
        expect(result, isNotNull, reason: 'PIQE 数字表应有分析结果');
        expect(result!['kind'], 'piqe');
        final v = result['piqe'] as double;
        expect(v.isNaN, isFalse);
        expect(v, inInclusiveRange(0, 100));
      } finally {
        await file.delete();
      }
    });
  });

  group('PIQE 数字表节点显示', () {
    testWidgets('显示分值、标签与「越小越好」提示', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final piqeId = state.graph.addNode('piqe', 0, 0);
      state.instrumentResults[piqeId] = {'kind': 'piqe', 'piqe': 45.6789};
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('45.68'), findsOneWidget);
      expect(find.text('PIQE'), findsOneWidget);
      expect(find.text('越小越好'), findsOneWidget);
    });
  });
}
