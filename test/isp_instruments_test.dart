import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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
      // 4x2 纯灰 128 → Y=128，每列计数 = 高度 × 驻留权重刻度。
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
        expect(counts[128 * cols + c], 2 * 256, reason: '列 $c');
      }
      expect(counts.fold<int>(0, (s, c) => s + c), 8 * 256);
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
        expect(r[200 * cols + c], 2 * 256, reason: 'R 列 $c');
        expect(g[100 * cols + c], 2 * 256, reason: 'G 列 $c');
        expect(b[50 * cols + c], 2 * 256, reason: 'B 列 $c');
        expect(y[124 * cols + c], 2 * 256, reason: 'Y 列 $c');
      }
      expect(r.fold<int>(0, (s, c) => s + c), 8 * 256);
      expect(g.fold<int>(0, (s, c) => s + c), 8 * 256);
      expect(b.fold<int>(0, (s, c) => s + c), 8 * 256);
      expect(y.fold<int>(0, (s, c) => s + c), 8 * 256);
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

    test('vectorscope 行模式（隔行条带）跨行不连线，行内轨迹一致', () {
      // 两行：首行全灰、末行全红。整帧单趟会把灰→红连成跨行斜线；
      // rowWidth 模式每行重置电子束起点，只有行内轨迹（此处为点）。
      Uint8List twoRows() {
        final rgba = Uint8List(8 * 2 * 4);
        for (var i = 0; i < 8; i++) {
          rgba[i * 4] = 128;
          rgba[i * 4 + 1] = 128;
          rgba[i * 4 + 2] = 128;
          rgba[i * 4 + 3] = 255;
        }
        for (var i = 8; i < 16; i++) {
          rgba[i * 4] = 255;
          rgba[i * 4 + 1] = 0;
          rgba[i * 4 + 2] = 0;
          rgba[i * 4 + 3] = 255;
        }
        return rgba;
      }

      final plain = vectorscope(twoRows());
      final banded = vectorscope(twoRows(), rowWidth: 8);
      // 灰点 (256,256) 与红点 (170,511) 之间的中间格：
      // 单趟连线经过，行模式为空。
      const mid = 383 * 512 + 213;
      expect(plain[mid], greaterThan(0));
      expect(banded[mid], 0);
      // 两端点两种模式都有。
      expect(banded[256 * 512 + 256], greaterThan(0));
      expect(banded[511 * 512 + 170], greaterThan(0));
    });

    test('vectorscope 隔行条带拆分合并与整帧单趟结果一致', () {
      // 每行图案相同且行首像素 == 行末像素：跨行接续段长度为零，
      // 条带合并后与整帧单趟逐格相等（行内轨迹完全一致）。
      const w = 64, h = 48, n = 4;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final xx = x == w - 1 ? 0 : x; // 行末 = 行首
          rgba[i] = (xx * 7) % 256;
          rgba[i + 1] = (xx * 13) % 256;
          rgba[i + 2] = (xx * 29) % 256;
          rgba[i + 3] = 255;
        }
      }
      // 与 InstrumentAnalyzer.analyzeVectorscopeParallel 相同的隔行切法。
      final parts = <Uint32List>[];
      for (var b = 0; b < n; b++) {
        var rows = 0;
        for (var y = b; y < h; y += n) {
          rows++;
        }
        final band = Uint8List(rows * w * 4);
        var dst = 0;
        for (var y = b; y < h; y += n, dst += w * 4) {
          band.setRange(dst, dst + w * 4, rgba, y * w * 4);
        }
        parts.add(vectorscope(band, rowWidth: w));
      }
      final merged = parts.first;
      for (var p = 1; p < parts.length; p++) {
        for (var i = 0; i < merged.length; i++) {
          merged[i] += parts[p][i];
        }
      }
      expect(merged, vectorscope(rgba));
    });

    test('波形竖向扫迹：亮度正比于电子束扫过频次', () {
      // 4 列宽图像：左半黑、右半白（水平硬边）。每行在 col1→col2
      // 之间产生一次 0↔255 扫迹。
      const w = 4, h = 8;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final v = x < 2 ? 0 : 255;
          rgba[i] = v;
          rgba[i + 1] = v;
          rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
      }
      final (counts, cols) = waveformLuma(rgba, w, h);
      expect(cols, 4);
      // 驻留：每列电平计数 = 行数 × 256。
      expect(counts[0 * cols + 0], h * 256);
      expect(counts[255 * cols + 2], h * 256);
      // 竖向扫迹：归入新列 col2 的中间电平每行被扫过一次 →
      // 计数 = 行数（为驻留的 1/256，对数刻度下约一半亮度）。
      expect(counts[128 * cols + 2], h);
      expect(counts[1 * cols + 2], h);
      expect(counts[254 * cols + 2], h);
      // 无跳变的 col1 中间电平无扫迹（字幕灰幕问题：无扫过不填充）。
      expect(counts[128 * cols + 1], 0);
    });

    test('waveform 按可见通道选择性统计与全通道结果一致', () {
      const w = 32, h = 8;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = (i * 7) % 256;
        rgba[i * 4 + 1] = (i * 13) % 256;
        rgba[i * 4 + 2] = (i * 29) % 256;
        rgba[i * 4 + 3] = 255;
      }
      final (fr, fg, fb, fy, fcols) = waveformRgb(rgba, w, h);
      final (tables, cols) = waveformSelective(rgba, w, h, {'y', 'b'});
      expect(cols, fcols);
      expect(tables.keys, unorderedEquals(['y', 'b']));
      expect(tables['y'], fy);
      expect(tables['b'], fb);
      // 空通道集：不统计但仍给出列数。
      final (empty, ecols) = waveformSelective(rgba, w, h, {});
      expect(empty, isEmpty);
      expect(ecols, fcols);
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

    test('预览运行后波形/矢量示波器节点拿到显示图像', () async {
      const w = 16, h = 16;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_instr_wv_$stamp.raw');
      await raw.writeAsBytes(List<int>.generate(w * h, (i) => i));
      try {
        final state = IspStudioState.withDefaultGraph();
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

        final waveId = state.graph.addNode('waveform', 0, 0);
        final vecId = state.graph.addNode('vectorscope', 0, 0);
        expect(state.graph.connect(gammaId, 'out', waveId, 'in'), isNull);
        expect(state.graph.connect(gammaId, 'out', vecId, 'in'), isNull);

        await state.runPreview();

        expect(state.statusMessage, contains('预览就绪'));
        expect(state.instrumentResults[waveId], isNotNull);
        expect(state.instrumentResults[vecId], isNotNull);
        expect(state.instrumentImages[waveId], isNotNull,
            reason: '波形示波器应有解码后的显示图像');
        expect(state.instrumentImages[vecId], isNotNull,
            reason: '矢量示波器应有解码后的显示图像');
      } finally {
        await raw.delete();
      }
    });

    test('运行预览进度：完成后 progress 与 progressTick 都收敛到 1', () async {
      // 8x8、8bit、RGGB 单帧，像素 0..63。
      const w = 8, h = 8;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_prog_$stamp.raw');
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

        // 进度显示值只能前进不能后退。
        var last = 0.0;
        state.progressTick.addListener(() {
          expect(state.progressTick.value, greaterThanOrEqualTo(last));
          last = state.progressTick.value;
        });

        await state.runPreview();
        expect(state.statusMessage, contains('预览就绪'));
        expect(state.progress, 1.0);
        expect(state.progressTick.value, 1.0);
        expect(last, greaterThan(0), reason: '运行过程中进度显示值应有连续中间值');
      } finally {
        await raw.delete();
      }
    });

    test('波形通道切换后递增 instrumentTick 触发局部重绘', () async {
      // 8x8、8bit、RGGB 单帧，像素 0..63。
      const w = 8, h = 8;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_instr3_$stamp.raw');
      await raw.writeAsBytes(List<int>.generate(w * h, (i) => i));
      try {
        final state = IspStudioState.withDefaultGraph();
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

        final waveId = state.graph.addNode('waveform', 0, 0);
        expect(state.graph.connect(gammaId, 'out', waveId, 'in'), isNull);

        await state.runPreview();
        expect(state.instrumentResults[waveId], isNotNull);

        final tick = state.instrumentTick.value;
        state.toggleWaveformChannel(waveId, 'y');
        // 重绘图像异步解码：轮询等它完成（失败时超时报错而非挂起）。
        for (var i = 0; i < 200 && state.instrumentTick.value == tick; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(state.instrumentTick.value, greaterThan(tick),
            reason: '通道切换后 instrumentTick 必须递增，否则仪器附加区不重建');
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
      // 缺省 RGB 全开（与直方图一致）。
      expect(state.waveformChannels('n1'), {'r', 'g', 'b'});
      // R/G/B 态下勾选 G：G 被关闭，剩下 R/B。
      state.toggleWaveformChannel('n1', 'g');
      expect(state.waveformChannels('n1'), {'r', 'b'});
      // 选中 Y：R/G/B 全部关闭。
      state.toggleWaveformChannel('n1', 'y');
      expect(state.waveformChannels('n1'), {'y'});
      // 取消 Y 后恢复 RGB 全选。
      state.toggleWaveformChannel('n1', 'y');
      expect(state.waveformChannels('n1'), {'r', 'g', 'b'});
    });

    test('修改图片源文件后重新运行预览，仪器结果随之刷新', () async {
      img.Image solid(int v) {
        final image = img.Image(width: 16, height: 16);
        img.fill(image, color: img.ColorRgb8(v, v, v));
        return image;
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final fileA = File('${Directory.systemTemp.path}/isp_img_a_$stamp.bmp');
      final fileB = File('${Directory.systemTemp.path}/isp_img_b_$stamp.bmp');
      await fileA.writeAsBytes(img.encodeBmp(solid(10)));
      await fileB.writeAsBytes(img.encodeBmp(solid(245)));
      try {
        final state = IspStudioState();
        final srcId = state.graph.addNode('image_source', 0, 0);
        final pvId = state.graph.addNode('preview', 300, 0);
        final waveId = state.graph.addNode('waveform', 600, 0);
        expect(state.graph.connect(srcId, 'out_rgb', pvId, 'in'), isNull);
        expect(state.graph.connect(srcId, 'out_rgb', waveId, 'in'), isNull);
        state.setParam(srcId, 'filePath', fileA.path);

        int argmaxLevel() {
          final counts = state.instrumentResults[waveId]?['y'] as Uint32List?;
          expect(counts, isNotNull, reason: '波形仪器应有分析结果');
          var best = 0, bestC = 0;
          final cols =
              (state.instrumentResults[waveId]!['columns'] as num).toInt();
          for (var lvl = 0; lvl < 256; lvl++) {
            var c = 0;
            for (var col = 0; col < cols; col++) {
              c += counts![lvl * cols + col];
            }
            if (c > bestC) {
              bestC = c;
              best = lvl;
            }
          }
          return best;
        }

        await state.runPreview();
        expect(state.statusMessage, contains('预览就绪'));
        expect(argmaxLevel(), lessThan(40), reason: '暗图计数应集中在低亮度');

        state.setParam(srcId, 'filePath', fileB.path);
        await state.runPreview();
        expect(state.statusMessage, contains('预览就绪'));
        expect(argmaxLevel(), greaterThan(220),
            reason: '换成亮图重新运行后，波形计数应集中在高亮度');
      } finally {
        await fileA.delete();
        await fileB.delete();
      }
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

