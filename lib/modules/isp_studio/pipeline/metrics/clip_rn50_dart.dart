/// CLIP RN50 图像编码器（ModifiedResNet + AttentionPool2d）的进程内
/// Dart 实现，语义忠实于 pyiqa 内置 clip 源码
/// （scratch/eval_venv/Lib/site-packages/pyiqa/archs/clip_model.py）：
///
///   stem：conv1(3→32,k3,s2,p1)→relu→conv2(32→32,k3,s1,p1)→relu→
///         conv3(32→64,k3,s1,p1)→relu→avgPool(k2,s2)
///   layer1..4：Bottleneck（expansion=4）堆叠，(planes,blocks,stride)
///         = (64,3,1) / (128,4,2) / (256,6,2) / (512,3,2)
///   Bottleneck：conv1(1×1)→relu→conv2(3×3,p1,s1)→relu→
///         avgPool(stride)（仅 stride>1）→conv3(1×1,planes→4planes)；
///         downsample（stride>1 或 in≠out 时）= avgPool(stride)（同上，
///         stride==1 时 AvgPool2d(1) 为恒等，省略）→conv(1×1)；
///         out = relu(out + identity)。所有 BN 已在导出权重时折叠进
///         相邻 conv（bias 非空）。
///   AttentionPool2d（pos_embedding=False，不加位置嵌入）：
///         x [1,2048,h,w] → reshape 成 hw 个 2048 维 token，前插全局
///         均值 token（共 L=hw+1 个）→ 32 头自注意力（head_dim=64，
///         scale=64^-0.5，q/k/v 各自独立 Linear(2048→2048) 带 bias）
///         → c_proj Linear(2048→1024) 带 bias → 取第 0 个 token 得
///         [1024] 图像特征（未 L2 归一化）。
///
/// 输入任意分辨率（无 resize），输出维度固定 1024。
/// 权重从 .nnw 读取（tools/iqa/weights/clipiqa_rn50.nnw，键
/// visual.conv{1,2,3}.*、visual.layer{l}.{b}.conv{1,2,3}.*、
/// visual.layer{l}.0.downsample.0.*、visual.attnpool.{q,k,v,c}_proj.*）。
///
/// 纯 Dart（无 Flutter 依赖）。[forward] 为单线程同步版；
/// [forwardParallel] 的 conv 走 NnPool 多 isolate 并行，与同步版
/// 位级一致（同 Vgg16Dart 的惯例）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../nn/nn_pool.dart';
import '../nn/nnw_reader.dart';
import '../nn/ops.dart' as ops;
import '../nn/tensor.dart';

/// conv2d 调用签名（同步版直接绑 ops.conv2d，并行版绑 NnPool 封装）。
typedef _Conv2dFn = NnTensor Function(NnTensor x, NnTensor weight,
    {Float32List? bias, int strideH, int strideW, int padH, int padW});

/// 一个 Bottleneck 的权重（conv1/2/3 必带，downsample 仅每层的 block 0）。
class _Block {
  _Block(this.stride, this.w1, this.b1, this.w2, this.b2, this.w3, this.b3,
      this.dsW, this.dsB);

  final int stride;
  final NnTensor w1, w2, w3;
  final Float32List b1, b2, b3;

  /// downsample 的 1×1 投影权重（null 表示 identity 直连）。
  final NnTensor? dsW;
  final Float32List? dsB;
}

/// AttentionPool2d 权重（q/k/v/c 四个 Linear）。
class _AttnPoolW {
  _AttnPoolW(this.qW, this.qB, this.kW, this.kB, this.vW, this.vB, this.cW,
      this.cB);

  final NnTensor qW, kW, vW, cW;
  final Float32List qB, kB, vB, cB;
}

/// CLIP RN50 图像编码器前向，输出 [1024] 特征（未 L2 归一化）。
class ClipRn50Dart {
  ClipRn50Dart._(this._stem, this._layers, this._attnpool);

  /// 从 .nnw 文件加载全部 visual 权重。
  factory ClipRn50Dart.load(String nnwPath) {
    final reader = NnwReader.open(nnwPath);
    try {
      NnTensor w(String name) => reader.readTensor(name);
      Float32List b(String name) => reader.tensor(name).$1;
      final stem = [
        for (var i = 1; i <= 3; i++) (w('visual.conv$i.weight'), b('visual.conv$i.bias')),
      ];
      final layers = <List<_Block>>[];
      for (var li = 0; li < _layerConfig.length; li++) {
        final (planes, blocks, stride) = _layerConfig[li];
        final lv = li + 1;
        layers.add([
          for (var bi = 0; bi < blocks; bi++)
            _Block(
              bi == 0 ? stride : 1,
              w('visual.layer$lv.$bi.conv1.weight'),
              b('visual.layer$lv.$bi.conv1.bias'),
              w('visual.layer$lv.$bi.conv2.weight'),
              b('visual.layer$lv.$bi.conv2.bias'),
              w('visual.layer$lv.$bi.conv3.weight'),
              b('visual.layer$lv.$bi.conv3.bias'),
              // downsample 仅 block 0：stride>1 或 in≠4·planes。
              bi == 0 ? w('visual.layer$lv.$bi.downsample.0.weight') : null,
              bi == 0 ? b('visual.layer$lv.$bi.downsample.0.bias') : null,
            ),
        ]);
      }
      final ap = _AttnPoolW(
        w('visual.attnpool.q_proj.weight'),
        b('visual.attnpool.q_proj.bias'),
        w('visual.attnpool.k_proj.weight'),
        b('visual.attnpool.k_proj.bias'),
        w('visual.attnpool.v_proj.weight'),
        b('visual.attnpool.v_proj.bias'),
        w('visual.attnpool.c_proj.weight'),
        b('visual.attnpool.c_proj.bias'),
      );
      return ClipRn50Dart._(stem, layers, ap);
    } finally {
      reader.close();
    }
  }

  /// (planes, blocks, stride)，与 ModifiedResNet(layers=[3,4,6,3]) 一致。
  static const _layerConfig = [(64, 3, 1), (128, 4, 2), (256, 6, 2), (512, 3, 2)];

  /// AttentionPool2d 的头数与头维（RN50：width*32//64 = 32 头）。
  static const _heads = 32;
  static const _headDim = 64;
  static const _embedDim = _heads * _headDim; // 2048

  /// stem 三个 conv 的 (weight, bias)。
  final List<(NnTensor, Float32List)> _stem;
  final List<List<_Block>> _layers;
  final _AttnPoolW _attnpool;

  static NnTensor _blockForward(NnTensor x, _Block blk, _Conv2dFn conv) {
    var out = conv(x, blk.w1, bias: blk.b1); // 1×1
    out = ops.relu(out);
    out = conv(out, blk.w2, bias: blk.b2, padH: 1, padW: 1); // 3×3 s1 p1
    out = ops.relu(out);
    // 抗锯齿下采样：stride>1 时在 conv2 之后 avgPool。
    if (blk.stride > 1) {
      out = ops.avgPool2d(out, blk.stride, blk.stride, blk.stride, blk.stride, 0, 0);
    }
    out = conv(out, blk.w3, bias: blk.b3); // 1×1, planes→4planes
    var identity = x;
    if (blk.dsW != null) {
      if (blk.stride > 1) {
        identity = ops.avgPool2d(
            identity, blk.stride, blk.stride, blk.stride, blk.stride, 0, 0);
      }
      identity = conv(identity, blk.dsW!, bias: blk.dsB);
    }
    for (var i = 0; i < out.numel; i++) {
      out.data[i] += identity.data[i];
    }
    return ops.relu(out);
  }

  static Future<NnTensor> _blockForwardP(
      NnTensor x, _Block blk, NnPool pool) async {
    var out = await pool.parallelConv2d(x, blk.w1, bias: blk.b1);
    out = ops.relu(out);
    out = await pool.parallelConv2d(out, blk.w2,
        bias: blk.b2, padH: 1, padW: 1);
    out = ops.relu(out);
    if (blk.stride > 1) {
      out = ops.avgPool2d(out, blk.stride, blk.stride, blk.stride, blk.stride, 0, 0);
    }
    out = await pool.parallelConv2d(out, blk.w3, bias: blk.b3);
    var identity = x;
    if (blk.dsW != null) {
      if (blk.stride > 1) {
        identity = ops.avgPool2d(
            identity, blk.stride, blk.stride, blk.stride, blk.stride, 0, 0);
      }
      identity = await pool.parallelConv2d(identity, blk.dsW!, bias: blk.dsB);
    }
    for (var i = 0; i < out.numel; i++) {
      out.data[i] += identity.data[i];
    }
    return ops.relu(out);
  }

  /// AttentionPool2d 前向（pos_embedding=False）。x 为 [1,2048,h,w]，
  /// 返回第 0 个 token（全局均值 token）经 c_proj 后的 [1024] 特征。
  Float32List _attnPoolForward(NnTensor x) {
    final c = x.channels, hw = x.height * x.width;
    if (c != _embedDim || x.batch != 1) {
      throw ArgumentError('attnpool 需要 [1,$_embedDim,h,w] 输入，得到 $x');
    }
    final l = hw + 1;
    // NCHW → (HW+1)×C 序列，第 0 个 token 为全局均值。
    final seq = NnTensor.zeros([l, c]);
    for (var ch = 0; ch < c; ch++) {
      final base = ch * hw;
      var mean = 0.0;
      for (var i = 0; i < hw; i++) {
        mean += x.data[base + i];
        seq.data[(i + 1) * c + ch] = x.data[base + i];
      }
      seq.data[ch] = mean / hw;
    }
    final q = ops.linear(seq, _attnpool.qW, bias: _attnpool.qB);
    final k = ops.linear(seq, _attnpool.kW, bias: _attnpool.kB);
    final v = ops.linear(seq, _attnpool.vW, bias: _attnpool.vB);
    const scale = 1.0 / 8.0; // head_dim(64)^-0.5
    final ctx = Float32List(l * c);
    // 逐头：qH/kH/vH [L,64]（维度切片连续拷贝），softmax(qH·kHᵀ·scale)·vH。
    final qH = Float32List(l * _headDim);
    final kH = Float32List(l * _headDim);
    final vH = Float32List(l * _headDim);
    final attn = Float32List(l * l);
    final outH = Float32List(l * _headDim);
    for (var h = 0; h < _heads; h++) {
      final off = h * _headDim;
      for (var t = 0; t < l; t++) {
        final row = t * c + off;
        qH.setRange(t * _headDim, (t + 1) * _headDim, q.data, row);
        kH.setRange(t * _headDim, (t + 1) * _headDim, k.data, row);
        vH.setRange(t * _headDim, (t + 1) * _headDim, v.data, row);
      }
      // attn = qH @ kHᵀ * scale（linear 即 x @ weightᵀ），逐行 softmax
      // （torch 等价，减最大值）。
      final scores = ops.linear(
          NnTensor(qH, [l, _headDim]), NnTensor(kH, [l, _headDim]));
      for (var t = 0; t < l; t++) {
        final base = t * l;
        var maxV = double.negativeInfinity;
        for (var i = 0; i < l; i++) {
          final sv = scores.data[base + i] * scale;
          scores.data[base + i] = sv;
          if (sv > maxV) {
            maxV = sv;
          }
        }
        var sum = 0.0;
        for (var i = 0; i < l; i++) {
          final e = math.exp(scores.data[base + i] - maxV);
          attn[base + i] = e;
          sum += e;
        }
        for (var i = 0; i < l; i++) {
          attn[base + i] = attn[base + i] / sum;
        }
      }
      final o = ops.matmul(NnTensor(attn, [l, l]), NnTensor(vH, [l, _headDim]));
      outH.setRange(0, l * _headDim, o.data);
      for (var t = 0; t < l; t++) {
        ctx.setRange(t * c + off, t * c + off + _headDim, outH, t * _headDim);
      }
    }
    final proj =
        ops.linear(NnTensor(ctx, [l, c]), _attnpool.cW, bias: _attnpool.cB);
    return Float32List.fromList(proj.data.sublist(0, proj.shape[1]));
  }

  /// 单线程同步前向。[x] 为已归一化的 [1,3,H,W]，返回 [1024] 特征。
  Float32List forward(NnTensor x) {
    if (x.rank != 4 || x.batch != 1 || x.channels != 3) {
      throw ArgumentError('ClipRn50Dart.forward 需要 [1,3,H,W] 输入，得到 $x');
    }
    var h = ops.conv2d(x, _stem[0].$1,
        bias: _stem[0].$2, strideH: 2, strideW: 2, padH: 1, padW: 1);
    h = ops.relu(h);
    h = ops.conv2d(h, _stem[1].$1, bias: _stem[1].$2, padH: 1, padW: 1);
    h = ops.relu(h);
    h = ops.conv2d(h, _stem[2].$1, bias: _stem[2].$2, padH: 1, padW: 1);
    h = ops.relu(h);
    h = ops.avgPool2d(h, 2, 2, 2, 2, 0, 0);
    for (final layer in _layers) {
      for (final blk in layer) {
        h = _blockForward(h, blk, ops.conv2d);
      }
    }
    return _attnPoolForward(h);
  }

  /// NnPool 并行前向（conv 走 parallelConv2d），结果与 [forward]
  /// 位级一致。
  Future<Float32List> forwardParallel(NnTensor x, NnPool pool) async {
    if (x.rank != 4 || x.batch != 1 || x.channels != 3) {
      throw ArgumentError(
          'ClipRn50Dart.forwardParallel 需要 [1,3,H,W] 输入，得到 $x');
    }
    var h = await pool.parallelConv2d(x, _stem[0].$1,
        bias: _stem[0].$2, strideH: 2, strideW: 2, padH: 1, padW: 1);
    h = ops.relu(h);
    h = await pool.parallelConv2d(h, _stem[1].$1,
        bias: _stem[1].$2, padH: 1, padW: 1);
    h = ops.relu(h);
    h = await pool.parallelConv2d(h, _stem[2].$1,
        bias: _stem[2].$2, padH: 1, padW: 1);
    h = ops.relu(h);
    h = ops.avgPool2d(h, 2, 2, 2, 2, 0, 0);
    for (final layer in _layers) {
      for (final blk in layer) {
        h = await _blockForwardP(h, blk, pool);
      }
    }
    return _attnPoolForward(h);
  }
}
