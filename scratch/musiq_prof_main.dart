// MUSIQ 进程内 Dart 实现（lib/modules/isp_studio/pipeline/metrics/musiq_dart.dart）
// 的真机耗时构成探针（GPU 化立项前的摸底）：
//   flutter run -d windows --release -t scratch/musiq_prof_main.dart
// 在真实 Windows/release 环境对 2592×1940 busyFrame 输入：
//   1) 直通 compute(musiqScoreInIsolate)（优化 10 后生产口径，共享
//      NnPool 由后台 isolate 自起，worker=核数-4）计总耗时；
//   2) 分阶段拆解：预处理 / 多尺度 patch 提取 / tokenizer（pool conv
//      等待 vs 调用 isolate 同步 GN/relu/maxpool）/ embedding GEMM /
//      transformer 14 层（细拆 qkv、QK^T、softmax、AV、out、fc1/gelu/fc2、
//      LN、residual，区分「同步 sgemm」与「同步逐元素 op」）/ head；
//   3) Timer.periodic(50ms) 计数打印 eventloopTicks，识别哪些阶段把
//      调用 isolate 堵死（ticks≈0）。
// transformer 只实测前 2 层再 ×7 外推（14 层权重同形，逐层耗时一致），
// 否则「直通 + 分阶段」两遍全量会超过 10 分钟；外推项打印中均标注。
// 复刻代码（_padZero / tokenizerForwardParallel / embeddingForwardParallel /
// _attention / _blockForward / encoderScore / _prepareSeq）逐字抄自
// musiq_dart.dart（私有成员经 NnwReader 直接读同名权重键），并在 8 patch
// 小规模上与公开 API 做位级对拍（check 行 maxAbs/diff 应全为 0）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/musiq_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nnw_reader.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart' as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

const int kW = 2592, kH = 1940; // 真机 5MP 2x 降采样后的馈源尺寸
const int kPatch = 32;
const int kDim = 384;
const int kHeads = 6;
const int kHeadDim = 64;
const int kLayers = 14;
const int kMeasuredLayers = 2; // transformer 实测层数，其余外推

int _ticks = 0; // Timer.periodic(50ms) 计数：调用 isolate 活性探针

/// 高纹理彩色测试帧（图案同 test/isp_pyiqa_test.dart 的 busyFrame）。
Uint8List busyFrame(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final r = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0)
          .toInt();
      final g = (128 +
              70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
              40 * math.cos((2 * x - y) / 6.7))
          .clamp(0.0, 255.0)
          .toInt();
      final b = (128 +
              70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

/// 零填充（TF SAME / exact_padding_2d constant 模式）。逐字抄自
/// musiq_dart.dart 的 _padZero（私有，无法直接复用）。
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

/// 一个 TransformerBlock 的权重（字段与 musiq_dart.dart 的
/// _TransformerBlockW 一一对应）。
class ProfBlockW {
  ProfBlockW(
      this.norm1W, this.norm1B, this.qW, this.qB, this.kW, this.kB, this.vW,
      this.vB, this.outW, this.outB, this.norm2W, this.norm2B, this.fc1W,
      this.fc1B, this.fc2W, this.fc2B);

  final Float32List norm1W, norm1B, qB, kB, vB, outB, norm2W, norm2B;
  final Float32List fc1B, fc2B;
  final NnTensor qW, kW, vW, outW, fc1W, fc2W;
}

/// 探针用权重包（键名逐字抄自 MusiqDart.load）。
class ProfW {
  ProfW(
      this.convRootW, this.gnRootW, this.gnRootB, this.b1c1W, this.b1gn1W,
      this.b1gn1B, this.b1c2W, this.b1gn2W, this.b1gn2B, this.b1c3W,
      this.b1gn3W, this.b1gn3B, this.b1projW, this.b1pgnW, this.b1pgnB,
      this.embW, this.embB, this.clsToken, this.posEmb, this.scaleEmb,
      this.encNormW, this.encNormB, this.blocks, this.headW, this.headB);

  final NnTensor convRootW;
  final Float32List gnRootW, gnRootB;
  final NnTensor b1c1W, b1c2W, b1c3W, b1projW;
  final Float32List b1gn1W, b1gn1B, b1gn2W, b1gn2B, b1gn3W, b1gn3B;
  final Float32List b1pgnW, b1pgnB;
  final NnTensor embW; // [384,16384]
  final Float32List embB;
  final Float32List clsToken; // [384]
  final Float32List posEmb; // [100*384]
  final Float32List scaleEmb; // [3*384]
  final Float32List encNormW, encNormB;
  final List<ProfBlockW> blocks;
  final NnTensor headW; // [1,384]
  final Float32List headB;
}

/// 从 .nnw 加载探针用权重（键名与 MusiqDart.load 完全一致）。
ProfW loadProfW(String nnwPath) {
  final reader = NnwReader.open(nnwPath);
  try {
    NnTensor w(String name) => reader.readTensor(name);
    Float32List b(String name) => reader.tensor(name).$1;
    const p = 'transformer_encoder.transformer.encoderblock_';
    return ProfW(
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
        for (var i = 0; i < kLayers; i++)
          ProfBlockW(
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

/// tokenizer 阶段计时累加器。
class ProfTokAcc {
  var poolMs = 0; // pool.parallelConv2d 等待合计
  var syncMs = 0; // 调用 isolate 同步 op（GN/relu/maxpool/pad/residual）合计
  final convs = <(String, int)>[]; // 逐 conv 的 pool 等待
}

/// embedding 阶段计时累加器。
class ProfEmbAcc {
  var flatMs = 0; // NHWC 展平（同步）
  var gemmMs = 0; // pool.parallelGemm 等待
  var biasMs = 0; // bias 加（同步）
}

/// transformer 阶段计时累加器（全为调用 isolate 上的同步执行）。
class ProfTrAcc {
  var preludeMs = 0; // pos/scale emb 相加 + CLS 前插
  var layerMs = 0; // 已跑层合计
  var headMs = 0; // encoder_norm + head
  var lnMs = 0, qkvMs = 0, scoresMs = 0, softmaxMs = 0, avMs = 0;
  var outProjMs = 0, fc1Ms = 0, geluMs = 0, fc2Ms = 0;
  var residualMs = 0, copyMs = 0; // 残差相加；head 切片/写回拷贝

  int get gemmMs => qkvMs + scoresMs + avMs + outProjMs + fc1Ms + fc2Ms;
  int get syncOpsMs => lnMs + softmaxMs + geluMs + residualMs + copyMs;
}

/// patch tokenizer 前向（NnPool 池并行），逐字抄自
/// MusiqDart.tokenizerForwardParallel，仅在 await/同步段之间插入计时。
Future<NnTensor> profTokenizerForwardParallel(
    NnTensor patches, NnPool pool, ProfW w, ProfTokAcc acc) async {
  final p0 =
      ops.exactPaddingTfSame(patches.height, patches.width, 7, 7, 2, 2);
  var sw = Stopwatch()..start();
  var t = _padZero(patches, p0.padTop, p0.padBottom, p0.padLeft, p0.padRight);
  acc.syncMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  t = await pool.parallelConv2d(t, w.convRootW, strideH: 2, strideW: 2);
  acc.poolMs += sw.elapsedMilliseconds;
  acc.convs.add(('conv_root', sw.elapsedMilliseconds));
  sw = Stopwatch()..start();
  t = ops.groupNorm(t, 32, w.gnRootW, w.gnRootB, eps: 1e-6);
  t = ops.relu(t);
  final p = ops.exactPaddingTfSame(t.height, t.width, 3, 3, 2, 2);
  t = _padZero(t, p.padTop, p.padBottom, p.padLeft, p.padRight);
  t = ops.maxPool2d(t, 3, 3, 2, 2, 0, 0);
  acc.syncMs += sw.elapsedMilliseconds;

  // Bottleneck（k1 的 SAME padding 为 0，直接 parallelConv2d）。
  sw = Stopwatch()..start();
  var tmp = await pool.parallelConv2d(t, w.b1projW);
  acc.poolMs += sw.elapsedMilliseconds;
  acc.convs.add(('block1.conv_proj', sw.elapsedMilliseconds));
  sw = Stopwatch()..start();
  final identity =
      ops.groupNorm(tmp, 32, w.b1pgnW, w.b1pgnB, eps: 1e-4);
  acc.syncMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  tmp = await pool.parallelConv2d(t, w.b1c1W);
  acc.poolMs += sw.elapsedMilliseconds;
  acc.convs.add(('block1.conv1', sw.elapsedMilliseconds));
  sw = Stopwatch()..start();
  var y = ops.relu(
      ops.groupNorm(tmp, 32, w.b1gn1W, w.b1gn1B, eps: 1e-4));
  final p2 = ops.exactPaddingTfSame(y.height, y.width, 3, 3, 1, 1);
  y = _padZero(y, p2.padTop, p2.padBottom, p2.padLeft, p2.padRight);
  acc.syncMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  tmp = await pool.parallelConv2d(y, w.b1c2W);
  acc.poolMs += sw.elapsedMilliseconds;
  acc.convs.add(('block1.conv2', sw.elapsedMilliseconds));
  sw = Stopwatch()..start();
  y = ops.relu(
      ops.groupNorm(tmp, 32, w.b1gn2W, w.b1gn2B, eps: 1e-4));
  acc.syncMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  tmp = await pool.parallelConv2d(y, w.b1c3W);
  acc.poolMs += sw.elapsedMilliseconds;
  acc.convs.add(('block1.conv3', sw.elapsedMilliseconds));
  sw = Stopwatch()..start();
  y = ops.groupNorm(tmp, 32, w.b1gn3W, w.b1gn3B, eps: 1e-4);
  for (var i = 0; i < y.numel; i++) {
    y.data[i] += identity.data[i];
  }
  y = ops.relu(y);
  acc.syncMs += sw.elapsedMilliseconds;
  return y;
}

/// embedding Linear(16384→384)（NnPool 池并行），逐字抄自
/// MusiqDart.embeddingForwardParallel，仅插入计时。
Future<NnTensor> profEmbeddingForwardParallel(
    NnTensor tok, NnPool pool, ProfW w, ProfEmbAcc acc) async {
  final n = tok.batch, k = w.embW.shape[1];
  var sw = Stopwatch()..start();
  final flat = MusiqDart.nhwcFlatten(tok);
  acc.flatMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  final out =
      await pool.parallelGemm(flat, w.embW.data, n, kDim, k, transB: true);
  acc.gemmMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  for (var r = 0; r < n; r++) {
    final base = r * kDim;
    for (var j = 0; j < kDim; j++) {
      out[base + j] += w.embB[j];
    }
  }
  acc.biasMs += sw.elapsedMilliseconds;
  return NnTensor(out, [n, kDim]);
}

/// 6 头自注意力，逐字抄自 musiq_dart.dart 的 _attention（static），
/// 仅在各 op 段之间插入计时。
NnTensor profAttention(
    NnTensor x, ProfBlockW blk, Int32List mask, ProfTrAcc acc) {
  final n = x.shape[0];
  var sw = Stopwatch()..start();
  final q = ops.linear(x, blk.qW, bias: blk.qB);
  final k = ops.linear(x, blk.kW, bias: blk.kB);
  final v = ops.linear(x, blk.vW, bias: blk.vB);
  acc.qkvMs += sw.elapsedMilliseconds;
  const scale = 1.0 / 8.0; // head_dim(64)^-0.5
  final ctx = Float32List(n * kDim);
  final qH = Float32List(n * kHeadDim);
  final kH = Float32List(n * kHeadDim);
  final vH = Float32List(n * kHeadDim);
  final attn = Float32List(n * n);
  for (var h = 0; h < kHeads; h++) {
    final off = h * kHeadDim;
    sw = Stopwatch()..start();
    for (var t = 0; t < n; t++) {
      final row = t * kDim + off;
      qH.setRange(t * kHeadDim, (t + 1) * kHeadDim, q.data, row);
      kH.setRange(t * kHeadDim, (t + 1) * kHeadDim, k.data, row);
      vH.setRange(t * kHeadDim, (t + 1) * kHeadDim, v.data, row);
    }
    acc.copyMs += sw.elapsedMilliseconds;
    // scores = qH @ kHᵀ * scale，再 masked_fill(mask==0, -1e3)。
    sw = Stopwatch()..start();
    final scores =
        ops.linear(NnTensor(qH, [n, kHeadDim]), NnTensor(kH, [n, kHeadDim]));
    acc.scoresMs += sw.elapsedMilliseconds;
    sw = Stopwatch()..start();
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
    acc.softmaxMs += sw.elapsedMilliseconds;
    sw = Stopwatch()..start();
    final o =
        ops.matmul(NnTensor(attn, [n, n]), NnTensor(vH, [n, kHeadDim]));
    acc.avMs += sw.elapsedMilliseconds;
    sw = Stopwatch()..start();
    for (var t = 0; t < n; t++) {
      ctx.setRange(t * kDim + off, t * kDim + off + kHeadDim, o.data,
          t * kHeadDim);
    }
    acc.copyMs += sw.elapsedMilliseconds;
  }
  sw = Stopwatch()..start();
  final r = ops.linear(NnTensor(ctx, [n, kDim]), blk.outW, bias: blk.outB);
  acc.outProjMs += sw.elapsedMilliseconds;
  return r;
}

/// TransformerBlock（pre-LN），逐字抄自 musiq_dart.dart 的 _blockForward。
NnTensor profBlockForward(
    NnTensor x, ProfBlockW blk, Int32List mask, ProfTrAcc acc) {
  var sw = Stopwatch()..start();
  var y = ops.layerNorm(x, [kDim], blk.norm1W, blk.norm1B, eps: 1e-6);
  acc.lnMs += sw.elapsedMilliseconds;
  y = profAttention(y, blk, mask, acc);
  sw = Stopwatch()..start();
  final out = NnTensor.zeros(x.shape);
  for (var i = 0; i < x.numel; i++) {
    out.data[i] = x.data[i] + y.data[i];
  }
  acc.residualMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  y = ops.layerNorm(out, [kDim], blk.norm2W, blk.norm2B, eps: 1e-6);
  acc.lnMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  y = ops.linear(y, blk.fc1W, bias: blk.fc1B);
  acc.fc1Ms += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  y = ops.gelu(y);
  acc.geluMs += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  y = ops.linear(y, blk.fc2W, bias: blk.fc2B);
  acc.fc2Ms += sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  for (var i = 0; i < out.numel; i++) {
    out.data[i] += y.data[i];
  }
  acc.residualMs += sw.elapsedMilliseconds;
  return out;
}

/// Transformer 编码器 + head，逐字抄自 MusiqDart.encoderScore。
/// [layersToRun] < 14 时用于外推测量（返回值无意义，勿当分数用）。
double profEncoderScore(Float32List emb, Int32List hse, Int32List scaleIds,
    Int32List mask, ProfW w, ProfTrAcc acc, int layersToRun,
    {bool traceLayers = false}) {
  var sw = Stopwatch()..start();
  final s = hse.length;
  final n = s + 1;
  final x = NnTensor.zeros([n, kDim]);
  // posembed/scale emb 加在 patch token 上，再前插 CLS（musiq_arch
  // TransformerEncoder.forward 的顺序）。
  x.data.setRange(kDim, n * kDim, emb);
  for (var i = 0; i < s; i++) {
    final row = (i + 1) * kDim;
    final pb = hse[i] * kDim, sb = scaleIds[i] * kDim;
    for (var j = 0; j < kDim; j++) {
      x.data[row + j] += w.posEmb[pb + j] + w.scaleEmb[sb + j];
    }
  }
  x.data.setRange(0, kDim, w.clsToken);
  final maskFull = Int32List(n);
  maskFull[0] = 1;
  maskFull.setRange(1, n, mask);
  acc.preludeMs += sw.elapsedMilliseconds;

  var h = x;
  for (var li = 0; li < layersToRun; li++) {
    sw = Stopwatch()..start();
    h = profBlockForward(h, w.blocks[li], maskFull, acc);
    acc.layerMs += sw.elapsedMilliseconds;
    if (traceLayers) {
      print('MUSIQ_PROF transformer.layer$li = ${sw.elapsedMilliseconds}ms');
    }
  }
  sw = Stopwatch()..start();
  h = ops.layerNorm(h, [kDim], w.encNormW, w.encNormB, eps: 1e-6);
  // head Linear(384→1) 作用于 CLS（第 0 行）。
  var score = w.headB[0];
  for (var j = 0; j < kDim; j++) {
    score += h.data[j] * w.headW.data[j];
  }
  acc.headMs += sw.elapsedMilliseconds;
  return score;
}

/// 拼接三尺度为单条序列，逐字抄自 MusiqDart._prepareSeq。
(NnTensor, Int32List, Int32List, Int32List) profPrepareSeq(
    List<MusiqScalePatches> scales) {
  var total = 0;
  for (final sc in scales) {
    total += sc.seqLen;
  }
  final patches = NnTensor.zeros([total, 3, kPatch, kPatch]);
  final hse = Int32List(total);
  final scaleIds = Int32List(total);
  final mask = Int32List(total);
  var off = 0;
  for (final sc in scales) {
    patches.data.setRange(off * 3 * kPatch * kPatch,
        (off + sc.seqLen) * 3 * kPatch * kPatch, sc.patches.data);
    hse.setRange(off, off + sc.seqLen, sc.hse);
    mask.setRange(off, off + sc.seqLen, sc.mask);
    for (var i = 0; i < sc.seqLen; i++) {
      scaleIds[off + i] = sc.scaleId;
    }
    off += sc.seqLen;
  }
  return (patches, hse, scaleIds, mask);
}

double maxAbsDiff(Float32List a, Float32List b) {
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > m) m = d;
  }
  return m;
}

Future<void> profile() async {
  if (!File(musiqWeightsPath).existsSync()) {
    print('MUSIQ_PROF_ERROR 缺少权重 $musiqWeightsPath');
    return;
  }
  final tickTimer =
      Timer.periodic(const Duration(milliseconds: 50), (_) => _ticks++);
  var sw = Stopwatch()..start();
  final rgba = busyFrame(kW, kH);
  print('MUSIQ_PROF busyFrame ${kW}x$kH gen = ${sw.elapsedMilliseconds}ms');
  sw = Stopwatch()..start();
  final pool = NnPool();
  await pool.start(math.max(2, Platform.numberOfProcessors - 4));
  print('MUSIQ_PROF pool.start workers=${pool.workerCount} '
      '= ${sw.elapsedMilliseconds}ms');
  try {
    sw = Stopwatch()..start();
    final model = MusiqDart.load(musiqWeightsPath);
    final prof = loadProfW(musiqWeightsPath);
    print('MUSIQ_PROF load = ${sw.elapsedMilliseconds}ms');

    // ---- 1) 直通：生产新入口 compute(musiqScoreInIsolate)（优化 10
    // 后状态层口径：后台 isolate 自起 NnPool，全流程移出 UI） ----
    var tk = _ticks;
    sw = Stopwatch()..start();
    final direct = await compute(musiqScoreInIsolate,
        {'rgba': rgba, 'width': kW, 'height': kH});
    print('MUSIQ_PROF total(compute入口) = ${sw.elapsedMilliseconds}ms '
        'score=$direct eventloopTicks=${_ticks - tk}');

    // ---- 2) 预处理（RGBA→[-1,1] NCHW，同步） ----
    tk = _ticks;
    sw = Stopwatch()..start();
    final x = musiqInput(rgba, kW, kH);
    print('MUSIQ_PROF preprocess = ${sw.elapsedMilliseconds}ms '
        'eventloopTicks=${_ticks - tk}');

    // ---- 3) 多尺度 patch 提取（同步；musiqMultiscalePatches 展开为
    // 逐尺度调用以分别计时，参数与之一致） ----
    tk = _ticks;
    final scales = <MusiqScalePatches>[];
    final longerSides = [224, 384];
    for (var i = 0; i < longerSides.length; i++) {
      sw = Stopwatch()..start();
      final sc = musiqExtractScale(x, longerSides[i], i);
      print('MUSIQ_PROF patch.scale$i(longerSide=${longerSides[i]}) '
          '= ${sw.elapsedMilliseconds}ms '
          'rh=${sc.rh} rw=${sc.rw} grid=${sc.countH}x${sc.countW} '
          'real=${sc.realPatches} seqLen=${sc.seqLen}');
      scales.add(sc);
    }
    sw = Stopwatch()..start();
    final scRaw = musiqExtractScale(x, null, 2);
    print('MUSIQ_PROF patch.scale2(原始分辨率) '
        '= ${sw.elapsedMilliseconds}ms '
        'rh=${scRaw.rh} rw=${scRaw.rw} grid=${scRaw.countH}x${scRaw.countW} '
        'real=${scRaw.realPatches} seqLen=${scRaw.seqLen}');
    scales.add(scRaw);
    sw = Stopwatch()..start();
    final (patches, hse, scaleIds, mask) = profPrepareSeq(scales);
    final prepareMs = sw.elapsedMilliseconds;
    final tokens = hse.length + 1;
    print('MUSIQ_PROF patches=${hse.length} tokens=$tokens '
        'scales=[${scales.map((s) => s.seqLen).join(',')}] '
        'prepareSeq=${prepareMs}ms eventloopTicks=${_ticks - tk}');

    // ---- 4) 复刻保真校验（8 patch 小规模，与公开 API 位级对拍） ----
    const cs = 8;
    final small = NnTensor(
        Float32List.fromList(
            patches.data.sublist(0, cs * 3 * kPatch * kPatch)),
        [cs, 3, kPatch, kPatch]);
    final tRef = await model.tokenizerForwardParallel(small, pool);
    final tProf = await profTokenizerForwardParallel(
        small, pool, prof, ProfTokAcc());
    final eRef = await model.embeddingForwardParallel(tRef, pool);
    final eProf = await profEmbeddingForwardParallel(
        tRef, pool, prof, ProfEmbAcc());
    final hse8 = Int32List.fromList(hse.sublist(0, cs));
    final sc8 = Int32List.fromList(scaleIds.sublist(0, cs));
    final m8 = Int32List.fromList(mask.sublist(0, cs));
    final sRef = model.encoderScore(eRef.data, hse8, sc8, m8);
    final sProf = profEncoderScore(
        eRef.data, hse8, sc8, m8, prof, ProfTrAcc(), kLayers);
    print('MUSIQ_PROF check tokenizer.maxAbs='
        '${maxAbsDiff(tRef.data, tProf.data)} '
        'embedding.maxAbs=${maxAbsDiff(eRef.data, eProf.data)} '
        'encoder.diff=${(sRef - sProf).abs()}（应全为 0）');

    // ---- 5) tokenizer 前向（全量 5134 patch 级；pool conv vs 同步 op） ----
    final accTok = ProfTokAcc();
    tk = _ticks;
    sw = Stopwatch()..start();
    final tok =
        await profTokenizerForwardParallel(patches, pool, prof, accTok);
    print('MUSIQ_PROF tokenizer = ${sw.elapsedMilliseconds}ms '
        'eventloopTicks=${_ticks - tk}');
    for (final (name, ms) in accTok.convs) {
      print('MUSIQ_PROF tokenizer.conv.$name(pool) = ${ms}ms');
    }
    print('MUSIQ_PROF tokenizer.pool-conv等待 = ${accTok.poolMs}ms');
    print('MUSIQ_PROF tokenizer.sync-ops(GN/relu/maxpool/pad/residual) '
        '= ${accTok.syncMs}ms');

    // ---- 6) embedding GEMM（pool） ----
    final accEmb = ProfEmbAcc();
    tk = _ticks;
    sw = Stopwatch()..start();
    final emb = await profEmbeddingForwardParallel(tok, pool, prof, accEmb);
    print('MUSIQ_PROF embed = ${sw.elapsedMilliseconds}ms '
        'eventloopTicks=${_ticks - tk}');
    print('MUSIQ_PROF embed.flatten(NHWC展平,同步) = ${accEmb.flatMs}ms');
    print('MUSIQ_PROF embed.gemm(pool等待) = ${accEmb.gemmMs}ms');
    print('MUSIQ_PROF embed.bias(同步) = ${accEmb.biasMs}ms');

    // ---- 7) transformer：只实测前 kMeasuredLayers 层再 ×7 外推 ----
    final accTr = ProfTrAcc();
    tk = _ticks;
    profEncoderScore(emb.data, hse, scaleIds, mask, prof, accTr,
        kMeasuredLayers,
        traceLayers: true);
    final trTicks = _ticks - tk;
    const ext = kLayers / kMeasuredLayers;
    int xp(int v) => (v * ext).round();
    print('MUSIQ_PROF transformer = ${xp(accTr.layerMs)}ms'
        '（外推：实测前 $kMeasuredLayers 层 ${accTr.layerMs}ms × $ext）'
        ' eventloopTicks=$trTicks');
    print('MUSIQ_PROF transformer.prelude(pos/scale emb + CLS) '
        '= ${accTr.preludeMs}ms（实测，不外推）');
    print('MUSIQ_PROF transformer.qkv(同步sgemm) = ${xp(accTr.qkvMs)}ms（外推）');
    print('MUSIQ_PROF transformer.scores QK^T(同步sgemm) '
        '= ${xp(accTr.scoresMs)}ms（外推）');
    print('MUSIQ_PROF transformer.softmax(含mask填充,同步逐元素) '
        '= ${xp(accTr.softmaxMs)}ms（外推）');
    print('MUSIQ_PROF transformer.AV(同步sgemm) = ${xp(accTr.avMs)}ms（外推）');
    print('MUSIQ_PROF transformer.out_proj(同步sgemm) '
        '= ${xp(accTr.outProjMs)}ms（外推）');
    print('MUSIQ_PROF transformer.fc1(同步sgemm) = ${xp(accTr.fc1Ms)}ms（外推）');
    print('MUSIQ_PROF transformer.gelu(同步逐元素) = ${xp(accTr.geluMs)}ms（外推）');
    print('MUSIQ_PROF transformer.fc2(同步sgemm) = ${xp(accTr.fc2Ms)}ms（外推）');
    print('MUSIQ_PROF transformer.layerNorm(同步) = ${xp(accTr.lnMs)}ms（外推）');
    print('MUSIQ_PROF transformer.residual(同步) '
        '= ${xp(accTr.residualMs)}ms（外推）');
    print('MUSIQ_PROF transformer.head切片拷贝(同步) '
        '= ${xp(accTr.copyMs)}ms（外推）');
    print('MUSIQ_PROF transformer.gemm(同步sgemm合计) '
        '= ${xp(accTr.gemmMs)}ms（外推）');
    print('MUSIQ_PROF transformer.sync-ops(LN/softmax/gelu/residual/拷贝合计) '
        '= ${xp(accTr.syncOpsMs)}ms（外推）');
    print('MUSIQ_PROF transformer.pool-wait = 0ms（实现未走 pool，'
        '全程堵在调用 isolate）');

    // ---- 8) head（encoder_norm + head Linear，实测；输入只过了
    // kMeasuredLayers 层，值无意义仅计时） ----
    print('MUSIQ_PROF head = ${accTr.headMs}ms（实测）');

    // ---- 9) 汇总 ----
    final poolBusy = accTok.poolMs + accEmb.gemmMs;
    final uiSync = accTok.syncMs +
        accEmb.flatMs +
        accEmb.biasMs +
        accTr.preludeMs +
        xp(accTr.layerMs) +
        accTr.headMs;
    print('MUSIQ_PROF summary pool忙碌 ≈ ${poolBusy}ms；'
        '调用 isolate 同步 ≈ ${uiSync}ms（含 transformer 外推）；'
        'transformer 窗口内 pool 完全空闲');
  } finally {
    tickTimer.cancel();
    pool.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('musiq prof')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await profile();
    } catch (e, st) {
      print('MUSIQ_PROF_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
