import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/isp_studio_view.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('minmaxMono 分析函数', () {
    test('灰度帧取 R 通道最小/最大值', () {
      // 三个像素：灰度 128、5、250（mono 出图 R=G=B）。
      final rgba = Uint8List.fromList(
          [128, 128, 128, 255, 5, 5, 5, 255, 250, 250, 250, 255]);
      final (mn, mx) = minmaxMono(rgba);
      expect(mn, 5);
      expect(mx, 250);
    });

    test('纯色帧最小值等于最大值；空帧返回 (0, 0)', () {
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = rgba[i + 1] = rgba[i + 2] = 77;
        rgba[i + 3] = 255;
      }
      final (mn, mx) = minmaxMono(rgba);
      expect(mn, 77);
      expect(mx, 77);
      expect(minmaxMono(Uint8List(0)), (0, 0));
    });

    test('条带分片合并：max 取各片最大、min 取各片最小', () {
      final parts = [
        {'kind': 'minmax', 'min': 30, 'max': 200},
        {'kind': 'minmax', 'min': 10, 'max': 150},
        {'kind': 'minmax', 'min': 40, 'max': 250},
      ];
      final merged = mergeInstrumentResults(parts);
      expect(merged['min'], 10);
      expect(merged['max'], 250);
    });

    test('instrumentAnalyze 分发 minmax 类型', () {
      final rgba = Uint8List.fromList([3, 3, 3, 255, 99, 99, 99, 255]);
      final result = instrumentAnalyze('minmax', rgba, 2, 1);
      expect(result['kind'], 'minmax');
      expect(result['min'], 3);
      expect(result['max'], 99);
    });
  });

  group('minmax 节点注册', () {
    test('最值保持器是只进不出的仪器节点，带 in_mono 输入', () {
      final type = IspNodeRegistry.byId('minmax');
      expect(type, isNotNull);
      expect(type!.displayName, '最值保持器');
      expect(type.outputs, isEmpty);
      final monoPort = type.inputPort('in_mono');
      expect(monoPort, isNotNull);
      expect(monoPort!.type, IspPortType.mono);
      expect(instrumentTypes.contains('minmax'), isTrue);
      expect(sinkNodeTypes.contains('minmax'), isTrue);
    });
  });

  group('IspStudioState 最值保持', () {
    test('运行预览后拿到当前帧最值与跨帧保持值，复位后清除保持值', () async {
      img.Image solid(int v) {
        final image = img.Image(width: 16, height: 16);
        img.fill(image, color: img.ColorRgb8(v, v, v));
        return image;
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final fileA = File('${Directory.systemTemp.path}/isp_mm_a_$stamp.bmp');
      final fileB = File('${Directory.systemTemp.path}/isp_mm_b_$stamp.bmp');
      await fileA.writeAsBytes(img.encodeBmp(solid(10)));
      await fileB.writeAsBytes(img.encodeBmp(solid(245)));
      try {
        final state = IspStudioState();
        final srcId = state.graph.addNode('image_source', 0, 0);
        final splitId = state.graph.addNode('rgb_splitter', 200, 0);
        final mmId = state.graph.addNode('minmax', 400, 0);
        expect(state.graph.connect(srcId, 'out_rgb', splitId, 'in'), isNull);
        expect(
            state.graph.connect(splitId, 'out_r', mmId, 'in_mono'), isNull);
        state.setParam(srcId, 'filePath', fileA.path);

        await state.runPreview();
        var result = state.instrumentResults[mmId];
        expect(result, isNotNull, reason: '最值保持器应有分析结果');
        expect(result!['min'], 10);
        expect(result['max'], 10);
        expect(result['holdMin'], 10, reason: '首帧保持值等于当前帧');
        expect(result['holdMax'], 10);

        // 换成亮图重跑：当前帧最值更新，保持值累计历史极值。
        state.setParam(srcId, 'filePath', fileB.path);
        await state.runPreview();
        result = state.instrumentResults[mmId];
        expect(result!['min'], 245);
        expect(result['max'], 245);
        expect(result['holdMin'], 10, reason: '保持最小值应留住暗帧的 10');
        expect(result['holdMax'], 245);

        // 复位：保持值清除，回到当前帧口径（下次刷新重新累计）。
        state.resetMinmaxHold(mmId);
        result = state.instrumentResults[mmId];
        expect(result, isNotNull);
        expect(result!.containsKey('holdMin'), isFalse);
        expect(result.containsKey('holdMax'), isFalse);
      } finally {
        await fileA.delete();
        await fileB.delete();
      }
    });

    test('未连接的最值保持器不产生分析结果', () async {
      img.Image solid(int v) {
        final image = img.Image(width: 8, height: 8);
        img.fill(image, color: img.ColorRgb8(v, v, v));
        return image;
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File('${Directory.systemTemp.path}/isp_mm_c_$stamp.bmp');
      await file.writeAsBytes(img.encodeBmp(solid(10)));
      try {
        final state = IspStudioState();
        final srcId = state.graph.addNode('image_source', 0, 0);
        state.setParam(srcId, 'filePath', file.path);
        final mmId = state.graph.addNode('minmax', 400, 0); // 不连接
        await state.runPreview();
        expect(state.instrumentResults.containsKey(mmId), isFalse);
      } finally {
        await file.delete();
      }
    });
  });

  group('最值保持器节点显示', () {
    testWidgets('显示当前帧最值、保持值与复位按钮', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = IspStudioState.withDefaultGraph();
      final mmId = state.graph.addNode('minmax', 0, 0);
      state.instrumentResults[mmId] = {
        'kind': 'minmax',
        'min': 12,
        'max': 250,
        'holdMin': 5,
        'holdMax': 255,
      };
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: IspStudioView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('最大'), findsOneWidget);
      expect(find.text('最小'), findsOneWidget);
      expect(find.text('保持 255'), findsOneWidget);
      expect(find.text('保持 5'), findsOneWidget);
      expect(find.text('复位'), findsOneWidget);

      // 点击复位：保持值从结果中移除。
      await tester.tap(find.text('复位'));
      await tester.pumpAndSettle();
      final result = state.instrumentResults[mmId]!;
      expect(result.containsKey('holdMin'), isFalse);
      expect(result.containsKey('holdMax'), isFalse);
    });
  });

  group('extractChannelGray 通道提取', () {
    test('r/g/b 通道取对应字节', () {
      final rgba =
          Uint8List.fromList([200, 100, 50, 255, 10, 20, 30, 255]);
      final r = extractChannelGray(rgba, 'r');
      expect([r[0], r[1], r[2]], [200, 200, 200]);
      expect([r[4], r[5], r[6]], [10, 10, 10]);
      final g = extractChannelGray(rgba, 'g');
      expect([g[0], g[4]], [100, 20]);
      final b = extractChannelGray(rgba, 'b');
      expect([b[0], b[4]], [50, 30]);
    });

    test('y/u/v 为 BT.601 全范围：灰色 U/V 归零于 128', () {
      Uint8List solid(int r, int g, int b) =>
          Uint8List.fromList([r, g, b, 255]);
      // 中灰：Y=128，U=V=128。
      final gray = extractChannelGray(solid(128, 128, 128), 'y');
      expect(gray[0], 128);
      expect(extractChannelGray(solid(128, 128, 128), 'u')[0], 128);
      expect(extractChannelGray(solid(128, 128, 128), 'v')[0], 128);
      // 纯红：Y≈76，V 偏高、U 偏低（与 rgbToYuv 同系数）。
      expect(extractChannelGray(solid(255, 0, 0), 'y')[0], 76);
      expect(extractChannelGray(solid(255, 0, 0), 'v')[0], greaterThan(200));
      expect(extractChannelGray(solid(255, 0, 0), 'u')[0], lessThan(100));
    });

    test('h/s/l 为标准 HSL 映射到 0..255（与 rgbToHsl 同口径）', () {
      Uint8List solid(int r, int g, int b) =>
          Uint8List.fromList([r, g, b, 255]);
      // 纯红：H=0、S=1→255、L=0.5→128。
      expect(extractChannelGray(solid(255, 0, 0), 'h')[0], 0);
      expect(extractChannelGray(solid(255, 0, 0), 's')[0], 255);
      expect(extractChannelGray(solid(255, 0, 0), 'l')[0], 128);
      // 中灰：S=0，L=128。
      expect(extractChannelGray(solid(128, 128, 128), 's')[0], 0);
      expect(extractChannelGray(solid(128, 128, 128), 'l')[0], 128);
    });

    test('未知通道原样返回', () {
      final rgba = Uint8List.fromList([1, 2, 3, 255]);
      expect(identical(extractChannelGray(rgba, 'x'), rgba), isTrue);
    });
  });

  group('播放中分路器通道馈源', () {
    test('同分路器不同通道下的多台最值保持器播放时读数不同', () async {
      // 8x8、8bit、RGGB 共 3 帧：R 相位 250、B 相位 5、G 相位 120，
      // 去马赛克后 R/G/B 三通道电平差异显著。
      const w = 8, h = 8, frames = 3;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_mm_play_$stamp.raw');
      await raw.writeAsBytes([
        for (var f = 0; f < frames; f++)
          for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++) ...() {
              final v = (x.isEven && y.isEven)
                  ? 250
                  : (x.isOdd && y.isOdd)
                      ? 5
                      : 120;
              return [v & 0xFF, (v >> 8) & 0xFF];
            }(),
      ]);
      try {
        final state = IspStudioState.withDefaultGraph();
        addTearDown(state.dispose);
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        final gammaId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'gamma')
            .key;
        // 灰世界自动白平衡会把这种均匀色偏合成图拉成灰图（通道均值
        // 归一），测试改为手动白平衡（增益 1.0）保留通道差异。
        final wbId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'white_balance')
            .key;
        state.setParam(wbId, 'mode', 'manual');
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');

        // 预览保持在主链（gamma.out）上：播放只跑预览链，三台最值
        // 保持器都复用该帧——无端口修正时读数完全一样（回归场景）。
        final splitId = state.graph.addNode('rgb_splitter', 0, 0);
        expect(state.graph.connect(gammaId, 'out', splitId, 'in'), isNull);
        final mmR = state.graph.addNode('minmax', 0, 0);
        final mmG = state.graph.addNode('minmax', 0, 0);
        final mmB = state.graph.addNode('minmax', 0, 0);
        expect(state.graph.connect(splitId, 'out_r', mmR, 'in_mono'), isNull);
        expect(state.graph.connect(splitId, 'out_g', mmG, 'in_mono'), isNull);
        expect(state.graph.connect(splitId, 'out_b', mmB, 'in_mono'), isNull);

        final playing = state.togglePlayback();
        // 等三台仪器都拿到播放刷新结果（失败时超时报错而非挂起）。
        for (var i = 0; i < 300; i++) {
          if (state.instrumentResults[mmR]?['max'] != null &&
              state.instrumentResults[mmG]?['max'] != null &&
              state.instrumentResults[mmB]?['max'] != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        state.stopPlayback();
        await playing;

        final rMax = state.instrumentResults[mmR]?['max'] as int?;
        final gMax = state.instrumentResults[mmG]?['max'] as int?;
        final bMax = state.instrumentResults[mmB]?['max'] as int?;
        expect(rMax, isNotNull, reason: 'R 通道最值保持器应有结果');
        expect(gMax, isNotNull, reason: 'G 通道最值保持器应有结果');
        expect(bMax, isNotNull, reason: 'B 通道最值保持器应有结果');
        // 回归守卫：三通道读数不得完全一样；R(250) 应显著高于 B(5)。
        expect(rMax, greaterThan(bMax! + 100),
            reason: 'R 通道最大值应显著高于 B 通道（端口修正生效）');
        expect(gMax, greaterThan(bMax + 40));
        expect(gMax, lessThan(rMax!));
      } finally {
        await raw.delete();
      }
    });
  });
}
