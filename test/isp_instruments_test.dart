import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('instruments 分析函数', () {
    test('histogramRgb 分通道计数', () {
      // 两个像素：(255, 0, 0) 与 (0, 128, 255)。
      final rgba = Uint8List.fromList(
          [255, 0, 0, 255, 0, 128, 255, 255]);
      final (r, g, b) = histogramRgb(rgba);
      expect(r[255], 1);
      expect(r[0], 1);
      expect(g[128], 1);
      expect(g[0], 1);
      expect(b[255], 1);
      expect(b[0], 1);
      expect(r.fold<int>(0, (s, c) => s + c), 2);
    });

    test('waveformLuma 纯色帧所有计数落在同一亮度级', () {
      // 4x2 纯灰 128 → Y=128，每列计数 = 高度。
      final rgba = Uint8List(4 * 2 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 128;
        rgba[i + 1] = 128;
        rgba[i + 2] = 128;
        rgba[i + 3] = 255;
      }
      final (counts, cols) = waveformLuma(rgba, 4, 2);
      expect(cols, 4);
      for (var c = 0; c < cols; c++) {
        expect(counts[128 * cols + c], 2, reason: '列 $c');
      }
      expect(counts.fold<int>(0, (s, c) => s + c), 8);
    });

    test('vectorscope 灰色落在中性中心，纯红偏离中心', () {
      Uint8List solid(int r, int g, int b) {
        final rgba = Uint8List(4 * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i] = r;
          rgba[i + 1] = g;
          rgba[i + 2] = b;
          rgba[i + 3] = 255;
        }
        return rgba;
      }

      final gray = vectorscope(solid(128, 128, 128));
      expect(gray[256 * 512 + 256], 4 * 256); // 中心 (256,256)，满权重 256
      final red = vectorscope(solid(255, 0, 0));
      expect(red[256 * 512 + 256], 0); // 中心无计数
      expect(red.fold<int>(0, (s, c) => s + c), 4 * 256);
    });

    test('vectorscope 相邻像素的色度点按顺序连线', () {
      // 灰 → 纯红两个像素：两端点有点，且连线经过的中间格也有计数。
      final rgba = Uint8List.fromList(
          [128, 128, 128, 255, 255, 0, 0, 255]);
      final counts = vectorscope(rgba);
      expect(counts[256 * 512 + 256], greaterThan(0)); // 灰端点
      final nonZero = counts.where((c) => c > 0).length;
      expect(nonZero, greaterThan(2)); // 不止两个端点，说明连成线
      // 线段上的每个非零格应介于两端点之间（Cb/Cr 都在两端范围内）。
      final cbRed = 256 + ((-43 * 255 + 64) >> 7);
      final crRed = 511; // 256 + ((128*255+64)>>7) = 511
      for (var cr = 0; cr < 512; cr++) {
        for (var cb = 0; cb < 512; cb++) {
          if (counts[cr * 512 + cb] == 0) continue;
          expect(cb, inInclusiveRange(cbRed, 256));
          expect(cr, inInclusiveRange(256, crRed));
        }
      }
      // 抗锯齿：斜线的亮度按覆盖率分摊，存在非整权重的格。
      expect(counts.any((c) => c % 256 != 0), isTrue);
    });
  });

  group('IspStudioState 仪器分析', () {
    test('预览运行后直方图节点拿到分析结果', () async {
      // 8x8、8bit、RGGB 单帧，像素 0..63。
      const w = 8, h = 8;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_instr_$stamp.raw');
      await raw.writeAsBytes(List<int>.generate(w * h, (i) => i));
      try {
        final state = IspStudioState(); // 默认图：源→…→gamma→预览
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        final gammaId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'gamma')
            .key;
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');

        final histId = state.graph.addNode('histogram', 0, 0);
        expect(state.graph.connect(gammaId, 'out', histId, 'in'), isNull);

        await state.runPreview();

        expect(state.statusMessage, contains('预览就绪'));
        final result = state.instrumentResults[histId];
        expect(result, isNotNull, reason: '直方图节点应有分析结果');
        final r = result!['r'] as Uint32List;
        expect(r.fold<int>(0, (s, c) => s + c), w * h);
      } finally {
        await raw.delete();
      }
    });

    test('直方图通道勾选切换', () {
      final state = IspStudioState();
      expect(state.histogramChannels('n1'), {'r', 'g', 'b'});
      state.toggleHistogramChannel('n1', 'g');
      expect(state.histogramChannels('n1'), {'r', 'b'});
      state.toggleHistogramChannel('n1', 'g');
      expect(state.histogramChannels('n1'), {'r', 'g', 'b'});
    });

    test('未连接的仪器节点不产生分析结果', () async {      const w = 8, h = 8;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_instr2_$stamp.raw');
      await raw.writeAsBytes(List<int>.generate(w * h, (i) => i));
      try {
        final state = IspStudioState();
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');
        final histId = state.graph.addNode('histogram', 0, 0); // 不连接
        await state.runPreview();
        expect(state.instrumentResults.containsKey(histId), isFalse);
      } finally {
        await raw.delete();
      }
    });
  });

  group('直方图节点显示', () {
    testWidgets('绘制区占满节点宽度（不塌缩）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState();
      final histId = state.graph.addNode('histogram', 0, 0);
      final bins = Uint32List(256)..[128] = 100;
      state.instrumentResults[histId] = {
        'kind': 'histogram',
        'r': bins,
        'g': bins,
        'b': bins,
      };
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      final histNode = find.ancestor(
          of: find.text('直方图'), matching: find.byType(IspNodeWidget));
      expect(histNode, findsOneWidget);
      final paint =
          find.descendant(of: histNode, matching: find.byType(CustomPaint));
      expect(paint, findsOneWidget);
      // 回归守卫：无 child 的 CustomPaint 曾在松散约束下塌缩成 0 宽。
      expect(tester.getSize(paint).width, greaterThan(100));
      expect(tester.getSize(paint).height, greaterThan(50));
    });
  });
}
