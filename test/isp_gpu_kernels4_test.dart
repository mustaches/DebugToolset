// GPU 链执行器逐算子正确性测试（hsl_splitter / hsl_combiner）：
// 合路 shader 与 CPU 语义逐值对比；e2e 复刻「HSL独立通道预览」流程
// （分路 → 三单通道预览 → 合路 → 预览），GPU 链与 CPU 链出图比对。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/levels_curve.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const w = 16, h = 12, maxValue = 255; // 8bit 口径

Uint16List randFrame(int n, int seed) {
  final out = Uint16List(n);
  var s = seed;
  for (var i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out[i] = s % (maxValue + 1);
  }
  return out;
}

Future<Uint16List> runShader(
  ui.FragmentProgram prog,
  List<double> uniforms,
  List<Uint16List> inputs,
  List<int> inputChannels,
  int outChannels,
) async {
  final samplers = <ui.Image>[];
  for (var i = 0; i < inputs.length; i++) {
    samplers
        .add(await GpuPipeline.uploadPacked(inputs[i], w, h, inputChannels[i]));
  }
  final outTexW = w * outChannels ~/ 2;
  final out = GpuPipeline.runPass(prog, uniforms, samplers, outTexW, h);
  final bytes = await GpuPipeline.readbackBytes(out);
  for (final s in samplers) {
    s.dispose();
  }
  out.dispose();
  return bytes.buffer.asUint16List();
}

void expectClose(Uint16List actual, Uint16List expected, int tol, String tag) {
  expect(actual.length, expected.length, reason: tag);
  var maxDiff = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxDiff) maxDiff = d;
  }
  // ignore: avoid_print
  print('$tag 最大差 $maxDiff（容差 $tol）');
  expect(maxDiff, lessThanOrEqualTo(tol), reason: tag);
}

void expectRgbaClose(Uint8List actual, Uint8List expected, int tol, String tag) {
  expect(actual.length, expected.length, reason: tag);
  var maxDiff = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxDiff) maxDiff = d;
  }
  // ignore: avoid_print
  print('$tag 最大差 $maxDiff（容差 $tol）');
  expect(maxDiff, lessThanOrEqualTo(tol), reason: tag);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GpuPipeline gpu;

  setUpAll(() async {
    gpu = (await GpuPipeline.tryCreate())!;
  });

  group('combine_3ch GPU vs CPU 语义（HSL 口径）', () {
    // uniforms：uTexW, uTexH, uHas0..2, uDef0..2, uOutTexW，
    // 顺序见 isp_combine_3ch.frag；HSL/RGB 缺省值全 0。
    List<double> uniforms(bool hasH, bool hasS, bool hasL,
            [double def0 = 0, double def1 = 0, double def2 = 0]) =>
        [
          (w / 2).toDouble(), h.toDouble(),
          hasH ? 1.0 : 0.0, hasS ? 1.0 : 0.0, hasL ? 1.0 : 0.0,
          def0, def1, def2,
          (w * 3 / 2).toDouble(),
        ];

    test('三路齐全：交织打包', () async {
      final hPlane = randFrame(w * h, 1);
      final sPlane = randFrame(w * h, 2);
      final lPlane = randFrame(w * h, 3);
      final expected = Uint16List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        expected[i * 3] = hPlane[i];
        expected[i * 3 + 1] = sPlane[i];
        expected[i * 3 + 2] = lPlane[i];
      }
      final actual = await runShader(
        gpu.progForTest('combine_3ch'),
        uniforms(true, true, true),
        [hPlane, sPlane, lPlane], [1, 1, 1], 3,
      );
      expectClose(actual, expected, 0, 'combine_3ch 三路');
    });

    test('未连接通道填缺省值（与 CPU 一致）', () async {
      final hPlane = randFrame(w * h, 4);
      final lPlane = randFrame(w * h, 5);
      final expected = Uint16List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        expected[i * 3] = hPlane[i];
        expected[i * 3 + 2] = lPlane[i];
      }
      final actual = await runShader(
        gpu.progForTest('combine_3ch'),
        uniforms(true, false, true),
        // S 未连接：占位 sampler 不采样（uHas1=0）。
        [hPlane, hPlane, lPlane], [1, 1, 1], 3,
      );
      expectClose(actual, expected, 0, 'combine_3ch 缺 S');
    });

    test('YUV 口径：U/V 未连接填色度中点', () async {
      final yPlane = randFrame(w * h, 6);
      const mid = maxValue >> 1;
      final expected = Uint16List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        expected[i * 3] = yPlane[i];
        expected[i * 3 + 1] = mid;
        expected[i * 3 + 2] = mid;
      }
      final actual = await runShader(
        gpu.progForTest('combine_3ch'),
        uniforms(true, false, false, 0, mid.toDouble(), mid.toDouble()),
        [yPlane, yPlane, yPlane], [1, 1, 1], 3,
      );
      expectClose(actual, expected, 0, 'combine_3ch YUV 缺 U/V');
    });
  });

  group('HSL 分路/合路 e2e（复刻 HSL独立通道预览 流程）', () {
    /// 8bit unpacked RAW：每像素一个 16 位小端字。
    List<int> raw8Le(Iterable<int> px) => [
          for (final v in px) ...[v & 0xFF, (v >> 8) & 0xFF],
        ];

    Map<String, Object?> op(String id, String type,
            [Map<String, Object?> inputs = const {},
            Map<String, Object?> params = const {}]) =>
        {'nodeId': id, 'typeId': type, 'params': params, 'inputs': inputs};

    Map<String, Object?> portOf(String nodeId, String port) =>
        {'fromNodeId': nodeId, 'fromPort': port};

    List<Map<String, Object?>> buildChain(String filePath,
        {required String sink}) {
      final chain = <Map<String, Object?>>[
        op('src', 'bayer_source', {}, {
          'filePath': filePath,
          'width': w,
          'height': h,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
          'bayerPattern': 'RGGB',
          'littleEndian': true,
          'frameIndex': 0,
        }),
        op('dm', 'demosaic', {'in': portOf('src', 'out')},
            {'algorithm': 'bilinear'}),
        op('csc', 'csc_rgb2hsl', {'in': portOf('dm', 'out')}),
        op('split', 'hsl_splitter', {'in': portOf('csc', 'out')}),
        op('pvH', 'preview', {'in_mono': portOf('split', 'out_h')}),
        op('pvS', 'preview', {'in_mono': portOf('split', 'out_s')}),
        op('pvL', 'preview', {'in_mono': portOf('split', 'out_l')}),
        op('comb', 'hsl_combiner', {
          'in_h': portOf('pvH', 'out_mono'),
          'in_s': portOf('pvS', 'out_mono'),
          'in_l': portOf('pvL', 'out_mono'),
        }),
        op('pv', 'preview', {'in_hsl': portOf('comb', 'out')}),
      ];
      if (sink == 'pv') return chain;
      // 单通道预览链：源 → … → 分路 → 对应预览。
      final cut = {'pvH': 5, 'pvS': 6, 'pvL': 7}[sink]!;
      return chain.sublist(0, cut);
    }

    test('isSupportedChain 判定通过', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_hsl_gpu_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        expect(GpuPipeline.isSupportedChain(buildChain(tmp.path, sink: 'pv')),
            isTrue);
      } finally {
        await tmp.delete();
      }
    });

    test('前缀覆盖预览：捕获图与耗时均落表（Bayer2RGB 预览#1 场景）', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_hsl_gpu_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        // 主链 源→去马赛克→预览；RAW 直显预览 pvRaw 的链 [src, pvRaw]
        // 是主链前缀，被覆盖后在源节点处捕获——其节点不在主链上，
        // 耗时只能来自捕获测量。
        final chain = <Map<String, Object?>>[
          op('src', 'bayer_source', {}, {
            'filePath': tmp.path,
            'width': w,
            'height': h,
            'bitDepth': '8',
            'packing': 'unpacked_lsb',
            'bayerPattern': 'RGGB',
            'littleEndian': true,
            'frameIndex': 0,
          }),
          op('dm', 'demosaic', {'in': portOf('src', 'out')},
              {'algorithm': 'bilinear'}),
          op('pv', 'preview', {'in': portOf('dm', 'out')}),
        ];
        final result =
            await gpu.run(chain, 0, displayCaptures: {'pvRaw': 'src'});
        expect(result.displayImages['pvRaw'], isNotNull);
        result.displayImages['pvRaw']!.dispose();
        result.image.dispose();
        expect(result.timingsUs.containsKey('pvRaw'), isTrue);
        expect(result.timingsUs['pvRaw']!, greaterThanOrEqualTo(0));
      } finally {
        await tmp.delete();
      }
    });

    test('GPU 链与 CPU 链出图一致（含分支预览捕获）', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_hsl_gpu_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(raw8Le(List<int>.generate(w * h, (i) => i)));
      try {
        final chain = buildChain(tmp.path, sink: 'pv');
        // GPU：主链一次执行，三个分支预览在各自节点捕获（其输入为 mono
        // 平面，不是主帧——捕获点必须设在预览节点自身）。
        final result = await gpu.run(chain, 0, displayCaptures: {
          'pvH': 'pvH',
          'pvS': 'pvS',
          'pvL': 'pvL',
        });
        final gpuMain = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        // 合路器输出捕获为 hsl 格式。
        expect(result.captures['comb']?['format'], 'hsl');

        final cpuMain = await runChainFrame(chain, 0);
        expectRgbaClose(gpuMain, cpuMain, 8, 'e2e 合路预览');

        // 分支预览：GPU 捕获图 vs CPU 单通道预览链出图。
        for (final pv in ['pvH', 'pvS', 'pvL']) {
          final img = result.displayImages[pv];
          expect(img, isNotNull, reason: pv);
          final gpuBranch = await GpuPipeline.readbackBytes(img!);
          img.dispose();
          final cpuBranch = await runChainFrame(buildChain(tmp.path, sink: pv), 0);
          expectRgbaClose(gpuBranch, cpuBranch, 8, 'e2e 分支预览 $pv');
        }
      } finally {
        await tmp.delete();
      }
    });
  });

  group('图片源 outFormat（复刻 HSL色相控制流：out_hsl 直连调节器）', () {
    Map<String, Object?> op(String id, String type,
            [Map<String, Object?> inputs = const {},
            Map<String, Object?> params = const {},
            Map<String, Object?> extra = const {}]) =>
        {'nodeId': id, 'typeId': type, 'params': params, 'inputs': inputs,
         ...extra};

    Future<File> tempPng() async {
      final im = img.Image(width: 8, height: 4, numChannels: 3);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 8; x++) {
          im.setPixelRgb(x, y, (x * 31) % 256, (y * 85) % 256,
              ((x + y) * 17) % 256);
        }
      }
      final tmp = File(
          '${Directory.systemTemp.path}/isp_outfmt_${DateTime.now().microsecondsSinceEpoch}.png');
      await tmp.writeAsBytes(img.encodePng(im));
      return tmp;
    }

    test('out_hsl → hsl_debugger：GPU 与 CPU 出图一致', () async {
      final tmp = await tempPng();
      try {
        final chain = <Map<String, Object?>>[
          op('src', 'image_source', {},
              {'filePath': tmp.path, 'bitDepth': '8'},
              {'outFormat': 'hsl'}),
          op('dbg', 'hsl_debugger',
              {'in': {'fromNodeId': 'src', 'fromPort': 'out_hsl'}},
              {'h_shift': 90.0, 's_gain': 1.0, 'l_gain': 1.0}),
          op('pv', 'preview',
              {'in_hsl': {'fromNodeId': 'dbg', 'fromPort': 'out'}}),
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0);
        final gpuRgba = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        // 调节器输出捕获为 hsl（而非 rgb）——修复前此处抛
        // 「HSL调节器需要 hsl 输入（当前 rgb）」整帧回退 CPU。
        expect(result.captures['dbg']?['format'], 'hsl');
        final cpuRgba = await runChainFrame(chain, 0);
        expectRgbaClose(gpuRgba, cpuRgba, 6, 'out_hsl → hsl_debugger');
      } finally {
        await tmp.delete();
      }
    });

    test('out_yuv → yuv_debugger：GPU 与 CPU 出图一致', () async {
      final tmp = await tempPng();
      try {
        final chain = <Map<String, Object?>>[
          op('src', 'image_source', {},
              {'filePath': tmp.path, 'bitDepth': '8'},
              {'outFormat': 'yuv'}),
          op('dbg', 'yuv_debugger',
              {'in': {'fromNodeId': 'src', 'fromPort': 'out_yuv'}},
              {'y_gain': 1.2, 'u_gain': 0.8, 'v_gain': 1.0}),
          op('pv', 'preview',
              {'in_yuv': {'fromNodeId': 'dbg', 'fromPort': 'out'}}),
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0);
        final gpuRgba = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        expect(result.captures['dbg']?['format'], 'yuv');
        final cpuRgba = await runChainFrame(chain, 0);
        expectRgbaClose(gpuRgba, cpuRgba, 6, 'out_yuv → yuv_debugger');
      } finally {
        await tmp.delete();
      }
    });
  });

  group('RGB 分路/合路 e2e（复刻 RGB独立通道预览 流程）', () {
    Map<String, Object?> op(String id, String type,
            [Map<String, Object?> inputs = const {},
            Map<String, Object?> params = const {},
            Map<String, Object?> extra = const {}]) =>
        {'nodeId': id, 'typeId': type, 'params': params, 'inputs': inputs,
         ...extra};

    Map<String, Object?> portOf(String nodeId, String port) =>
        {'fromNodeId': nodeId, 'fromPort': port};

    Future<File> tempPng() async {
      final im = img.Image(width: w, height: h, numChannels: 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          im.setPixelRgb(x, y, (x * 13) % 256, (y * 21) % 256,
              ((x + y) * 7) % 256);
        }
      }
      final tmp = File(
          '${Directory.systemTemp.path}/isp_rgb_gpu_${DateTime.now().microsecondsSinceEpoch}.png');
      await tmp.writeAsBytes(img.encodePng(im));
      return tmp;
    }

    List<Map<String, Object?>> buildChain(String filePath,
        {required String sink, String outFormat = 'rgb'}) {
      final chain = <Map<String, Object?>>[
        op('src', 'image_source', {}, {'filePath': filePath, 'bitDepth': '8'},
            {'outFormat': outFormat}),
        op('split', 'rgb_splitter', {'in': portOf('src', 'out_rgb')}),
        op('pvR', 'preview', {'in_mono': portOf('split', 'out_r')}),
        op('pvG', 'preview', {'in_mono': portOf('split', 'out_g')}),
        op('pvB', 'preview', {'in_mono': portOf('split', 'out_b')}),
        op('comb', 'rgb_combiner', {
          'in_r': portOf('pvR', 'out_mono'),
          'in_g': portOf('pvG', 'out_mono'),
          'in_b': portOf('pvB', 'out_mono'),
        }),
        op('pv', 'preview', {'in': portOf('comb', 'out')}),
      ];
      if (sink == 'pv') return chain;
      // 单通道预览链：源 → 分路 → 对应预览。
      final cut = {'pvR': 3, 'pvG': 4, 'pvB': 5}[sink]!;
      return chain.sublist(0, cut);
    }

    test('GPU 链与 CPU 链出图一致（含分支预览捕获）', () async {
      final tmp = await tempPng();
      try {
        final chain = buildChain(tmp.path, sink: 'pv');
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0, displayCaptures: {
          'pvR': 'pvR',
          'pvG': 'pvG',
          'pvB': 'pvB',
        });
        final gpuMain = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        expect(result.captures['comb']?['format'], 'rgb');
        final cpuMain = await runChainFrame(chain, 0);
        expectRgbaClose(gpuMain, cpuMain, 4, 'e2e 合路预览');
        for (final pv in ['pvR', 'pvG', 'pvB']) {
          final img0 = result.displayImages[pv];
          expect(img0, isNotNull, reason: pv);
          final gpuBranch = await GpuPipeline.readbackBytes(img0!);
          img0.dispose();
          final cpuBranch =
              await runChainFrame(buildChain(tmp.path, sink: pv), 0);
          expectRgbaClose(gpuBranch, cpuBranch, 4, 'e2e 分支预览 $pv');
        }
      } finally {
        await tmp.delete();
      }
    });

    test('HSL 输入内转 RGB 再分路（outFormat hsl）', () async {
      final tmp = await tempPng();
      try {
        final chain = <Map<String, Object?>>[
          op('src', 'image_source', {}, {'filePath': tmp.path, 'bitDepth': '8'},
              {'outFormat': 'hsl'}),
          op('split', 'rgb_splitter', {'in': portOf('src', 'out_hsl')}),
          op('pvR', 'preview', {'in_mono': portOf('split', 'out_r')}),
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0);
        final gpuRgba = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        final cpuRgba = await runChainFrame(chain, 0);
        expectRgbaClose(gpuRgba, cpuRgba, 6, 'hsl 输入分路');
      } finally {
        await tmp.delete();
      }
    });
  });

  group('YUV 分路/合路 e2e（复刻 YUV独立通道预览 流程）', () {
    Map<String, Object?> op(String id, String type,
            [Map<String, Object?> inputs = const {},
            Map<String, Object?> params = const {},
            Map<String, Object?> extra = const {}]) =>
        {'nodeId': id, 'typeId': type, 'params': params, 'inputs': inputs,
         ...extra};

    Map<String, Object?> portOf(String nodeId, String port) =>
        {'fromNodeId': nodeId, 'fromPort': port};

    Future<File> tempPng() async {
      final im = img.Image(width: w, height: h, numChannels: 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          im.setPixelRgb(x, y, (x * 13) % 256, (y * 21) % 256,
              ((x + y) * 7) % 256);
        }
      }
      final tmp = File(
          '${Directory.systemTemp.path}/isp_yuv_gpu_${DateTime.now().microsecondsSinceEpoch}.png');
      await tmp.writeAsBytes(img.encodePng(im));
      return tmp;
    }

    List<Map<String, Object?>> buildChain(String filePath,
        {required String sink}) {
      final chain = <Map<String, Object?>>[
        op('src', 'image_source', {}, {'filePath': filePath, 'bitDepth': '8'},
            {'outFormat': 'yuv'}),
        op('split', 'yuv_splitter', {'in': portOf('src', 'out_yuv')}),
        op('pvY', 'preview', {'in_mono': portOf('split', 'out_y')}),
        op('pvU', 'preview', {'in_mono': portOf('split', 'out_u')}),
        op('pvV', 'preview', {'in_mono': portOf('split', 'out_v')}),
        op('comb', 'yuv_combiner', {
          'in_y': portOf('pvY', 'out_mono'),
          'in_u': portOf('pvU', 'out_mono'),
          'in_v': portOf('pvV', 'out_mono'),
        }),
        op('pv', 'preview', {'in_yuv': portOf('comb', 'out')}),
      ];
      if (sink == 'pv') return chain;
      final cut = {'pvY': 3, 'pvU': 4, 'pvV': 5}[sink]!;
      return chain.sublist(0, cut);
    }

    test('U/V 经预览中转的合路链：GPU 与 CPU 出图一致', () async {
      // 修复前：out_u/out_v 为零拷贝通道引用且 isSupportedChain 强制
      // 合路器 U/V 直连分路器，经预览中转的形态整链回退 CPU。
      final tmp = await tempPng();
      try {
        final chain = buildChain(tmp.path, sink: 'pv');
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0, displayCaptures: {
          'pvY': 'pvY',
          'pvU': 'pvU',
          'pvV': 'pvV',
        });
        final gpuMain = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        expect(result.captures['comb']?['format'], 'yuv');
        final cpuMain = await runChainFrame(chain, 0);
        expectRgbaClose(gpuMain, cpuMain, 6, 'e2e 合路预览');
        for (final pv in ['pvY', 'pvU', 'pvV']) {
          final img0 = result.displayImages[pv];
          expect(img0, isNotNull, reason: pv);
          final gpuBranch = await GpuPipeline.readbackBytes(img0!);
          img0.dispose();
          final cpuBranch =
              await runChainFrame(buildChain(tmp.path, sink: pv), 0);
          expectRgbaClose(gpuBranch, cpuBranch, 6, 'e2e 分支预览 $pv');
        }
      } finally {
        await tmp.delete();
      }
    });
  });

  group('video_source GPU 单帧预览（复刻 YUV多路视频预览 链形态）', () {
    Map<String, Object?> op(String id, String type,
            [Map<String, Object?> inputs = const {},
            Map<String, Object?> params = const {},
            Map<String, Object?> extra = const {}]) =>
        {'nodeId': id, 'typeId': type, 'params': params, 'inputs': inputs,
         ...extra};

    Map<String, Object?> portOf(String nodeId, String port) =>
        {'fromNodeId': nodeId, 'fromPort': port};

    test('视频源 → 分路 → 三预览 → 合路 → 预览：GPU 与 CPU 一致', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 16x16 彩条测试源，2 帧。
      final tmp = File(
          '${Directory.systemTemp.path}/isp_video_gpu_${DateTime.now().microsecondsSinceEpoch}.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc2=size=16x16:rate=2:duration=1',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final chain = <Map<String, Object?>>[
          op('src', 'video_source', {}, {
            'filePath': tmp.path,
            'ffmpegPath': 'tools/ffmpeg/ffmpeg.exe',
          }, {'outFormat': 'yuv'}),
          op('split', 'yuv_splitter', {'in': portOf('src', 'out_yuv')}),
          op('pvY', 'preview', {'in_mono': portOf('split', 'out_y')}),
          op('pvU', 'preview', {'in_mono': portOf('split', 'out_u')}),
          op('pvV', 'preview', {'in_mono': portOf('split', 'out_v')}),
          op('comb', 'yuv_combiner', {
            'in_y': portOf('pvY', 'out_mono'),
            'in_u': portOf('pvU', 'out_mono'),
            'in_v': portOf('pvV', 'out_mono'),
          }),
          op('pv', 'preview', {'in_yuv': portOf('comb', 'out')}),
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0, displayCaptures: {
          'pvY': 'pvY',
          'pvU': 'pvU',
          'pvV': 'pvV',
        });
        expect(result.captures['comb']?['format'], 'yuv');
        final gpuMain = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        // CPU 预览路径（无平面轨道注入）：同一帧 ffmpeg 解码为 RGB16 后
        // 内部转 YUV，与 GPU 路径语义一致（浮点/定点差给容差）。
        final cpuMain = await runChainFrame(chain, 0);
        expectRgbaClose(gpuMain, cpuMain, 6, '视频源 e2e 合路预览');
      } finally {
        await tmp.delete();
      }
    });
  });

  group('levels_curve GPU vs CPU（曲线调节器 LUT 映射）', () {
    Future<Uint16List> runLut(Uint16List src, Uint16List lut) async {
      final srcTex = await GpuPipeline.uploadPacked(src, w, h, 3);
      final lutTex = await GpuPipeline.uploadPacked(lut, kLevelsMax + 1, 1, 1);
      final out = GpuPipeline.runPass(
          gpu.progForTest('levels_curve'),
          [w * 3 / 2, h.toDouble(), maxValue.toDouble(), 2048.0],
          [srcTex, lutTex], w * 3 ~/ 2, h);
      final bytes = await GpuPipeline.readbackBytes(out);
      srcTex.dispose();
      lutTex.dispose();
      out.dispose();
      return bytes.buffer.asUint16List();
    }

    test('样条曲线（4 控制点）', () async {
      final src = randFrame(w * h * 3, 77);
      final lut = levelsCurveLut([
        [0.0, 0.0],
        [1024.0, 2048.0],
        [3072.0, 2500.0],
        [4095.0, 4095.0],
      ]);
      final cpu = applyLevelsCurve(src, lut, maxValue: maxValue);
      expectClose(await runLut(src, lut), cpu, 1, 'levels_curve spline');
    });

    test('gamma 模式（γ=0.5 压暗）', () async {
      final src = randFrame(w * h * 3, 78);
      final lut = levelsCurveLut(kLevelsIdentityPoints,
          mode: LevelsCurveMode.gamma, gamma: 0.5);
      final cpu = applyLevelsCurve(src, lut, maxValue: maxValue);
      expectClose(await runLut(src, lut), cpu, 1, 'levels_curve gamma');
    });

    test('e2e：image → 曲线调节器 → 预览（GPU vs CPU）', () async {
      final im = img.Image(width: w, height: h, numChannels: 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          im.setPixelRgb(x, y, (x * 13) % 256, (y * 21) % 256,
              ((x + y) * 7) % 256);
        }
      }
      final tmp = File(
          '${Directory.systemTemp.path}/isp_lv_gpu_${DateTime.now().microsecondsSinceEpoch}.png');
      await tmp.writeAsBytes(img.encodePng(im));
      try {
        final chain = <Map<String, Object?>>[
          {
            'nodeId': 'src', 'typeId': 'image_source',
            'params': {'filePath': tmp.path, 'bitDepth': '8'},
            'inputs': <String, Object?>{}, 'outFormat': 'rgb',
          },
          {
            'nodeId': 'lv', 'typeId': 'levels_curves',
            'params': {
              'points': [
                [0.0, 0.0],
                [2048.0, 3200.0],
                [4095.0, 4095.0],
              ],
            },
            'inputs': {'in': {'fromNodeId': 'src', 'fromPort': 'out_rgb'}},
          },
          {
            'nodeId': 'pv', 'typeId': 'preview', 'params': <String, Object?>{},
            'inputs': {'in': {'fromNodeId': 'lv', 'fromPort': 'out'}},
          },
        ];
        expect(GpuPipeline.isSupportedChain(chain), isTrue);
        final result = await gpu.run(chain, 0);
        final gpuRgba = await GpuPipeline.readbackBytes(result.image);
        result.image.dispose();
        expect(result.captures['lv']?['format'], 'rgb');
        final cpuRgba = await runChainFrame(chain, 0);
        expectRgbaClose(gpuRgba, cpuRgba, 4, 'levels e2e');
      } finally {
        await tmp.delete();
      }
    });
  });
}
