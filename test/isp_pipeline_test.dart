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
  });

  group('sourceFrameCount / runChainFrame', () {
    test('counts frames of a temp raw file and processes a frame', () async {
      // 造一个 4x4、8bit、RGGB 的两帧 RAW 临时文件。
      const w = 4, h = 4;
      final frameBytes =
          frameByteSize(width: w, height: h, bitDepth: 8, packing: BayerPacking.unpackedLsb);
      expect(frameBytes, w * h);
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

    test('nodeTimingsUs 记录各节点执行耗时', () async {
      // 4x4、8bit、RGGB 单帧。
      const w = 4, h = 4;
      final tmp = File(
          '${Directory.systemTemp.path}/isp_timing_test_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(List<int>.generate(w * h, (i) => i));
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
      await tmp.writeAsBytes(List<int>.generate(w * h, (i) => i));
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
      await tmp.writeAsBytes(List<int>.filled(w * h, 128)); // 仅 1 帧
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
      await tmp.writeAsBytes(List<int>.generate(w * h, (i) => i));
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
      await tmp.writeAsBytes(List<int>.generate(w * h, (i) => i));
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

        // 马赛克源（链截断到 n1）：(x=2, y=1) → 一维下标 6。
        final mosaic = await runChainValueAtInIsolate(
            {'chain': [chain.first], 'frameIndex': 0, 'x': 2, 'y': 1, 'channel': 0});
        expect(mosaic, 6);

        // 链末端节点输出恒为 RGBA，A 通道恒为 255。
        final alpha = await runChainValueAtInIsolate(
            {'chain': chain, 'frameIndex': 0, 'x': 3, 'y': 2, 'channel': 3});
        expect(alpha, 255);

        // 坐标越界 → RangeError；通道越界（mosaic 只有 1 通道）→ StateError。
        expect(
            () => runChainValueAtInIsolate(
                {'chain': chain, 'frameIndex': 0, 'x': 4, 'y': 0, 'channel': 0}),
            throwsRangeError);
        expect(
            () => runChainValueAtInIsolate(
                {'chain': [chain.first], 'frameIndex': 0, 'x': 0, 'y': 0, 'channel': 1}),
            throwsStateError);
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
      await tmp.writeAsBytes(List<int>.filled(w * h, 128));
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
          bytes.add((x & 1) == 0 && (y & 1) == 0 ? 60 : 180);
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
          List<int>.generate(w * h, (i) => 20 + (i * 3) % 200), 'raw');
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
          await tempRaw(List<int>.filled(w * h * 2, 100), 'mono_chain');
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
          await tempRaw(List<int>.filled(w * h, 100), 'fusion_wl');
      final flTmp =
          await tempRaw(List<int>.filled(w * h, 255), 'fusion_fl');
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
  });
}
