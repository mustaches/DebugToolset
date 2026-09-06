/// GPU NN 的 fp16 打包/解包纯函数与整网权重预打包（**纯 Dart，无
/// dart:ui/Flutter 依赖**，可在后台 isolate 经 compute 执行）。
///
/// 背景：三条 GPU 纹理驻留链（VGG16/RN50/InceptionV3）的 load 原先在
/// UI isolate 同步做「NnwReader 读 + fp16 打包」大循环，被并发 CPU
/// 风暴饿死时造成 >2 分钟「未响应」。本文件把全部 CPU 重活抽成纯
/// 函数：三条链的 load 改为**整网一次 compute** 在后台 isolate 完成
/// 读取与打包（[packVgg16Weights]/[packRn50Weights]/
/// [packInceptionWeights]），UI 侧仅
/// [GpuNnBackend.uploadPackedConvWeights] 上传纹理；大输入特征图的
/// 打包（[packFeatureInIsolate]/[packFeatureBandsInIsolate]）同样可
/// 放后台。
///
/// [GpuNnBackend] 的同名静态方法（packFeature/packWeightsPass/
/// packBias/unpackFeature/packFeatureBand/unpackFeatureBandInto/
/// embed1x1）与顶层 floatToHalfBits/halfBitsToFloat 均委托/转发本
/// 文件，数值与调用点签名逐位不变。
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'nnw_reader.dart';
import 'tensor.dart';

/// 纹理边长上限（保守取 8192，GL/D3D 桌面普遍保证；同
/// [GpuNnBackend.maxTextureDim]）。
const int kGpuNnMaxTextureDim = 8192;

/// 单 pass 最大输入通道组数（与 shader MAX_CG 一致，cin ≤ 256/pass；
/// 同 [GpuNnBackend.maxChannelGroupsPerPass]）。
const int kMaxChannelGroupsPerPass = 64;

/// float32 → IEEE half 位型（0..65535），舍入到最近。
int floatToHalfBits(double v) {
  if (v.isNaN) return 0x7E00;
  final s = v < 0 ? 0x8000 : 0;
  final av = v.abs();
  if (av >= 65520.0) return s | 0x7C00; // 上溢 → inf
  if (av < 6.103515625e-05) {
    // 次正规/零：bits = round(av * 2^24)
    return s | (av * 16777216.0).round().clamp(0, 1023);
  }
  var e = (math.log(av) / math.ln2).floor().clamp(-14, 15);
  var m = ((av / math.pow(2.0, e) - 1.0) * 1024.0).round();
  if (m >= 1024) {
    m = 0;
    e += 1;
  }
  return s | ((e + 15) << 10) | m;
}

/// IEEE half 位型 → float32。
double halfBitsToFloat(int b) {
  final s = (b & 0x8000) != 0 ? -1.0 : 1.0;
  final e = (b >> 10) & 0x1F;
  final m = b & 0x3FF;
  if (e == 0) return s * m * 5.9604644775390625e-08; // 次正规: m*2^-24
  if (e == 31) return s * 65504.0; // inf/nan 钳位
  return s * (1024 + m) * math.pow(2.0, e - 25).toDouble();
}

/// 特征图 NCHW fp32 → fp16 折叠打包（返回 halves 与物理纹理尺寸）。
(Uint16List, int, int) packFeature(
    Float32List data, int cin, int h, int w, int cinP) {
  final cinG = cinP ~/ 4;
  final texels = 2 * cinG * h * w;
  final tw = math.min(kGpuNnMaxTextureDim, texels);
  final th = (texels + tw - 1) ~/ tw;
  final halves = Uint16List(tw * th * 2);
  for (var ci = 0; ci < cin; ci++) {
    final gi = ci >> 2, k = ci & 3;
    final srcBase = ci * h * w;
    final dstBase = gi * h * w * 4 + k;
    for (var i = 0; i < h * w; i++) {
      halves[dstBase + i * 4] = floatToHalfBits(data[srcBase + i]);
    }
  }
  return (halves, tw, th);
}

/// 权重 [cout, cin, kH, kW] 某 pass（输入通道组 [giBase, giBase+cinGpass)
/// ）→ fp16 折叠打包（cell=((go*cinGpass+gi0)*TAPS+tap)*4+co，
/// TAPS=kH*kW，tap=r*kW+c 行主序）。
(Uint16List, int, int) packWeightsPass(Float32List w, int cout,
    int cin, int cinP, int coutP, int giBase, int cinGpass,
    {int kH = 3, int kW = 3}) {
  final coutG = coutP ~/ 4;
  final taps = kH * kW;
  final cells = coutG * cinGpass * taps * 4;
  final texels = cells * 2;
  final tw = math.min(kGpuNnMaxTextureDim, texels);
  final th = (texels + tw - 1) ~/ tw;
  final halves = Uint16List(tw * th * 2);
  for (var go = 0; go < coutG; go++) {
    for (var gi0 = 0; gi0 < cinGpass; gi0++) {
      final gi = giBase + gi0;
      for (var tap = 0; tap < taps; tap++) {
        for (var co = 0; co < 4; co++) {
          final cell = ((go * cinGpass + gi0) * taps + tap) * 4 + co;
          final coCh = go * 4 + co;
          for (var k = 0; k < 4; k++) {
            final ciCh = gi * 4 + k;
            final v = (coCh < cout && ciCh < cin)
                ? w[(coCh * cin + ciCh) * taps + tap]
                : 0.0;
            halves[cell * 4 + k] = floatToHalfBits(v);
          }
        }
      }
    }
  }
  return (halves, tw, th);
}

/// 偏置 [cout] → 宽 coutG*2、高 1 的 fp16 纹理（pad 通道补 0）。
(Uint16List, int) packBias(Float32List? bias, int cout, int coutP) {
  final coutG = coutP ~/ 4;
  final halves = Uint16List(coutG * 4);
  if (bias != null) {
    for (var c = 0; c < cout; c++) {
      halves[c] = floatToHalfBits(bias[c]);
    }
  }
  return (halves, coutG * 2);
}

/// fp16 折叠打包输出 → NCHW fp32（丢弃 pad 通道）。
Float32List unpackFeature(
    Uint16List halves, int cout, int h, int w, int coutP) {
  final out = Float32List(cout * h * w);
  for (var co = 0; co < cout; co++) {
    final go = co >> 2, k = co & 3;
    final srcBase = go * h * w * 4 + k;
    final dstBase = co * h * w;
    for (var i = 0; i < h * w; i++) {
      out[dstBase + i] = halfBitsToFloat(halves[srcBase + i * 4]);
    }
  }
  return out;
}

/// [packFeature] 的带切片版：只装全局行 [g0, g0+th)（分块上传用）。
(Uint16List, int, int) packFeatureBand(Float32List data, int cin,
    int h, int w, int cinP, int g0, int th) {
  final cinG = cinP ~/ 4;
  final texels = 2 * cinG * th * w;
  final tw = math.min(kGpuNnMaxTextureDim, texels);
  final thTex = (texels + tw - 1) ~/ tw;
  final halves = Uint16List(tw * thTex * 2);
  for (var ci = 0; ci < cin; ci++) {
    final gi = ci >> 2, k = ci & 3;
    final srcBase = ci * h * w + g0 * w;
    final dstBase = gi * th * w * 4 + k;
    for (var i = 0; i < th * w; i++) {
      halves[dstBase + i * 4] = floatToHalfBits(data[srcBase + i]);
    }
  }
  return (halves, tw, thTex);
}

/// [unpackFeature] 的带切片版：把带 halves 解包进完整缓冲 [out] 的
/// 全局行 [g0, g0+th)（分块回读用）。
void unpackFeatureBandInto(Uint16List halves, Float32List out,
    int cout, int h, int w, int coutP, int g0, int th) {
  for (var co = 0; co < cout; co++) {
    final go = co >> 2, k = co & 3;
    final srcBase = go * th * w * 4 + k;
    final dstBase = co * h * w + g0 * w;
    for (var i = 0; i < th * w; i++) {
      out[dstBase + i] = halfBitsToFloat(halves[srcBase + i * 4]);
    }
  }
}

/// 1x1/s1/p0 权重 [cout, cin, 1, 1] → 等效 3x3/s1/p1（中心 tap 嵌入）。
NnTensor embed1x1(NnTensor weight) {
  final cout = weight.shape[0], cin = weight.shape[1];
  final out = NnTensor.zeros([cout, cin, 3, 3]);
  for (var i = 0; i < cout * cin; i++) {
    out.data[i * 9 + 4] = weight.data[i];
  }
  return out;
}

// ------------------------------------------------------------------
// 整网权重预打包（后台 isolate 产物，全部为可跨 isolate 发送的
// 普通对象/TypedData；UI 侧经 GpuNnBackend.uploadPackedConvWeights
// 逐 conv 上传纹理）。
// ------------------------------------------------------------------

/// 一个 conv 的打包权重（多 pass 时每 pass 一 (halves, tw, th)）。
class PackedConvWeights {
  PackedConvWeights(this.passes, this.biasHalves, this.biasTexW, this.cout,
      this.coutPadded, this.kH, this.kW);

  /// 各 pass 的 (halves, 物理纹理宽, 物理纹理高)。
  final List<(Uint16List, int, int)> passes;

  /// 偏置 halves（无偏置为 null）与其物理纹理宽（高恒 1）。
  final Uint16List? biasHalves;
  final int biasTexW;

  final int cout, coutPadded, kH, kW;
}

/// 与 [GpuNnBackend.uploadConvWeights] 相同的打包逻辑（纯 CPU 部分，
/// 可在后台 isolate 执行）。
PackedConvWeights packConvWeights(NnTensor weight, int cinP,
    {Float32List? bias}) {
  final cout = weight.shape[0], cin = weight.shape[1];
  final kH = weight.shape[2], kW = weight.shape[3];
  final coutP = (cout + 3) & ~3;
  final cinG = cinP ~/ 4;
  final passes = <(Uint16List, int, int)>[];
  for (var giBase = 0; giBase < cinG; giBase += kMaxChannelGroupsPerPass) {
    final cinGpass = math.min(kMaxChannelGroupsPerPass, cinG - giBase);
    passes.add(packWeightsPass(
        weight.data, cout, cin, cinP, coutP, giBase, cinGpass,
        kH: kH, kW: kW));
  }
  Uint16List? biasHalves;
  var biasTexW = 0;
  if (bias != null) {
    final (h, tw) = packBias(bias, cout, coutP);
    biasHalves = h;
    biasTexW = tw;
  }
  return PackedConvWeights(
      passes, biasHalves, biasTexW, cout, coutP, kH, kW);
}

/// VGG16 整网打包结果（[convs] 按消息中 convIndices 顺序）。
class PackedVgg16Weights {
  PackedVgg16Weights(this.convs, this.cin);

  final List<PackedConvWeights> convs;

  /// 各 conv 的输入通道数（未填充）。
  final List<int> cin;
}

/// compute() 入口：VGG16 整网打包。消息为 (nnwPath, convIndices)
/// （如 Vgg16Dart.convIndices）。
@pragma('vm:entry-point')
PackedVgg16Weights packVgg16Weights((String, List<int>) msg) {
  final (nnwPath, convIndices) = msg;
  final reader = NnwReader.open(nnwPath);
  try {
    final convs = <PackedConvWeights>[];
    final cin = <int>[];
    for (final idx in convIndices) {
      final w = reader.readTensor('features.$idx.weight');
      final b = reader.tensor('features.$idx.bias').$1;
      final cinP = (w.shape[1] + 3) & ~3;
      convs.add(packConvWeights(w, cinP, bias: b));
      cin.add(w.shape[1]);
    }
    return PackedVgg16Weights(convs, cin);
  } finally {
    reader.close();
  }
}

/// CLIP RN50 一个 Bottleneck 的打包权重（ds 仅每层 block 0 非空）。
class PackedRn50Block {
  PackedRn50Block(this.c1, this.c2, this.c3, this.ds);

  final PackedConvWeights c1, c2, c3;
  final PackedConvWeights? ds;
}

/// CLIP RN50 整网打包结果（stem 3 个 conv + 16 个 Bottleneck）。
class PackedRn50Weights {
  PackedRn50Weights(this.stem, this.blocks);

  final List<PackedConvWeights> stem;
  final List<PackedRn50Block> blocks;
}

/// compute() 入口：CLIP RN50 整网打包（1x1 先 embed1x1；attention
/// 权重不打包）。消息为 (nnwPath, layerConfig)，layerConfig 为
/// [[planes, blocks, stride], ...]（同 ClipRn50Dart 的层配置，本函数
/// 只用 blocks 列）。
@pragma('vm:entry-point')
PackedRn50Weights packRn50Weights((String, List<List<int>>) msg) {
  final (nnwPath, layerConfig) = msg;
  final reader = NnwReader.open(nnwPath);
  try {
    PackedConvWeights up(String wp, String bp, {bool embed = false}) {
      var w = reader.readTensor(wp);
      if (embed) w = embed1x1(w);
      final cinP = (w.shape[1] + 3) & ~3;
      return packConvWeights(w, cinP, bias: reader.tensor(bp).$1);
    }

    final stem = <PackedConvWeights>[
      for (var i = 1; i <= 3; i++)
        up('visual.conv$i.weight', 'visual.conv$i.bias'),
    ];
    final blocks = <PackedRn50Block>[];
    for (var li = 0; li < layerConfig.length; li++) {
      final lv = li + 1;
      for (var bi = 0; bi < layerConfig[li][1]; bi++) {
        blocks.add(PackedRn50Block(
          up('visual.layer$lv.$bi.conv1.weight',
              'visual.layer$lv.$bi.conv1.bias',
              embed: true),
          up('visual.layer$lv.$bi.conv2.weight',
              'visual.layer$lv.$bi.conv2.bias'),
          up('visual.layer$lv.$bi.conv3.weight',
              'visual.layer$lv.$bi.conv3.bias',
              embed: true),
          bi == 0
              ? up('visual.layer$lv.$bi.downsample.0.weight',
                  'visual.layer$lv.$bi.downsample.0.bias',
                  embed: true)
              : null,
        ));
      }
    }
    return PackedRn50Weights(stem, blocks);
  } finally {
    reader.close();
  }
}

/// compute() 入口：InceptionV3（FID 版）整网打包（全部 BasicConv2d，
/// 键同 CPU 版，如 `Mixed_5b.branch1x1.conv`）。分支输出通道数须均为
/// 4 的倍数，不满足抛 [UnsupportedError]（经 compute 传播回调用方，
/// 语义与原 load 内抛出一致）。
@pragma('vm:entry-point')
Map<String, PackedConvWeights> packInceptionWeights(String nnwPath) {
  final reader = NnwReader.open(nnwPath);
  try {
    final conv = <String, PackedConvWeights>{};
    for (final name in reader.tensorNames) {
      if (!name.endsWith('.conv.weight')) {
        continue;
      }
      final base = name.substring(0, name.length - '.conv.weight'.length);
      final w = reader.readTensor(name);
      if (w.shape[0] % 4 != 0) {
        throw UnsupportedError('InceptionV3Gpu: $base 输出通道 '
            '${w.shape[0]} 非 4 的倍数（concat 无法按组对齐）');
      }
      final cinP = (w.shape[1] + 3) & ~3;
      conv[base] =
          packConvWeights(w, cinP, bias: reader.tensor('$base.conv.bias').$1);
    }
    return conv;
  } finally {
    reader.close();
  }
}

/// compute() 入口：大输入特征图打包（消息为 (data, cin, h, w, cinP)），
/// 供 [GpuNnBackend.uploadFeatureMap] 把 UI 上的 fp16 打包大循环挪到
/// 后台 isolate。
@pragma('vm:entry-point')
(Uint16List, int, int) packFeatureInIsolate(
        (Float32List, int, int, int, int) msg) =>
    packFeature(msg.$1, msg.$2, msg.$3, msg.$4, msg.$5);

/// compute() 入口：分块上传的各带打包（消息为 (data, cin, h, w, cinP,
/// bandHeights)，返回与带序一致的 (halves, tw, th) 列表），供
/// [GpuNnBackend.uploadFeatureMapBanded] 使用。
@pragma('vm:entry-point')
List<(Uint16List, int, int)> packFeatureBandsInIsolate(
    (Float32List, int, int, int, int, List<int>) msg) {
  final (data, cin, h, w, cinP, heights) = msg;
  final out = <(Uint16List, int, int)>[];
  var g = 0;
  for (final th in heights) {
    out.add(packFeatureBand(data, cin, h, w, cinP, g, th));
    g += th;
  }
  return out;
}

// ------------------------------------------------------------------
// 下载侧解包（优化 8）：fp16→fp32 逐元素 CPU 循环放后台 isolate，
// TransferableTypedData 进出避免拷贝。数值与就地解包逐位一致（同一
// halfBitsToFloat 逐元素调用）。
// ------------------------------------------------------------------

/// compute() 入口：整图回读 halves 解包为 NCHW fp32（消息为
/// (TransferableTypedData halves, cout, h, w, coutP)，返回
/// TransferableTypedData(Float32List [cout*h*w])；供
/// [GpuNnBackend.downloadFeatureMap] 大图路径使用。
@pragma('vm:entry-point')
TransferableTypedData unpackFeatureInIsolate(
    (TransferableTypedData, int, int, int, int) msg) {
  final halves = msg.$1.materialize().asUint16List();
  final out = unpackFeature(halves, msg.$2, msg.$3, msg.$4, msg.$5);
  return TransferableTypedData.fromList([out]);
}

/// compute() 入口：单带回读 halves 解包（优化 8 逐带流水线用）。消息
/// 为 (TransferableTypedData halves, cout, h, w, coutP, g0, th)（h/g0
/// 仅保留完整几何上下文；返回该带全局行 [g0, g0+th) 的 NCHW fp32 段
/// TransferableTypedData(Float32List [cout*th*w]，每通道连续 th*w
/// 元素），UI 侧按通道 setRange 拼进完整缓冲。
@pragma('vm:entry-point')
TransferableTypedData unpackFeatureBandInIsolate(
    (TransferableTypedData, int, int, int, int, int, int) msg) {
  final halves = msg.$1.materialize().asUint16List();
  final cout = msg.$2, w = msg.$4, th = msg.$7;
  final band = Float32List(cout * th * w);
  for (var co = 0; co < cout; co++) {
    final go = co >> 2, k = co & 3;
    final srcBase = go * th * w * 4 + k;
    final dstBase = co * th * w;
    for (var i = 0; i < th * w; i++) {
      band[dstBase + i] = halfBitsToFloat(halves[srcBase + i * 4]);
    }
  }
  return TransferableTypedData.fromList([band]);
}
