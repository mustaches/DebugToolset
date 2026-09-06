/// VGG16 主干的 GPU 纹理驻留前向（LPIPS/DISTS 共用，对应
/// [Vgg16Dart.forward] 的 GPU 版）。
///
/// 权重在 [load] 时上传一次（13 个 conv3x3 的 fp16 打包纹理，含偏置）；
/// [forward] 把输入特征图上传一次，随后 13 conv(+relu) + 4 pool（LPIPS
/// 的 MaxPool2x2 或 DISTS 的 L2pooling）全部 GPU 驻留执行，只在 5 个
/// 切片特征处回读（fp16 解码 Float32List NCHW，与 CPU 版切片同构）。
///
/// 限制与回退：仅 UI isolate 可用（[GpuNnBackend] 依赖 dart:ui）。
/// 折叠布局单纹理受纹素数 < 2^24 约束；超出时整链切换**分块路径**
/// （沿 H 切带、每带一张纹理，halo 经 stitch shader 拼接，见
/// [GpuNnBackend] 库注释）；逐层按实际池化类型做分块规划预检
/// （[_requireChainSupported]），任何一层不可行即抛
/// [UnsupportedError]，由调用方整链回退 CPU（不做半 GPU 半 CPU 混合）。
/// fp16 精度：逐层 relToRms 与端到端 LPIPS/DISTS 对拍记录见
/// test/isp_nn_gpu_vgg_test.dart。
library;

import 'package:flutter/foundation.dart';

import '../nn/nn_gpu.dart';
import '../nn/nn_gpu_pack.dart' as pack;
import '../nn/tensor.dart';
import 'vgg16_dart.dart';

/// GPU 纹理驻留的 VGG16 前向（实现 [Vgg16AsyncForward]）。
class Vgg16Gpu implements Vgg16AsyncForward {
  Vgg16Gpu._(this._backend, this._convW, this._cin);

  final GpuNnBackend _backend;

  /// 13 个 conv 的 GPU 驻留权重（按 [Vgg16Dart.convIndices] 顺序）。
  final List<GpuConvWeights> _convW;

  /// 各 conv 的输入通道数（未填充）。
  final List<int> _cin;

  /// 池化出现在这些 conv 索引之前（同 Vgg16Dart 的层序）。
  static const _poolBefore = {5, 10, 17, 24};

  /// 切片特征在这些 conv（relu 后）截取：relu1_2..relu5_3。
  static const _sliceAfter = {2, 7, 14, 21, 28};

  /// 测试用：true 时跳过单纹理预检、强制走分块路径（配合
  /// [GpuNnBackend.debugMaxBandTexels] 使小尺寸也能验证分块链）。
  /// 生产代码勿动。
  static bool debugForceBanded = false;

  /// 从 .nnw 加载 13 个 conv 的 weight+bias 并上传为 GPU 驻留纹理。
  /// 读取与 fp16 打包整网一次 compute 在后台 isolate 完成（避免 UI
  /// isolate 同步大循环卡死，见 nn_gpu_pack.dart），UI 侧仅上传纹理。
  /// 任一失败抛异常（已上传的权重随之释放），调用方回退 CPU。
  static Future<Vgg16Gpu> load(GpuNnBackend backend, String nnwPath) async {
    final packed =
        await compute(pack.packVgg16Weights, (nnwPath, Vgg16Dart.convIndices));
    final convW = <GpuConvWeights>[];
    try {
      for (final p in packed.convs) {
        convW.add(await backend.uploadPackedConvWeights(p));
      }
      return Vgg16Gpu._(backend, convW, packed.cin);
    } catch (_) {
      for (final w in convW) {
        w.dispose();
      }
      rethrow;
    }
  }

  /// 释放全部 GPU 驻留权重纹理（backend 本身由持有方管理）。
  void dispose() {
    for (final w in _convW) {
      w.dispose();
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
  /// 先逐层按单纹理折叠布局纹素数/纹理边长约束检查（池化按 L2pooling
  /// 的较大输出尺寸 floor((H+1)/2) 取上界），全部通过返回 false（单纹
  /// 理路径，行为与旧版一致）；任一层超出则按 [useL2Pooling] 对应的池
  /// 化类型做整链分块规划模拟（[debugForceBanded] 时跳过单纹理检查直
  /// 接模拟），不可行抛 [UnsupportedError]（调用方应回退 CPU）。
  bool _requireChainSupported(int h0, int w0, {required bool useL2Pooling}) {
    if (!debugForceBanded) {
      var h = h0, w = w0;
      var single = true;
      for (var i = 0; i < Vgg16Dart.convIndices.length; i++) {
        final idx = Vgg16Dart.convIndices[i];
        if (_poolBefore.contains(idx)) {
          h = (h + 1) ~/ 2;
          w = (w + 1) ~/ 2;
        }
        final cinP = (_cin[i] + 3) & ~3;
        final coutP = _convW[i].coutPadded;
        if (!_sizeOk(2 * (cinP ~/ 4) * h * w) ||
            !_sizeOk(2 * (coutP ~/ 4) * h * w)) {
          single = false;
          break;
        }
      }
      if (single) return false;
    }
    _requireBandedSupported(h0, w0, useL2Pooling: useL2Pooling);
    return true;
  }

  /// 整链分块规划模拟（与分块执行共用 [GpuNnBackend] 的规划函数，结果
  /// 一致）：含 stitch 覆盖 ≤3 与 maxpool 奇偶约束。不可行抛
  /// [UnsupportedError]。
  void _requireBandedSupported(int h0, int w0,
      {required bool useL2Pooling}) {
    String err(String what) => 'Vgg16Gpu: ${h0}x$w0 输入分块路径不可行（$what）'
        '（调用方应回退 CPU）';
    var heights = GpuNnBackend.planBandHeights(h0, w0, 4);
    if (heights == null) throw UnsupportedError(err('输入上传 $h0 x$w0'));
    var h = h0, w = w0;
    for (var i = 0; i < Vgg16Dart.convIndices.length; i++) {
      final idx = Vgg16Dart.convIndices[i];
      if (_poolBefore.contains(idx)) {
        heights = useL2Pooling
            ? GpuNnBackend.poolBandsL2(heights!)
            : GpuNnBackend.poolBandsMax(heights!);
        if (heights == null) {
          throw UnsupportedError(err('maxpool 奇偶约束（${h}x$w）'));
        }
        h = useL2Pooling ? (h + 1) ~/ 2 : h ~/ 2;
        w = useL2Pooling ? (w + 1) ~/ 2 : w ~/ 2;
      }
      final cinP = (_cin[i] + 3) & ~3;
      final coutP = _convW[i].coutPadded;
      heights = GpuNnBackend.planConvOutBands(heights!, h, w, cinP, coutP);
      if (heights == null) {
        throw UnsupportedError(err('conv 层 features.$idx'
            '（${h}x$w ${_cin[i]}→${_convW[i].cout}）'));
      }
    }
  }

  /// GPU 驻留前向：输入上传一次 → 13 conv(+relu) + 4 pool 全部驻留执行
  /// → 只在 5 个切片特征处回读。任何一步失败抛异常（已创建的中间纹理
  /// 在抛出前释放），调用方整链回退 CPU。
  @override
  Future<List<NnTensor>> forward(NnTensor x,
      {bool useL2Pooling = false}) async {
    if (x.rank != 4 || x.batch != 1 || x.channels != 3) {
      throw ArgumentError('Vgg16Gpu.forward 需要 [1,3,H,W] 输入，得到 $x');
    }
    if (_requireChainSupported(x.height, x.width,
        useL2Pooling: useL2Pooling)) {
      return _forwardBanded(x, useL2Pooling: useL2Pooling);
    }
    final slices = <GpuNnTensor>[];
    var h = await _backend.uploadFeatureMap(x);
    final yielder = GpuDispatchYield(); // 层间让出（优化 6，纯调度）
    try {
      for (var i = 0; i < Vgg16Dart.convIndices.length; i++) {
        final idx = Vgg16Dart.convIndices[i];
        if (_poolBefore.contains(idx)) {
          final pooled = useL2Pooling
              ? _backend.l2PoolDistsGpu(h)
              : _backend.maxPool2x2Gpu(h);
          h.dispose();
          h = pooled;
        }
        final conv = _backend.conv2dGpu(h, _convW[i]);
        h.dispose();
        final act = _backend.reluGpu(conv);
        conv.dispose();
        h = act;
        if (_sliceAfter.contains(idx)) {
          // 切片处再过一个 relu pass 复制一份（relu 幂等，值不变），
          // 使切片与继续前向的 h 各自独立持有纹理、互不污染。
          slices.add(_backend.reluGpu(h));
        }
        await yielder.tick();
      }
    } catch (_) {
      h.dispose();
      for (final s in slices) {
        s.dispose();
      }
      rethrow;
    }
    h.dispose();
    try {
      final out = <NnTensor>[];
      for (var i = 0; i < slices.length; i++) {
        out.add(await _backend.downloadFeatureMap(slices[i]));
      }
      return out;
    } finally {
      for (final s in slices) {
        s.dispose();
      }
    }
  }

  /// 分块路径前向（大图：折叠布局总纹素数超单纹理上限时由 [forward]
  /// 选择）：语义与单纹理路径完全一致，各 op 换用 banded 变体。
  Future<List<NnTensor>> _forwardBanded(NnTensor x,
      {required bool useL2Pooling}) async {
    final slices = <GpuNnBandedTensor>[];
    var h = await _backend.uploadFeatureMapBanded(x);
    final yielder = GpuDispatchYield(); // 层间让出（优化 6，纯调度）
    try {
      for (var i = 0; i < Vgg16Dart.convIndices.length; i++) {
        final idx = Vgg16Dart.convIndices[i];
        if (_poolBefore.contains(idx)) {
          final pooled = useL2Pooling
              ? _backend.l2PoolDistsGpuBanded(h)
              : _backend.maxPool2x2GpuBanded(h);
          h.dispose();
          h = pooled;
        }
        final conv = _backend.conv2dGpuBanded(h, _convW[i]);
        h.dispose();
        final act = _backend.reluGpuBanded(conv);
        conv.dispose();
        h = act;
        if (_sliceAfter.contains(idx)) {
          // 同单纹理路径：切片处再过一个 relu pass 复制一份。
          slices.add(_backend.reluGpuBanded(h));
        }
        await yielder.tick();
      }
    } catch (_) {
      h.dispose();
      for (final s in slices) {
        s.dispose();
      }
      rethrow;
    }
    h.dispose();
    try {
      final out = <NnTensor>[];
      for (var i = 0; i < slices.length; i++) {
        out.add(await _backend.downloadFeatureMapBanded(slices[i]));
      }
      return out;
    } finally {
      for (final s in slices) {
        s.dispose();
      }
    }
  }
}
