/// MUSIQ（Multi-scale Image Quality Transformer，koniq10k 权重）的
/// 进程内 Dart 实现，语义忠实于 pyiqa 的 MUSIQ
/// （scratch/eval_venv/Lib/site-packages/pyiqa/archs/musiq_arch.py +
/// data/multiscale_trans_util.py）：
///
///   x = RGBA→[0,1] RGB（NCHW [1,3,H,W]）→ (x−0.5)*2（[-1,1]）
///   多尺度切 patch（get_multiscale_patches）：3 个尺度——长边 224、
///     384（bicubic align_corners=False，rh/rw 用 Python round 即
///     round-half-even）、原始分辨率；每尺度 SAME 零填充后按 32×32
///     stride 32 切 patch（unfold 顺序：位置行主序，patch 内
///     [C][H][W] 展平为 3072 维）；224/384 尺度一律 pad/cut 到
///     max_seq_len=49/144（截断取前 N 个，不足补零行：hse/scale/
///     mask 全 0），原始尺度不 pad/cut（mask 全 1）。
///     HSE 哈希位置索引：10×10 网格，idx=floor(i*10/count)，
///     hash=h_idx*10+w_idx ∈[0,100)；尺度索引 224→0、384→1、
///     原始→2。
///   patch tokenizer（轻量 ResNet，StdConv 的权重标准化已在导出时
///     烘焙为普通卷积权重，StdConv 无 bias）：
///     conv_root(3→64,k7,s2,TF SAME 精确 padding)→GN(32,64,eps=1e-6)
///     →relu→ExactPadding2d(k3,s2,same)→maxPool(k3,s2)→
///     Bottleneck(64→256)：conv1(k1)→GN(32,*,eps=1e-4)→relu→
///     conv2(k3,s1,SAME)→GN→relu→conv3(k1)→GN；shortcut=
///     conv_proj(k1)+gn_proj；out=relu(x+identity)。
///     输出 [n,256,8,8] 按 NHWC 顺序展平（[H][W][C]，channel 最
///     内层）为 16384 维 → embedding Linear(16384→384)。
///   Transformer 编码器（14 层 pre-LN，384 维，6 头 head_dim=64，
///     scale=64^-0.5）：x += position_emb[hse] + scale_emb[scale]；
///     前插 CLS token（mask 前插 1）；每层 x += Attention(LN1(x))
///     （mask 填充 −1e3 而非 −inf）、x += MLP(LN2(x))（fc1 384→1152
///     →精确 erf 版 GELU→fc2 1152→384）；末尾 encoder_norm
///     LayerNorm(eps=1e-6)。
///   head Linear(384→1) 作用于 CLS 位置输出即分数（koniq
///     num_class=1，dist_to_mos 恒等，无 clamp/sigmoid）。
///
/// 纯 Dart（无 Flutter 依赖）。计算量大，勿在 UI isolate 直接跑
/// 同步版；[musiqScoreInIsolate] 为 compute() 入口（后台 isolate 内
/// 自起 NnPool，预处理/patch/tokenizer/embedding/transformer 全部
/// 移出 UI），[musiqScoreParallel] 走 NnPool 多 isolate 并行（patch
/// tokenizer 的 conv、embedding 的 gemm 与 transformer 的全部 GEMM
/// 池并行，per-head mask/softmax 经 Isolate.run 按头并行；与同步版
/// 位级一致）。
///
/// 黄金值对拍见 test/isp_musiq_dart_test.dart（由
/// tools/iqa/dump_musiq_golden.py 生成）。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../nn/nn_pool.dart';
import '../nn/nnw_reader.dart';
import '../nn/ops.dart' as ops;
import '../nn/tensor.dart';

/// MUSIQ koniq10k 权重的缺省路径（相对工作目录）。
const String musiqWeightsPath = 'tools/iqa/weights/musiq_koniq.nnw';

const int _patchSize = 32;
const int _hseGrid = 10;
const int _dim = 384;
const int _heads = 6;
const int _headDim = 64;
const int _layers = 14;
const List<int> _longerSides = [224, 384];

/// compute() 入口：`{'rgba': Uint8List, 'width': int, 'height': int,
/// 'weightsPath': String?}` → MUSIQ 分值（double，约 0..100）。
/// 在后台 isolate 内自起 NnPool（核数-4，同状态层共享池口径）并自行
/// 从 nnwPath 加载权重（108MB 按需读，避免跨 isolate 传权重），
/// 预处理/多尺度 patch/tokenizer/embedding/transformer 全部在该
/// isolate 内完成；结果与 [musiqScore] 位级一致。
@pragma('vm:entry-point')
Future<double> musiqScoreInIsolate(Map<String, Object?> msg) async {
  final model = MusiqDart.load(
      (msg['weightsPath'] as String?) ?? musiqWeightsPath);
  final pool = NnPool();
  await pool.start(math.max(2, Platform.numberOfProcessors - 4));
  try {
    return await model.scoreParallel(
        musiqInput(msg['rgba'] as Uint8List, msg['width'] as int,
            msg['height'] as int),
        pool);
  } finally {
    pool.dispose();
  }
}

/// RGBA8888 → [-1,1] RGB NCHW [1,3,H,W]：先 /255 到 [0,1]，再
/// (x−0.5)*2（musiq_arch.MUSIQ.forward 的 eval 预处理）。
NnTensor musiqInput(Uint8List rgba, int width, int height) {
  final s = width * height;
  final out = NnTensor.zeros([1, 3, height, width]);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    for (var i = 0, j = c; i < s; i++, j += 4) {
      out.data[base + i] = (rgba[j] / 255.0 - 0.5) * 2.0;
    }
  }
  return out;
}

/// Python 的 round()：round-half-even（banker's rounding）。Dart 的
/// double.round() 是 half-away，不能直接用于 multiscale 的 rh/rw 计算。
/// 仅处理正数（尺寸场景）。
int roundHalfEven(double v) {
  final f = v.floor();
  final d = v - f;
  if (d < 0.5) {
    return f;
  }
  if (d > 0.5) {
    return f + 1;
  }
  return f.isEven ? f : f + 1;
}

/// 单尺度的 patch 切分结果（multiscale_trans_util 的
/// _extract_patches_and_positions_from_image 等价物）。
class MusiqScalePatches {
  MusiqScalePatches(this.patches, this.hse, this.mask, this.scaleId,
      this.rh, this.rw, this.countH, this.countW, this.realPatches);

  /// [seqLen,3,32,32] patch 张量（补零行数据全 0）。
  final NnTensor patches;

  /// [seqLen] HSE 哈希位置索引（∈[0,100)，补零行为 0）。
  final Int32List hse;

  /// [seqLen] 输入 mask（真实 patch 为 1，补零行为 0）。
  final Int32List mask;

  /// 尺度索引（224→0、384→1、原始→2）。
  final int scaleId;

  /// resize 后的高/宽（原始尺度即原图尺寸）。
  final int rh, rw;

  /// 切分网格（ceil(rh/32)×ceil(rw/32)）。
  final int countH, countW;

  /// 真实 patch 数（countH*countW，截断前）。
  final int realPatches;

  int get seqLen => hse.length;
}

/// 零填充（TF SAME / exact_padding_2d constant 模式）。
NnTensor _padZero(NnTensor x, int top, int bottom, int left, int right) {
  if (top == 0 && bottom == 0 && left == 0 && right == 0) {
    return x;
  }
  final n = x.batch, c = x.channels, h = x.height, w = x.width;
  final oh = h + top + bottom, ow = w + left + right;
  final out = NnTensor.zeros([n, c, oh, ow]);
  for (var b = 0; b < n; b++) {
    for (var ch = 0; ch < c; ch++) {
      final srcC = (b * c + ch) * h * w;
      final dstC = (b * c + ch) * oh * ow;
      for (var y = 0; y < h; y++) {
        out.data.setRange(dstC + (top + y) * ow + left,
            dstC + (top + y) * ow + left + w, x.data, srcC + y * w);
      }
    }
  }
  return out;
}

/// 切一个尺度的 patch。[longerSide] 为 null 表示原始分辨率
/// （不 resize、不 pad/cut）。patch 数据按 [C][H][W] 展平
/// （torch unfold 语义），hse/mask 语义见 [MusiqScalePatches]。
MusiqScalePatches musiqExtractScale(NnTensor x, int? longerSide, int scaleId) {
  if (x.rank != 4 || x.batch != 1 || x.channels != 3) {
    throw ArgumentError('musiqExtractScale 需要 [1,3,H,W] 输入，得到 $x');
  }
  final h = x.height, w = x.width;
  NnTensor img;
  int rh, rw, maxSeq;
  if (longerSide == null) {
    img = x;
    rh = h;
    rw = w;
    maxSeq = -1;
  } else {
    final ratio = longerSide / math.max(h, w);
    rh = roundHalfEven(h * ratio);
    rw = roundHalfEven(w * ratio);
    img = ops.resizeBicubic(x, rh, rw);
    final cells = (longerSide + _patchSize - 1) ~/ _patchSize;
    maxSeq = cells * cells; // ceil(side/32)^2
  }
  final countH = (rh + _patchSize - 1) ~/ _patchSize;
  final countW = (rw + _patchSize - 1) ~/ _patchSize;
  final real = countH * countW;
  final seqLen = maxSeq < 0 ? real : maxSeq; // pad/cut 到 maxSeq

  // SAME 零填充：pad_total=(ceil(h/32)−1)*32+31−h（extract_image_patches，
  // kernel=stride=32、dilation=1）。
  final padRow = (countH - 1) * _patchSize + _patchSize - rh;
  final padCol = (countW - 1) * _patchSize + _patchSize - rw;
  final padded = _padZero(
      img, padRow ~/ 2, padRow - padRow ~/ 2, padCol ~/ 2, padCol - padCol ~/ 2);
  final ph = padded.height, pw = padded.width;

  final kept = math.min(real, seqLen); // 截断取前 N 个
  final data = Float32List(seqLen * 3 * _patchSize * _patchSize);
  final hse = Int32List(seqLen);
  final mask = Int32List(seqLen);
  for (var p = 0; p < kept; p++) {
    final row = p ~/ countW, col = p % countW;
    final py = row * _patchSize, px = col * _patchSize;
    var dst = p * 3 * _patchSize * _patchSize;
    for (var c = 0; c < 3; c++) {
      final cBase = c * ph * pw;
      for (var r = 0; r < _patchSize; r++) {
        data.setRange(dst, dst + _patchSize, padded.data,
            cBase + (py + r) * pw + px);
        dst += _patchSize;
      }
    }
    // HSE：nearest 下采样语义 idx=floor(i*grid/count)，hash=h*10+w。
    hse[p] = (row * _hseGrid ~/ countH) * _hseGrid + col * _hseGrid ~/ countW;
    mask[p] = 1;
  }
  return MusiqScalePatches(
      NnTensor(data, [seqLen, 3, _patchSize, _patchSize]),
      hse,
      mask,
      scaleId,
      rh,
      rw,
      countH,
      countW,
      real);
}

/// get_multiscale_patches 等价物：224、384、原始三尺度，返回顺序与
/// torch 的 cat(outputs, dim=-1) 一致。
List<MusiqScalePatches> musiqMultiscalePatches(NnTensor x) {
  return [
    for (var i = 0; i < _longerSides.length; i++)
      musiqExtractScale(x, _longerSides[i], i),
    musiqExtractScale(x, null, _longerSides.length),
  ];
}

/// 一个 TransformerBlock 的权重（pre-LN + 6 头注意力 + MLP）。
class _TransformerBlockW {
  _TransformerBlockW(
      this.norm1W, this.norm1B, this.qW, this.qB, this.kW, this.kB, this.vW,
      this.vB, this.outW, this.outB, this.norm2W, this.norm2B, this.fc1W,
      this.fc1B, this.fc2W, this.fc2B);

  final Float32List norm1W, norm1B, qB, kB, vB, outB, norm2W, norm2B;
  final Float32List fc1B, fc2B;
  final NnTensor qW, kW, vW, outW, fc1W, fc2W;
}

/// MUSIQ（koniq10k）前向模型。用 [MusiqDart.load] 加载 .nnw 权重。
class MusiqDart {
  MusiqDart._(
      this._convRootW, this._gnRootW, this._gnRootB, this._b1c1W,
      this._b1gn1W, this._b1gn1B, this._b1c2W, this._b1gn2W, this._b1gn2B,
      this._b1c3W, this._b1gn3W, this._b1gn3B, this._b1projW, this._b1pgnW,
      this._b1pgnB, this._embW, this._embB, this._clsToken, this._posEmb,
      this._scaleEmb, this._encNormW, this._encNormB, this._blocks,
      this._headW, this._headB);

  /// 从 .nnw 文件加载全部权重（键见 tools/iqa/export_weights.py，
  /// StdConv 已烘焙为普通 conv 权重）。
  factory MusiqDart.load(String nnwPath) {
    final reader = NnwReader.open(nnwPath);
    try {
      NnTensor w(String name) => reader.readTensor(name);
      Float32List b(String name) => reader.tensor(name).$1;
      const p = 'transformer_encoder.transformer.encoderblock_';
      return MusiqDart._(
        w('conv_root.weight'), b('gn_root.weight'), b('gn_root.bias'),
        w('block1.conv1.weight'), b('block1.gn1.weight'), b('block1.gn1.bias'),
        w('block1.conv2.weight'), b('block1.gn2.weight'), b('block1.gn2.bias'),
        w('block1.conv3.weight'), b('block1.gn3.weight'), b('block1.gn3.bias'),
        w('block1.conv_proj.weight'), b('block1.gn_proj.weight'),
        b('block1.gn_proj.bias'),
        w('embedding.weight'), b('embedding.bias'),
        b('transformer_encoder.cls'),
        b('transformer_encoder.posembed_input.position_emb'),
        b('transformer_encoder.scaleembed_input.scale_emb'),
        b('transformer_encoder.encoder_norm.weight'),
        b('transformer_encoder.encoder_norm.bias'),
        [
          for (var i = 0; i < _layers; i++)
            _TransformerBlockW(
              b('$p$i.norm1.weight'), b('$p$i.norm1.bias'),
              w('$p$i.attention.query.weight'), b('$p$i.attention.query.bias'),
              w('$p$i.attention.key.weight'), b('$p$i.attention.key.bias'),
              w('$p$i.attention.value.weight'), b('$p$i.attention.value.bias'),
              w('$p$i.attention.out.weight'), b('$p$i.attention.out.bias'),
              b('$p$i.norm2.weight'), b('$p$i.norm2.bias'),
              w('$p$i.mlp.fc1.weight'), b('$p$i.mlp.fc1.bias'),
              w('$p$i.mlp.fc2.weight'), b('$p$i.mlp.fc2.bias'),
            ),
        ],
        w('head.weight'), b('head.bias'),
      );
    } finally {
      reader.close();
    }
  }

  final NnTensor _convRootW;
  final Float32List _gnRootW, _gnRootB;
  final NnTensor _b1c1W, _b1c2W, _b1c3W, _b1projW;
  final Float32List _b1gn1W, _b1gn1B, _b1gn2W, _b1gn2B, _b1gn3W, _b1gn3B;
  final Float32List _b1pgnW, _b1pgnB;
  final NnTensor _embW; // [384,16384]
  final Float32List _embB;
  final Float32List _clsToken; // [384]
  final Float32List _posEmb; // [100*384]
  final Float32List _scaleEmb; // [3*384]
  final Float32List _encNormW, _encNormB;
  final List<_TransformerBlockW> _blocks;
  final NnTensor _headW; // [1,384]
  final Float32List _headB;

  /// TF SAME 精确 padding 的 StdConv 前向（权重标准化已烘焙进权重，
  /// 无 bias）。[conv] 注入以复用同步/池并行两种实现。
  static NnTensor _convSame(NnTensor x, NnTensor w, int sH, int sW,
      NnTensor Function(NnTensor, NnTensor,
              {Float32List? bias, int strideH, int strideW, int padH, int padW})
          conv) {
    final p = ops.exactPaddingTfSame(
        x.height, x.width, w.shape[2], w.shape[3], sH, sW);
    return conv(_padZero(x, p.padTop, p.padBottom, p.padLeft, p.padRight), w,
        strideH: sH, strideW: sW);
  }

  /// patch tokenizer 前向（同步）：[n,3,32,32] → [n,256,8,8]。
  NnTensor tokenizerForward(NnTensor patches) {
    var t = _convSame(patches, _convRootW, 2, 2, ops.conv2d);
    t = ops.groupNorm(t, 32, _gnRootW, _gnRootB, eps: 1e-6);
    t = ops.relu(t);
    // root_pool：ExactPadding2d(3,2,same) + MaxPool2d(3,2)。
    final p = ops.exactPaddingTfSame(t.height, t.width, 3, 3, 2, 2);
    t = _padZero(t, p.padTop, p.padBottom, p.padLeft, p.padRight);
    t = ops.maxPool2d(t, 3, 3, 2, 2, 0, 0);
    return _bottleneck(t, ops.conv2d);
  }

  /// patch tokenizer 前向（NnPool 池并行）：conv 走 parallelConv2d，
  /// 与 [tokenizerForward] 位级一致。
  Future<NnTensor> tokenizerForwardParallel(
      NnTensor patches, NnPool pool) async {
    final p0 = ops.exactPaddingTfSame(
        patches.height, patches.width, 7, 7, 2, 2);
    var t = await pool.parallelConv2d(
        _padZero(patches, p0.padTop, p0.padBottom, p0.padLeft, p0.padRight),
        _convRootW,
        strideH: 2,
        strideW: 2);
    t = ops.groupNorm(t, 32, _gnRootW, _gnRootB, eps: 1e-6);
    t = ops.relu(t);
    final p = ops.exactPaddingTfSame(t.height, t.width, 3, 3, 2, 2);
    t = _padZero(t, p.padTop, p.padBottom, p.padLeft, p.padRight);
    t = ops.maxPool2d(t, 3, 3, 2, 2, 0, 0);

    // Bottleneck（k1 的 SAME padding 为 0，直接 parallelConv2d）。
    final identity = ops.groupNorm(
        await pool.parallelConv2d(t, _b1projW), 32, _b1pgnW, _b1pgnB,
        eps: 1e-4);
    var y = ops.relu(ops.groupNorm(
        await pool.parallelConv2d(t, _b1c1W), 32, _b1gn1W, _b1gn1B,
        eps: 1e-4));
    final p2 = ops.exactPaddingTfSame(y.height, y.width, 3, 3, 1, 1);
    y = ops.relu(ops.groupNorm(
        await pool.parallelConv2d(
            _padZero(y, p2.padTop, p2.padBottom, p2.padLeft, p2.padRight),
            _b1c2W),
        32,
        _b1gn2W,
        _b1gn2B,
        eps: 1e-4));
    y = ops.groupNorm(await pool.parallelConv2d(y, _b1c3W), 32, _b1gn3W,
        _b1gn3B,
        eps: 1e-4);
    for (var i = 0; i < y.numel; i++) {
      y.data[i] += identity.data[i];
    }
    return ops.relu(y);
  }

  /// Bottleneck(64→256)（同步版，conv 注入复用）。
  NnTensor _bottleneck(
      NnTensor t,
      NnTensor Function(NnTensor, NnTensor,
              {Float32List? bias, int strideH, int strideW, int padH, int padW})
          conv) {
    final identity =
        ops.groupNorm(_convSame(t, _b1projW, 1, 1, conv), 32, _b1pgnW, _b1pgnB,
            eps: 1e-4);
    var y = ops.relu(ops.groupNorm(_convSame(t, _b1c1W, 1, 1, conv), 32,
        _b1gn1W, _b1gn1B,
        eps: 1e-4));
    y = ops.relu(ops.groupNorm(_convSame(y, _b1c2W, 1, 1, conv), 32, _b1gn2W,
        _b1gn2B,
        eps: 1e-4));
    y = ops.groupNorm(_convSame(y, _b1c3W, 1, 1, conv), 32, _b1gn3W, _b1gn3B,
        eps: 1e-4);
    for (var i = 0; i < y.numel; i++) {
      y.data[i] += identity.data[i];
    }
    return ops.relu(y);
  }

  /// [n,256,8,8] → NHWC 展平（[H][W][C]，channel 最内层）16384 维。
  static Float32List nhwcFlatten(NnTensor tok) {
    final n = tok.batch, c = tok.channels, s = tok.height * tok.width;
    final flat = Float32List(n * c * s);
    for (var p = 0; p < n; p++) {
      final pBase = p * c * s;
      var dst = p * c * s;
      for (var i = 0; i < s; i++) {
        for (var ch = 0; ch < c; ch++) {
          flat[dst++] = tok.data[pBase + ch * s + i];
        }
      }
    }
    return flat;
  }

  /// embedding Linear(16384→384)（同步）：[n,256,8,8] → [n,384]。
  NnTensor embeddingForward(NnTensor tok) {
    final n = tok.batch;
    return ops.linear(NnTensor(nhwcFlatten(tok), [n, _embW.shape[1]]), _embW,
        bias: _embB);
  }

  /// embedding Linear（NnPool 池并行）：gemm 按行块切分，与
  /// [embeddingForward] 位级一致。
  Future<NnTensor> embeddingForwardParallel(NnTensor tok, NnPool pool) async {
    final n = tok.batch, k = _embW.shape[1];
    final flat = nhwcFlatten(tok);
    final out =
        await pool.parallelGemm(flat, _embW.data, n, _dim, k, transB: true);
    for (var r = 0; r < n; r++) {
      final base = r * _dim;
      for (var j = 0; j < _dim; j++) {
        out[base + j] += _embB[j];
      }
    }
    return NnTensor(out, [n, _dim]);
  }

  /// 6 头自注意力（pre-LN 之后）：q/k/v Linear(384→384,bias)，
  /// head_dim=64、scale=64^-0.5，mask 填充 −1e3（masked_fill(
  /// mask==0,−1000)，非 −inf），softmax → out Linear。
  static NnTensor _attention(
      NnTensor x, _TransformerBlockW blk, Int32List mask) {
    final n = x.shape[0];
    final q = ops.linear(x, blk.qW, bias: blk.qB);
    final k = ops.linear(x, blk.kW, bias: blk.kB);
    final v = ops.linear(x, blk.vW, bias: blk.vB);
    const scale = 1.0 / 8.0; // head_dim(64)^-0.5
    final ctx = Float32List(n * _dim);
    final qH = Float32List(n * _headDim);
    final kH = Float32List(n * _headDim);
    final vH = Float32List(n * _headDim);
    final attn = Float32List(n * n);
    for (var h = 0; h < _heads; h++) {
      final off = h * _headDim;
      for (var t = 0; t < n; t++) {
        final row = t * _dim + off;
        qH.setRange(t * _headDim, (t + 1) * _headDim, q.data, row);
        kH.setRange(t * _headDim, (t + 1) * _headDim, k.data, row);
        vH.setRange(t * _headDim, (t + 1) * _headDim, v.data, row);
      }
      // scores = qH @ kHᵀ * scale，再 masked_fill(mask==0, -1e3)。
      final scores =
          ops.linear(NnTensor(qH, [n, _headDim]), NnTensor(kH, [n, _headDim]));
      for (var i = 0; i < n; i++) {
        final base = i * n;
        if (mask[i] == 0) {
          for (var j = 0; j < n; j++) {
            attn[base + j] = -1e3;
          }
          continue;
        }
        for (var j = 0; j < n; j++) {
          attn[base + j] = mask[j] == 0 ? -1e3 : scores.data[base + j] * scale;
        }
      }
      // 逐行 softmax（减最大值）。
      for (var i = 0; i < n; i++) {
        final base = i * n;
        var maxV = double.negativeInfinity;
        for (var j = 0; j < n; j++) {
          if (attn[base + j] > maxV) {
            maxV = attn[base + j];
          }
        }
        var sum = 0.0;
        for (var j = 0; j < n; j++) {
          final e = math.exp(attn[base + j] - maxV);
          attn[base + j] = e;
          sum += e;
        }
        for (var j = 0; j < n; j++) {
          attn[base + j] = attn[base + j] / sum;
        }
      }
      final o =
          ops.matmul(NnTensor(attn, [n, n]), NnTensor(vH, [n, _headDim]));
      for (var t = 0; t < n; t++) {
        ctx.setRange(t * _dim + off, t * _dim + off + _headDim, o.data,
            t * _headDim);
      }
    }
    return ops.linear(NnTensor(ctx, [n, _dim]), blk.outW, bias: blk.outB);
  }

  /// 池并行 Linear：与 ops.linear 位级一致（ops.linear 即
  /// sgemm(x, W, rows, outF, inF, transB: true) + 逐行 bias 加；
  /// NnPool.parallelGemm 按 M 行块切分，不改变任一输出元素的 k 维
  /// 累加顺序）。bias 加循环与 ops.linear 逐字一致。
  static Future<NnTensor> _linearParallel(
      NnTensor x, NnTensor weight, Float32List? bias, NnPool pool) async {
    final inF = weight.shape[1], outF = weight.shape[0];
    if (x.shape.last != inF) {
      throw ArgumentError(
          'linear: 输入末维 ${x.shape.last} != in_features $inF');
    }
    final rows = x.numel ~/ inF;
    final out = NnTensor.zeros([...x.shape.sublist(0, x.rank - 1), outF]);
    await pool.parallelGemm(x.data, weight.data, rows, outF, inF,
        transB: true, c: out.data);
    if (bias != null) {
      for (var r = 0; r < rows; r++) {
        final base = r * outF;
        for (var j = 0; j < outF; j++) {
          out.data[base + j] += bias[j];
        }
      }
    }
    return out;
  }

  /// 6 头自注意力的池并行版（与 [_attention] 位级一致）：q/k/v/out
  /// 投影与 per-head scores（ops.linear(qH,kH) 即 sgemm(m=n,n=n,k=64,
  /// transB:true)）/AV（ops.matmul(attn,vH) 即 sgemm(m=n,n=64,k=n)）
  /// 的 GEMM 走 [pool]；mask 填充 + 逐行 softmax 经
  /// [_maskSoftmaxHeadInIsolate] 按头并行（per-row 独立、逐元素
  /// 确定性）。per-head 的切片/回写循环与运算顺序与 [_attention]
  /// 逐字一致（仅缓冲从循环外复用改为每 head 独立分配，不影响数值）。
  static Future<NnTensor> _attentionParallel(
      NnTensor x, _TransformerBlockW blk, Int32List mask, NnPool pool) async {
    final n = x.shape[0];
    final q = await _linearParallel(x, blk.qW, blk.qB, pool);
    final k = await _linearParallel(x, blk.kW, blk.kB, pool);
    final v = await _linearParallel(x, blk.vW, blk.vB, pool);
    final ctx = Float32List(n * _dim);
    Future<void> head(int h) async {
      final off = h * _headDim;
      final qH = Float32List(n * _headDim);
      final kH = Float32List(n * _headDim);
      final vH = Float32List(n * _headDim);
      for (var t = 0; t < n; t++) {
        final row = t * _dim + off;
        qH.setRange(t * _headDim, (t + 1) * _headDim, q.data, row);
        kH.setRange(t * _headDim, (t + 1) * _headDim, k.data, row);
        vH.setRange(t * _headDim, (t + 1) * _headDim, v.data, row);
      }
      final scores =
          await pool.parallelGemm(qH, kH, n, n, _headDim, transB: true);
      final attn = await _maskSoftmaxHeadInIsolate(scores, mask, n);
      final o = await pool.parallelGemm(attn, vH, n, _headDim, n);
      for (var t = 0; t < n; t++) {
        ctx.setRange(
            t * _dim + off, t * _dim + off + _headDim, o, t * _headDim);
      }
    }

    await Future.wait([for (var h = 0; h < _heads; h++) head(h)]);
    return _linearParallel(
        NnTensor(ctx, [n, _dim]), blk.outW, blk.outB, pool);
  }

  /// TransformerBlock（pre-LN）池并行版：LN/gelu/residual 与
  /// [_blockForward] 逐字一致（同步执行），GEMM 走 [pool]，位级一致。
  static Future<NnTensor> _blockForwardParallel(NnTensor x,
      _TransformerBlockW blk, Int32List mask, NnPool pool) async {
    var y = ops.layerNorm(x, [_dim], blk.norm1W, blk.norm1B, eps: 1e-6);
    y = await _attentionParallel(y, blk, mask, pool);
    final out = NnTensor.zeros(x.shape);
    for (var i = 0; i < x.numel; i++) {
      out.data[i] = x.data[i] + y.data[i];
    }
    y = ops.layerNorm(out, [_dim], blk.norm2W, blk.norm2B, eps: 1e-6);
    y = await _linearParallel(y, blk.fc1W, blk.fc1B, pool);
    y = ops.gelu(y);
    y = await _linearParallel(y, blk.fc2W, blk.fc2B, pool);
    for (var i = 0; i < out.numel; i++) {
      out.data[i] += y.data[i];
    }
    return out;
  }

  /// TransformerBlock（pre-LN）：x += Attention(LN1(x))；
  /// x += MLP(LN2(x))（fc1→精确 erf GELU→fc2）。
  static NnTensor _blockForward(
      NnTensor x, _TransformerBlockW blk, Int32List mask) {
    var y = ops.layerNorm(x, [_dim], blk.norm1W, blk.norm1B, eps: 1e-6);
    y = _attention(y, blk, mask);
    final out = NnTensor.zeros(x.shape);
    for (var i = 0; i < x.numel; i++) {
      out.data[i] = x.data[i] + y.data[i];
    }
    y = ops.layerNorm(out, [_dim], blk.norm2W, blk.norm2B, eps: 1e-6);
    y = ops.linear(y, blk.fc1W, bias: blk.fc1B);
    y = ops.gelu(y);
    y = ops.linear(y, blk.fc2W, bias: blk.fc2B);
    for (var i = 0; i < out.numel; i++) {
      out.data[i] += y.data[i];
    }
    return out;
  }

  /// Transformer 编码器 + head：输入 embedding 输出 [S,384] 与逐 patch
  /// 的 hse/尺度索引/mask，返回 CLS 位置的 head 标量（即 MUSIQ 分数，
  /// koniq num_class=1 时 dist_to_mos 恒等）。
  double encoderScore(
      Float32List emb, Int32List hse, Int32List scaleIds, Int32List mask) {
    final s = hse.length;
    final n = s + 1;
    final x = NnTensor.zeros([n, _dim]);
    // posembed/scale emb 加在 patch token 上，再前插 CLS（musiq_arch
    // TransformerEncoder.forward 的顺序）。
    x.data.setRange(_dim, n * _dim, emb);
    for (var i = 0; i < s; i++) {
      final row = (i + 1) * _dim;
      final pb = hse[i] * _dim, sb = scaleIds[i] * _dim;
      for (var j = 0; j < _dim; j++) {
        x.data[row + j] += _posEmb[pb + j] + _scaleEmb[sb + j];
      }
    }
    x.data.setRange(0, _dim, _clsToken);
    final maskFull = Int32List(n);
    maskFull[0] = 1;
    maskFull.setRange(1, n, mask);

    var h = x;
    for (final blk in _blocks) {
      h = _blockForward(h, blk, maskFull);
    }
    h = ops.layerNorm(h, [_dim], _encNormW, _encNormB, eps: 1e-6);
    // head Linear(384→1) 作用于 CLS（第 0 行）。
    var score = _headB[0];
    for (var j = 0; j < _dim; j++) {
      score += h.data[j] * _headW.data[j];
    }
    return score;
  }

  /// [encoderScore] 的池并行版：CLS/posEmb/scaleEmb/mask 前插、末尾
  /// encoder_norm 与 head 的代码与运算顺序逐字一致；14 层 block 改
  /// [_blockForwardParallel]（GEMM 走 [pool]、per-head mask/softmax
  /// 经 Isolate.run 按头并行），结果与 [encoderScore] 位级一致。
  Future<double> encoderScoreParallel(Float32List emb, Int32List hse,
      Int32List scaleIds, Int32List mask, NnPool pool) async {
    final s = hse.length;
    final n = s + 1;
    final x = NnTensor.zeros([n, _dim]);
    // posembed/scale emb 加在 patch token 上，再前插 CLS（musiq_arch
    // TransformerEncoder.forward 的顺序）。
    x.data.setRange(_dim, n * _dim, emb);
    for (var i = 0; i < s; i++) {
      final row = (i + 1) * _dim;
      final pb = hse[i] * _dim, sb = scaleIds[i] * _dim;
      for (var j = 0; j < _dim; j++) {
        x.data[row + j] += _posEmb[pb + j] + _scaleEmb[sb + j];
      }
    }
    x.data.setRange(0, _dim, _clsToken);
    final maskFull = Int32List(n);
    maskFull[0] = 1;
    maskFull.setRange(1, n, mask);

    var h = x;
    for (final blk in _blocks) {
      h = await _blockForwardParallel(h, blk, maskFull, pool);
    }
    h = ops.layerNorm(h, [_dim], _encNormW, _encNormB, eps: 1e-6);
    // head Linear(384→1) 作用于 CLS（第 0 行）。
    var score = _headB[0];
    for (var j = 0; j < _dim; j++) {
      score += h.data[j] * _headW.data[j];
    }
    return score;
  }

  /// 拼接三尺度为单条序列：patch 数据 [total,3,32,32] 与逐 patch
  /// 的 hse/尺度索引/mask（torch 的 cat(outputs, dim=-1) 等价物）。
  static (NnTensor, Int32List, Int32List, Int32List) _prepareSeq(
      List<MusiqScalePatches> scales) {
    var total = 0;
    for (final sc in scales) {
      total += sc.seqLen;
    }
    final patches = NnTensor.zeros([total, 3, _patchSize, _patchSize]);
    final hse = Int32List(total);
    final scaleIds = Int32List(total);
    final mask = Int32List(total);
    var off = 0;
    for (final sc in scales) {
      patches.data.setRange(off * 3 * _patchSize * _patchSize,
          (off + sc.seqLen) * 3 * _patchSize * _patchSize, sc.patches.data);
      hse.setRange(off, off + sc.seqLen, sc.hse);
      mask.setRange(off, off + sc.seqLen, sc.mask);
      for (var i = 0; i < sc.seqLen; i++) {
        scaleIds[off + i] = sc.scaleId;
      }
      off += sc.seqLen;
    }
    return (patches, hse, scaleIds, mask);
  }

  /// 完整前向（同步）：[x] 为已归一化 [-1,1] 的 [1,3,H,W]，
  /// 返回 MUSIQ 分数。
  double score(NnTensor x) {
    final (patches, hse, scaleIds, mask) =
        _prepareSeq(musiqMultiscalePatches(x));
    final emb = embeddingForward(tokenizerForward(patches));
    return encoderScore(emb.data, hse, scaleIds, mask);
  }

  /// 完整前向（NnPool 池并行）：tokenizer 的 conv、embedding 的
  /// gemm 与 transformer 的全部 GEMM 池并行（per-head mask/softmax
  /// 经 Isolate.run 按头并行）；与 [score] 位级一致。
  Future<double> scoreParallel(NnTensor x, NnPool pool) async {
    final (patches, hse, scaleIds, mask) =
        _prepareSeq(musiqMultiscalePatches(x));
    final tok = await tokenizerForwardParallel(patches, pool);
    final emb = await embeddingForwardParallel(tok, pool);
    return encoderScoreParallel(emb.data, hse, scaleIds, mask, pool);
  }
}

/// 单 head 的 mask 填充 + 逐行 softmax：[n,n] scores → attn。
/// 代码与运算顺序逐字抄自 [MusiqDart._attention] 的内联段
/// （masked_fill(mask==0,−1000) 非 −inf、softmax 减最大值），
/// per-row 独立、逐元素确定——经 Isolate.run 在独立 isolate 执行
/// 与同步执行位级一致（math.exp 为 VM 内建确定性函数）。
Float32List _maskSoftmaxHead(Float32List scores, Int32List mask, int n) {
  const scale = 1.0 / 8.0; // head_dim(64)^-0.5
  final attn = Float32List(n * n);
  // masked_fill(mask==0, -1e3)，再乘 scale。
  for (var i = 0; i < n; i++) {
    final base = i * n;
    if (mask[i] == 0) {
      for (var j = 0; j < n; j++) {
        attn[base + j] = -1e3;
      }
      continue;
    }
    for (var j = 0; j < n; j++) {
      attn[base + j] = mask[j] == 0 ? -1e3 : scores[base + j] * scale;
    }
  }
  // 逐行 softmax（减最大值）。
  for (var i = 0; i < n; i++) {
    final base = i * n;
    var maxV = double.negativeInfinity;
    for (var j = 0; j < n; j++) {
      if (attn[base + j] > maxV) {
        maxV = attn[base + j];
      }
    }
    var sum = 0.0;
    for (var j = 0; j < n; j++) {
      final e = math.exp(attn[base + j] - maxV);
      attn[base + j] = e;
      sum += e;
    }
    for (var j = 0; j < n; j++) {
      attn[base + j] = attn[base + j] / sum;
    }
  }
  return attn;
}

/// [_maskSoftmaxHead] 的 Isolate.run 包装（n≈5136 时单 head [n,n]
/// ≈105MB，进出均经 TransferableTypedData 零拷贝传输）。
Future<Float32List> _maskSoftmaxHeadInIsolate(
    Float32List scores, Int32List mask, int n) async {
  final inTtd = TransferableTypedData.fromList([scores]);
  final outTtd = await Isolate.run(() {
    final s = inTtd.materialize().asFloat32List();
    return TransferableTypedData.fromList([_maskSoftmaxHead(s, mask, n)]);
  });
  return outTtd.materialize().asFloat32List();
}

void _checkInput(Uint8List rgba, int width, int height) {
  if (width < 1 || height < 1 || rgba.length < width * height * 4) {
    throw ArgumentError('musiqScore: 帧尺寸/数据长度不符 '
        '($width×$height, ${rgba.length})');
  }
}

/// MUSIQ 分值（同步单线程版）。输入 RGBA8888，任意分辨率。
double musiqScore(Uint8List rgba, int width, int height,
    {String weightsPath = musiqWeightsPath}) {
  _checkInput(rgba, width, height);
  final model = MusiqDart.load(weightsPath);
  return model.score(musiqInput(rgba, width, height));
}

/// MUSIQ 分值（NnPool 多 isolate 并行版）：结果与 [musiqScore]
/// 位级一致。传入共享 [pool] 时直接使用（调用侧负责其生命周期）；
/// 缺省内部启动 [workers] 个 worker（缺省按 CPU 核数），算完即销毁。
Future<double> musiqScoreParallel(Uint8List rgba, int width, int height,
    {String weightsPath = musiqWeightsPath, int? workers,
    NnPool? pool}) async {
  _checkInput(rgba, width, height);
  final model = MusiqDart.load(weightsPath);
  final ownPool = pool == null;
  final p = pool ?? NnPool();
  if (ownPool) await p.start(workers);
  try {
    return await model.scoreParallel(musiqInput(rgba, width, height), p);
  } finally {
    if (ownPool) p.dispose();
  }
}
