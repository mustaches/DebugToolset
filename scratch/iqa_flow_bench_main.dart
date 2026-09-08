// 图像评价.ispflow「运行预览」仪器阶段基准：复刻 _runInstruments 的
// 生产口径（2x 降采样馈源 1688×3000、_gpuMetricLock 串行、
// _heavyCpuLock ≤2、FID/KID 共享 Inception 特征），15 个指标并发扇出，
// 输出每指标耗时/后端/分数与总墙钟时间。
//
// 运行（release，Impeller 默认）：
//   flutter run scratch/iqa_flow_bench_main.dart -d windows --release
// 对照（关闭 Impeller）：
//   flutter run scratch/iqa_flow_bench_main.dart -d windows --release --no-enable-impeller
// 完成标记：IQA_FLOW_BENCH_TOTAL（供 run_bench_watchdog.sh 匹配）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/brisque.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/piqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/dists_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clipiqa_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/musiq_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clip_rn50_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_v3_gpu.dart';

// --- 复刻 isp_studio_state.dart 的两把并发治理锁（优化 6/7） ---

/// NIQE/BRISQUE/PIQE 的 compute 入口（顶层函数，避免闭包共享上下文里
/// 混入 Future 导致 isolate message 不可发送）。
double _singleCpuEntry(Map<String, Object?> msg) {
  final rgba = msg['rgba'] as Uint8List;
  final w = msg['width'] as int;
  final h = msg['height'] as int;
  return switch (msg['kind']) {
    'niqe' => niqeScore(rgba, w, h),
    'brisque' => brisqueScore(rgba, w, h),
    _ => piqeScore(rgba, w, h),
  };
}

Future<void> _gpuTurn = Future.value();

// 优化 12：FID/KID 走独立锁链，与 VGG/RN50 大链并行交错。
Future<void> _gpuPatchTurn = Future.value();

Future<T> _gpuLock<T>(Future<T> Function() fn) {
  final completer = Completer<T>();
  _gpuTurn = _gpuTurn.then((_) async {
    try {
      completer.complete(await fn());
    } catch (e, st) {
      completer.completeError(e, st);
    }
  });
  return completer.future;
}

// 优化 12：FID/KID 走独立锁链，与 VGG/RN50 大链并行交错。
Future<T> _gpuPatchLock<T>(Future<T> Function() fn) {
  final completer = Completer<T>();
  _gpuPatchTurn = _gpuPatchTurn.then((_) async {
    try {
      completer.complete(await fn());
    } catch (e, st) {
      completer.completeError(e, st);
    }
  });
  return completer.future;
}

var _heavyRunning = 0;
final _heavyWaiters = <Completer<void>>[];

Future<T> _heavyLock<T>(Future<T> Function() fn) async {
  while (_heavyRunning >= 2) {
    final waiter = Completer<void>();
    _heavyWaiters.add(waiter);
    await waiter.future;
  }
  _heavyRunning++;
  try {
    return await fn();
  } finally {
    _heavyRunning--;
    if (_heavyWaiters.isNotEmpty) _heavyWaiters.removeAt(0).complete();
  }
}

// --- 基准本体 ---

void _report(String kind, int ms, String backend, Object? value) {
  print('IQA_FLOW_BENCH $kind | ${ms}ms | $backend | $value');
}

Future<void> bench() async {
  const refPath = 'IspFlow/DemoPhoto/3.jpg';
  const testPath = 'IspFlow/DemoPhoto/3noise.png';
  final totalSw = Stopwatch()..start();

  // 馈源：生产解码入口 + 2x 降采样（后台 isolate，同 _downsampleFeed）。
  var sw = Stopwatch()..start();
  final (refFull, rw0, rh0) = await decodeImageFileToRgba8(refPath);
  final (testFull, tw0, th0) = await decodeImageFileToRgba8(testPath);
  print('IQA_FLOW_BENCH 解码 ${sw.elapsedMilliseconds}ms '
      '(${rw0}x$rh0, ${tw0}x$th0)');
  sw = Stopwatch()..start();
  final (ra, w, h) = await compute(downsampleRgba82xInIsolate,
      {'src': refFull, 'width': rw0, 'height': rh0});
  final (ta, w2, h2) = await compute(downsampleRgba82xInIsolate,
      {'src': testFull, 'width': tw0, 'height': th0});
  assert(w == w2 && h == h2);
  print('IQA_FLOW_BENCH 降采样 ${sw.elapsedMilliseconds}ms (${w}x$h)');

  // 共享 NnPool（核数-4，同 _sharedNnPool）与三条 GPU 链（懒创建）。
  final pool = NnPool();
  await pool.start(math.max(2, Platform.numberOfProcessors - 4));
  final backend = await GpuNnBackend.tryCreate();
  print('IQA_FLOW_BENCH GpuNnBackend=${backend != null}');
  Vgg16Gpu? vgg;
  ClipRn50Gpu? rn50;
  InceptionV3Gpu? inception;
  if (backend != null) {
    sw = Stopwatch()..start();
    try {
      vgg = await Vgg16Gpu.load(backend, lpipsVggWeightsPath);
    } catch (e) {
      print('IQA_FLOW_BENCH VGG16 GPU 链加载失败: $e');
    }
    try {
      rn50 = await ClipRn50Gpu.load(backend, clipiqaWeightsPath);
    } catch (e) {
      print('IQA_FLOW_BENCH RN50 GPU 链加载失败: $e');
    }
    try {
      inception = await InceptionV3Gpu.load(backend, inceptionV3WeightsPath);
    } catch (e) {
      print('IQA_FLOW_BENCH InceptionV3 GPU 链加载失败: $e');
    }
    print('IQA_FLOW_BENCH GPU链权重上传 ${sw.elapsedMilliseconds}ms '
        '(vgg=${vgg != null} rn50=${rn50 != null} inc=${inception != null})');
  }

  // FID/KID 共享特征（同 _deepIqaFeatCache）：先提交者算，后到者复用。
  Future<(Float32List, Float32List)>? featFuture;
  Future<(Float32List, Float32List)> sharedFeats() =>
      featFuture ??= _gpuLock(() async {
        final fr = await inceptionPatchFeaturesParallel(ra, w, h,
            gpuNet: inception);
        final ft = await inceptionPatchFeaturesParallel(ta, w, h,
            gpuNet: inception);
        return (fr, ft);
      });

  final tasks = <String, Future<void>>{};

  void dual(String kind) {
    tasks[kind] = () async {
      final t = Stopwatch()..start();
      final r = await _heavyLock(() => compute(dualMetricInIsolate,
          {'kind': kind, 'ref': ra, 'test': ta, 'width': w, 'height': h}));
      final v = r['psnr'] ?? r['ssim'] ?? r['fsim'];
      _report(kind, t.elapsedMilliseconds, 'cpu', v);
    }();
  }

  for (final k in ['psnr', 'ssim', 'msssim', 'fsim']) dual(k);

  void singleCpu(String kind) {
    tasks[kind] = () async {
      final t = Stopwatch()..start();
      final v = await _heavyLock(() => compute(_singleCpuEntry,
          {'kind': kind, 'rgba': ta, 'width': w, 'height': h}));
      _report(kind, t.elapsedMilliseconds, 'cpu', v);
    }();
  }

  singleCpu('niqe');
  singleCpu('brisque');
  singleCpu('piqe');
  tasks['ilniqe'] = () async {
    final t = Stopwatch()..start();
    final v = await _heavyLock(() => compute(ilniqeScoreParallelInIsolate,
        {'rgba': ta, 'width': w, 'height': h}));
    _report('ilniqe', t.elapsedMilliseconds, 'cpu', v);
  }();
  tasks['musiq'] = () async {
    final t = Stopwatch()..start();
    final v = await _heavyLock(() => compute(musiqScoreInIsolate,
        {'rgba': ta, 'width': w, 'height': h}));
    _report('musiq', t.elapsedMilliseconds, 'cpu', v);
  }();

  void gpuPair(String kind) {
    tasks[kind] = () async {
      final t = Stopwatch()..start();
      var usedGpu = false;
      final v = await _gpuLock(() => kind == 'lpips'
          ? lpipsScoreParallel(ra, ta, w, h,
              pool: pool, vggForward: vgg, onBackend: (g) => usedGpu = g)
          : distsScoreParallel(ra, ta, w, h,
              pool: pool, vggForward: vgg, onBackend: (g) => usedGpu = g));
      _report(kind, t.elapsedMilliseconds, usedGpu ? 'gpu' : 'cpu', v);
    }();
  }

  gpuPair('lpips');
  gpuPair('dists');

  tasks['clipiqa'] = () async {
    final t = Stopwatch()..start();
    var usedGpu = false;
    final v = await _gpuLock(() => clipiqaScoreParallel(ta, w, h,
        pool: pool, gpuTrunk: rn50, onBackend: (g) => usedGpu = g));
    _report('clipiqa', t.elapsedMilliseconds, usedGpu ? 'gpu' : 'cpu', v);
  }();

  tasks['fid'] = () async {
    final t = Stopwatch()..start();
    final (fr, ft) = await sharedFeats();
    final n = fr.length ~/ fidFeatureDim;
    final nt = ft.length ~/ fidFeatureDim;
    final v = fidScoreFromFeatures(fr, n, ft, nt);
    _report('fid', t.elapsedMilliseconds, inception != null ? 'gpu' : 'cpu',
        v);
  }();
  tasks['kid'] = () async {
    final t = Stopwatch()..start();
    final (fr, ft) = await sharedFeats();
    final v = kidCompute(
        fr, fr.length ~/ fidFeatureDim, ft, ft.length ~/ fidFeatureDim);
    _report('kid', t.elapsedMilliseconds, inception != null ? 'gpu' : 'cpu',
        v);
  }();

  await Future.wait(tasks.values);
  print('IQA_FLOW_BENCH_TOTAL ${totalSw.elapsedMilliseconds}ms '
      '(15 指标, 馈源 ${w}x$h)');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('iqa flow bench')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await bench();
    } catch (e, st) {
      print('IQA_FLOW_BENCH_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
