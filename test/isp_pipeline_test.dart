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

    test('cis_mono 源直接输出灰度 RGB', () async {
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
        expect(graph.connect(src, 'out', prev, 'in'), isNull);
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
}
