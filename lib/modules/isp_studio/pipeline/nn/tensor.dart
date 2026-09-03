/// NCHW 张量轻封装：Float32List + shape（纯 Dart，无 Flutter 依赖）。
library;

import 'dart:typed_data';

/// 轻量张量：行主序（C 序）fp32 数据 + 任意维 shape。
///
/// 图像算子约定输入为 4 维 NCHW（batch 维参与运算，不恒为 1），
/// 矩阵算子用 2 维 / 3 维（batchMatmul）。
class NnTensor {
  NnTensor(this.data, List<int> shape)
      : shape = List<int>.unmodifiable(shape) {
    var numel = shape.isEmpty ? 1 : 1;
    for (final d in shape) {
      if (d < 0) {
        throw ArgumentError('shape 含负数维: $shape');
      }
      numel *= d;
    }
    if (numel != data.length) {
      throw ArgumentError('shape $shape 的元素数 $numel 与数据长度 '
          '${data.length} 不符');
    }
  }

  factory NnTensor.zeros(List<int> shape) {
    var numel = 1;
    for (final d in shape) {
      numel *= d;
    }
    return NnTensor(Float32List(numel), shape);
  }

  final Float32List data;
  final List<int> shape;

  int get rank => shape.length;
  int get numel => data.length;

  /// 4 维 NCHW 快捷访问。
  int get batch => shape[0];
  int get channels => shape[1];
  int get height => shape[2];
  int get width => shape[3];

  @override
  String toString() => 'NnTensor($shape)';
}
