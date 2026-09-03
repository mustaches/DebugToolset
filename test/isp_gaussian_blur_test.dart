import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('applyGaussianBlur', () {
    test('平坦图不变（凸组合）', () {
      final data = Uint16List(8 * 8 * 3);
      for (var i = 0; i < data.length; i++) {
        data[i] = 1000;
      }
      applyGaussianBlur(data, width: 8, height: 8, sigma: 2.0);
      expect(data.every((v) => v == 1000), isTrue);
    });

    test('strength=0 恒等（直通）', () {
      final data = Uint16List.fromList(
          List<int>.generate(8 * 8 * 3, (i) => (i * 37) % 4096));
      final orig = Uint16List.fromList(data);
      applyGaussianBlur(data, width: 8, height: 8, sigma: 2.0, strength: 0);
      expect(data, orig);
    });

    test('冲激响应按高斯核扩散（中心 = k[r]²×峰值，左右对称）', () {
      const w = 9, h = 9;
      final data = Uint16List(w * h * 3);
      // 中心像素纯白冲激。
      data[(4 * w + 4) * 3] = 4095;
      data[(4 * w + 4) * 3 + 1] = 4095;
      data[(4 * w + 4) * 3 + 2] = 4095;
      const sigma = 1.0;
      applyGaussianBlur(data, width: w, height: h, sigma: sigma);
      // 一维核（σ=1，半径 3）中心权重 k0：冲激二维扩散后中心 = k0²×峰值。
      final k0 = gaussCenterWeight();
      final center = data[(4 * w + 4) * 3];
      expect(center, closeTo((4095 * k0 * k0).round(), 2));
      // 左右对称。
      expect(data[(4 * w + 3) * 3], data[(4 * w + 5) * 3]);
      expect(data[(4 * w + 3) * 3], greaterThan(0));
      expect(data[(4 * w + 3) * 3], lessThan(center));
    });

    test('模糊降低方差（噪声被平滑）', () {
      const w = 32, h = 32;
      final data = Uint16List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        final v = 1000 + ((i * 31) % 201) - 100;
        data[i * 3] = data[i * 3 + 1] = data[i * 3 + 2] = v;
      }
      double variance(Uint16List d) {
        var mean = 0.0;
        for (var i = 0; i < w * h; i++) {
          mean += d[i * 3];
        }
        mean /= w * h;
        var s = 0.0;
        for (var i = 0; i < w * h; i++) {
          s += (d[i * 3] - mean) * (d[i * 3] - mean);
        }
        return s / (w * h);
      }

      final before = variance(data);
      applyGaussianBlur(data, width: w, height: h, sigma: 1.5);
      expect(variance(data), lessThan(before));
    });
  });

  group('gaussian_blur 节点', () {
    test('注册为四域输入输出的 Process 算子', () {
      final type = IspNodeRegistry.byId('gaussian_blur');
      expect(type, isNotNull);
      expect(type!.displayName, '高斯模糊');
      expect(type.inputPort('in')!.type, IspPortType.rgb);
      expect(type.inputPort('in_yuv')!.type, IspPortType.yuv);
      expect(type.inputPort('in_hsl')!.type, IspPortType.hsl);
      expect(type.inputPort('in_mono')!.type, IspPortType.mono);
      expect(type.outputPort('out_rgb')!.type, IspPortType.rgb);
      expect(type.outputPort('out_yuv')!.type, IspPortType.yuv);
      expect(type.outputPort('out_hsl')!.type, IspPortType.hsl);
      expect(type.outputPort('out_mono')!.type, IspPortType.mono);
    });

    test('链执行：RGB 域高斯模糊作用于主帧', () async {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final blurId = graph.addNode('gaussian_blur', 200, 0);
      final prevId = graph.addNode('preview', 400, 0);
      expect(graph.connect(srcId, 'out_rgb', blurId, 'in'), isNull);
      expect(graph.connect(blurId, 'out_rgb', prevId, 'in'), isNull);

      final chain = compileChain(graph, prevId);
      expect(chain.map((c) => c['typeId']),
          ['image_source', 'gaussian_blur', 'preview']);

      // 注入 2x1 黑白冲激：模糊后黑点被白色扩散染亮、白点被拉低。
      final src = Uint8List.fromList([0, 0, 0, 255, 255, 255, 255, 255]);
      final rgba = await runChainFrame(chain, 0,
          sourceRgba: src, sourceWidth: 2, sourceHeight: 1);
      expect(rgba[0], greaterThan(0), reason: '白色应扩散到左侧黑色像素');
      expect(rgba[4], lessThan(255), reason: '白色像素被邻域黑色拉低');
    });

    test('链执行：YUV 域输入模糊并同格式输出', () async {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final blurId = graph.addNode('gaussian_blur', 200, 0);
      final prevId = graph.addNode('preview', 400, 0);
      expect(graph.connect(srcId, 'out_yuv', blurId, 'in_yuv'), isNull);
      expect(graph.connect(blurId, 'out_yuv', prevId, 'in_yuv'), isNull);

      // 注入 4x1 帧：Y 通道黑白交替。
      final src = Uint8List.fromList([
        0, 0, 0, 255, 255, 255, 255, 255,
        0, 0, 0, 255, 255, 255, 255, 255,
      ]);
      final rgba = await runChainFrame(compileChain(graph, prevId), 0,
          sourceRgba: src, sourceWidth: 4, sourceHeight: 1);
      // 中间像素被邻域扩散染亮（不再纯黑）。
      expect(rgba[8], greaterThan(0));
    });

    test('链执行：Mono 域单通道模糊', () async {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('rgb_splitter', 100, 0);
      final blurId = graph.addNode('gaussian_blur', 200, 0);
      final prevId = graph.addNode('preview', 400, 0);
      expect(graph.connect(srcId, 'out_rgb', splitId, 'in'), isNull);
      expect(graph.connect(splitId, 'out_r', blurId, 'in_mono'), isNull);
      expect(graph.connect(blurId, 'out_mono', prevId, 'in_mono'), isNull);

      // R=黑/白冲激（2x1）。
      final src = Uint8List.fromList([0, 50, 100, 255, 255, 100, 50, 255]);
      final rgba = await runChainFrame(compileChain(graph, prevId), 0,
          sourceRgba: src, sourceWidth: 2, sourceHeight: 1);
      expect(rgba[0], greaterThan(0), reason: 'R 通道白色应向左扩散');
      expect(rgba[4], lessThan(255), reason: 'R 通道白色被邻域拉低');
    });

    test('互斥输入组：in_mono 已连接时 in 不可接', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('rgb_splitter', 100, 0);
      final blurId = graph.addNode('gaussian_blur', 200, 0);
      expect(graph.connect(splitId, 'out_r', blurId, 'in_mono'), isNull);
      expect(graph.connect(srcId, 'out_rgb', blurId, 'in'),
          contains('只能接入一路'));
    });

    test('运行预览后双联对比图填充（调整前/调整后）', () async {
      const w = 16, h = 16;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_gb_$stamp.raw');
      await raw.writeAsBytes([
        for (var i = 0; i < w * h; i++) ...[i % 256, 0],
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
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');

        final blurId = state.graph.addNode('gaussian_blur', 0, 0);
        expect(state.graph.connect(gammaId, 'out', blurId, 'in'), isNull);
        await state.runPreview();

        expect(state.previewImages[blurId], isNotNull,
            reason: '调整后（输出链）应有预览图');
        expect(state.previewInputImages[blurId], isNotNull,
            reason: '调整前（输入链）应有预览图');
      } finally {
        await raw.delete();
      }
    });
  });
}

/// σ=1、半径 3 的归一化高斯核中心权重。
double gaussCenterWeight() {
  var sum = 0.0;
  var center = 0.0;
  for (var i = -3; i <= 3; i++) {
    final v = math.exp(-(i * i) / 2.0);
    sum += v;
    if (i == 0) center = v;
  }
  return center / sum;
}
