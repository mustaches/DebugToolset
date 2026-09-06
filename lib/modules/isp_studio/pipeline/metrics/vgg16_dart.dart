/// VGG16 主干前向（torchvision vgg16 features 的 13 个 3×3 conv），
/// LPIPS / DISTS 共用的特征提取器（纯 Dart，无 Flutter 依赖）。
///
/// 层序与 torchvision 一致：conv(3×3,s1,p1,bias)+relu 交替，索引
/// 4/9/16/23 处为池化——LPIPS 用 MaxPool2(k2,s2)，DISTS 用 L2pooling
/// （ops.l2PoolingDists，stride2/pad1，奇数尺寸输出 floor((H+1)/2)，
/// 与 maxpool 的 floor(H/2) 不同）。返回 5 个切片特征：relu1_2
/// （索引 3 后）、relu2_2（8 后）、relu3_3（15 后）、relu4_3（22 后）、
/// relu5_3（29 后）。
///
/// 权重从 .nnw 读取（tools/iqa/weights/vgg16.nnw，键
/// features.{0,2,5,7,10,12,14,17,19,21,24,26,28}.weight/.bias）。
/// [forward] 为单线程同步版；[forwardParallel] 走 NnPool 的
/// parallelConv2d 多 isolate 并行，与同步版位级一致（见 nn_pool.dart）。
library;

import 'dart:typed_data';

import '../nn/nn_pool.dart';
import '../nn/nnw_reader.dart';
import '../nn/ops.dart' as ops;
import '../nn/tensor.dart';

/// VGG16（features 部分）前向，输出 5 个切片特征。
class Vgg16Dart {
  Vgg16Dart._(this._weights, this._biases);

  /// 从 .nnw 文件加载 13 个 conv 的 weight+bias。
  factory Vgg16Dart.load(String nnwPath) {
    final reader = NnwReader.open(nnwPath);
    try {
      final weights = <NnTensor>[];
      final biases = <Float32List>[];
      for (final idx in convIndices) {
        weights.add(reader.readTensor('features.$idx.weight'));
        biases.add(reader.tensor('features.$idx.bias').$1);
      }
      return Vgg16Dart._(weights, biases);
    } finally {
      reader.close();
    }
  }

  /// conv 层在 torchvision features 序列中的索引（其余为 relu/池化）。
  static const convIndices = [0, 2, 5, 7, 10, 12, 14, 17, 19, 21, 24, 26, 28];

  /// 池化出现在这些 conv 索引之前（features 的 4/9/16/23）。
  static const _poolBefore = {5, 10, 17, 24};

  /// 切片特征在这些 conv（relu 后）截取：relu1_2..relu5_3。
  static const _sliceAfter = {2, 7, 14, 21, 28};

  final List<NnTensor> _weights;
  final List<Float32List> _biases;

  /// 单线程同步前向。[x] 为 [1,3,H,W]；[useL2Pooling] 为 true 时把
  /// 4 个 MaxPool 替换为 DISTS 的 L2pooling。返回 relu1_2..relu5_3
  /// 共 5 个特征（按由浅到深顺序）。
  List<NnTensor> forward(NnTensor x, {bool useL2Pooling = false}) {
    if (x.rank != 4 || x.channels != 3) {
      throw ArgumentError('Vgg16Dart.forward 需要 [N,3,H,W] 输入，得到 $x');
    }
    final feats = <NnTensor>[];
    var h = x;
    for (var i = 0; i < convIndices.length; i++) {
      final idx = convIndices[i];
      if (_poolBefore.contains(idx)) {
        h = useL2Pooling
            ? ops.l2PoolingDists(h)
            : ops.maxPool2d(h, 2, 2, 2, 2, 0, 0);
      }
      h = ops.conv2d(h, _weights[i],
          bias: _biases[i], strideH: 1, strideW: 1, padH: 1, padW: 1);
      h = ops.relu(h);
      if (_sliceAfter.contains(idx)) {
        feats.add(h);
      }
    }
    return feats;
  }

  /// NnPool 并行前向（conv 走 parallelConv2d），结果与 [forward]
  /// 位级一致。
  Future<List<NnTensor>> forwardParallel(NnTensor x, NnPool pool,
      {bool useL2Pooling = false}) async {
    if (x.rank != 4 || x.channels != 3) {
      throw ArgumentError(
          'Vgg16Dart.forwardParallel 需要 [N,3,H,W] 输入，得到 $x');
    }
    final feats = <NnTensor>[];
    var h = x;
    for (var i = 0; i < convIndices.length; i++) {
      final idx = convIndices[i];
      if (_poolBefore.contains(idx)) {
        h = useL2Pooling
            ? ops.l2PoolingDists(h)
            : ops.maxPool2d(h, 2, 2, 2, 2, 0, 0);
      }
      h = await pool.parallelConv2d(h, _weights[i],
          bias: _biases[i], strideH: 1, strideW: 1, padH: 1, padW: 1);
      h = ops.relu(h);
      if (_sliceAfter.contains(idx)) {
        feats.add(h);
      }
    }
    return feats;
  }
}

/// 两阶段前向（优化 11：双图流水线）的句柄基类：持有
/// [Vgg16AsyncForward.forwardSubmit] 已提交的 GPU 驻留切片纹理，供
/// [Vgg16AsyncForward.forwardDownload] 回读。定义为纯 Dart 空基类以
/// 保持本文件无 Flutter 依赖；实现侧（vgg16_gpu.dart）才携带
/// GpuNnTensor 等 dart:ui 类型。
abstract class Vgg16ForwardHandle {
  const Vgg16ForwardHandle();
}

/// VGG16 前向的异步抽象（GPU 纹理驻留实现见 vgg16_gpu.dart）。定义为
/// 纯 Dart 接口，以保持本文件（及 lpips_dart/dists_dart）无 Flutter
/// 依赖、可在后台 isolate 加载；实现侧才引入 dart:ui。
abstract class Vgg16AsyncForward {
  /// 全局静态开关：false 时调用方应直接使用 CPU 路径。
  /// 默认 true 的依据（test/isp_nn_gpu_vgg_test.dart 与
  /// scratch/nn_gpu_vgg_bench_main.dart 实测）：逐层切片 relToRms
  /// 0.005~0.018；256×192 busyFrame 端到端分数 vs Python 基线相对偏差
  /// LPIPS 7.8e-6、DISTS 7.7e-5（均远小于 1e-3）。
  static bool enabled = true;

  /// 与 [Vgg16Dart.forward] 同构的异步前向：输入 [1,3,H,W]，返回
  /// relu1_2..relu5_3 共 5 个特征。任何一步不支持/失败都应抛异常，
  /// 由调用方整链回退 CPU。等价于 [forwardSubmit] + [forwardDownload]
  /// 顺序调用（无流水线重叠）。
  Future<List<NnTensor>> forward(NnTensor x, {bool useL2Pooling = false});

  /// 两阶段前向（优化 11）——提交阶段：上传输入并链式提交全部 GPU
  /// pass（中间纹理照旧即弃），返回持有 5 个切片驻留纹理的句柄，不
  /// 等待回读。配对调用方按 submit0→submit1→download0→download1 编排
  /// 时，图 1 的 CPU 下载/解包与图 2 的 GPU 光栅化在时间轴上重叠；
  /// 每图的计算序列与 [forward] 完全相同（数值逐位一致）。任何一步
  /// 不支持/失败抛异常（实现侧已释放中间纹理），由调用方整链回退
  /// CPU；成功返回的句柄必须由 [forwardDownload] 或 [discardForward]
  /// 消费，否则切片纹理泄漏。
  Future<Vgg16ForwardHandle> forwardSubmit(NnTensor x,
      {bool useL2Pooling = false});

  /// 两阶段前向——下载阶段：逐切片回读并释放句柄持有的全部驻留纹理
  /// （下载中途失败同样全部释放）。返回 relu1_2..relu5_3 共 5 个特征，
  /// 与 [forward] 逐位一致。
  Future<List<NnTensor>> forwardDownload(Vgg16ForwardHandle handle);

  /// 放弃一个已提交的前向（如配对图的 [forwardSubmit] 失败后清理已
  /// 驻留的那一份）：只释放驻留纹理，不做回读。
  Future<void> discardForward(Vgg16ForwardHandle handle);
}
