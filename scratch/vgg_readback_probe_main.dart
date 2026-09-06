// VGG16 GPU 链回读成本探针（一次性诊断脚本，scratch 不参与分析）：
//   flutter run -d windows --release -t scratch/vgg_readback_probe_main.dart
//
// 验证模型假设：toImage_sync 全延迟提交（探针 toimage_probe_main 已证实
// 提交 0ms、GPU 有占用）下，真实 banded 前向的全部光栅化成本发生在
// 切片回读（ui.Image.toByteData，nn_gpu.dart 的 _readback）时、且在 UI
// 线程同步执行；若 5 次切片回读各自重算整条依赖图（~5× 重复光栅化），
// 则 bench 的 1688×3000 单侧 21s ≈ 5 × 4.2s。
//
// 做法：不改 lib/，用公开的 GpuNnBackend banded 原语 + nn_gpu_pack 的
// 整网打包入口照抄 Vgg16Gpu._forwardBanded 的提交循环（LPIPS 口径：
// maxpool；_poolBefore/_sliceAfter 常量为 vgg16_gpu.dart 的私有值，照抄
// 字面量），把「提交」与「回读」拆开计时；另做同图二次回读（缓存验证）、
// drawImage+toImage 物化对比，以及 50ms Timer 的 UI 事件循环活性计数
// （ticks=0 即该阶段堵 UI 线程）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu_pack.dart'
    as pack;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Vgg16Gpu 的私有常量（照抄字面量）：池化出现在这些 conv 索引之前。
const poolBefore = {5, 10, 17, 24};

/// 切片特征在这些 conv（relu 后）截取：relu1_2..relu5_3。
const sliceAfter = {2, 7, 14, 21, 28};

final status = ValueNotifier<String>('回读探针初始化…');

/// UI 事件循环活性计数（50ms 一拍；某阶段 ticks=0 即堵 UI 线程）。
var eventloopTicks = 0;

void say(String s) {
  status.value = s;
  // ignore: avoid_print
  print(s);
}

/// busyFrame（同 scratch/nn_gpu_vgg_bench_main.dart）。
Uint8List busyFrame(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 1] = (128 +
              70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
              40 * math.cos((2 * x - y) / 6.7))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 2] = (128 +
              70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

/// busyFrame RGBA → LPIPS ScalingLayer 输出（同 bench main）。
NnTensor lpipsInput(Uint8List rgba, int width, int height) {
  const shift = [-0.030, -0.088, -0.188];
  const scale = [0.458, 0.448, 0.450];
  final s = width * height;
  final data = Float32List(3 * s);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    for (var i = 0, j = c; i < s; i++, j += 4) {
      data[base + i] = ((rgba[j] / 255.0) * 2.0 - 1.0 - shift[c]) / scale[c];
    }
  }
  return NnTensor(data, [1, 3, height, width]);
}

/// 照抄 Vgg16Gpu._forwardBanded 的提交循环（LPIPS 口径 maxpool），
/// 不做任何回读：返回 5 个切片（调用方负责 dispose；链尾 h 已释放）。
Future<List<GpuNnBandedTensor>> submitChain(
    GpuNnBackend g, List<GpuConvWeights> convW, NnTensor x) async {
  final slices = <GpuNnBandedTensor>[];
  var h = await g.uploadFeatureMapBanded(x);
  for (var i = 0; i < Vgg16Dart.convIndices.length; i++) {
    final idx = Vgg16Dart.convIndices[i];
    if (poolBefore.contains(idx)) {
      final pooled = g.maxPool2x2GpuBanded(h);
      h.dispose();
      h = pooled;
    }
    final conv = g.conv2dGpuBanded(h, convW[i]);
    h.dispose();
    final act = g.reluGpuBanded(conv);
    conv.dispose();
    h = act;
    if (sliceAfter.contains(idx)) {
      slices.add(g.reluGpuBanded(h));
    }
  }
  h.dispose();
  return slices;
}

/// 阶段计时小工具：返回耗时并重置活性计数。
class _Phase {
  final sw = Stopwatch()..start();

  String done(String name) {
    final ms = sw.elapsedMilliseconds;
    final line =
        'VGG_RB_PROBE $name = ${ms}ms (eventloopTicks=$eventloopTicks)';
    say(line);
    eventloopTicks = 0;
    sw.reset();
    return line;
  }
}

Future<void> probe() async {
  if (!File(lpipsVggWeightsPath).existsSync()) {
    say('VGG_RB_PROBE_ERROR 缺少权重 $lpipsVggWeightsPath');
    return;
  }
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    say('VGG_RB_PROBE_ERROR backend 初始化失败');
    return;
  }

  // 权重：整网一次 compute 后台打包（同优化 5 的生产路径），UI 仅上传。
  var ph = _Phase();
  final packed = await compute(
      pack.packVgg16Weights, (lpipsVggWeightsPath, Vgg16Dart.convIndices));
  final convW = <GpuConvWeights>[];
  for (final p in packed.convs) {
    convW.add(await g.uploadPackedConvWeights(p));
  }
  ph.done('loadWeights');

  const w = 1688, h = 3000;
  final input = lpipsInput(busyFrame(w, h), w, h);

  // ---------------- a. 提交阶段（链 #1，不回读） ----------------
  say('VGG_RB_PROBE === 提交链 #1（banded 前向，~1600 pass，不回读） ===');
  final slices1 = await submitChain(g, convW, input);
  ph.done('submitChain1');

  // ---------------- b. 5 次切片回读各自计时 ----------------
  say('VGG_RB_PROBE === 逐切片回读（downloadFeatureMapBanded） ===');
  for (var i = 0; i < slices1.length; i++) {
    await g.downloadFeatureMapBanded(slices1[i]);
    ph.done('readback slice$i (${slices1[i].shape})');
  }

  // ---------------- c. 缓存验证：同图二次回读 ----------------
  final img0 = slices1[0].bands[0].tex;
  await img0.toByteData();
  ph.done('readbackAgain slice0.band0（同图第二次 toByteData）');

  // ---------------- d. 物化对比（链 #2 全新惰性图） ----------------
  say('VGG_RB_PROBE === 物化对比（重新提交链 #2 得全新惰性图） ===');
  final slices2 = await submitChain(g, convW, input);
  ph.done('submitChain2');
  // 只留 slice0/slice1，其余切片立即释放（省显存/内存）。
  for (var i = 2; i < slices2.length; i++) {
    slices2[i].dispose();
  }
  final lazyA = slices2[0].bands[0].tex; // 链 #2 slice0 band0（惰性）
  final lazyB = slices2[1].bands[0].tex; // 链 #2 slice1 band0（惰性）
  // d1：drawImage(惰性图) 录制 → await toImage 物化（光栅线程管线）。
  ui.Image? materialized;
  try {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawImage(
        lazyA, ui.Offset.zero, ui.Paint());
    final pic = rec.endRecording();
    materialized =
        await pic.toImage(slices2[0].bands[0].texW, slices2[0].bands[0].texH);
    pic.dispose();
    ph.done('materialize slice0.band0（drawImage+await toImage）');
    // d2：物化后的图回读。
    await materialized.toByteData();
    ph.done('readbackMaterialized（物化图 toByteData）');
  } catch (e) {
    say('VGG_RB_PROBE_ERROR materialize $e');
  }
  // d3：直接回读另一张惰性图（此时链 #2 的光栅化可能已被 d1 在光栅
  // 线程完成——本行同时验证「光栅线程物化后 UI 直读是否命中缓存」）。
  await lazyB.toByteData();
  ph.done('directReadbackLazy slice1.band0（materialize 之后）');

  // ---------------- 判读提示 ----------------
  say('VGG_RB_PROBE 判读：① submitChain ≈0ms 证实提交全延迟；'
      '② 5 次 readback 若各自 ~4s 级 → 每次回读重算整条依赖图（5× 重复'
      '光栅化），若 slice0 贵而后续便宜 → 仅首次付全链成本；'
      '③ readbackAgain ≈0ms → 同图有光栅化缓存；'
      '④ materialize 阶段 ticks>0 而 readback 阶段 ticks=0 → '
      'toImage 物化不堵 UI、toByteData 惰性图堵 UI；'
      '⑤ directReadbackLazy 在 materialize 后若变便宜 → 光栅线程产物'
      '可被 UI 直读命中。');

  materialized?.dispose();
  for (final s in slices1) {
    s.dispose();
  }
  slices2[0].dispose();
  slices2[1].dispose();
  for (final cw in convW) {
    cw.dispose();
  }
  g.dispose();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Timer.periodic(const Duration(milliseconds: 50), (_) => eventloopTicks++);
  runApp(MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF202020),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, s, _) => Text(s,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  ));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await probe();
    } catch (e, st) {
      say('VGG_RB_PROBE_ERROR 顶层 $e\n$st');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(0);
  });
}
