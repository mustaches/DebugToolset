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
  /// 32x32 灰度渐变帧（多尺度：32→16→8 三个尺度）。
  Uint8List gradient({int rOff = 0, int gOff = 0, int bOff = 0}) {
    const w = 32, h = 32;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      final v = (i * 7) % 256;
      rgba[i * 4] = (v + rOff).clamp(0, 255);
      rgba[i * 4 + 1] = (v + gOff).clamp(0, 255);
      rgba[i * 4 + 2] = (v + bOff).clamp(0, 255);
      rgba[i * 4 + 3] = 255;
    }
    return rgba;
  }

  group('msssimRgba 分析函数', () {
    test('完全相同为 1.0（总体与分通道）', () {
      final a = gradient();
      final (ms, sr, sg, sb) = msssimRgba(a, Uint8List.fromList(a), 32, 32);
      expect(ms, 1.0);
      expect(sr, 1.0);
      expect(sg, 1.0);
      expect(sb, 1.0);
    });

    test('只改 R 通道：R 通道值下降，G/B 仍为 1.0', () {
      final a = gradient();
      final b = gradient(rOff: 30);
      final (ms, sr, sg, sb) = msssimRgba(a, b, 32, 32);
      expect(sr, lessThan(1.0));
      expect(sg, 1.0);
      expect(sb, 1.0);
      expect(ms, lessThan(1.0));
    });

    test('平坦图仅亮度偏移：结构项恒为 1，MS-SSIM 接近 1', () {
      Uint8List solid(int v, int side) {
        final rgba = Uint8List(side * side * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
        return rgba;
      }

      final (ms, _, _, _) = msssimRgba(solid(100, 16), solid(110, 16), 16, 16);
      expect(ms, lessThan(1.0));
      expect(ms, greaterThan(0.95), reason: '平坦图无结构差异，只有亮度项');
    });

    test('噪声越大 MS-SSIM 越低（单调性）', () {
      final a = gradient();
      Uint8List noisy(int amp) {
        final out = Uint8List.fromList(a);
        for (var i = 0; i < 32 * 32; i++) {
          final n = ((i * 31) % (2 * amp + 1)) - amp;
          for (var c = 0; c < 3; c++) {
            out[i * 4 + c] = (out[i * 4 + c] + n).clamp(0, 255);
          }
        }
        return out;
      }

      final (ms5, _, _, _) = msssimRgba(a, noisy(5), 32, 32);
      final (ms30, _, _, _) = msssimRgba(a, noisy(30), 32, 32);
      expect(ms5, greaterThan(ms30));
      // 多尺度对零均值噪声有鲁棒性（粗尺度均值滤波削弱噪声），
      // 只要求明显下降、不要求跌到很低。
      expect(ms30, lessThan(0.995));
    });

    test('不足一个块的小图：退化为单尺度 SSIM', () {
      final a = Uint8List.fromList([10, 20, 30, 255]);
      final (ms, _, _, _) = msssimRgba(a, Uint8List.fromList(a), 1, 1);
      expect(ms, 1.0);
    });

    test('dualMetricInIsolate 并行路径与 msssimRgba 一致（≥1M 像素触发）',
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
        'kind': 'msssim',
        'ref': a,
        'test': b,
        'width': 1024,
        'height': 1024,
      });
      final (v, sr, sg, sb) = msssimRgba(a, b, 1024, 1024);
      expect(res['ssim'] as double, closeTo(v, 1e-9));
      expect(res['ssimR'] as double, closeTo(sr, 1e-9));
      expect(res['ssimG'] as double, closeTo(sg, 1e-9));
      expect(res['ssimB'] as double, closeTo(sb, 1e-9));
    });
  });

  group('msssim 节点注册', () {
    test('MS-SSIM 数字表是双输入评价算法节点（参考/测试两组四域端口）', () {
      final type = IspNodeRegistry.byId('msssim');
      expect(type, isNotNull);
      expect(type!.displayName, 'MS-SSIM 数字表');
      expect(type.outputs, isEmpty);
      expect(type.inputs.length, 8);
      expect(instrumentTypes.contains('msssim'), isTrue);
      expect(sinkNodeTypes.contains('msssim'), isTrue);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
      expect(type.inputPort('in_test_mono')!.type, IspPortType.mono);
    });
  });

  group('IspStudioState MS-SSIM 分析', () {
    test('相同图片为 1.0，换不同测试图后小于 1', () async {
      img.Image solid(int v) {
        final image = img.Image(width: 16, height: 16);
        img.fill(image, color: img.ColorRgb8(v, v, v));
        return image;
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final fileA = File('${Directory.systemTemp.path}/isp_msssim_a_$stamp.bmp');
      final fileB = File('${Directory.systemTemp.path}/isp_msssim_b_$stamp.bmp');
      final fileC = File('${Directory.systemTemp.path}/isp_msssim_c_$stamp.bmp');
      await fileA.writeAsBytes(img.encodeBmp(solid(120)));
      await fileB.writeAsBytes(img.encodeBmp(solid(120)));
      await fileC.writeAsBytes(img.encodeBmp(solid(160)));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final refId = state.graph.addNode('image_source', 0, 0);
        final testId = state.graph.addNode('image_source', 0, 200);
        final msId = state.graph.addNode('msssim', 300, 100);
        expect(state.graph.connect(refId, 'out_rgb', msId, 'in'), isNull);
        expect(
            state.graph.connect(testId, 'out_rgb', msId, 'in_test'), isNull);
        state.setParam(refId, 'filePath', fileA.path);
        state.setParam(testId, 'filePath', fileB.path);

        await state.runPreview();
        var result = state.instrumentResults[msId];
        expect(result, isNotNull, reason: 'MS-SSIM 数字表应有分析结果');
        expect(result!['kind'], 'msssim');
        expect(result['ssim'], 1.0, reason: '两图完全相同');

        // 换图用新路径而非覆盖同路径（图片解码缓存按 mtime/大小校验，
        // 秒级 mtime 精度下同秒内覆盖会读到旧图）。
        state.setParam(testId, 'filePath', fileC.path);
        await state.runPreview();
        result = state.instrumentResults[msId];
        expect(result, isNotNull);
        final ms = result!['ssim'] as double;
        expect(ms, lessThan(1.0));
        expect(ms, greaterThan(0.9), reason: '仅亮度偏移，结构仍一致');
      } finally {
        await fileA.delete();
        await fileB.delete();
        await fileC.delete();
      }
    });
  });

  group('MS-SSIM 数字表节点显示', () {
    testWidgets('显示总体值与 R/G/B 分通道值，标签为 MS-SSIM', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final msId = state.graph.addNode('msssim', 0, 0);
      state.instrumentResults[msId] = {
        'kind': 'msssim',
        'ssim': 0.9985,
        'ssimR': 0.9990,
        'ssimG': 0.9980,
        'ssimB': 0.9985,
      };
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('0.9985'), findsWidgets);
      expect(find.text('MS-SSIM'), findsOneWidget);
      expect(find.textContaining('R 0.9990'), findsOneWidget);
    });
  });
}
