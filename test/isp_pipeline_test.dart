import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  /// Windows 上刚关闭的文件句柄删除时可能短暂被占用，重试几次。
  Future<void> deleteQuietly(File f) async {
    for (var i = 0; i < 5; i++) {
      try {
        await f.delete();
        return;
      } on PathAccessException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// 8bit unpacked RAW：每像素一个 16 位小端字（LSB 对齐，与位深无关）。
  List<int> raw8Le(Iterable<int> px) => [
        for (final v in px) ...[v & 0xFF, (v >> 8) & 0xFF],
      ];

  group('compileChain', () {
    test('default graph compiles preview chain in topo order', () {
      final graph = defaultGraph();
      final previewId = graph.nodes.entries
          .firstWhere((e) => e.value.typeId == 'preview')
          .key;
      final chain = compileChain(graph, previewId);
      expect(chain.first['typeId'], 'bayer_source');
      expect(chain.last['typeId'], 'preview');
      final typeIds = chain.map((op) => op['typeId'] as String).toList();
      // 顺序约束：去马赛克在白平衡前，白平衡在 CCM 前，CCM 在 Gamma 前。
      expect(typeIds.indexOf('demosaic') < typeIds.indexOf('white_balance'),
          isTrue);
      expect(typeIds.indexOf('white_balance') < typeIds.indexOf('ccm'), isTrue);
      expect(typeIds.indexOf('ccm') < typeIds.indexOf('gamma'), isTrue);
      // image_output 接在预览之后，不在预览的上游链中。
      expect(typeIds.contains('image_output'), isFalse);
    });

    test('missing sink throws', () {
      final graph = defaultGraph();
      expect(() => compileChain(graph, 'nope'), throwsStateError);
    });

    test('chain without source throws', () {
      final graph = defaultGraph();
      final srcId = graph.nodes.entries
          .firstWhere((e) => e.value.typeId == 'bayer_source')
          .key;
      graph.removeNode(srcId);
      final previewId = graph.nodes.entries
          .firstWhere((e) => e.value.typeId == 'preview')
          .key;
      expect(() => compileChain(graph, previewId), throwsStateError);
    });

    test('mux4 未选中的输入支路不参与编译（死支路剔除）', () {
      // 源1~源4 各接一个独立源：只有 select 选中的支路参与编译
      //（未选中支路不解码、不计入源节点数）。
      final graph = IspGraph();
      final mux = graph.addNode('mux4', 0, 0);
      final pv = graph.addNode('preview', 0, 0);
      final srcs = [
        for (var i = 0; i < 4; i++) graph.addNode('image_source', 0, 0),
      ];
      const ports = ['in1', 'in2', 'in3', 'in4'];
      for (var i = 0; i < 4; i++) {
        expect(graph.connect(srcs[i], 'out_rgb', mux, ports[i]), isNull);
      }
      expect(graph.connect(mux, 'out_rgb', pv, 'in'), isNull);

      List<String> chainSrcIds(int select) {
        graph.nodes[mux]!.paramValues['select'] = select;
        return [
          for (final op in compileChain(graph, pv))
            if (op['typeId'] == 'image_source') op['nodeId'] as String,
        ];
      }

      expect(chainSrcIds(1), [srcs[0]]);
      expect(chainSrcIds(3), [srcs[2]]);
      // 未选中的支路节点不在链中。
      final ids = [
        for (final op in compileChain(graph, pv)) op['nodeId'] as String,
      ];
      expect(ids, isNot(contains(srcs[1])));
      expect(ids, contains(mux));
    });

    test('双输入评价仪器允许两个源节点（参考/测试两路）', () {
      // PSNR/SSIM/LPIPS 等全参考评价数字表有两路输入，各自接独立
      // 图片源：编译到该汇点的链含 2 个源节点，不应报多源错误。
      for (final metric in dualInputMetricTypes) {
        final graph = IspGraph();
        final ref = graph.addNode('image_source', 0, 0);
        final test = graph.addNode('image_source', 0, 0);
        final sink = graph.addNode(metric, 0, 0);
        expect(graph.connect(ref, 'out_rgb', sink, 'in'), isNull);
        expect(graph.connect(test, 'out_rgb', sink, 'in_test'), isNull);
        final chain = compileChain(graph, sink);
        expect(chain.last['typeId'], metric);
        expect(
            chain.where((op) => op['typeId'] == 'image_source').length, 2);
      }
    });

    test('双输入评价仪器超过两个源节点仍报错', () {
      // 混叠器双源 + 评价仪器测试路 = 3 个源，超出双源上限。
      final graph = IspGraph();
      final sink = graph.addNode('psnr', 0, 0);
      final blender = graph.addNode('blender', 0, 0);
      final src1 = graph.addNode('image_source', 0, 0);
      final src2 = graph.addNode('image_source', 0, 0);
      final src3 = graph.addNode('image_source', 0, 0);
      expect(graph.connect(src1, 'out_rgb', blender, 'in'), isNull);
      expect(graph.connect(src2, 'out_rgb', blender, 'in_blend'), isNull);
      expect(graph.connect(blender, 'out_rgb', sink, 'in'), isNull);
      expect(graph.connect(src3, 'out_rgb', sink, 'in_test'), isNull);
      expect(() => compileChain(graph, sink), throwsStateError);
    });
  });

  group('sourceFrameCount / runChainFrame', () {
    test('counts frames of a temp raw file and processes a frame', () async {
      // 造一个 4x4、8bit、RGGB 的两帧 RAW 临时文件。
      const w = 4, h = 4;
      final frameBytes =
          frameByteSize(width: w, height: h, bitDepth: 8, packing: BayerPacking.unpackedLsb);
      expect(frameBytes, w * h * 2);
      final bytes = List<int>.generate(frameBytes * 2, (i) => (i * 7) % 256);
      final tmp = File(
          '${Directory.systemTemp.path}/isp_runner_test_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(bytes);
      try {
        final params = <String, Object?>{
          'filePath': tmp.path,
          'width': w,
          'height': h,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
          'bayerPattern': 'RGGB',
          'littleEndian': true,
          'frameIndex': 0,
        };
        expect(await sourceFrameCount('bayer_source', params), 2);

        final chain = <Map<String, Object?>>[
          {'typeId': 'bayer_source', 'params': params},
          {
            'typeId': 'demosaic',
            'params': {'algorithm': 'bilinear'}
          },
        ];
        final rgba = await runChainFrame(chain, 1); // 第二帧
        expect(rgba.length, w * h * 4);
        expect(rgba[3], 255); // alpha
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('ahe 经 in_mono 侧支路（分路器 Y 通道）不阻塞主链', () async {
      // 复现 Bayer2RGB 流程的故障拓扑：
      // …→yuv_splitter→ahe(in_mono)→histogram(in_mono)，且
      // ahe.out_mono→yuv_combiner.in_y→…→preview。旧实现 ahe 只认主链帧
      // （此时为 YUV）直接抛错，且不登记 out_mono 使合路器 Y 全零。
      const w = 8, h = 8;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_ahe_mono_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        List<Map<String, Object?>> baseOps() => [
              {
                'typeId': 'bayer_source',
                'nodeId': 'src',
                'params': {
                  'filePath': tmp.path,
                  'width': w,
                  'height': h,
                  'bitDepth': '8',
                  'packing': 'unpacked_lsb',
                  'bayerPattern': 'RGGB',
                  'littleEndian': true,
                  'frameIndex': 0,
                },
              },
              {
                'typeId': 'demosaic',
                'nodeId': 'dm',
                'params': {'algorithm': 'bilinear'},
              },
              {'typeId': 'csc_rgb2yuv', 'nodeId': 'yuv', 'params': {}},
              {'typeId': 'yuv_splitter', 'nodeId': 'split', 'params': {}},
            ];
        Map<String, Object?> aheOp() => {
              'typeId': 'ahe',
              'nodeId': 'ahe',
              'params': {'blockSize': 8, 'clipLimit': 2.0, 'strength': 1.0},
              'inputs': {
                'in_mono': {'fromNodeId': 'split', 'fromPort': 'out_y'},
              },
            };

        // 链 A：ahe.out_mono → histogram.in_mono（直方图#2 场景）。
        final chainToHist = [
          ...baseOps(),
          aheOp(),
          {
            'typeId': 'histogram',
            'nodeId': 'hist',
            'params': <String, Object?>{},
            'inputs': {
              'in_mono': {'fromNodeId': 'ahe', 'fromPort': 'out_mono'},
            },
          },
        ];
        final sinkFormats = <String>[];
        final rgbaA = await runChainFrame(chainToHist, 0,
            onNodeOutput: (nodeId, data, format, width, height) {
          if (nodeId == 'hist') sinkFormats.add('$format:${data.length}');
        });
        expect(rgbaA.length, w * h * 4);
        // 汇点先收到单通道 mono 帧（ahe 处理结果），最后收到 RGBA。
        expect(sinkFormats, contains('mono:${w * h}'));
        expect(sinkFormats.last, 'rgba:${w * h * 4}');

        // 链 B：ahe.out_mono → yuv_combiner.in_y（预览#2 场景），
        // U/V 仍由分路器直供；合路器必须拿到非零 Y。
        final chainToPreview = [
          ...baseOps(),
          aheOp(),
          {
            'typeId': 'yuv_combiner',
            'nodeId': 'comb',
            'params': <String, Object?>{},
            'inputs': {
              'in_y': {'fromNodeId': 'ahe', 'fromPort': 'out_mono'},
              'in_u': {'fromNodeId': 'split', 'fromPort': 'out_u'},
              'in_v': {'fromNodeId': 'split', 'fromPort': 'out_v'},
            },
          },
          {'typeId': 'preview', 'nodeId': 'pv', 'params': <String, Object?>{}},
        ];
        List<int>? combOut;
        final rgbaB = await runChainFrame(chainToPreview, 0,
            onNodeOutput: (nodeId, data, format, width, height) {
          if (nodeId == 'comb') combOut = List<int>.of(data);
        });
        expect(rgbaB.length, w * h * 4);
        expect(combOut, isNotNull);
        var ySum = 0;
        for (var i = 0; i < w * h; i++) {
          ySum += combOut![i * 3];
        }
        expect(ySum, greaterThan(0), reason: '合路器 Y 通道应来自 ahe 输出');
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('morphology 经 in_mono 侧支路（边缘提取 out_mono）处理生效', () async {
      // 回归：旧实现 in_mono 单接时，处理结果只登记 portOutputs['out_mono']，
      // 循环末公用登记段（frame.format=='mono' → opOuts['out_mono']=
      // frame.data）用未处理的主帧数据将其覆盖，节点表现为完全无效。
      const w = 8, h = 8;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_morph_mono_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => (i * 37) % 256)));
      try {
        List<Map<String, Object?>> chain(Map<String, Object?> morphParams) => [
              {
                'typeId': 'bayer_source',
                'nodeId': 'src',
                'params': {
                  'filePath': tmp.path,
                  'width': w,
                  'height': h,
                  'bitDepth': '8',
                  'packing': 'unpacked_lsb',
                  'bayerPattern': 'RGGB',
                  'littleEndian': true,
                  'frameIndex': 0,
                },
              },
              {
                'typeId': 'demosaic',
                'nodeId': 'dm',
                'params': {'algorithm': 'bilinear'},
              },
              {
                'typeId': 'edge_extract',
                'nodeId': 'edge',
                'params': {'gain': 4.0, 'threshold': 0.0},
              },
              {
                'typeId': 'morphology',
                'nodeId': 'morph',
                'params': morphParams,
                'inputs': {
                  'in_mono': {'fromNodeId': 'edge', 'fromPort': 'out_mono'},
                },
              },
              {
                'typeId': 'preview',
                'nodeId': 'pv',
                'params': <String, Object?>{},
                'inputs': {
                  'in_mono': {'fromNodeId': 'morph', 'fromPort': 'out_mono'},
                },
              },
            ];

        int nonzero(Uint8List rgba) {
          var n = 0;
          for (var i = 0; i < rgba.length; i += 4) {
            if (rgba[i] != 0) n++;
          }
          return n;
        }

        final dilate =
            await runChainFrame(chain({'mode': 'dilate', 'radius': 1}), 0);
        final erode =
            await runChainFrame(chain({'mode': 'erode', 'radius': 1}), 0);
        final bypass = await runChainFrame(
            chain({'bypass': true, 'mode': 'dilate', 'radius': 1}), 0);

        expect(dilate, isNot(equals(bypass)), reason: '膨胀结果应与直通不同');
        expect(erode, isNot(equals(bypass)), reason: '腐蚀结果应与直通不同');
        expect(nonzero(dilate), greaterThan(nonzero(erode)),
            reason: '膨胀的非零像素应多于腐蚀');
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('nodeTimingsUs 记录各节点执行耗时', () async {
      // 4x4、8bit、RGGB 单帧。
      const w = 4, h = 4;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_timing_test_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        final chain = <Map<String, Object?>>[
          {
            'typeId': 'bayer_source',
            'nodeId': 'src',
            'params': {
              'filePath': tmp.path,
              'width': w,
              'height': h,
              'bitDepth': '8',
              'packing': 'unpacked_lsb',
              'bayerPattern': 'RGGB',
              'littleEndian': true,
              'frameIndex': 0,
            }
          },
          {
            'typeId': 'demosaic',
            'nodeId': 'dm',
            'params': {'algorithm': 'bilinear'}
          },
          {'typeId': 'preview', 'nodeId': 'pv', 'params': <String, Object?>{}},
        ];
        final timings = <String, int>{};
        final rgba = await runChainFrame(chain, 0, nodeTimingsUs: timings);
        expect(rgba.length, w * h * 4);
        // 源（解码）、算子、汇点（含链末默认色调映射）都有计时。
        expect(timings.keys, containsAll(['src', 'dm', 'pv']));
        for (final us in timings.values) {
          expect(us, greaterThanOrEqualTo(0));
        }
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('runChainFrameWithProgress 按节点顺序回报进度', () async {
      // 4x4、8bit、RGGB 单帧。
      const w = 4, h = 4;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_progress_test_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        final chain = <Map<String, Object?>>[
          {
            'typeId': 'bayer_source',
            'nodeId': 'src',
            'params': {
              'filePath': tmp.path,
              'width': w,
              'height': h,
              'bitDepth': '8',
              'packing': 'unpacked_lsb',
              'bayerPattern': 'RGGB',
              'littleEndian': true,
              'frameIndex': 0,
            }
          },
          {
            'typeId': 'demosaic',
            'nodeId': 'dm',
            'params': {'algorithm': 'bilinear'}
          },
          {'typeId': 'preview', 'nodeId': 'pv', 'params': <String, Object?>{}},
        ];
        final starts = <(String, int, int)>[];
        final result = await runChainFrameWithProgress(chain, 0,
            onNodeStart: (nodeId, index, total) {
          starts.add((nodeId, index, total));
        });
        // 节点按链序依次回报，序号 0..n-1，总数为链长。
        expect(starts.map((s) => s.$1), ['src', 'dm', 'pv']);
        expect(starts.map((s) => s.$2), [0, 1, 2]);
        expect(starts.map((s) => s.$3), [3, 3, 3]);
        // 返回结构与 runChainFrameCapturedInIsolate 同构。
        expect((result['rgba'] as Uint8List).length, w * h * 4);
        expect(
            (result['timings'] as Map).keys, containsAll(['src', 'dm', 'pv']));
        expect(
            (result['captures'] as Map).keys, containsAll(['src', 'dm', 'pv']));
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('sourceFrameCount rejects missing file', () async {
      expect(
        () => sourceFrameCount('bayer_source', {
          'filePath': 'nonexistent_file.xyz',
          'width': 4,
          'height': 4,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
        }),
        throwsStateError,
      );
    });

    test('runChainFrame rejects frame beyond file', () async {
      const w = 4, h = 4;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_runner_test2_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(List<int>.filled(w * h * 2, 128)); // 仅 1 帧
      try {
        final chain = <Map<String, Object?>>[
          {
            'typeId': 'bayer_source',
            'params': {
              'filePath': tmp.path,
              'width': w,
              'height': h,
              'bitDepth': '8',
              'packing': 'unpacked_lsb',
              'bayerPattern': 'RGGB',
              'littleEndian': true,
              'frameIndex': 0,
            }
          },
        ];
        expect(() => runChainFrame(chain, 1), throwsStateError);
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('onNodeOutput / captured isolate 采样各节点输出', () async {
      // 4x4、8bit、RGGB 单帧，像素值 0..15。
      const w = 4, h = 4;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_capture_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        final params = <String, Object?>{
          'filePath': tmp.path,
          'width': w,
          'height': h,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
          'bayerPattern': 'RGGB',
          'littleEndian': true,
          'frameIndex': 0,
        };
        final chain = <Map<String, Object?>>[
          {'typeId': 'bayer_source', 'params': params, 'nodeId': 'n1'},
          {
            'typeId': 'demosaic',
            'params': {'algorithm': 'bilinear'},
            'nodeId': 'n2',
          },
        ];

        // 直接回调：源节点输出为马赛克原值；去马赛克后先出 RGB，
        // 链末端再补一次最终 RGBA 回调。
        final seen = <String, List<(List<int>, String, int, int)>>{};
        await runChainFrame(chain, 0,
            onNodeOutput: (id, data, format, w, h) =>
                seen.putIfAbsent(id, () => []).add((data, format, w, h)));
        expect(seen['n1']!.single.$2, 'mosaic');
        expect(seen['n1']!.single.$1, List<int>.generate(w * h, (i) => i));
        expect((seen['n1']!.single.$3, seen['n1']!.single.$4), (w, h));
        expect(seen['n2']!.map((e) => e.$2), ['rgb', 'rgba']);
        expect(seen['n2']!.first.$1, hasLength(w * h * 3));
        expect(seen['n2']!.last.$1, hasLength(w * h * 4));

        // isolate 入口：返回 RGBA + 各节点采样，汇点恒为 rgba。
        final result = await runChainFrameCapturedInIsolate(
            {'chain': chain, 'frameIndex': 0});
        expect((result['rgba'] as Uint8List).length, w * h * 4);
        final caps =
            (result['captures'] as Map).cast<String, Map<String, Object?>>();
        expect(caps['n1']!['format'], 'mosaic');
        expect(caps['n1']!['length'], w * h);
        expect((caps['n1']!['width'], caps['n1']!['height']), (w, h));
        expect(caps['n1']!['sample'], List<int>.generate(w * h, (i) => i));
        expect(caps['n2']!['format'], 'rgba');
        expect(caps['n2']!['length'], w * h * 4);
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('runChainValueAtInIsolate 按 (x, y, channel) 取节点输出值', () async {
      // 4x4、8bit、RGGB 单帧，像素值 0..15。
      const w = 4, h = 4;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_value_at_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        final params = <String, Object?>{
          'filePath': tmp.path,
          'width': w,
          'height': h,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
          'bayerPattern': 'RGGB',
          'littleEndian': true,
          'frameIndex': 0,
        };
        final chain = <Map<String, Object?>>[
          {'typeId': 'bayer_source', 'params': params, 'nodeId': 'n1'},
          {
            'typeId': 'demosaic',
            'params': {'algorithm': 'bilinear'},
            'nodeId': 'n2',
          },
        ];

        // 马赛克源（链截断到 n1）：链末端对 mosaic 按 RAW 直显规则出
        // RGBA 灰度（monoToRgba，gamma 2.2），(x=2, y=1) → 一维下标 6。
        final mosaic = await runChainValueAtInIsolate(
            {'chain': [chain.first], 'frameIndex': 0, 'x': 2, 'y': 1, 'channel': 0});
        final gray = monoToRgba(
            Uint16List.fromList(List<int>.generate(w * h, (i) => i)),
            maxValue: 255, gamma: 2.2);
        expect(mosaic, gray[6 * 4]);

        // 链末端节点输出恒为 RGBA，A 通道恒为 255。
        final alpha = await runChainValueAtInIsolate(
            {'chain': chain, 'frameIndex': 0, 'x': 3, 'y': 2, 'channel': 3});
        expect(alpha, 255);

        // 坐标越界 → RangeError；通道越界（末端 RGBA 只有 4 通道）→ StateError。
        expect(
            () => runChainValueAtInIsolate(
                {'chain': chain, 'frameIndex': 0, 'x': 4, 'y': 0, 'channel': 0}),
            throwsRangeError);
        expect(
            () => runChainValueAtInIsolate(
                {'chain': [chain.first], 'frameIndex': 0, 'x': 0, 'y': 0, 'channel': 4}),
            throwsStateError);
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('preview in_raw：RAW 马赛克直显（像素值=亮度灰度图）', () async {
      // 4x4、8bit、RGGB 单帧，像素 0..15（unpacked 固定 2 字节/像素）。
      const w = 4, h = 4;
      final bytes = raw8Le(List<int>.generate(w * h, (i) => i));
      final tmp = File(
          '${Directory.systemTemp.path}/isp_rawview_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(bytes);
      try {
        // bayer_source.out → preview.in_raw：不去马赛克，链末端对 mosaic
        // 格式按像素值=亮度出灰度图（默认 gamma 2.2）。
        final chain = <Map<String, Object?>>[
          {
            'typeId': 'bayer_source',
            'nodeId': 'src',
            'params': {
              'filePath': tmp.path,
              'width': w,
              'height': h,
              'bitDepth': '8',
              'packing': 'unpacked_lsb',
              'bayerPattern': 'RGGB',
              'littleEndian': true,
              'frameIndex': 0,
            }
          },
          {
            'typeId': 'preview',
            'nodeId': 'pv',
            'params': <String, Object?>{},
            'inputs': {
              'in_raw': {'fromNodeId': 'src', 'fromPort': 'out'},
            },
          },
        ];
        final rgba = await runChainFrame(chain, 0);
        expect(rgba.length, w * h * 4);
        // 灰度：每像素 R==G==B。
        for (var p = 0; p < w * h; p++) {
          expect(rgba[p * 4], rgba[p * 4 + 1], reason: 'pixel $p G');
          expect(rgba[p * 4 + 1], rgba[p * 4 + 2], reason: 'pixel $p B');
        }
        // 与 monoToRgba(unpackBayer(...)) 的输出逐字节相等。
        final mosaic = unpackBayer(Uint8List.fromList(bytes),
            width: w,
            height: h,
            bitDepth: 8,
            packing: BayerPacking.unpackedLsb);
        expect(rgba, monoToRgba(mosaic, maxValue: 255, gamma: 2.2));
      } finally {
        await deleteQuietly(tmp);
      }
    });
  });

  group('新源节点', () {
    /// 建 image_source → preview 图，返回 (graph, srcId, previewId)。
    (IspGraph, String, String) imageGraph(String path) {
      final graph = IspGraph();
      final src = graph.addNode('image_source', 0, 0);
      graph.nodes[src]!.paramValues['filePath'] = path;
      final prev = graph.addNode('preview', 200, 0);
      return (graph, src, prev);
    }

    test('image_source 解码 PNG 并经 RGB 输出', () async {
      final im = img.Image(width: 4, height: 2, numChannels: 3);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 4; x++) {
          im.setPixelRgb(x, y, 200, 100, 50);
        }
      }
      final tmp = File(
          '${Directory.systemTemp.path}/isp_image_src_${DateTime.now().microsecondsSinceEpoch}.png');
      await tmp.writeAsBytes(img.encodePng(im));
      try {
        final (graph, src, prev) = imageGraph(tmp.path);
        expect(graph.connect(src, 'out_rgb', prev, 'in'), isNull);
        final chain = compileChain(graph, prev);
        expect(chain.first['outFormat'], 'rgb');
        expect(await sourceFrameCount('image_source',
            chain.first['params'] as Map<String, Object?>), 1);
        expect(
            await sourceDimensions('image_source',
                chain.first['params'] as Map<String, Object?>),
            (4, 2));
        final rgba = await runChainFrame(chain, 0);
        expect(rgba.length, 4 * 2 * 4);
        // 图片源已是 sRGB 显示数据：gamma 1.0 直通，像素值原样输出。
        expect(rgba[0], 200);
        expect(rgba[1], 100);
        expect(rgba[2], 50);
        expect(rgba[3], 255);
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('image_source YUV/HSL 输出端口决定链格式', () async {
      final im = img.Image(width: 2, height: 2, numChannels: 3);
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          im.setPixelRgb(x, y, 128, 128, 128);
        }
      }
      final tmp = File(
          '${Directory.systemTemp.path}/isp_image_yuv_${DateTime.now().microsecondsSinceEpoch}.png');
      await tmp.writeAsBytes(img.encodePng(im));
      try {
        // YUV 输出 → YUV 输入；灰色经 YUV 往返仍应为灰。
        final (graph, src, prev) = imageGraph(tmp.path);
        expect(graph.connect(src, 'out_yuv', prev, 'in_yuv'), isNull);
        final chain = compileChain(graph, prev);
        expect(chain.first['outFormat'], 'yuv');
        final rgba = await runChainFrame(chain, 0);
        expect((rgba[0] - rgba[1]).abs(), lessThanOrEqualTo(2));
        expect((rgba[1] - rgba[2]).abs(), lessThanOrEqualTo(2));

        // HSL 同理。
        final (graph2, src2, prev2) = imageGraph(tmp.path);
        expect(graph2.connect(src2, 'out_hsl', prev2, 'in_hsl'), isNull);
        final chain2 = compileChain(graph2, prev2);
        expect(chain2.first['outFormat'], 'hsl');
        final rgba2 = await runChainFrame(chain2, 0);
        expect((rgba2[0] - rgba2[1]).abs(), lessThanOrEqualTo(2));

        // 端口类型不匹配：YUV 输出不能接 RGB 输入。
        final (graph3, src3, prev3) = imageGraph(tmp.path);
        expect(graph3.connect(src3, 'out_yuv', prev3, 'in'), '端口类型不匹配');
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('video_source 解析元信息并逐帧解码（gamma 1.0 直通）', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 16x16 纯红，2fps × 2s = 4 帧。
      final tmp = File(
          '${Directory.systemTemp.path}/isp_video_src_${DateTime.now().microsecondsSinceEpoch}.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=red:size=16x16:rate=2:duration=2',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final graph = IspGraph();
        final src = graph.addNode('video_source', 0, 0);
        graph.nodes[src]!.paramValues['filePath'] = tmp.path;
        final prev = graph.addNode('preview', 200, 0);
        expect(graph.connect(src, 'out_rgb', prev, 'in'), isNull);
        final chain = compileChain(graph, prev);
        expect(chain.first['outFormat'], 'rgb');
        expect(
            await sourceFrameCount('video_source',
                chain.first['params'] as Map<String, Object?>),
            4);
        expect(
            await sourceDimensions('video_source',
                chain.first['params'] as Map<String, Object?>),
            (16, 16));
        final rgba = await runChainFrame(chain, 0);
        expect(rgba.length, 16 * 16 * 4);
        // 纯红：gamma 1.0 直通，R 接近 255、G/B 接近 0（yuv420 有损，给容差）。
        expect(rgba[0], greaterThan(240));
        expect(rgba[1], lessThan(15));
        expect(rgba[2], lessThan(15));
        expect(rgba[3], 255);
        // 最后一帧可解；越界帧抛 StateError。
        expect(await runChainFrame(chain, 3), hasLength(16 * 16 * 4));
        await expectLater(runChainFrame(chain, 4), throwsStateError);

        // 注入预解码帧（流式播放路径）：跳过源解码直接出图。
        final injected = Uint8List(16 * 16 * 4);
        for (var j = 0; j < injected.length; j += 4) {
          injected[j + 1] = 200; // 纯绿 G=200
          injected[j + 3] = 255;
        }
        final rgba2 = await runChainFrame(chain, 0,
            sourceRgba: injected, sourceWidth: 16, sourceHeight: 16);
        expect(rgba2[0], lessThan(15));
        expect(rgba2[1], 200);
        expect(rgba2[2], lessThan(15));
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('VideoFrameStream 顺序解码到 EOF，重起后可再读', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 16x16 纯蓝，2fps × 2s = 4 帧。
      final tmp = File(
          '${Directory.systemTemp.path}/isp_video_stream_${DateTime.now().microsecondsSinceEpoch}.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=blue:size=16x16:rate=2:duration=2',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        // 从第 1 帧起：按序读 3 帧后 EOF 返回 null。
        final stream = await VideoFrameStream.start(tmp.path, 1);
        expect(stream.info.frameCount, 4);
        for (var k = 0; k < 3; k++) {
          final f = await stream.next();
          expect(f, isNotNull);
          expect(f, hasLength(16 * 16 * 4));
          expect(stream.nextIndex, 2 + k);
          // 纯蓝：B 接近 255，R/G 接近 0。
          expect(f![2], greaterThan(240));
          expect(f[0], lessThan(15));
          stream.recycle(f); // 归还缓冲池，供后续帧复用
        }
        expect(await stream.next(), isNull); // EOF
        await stream.dispose();

        // 回卷：从第 0 帧重起流，仍有帧可读。
        final stream2 = await VideoFrameStream.start(tmp.path, 0);
        expect(await stream2.next(), isNotNull);
        await stream2.dispose();
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('yuv444p 直出流 + sourceYuv 注入（YUV 链免 RGB 往返）', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 16x16 纯蓝，2fps × 2s = 4 帧。
      final tmp = File(
          '${Directory.systemTemp.path}/isp_video_yuv_${DateTime.now().microsecondsSinceEpoch}.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=blue:size=16x16:rate=2:duration=2',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final graph = IspGraph();
        final src = graph.addNode('video_source', 0, 0);
        graph.nodes[src]!.paramValues['filePath'] = tmp.path;
        final prev = graph.addNode('preview', 200, 0);
        expect(graph.connect(src, 'out_yuv', prev, 'in_yuv'), isNull);
        final chain = compileChain(graph, prev);
        expect(chain.first['outFormat'], 'yuv');

        // yuv444p 直出流：平面 Y/U/V，全范围。
        final stream =
            await VideoFrameStream.start(tmp.path, 0, pixelFormat: 'yuv444p');
        final yuv = await stream.next();
        expect(yuv, isNotNull);
        expect(yuv, hasLength(16 * 16 * 3));
        // 纯蓝（全范围 BT.601）：Y≈29、U≈255、V≈107（yuv420 有损，给容差）。
        expect(yuv![0], lessThan(60));
        expect(yuv[16 * 16], greaterThan(220));
        expect(yuv[16 * 16 * 2], inInclusiveRange(80, 135));
        stream.recycle(yuv);
        await stream.dispose();

        // 注入 yuv444p 帧走完整 YUV 链：预览输出回到纯蓝 RGBA。
        final rgba = await runChainFrame(chain, 0,
            sourceYuv: yuv, sourceWidth: 16, sourceHeight: 16);
        expect(rgba, hasLength(16 * 16 * 4));
        expect(rgba[2], greaterThan(240));
        expect(rgba[0], lessThan(15));
        expect(rgba[1], lessThan(15));
        expect(rgba[3], 255);
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('cis_mono 源以 16 位 mono 中间格式入链', () async {
      const w = 4, h = 2;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_mono_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(List<int>.filled(w * h * 2, 128));
      try {
        final graph = IspGraph();
        final src = graph.addNode('cis_mono', 0, 0);
        final p = graph.nodes[src]!.paramValues;
        p['filePath'] = tmp.path;
        p['width'] = w;
        p['height'] = h;
        p['bitDepth'] = '8';
        final prev = graph.addNode('preview', 200, 0);
        // mono 输出接 RGB 输入端口类型不匹配；走 in_mono。
        expect(graph.connect(src, 'out', prev, 'in'), '端口类型不匹配');
        expect(graph.connect(src, 'out', prev, 'in_mono'), isNull);
        final rgba = await runChainFrame(compileChain(graph, prev), 0);
        expect(rgba.length, w * h * 4);
        // 灰度：三通道相等；gamma 2.2 后大于 128。
        expect(rgba[0], rgba[1]);
        expect(rgba[1], rgba[2]);
        expect(rgba[0], greaterThan(128));
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('cis_rccc 源经 demosaic 输出', () async {
      const w = 4, h = 4;
      // R=60，C=180 → (60,60,60) 灰
      final bytes = <int>[];
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = (x & 1) == 0 && (y & 1) == 0 ? 60 : 180;
          bytes.add(v & 0xFF);
          bytes.add((v >> 8) & 0xFF);
        }
      }
      final tmp = File(
          '${Directory.systemTemp.path}/isp_rccc_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(bytes);
      try {
        final graph = IspGraph();
        final src = graph.addNode('cis_rccc', 0, 0);
        final p = graph.nodes[src]!.paramValues;
        p['filePath'] = tmp.path;
        p['width'] = w;
        p['height'] = h;
        p['bitDepth'] = '8';
        final dem = graph.addNode('demosaic', 200, 0);
        final prev = graph.addNode('preview', 400, 0);
        expect(graph.connect(src, 'out', dem, 'in'), isNull);
        expect(graph.connect(dem, 'out', prev, 'in'), isNull);
        final rgba = await runChainFrame(compileChain(graph, prev), 0);
        // RCCC 重建为灰色：三通道相等。
        expect((rgba[0] - rgba[1]).abs(), lessThanOrEqualTo(2));
        expect((rgba[1] - rgba[2]).abs(), lessThanOrEqualTo(2));
      } finally {
        await deleteQuietly(tmp);
      }
    });
  });

  group('ICG 荧光内窥镜链级用例', () {
    /// 造一个 8bit unpacked RAW 临时文件。
    Future<File> tempRaw(List<int> bytes, String tag) async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_icg_${tag}_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(bytes);
      return tmp;
    }

    void setRawParams(IspGraph graph, String nodeId, String path, int w, int h) {
      final p = graph.nodes[nodeId]!.paramValues;
      p['filePath'] = path;
      p['width'] = w;
      p['height'] = h;
      p['bitDepth'] = '8';
    }

    test('bayer 链挂新 RAW 域算子（dpc/fpn/lsc/grgb/bayer_dnr/highlight）',
        () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)), 'raw');
      try {
        final graph = IspGraph();
        var prev = graph.addNode('bayer_source', 0, 0);
        setRawParams(graph, prev, tmp.path, w, h);
        // 按典型流水线顺序串接全部新 RAW 域算子（默认参数）。
        for (final type in [
          'black_level',
          'dpc',
          'fpn',
          'lsc',
          'grgb_balance',
          'bayer_dnr',
          'highlight',
          'demosaic',
          'preview',
        ]) {
          final id = graph.addNode(type, 0, 0);
          expect(graph.connect(prev, 'out', id, 'in'), isNull, reason: type);
          prev = id;
        }
        final rgba = await runChainFrame(compileChain(graph, prev), 0);
        expect(rgba.length, w * h * 4);
        for (var i = 3; i < rgba.length; i += 4) {
          expect(rgba[i], 255); // alpha
        }
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('cis_mono→fluoro_leak→fluoro_temporal→preview mono 链端到端',
        () async {
      const w = 8, h = 8;
      // 两帧，验证时域 IIR 的历史帧累积路径（frame 0 直通、frame 1 混合）。
      final tmp =
          await tempRaw(List<int>.filled(w * h * 4, 100), 'mono_chain');
      try {
        final graph = IspGraph();
        final src = graph.addNode('cis_mono', 0, 0);
        setRawParams(graph, src, tmp.path, w, h);
        final leak = graph.addNode('fluoro_leak', 0, 0);
        graph.nodes[leak]!.paramValues['level'] = 20.0;
        final temporal = graph.addNode('fluoro_temporal', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(src, 'out', leak, 'in_mono'), isNull);
        expect(graph.connect(leak, 'out_mono', temporal, 'in_mono'), isNull);
        expect(graph.connect(temporal, 'out_mono', prev, 'in_mono'), isNull);
        final chain = compileChain(graph, prev);
        for (final frameIndex in [0, 1]) {
          final rgba = await runChainFrame(chain, frameIndex);
          expect(rgba.length, w * h * 4);
          // 灰度出图：三通道相等；100 − 20 = 80，gamma 2.2 后明显提亮。
          expect(rgba[0], rgba[1]);
          expect(rgba[1], rgba[2]);
          expect(rgba[0], greaterThan(100));
        }
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('双源 fluoro_fusion 链（白光 bayer + 荧光 mono）端到端', () async {
      const w = 8, h = 8;
      final wlTmp =
          await tempRaw(List<int>.filled(w * h * 2, 100), 'fusion_wl');
      final flTmp =
          await tempRaw(List<int>.filled(w * h * 2, 255), 'fusion_fl');
      try {
        final graph = IspGraph();
        final wl = graph.addNode('bayer_source', 0, 0);
        setRawParams(graph, wl, wlTmp.path, w, h);
        final dem = graph.addNode('demosaic', 0, 0);
        final fl = graph.addNode('cis_mono', 0, 0);
        setRawParams(graph, fl, flTmp.path, w, h);
        final leak = graph.addNode('fluoro_leak', 0, 0);
        final fusion = graph.addNode('fluoro_fusion', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(wl, 'out', dem, 'in'), isNull);
        expect(graph.connect(dem, 'out', fusion, 'in'), isNull);
        expect(graph.connect(fl, 'out', leak, 'in_mono'), isNull);
        expect(graph.connect(leak, 'out_mono', fusion, 'in_fluoro'), isNull);
        expect(graph.connect(fusion, 'out', prev, 'in'), isNull);
        // 含 fluoro_fusion 的链允许 2 个源节点。
        final chain = compileChain(graph, prev);
        expect(
            chain.where((op) => sourceTypes.contains(op['typeId'])).length, 2);
        final rgba = await runChainFrame(chain, 0);
        expect(rgba.length, w * h * 4);
        // 荧光满幅 → α 映射后绿色通道显著高于 R/B（绿色伪彩融合）。
        expect(rgba[1], greaterThan(rgba[0]));
        expect(rgba[1], greaterThan(rgba[2]));

        // 对照：不含 fluoro_fusion 的双源链仍被拒绝（两个 mono 源经
        // 合路器汇入同一汇点）。
        final graph2 = IspGraph();
        final src1 = graph2.addNode('cis_mono', 0, 0);
        final src2 = graph2.addNode('cis_mono', 0, 0);
        final combiner = graph2.addNode('rgb_combiner', 0, 0);
        final prev2 = graph2.addNode('preview', 0, 0);
        expect(graph2.connect(src1, 'out', combiner, 'in_r'), isNull);
        expect(graph2.connect(src2, 'out', combiner, 'in_g'), isNull);
        expect(graph2.connect(combiner, 'out', prev2, 'in'), isNull);
        expect(() => compileChain(graph2, prev2), throwsStateError);
      } finally {
        await deleteQuietly(wlTmp);
        await deleteQuietly(flTmp);
      }
    });

    test('双源 multiplier 链（mono × mono）端到端，分辨率不一致报错',
        () async {
      const w = 8, h = 8;
      final t1 = await tempRaw(raw8Le(List<int>.filled(w * h, 200)), 'mul_a');
      final t2 = await tempRaw(raw8Le(List<int>.filled(w * h, 128)), 'mul_b');
      final tSmall =
          await tempRaw(raw8Le(List<int>.filled(w * h ~/ 2, 128)), 'mul_s');
      try {
        final graph = IspGraph();
        final s1 = graph.addNode('cis_mono', 0, 0);
        setRawParams(graph, s1, t1.path, w, h);
        final s2 = graph.addNode('cis_mono', 0, 0);
        setRawParams(graph, s2, t2.path, w, h);
        final mul = graph.addNode('multiplier', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(s1, 'out', mul, 'in_mono'), isNull);
        expect(graph.connect(s2, 'out', mul, 'in_mono2'), isNull);
        expect(graph.connect(mul, 'out_mono', prev, 'in_mono'), isNull);
        // 含 multiplier 的链允许 2 个源节点。
        final chain = compileChain(graph, prev);
        expect(
            chain.where((op) => sourceTypes.contains(op['typeId'])).length, 2);
        final rgba = await runChainFrame(chain, 0);
        expect(rgba.length, w * h * 4);
        // 亮度灰度出图：三通道相等；200×128/255 ≈ 100，gamma 2.2 后提亮。
        expect(rgba[0], rgba[1]);
        expect(rgba[1], rgba[2]);
        expect(rgba[0], greaterThan(100));

        // 输入源2 未接入：执行时报错。
        graph.disconnectInput(mul, 'in_mono2');
        final chainUnconnected = compileChain(graph, prev);
        await expectLater(
            runChainFrame(chainUnconnected, 0), throwsStateError);

        // 分辨率不一致（源2 换成 8×4）：执行时报错。
        expect(graph.connect(s2, 'out', mul, 'in_mono2'), isNull);
        setRawParams(graph, s2, tSmall.path, w, h ~/ 2);
        final chainMismatch = compileChain(graph, prev);
        await expectLater(
            runChainFrame(chainMismatch, 0), throwsStateError);
      } finally {
        await deleteQuietly(t1);
        await deleteQuietly(t2);
        await deleteQuietly(tSmall);
      }
    });

    test('edge_extract 的 out_mono 单通道输出接预览：按亮度灰度出图',
        () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)),
          'edge_mono');
      try {
        final graph = IspGraph();
        final src = graph.addNode('bayer_source', 0, 0);
        setRawParams(graph, src, tmp.path, w, h);
        final dem = graph.addNode('demosaic', 0, 0);
        final edge = graph.addNode('edge_extract', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(src, 'out', dem, 'in'), isNull);
        expect(graph.connect(dem, 'out', edge, 'in'), isNull);
        expect(graph.connect(edge, 'out_mono', prev, 'in_mono'), isNull);
        final rgba = await runChainFrame(compileChain(graph, prev), 0);
        expect(rgba.length, w * h * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          // 单通道亮度图：三通道相等。
          expect(rgba[i], rgba[i + 1]);
          expect(rgba[i + 1], rgba[i + 2]);
        }
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('cis_mono→bright_contrast_adjuster(in_mono)→preview mono 链端到端',
        () async {
      const w = 8, h = 8;
      final tmp =
          await tempRaw(raw8Le(List<int>.filled(w * h, 100)), 'bc_mono');
      try {
        final graph = IspGraph();
        final src = graph.addNode('cis_mono', 0, 0);
        setRawParams(graph, src, tmp.path, w, h);
        final bc = graph.addNode('bright_contrast_adjuster', 0, 0);
        graph.nodes[bc]!.paramValues['bright'] = 200.0; // 提亮一倍
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(src, 'out', bc, 'in_mono'), isNull);
        expect(graph.connect(bc, 'out_mono', prev, 'in_mono'), isNull);
        final rgba = await runChainFrame(compileChain(graph, prev), 0);
        expect(rgba.length, w * h * 4);
        // 灰度出图：三通道相等；100×2 = 200，gamma 2.2 后明显提亮。
        expect(rgba[0], rgba[1]);
        expect(rgba[1], rgba[2]);
        expect(rgba[0], greaterThan(150));
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('分路器单通道端口(out_y)接入 mono 算子：bright_contrast→multiplier',
        () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)),
          'bc_mul_branch');
      try {
        final graph = IspGraph();
        final src = graph.addNode('bayer_source', 0, 0);
        setRawParams(graph, src, tmp.path, w, h);
        final dem = graph.addNode('demosaic', 0, 0);
        final edge = graph.addNode('edge_extract', 0, 0);
        final csc = graph.addNode('csc_rgb2yuv', 0, 0);
        final split = graph.addNode('yuv_splitter', 0, 0);
        final bc = graph.addNode('bright_contrast_adjuster', 0, 0);
        graph.nodes[bc]!.paramValues['bright'] = 150.0;
        final mul = graph.addNode('multiplier', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(src, 'out', dem, 'in'), isNull);
        expect(graph.connect(dem, 'out', edge, 'in'), isNull);
        expect(graph.connect(dem, 'out', csc, 'in'), isNull);
        expect(graph.connect(csc, 'out', split, 'in'), isNull);
        // 单通道端口 out_y 接入 mono 输入：应构造 mono 帧而非拿 YUV 整帧。
        expect(graph.connect(split, 'out_y', bc, 'in_mono'), isNull);
        expect(graph.connect(edge, 'out_mono', mul, 'in_mono'), isNull);
        expect(graph.connect(bc, 'out_mono', mul, 'in_mono2'), isNull);
        expect(graph.connect(mul, 'out_mono', prev, 'in_mono'), isNull);
        final outs = <String, List<int>>{};
        final rgba = await runChainFrame(compileChain(graph, prev), 0,
            onNodeOutput: (nodeId, data, format, w0, h0) {
          outs[nodeId] = data;
        });
        expect(rgba.length, w * h * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          expect(rgba[i], rgba[i + 1]);
          expect(rgba[i + 1], rgba[i + 2]);
        }
        // 亮度/对比度输出必须是单通道 mono（w*h），乘法器才能取到。
        expect(outs[bc]!.length, w * h, reason: 'bright_contrast mono 输出');
        expect(outs[mul]!.length, w * h, reason: 'multiplier mono 输出');
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('multiplier 单源分支链：edge_extract.out_mono × 分路器 Y'
        '（经预览透传），主帧非 Mono 也能正确取数', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)),
          'mul_branch');
      try {
        final graph = IspGraph();
        final src = graph.addNode('bayer_source', 0, 0);
        setRawParams(graph, src, tmp.path, w, h);
        final dem = graph.addNode('demosaic', 0, 0);
        final edge = graph.addNode('edge_extract', 0, 0);
        final csc = graph.addNode('csc_rgb2yuv', 0, 0);
        final split = graph.addNode('yuv_splitter', 0, 0);
        final prevY = graph.addNode('preview', 0, 0);
        final mul = graph.addNode('multiplier', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(src, 'out', dem, 'in'), isNull);
        expect(graph.connect(dem, 'out', edge, 'in'), isNull);
        expect(graph.connect(dem, 'out', csc, 'in'), isNull);
        expect(graph.connect(csc, 'out', split, 'in'), isNull);
        expect(graph.connect(split, 'out_y', prevY, 'in_mono'), isNull);
        expect(graph.connect(edge, 'out_mono', mul, 'in_mono'), isNull);
        expect(graph.connect(prevY, 'out_mono', mul, 'in_mono2'), isNull);
        expect(graph.connect(mul, 'out_mono', prev, 'in_mono'), isNull);
        // 拓扑序下乘法器的线性主帧是分路器留下的 YUV 帧（非 Mono）：
        // 两路输入必须按端口取数，不能对主帧 requireMono。
        // 同时验证分支感知取帧：乘法器结果不得等于边缘图本身
        // （旧线性主帧会让分路器错拿边缘图，E×E/255 在 E∈{0,255} 时
        // 恰好还原边缘图）。
        final outs = <String, List<int>>{};
        final rgba = await runChainFrame(compileChain(graph, prev), 0,
            onNodeOutput: (nodeId, data, format, w0, h0) {
          outs[nodeId] = data;
        });
        expect(rgba.length, w * h * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          expect(rgba[i], rgba[i + 1]);
          expect(rgba[i + 1], rgba[i + 2]);
        }
        final edgeOut = outs[edge]!;
        final mulOut = outs[mul]!;
        var diffPx = 0;
        for (var i = 0; i < w * h; i++) {
          if (edgeOut[i * 3] != mulOut[i]) diffPx++;
        }
        expect(diffPx, greaterThan(0),
            reason: '调制结果不应与边缘图完全一致（E×Y/255 ≠ E）');
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('adder 单源分支链：balance=1/0 分别退化为源1/源2 直通', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)),
          'add_branch');
      try {
        IspGraph buildGraph() {
          final graph = IspGraph();
          final src = graph.addNode('bayer_source', 0, 0);
          setRawParams(graph, src, tmp.path, w, h);
          final dem = graph.addNode('demosaic', 0, 0);
          final edge = graph.addNode('edge_extract', 0, 0);
          final csc = graph.addNode('csc_rgb2yuv', 0, 0);
          final split = graph.addNode('yuv_splitter', 0, 0);
          final prevY = graph.addNode('preview', 0, 0);
          final add = graph.addNode('adder', 0, 0);
          final prev = graph.addNode('preview', 0, 0);
          expect(graph.connect(src, 'out', dem, 'in'), isNull);
          expect(graph.connect(dem, 'out', edge, 'in'), isNull);
          expect(graph.connect(dem, 'out', csc, 'in'), isNull);
          expect(graph.connect(csc, 'out', split, 'in'), isNull);
          expect(graph.connect(split, 'out_y', prevY, 'in_mono'), isNull);
          expect(graph.connect(edge, 'out_mono', add, 'in_mono'), isNull);
          expect(graph.connect(prevY, 'out_mono', add, 'in_mono2'), isNull);
          expect(graph.connect(add, 'out_mono', prev, 'in_mono'), isNull);
          return graph;
        }

        String idOf(IspGraph g, String typeId, {bool last = false}) {
          final matches =
              g.nodes.entries.where((e) => e.value.typeId == typeId);
          return (last ? matches.last : matches.first).key;
        }

        // balance=1：加法器输出 = 源1（边缘图）。
        final g1 = buildGraph();
        g1.nodes[idOf(g1, 'adder')]!.paramValues['balance'] = 1.0;
        final outs1 = <String, List<int>>{};
        await runChainFrame(
            compileChain(g1, idOf(g1, 'preview', last: true)), 0,
            onNodeOutput: (nodeId, data, format, w0, h0) {
          outs1[nodeId] = data;
        });
        final edgeId = idOf(g1, 'edge_extract');
        final addId1 = idOf(g1, 'adder');
        for (var i = 0; i < w * h; i++) {
          expect(outs1[addId1]![i], outs1[edgeId]![i * 3],
              reason: 'balance=1 应等于边缘图（源1）');
        }

        // balance=0：加法器输出 = 源2（分路器 Y，经预览透传）。
        final g0 = buildGraph();
        g0.nodes[idOf(g0, 'adder')]!.paramValues['balance'] = 0.0;
        final outs0 = <String, List<int>>{};
        await runChainFrame(
            compileChain(g0, idOf(g0, 'preview', last: true)), 0,
            onNodeOutput: (nodeId, data, format, w0, h0) {
          outs0[nodeId] = data;
        });
        final prevYId = g0.nodes.entries
            .where((e) => e.value.typeId == 'preview')
            .first
            .key;
        final addId0 = idOf(g0, 'adder');
        for (var i = 0; i < w * h; i++) {
          expect(outs0[addId0]![i], outs0[prevYId]![i],
              reason: 'balance=0 应等于分路器 Y（源2）');
        }
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('blender 单源分支链：基图 + 混叠图×蒙版×强度（正常模式）', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)),
          'blend_branch');
      try {
        // 图：src→dm→csc→split→prevY（混叠图=Y 支路）；dm→edge（蒙版=
        // 边缘图支路）；基图 = dem 输出 RGB（split 的 out 主帧别名）。
        final graph = IspGraph();
        final src = graph.addNode('bayer_source', 0, 0);
        setRawParams(graph, src, tmp.path, w, h);
        final dem = graph.addNode('demosaic', 0, 0);
        final edge = graph.addNode('edge_extract', 0, 0);
        final csc = graph.addNode('csc_rgb2yuv', 0, 0);
        final split = graph.addNode('yuv_splitter', 0, 0);
        final prevY = graph.addNode('preview', 0, 0);
        final mix = graph.addNode('blender', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(src, 'out', dem, 'in'), isNull);
        expect(graph.connect(dem, 'out', edge, 'in'), isNull);
        expect(graph.connect(dem, 'out', csc, 'in'), isNull);
        expect(graph.connect(csc, 'out', split, 'in'), isNull);
        expect(graph.connect(split, 'out_y', prevY, 'in_mono'), isNull);
        expect(graph.connect(csc, 'out', mix, 'in_yuv'), isNull);
        expect(graph.connect(edge, 'out_mono', mix, 'in_mask'), isNull);
        expect(graph.connect(prevY, 'out_mono', mix, 'in_blend_mono'), isNull);
        expect(graph.connect(mix, 'out_yuv', prev, 'in_yuv'), isNull);

        graph.nodes[mix]!.paramValues['strength'] = 1.0;
        final outs = <String, List<int>>{};
        await runChainFrame(compileChain(graph, prev), 0,
            onNodeOutput: (nodeId, data, format, w0, h0) {
          outs[nodeId] = data;
        });
        final baseOut = outs[csc]!; // 基图（YUV 交织帧）
        final maskOut = outs[edge]!; // 蒙版（out_mono，基图 0 通道同值）
        final blendOut = outs[prevY]!; // 混叠图（mono Y）
        final mixOut = outs[mix]!;
        const maxV = 255;
        for (var i = 0; i < w * h; i++) {
          final delta = (maskOut[i * 3] * blendOut[i] / maxV).round();
          // YUV 基图：增量只加 Y 通道，U/V 必须与基图一致。
          expect(mixOut[i * 3],
              (baseOut[i * 3] + delta).clamp(0, maxV),
              reason: '像素 $i Y：基图+混叠图×蒙版/maxV');
          expect(mixOut[i * 3 + 1], baseOut[i * 3 + 1],
              reason: '像素 $i U 不应被混叠修改');
          expect(mixOut[i * 3 + 2], baseOut[i * 3 + 2],
              reason: '像素 $i V 不应被混叠修改');
        }
        // 有实际混叠效果（不是纯基图直通）。
        var changed = 0;
        for (var i = 0; i < w * h * 3; i++) {
          if (mixOut[i] != baseOut[i]) changed++;
        }
        expect(changed, greaterThan(0));

        // 缺蒙版/混叠图：链执行抛 StateError。
        final graph2 = IspGraph();
        final src2 = graph2.addNode('bayer_source', 0, 0);
        setRawParams(graph2, src2, tmp.path, w, h);
        final dem2 = graph2.addNode('demosaic', 0, 0);
        final mix2 = graph2.addNode('blender', 0, 0);
        final prev2 = graph2.addNode('preview', 0, 0);
        expect(graph2.connect(src2, 'out', dem2, 'in'), isNull);
        expect(graph2.connect(dem2, 'out', mix2, 'in'), isNull);
        expect(graph2.connect(mix2, 'out_rgb', prev2, 'in'), isNull);
        await expectLater(runChainFrame(compileChain(graph2, prev2), 0),
            throwsStateError);
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('mux4 多路选择器：输出透传 select 选中的那路输入', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)),
          'mux4_sel');
      try {
        // 源1 = dem 输出 RGB（接 in1），源2 = 分路器 Y（接 in2_mono，
        // 单通道端口），select 切换验证透传语义。
        IspGraph buildGraph() {
          final graph = IspGraph();
          final src = graph.addNode('bayer_source', 0, 0);
          setRawParams(graph, src, tmp.path, w, h);
          final dem = graph.addNode('demosaic', 0, 0);
          final csc = graph.addNode('csc_rgb2yuv', 0, 0);
          final split = graph.addNode('yuv_splitter', 0, 0);
          final mux = graph.addNode('mux4', 0, 0);
          expect(graph.connect(src, 'out', dem, 'in'), isNull);
          expect(graph.connect(dem, 'out', csc, 'in'), isNull);
          expect(graph.connect(csc, 'out', split, 'in'), isNull);
          expect(graph.connect(dem, 'out', mux, 'in1'), isNull);
          expect(graph.connect(split, 'out_y', mux, 'in2_mono'), isNull);
          return graph;
        }

        Future<(List<int>, List<int>)> runWith(int select) async {
          final graph = buildGraph();
          final muxId = graph.nodes.entries
              .firstWhere((e) => e.value.typeId == 'mux4')
              .key;
          graph.nodes[muxId]!.paramValues['select'] = select;
          final prevId = graph.addNode('preview', 0, 0);
          expect(graph.connect(muxId, 'out_rgb', prevId, 'in'), isNull);
          final outs = <String, List<int>>{};
          await runChainFrame(compileChain(graph, prevId), 0,
              onNodeOutput: (nodeId, data, format, w0, h0) {
            outs[nodeId] = data;
          });
          final demId = graph.nodes.entries
              .firstWhere((e) => e.value.typeId == 'demosaic')
              .key;
          return (outs[muxId]!, outs[demId]!);
        }

        // select=1：输出 = 源1（dem RGB 主帧），逐值一致（透传不改数据）。
        final (mux1, demOut) = await runWith(1);
        expect(mux1, demOut, reason: 'select=1 应透传源1');
        // select=2：输出 = 源2（分路器 Y 的 mono 帧，w*h 单通道）。
        final (mux2, _) = await runWith(2);
        expect(mux2.length, w * h, reason: 'select=2 应透传单通道源2');
        expect(mux2, isNot(demOut));

        // 未接入的源：选中支路为空，链缺少源节点直接不可编译。
        final graph3 = buildGraph();
        final muxId3 = graph3.nodes.entries
            .firstWhere((e) => e.value.typeId == 'mux4')
            .key;
        graph3.nodes[muxId3]!.paramValues['select'] = 3;
        final prev3 = graph3.addNode('preview', 0, 0);
        expect(graph3.connect(muxId3, 'out_rgb', prev3, 'in'), isNull);
        expect(() => compileChain(graph3, prev3), throwsStateError);
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('bright_contrast_adjuster 非 mono 输入时 out_mono 为亮度通道', () async {
      // 混叠器测试流程的拓扑：YUV → 亮度/对比度调节器，其 out_mono 应
      // 为调整后的 Y 通道（供混叠器蒙版等 mono 侧端口消费）；旧实现
      // 只在 mono 输入时登记 out_mono，YUV 输入时该端口为空。
      const w = 8, h = 8;
      final tmp = await tempRaw(
          raw8Le(List<int>.generate(w * h, (i) => 20 + (i * 3) % 200)),
          'bc_out_mono');
      try {
        final graph = IspGraph();
        final src = graph.addNode('bayer_source', 0, 0);
        setRawParams(graph, src, tmp.path, w, h);
        final dem = graph.addNode('demosaic', 0, 0);
        final csc = graph.addNode('csc_rgb2yuv', 0, 0);
        final bc = graph.addNode('bright_contrast_adjuster', 0, 0);
        final prev = graph.addNode('preview', 0, 0);
        expect(graph.connect(src, 'out', dem, 'in'), isNull);
        expect(graph.connect(dem, 'out', csc, 'in'), isNull);
        expect(graph.connect(csc, 'out', bc, 'in_yuv'), isNull);
        expect(graph.connect(bc, 'out_mono', prev, 'in_mono'), isNull);
        graph.nodes[bc]!.paramValues['bright'] = 150.0;

        String? sinkFormat;
        await runChainFrame(compileChain(graph, prev), 0,
            onNodeOutput: (nodeId, data, format, w0, h0) {
          if (nodeId == prev) sinkFormat ??= '$format:${data.length}';
        });
        expect(sinkFormat, 'mono:${w * h}',
            reason: '汇点应收到调节器的单通道 Y（out_mono）');
      } finally {
        await deleteQuietly(tmp);
      }
    });
  });
}
