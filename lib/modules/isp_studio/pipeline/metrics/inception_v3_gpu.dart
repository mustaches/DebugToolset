/// InceptionV3（mseitzer pytorch-fid 移植版，FID/KID 口径）pool3 特征
/// 提取的 GPU 纹理驻留前向（对应 [InceptionV3Dart.forward] 的 GPU 版）。
///
/// 权重在 [load] 时上传一次（全部 BasicConv2d 的折叠权重，1x1 原生
/// 支持不再嵌入 3x3）；[forward] 把 [1,3,H,W] 输入上传一次，随后
/// stem + Mixed_5b..7c 的 121 个 conv（relu 融合进 conv 末 pass）与
/// 池化/分支 concat 全部 GPU 驻留执行，只在 Mixed_7c 输出处回读一次
/// （fp16 解码 [1,2048,h′,w′]），adaptiveAvgPool1x1 在 CPU 完成
/// （8×8×2048 均值，代价可忽略）。
///
/// 限制与回退：仅 UI isolate 可用（[GpuNnBackend] 依赖 dart:ui）。
/// patch 输入恒为 299²（[inceptionPatchInput] 负责 resize），最大中间
/// 张量 ≈47 万纹素 ≪ 2^24，故只走单纹理路径（无 banded）；逐层做纹
/// 素上限预检（[_requireSupported]），不可行抛 [UnsupportedError]，
/// 由调用方整链回退 CPU。fp16 精度：对拍记录见
/// test/isp_nn_gpu_inception_test.dart 与
/// scratch/nn_gpu_inception_bench_main.dart。
library;

import 'package:flutter/foundation.dart';

import '../nn/nn_gpu.dart';
import '../nn/nn_gpu_pack.dart' as pack;
import '../nn/ops.dart' as ops;
import '../nn/tensor.dart';
import 'inception_dart.dart';

/// [InceptionV3Gpu] 两阶段前向（优化 11：patch 流水线）的句柄：持有
/// Mixed_7c 输出纹理（[1,2048,h′,w′]），由
/// [InceptionV3Gpu.forwardDownload] 消费（回读 + adaptiveAvgPool1x1 +
/// 释放）或 [InceptionV3Gpu.discardForward] 直接释放，否则纹理泄漏。
class InceptionV3ForwardHandle {
  InceptionV3ForwardHandle(this.output);

  /// Mixed_7c 的 GPU 驻留输出（relu 后）。
  final GpuNnTensor output;

  void dispose() => output.dispose();
}

/// GPU 纹理驻留的 InceptionV3（FID 版）前向。
class InceptionV3Gpu {
  InceptionV3Gpu._(this._backend, this._conv);

  final GpuNnBackend _backend;

  /// 全部 BasicConv2d 的 GPU 驻留权重（键同 CPU 版，如
  /// `Mixed_5b.branch1x1.conv`）。
  final Map<String, GpuConvWeights> _conv;

  /// 测试/生产全局开关：false 时调用方不使用 GPU 链（镜像
  /// Vgg16AsyncForward.enabled / ClipRn50Gpu.enabled 的约定）。
  static bool enabled = true;

  /// 从 .nnw 加载全部 BasicConv2d 权重并上传为 GPU 驻留纹理。读取与
  /// fp16 打包整网一次 compute 在后台 isolate 完成（避免 UI isolate
  /// 同步大循环卡死，见 nn_gpu_pack.dart），UI 侧仅上传纹理。分支
  /// 通道数须均为 4 的倍数（concat 通道组整组对齐），不满足或任一上
  /// 传失败抛异常（已上传的权重随之释放），调用方回退 CPU。
  static Future<InceptionV3Gpu> load(
      GpuNnBackend backend, String nnwPath) async {
    final packed = await compute(pack.packInceptionWeights, nnwPath);
    final conv = <String, GpuConvWeights>{};
    try {
      for (final e in packed.entries) {
        conv[e.key] = await backend.uploadPackedConvWeights(e.value);
      }
      return InceptionV3Gpu._(backend, conv);
    } catch (_) {
      for (final w in conv.values) {
        w.dispose();
      }
      rethrow;
    }
  }

  /// 释放全部 GPU 驻留权重纹理（backend 本身由持有方管理）。
  void dispose() {
    for (final w in _conv.values) {
      w.dispose();
    }
  }

  GpuConvWeights _w(String name) {
    final w = _conv[name];
    if (w == null) {
      throw ArgumentError('InceptionV3Gpu: 缺少权重 "$name"');
    }
    return w;
  }

  /// 逐层纹素上限预检（单纹理路径）：沿网络结构模拟 (cP, h, w)，任一
  /// 张量的折叠纹素数 ≥ 2^24 抛 [UnsupportedError]（调用方回退 CPU）。
  void _requireSupported(int h0, int w0) {
    void check(int cP, int hh, int ww, String what) {
      final texels = 2 * (cP ~/ 4) * hh * ww;
      if (texels >= GpuNnBackend.maxTexels) {
        throw UnsupportedError('InceptionV3Gpu: $what 超出单纹理约束 '
            '(${cP}ch ${hh}x$ww)（调用方应回退 CPU）');
      }
    }

    var c = 4, h = h0, w = w0; // 输入 3ch 零填充到 4
    check(c, h, w, '输入');
    void bc(String name, {int sh = 1, int ph = 0, int pw = 0}) {
      final wgt = _w(name);
      check(c, h, w, '$name 输入');
      h = (h + 2 * ph - wgt.kH) ~/ sh + 1;
      w = (w + 2 * pw - wgt.kW) ~/ sh + 1;
      c = wgt.coutPadded;
      check(c, h, w, '$name 输出');
    }

    void pool3(int s, int p) {
      check(c, h, w, 'pool3x3 输入');
      h = (h + 2 * p - 3) ~/ s + 1;
      w = (w + 2 * p - 3) ~/ s + 1;
      check(c, h, w, 'pool3x3 输出');
    }

    int cCat(List<int> branchCs) {
      final total = branchCs.fold<int>(0, (a, b) => a + b);
      check(total, h, w, 'concat 输出');
      return total;
    }

    void mixedA(String p) {
      final cIn = c;
      bc('$p.branch1x1');
      final c1 = c;
      c = cIn;
      bc('$p.branch5x5_1');
      bc('$p.branch5x5_2', ph: 2, pw: 2);
      final c5 = c;
      c = cIn;
      bc('$p.branch3x3dbl_1');
      bc('$p.branch3x3dbl_2', ph: 1, pw: 1);
      bc('$p.branch3x3dbl_3', ph: 1, pw: 1);
      final c3 = c;
      c = cIn;
      bc('$p.branch_pool');
      c = cCat([c1, c5, c3, c]);
    }

    void mixedB(String p) {
      final cIn = c, hIn = h, wIn = w;
      bc('$p.branch3x3', sh: 2);
      final c3 = c;
      c = cIn;
      h = hIn;
      w = wIn;
      bc('$p.branch3x3dbl_1');
      bc('$p.branch3x3dbl_2', ph: 1, pw: 1);
      bc('$p.branch3x3dbl_3', sh: 2);
      final cd = c;
      // branch_pool：maxPool k3/s2/p0 保持通道
      c = cCat([c3, cd, cIn]);
    }

    void mixedC(String p) {
      final cIn = c;
      bc('$p.branch1x1');
      final c1 = c;
      c = cIn;
      bc('$p.branch7x7_1');
      bc('$p.branch7x7_2', pw: 3);
      bc('$p.branch7x7_3', ph: 3);
      final c7 = c;
      c = cIn;
      bc('$p.branch7x7dbl_1');
      bc('$p.branch7x7dbl_2', ph: 3);
      bc('$p.branch7x7dbl_3', pw: 3);
      bc('$p.branch7x7dbl_4', ph: 3);
      bc('$p.branch7x7dbl_5', pw: 3);
      final cd = c;
      c = cIn;
      bc('$p.branch_pool');
      c = cCat([c1, c7, cd, c]);
    }

    void mixedD(String p) {
      final cIn = c, hIn = h, wIn = w;
      bc('$p.branch3x3_1');
      bc('$p.branch3x3_2', sh: 2);
      final c3 = c;
      c = cIn;
      h = hIn;
      w = wIn;
      bc('$p.branch7x7x3_1');
      bc('$p.branch7x7x3_2', pw: 3);
      bc('$p.branch7x7x3_3', ph: 3);
      bc('$p.branch7x7x3_4', sh: 2);
      final c7 = c;
      c = cCat([c3, c7, cIn]);
    }

    void mixedE(String p) {
      final cIn = c;
      bc('$p.branch1x1');
      final c1 = c;
      c = cIn;
      bc('$p.branch3x3_1');
      final c3h = c;
      bc('$p.branch3x3_2a', pw: 1);
      final c3a = c;
      c = c3h;
      bc('$p.branch3x3_2b', ph: 1);
      final c3b = c;
      c = cIn;
      bc('$p.branch3x3dbl_1');
      bc('$p.branch3x3dbl_2', ph: 1, pw: 1);
      final cdh = c;
      bc('$p.branch3x3dbl_3a', pw: 1);
      final cda = c;
      c = cdh;
      bc('$p.branch3x3dbl_3b', ph: 1);
      final cdb = c;
      c = cIn;
      bc('$p.branch_pool');
      c = cCat([c1, c3a + c3b, cda + cdb, c]);
    }

    bc('Conv2d_1a_3x3', sh: 2);
    bc('Conv2d_2a_3x3');
    bc('Conv2d_2b_3x3', ph: 1, pw: 1);
    pool3(2, 0);
    bc('Conv2d_3b_1x1');
    bc('Conv2d_4a_3x3');
    pool3(2, 0);
    mixedA('Mixed_5b');
    mixedA('Mixed_5c');
    mixedA('Mixed_5d');
    mixedB('Mixed_6a');
    for (final m in ['Mixed_6b', 'Mixed_6c', 'Mixed_6d', 'Mixed_6e']) {
      mixedC(m);
    }
    mixedD('Mixed_7a');
    mixedE('Mixed_7b');
    mixedE('Mixed_7c');
  }

  /// BasicConv2d（BN 已折叠）：conv（带 bias）+ relu（融合进 conv 末
  /// pass）。输入纹理不释放（调用方管理）。
  GpuNnTensor _bc(GpuNnTensor x, String name,
      {int sh = 1, int ph = 0, int pw = 0}) {
    final wgt = _w(name);
    return _backend.conv2dGpu(x, wgt,
        stride: sh, padH: ph, padW: pw, relu: true);
  }

  /// FIDInceptionA（Mixed_5b/5c/5d）：branch_pool 为
  /// avgPool(k3,s1,p1,countIncludePad=false) → 1x1 conv。
  GpuNnTensor _mixedA(GpuNnTensor x, String p) {
    final b1 = _bc(x, '$p.branch1x1');
    var b5 = _bc(x, '$p.branch5x5_1');
    final b5b = _bc(b5, '$p.branch5x5_2', ph: 2, pw: 2);
    b5.dispose();
    b5 = b5b;
    var b3 = _bc(x, '$p.branch3x3dbl_1');
    var t = _bc(b3, '$p.branch3x3dbl_2', ph: 1, pw: 1);
    b3.dispose();
    b3 = t;
    t = _bc(b3, '$p.branch3x3dbl_3', ph: 1, pw: 1);
    b3.dispose();
    b3 = t;
    final bpa = _backend.pool3x3Gpu(x, avg: true, stride: 1, pad: 1);
    final bp = _bc(bpa, '$p.branch_pool');
    bpa.dispose();
    final out = _backend.concatChannelsGpu([b1, b5, b3, bp]);
    b1.dispose();
    b5.dispose();
    b3.dispose();
    bp.dispose();
    return out;
  }

  /// InceptionB（Mixed_6a）：降采样块，branch_pool 为 maxPool(k3,s2)。
  GpuNnTensor _mixedB(GpuNnTensor x, String p) {
    final b3 = _bc(x, '$p.branch3x3', sh: 2);
    var bd = _bc(x, '$p.branch3x3dbl_1');
    var t = _bc(bd, '$p.branch3x3dbl_2', ph: 1, pw: 1);
    bd.dispose();
    bd = t;
    t = _bc(bd, '$p.branch3x3dbl_3', sh: 2);
    bd.dispose();
    bd = t;
    final bp = _backend.pool3x3Gpu(x, stride: 2);
    final out = _backend.concatChannelsGpu([b3, bd, bp]);
    b3.dispose();
    bd.dispose();
    bp.dispose();
    return out;
  }

  /// FIDInceptionC（Mixed_6b..6e）：1x7/7x1 分解分支。
  GpuNnTensor _mixedC(GpuNnTensor x, String p) {
    final b1 = _bc(x, '$p.branch1x1');
    var b7 = _bc(x, '$p.branch7x7_1');
    var t = _bc(b7, '$p.branch7x7_2', pw: 3);
    b7.dispose();
    b7 = t;
    t = _bc(b7, '$p.branch7x7_3', ph: 3);
    b7.dispose();
    b7 = t;
    var bd = _bc(x, '$p.branch7x7dbl_1');
    t = _bc(bd, '$p.branch7x7dbl_2', ph: 3);
    bd.dispose();
    bd = t;
    t = _bc(bd, '$p.branch7x7dbl_3', pw: 3);
    bd.dispose();
    bd = t;
    t = _bc(bd, '$p.branch7x7dbl_4', ph: 3);
    bd.dispose();
    bd = t;
    t = _bc(bd, '$p.branch7x7dbl_5', pw: 3);
    bd.dispose();
    bd = t;
    final bpa = _backend.pool3x3Gpu(x, avg: true, stride: 1, pad: 1);
    final bp = _bc(bpa, '$p.branch_pool');
    bpa.dispose();
    final out = _backend.concatChannelsGpu([b1, b7, bd, bp]);
    b1.dispose();
    b7.dispose();
    bd.dispose();
    bp.dispose();
    return out;
  }

  /// InceptionD（Mixed_7a）：降采样块，branch_pool 为 maxPool(k3,s2)。
  GpuNnTensor _mixedD(GpuNnTensor x, String p) {
    var b3 = _bc(x, '$p.branch3x3_1');
    final b3b = _bc(b3, '$p.branch3x3_2', sh: 2);
    b3.dispose();
    b3 = b3b;
    var b7 = _bc(x, '$p.branch7x7x3_1');
    var t = _bc(b7, '$p.branch7x7x3_2', pw: 3);
    b7.dispose();
    b7 = t;
    t = _bc(b7, '$p.branch7x7x3_3', ph: 3);
    b7.dispose();
    b7 = t;
    t = _bc(b7, '$p.branch7x7x3_4', sh: 2);
    b7.dispose();
    b7 = t;
    final bp = _backend.pool3x3Gpu(x, stride: 2);
    final out = _backend.concatChannelsGpu([b3, b7, bp]);
    b3.dispose();
    b7.dispose();
    bp.dispose();
    return out;
  }

  /// FIDInceptionE_1/E_2（Mixed_7b/7c）：3x3 分支拆 1x3‖3x1 双头。
  /// [maxPool] 为 true 时是 E_2（Mixed_7c）：branch_pool 用
  /// maxPool(k3,s1,p1)（bug 即特性，保留）；否则 avgPool(cip=false)。
  GpuNnTensor _mixedE(GpuNnTensor x, String p, {required bool maxPool}) {
    final b1 = _bc(x, '$p.branch1x1');
    final b3 = _bc(x, '$p.branch3x3_1');
    final b3a = _bc(b3, '$p.branch3x3_2a', pw: 1);
    final b3b = _bc(b3, '$p.branch3x3_2b', ph: 1);
    b3.dispose();
    final b3c = _backend.concatChannelsGpu([b3a, b3b]);
    b3a.dispose();
    b3b.dispose();
    var bd = _bc(x, '$p.branch3x3dbl_1');
    var t = _bc(bd, '$p.branch3x3dbl_2', ph: 1, pw: 1);
    bd.dispose();
    bd = t;
    final bda = _bc(bd, '$p.branch3x3dbl_3a', pw: 1);
    final bdb = _bc(bd, '$p.branch3x3dbl_3b', ph: 1);
    bd.dispose();
    final bdc = _backend.concatChannelsGpu([bda, bdb]);
    bda.dispose();
    bdb.dispose();
    final bpa = maxPool
        ? _backend.pool3x3Gpu(x, stride: 1, pad: 1)
        : _backend.pool3x3Gpu(x, avg: true, stride: 1, pad: 1);
    final bp = _bc(bpa, '$p.branch_pool');
    bpa.dispose();
    final out = _backend.concatChannelsGpu([b1, b3c, bdc, bp]);
    b1.dispose();
    b3c.dispose();
    bdc.dispose();
    bp.dispose();
    return out;
  }

  /// GPU 驻留前向：[x] 为 [1,3,H,W]、已按 (x·255−128)/128 归一化的
  /// 输入，返回 2048 维 pool3 特征（fp32）。任何一步失败抛异常（中间
  /// 纹理在抛出前释放），调用方整链回退 CPU。
  /// 等价于 [forwardSubmit] + [forwardDownload] 顺序调用。
  Future<Float32List> forward(NnTensor x) async {
    return forwardDownload(await forwardSubmit(x));
  }

  /// 提交阶段（优化 11：patch 流水线）：上传输入并链式提交全部 GPU
  /// pass（中间纹理照旧即弃），返回持有 Mixed_7c 输出纹理的句柄，
  /// 不做回读。与 [forwardDownload] 配合可让 patch i 的回读与
  /// patch i+1 的 GPU 光栅化重叠（每个 patch 的计算序列与 [forward]
  /// 完全相同，数值逐位一致）。
  Future<InceptionV3ForwardHandle> forwardSubmit(NnTensor x) async {
    if (x.rank != 4 || x.batch != 1 || x.channels != 3) {
      throw ArgumentError(
          'InceptionV3Gpu.forwardSubmit 需要 [1,3,H,W] 输入，得到 $x');
    }
    _requireSupported(x.height, x.width);
    var h = await _backend.uploadFeatureMap(x);
    final yielder = GpuDispatchYield(); // 层间让出（优化 6，纯调度）
    GpuNnTensor step(GpuNnTensor out) {
      h.dispose();
      return out;
    }

    try {
      h = step(_bc(h, 'Conv2d_1a_3x3', sh: 2));
      h = step(_bc(h, 'Conv2d_2a_3x3'));
      h = step(_bc(h, 'Conv2d_2b_3x3', ph: 1, pw: 1));
      await yielder.tick();
      h = step(_backend.pool3x3Gpu(h, stride: 2));
      h = step(_bc(h, 'Conv2d_3b_1x1'));
      h = step(_bc(h, 'Conv2d_4a_3x3'));
      await yielder.tick();
      h = step(_backend.pool3x3Gpu(h, stride: 2));
      h = step(_mixedA(h, 'Mixed_5b'));
      await yielder.tick();
      h = step(_mixedA(h, 'Mixed_5c'));
      await yielder.tick();
      h = step(_mixedA(h, 'Mixed_5d'));
      await yielder.tick();
      h = step(_mixedB(h, 'Mixed_6a'));
      await yielder.tick();
      for (final m in ['Mixed_6b', 'Mixed_6c', 'Mixed_6d', 'Mixed_6e']) {
        h = step(_mixedC(h, m));
        await yielder.tick();
      }
      h = step(_mixedD(h, 'Mixed_7a'));
      await yielder.tick();
      h = step(_mixedE(h, 'Mixed_7b', maxPool: false));
      await yielder.tick();
      h = step(_mixedE(h, 'Mixed_7c', maxPool: true));
    } catch (_) {
      h.dispose();
      rethrow;
    }
    return InceptionV3ForwardHandle(h);
  }

  /// 下载阶段（优化 11）：回读 Mixed_7c 并做 adaptiveAvgPool1x1，无论
  /// 成败都在返回/抛出前释放句柄持有的输出纹理。
  Future<Float32List> forwardDownload(InceptionV3ForwardHandle handle) async {
    try {
      final feat = await _backend.downloadFeatureMap(handle.output,
          channels: inceptionFeatureDim);
      return ops.adaptiveAvgPool1x1(feat).data;
    } finally {
      handle.dispose();
    }
  }

  /// 放弃一个已提交的前向：只释放输出纹理，不做回读。
  Future<void> discardForward(InceptionV3ForwardHandle handle) async {
    handle.dispose();
  }
}
