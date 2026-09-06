/// InceptionV3（mseitzer pytorch-fid 移植版，FID/KID 口径）pool3 特征
/// 提取的进程内 Dart 实现（纯 Dart，无 Flutter 依赖），语义忠实于
/// pyiqa（scratch/eval_venv/Lib/site-packages/pyiqa/archs/inception.py）
/// 与 iqa_bridge.py 的 _InceptionFeature / _DistMetric.add：
///
///   切块：s = min(299, h, w)，50% 重叠（步长 max(1, s//2)），
///     起点 range(0, dim−s+1, step)，末块贴边（dim ≤ s 时单块），
///     y 外层 x 内层
///   预处理：RGBA8888 → [0,1] RGB planes → 每 patch 双线性 resize 到
///     299²（align_corners=False）→ (x·255−128)/128
///   网络：BN 已在导出时折叠进 conv（tools/iqa/export_weights.py，
///     eps=1e-3），每个 BasicConv2d = conv(带 bias) + relu，无 BN；
///     Mixed_7b 的 branch_pool 用 avgPool（count_include_pad=False），
///     Mixed_7c 的 branch_pool 用 maxPool（著名的 bug 即特性，保留）
///   输出：adaptiveAvgPool1x1 后的 2048 维 pool3 特征。
///
/// 权重：tools/iqa/weights/inception_v3_fid.nnw（键如
/// `Mixed_5b.branch1x1.conv.weight`）。
///
/// [InceptionV3Dart.inceptionPatchFeatures] 为单线程同步版；
/// [inceptionPatchFeaturesParallel] 把 patch 分给多个 isolate（每个
/// 各自加载权重跑完整网络），与同步版位级一致；
/// [inceptionFeaturesInIsolate] 为 compute() 入口。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../nn/nnw_reader.dart';
import '../nn/ops.dart' as ops;
import '../nn/tensor.dart';
import 'inception_v3_gpu.dart';

/// InceptionV3（FID 版）权重的缺省路径（相对工作目录）。
const String inceptionV3WeightsPath = 'tools/iqa/weights/inception_v3_fid.nnw';

/// 网络输入边长（patch 一律 resize 到 299²）。
const int inceptionInputSize = 299;

/// pool3 特征维度。
const int inceptionFeatureDim = 2048;

/// patch 切块起点（一维）：移植 iqa_bridge.py 的 _patch_positions——
/// 50% 重叠，末块贴边补齐（dim ≤ size 时单块）。
List<int> inceptionPatchPositions(int dim, int size) {
  if (dim <= size) {
    return [0];
  }
  final step = math.max(1, size ~/ 2);
  final pos = <int>[];
  for (var p = 0; p <= dim - size; p += step) {
    pos.add(p);
  }
  if (pos.last != dim - size) {
    pos.add(dim - size);
  }
  return pos;
}

/// 整帧 patch 网格：(y0, x0, s) 列表，y 外层 x 内层（与 Python 参考
/// `for y in ys for x in xs` 同序）。
List<(int, int, int)> inceptionPatchGrid(int width, int height) {
  final s = math.min(inceptionInputSize, math.min(height, width));
  final xs = inceptionPatchPositions(width, s);
  final ys = inceptionPatchPositions(height, s);
  return [for (final y in ys) for (final x in xs) (y, x, s)];
}

/// 单个 patch 的网络输入：RGBA8888 中 (y0,x0) 起 s×s 块 → [0,1] RGB
/// planes → 双线性 resize 到 299² → (x·255−128)/128，[1,3,299,299]。
NnTensor inceptionPatchInput(
    Uint8List rgba, int width, int y0, int x0, int s) {
  final t = NnTensor.zeros([1, 3, s, s]);
  for (var c = 0; c < 3; c++) {
    final cBase = c * s * s;
    for (var dy = 0; dy < s; dy++) {
      var src = ((y0 + dy) * width + x0) * 4 + c;
      var dst = cBase + dy * s;
      for (var dx = 0; dx < s; dx++, dst++, src += 4) {
        t.data[dst] = rgba[src] / 255.0;
      }
    }
  }
  final r = ops.resizeBilinear(t, inceptionInputSize, inceptionInputSize);
  for (var i = 0; i < r.numel; i++) {
    r.data[i] = (r.data[i] * 255.0 - 128.0) / 128.0;
  }
  return r;
}

/// InceptionV3（FID 版）前向，输出 2048 维 pool3 特征。
class InceptionV3Dart {
  InceptionV3Dart._(this._weights, this._biases);

  /// 从 .nnw 加载全部 BasicConv2d 的折叠权重（`*..conv.weight/.bias`，
  /// 按键名前缀索引，如 `Mixed_5b.branch1x1.conv`）。fc 层不参与
  /// pool3 特征，不加载。
  factory InceptionV3Dart.load(String nnwPath) {
    final reader = NnwReader.open(nnwPath);
    try {
      final weights = <String, NnTensor>{};
      final biases = <String, Float32List>{};
      for (final name in reader.tensorNames) {
        if (!name.endsWith('.conv.weight')) {
          continue;
        }
        final base =
            name.substring(0, name.length - '.conv.weight'.length);
        weights[base] = reader.readTensor(name);
        biases[base] = reader.tensor('$base.conv.bias').$1;
      }
      return InceptionV3Dart._(weights, biases);
    } finally {
      reader.close();
    }
  }

  final Map<String, NnTensor> _weights;
  final Map<String, Float32List> _biases;

  /// BasicConv2d（BN 已折叠）：conv(带 bias) + relu。kernel 尺寸取
  /// 权重形状，支持非对称（1x7/7x1/1x3/3x1）。
  NnTensor _bc(NnTensor x, String name,
      {int sh = 1, int sw = 1, int ph = 0, int pw = 0}) {
    final w = _weights[name];
    final b = _biases[name];
    if (w == null || b == null) {
      throw ArgumentError('InceptionV3Dart: 缺少权重 "$name"');
    }
    return ops.relu(ops.conv2d(x, w,
        bias: b, strideH: sh, strideW: sw, padH: ph, padW: pw));
  }

  /// FIDInceptionA（Mixed_5b/5c/5d）：branch_pool 为
  /// avgPool(k3,s1,p1,countIncludePad=false) → 1x1 conv。
  NnTensor _mixedA(NnTensor x, String p) {
    final b1 = _bc(x, '$p.branch1x1');
    var b5 = _bc(x, '$p.branch5x5_1');
    b5 = _bc(b5, '$p.branch5x5_2', ph: 2, pw: 2);
    var b3 = _bc(x, '$p.branch3x3dbl_1');
    b3 = _bc(b3, '$p.branch3x3dbl_2', ph: 1, pw: 1);
    b3 = _bc(b3, '$p.branch3x3dbl_3', ph: 1, pw: 1);
    var bp = ops.avgPool2d(x, 3, 3, 1, 1, 1, 1, countIncludePad: false);
    bp = _bc(bp, '$p.branch_pool');
    return ops.concatChannels([b1, b5, b3, bp]);
  }

  /// InceptionB（Mixed_6a）：降采样块，branch_pool 为 maxPool(k3,s2)。
  NnTensor _mixedB(NnTensor x, String p) {
    final b3 = _bc(x, '$p.branch3x3', sh: 2, sw: 2);
    var bd = _bc(x, '$p.branch3x3dbl_1');
    bd = _bc(bd, '$p.branch3x3dbl_2', ph: 1, pw: 1);
    bd = _bc(bd, '$p.branch3x3dbl_3', sh: 2, sw: 2);
    final bp = ops.maxPool2d(x, 3, 3, 2, 2, 0, 0);
    return ops.concatChannels([b3, bd, bp]);
  }

  /// FIDInceptionC（Mixed_6b..6e）：1x7/7x1 分解分支。
  NnTensor _mixedC(NnTensor x, String p) {
    final b1 = _bc(x, '$p.branch1x1');
    var b7 = _bc(x, '$p.branch7x7_1');
    b7 = _bc(b7, '$p.branch7x7_2', ph: 0, pw: 3);
    b7 = _bc(b7, '$p.branch7x7_3', ph: 3, pw: 0);
    var bd = _bc(x, '$p.branch7x7dbl_1');
    bd = _bc(bd, '$p.branch7x7dbl_2', ph: 3, pw: 0);
    bd = _bc(bd, '$p.branch7x7dbl_3', ph: 0, pw: 3);
    bd = _bc(bd, '$p.branch7x7dbl_4', ph: 3, pw: 0);
    bd = _bc(bd, '$p.branch7x7dbl_5', ph: 0, pw: 3);
    var bp = ops.avgPool2d(x, 3, 3, 1, 1, 1, 1, countIncludePad: false);
    bp = _bc(bp, '$p.branch_pool');
    return ops.concatChannels([b1, b7, bd, bp]);
  }

  /// InceptionD（Mixed_7a）：降采样块，branch_pool 为 maxPool(k3,s2)。
  NnTensor _mixedD(NnTensor x, String p) {
    var b3 = _bc(x, '$p.branch3x3_1');
    b3 = _bc(b3, '$p.branch3x3_2', sh: 2, sw: 2);
    var b7 = _bc(x, '$p.branch7x7x3_1');
    b7 = _bc(b7, '$p.branch7x7x3_2', ph: 0, pw: 3);
    b7 = _bc(b7, '$p.branch7x7x3_3', ph: 3, pw: 0);
    b7 = _bc(b7, '$p.branch7x7x3_4', sh: 2, sw: 2);
    final bp = ops.maxPool2d(x, 3, 3, 2, 2, 0, 0);
    return ops.concatChannels([b3, b7, bp]);
  }

  /// FIDInceptionE_1/E_2（Mixed_7b/7c）：3x3 分支拆 1x3‖3x1 双头。
  /// [maxPool] 为 true 时是 E_2（Mixed_7c）：branch_pool 用
  /// maxPool(k3,s1,p1)（pytorch-fid 的著名 bug 即特性，必须保留）；
  /// 否则为 E_1：avgPool(k3,s1,p1,countIncludePad=false)。
  NnTensor _mixedE(NnTensor x, String p, {required bool maxPool}) {
    final b1 = _bc(x, '$p.branch1x1');
    var b3 = _bc(x, '$p.branch3x3_1');
    final b3a = _bc(b3, '$p.branch3x3_2a', ph: 0, pw: 1);
    final b3b = _bc(b3, '$p.branch3x3_2b', ph: 1, pw: 0);
    b3 = ops.concatChannels([b3a, b3b]);
    var bd = _bc(x, '$p.branch3x3dbl_1');
    bd = _bc(bd, '$p.branch3x3dbl_2', ph: 1, pw: 1);
    final bda = _bc(bd, '$p.branch3x3dbl_3a', ph: 0, pw: 1);
    final bdb = _bc(bd, '$p.branch3x3dbl_3b', ph: 1, pw: 0);
    bd = ops.concatChannels([bda, bdb]);
    var bp = maxPool
        ? ops.maxPool2d(x, 3, 3, 1, 1, 1, 1)
        : ops.avgPool2d(x, 3, 3, 1, 1, 1, 1, countIncludePad: false);
    bp = _bc(bp, '$p.branch_pool');
    return ops.concatChannels([b1, b3, bd, bp]);
  }

  /// 前向：[x] 为 [1,3,299,299]、已按 (x·255−128)/128 归一化的输入，
  /// 返回 2048 维 pool3 特征（fp32）。
  Float32List forward(NnTensor x) {
    if (x.rank != 4 || x.channels != 3) {
      throw ArgumentError('InceptionV3Dart.forward 需要 [N,3,H,W] 输入，'
          '得到 $x');
    }
    var h = _bc(x, 'Conv2d_1a_3x3', sh: 2, sw: 2);
    h = _bc(h, 'Conv2d_2a_3x3');
    h = _bc(h, 'Conv2d_2b_3x3', ph: 1, pw: 1);
    h = ops.maxPool2d(h, 3, 3, 2, 2, 0, 0);
    h = _bc(h, 'Conv2d_3b_1x1');
    h = _bc(h, 'Conv2d_4a_3x3');
    h = ops.maxPool2d(h, 3, 3, 2, 2, 0, 0);
    h = _mixedA(h, 'Mixed_5b');
    h = _mixedA(h, 'Mixed_5c');
    h = _mixedA(h, 'Mixed_5d');
    h = _mixedB(h, 'Mixed_6a');
    for (final m in ['Mixed_6b', 'Mixed_6c', 'Mixed_6d', 'Mixed_6e']) {
      h = _mixedC(h, m);
    }
    h = _mixedD(h, 'Mixed_7a');
    h = _mixedE(h, 'Mixed_7b', maxPool: false);
    h = _mixedE(h, 'Mixed_7c', maxPool: true);
    h = ops.adaptiveAvgPool1x1(h);
    return h.data;
  }

  /// 整帧 patch 特征（同步单线程版）：返回 [n,2048] 连续排布，
  /// patch 顺序同 [inceptionPatchGrid]。
  Float32List inceptionPatchFeatures(Uint8List rgba, int width, int height) {
    _checkFrame(rgba, width, height);
    final grid = inceptionPatchGrid(width, height);
    final out = Float32List(grid.length * inceptionFeatureDim);
    for (var i = 0; i < grid.length; i++) {
      final (y0, x0, s) = grid[i];
      final f = forward(inceptionPatchInput(rgba, width, y0, x0, s));
      out.setRange(i * inceptionFeatureDim, (i + 1) * inceptionFeatureDim, f);
    }
    return out;
  }
}

void _checkFrame(Uint8List rgba, int width, int height) {
  if (width < 1 || height < 1 || rgba.length < width * height * 4) {
    throw ArgumentError('inceptionPatchFeatures: 帧尺寸/数据长度不符 '
        '($width×$height, ${rgba.length})');
  }
}

/// patch 段 [i0,i1) 的特征（isolate 内执行：各自加载权重跑完整网络）。
Float32List _featuresChunk(Uint8List rgba, int width, int height,
    String weightsPath, Int32List rects, int i0, int i1) {
  final net = InceptionV3Dart.load(weightsPath);
  final out = Float32List((i1 - i0) * inceptionFeatureDim);
  for (var i = i0; i < i1; i++) {
    final f = net.forward(inceptionPatchInput(
        rgba, width, rects[i * 3], rects[i * 3 + 1], rects[i * 3 + 2]));
    out.setRange((i - i0) * inceptionFeatureDim,
        (i - i0 + 1) * inceptionFeatureDim, f);
  }
  return out;
}

/// 整帧 patch 特征（多 isolate 并行版）：patch 分给 [workers] 个
/// isolate（缺省按 CPU 核数），每个各自加载权重跑完整网络，结果与
/// [InceptionV3Dart.inceptionPatchFeatures] 位级一致。
///
/// [gpuNet]（可选，GPU 纹理驻留的 InceptionV3Gpu）非空且
/// [InceptionV3Gpu.enabled] 时改走 GPU 路径：逐 patch 驻留前向（UI
/// isolate 串行，fp16 精度见 test/isp_nn_gpu_inception_test.dart）；
/// 任一 patch 失败抛异常，由调用方整批回退本函数的 isolate 并行路径。
Future<Float32List> inceptionPatchFeaturesParallel(
    Uint8List rgba, int width, int height,
    {String weightsPath = inceptionV3WeightsPath,
    int? workers,
    InceptionV3Gpu? gpuNet}) async {
  _checkFrame(rgba, width, height);
  final grid = inceptionPatchGrid(width, height);
  final n = grid.length;
  final gn = gpuNet;
  if (gn != null && InceptionV3Gpu.enabled) {
    final out = Float32List(n * inceptionFeatureDim);
    for (var i = 0; i < n; i++) {
      final (y0, x0, s) = grid[i];
      final f = await gn.forward(inceptionPatchInput(rgba, width, y0, x0, s));
      out.setRange(
          i * inceptionFeatureDim, (i + 1) * inceptionFeatureDim, f);
    }
    return out;
  }
  final nw =
      math.max(1, math.min(workers ?? (Platform.numberOfProcessors - 2), n));
  if (nw <= 1) {
    return InceptionV3Dart.load(weightsPath)
        .inceptionPatchFeatures(rgba, width, height);
  }
  final rects = Int32List(n * 3);
  for (var i = 0; i < n; i++) {
    rects[i * 3] = grid[i].$1;
    rects[i * 3 + 1] = grid[i].$2;
    rects[i * 3 + 2] = grid[i].$3;
  }
  final tasks = <Future<Float32List>>[];
  final starts = <int>[];
  for (var t = 0; t < nw; t++) {
    final i0 = n * t ~/ nw;
    final i1 = n * (t + 1) ~/ nw;
    if (i0 >= i1) {
      continue;
    }
    starts.add(i0);
    tasks.add(Isolate.run(
        () => _featuresChunk(rgba, width, height, weightsPath, rects, i0, i1)));
  }
  final chunks = await Future.wait(tasks);
  final out = Float32List(n * inceptionFeatureDim);
  for (var t = 0; t < chunks.length; t++) {
    out.setRange(starts[t] * inceptionFeatureDim,
        (starts[t] + chunks[t].length ~/ inceptionFeatureDim) *
            inceptionFeatureDim, chunks[t]);
  }
  return out;
}

/// compute() 入口：`{'rgba': Uint8List, 'width': int, 'height': int,
/// 'weightsPath': String?}` → `{'n': patch 数, 'features': Float32List
/// [n,2048]}`（单线程同步提取）。
@pragma('vm:entry-point')
Map<String, Object?> inceptionFeaturesInIsolate(Map<String, Object?> msg) {
  final rgba = msg['rgba'] as Uint8List;
  final width = msg['width'] as int;
  final height = msg['height'] as int;
  final weightsPath =
      (msg['weightsPath'] as String?) ?? inceptionV3WeightsPath;
  final features = InceptionV3Dart.load(weightsPath)
      .inceptionPatchFeatures(rgba, width, height);
  return {'n': features.length ~/ inceptionFeatureDim, 'features': features};
}
