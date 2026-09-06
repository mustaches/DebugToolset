/// CLIP RN50 主干（ModifiedResNet 的 conv 部分）的 GPU 纹理驻留前向
/// （CLIPIQA 用，对应 [ClipRn50Dart.forward] 去掉 AttentionPool2d 的
/// 部分；attention 留在 CPU 侧，见
/// [ClipRn50Dart.attnPoolForwardParallel]）。
///
/// 权重在 [load] 时上传一次（stem 3 个 conv3x3 + 16 个 Bottleneck 的
/// conv1/conv2/conv3 与 block0 的 downsample，1x1 均嵌入 3x3 中心 tap，
/// 含偏置）；[forwardTrunk] 把输入特征图上传一次，随后全部 conv(+relu)
/// /avgPool2x2/残差 addrelu GPU 驻留执行，只在最后回读一次
/// [1, 2048, h′, w′] 特征（fp16 解码 Float32List NCHW）。
///
/// 限制与回退：仅 UI isolate 可用（[GpuNnBackend] 依赖 dart:ui）。
/// 折叠布局单纹理受纹素数 < 2^24 约束；超出时整链切换分块路径（沿 H
/// 切带，halo 经 stitch shader 拼接，conv s2 的 padded 带为 2th+2 行，
/// 残差两路分块经 conv3 的 forceOutHeights 对齐）；逐层做分块规划预检
/// （[_requireChainSupported]），任何一层不可行即抛
/// [UnsupportedError]，由调用方整链回退 CPU（不做半 GPU 半 CPU 混合）。
/// fp16 精度：逐层/端到端 CLIPIQA 对拍记录见
/// test/isp_nn_gpu_rn50_test.dart。
library;

import 'package:flutter/foundation.dart';

import '../nn/nn_gpu.dart';
import '../nn/nn_gpu_pack.dart' as pack;
import '../nn/tensor.dart';
import 'clip_rn50_dart.dart';

/// 一个 Bottleneck 的 GPU 驻留权重（conv1/conv3 与 downsample 的 1x1
/// 已嵌入 3x3 中心 tap；ds 仅每层 block 0 非空）。
class _GpuBlock {
  _GpuBlock(this.stride, this.c1, this.c2, this.c3, this.ds);

  final int stride;
  final GpuConvWeights c1, c2, c3;
  final GpuConvWeights? ds;

  void dispose() {
    c1.dispose();
    c2.dispose();
    c3.dispose();
    ds?.dispose();
  }
}

/// GPU 纹理驻留的 CLIP RN50 主干前向（conv 部分）。
class ClipRn50Gpu {
  ClipRn50Gpu._(this._backend, this._stem, this._blocks);

  final GpuNnBackend _backend;

  /// stem 三个 conv3x3（conv1 为 s2/p1，其余 s1/p1）。
  final List<GpuConvWeights> _stem;
  final List<_GpuBlock> _blocks;

  /// (planes, blocks, stride)，同 [ClipRn50Dart] 的 _layerConfig。
  static const _layerConfig = [
    (64, 3, 1),
    (128, 4, 2),
    (256, 6, 2),
    (512, 3, 2)
  ];

  /// 测试用：true 时跳过单纹理预检、强制走分块路径（配合
  /// [GpuNnBackend.debugMaxBandTexels] 使小尺寸也能验证分块链）。
  /// 生产代码勿动。
  static bool debugForceBanded = false;

  /// 全局开关：false 时调用方不使用 GPU 链（镜像
  /// Vgg16AsyncForward.enabled 的约定；测试在软件光栅环境关断）。
  static bool enabled = true;

  /// 从 .nnw 加载 stem + 16 个 Bottleneck 的 weight+bias 并上传为 GPU
  /// 驻留纹理（1x1 先嵌入 3x3 中心 tap）。读取/embed/fp16 打包整网
  /// 一次 compute 在后台 isolate 完成（避免 UI isolate 同步大循环卡
  /// 死，见 nn_gpu_pack.dart），UI 侧仅上传纹理。任一失败抛异常（已
  /// 上传的权重随之释放），调用方回退 CPU。attention 权重不上传。
  static Future<ClipRn50Gpu> load(GpuNnBackend backend, String nnwPath) async {
    final packed = await compute(pack.packRn50Weights, (
      nnwPath,
      [for (final e in _layerConfig) [e.$1, e.$2, e.$3]],
    ));
    final stem = <GpuConvWeights>[];
    final blocks = <_GpuBlock>[];
    try {
      for (final p in packed.stem) {
        stem.add(await backend.uploadPackedConvWeights(p));
      }
      var pi = 0;
      for (var li = 0; li < _layerConfig.length; li++) {
        final (_, blockCount, stride) = _layerConfig[li];
        for (var bi = 0; bi < blockCount; bi++) {
          final pb = packed.blocks[pi++];
          blocks.add(_GpuBlock(
            bi == 0 ? stride : 1,
            await backend.uploadPackedConvWeights(pb.c1),
            await backend.uploadPackedConvWeights(pb.c2),
            await backend.uploadPackedConvWeights(pb.c3),
            pb.ds != null
                ? await backend.uploadPackedConvWeights(pb.ds!)
                : null,
          ));
        }
      }
      return ClipRn50Gpu._(backend, stem, blocks);
    } catch (_) {
      for (final w in stem) {
        w.dispose();
      }
      for (final b in blocks) {
        b.dispose();
      }
      rethrow;
    }
  }

  /// 释放全部 GPU 驻留权重纹理（backend 本身由持有方管理）。
  void dispose() {
    for (final w in _stem) {
      w.dispose();
    }
    for (final b in _blocks) {
      b.dispose();
    }
  }

  static bool _sizeOk(int texels) {
    if (texels >= GpuNnBackend.maxTexels) return false;
    final rows =
        (texels + GpuNnBackend.maxTextureDim - 1) ~/ GpuNnBackend.maxTextureDim;
    return rows <= GpuNnBackend.maxTextureDim;
  }

  /// 整链预检（在任何上传前调用）。返回 true 表示须走分块路径。
  ///
  /// 先逐层按单纹理折叠布局纹素数/纹理边长约束检查，全部通过返回
  /// false（单纹理路径）；任一层超出则做整链分块规划模拟（含残差
  /// forceOutHeights 对齐与 pool 奇偶约束），不可行抛
  /// [UnsupportedError]（调用方应回退 CPU）。[debugForceBanded] 时跳
  /// 过单纹理检查直接模拟。
  bool _requireChainSupported(int h0, int w0) {
    if (!debugForceBanded) {
      var h = h0, w = w0, cinP = 4;
      var single = true;
      // stem：conv1 s2(3→32) → conv2(32→32) → conv3(32→64) → avgpool。
      final stemOut = [32, 32, 64];
      for (var i = 0; i < 3; i++) {
        final oh = i == 0 ? (h + 1) ~/ 2 : h;
        final ow = i == 0 ? (w + 1) ~/ 2 : w;
        if (!_sizeOk(2 * (cinP ~/ 4) * h * w) ||
            !_sizeOk(2 * (stemOut[i] ~/ 4) * oh * ow)) {
          single = false;
          break;
        }
        h = oh;
        w = ow;
        cinP = stemOut[i];
      }
      if (single) {
        h ~/= 2;
        w ~/= 2;
        for (var li = 0; li < _layerConfig.length && single; li++) {
          final (planes, blockCount, stride) = _layerConfig[li];
          for (var bi = 0; bi < blockCount; bi++) {
            final s = bi == 0 ? stride : 1;
            // conv1(in→p) → conv2(p→p) → [avgpool] → conv3(p→4p)。
            if (!_sizeOk(2 * (cinP ~/ 4) * h * w) ||
                !_sizeOk(2 * (planes ~/ 4) * h * w)) {
              single = false;
              break;
            }
            var hh = h, ww = w;
            if (s > 1) {
              hh ~/= 2;
              ww ~/= 2;
            }
            if (!_sizeOk(2 * planes * hh * ww)) {
              // conv3 输出 2*(4p/4)*hh*ww
              single = false;
              break;
            }
            h = hh;
            w = ww;
            cinP = 4 * planes;
          }
        }
      }
      if (single) return false;
    }
    _requireBandedSupported(h0, w0);
    return true;
  }

  /// 整链分块规划模拟（与分块执行共用 [GpuNnBackend] 的规划函数，结果
  /// 一致）：含 stitch 覆盖 ≤3、pool 奇偶与残差强制分块校验。不可行
  /// 抛 [UnsupportedError]。
  void _requireBandedSupported(int h0, int w0) {
    String err(String what) => 'ClipRn50Gpu: ${h0}x$w0 输入分块路径不可行'
        '（$what）（调用方应回退 CPU）';
    var heights = GpuNnBackend.planBandHeights(h0, w0, 4);
    if (heights == null) throw UnsupportedError(err('输入上传 $h0 x$w0'));
    var h = h0, w = w0;
    // stem conv1 s2（3→32）。
    heights = GpuNnBackend.planConvOutBands(heights, h, w, 4, 32, stride: 2);
    if (heights == null) throw UnsupportedError(err('stem conv1 s2'));
    h = (h + 1) ~/ 2;
    w = (w + 1) ~/ 2;
    // stem conv2/conv3（32→32→64）与 avgpool。
    heights = GpuNnBackend.planConvOutBands(heights, h, w, 32, 64);
    if (heights == null) throw UnsupportedError(err('stem conv3'));
    heights = GpuNnBackend.poolBandsMax(heights);
    if (heights == null) throw UnsupportedError(err('stem avgpool 奇偶约束'));
    h ~/= 2;
    w ~/= 2;
    var inP = 64;
    for (var li = 0; li < _layerConfig.length; li++) {
      final (planes, blockCount, stride) = _layerConfig[li];
      final outP = 4 * planes;
      for (var bi = 0; bi < blockCount; bi++) {
        final s = bi == 0 ? stride : 1;
        final hasDs = bi == 0;
        // 主路径：conv1(in→p，1x1 无 halo) → conv2(p→p，分块沿用) →
        // [avgpool]。
        var mH = GpuNnBackend.planConvOutBands(heights!, h, w, inP, planes,
            noHalo: true);
        if (mH == null) {
          throw UnsupportedError(err('layer${li + 1}.$bi conv1'));
        }
        var hh = h, ww = w;
        if (s > 1) {
          mH = GpuNnBackend.poolBandsMax(mH);
          if (mH == null) {
            throw UnsupportedError(
                err('layer${li + 1}.$bi avgpool 奇偶约束'));
          }
          hh ~/= 2;
          ww ~/= 2;
        }
        // identity 分块：无 downsample 即块输入本身；有 downsample 时先
        // avgpool（同主路径的池化规则）再按 1x1 投影规划。
        List<int>? idH;
        if (hasDs) {
          List<int>? xH = heights;
          if (s > 1) {
            xH = GpuNnBackend.poolBandsMax(xH);
            if (xH == null) {
              throw UnsupportedError(
                  err('layer${li + 1}.$bi downsample avgpool 奇偶约束'));
            }
          }
          idH = GpuNnBackend.planConvOutBands(xH, hh, ww, inP, outP,
              noHalo: true);
          if (idH == null) {
            throw UnsupportedError(err('layer${li + 1}.$bi downsample'));
          }
        } else {
          idH = heights;
        }
        // conv3（p→4p，1x1 无 halo）强制输出分块 = identity 分块（残差
        // addRelu 对齐）。
        mH = GpuNnBackend.planConvOutBands(mH, hh, ww, planes, outP,
            forceOutHeights: idH, noHalo: true);
        if (mH == null) {
          throw UnsupportedError(
              err('layer${li + 1}.$bi conv3 残差分块对齐'));
        }
        heights = mH;
        h = hh;
        w = ww;
        inP = outP;
      }
    }
  }

  /// GPU 驻留主干前向：输入上传一次 → stem + 16 Bottleneck 全部驻留执
  /// 行 → 回读 [1, 2048, h′, w′]（h′/w′ 为 5 次折半后的尺寸）。任何一
  /// 步失败抛异常（中间纹理在抛出前释放），调用方整链回退 CPU。
  Future<NnTensor> forwardTrunk(NnTensor x) {
    if (x.rank != 4 || x.batch != 1 || x.channels != 3) {
      throw ArgumentError('ClipRn50Gpu.forwardTrunk 需要 [1,3,H,W] 输入，'
          '得到 $x');
    }
    return _requireChainSupported(x.height, x.width)
        ? _forwardBanded(x)
        : _forwardSingle(x);
  }

  /// 单纹理路径。
  Future<NnTensor> _forwardSingle(NnTensor x) async {
    var h = await _backend.uploadFeatureMap(x);
    final yielder = GpuDispatchYield(); // 层间让出（优化 6，纯调度）
    try {
      for (var i = 0; i < 3; i++) {
        final conv = _backend.conv2dGpu(h, _stem[i], stride: i == 0 ? 2 : 1);
        h.dispose();
        final act = _backend.reluGpu(conv);
        conv.dispose();
        h = act;
        await yielder.tick();
      }
      final pooled = _backend.avgPool2x2Gpu(h);
      h.dispose();
      h = pooled;
      for (final blk in _blocks) {
        final nb = _blockSingle(h, blk);
        h.dispose();
        h = nb;
        await yielder.tick();
      }
    } catch (_) {
      h.dispose();
      rethrow;
    }
    try {
      final out = await _backend.downloadFeatureMap(h, channels: 2048);
      return out;
    } finally {
      h.dispose();
    }
  }

  /// 单纹理 Bottleneck：conv1→relu→conv2→relu→[avgpool]→conv3，与
  /// identity（直连或 [avgpool]+downsample）addRelu。返回新纹理；
  /// 输入 [x] 由调用方释放。
  GpuNnTensor _blockSingle(GpuNnTensor x, _GpuBlock blk) {
    var out = _backend.reluGpu(_backend.conv2dGpu(x, blk.c1));
    var t = _backend.reluGpu(_backend.conv2dGpu(out, blk.c2));
    out.dispose();
    out = t;
    if (blk.stride > 1) {
      t = _backend.avgPool2x2Gpu(out);
      out.dispose();
      out = t;
    }
    t = _backend.conv2dGpu(out, blk.c3);
    out.dispose();
    out = t;
    final GpuNnTensor identity;
    final GpuNnTensor? idOwned;
    if (blk.ds != null) {
      var id = x;
      if (blk.stride > 1) {
        id = _backend.avgPool2x2Gpu(x);
      }
      identity = _backend.conv2dGpu(id, blk.ds!);
      idOwned = identical(id, x) ? null : id;
    } else {
      identity = x;
      idOwned = null;
    }
    final res = _backend.addReluGpu(out, identity);
    out.dispose();
    idOwned?.dispose();
    return res;
  }

  /// 分块路径（大图：折叠布局总纹素数超单纹理上限时由 [forwardTrunk]
  /// 选择）：语义与单纹理路径完全一致，各 op 换用 banded 变体。
  Future<NnTensor> _forwardBanded(NnTensor x) async {
    var h = await _backend.uploadFeatureMapBanded(x);
    final yielder = GpuDispatchYield(); // 层间让出（优化 6，纯调度）
    try {
      for (var i = 0; i < 3; i++) {
        final conv =
            _backend.conv2dGpuBanded(h, _stem[i], stride: i == 0 ? 2 : 1);
        h.dispose();
        final act = _backend.reluGpuBanded(conv);
        conv.dispose();
        h = act;
        await yielder.tick();
      }
      final pooled = _backend.avgPool2x2GpuBanded(h);
      h.dispose();
      h = pooled;
      for (final blk in _blocks) {
        final nb = _blockBanded(h, blk);
        h.dispose();
        h = nb;
        await yielder.tick();
      }
    } catch (_) {
      h.dispose();
      rethrow;
    }
    try {
      final out =
          await _backend.downloadFeatureMapBanded(h, channels: 2048);
      return out;
    } finally {
      h.dispose();
    }
  }

  /// 分块 Bottleneck：conv3 以 forceOutHeights 对齐 identity 分块后
  /// addRelu；conv1/conv3/downsample 为 1x1（noHalo，halo 行权重恒
  /// 零）。返回新分块张量；输入 [x] 由调用方释放。
  GpuNnBandedTensor _blockBanded(GpuNnBandedTensor x, _GpuBlock blk) {
    var out = _backend.reluGpuBanded(
        _backend.conv2dGpuBanded(x, blk.c1, noHalo: true));
    var t = _backend.reluGpuBanded(_backend.conv2dGpuBanded(out, blk.c2));
    out.dispose();
    out = t;
    if (blk.stride > 1) {
      t = _backend.avgPool2x2GpuBanded(out);
      out.dispose();
      out = t;
    }
    final GpuNnBandedTensor identity;
    final GpuNnBandedTensor? idOwned;
    if (blk.ds != null) {
      var id = x;
      if (blk.stride > 1) {
        id = _backend.avgPool2x2GpuBanded(x);
      }
      identity = _backend.conv2dGpuBanded(id, blk.ds!, noHalo: true);
      idOwned = identical(id, x) ? null : id;
    } else {
      identity = x;
      idOwned = null;
    }
    t = _backend.conv2dGpuBanded(out, blk.c3,
        forceOutHeights: identity.bandHeights, noHalo: true);
    out.dispose();
    out = t;
    final res = _backend.addReluGpuBanded(out, identity);
    out.dispose();
    idOwned?.dispose();
    return res;
  }
}
