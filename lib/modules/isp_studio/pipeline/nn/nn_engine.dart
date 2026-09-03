/// NN 推理后端抽象（纯 Dart，无 Flutter 依赖）。
///
/// [NnBackend] 声明重计算算子接口，便于以后扩展 GPU 后端；
/// [CpuNnBackend] 为默认实现，直接调用 ops.dart 中的纯函数。
library;

import 'dart:typed_data';

import 'gemm.dart';
import 'ops.dart' as ops;
import 'tensor.dart';

/// 推理后端接口：声明重计算算子（conv2d/gemm/linear/matmul 等）。
abstract class NnBackend {
  /// torch F.conv2d（NCHW，见 ops.conv2d）。
  NnTensor conv2d(
    NnTensor x,
    NnTensor weight, {
    Float32List? bias,
    int strideH = 1,
    int strideW = 1,
    int padH = 0,
    int padW = 0,
    int groups = 1,
  });

  /// C[M,N] = alpha·op(A)·op(B) + beta·C（[c] 缺省时新建）。
  Float32List gemm(
    Float32List a,
    Float32List b,
    int m,
    int n,
    int k, {
    bool transA = false,
    bool transB = false,
    double alpha = 1.0,
    double beta = 0.0,
    Float32List? c,
  });

  /// torch F.linear：y = x @ weightᵀ + bias。
  NnTensor linear(NnTensor x, NnTensor weight, {Float32List? bias});

  /// [M,K] × [K,N]。
  NnTensor matmul(NnTensor a, NnTensor b);

  /// [B,M,K] × [B,K,N]（attention 用）。
  NnTensor batchMatmul(NnTensor a, NnTensor b);

  NnTensor relu(NnTensor x);

  /// 精确 erf 版 GELU。
  NnTensor gelu(NnTensor x);

  NnTensor maxPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
      int strideW, int padH, int padW);

  NnTensor avgPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
      int strideW, int padH, int padW,
      {bool countIncludePad = true});

  NnTensor layerNorm(NnTensor x, List<int> normalizedShape,
      Float32List? weight, Float32List? bias,
      {double eps = 1e-5});

  NnTensor groupNorm(NnTensor x, int groups, Float32List? weight,
      Float32List? bias,
      {double eps = 1e-5});

  /// 沿最后一维 softmax。
  NnTensor softmax(NnTensor x);

  NnTensor resizeBilinear(NnTensor x, int outH, int outW);

  NnTensor resizeBicubic(NnTensor x, int outH, int outW);
}

/// 默认 CPU 后端：直接调用 ops.dart 的同步纯函数。
class CpuNnBackend implements NnBackend {
  const CpuNnBackend();

  @override
  NnTensor conv2d(
    NnTensor x,
    NnTensor weight, {
    Float32List? bias,
    int strideH = 1,
    int strideW = 1,
    int padH = 0,
    int padW = 0,
    int groups = 1,
  }) =>
      ops.conv2d(x, weight,
          bias: bias,
          strideH: strideH,
          strideW: strideW,
          padH: padH,
          padW: padW,
          groups: groups);

  @override
  Float32List gemm(
    Float32List a,
    Float32List b,
    int m,
    int n,
    int k, {
    bool transA = false,
    bool transB = false,
    double alpha = 1.0,
    double beta = 0.0,
    Float32List? c,
  }) {
    final out = c ?? Float32List(m * n);
    sgemm(a, b, out, m, n, k,
        transA: transA, transB: transB, alpha: alpha, beta: beta);
    return out;
  }

  @override
  NnTensor linear(NnTensor x, NnTensor weight, {Float32List? bias}) =>
      ops.linear(x, weight, bias: bias);

  @override
  NnTensor matmul(NnTensor a, NnTensor b) => ops.matmul(a, b);

  @override
  NnTensor batchMatmul(NnTensor a, NnTensor b) => ops.batchMatmul(a, b);

  @override
  NnTensor relu(NnTensor x) => ops.relu(x);

  @override
  NnTensor gelu(NnTensor x) => ops.gelu(x);

  @override
  NnTensor maxPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
          int strideW, int padH, int padW) =>
      ops.maxPool2d(x, kernelH, kernelW, strideH, strideW, padH, padW);

  @override
  NnTensor avgPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
          int strideW, int padH, int padW,
          {bool countIncludePad = true}) =>
      ops.avgPool2d(x, kernelH, kernelW, strideH, strideW, padH, padW,
          countIncludePad: countIncludePad);

  @override
  NnTensor layerNorm(NnTensor x, List<int> normalizedShape,
          Float32List? weight, Float32List? bias,
          {double eps = 1e-5}) =>
      ops.layerNorm(x, normalizedShape, weight, bias, eps: eps);

  @override
  NnTensor groupNorm(NnTensor x, int groups, Float32List? weight,
          Float32List? bias,
          {double eps = 1e-5}) =>
      ops.groupNorm(x, groups, weight, bias, eps: eps);

  @override
  NnTensor softmax(NnTensor x) => ops.softmax(x);

  @override
  NnTensor resizeBilinear(NnTensor x, int outH, int outW) =>
      ops.resizeBilinear(x, outH, outW);

  @override
  NnTensor resizeBicubic(NnTensor x, int outH, int outW) =>
      ops.resizeBicubic(x, outH, outW);
}
