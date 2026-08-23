// Bypass（直通）开关测试：Process 类节点注入 bypass 参数；勾选后 CPU
// 链与 GPU 链都输入直通输出。
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 8bit unpacked RAW：每像素一个 16 位小端字。
  List<int> raw8Le(Iterable<int> px) => [
        for (final v in px) ...[v & 0xFF, (v >> 8) & 0xFF],
      ];

  Future<File> tempRaw(int w, int h) async {
    final tmp = File(
        '${Directory.systemTemp.path}/isp_bypass_${DateTime.now().microsecondsSinceEpoch}.raw');
    await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i * 3 % 251)));
    return tmp;
  }

  Map<String, Object?> src(File tmp, int w, int h) => {
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
      };

  test('Process 类节点全部带 bypass 参数（首位，默认 false）', () {
    for (final id in IspNodeRegistry.processTypeIds) {
      final type = IspNodeRegistry.byId(id)!;
      final spec = type.params.firstWhere(
        (p) => p.key == 'bypass',
        orElse: () => throw StateError('$id 缺少 bypass 参数'),
      );
      expect(spec.type, IspParamType.boolean, reason: id);
      expect(spec.defaultValue, false, reason: id);
      expect(type.params.first.key, 'bypass', reason: '$id bypass 应在首位');
    }
    // 非 Process 类（源/分路/汇点/仪器）不注入。
    for (final id in [
      'bayer_source', 'cis_bayer_rggb', 'image_source', 'video_source',
      'rgb_splitter', 'yuv_combiner', 'preview', 'histogram', 'image_output',
    ]) {
      final type = IspNodeRegistry.byId(id)!;
      expect(type.params.any((p) => p.key == 'bypass'), isFalse,
          reason: '$id 不应有 bypass');
    }
  });

  test('CPU 链：bypass 节点与移除该节点结果一致', () async {
    const w = 8, h = 8;
    final tmp = await tempRaw(w, h);
    try {
      // 有 black_level（bypass: true）的链 vs 无 black_level 的链。
      final withBypass = await runChainFrame([
        src(tmp, w, h),
        {
          'typeId': 'black_level',
          'nodeId': 'bl',
          'params': {'r': 64.0, 'gr': 64.0, 'gb': 64.0, 'b': 64.0,
              'bypass': true},
        },
        {'typeId': 'demosaic', 'nodeId': 'dm', 'params': {}},
        {'typeId': 'preview', 'nodeId': 'pv', 'params': {}},
      ], 0);
      final without = await runChainFrame([
        src(tmp, w, h),
        {'typeId': 'demosaic', 'nodeId': 'dm', 'params': {}},
        {'typeId': 'preview', 'nodeId': 'pv', 'params': {}},
      ], 0);
      expect(withBypass, equals(without));

      //  sanity：未 bypass 时黑电平确实生效（结果不同）。
      final applied = await runChainFrame([
        src(tmp, w, h),
        {
          'typeId': 'black_level',
          'nodeId': 'bl',
          'params': {'r': 64.0, 'gr': 64.0, 'gb': 64.0, 'b': 64.0},
        },
        {'typeId': 'demosaic', 'nodeId': 'dm', 'params': {}},
        {'typeId': 'preview', 'nodeId': 'pv', 'params': {}},
      ], 0);
      expect(applied, isNot(equals(without)));
    } finally {
      await tmp.delete();
    }
  });

  test('CPU 链：ahe bypass 时 in_mono 直通 out_mono', () async {
    const w = 8, h = 8;
    final tmp = await tempRaw(w, h);
    try {
      List<Map<String, Object?>> tail(String yFromNode, String yFromPort) => [
            {'typeId': 'yuv_splitter', 'nodeId': 'sp', 'params': {}},
            if (yFromNode == 'ahe')
              {
                'typeId': 'ahe',
                'nodeId': 'ahe',
                'params': {'blockSize': 4, 'clipLimit': 2.0, 'strength': 1.0,
                    'bypass': true},
                'inputs': {
                  'in_mono': {'fromNodeId': 'sp', 'fromPort': 'out_y'},
                },
              },
            {
              'typeId': 'yuv_combiner',
              'nodeId': 'cb',
              'params': {},
              'inputs': {
                'in_y': {'fromNodeId': yFromNode, 'fromPort': yFromPort},
                'in_u': {'fromNodeId': 'sp', 'fromPort': 'out_u'},
                'in_v': {'fromNodeId': 'sp', 'fromPort': 'out_v'},
              },
            },
            {'typeId': 'csc_yuv2rgb', 'nodeId': 'rgb', 'params': {}},
            {'typeId': 'preview', 'nodeId': 'pv', 'params': {}},
          ];
      // bypass 的 ahe：in_mono → out_mono 直通。
      final bypassed = await runChainFrame(
          [src(tmp, w, h),
           {'typeId': 'demosaic', 'nodeId': 'dm', 'params': {}},
           {'typeId': 'csc_rgb2yuv', 'nodeId': 'yuv', 'params': {}},
           ...tail('ahe', 'out_mono')], 0);
      // 对照：无 ahe，合路器 Y 直接接分路器 out_y。
      final direct = await runChainFrame(
          [src(tmp, w, h),
           {'typeId': 'demosaic', 'nodeId': 'dm', 'params': {}},
           {'typeId': 'csc_rgb2yuv', 'nodeId': 'yuv', 'params': {}},
           ...tail('sp', 'out_y')], 0);
      expect(bypassed, equals(direct));
    } finally {
      await tmp.delete();
    }
  });

  test('GPU 链：bypass 节点直通（与 CPU 结果一致）', () async {
    const w = 8, h = 8;
    final tmp = await tempRaw(w, h);
    try {
      final gpu = await GpuPipeline.tryCreate();
      expect(gpu, isNotNull);
      final chain = <Map<String, Object?>>[
        {
          'typeId': 'cis_bayer_rggb',
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
          'typeId': 'black_level',
          'nodeId': 'bl',
          'params': {'r': 30.0, 'gr': 30.0, 'gb': 30.0, 'b': 30.0,
              'bypass': true},
        },
        {'typeId': 'demosaic', 'nodeId': 'dm', 'params': {}},
        {'typeId': 'preview', 'nodeId': 'pv', 'params': {}},
      ];
      expect(GpuPipeline.isSupportedChain(chain), isTrue);
      final result = await gpu!.run(chain, 0);
      final gpuRgba = await GpuPipeline.readbackBytes(result.image);
      result.image.dispose();
      final cpuRgba = await runChainFrame(chain, 0);
      // GPU/CPU 色调映射有 ±1 浮点差，逐字节容差比对。
      expect(gpuRgba.length, cpuRgba.length);
      var maxDiff = 0;
      for (var i = 0; i < gpuRgba.length; i++) {
        final d = (gpuRgba[i] - cpuRgba[i]).abs();
        if (d > maxDiff) maxDiff = d;
      }
      expect(maxDiff, lessThanOrEqualTo(1));
      // bypass 节点耗时应接近 0。
      expect(result.timingsUs['bl']! < 20000, isTrue);
    } finally {
      await tmp.delete();
    }
  });
}
