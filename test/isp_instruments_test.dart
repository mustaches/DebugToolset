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
      final (r, g, b, y) = histogramRgb(rgba);
      expect(r[255], 1);
      expect(r[0], 1);
      expect(g[128], 1);
      expect(g[0], 1);
      expect(b[255], 1);
      expect(b[0], 1);
      // Y（BT.601）：(255,0,0)→77，(0,128,255)→104。
      expect(y[77], 1);
      expect(y[104], 1);
      expect(r.fold<int>(0, (s, c) => s + c), 2);
      expect(y.fold<int>(0, (s, c) => s + c), 2);
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

    test('waveformRgb 纯色帧各通道计数落在各自通道级', () {
      // 4x2 纯色 (200, 100, 50)：R 计数落在 200 级、G 在 100、B 在 50，
      // Y = (77*200+150*100+29*50+128)>>8 = 124。
      final rgba = Uint8List(4 * 2 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 200;
        rgba[i + 1] = 100;
        rgba[i + 2] = 50;
        rgba[i + 3] = 255;
      }
      final (r, g, b, y, cols) = waveformRgb(rgba, 4, 2);
      expect(cols, 4);
      for (var c = 0; c < cols; c++) {
        expect(r[200 * cols + c], 2, reason: 'R 列 $c');
        expect(g[100 * cols + c], 2, reason: 'G 列 $c');
        expect(b[50 * cols + c], 2, reason: 'B 列 $c');
        expect(y[124 * cols + c], 2, reason: 'Y 列 $c');
      }
      expect(r.fold<int>(0, (s, c) => s + c), 8);
      expect(g.fold<int>(0, (s, c) => s + c), 8);
      expect(b.fold<int>(0, (s, c) => s + c), 8);
      expect(y.fold<int>(0, (s, c) => s + c), 8);
    });

    test('条带分片合并与全帧分析一致（波形/直方图）', () {
      // 16x8 渐变帧：各像素 RGB 各异。
      const w = 16, h = 8;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = (i * 7) % 256;
        rgba[i * 4 + 1] = (i * 13) % 256;
        rgba[i * 4 + 2] = (i * 29) % 256;
        rgba[i * 4 + 3] = 255;
      }
      // 按水平条带切成 3 片（行数不整除，末片更大），模拟 worker 池。
      final parts = <Map<String, Object?>>[];
      final histParts = <Map<String, Object?>>[];
      const rowsPer = 3;
      for (var y0 = 0; y0 < h; y0 += rowsPer) {
        final y1 = y0 + rowsPer > h ? h : y0 + rowsPer;
        final band =
            Uint8List.sublistView(rgba, y0 * w * 4, y1 * w * 4);
        final (r, g, b, y, cols) = waveformRgb(band, w, y1 - y0);
        parts.add({'kind': 'waveform', 'r': r, 'g': g, 'b': b, 'y': y,
            'columns': cols});
        final (hr, hg, hb, hy) = histogramRgb(band);
        histParts.add(
            {'kind': 'histogram', 'r': hr, 'g': hg, 'b': hb, 'y': hy});
      }
      final merged = mergeInstrumentResults(parts);
      final (fr, fg, fb, fy, fcols) = waveformRgb(rgba, w, h);
      expect(merged['columns'], fcols);
      expect(merged['r'], fr);
      expect(merged['g'], fg);
      expect(merged['b'], fb);
      expect(merged['y'], fy);
      final mergedHist = mergeInstrumentResults(histParts);
      final (hr, hg, hb, hy) = histogramRgb(rgba);
      expect(mergedHist['r'], hr);
      expect(mergedHist['g'], hg);
      expect(mergedHist['b'], hb);
      expect(mergedHist['y'], hy);
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
        final state = IspStudioState.withDefaultGraph(); // 默认图：源→…→gamma→预览
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
      final state = IspStudioState.withDefaultGraph();
      expect(state.histogramChannels('n1'), {'r', 'g', 'b'});
      state.toggleHistogramChannel('n1', 'g');
      expect(state.histogramChannels('n1'), {'r', 'b'});
      state.toggleHistogramChannel('n1', 'g');
      expect(state.histogramChannels('n1'), {'r', 'g', 'b'});
    });

    test('直方图 Y 通道与 R/G/B 互斥', () {
      final state = IspStudioState.withDefaultGraph();
      // 选中 Y：R/G/B 全部关闭。
      state.toggleHistogramChannel('n1', 'y');
      expect(state.histogramChannels('n1'), {'y'});
      // Y 态下勾选任一 RGB 通道：Y 取消，该通道生效。
      state.toggleHistogramChannel('n1', 'g');
      expect(state.histogramChannels('n1'), {'g'});
      // 取消 Y 后恢复默认 RGB 全选。
      state.toggleHistogramChannel('n1', 'y');
      state.toggleHistogramChannel('n1', 'y');
      expect(state.histogramChannels('n1'), {'r', 'g', 'b'});
    });

    test('波形监视器 Y 通道与 R/G/B 互斥', () {
      final state = IspStudioState.withDefaultGraph();
      // 缺省只显示 Y。
      expect(state.waveformChannels('n1'), {'y'});
      // Y 态下勾选 G：Y 取消，G 生效；R/G/B 之间可多选。
      state.toggleWaveformChannel('n1', 'g');
      expect(state.waveformChannels('n1'), {'g'});
      state.toggleWaveformChannel('n1', 'r');
      expect(state.waveformChannels('n1'), {'r', 'g'});
      // 选中 Y：R/G/B 全部关闭。
      state.toggleWaveformChannel('n1', 'y');
      expect(state.waveformChannels('n1'), {'y'});
      // 取消 Y 后恢复 RGB 全选。
      state.toggleWaveformChannel('n1', 'y');
      expect(state.waveformChannels('n1'), {'r', 'g', 'b'});
    });

    test('未连接的仪器节点不产生分析结果', () async {      const w = 8, h = 8;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_instr2_$stamp.raw');
      await raw.writeAsBytes(List<int>.generate(w * h, (i) => i));
      try {
        final state = IspStudioState.withDefaultGraph();
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

      final state = IspStudioState.withDefaultGraph();
      final histId = state.graph.addNode('histogram', 0, 0);
      final bins = Uint32List(256)..[128] = 100;
      state.instrumentResults[histId] = {
        'kind': 'histogram',
        'r': bins,
        'g': bins,
        'b': bins,
        'y': bins,
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
