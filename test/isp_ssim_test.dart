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
  /// 16x16 灰度渐变帧（块划分对齐 8×8）。
  Uint8List gradient({int rOff = 0, int gOff = 0, int bOff = 0}) {
    const w = 16, h = 16;
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

  group('ssimRgba 分析函数', () {
    test('完全相同为 1.0（总体与分通道）', () {
      final a = gradient();
      final (ssim, sr, sg, sb) = ssimRgba(a, Uint8List.fromList(a), 16, 16);
      expect(ssim, 1.0);
      expect(sr, 1.0);
      expect(sg, 1.0);
      expect(sb, 1.0);
    });

    test('只改 R 通道：ssimR 下降，G/B 仍为 1.0', () {
      final a = gradient();
      final b = gradient(rOff: 30);
      final (ssim, sr, sg, sb) = ssimRgba(a, b, 16, 16);
      expect(sr, lessThan(1.0));
      expect(sg, 1.0);
      expect(sb, 1.0);
      expect(ssim, lessThan(1.0));
    });

    test('两幅平坦图：方差/协方差为 0，SSIM 退化为亮度项', () {
      // 块内恒定：σa²=σb²=σab=0 → ssim = (2μaμb+C1)/(μa²+μb²+C1)。
      Uint8List solid(int v) {
        final rgba = Uint8List(8 * 8 * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
        return rgba;
      }

      final (ssim, _, _, _) = ssimRgba(solid(100), solid(110), 8, 8);
      const c1 = 6.5025;
      final expected = (2 * 100 * 110 + c1) / (100 * 100 + 110 * 110 + c1);
      expect(ssim, closeTo(expected, 1e-9));
    });

    test('内容不相关时显著小于 1', () {
      final a = gradient();
      final b = Uint8List.fromList(a.reversed.toList());
      final (ssim, _, _, _) = ssimRgba(a, b, 16, 16);
      expect(ssim, lessThan(0.9));
    });

    test('不足一个块的小图：整幅为单块', () {
      final a = Uint8List.fromList([10, 20, 30, 255]);
      final (ssim, _, _, _) = ssimRgba(a, Uint8List.fromList(a), 1, 1);
      expect(ssim, 1.0);
    });

    test('dualMetricInIsolate 并行路径与 ssimRgba 一致（≥1M 像素触发）',
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
        'kind': 'ssim',
        'ref': a,
        'test': b,
        'width': 1024,
        'height': 1024,
      });
      final (v, sr, sg, sb) = ssimRgba(a, b, 1024, 1024);
      expect(res['ssim'] as double, closeTo(v, 1e-9));
      expect(res['ssimR'] as double, closeTo(sr, 1e-9));
      expect(res['ssimG'] as double, closeTo(sg, 1e-9));
      expect(res['ssimB'] as double, closeTo(sb, 1e-9));
    });
  });

  group('ssim 节点注册', () {
    test('SSIM 数字表是双输入仪器节点（参考/测试两组四域端口）', () {
      final type = IspNodeRegistry.byId('ssim');
      expect(type, isNotNull);
      expect(type!.displayName, 'SSIM 数字表');
      expect(type.outputs, isEmpty);
      expect(type.inputs.length, 8);
      expect(instrumentTypes.contains('ssim'), isTrue);
      expect(sinkNodeTypes.contains('ssim'), isTrue);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
      expect(type.inputPort('in_test_mono')!.type, IspPortType.mono);
    });
  });

  group('IspStudioState SSIM 分析', () {
    test('相同图片 SSIM 为 1.0，换不同测试图后小于 1', () async {
      img.Image solid(int v) {
        final image = img.Image(width: 16, height: 16);
        img.fill(image, color: img.ColorRgb8(v, v, v));
        return image;
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final fileA = File('${Directory.systemTemp.path}/isp_ssim_a_$stamp.bmp');
      final fileB = File('${Directory.systemTemp.path}/isp_ssim_b_$stamp.bmp');
      final fileC = File('${Directory.systemTemp.path}/isp_ssim_c_$stamp.bmp');
      await fileA.writeAsBytes(img.encodeBmp(solid(120)));
      await fileB.writeAsBytes(img.encodeBmp(solid(120)));
      await fileC.writeAsBytes(img.encodeBmp(solid(160)));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final refId = state.graph.addNode('image_source', 0, 0);
        final testId = state.graph.addNode('image_source', 0, 200);
        final ssimId = state.graph.addNode('ssim', 300, 100);
        expect(state.graph.connect(refId, 'out_rgb', ssimId, 'in'), isNull);
        expect(
            state.graph.connect(testId, 'out_rgb', ssimId, 'in_test'), isNull);
        state.setParam(refId, 'filePath', fileA.path);
        state.setParam(testId, 'filePath', fileB.path);

        await state.runPreview();
        var result = state.instrumentResults[ssimId];
        expect(result, isNotNull, reason: 'SSIM 数字表应有分析结果');
        expect(result!['ssim'], 1.0, reason: '两图完全相同');
        expect(result['ssimR'], 1.0);

        // 换成不同亮度的测试图：SSIM 小于 1（平坦图退化为亮度项）。
        // 用新文件路径而非覆盖同路径：图片解码缓存按 mtime/大小校验，
        // 秒级 mtime 精度下同秒内覆盖会读到旧图。
        state.setParam(testId, 'filePath', fileC.path);
        await state.runPreview();
        result = state.instrumentResults[ssimId];
        expect(result, isNotNull);
        final ssim = result!['ssim'] as double;
        expect(ssim, lessThan(1.0));
        expect(ssim, greaterThan(0.9), reason: '仅亮度偏移，结构仍一致');
      } finally {
        await fileA.delete();
        await fileB.delete();
        await fileC.delete();
      }
    });

    test('缺一路输入时返回错误提示', () async {
      img.Image solid(int v) {
        final image = img.Image(width: 8, height: 8);
        img.fill(image, color: img.ColorRgb8(v, v, v));
        return image;
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final fileA = File('${Directory.systemTemp.path}/isp_ssim_c_$stamp.bmp');
      await fileA.writeAsBytes(img.encodeBmp(solid(120)));
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final refId = state.graph.addNode('image_source', 0, 0);
        final ssimId = state.graph.addNode('ssim', 300, 100);
        expect(state.graph.connect(refId, 'out_rgb', ssimId, 'in'), isNull);
        state.setParam(refId, 'filePath', fileA.path);

        await state.runPreview();
        final result = state.instrumentResults[ssimId];
        expect(result, isNotNull);
        expect(result!['error'], '需要接入参考图与测试图');
      } finally {
        await fileA.delete();
      }
    });
  });

  group('SSIM 数字表节点显示', () {
    testWidgets('显示总体 SSIM 与 R/G/B 分通道值', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final ssimId = state.graph.addNode('ssim', 0, 0);
      state.instrumentResults[ssimId] = {
        'kind': 'ssim',
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
      expect(find.text('SSIM'), findsOneWidget);
      expect(find.textContaining('R 0.9990'), findsOneWidget);
    });
  });
}
