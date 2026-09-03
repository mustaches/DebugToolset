/// NN conv2d 的 GPU 后端：FragmentShader + fp16 打包纹理（每物理纹素
/// 2 个 IEEE half，折叠线性布局，格式见 shaders/nn/nn_conv3x3_f16.frag
/// 头注释）。
///
/// 背景与限制：
/// - 本机 Impeller（flutter test 与真实 Windows 桌面一致）离屏渲染目标
///   只有 RGBA8——toImageSync(targetFormat: rgbaFloat32) 被静默降级为
///   RGBA8（输出钳位 [0,1] 并 8bit 量化，2026-09 spike 实测）。故中间
///   张量以 fp16 存储、shader 内解码为 fp32 累加，典型相对误差 ~1e-3。
/// - 仅 UI isolate 可用（依赖 dart:ui）；纹理上传/回读只有异步 API，
///   因此 [conv2d] 同步接口无法实现（抛 [UnimplementedError]），实际
///   入口为异步 [conv2dAsync] 或纹理驻留三件套
///   [uploadFeatureMap]/[conv2dGpu]/[downloadFeatureMap]；另有驻留
///   [reluGpu]/[maxPool2x2Gpu]/[l2PoolDistsGpu]（VGG16 池化变体）。
/// - 仅支持 groups==1、stride 1、3x3/pad 1 与 1x1/pad 0（后者嵌入 3x3
///   中心 tap 实现）的卷积形状，通道数自动零填充到 4 的倍数；单 pass
///   覆盖 cin ≤ 256，更大 cin 自动多 pass 累加。不支持时抛
///   [UnsupportedError]，由调用方回退 CPU。
/// - 单纹理形态受折叠布局纹素数 < 2^24 约束（[isSupportedConv]）。更大
///   的特征图走**分块（banded）路径**：沿 H 切成若干等高带（每带一张
///   纹理，带高 16 的倍数、末带余量），conv/L2pooling 经
///   [shaders/nn/nn_stitch3_f16.frag] 把目标带 ±1 行 halo 拼成 padded
///   带后按带渲染（uYOff=1），maxpool/relu 逐带直接执行。入口为
///   [uploadFeatureMapBanded]/[conv2dGpuBanded]/[reluGpuBanded]/
///   [maxPool2x2GpuBanded]/[l2PoolDistsGpuBanded]/
///   [downloadFeatureMapBanded]，规划见 [planBandHeights]/
///   [planConvOutBands]。小图仍走单纹理路径，行为逐位不变。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'nn_engine.dart';
import 'tensor.dart';

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

/// GPU 驻留特征图纹理（fp16 折叠打包）。
class GpuNnTensor {
  GpuNnTensor(this.tex, this.shape, this.texW, this.texH, this.channelsPadded);

  final ui.Image tex;

  /// 逻辑 NCHW（未填充）。
  final List<int> shape;
  final int texW, texH;

  /// 零填充到 4 的倍数后的通道数。
  final int channelsPadded;

  void dispose() => tex.dispose();
}

/// 分块（banded）GPU 驻留特征图：沿 H 切成若干带，每带一张纹理
/// （[bands] 按行升序，[bandOffsets] 为各带起始全局行）。用于折叠布局
/// 总纹素数 ≥ 2^24 的大特征图；带高规划见 [GpuNnBackend.planBandHeights]。
class GpuNnBandedTensor {
  GpuNnBandedTensor(
      this.bands, this.bandOffsets, this.shape, this.channelsPadded);

  /// 各带纹理（每个 shape 为 [1, channelsPadded, 带高, W]）。
  final List<GpuNnTensor> bands;

  /// 各带起始全局行（与 [bands] 等长，升序）。
  final List<int> bandOffsets;

  /// 逻辑 NCHW（shape[1] 为未填充通道数，与单纹理路径语义一致）。
  final List<int> shape;

  /// 零填充到 4 的倍数后的通道数。
  final int channelsPadded;

  int get height => shape[2];
  int get width => shape[3];

  /// 各带高度。
  List<int> get bandHeights => [for (final b in bands) b.shape[2]];

  void dispose() {
    for (final b in bands) {
      b.dispose();
    }
  }
}

/// GPU 驻留卷积权重：多 pass 时每 pass 一张权重纹理（仅含该 pass 的
/// 输入通道组），外加可选偏置纹理。
class GpuConvWeights {
  GpuConvWeights(this.passTex, this.passTexW, this.passTexH, this.biasTex,
      this.cout, this.coutPadded);

  final List<ui.Image> passTex;
  final List<int> passTexW, passTexH;
  final ui.Image? biasTex;
  final int cout, coutPadded;

  void dispose() {
    for (final t in passTex) {
      t.dispose();
    }
    biasTex?.dispose();
  }
}

/// GPU NN 后端。经 [tryCreate] 获取（shader 加载失败返回 null）。
class GpuNnBackend implements NnBackend {
  GpuNnBackend._(this._conv3x3, this._relu, this._maxpool2x2, this._l2pool,
      this._stitch, this._dummy);

  final ui.FragmentProgram _conv3x3;

  /// 逐元素 ReLU（[reluGpu]）。
  final ui.FragmentProgram _relu;

  /// MaxPool 2x2/s2/p0（[maxPool2x2Gpu]）。
  final ui.FragmentProgram _maxpool2x2;

  /// DISTS L2pooling（[l2PoolDistsGpu]）。
  final ui.FragmentProgram _l2pool;

  /// 分块 halo 拼接（[_stitchBand]，分块路径专用）。
  final ui.FragmentProgram _stitch;

  /// 1x1 哑纹理：未使用的 sampler（uAccum/uBias/uSrcB/uSrcC 等）绑定它。
  final ui.Image _dummy;

  /// 单 pass 最大输入通道组数（与 shader MAX_CG 一致，cin ≤ 256/pass）。
  static const maxChannelGroupsPerPass = 64;

  /// 折叠布局物理纹素数上限（shader 内 float 索引须 < 2^24 保精确）。
  static const maxTexels = 1 << 24;

  /// 纹理边长上限（保守取 8192，GL/D3D 桌面普遍保证）。
  static const maxTextureDim = 8192;

  /// 分块路径的单带物理纹素数预算（2^23 = 32MB RGBA8/带，同时为
  /// padded 带（+2 行）预留余量；远小于 2^24 使带内 float 索引精确）。
  static const maxBandTexels = 1 << 23;

  /// 测试用：>0 时覆盖 [maxBandTexels] 作为单带预算，使小尺寸也能
  /// 强制走分块路径。生产代码勿动。
  static int debugMaxBandTexels = 0;

  static const _shaderAsset = 'shaders/nn/nn_conv3x3_f16.frag';
  static const _reluShaderAsset = 'shaders/nn/nn_relu_f16.frag';
  static const _maxpoolShaderAsset = 'shaders/nn/nn_maxpool2x2_f16.frag';
  static const _l2poolShaderAsset = 'shaders/nn/nn_l2pool_dists_f16.frag';
  static const _stitchShaderAsset = 'shaders/nn/nn_stitch3_f16.frag';

  static Future<GpuNnBackend?> tryCreate() async {
    try {
      final prog = await ui.FragmentProgram.fromAsset(_shaderAsset);
      final relu = await ui.FragmentProgram.fromAsset(_reluShaderAsset);
      final maxpool = await ui.FragmentProgram.fromAsset(_maxpoolShaderAsset);
      final l2pool = await ui.FragmentProgram.fromAsset(_l2poolShaderAsset);
      final stitch = await ui.FragmentProgram.fromAsset(_stitchShaderAsset);
      final dummy = await _upload(Uint16List(2), 1, 1);
      return GpuNnBackend._(prog, relu, maxpool, l2pool, stitch, dummy);
    } catch (e) {
      // ignore: avoid_print
      print('[GpuNnBackend] 初始化失败: $e');
      return null;
    }
  }

  /// 释放后端持有的资源（哑纹理）。调用前须先释放所有由本后端
  /// 创建的纹理/权重。
  void dispose() => _dummy.dispose();

  // ------------------------------------------------------------------
  // 支持的卷积形状
  // ------------------------------------------------------------------

  /// [conv2dAsync] 支持的参数形态（VGG/RN50 的 3x3/s1/p1 与 1x1/s1/p0，
  /// groups==1）。stride 2、depthwise、非对称 kernel 等返回 false。
  static bool isSupportedConv(
    NnTensor x,
    NnTensor weight, {
    int strideH = 1,
    int strideW = 1,
    int padH = 0,
    int padW = 0,
    int groups = 1,
  }) {
    if (x.rank != 4 || weight.rank != 4) return false;
    if (groups != 1 || strideH != 1 || strideW != 1) return false;
    final kh = weight.shape[2], kw = weight.shape[3];
    final is3x3 = kh == 3 && kw == 3 && padH == 1 && padW == 1;
    final is1x1 = kh == 1 && kw == 1 && padH == 0 && padW == 0;
    if (!is3x3 && !is1x1) return false;
    if (weight.shape[1] != x.channels) return false;
    final cinP = (x.channels + 3) & ~3, coutP = (weight.shape[0] + 3) & ~3;
    final h = x.height, w = x.width;
    // 输入/输出折叠纹素数 = 2 * (c/4) * H * W，须 < 2^24 且摊平后可放入
    // maxTextureDim 见方的纹理。
    for (final texels in [2 * (cinP ~/ 4) * h * w, 2 * (coutP ~/ 4) * h * w]) {
      if (texels >= maxTexels) return false;
      final rows = (texels + maxTextureDim - 1) ~/ maxTextureDim;
      if (rows > maxTextureDim) return false;
    }
    return true;
  }

  static void _requireSupported(
    NnTensor x,
    NnTensor weight, {
    int strideH = 1,
    int strideW = 1,
    int padH = 0,
    int padW = 0,
    int groups = 1,
  }) {
    if (!isSupportedConv(x, weight,
        strideH: strideH,
        strideW: strideW,
        padH: padH,
        padW: padW,
        groups: groups)) {
      throw UnsupportedError('GpuNnBackend 不支持的卷积形态: '
          'x=${x.shape} w=${weight.shape} s=$strideH,$strideW '
          'p=$padH,$padW g=$groups（调用方应回退 CPU）');
    }
  }

  // ------------------------------------------------------------------
  // 分块（banded）规划
  // ------------------------------------------------------------------

  static int get _bandBudget =>
      debugMaxBandTexels > 0 ? debugMaxBandTexels : maxBandTexels;

  /// 单带高度上界（未取整）：2*(cP/4)*(TH+2)*W ≤ 预算。不可行返回 null。
  static int? _bandRowBudget(int w, int cP) {
    final per = 2 * (cP ~/ 4) * w;
    if (per <= 0) return null;
    final th0 = _bandBudget ~/ per - 2;
    return th0 > 0 ? th0 : null;
  }

  /// 把 H 切成 TH 等高带 + 末带余量（1..TH）。
  static List<int> splitHeights(int h, int th) {
    final out = <int>[];
    var rem = h;
    while (rem > th) {
      out.add(th);
      rem -= th;
    }
    if (rem > 0) out.add(rem);
    return out;
  }

  /// 单张量（上传/池化输入等）的分块带高规划：非末带高为 16 的倍数
  /// （保证 maxpool 逐带执行的奇偶对齐），末带任意。整体单带能放下时
  /// 返回 [h]；W 过宽等不可行形态返回 null（调用方回退 CPU）。
  static List<int>? planBandHeights(int h, int w, int cP) {
    final th0 = _bandRowBudget(w, cP);
    if (th0 == null) return null;
    if (th0 >= h) return [h];
    final th = (th0 ~/ 16) * 16;
    if (th < 16) return null;
    return splitHeights(h, th);
  }

  static List<int> _offsetsOf(List<int> heights) {
    final out = <int>[];
    var off = 0;
    for (final th in heights) {
      out.add(off);
      off += th;
    }
    return out;
  }

  /// stitch 覆盖校验：目标各带的 halo 行区间 [g-halo, g+th+halo)（裁剪
  /// 到 [0,H)）落在源带的并集须 ≤3 张（shader 只有 3 个源 sampler）。
  static bool stitchCoverageOk(
      List<int> inHeights, List<int> outHeights, int halo) {
    final inOff = _offsetsOf(inHeights);
    final h = inHeights.fold<int>(0, (a, b) => a + b);
    var g = 0;
    for (final th in outHeights) {
      final lo = math.max(g - halo, 0), hi = math.min(g + th + halo, h);
      var count = 0;
      for (var i = 0; i < inHeights.length; i++) {
        final s0 = inOff[i], s1 = s0 + inHeights[i];
        if (s0 < hi && s1 > lo) count++;
      }
      if (count > 3) return false;
      g += th;
    }
    return true;
  }

  /// conv 输出分块规划：通道数不变时直接沿用输入分块（stitch 覆盖
  /// 恒为「前/本/后」3 带）；通道数变化时按输出通道预算取带高，并不
  /// 粗于输入非末带最小高度（保证覆盖 ≤3）。单带能放下但覆盖 >3（输
  /// 入 ≥4 带）时回退多带。不可行返回 null。
  static List<int>? planConvOutBands(
      List<int> inHeights, int h, int w, int cinP, int coutP) {
    if (coutP == cinP) return List.of(inHeights);
    final th0 = _bandRowBudget(w, coutP);
    if (th0 == null) return null;
    if (th0 >= h) {
      final single = [h];
      if (stitchCoverageOk(inHeights, single, 1)) return single;
    }
    var cap = h;
    if (inHeights.length > 1) {
      cap = inHeights
          .sublist(0, inHeights.length - 1)
          .reduce(math.min);
    }
    final th = (math.min(th0, cap) ~/ 16) * 16;
    if (th < 16) return null;
    final cand = splitHeights(h, th);
    return stitchCoverageOk(inHeights, cand, 1) ? cand : null;
  }

  /// maxpool 的分块变换：非末带须偶高（奇偶对齐，由规划保证），末带
  /// 高 1 时输出为空带被丢弃。不满足返回 null（调用方回退 CPU）。
  static List<int>? poolBandsMax(List<int> heights) {
    final out = <int>[];
    for (var i = 0; i < heights.length; i++) {
      final th = heights[i];
      if (i < heights.length - 1 && th.isOdd) return null;
      final q = th ~/ 2;
      if (q == 0) continue; // 末带高 1：floor(1/2)=0，丢弃
      out.add(q);
    }
    return out.isEmpty ? null : out;
  }

  /// L2pooling 的分块变换：各带独立 ceil(th/2)（halo 走 stitch，无
  /// 奇偶约束）。
  static List<int> poolBandsL2(List<int> heights) =>
      [for (final th in heights) (th + 1) ~/ 2];

  // ------------------------------------------------------------------
  // 打包（CPU 侧）
  // ------------------------------------------------------------------

  /// 特征图 NCHW fp32 → fp16 折叠打包（返回 halves 与物理纹理尺寸）。
  static (Uint16List, int, int) packFeature(
      Float32List data, int cin, int h, int w, int cinP) {
    final cinG = cinP ~/ 4;
    final texels = 2 * cinG * h * w;
    final tw = math.min(maxTextureDim, texels);
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

  /// 权重 [cout, cin, 3, 3]（1x1 已嵌入中心 tap）某 pass（输入通道组
  /// [giBase, giBase+cinGpass)）→ fp16 折叠打包。
  static (Uint16List, int, int) packWeightsPass(Float32List w, int cout,
      int cin, int cinP, int coutP, int giBase, int cinGpass) {
    final coutG = coutP ~/ 4;
    final cells = coutG * cinGpass * 36;
    final texels = cells * 2;
    final tw = math.min(maxTextureDim, texels);
    final th = (texels + tw - 1) ~/ tw;
    final halves = Uint16List(tw * th * 2);
    for (var go = 0; go < coutG; go++) {
      for (var gi0 = 0; gi0 < cinGpass; gi0++) {
        final gi = giBase + gi0;
        for (var tap = 0; tap < 9; tap++) {
          for (var co = 0; co < 4; co++) {
            final cell = ((go * cinGpass + gi0) * 9 + tap) * 4 + co;
            final coCh = go * 4 + co;
            for (var k = 0; k < 4; k++) {
              final ciCh = gi * 4 + k;
              final v = (coCh < cout && ciCh < cin)
                  ? w[(coCh * cin + ciCh) * 9 + tap]
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
  static (Uint16List, int) packBias(Float32List? bias, int cout, int coutP) {
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
  static Float32List unpackFeature(
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
  static (Uint16List, int, int) packFeatureBand(Float32List data, int cin,
      int h, int w, int cinP, int g0, int th) {
    final cinG = cinP ~/ 4;
    final texels = 2 * cinG * th * w;
    final tw = math.min(maxTextureDim, texels);
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
  static void unpackFeatureBandInto(Uint16List halves, Float32List out,
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

  // ------------------------------------------------------------------
  // GPU 原语
  // ------------------------------------------------------------------

  static Future<ui.Image> _upload(Uint16List halves, int tw, int th) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(halves.buffer.asUint8List(), tw, th,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  static Future<Uint16List> _readback(ui.Image img) async {
    final bd = await img.toByteData();
    return bd!.buffer.asUint16List();
  }

  // ------------------------------------------------------------------
  // 纹理驻留 API
  // ------------------------------------------------------------------

  /// 上传特征图（通道零填充到 4 的倍数）。batch 须为 1。
  Future<GpuNnTensor> uploadFeatureMap(NnTensor x) async {
    if (x.rank != 4 || x.batch != 1) {
      throw UnsupportedError('GpuNnBackend 仅支持 batch==1 的 4 维特征图');
    }
    final cin = x.channels, h = x.height, w = x.width;
    final cinP = (cin + 3) & ~3;
    final (halves, tw, th) = packFeature(x.data, cin, h, w, cinP);
    return GpuNnTensor(await _upload(halves, tw, th),
        List.unmodifiable(x.shape), tw, th, cinP);
  }

  /// 上传卷积权重（weight [cout, cin, 3, 3]；1x1 卷积请先嵌入 3x3 中心
  /// tap，见 [embed1x1]）。多 pass 时每 pass 一张纹理。
  Future<GpuConvWeights> uploadConvWeights(NnTensor weight, int cinP,
      {Float32List? bias}) async {
    final cout = weight.shape[0], cin = weight.shape[1];
    final coutP = (cout + 3) & ~3;
    final cinG = cinP ~/ 4;
    final passTex = <ui.Image>[];
    final passTexW = <int>[], passTexH = <int>[];
    for (var giBase = 0;
        giBase < cinG;
        giBase += maxChannelGroupsPerPass) {
      final cinGpass =
          math.min(maxChannelGroupsPerPass, cinG - giBase);
      final (halves, tw, th) = packWeightsPass(
          weight.data, cout, cin, cinP, coutP, giBase, cinGpass);
      passTex.add(await _upload(halves, tw, th));
      passTexW.add(tw);
      passTexH.add(th);
    }
    ui.Image? biasTex;
    if (bias != null) {
      final (halves, tw) = packBias(bias, cout, coutP);
      biasTex = await _upload(halves, tw, 1);
    }
    return GpuConvWeights(passTex, passTexW, passTexH, biasTex, cout, coutP);
  }

  /// 1x1/s1/p0 权重 [cout, cin, 1, 1] → 等效 3x3/s1/p1（中心 tap 嵌入）。
  static NnTensor embed1x1(NnTensor weight) {
    final cout = weight.shape[0], cin = weight.shape[1];
    final out = NnTensor.zeros([cout, cin, 3, 3]);
    for (var i = 0; i < cout * cin; i++) {
      out.data[i * 9 + 4] = weight.data[i];
    }
    return out;
  }

  /// GPU 驻留 conv3x3/s1/p1：输入输出均为打包纹理，同步执行（pass 提交
  /// 为同步光栅化，不含上传/回读）。输出通道保留 pad（取数时用
  /// [GpuConvWeights.cout] 截断）。
  ///
  /// 分块路径专用参数（单纹理路径保持默认，行为逐位不变）：
  /// [yOff] 为输入垂直偏移（padded 带输入为 1.0，行 0 是上 halo）；
  /// [outH] 为输出空间高（padded 带输入时 = 带高，小于输入高 th+2）。
  GpuNnTensor conv2dGpu(GpuNnTensor x, GpuConvWeights wgt,
      {double yOff = 0.0, int? outH}) {
    final h = x.shape[2], w = x.shape[3];
    final oH = outH ?? h;
    final cinG = x.channelsPadded ~/ 4;
    final coutG = wgt.coutPadded ~/ 4;
    final outTexels = 2 * coutG * oH * w;
    final outTW = math.min(maxTextureDim, outTexels);
    final outTH = (outTexels + outTW - 1) ~/ outTW;

    ui.Image? accum;
    for (var pass = 0; pass < wgt.passTex.length; pass++) {
      final giBase = pass * maxChannelGroupsPerPass;
      final cinGpass =
          math.min(maxChannelGroupsPerPass, cinG - giBase);
      final isLast = pass == wgt.passTex.length - 1;
      final shader = _conv3x3.fragmentShader();
      shader.setFloat(0, x.texW.toDouble());
      shader.setFloat(1, x.texH.toDouble());
      shader.setFloat(2, w.toDouble());
      shader.setFloat(3, h.toDouble());
      shader.setFloat(4, cinGpass.toDouble());
      shader.setFloat(5, giBase.toDouble());
      shader.setFloat(6, wgt.passTexW[pass].toDouble());
      shader.setFloat(7, wgt.passTexH[pass].toDouble());
      shader.setFloat(8, outTW.toDouble());
      shader.setFloat(9, outTH.toDouble());
      shader.setFloat(10, pass > 0 ? 1.0 : 0.0);
      shader.setFloat(11, isLast && wgt.biasTex != null ? 1.0 : 0.0);
      shader.setFloat(12, (coutG * 2).toDouble());
      shader.setFloat(13, yOff);
      shader.setFloat(14, w.toDouble());
      shader.setFloat(15, oH.toDouble());
      shader.setImageSampler(0, x.tex);
      shader.setImageSampler(1, wgt.passTex[pass]);
      shader.setImageSampler(2, accum ?? _dummy);
      shader.setImageSampler(3, wgt.biasTex ?? _dummy);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
          ui.Rect.fromLTWH(0, 0, outTW.toDouble(), outTH.toDouble()),
          ui.Paint()..shader = shader);
      final picture = recorder.endRecording();
      final out = picture.toImageSync(outTW, outTH);
      picture.dispose();
      accum?.dispose();
      accum = out;
    }
    return GpuNnTensor(
        accum!, [1, wgt.coutPadded, oH, w], outTW, outTH, wgt.coutPadded);
  }

  /// 单 sampler 全屏 pass 的公共提交（同步光栅化）。
  static ui.Image _renderPass(ui.FragmentShader shader, int tw, int th) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
        ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        ui.Paint()..shader = shader);
    final picture = recorder.endRecording();
    final out = picture.toImageSync(tw, th);
    picture.dispose();
    return out;
  }

  /// GPU 驻留 ReLU：逐元素 max(·,0)，布局/尺寸不变。
  GpuNnTensor reluGpu(GpuNnTensor x) {
    final shader = _relu.fragmentShader();
    shader.setFloat(0, x.texW.toDouble());
    shader.setFloat(1, x.texH.toDouble());
    shader.setImageSampler(0, x.tex);
    final out = _renderPass(shader, x.texW, x.texH);
    return GpuNnTensor(out, x.shape, x.texW, x.texH, x.channelsPadded);
  }

  /// 池化 pass 的公共部分（输出物理纹理尺寸按折叠布局摊平）。
  /// [yOff] 仅 L2pooling 的分块 padded 输入使用（其 shader 声明了该
  /// uniform；maxpool shader 无此 uniform，传 null 不设置）。
  GpuNnTensor _poolGpu(
      ui.FragmentProgram prog, GpuNnTensor x, int outH, int outW,
      {double? yOff}) {
    final h = x.shape[2], w = x.shape[3];
    final cinG = x.channelsPadded ~/ 4;
    final outTexels = 2 * cinG * outH * outW;
    final outTW = math.min(maxTextureDim, outTexels);
    final outTH = (outTexels + outTW - 1) ~/ outTW;
    final shader = prog.fragmentShader();
    shader.setFloat(0, x.texW.toDouble());
    shader.setFloat(1, x.texH.toDouble());
    shader.setFloat(2, w.toDouble());
    shader.setFloat(3, h.toDouble());
    shader.setFloat(4, outTW.toDouble());
    shader.setFloat(5, outTH.toDouble());
    shader.setFloat(6, outW.toDouble());
    shader.setFloat(7, outH.toDouble());
    if (yOff != null) shader.setFloat(8, yOff);
    shader.setImageSampler(0, x.tex);
    final out = _renderPass(shader, outTW, outTH);
    return GpuNnTensor(out, [1, x.channelsPadded, outH, outW], outTW, outTH,
        x.channelsPadded);
  }

  /// GPU 驻留 MaxPool 2x2/s2/p0：输出 floor(H/2)×floor(W/2)，通道不变。
  GpuNnTensor maxPool2x2Gpu(GpuNnTensor x) =>
      _poolGpu(_maxpool2x2, x, x.shape[2] ~/ 2, x.shape[3] ~/ 2);

  /// GPU 驻留 DISTS L2pooling（3×3 Hanning depthwise on x²，s2/p1，
  /// sqrt(out+1e-12)）：输出 floor((H+1)/2)×floor((W+1)/2)，通道不变，
  /// 与 ops.l2PoolingDists 同语义。[yOff] 为分块 padded 输入的垂直
  /// 偏移（单纹理路径固定 0.0，行为与旧版逐位一致）。
  GpuNnTensor l2PoolDistsGpu(GpuNnTensor x, {double yOff = 0.0}) =>
      _poolGpu(_l2pool, x, (x.shape[2] + 1) ~/ 2, (x.shape[3] + 1) ~/ 2,
          yOff: yOff);

  /// 回读 GPU 驻留特征图为 CPU 张量（丢弃 pad 通道）。
  Future<NnTensor> downloadFeatureMap(GpuNnTensor t, {int? channels}) async {
    final cout = channels ?? t.shape[1];
    final h = t.shape[2], w = t.shape[3];
    final halves = await _readback(t.tex);
    return NnTensor(
        unpackFeature(halves, cout, h, w, t.channelsPadded),
        [1, cout, h, w]);
  }

  // ------------------------------------------------------------------
  // 分块（banded）纹理驻留 API：沿 H 切带，每带一张纹理，突破单纹理
  // 2^24 纹素上限。带高规划见 [planBandHeights]/[planConvOutBands]；
  // conv/L2pooling 的带间 halo 由 [_stitchBand] 拼接（padded 带）。
  // ------------------------------------------------------------------

  /// 分块上传特征图（通道零填充到 4 的倍数）。batch 须为 1；不可行
  /// 形态抛 [UnsupportedError]，由调用方回退 CPU。
  Future<GpuNnBandedTensor> uploadFeatureMapBanded(NnTensor x) async {
    if (x.rank != 4 || x.batch != 1) {
      throw UnsupportedError('GpuNnBackend 仅支持 batch==1 的 4 维特征图');
    }
    final cin = x.channels, h = x.height, w = x.width;
    final cinP = (cin + 3) & ~3;
    final heights = planBandHeights(h, w, cinP);
    if (heights == null) {
      throw UnsupportedError('GpuNnBackend 分块规划不可行: ${x.shape}');
    }
    final bands = <GpuNnTensor>[];
    try {
      var g = 0;
      for (final th in heights) {
        final (halves, tw, thTex) =
            packFeatureBand(x.data, cin, h, w, cinP, g, th);
        bands.add(GpuNnTensor(await _upload(halves, tw, thTex),
            [1, cinP, th, w], tw, thTex, cinP));
        g += th;
      }
    } catch (_) {
      for (final b in bands) {
        b.dispose();
      }
      rethrow;
    }
    return GpuNnBandedTensor(
        bands, _offsetsOf(heights), [1, cin, h, w], cinP);
  }

  /// halo 拼接：抽出全局行区间 [g0-1, g0+th]（目标带 [g0, g0+th) 加上下
  /// 各 1 行 halo）生成 padded 带纹理（空间尺寸 W×(th+2)；图像顶/底
  /// 之外写零）。源带覆盖须 ≤3（[stitchCoverageOk] 预检保证）。
  GpuNnTensor _stitchBand(GpuNnBandedTensor x, int g0, int th) {
    final h = x.height, w = x.width;
    final cinG = x.channelsPadded ~/ 4;
    final padH = th + 2;
    final texels = 2 * cinG * padH * w;
    if (texels >= maxTexels) {
      throw UnsupportedError('GpuNnBackend stitch 带超出折叠布局约束: '
          '${x.channelsPadded}ch ${padH}x$w');
    }
    final tw = math.min(maxTextureDim, texels);
    final thTex = (texels + tw - 1) ~/ tw;

    // 覆盖 [lo, hi) 的源带（升序，1..3 张）。
    final lo = math.max(g0 - 1, 0), hi = math.min(g0 + th + 1, h);
    final cov = <int>[];
    for (var i = 0; i < x.bands.length; i++) {
      final s0 = x.bandOffsets[i], s1 = s0 + x.bands[i].shape[2];
      if (s0 < hi && s1 > lo) cov.add(i);
    }
    if (cov.length > 3) {
      throw UnsupportedError('GpuNnBackend stitch 覆盖 ${cov.length} 张源带'
          '（>3）: ${x.shape} 带 [$g0, ${g0 + th})');
    }
    GpuNnTensor bandAt(int k) => x.bands[cov[k]];
    double startAt(int k) =>
        k < cov.length ? x.bandOffsets[cov[k]].toDouble() : h.toDouble();

    final shader = _stitch.fragmentShader();
    shader.setFloat(0, tw.toDouble());
    shader.setFloat(1, thTex.toDouble());
    shader.setFloat(2, w.toDouble());
    shader.setFloat(3, padH.toDouble());
    shader.setFloat(4, (g0 - 1).toDouble());
    shader.setFloat(5, h.toDouble());
    for (var k = 0; k < 3; k++) {
      final present = k < cov.length;
      shader.setFloat(6 + k * 2, startAt(k));
      shader.setFloat(
          7 + k * 2, present ? bandAt(k).shape[2].toDouble() : 0.0);
      shader.setFloat(12 + k * 2, present ? bandAt(k).texW.toDouble() : 1.0);
      shader.setFloat(13 + k * 2, present ? bandAt(k).texH.toDouble() : 1.0);
      shader.setImageSampler(k, present ? bandAt(k).tex : _dummy);
    }
    final out = _renderPass(shader, tw, thTex);
    return GpuNnTensor(
        out, [1, x.channelsPadded, padH, w], tw, thTex, x.channelsPadded);
  }

  /// 分块 GPU 驻留 conv3x3/s1/p1：逐输出带 stitch padded 带后按带渲染
  /// （权重纹理由各带共享；多 pass 累加逐带进行）。输出分块规划见
  /// [planConvOutBands]，不可行抛 [UnsupportedError]（调用方回退 CPU）。
  GpuNnBandedTensor conv2dGpuBanded(GpuNnBandedTensor x, GpuConvWeights wgt) {
    final h = x.height, w = x.width;
    final cinP = x.channelsPadded, coutP = wgt.coutPadded;
    final outHeights = planConvOutBands(x.bandHeights, h, w, cinP, coutP);
    if (outHeights == null) {
      throw UnsupportedError('GpuNnBackend 分块 conv 规划不可行: '
          '${x.shape} → cout=${wgt.cout}');
    }
    final outBands = <GpuNnTensor>[];
    var g = 0;
    try {
      for (final th in outHeights) {
        final padded = _stitchBand(x, g, th);
        final out = conv2dGpu(padded, wgt, yOff: 1.0, outH: th);
        padded.dispose();
        outBands.add(out);
        g += th;
      }
    } catch (_) {
      for (final b in outBands) {
        b.dispose();
      }
      rethrow;
    }
    return GpuNnBandedTensor(
        outBands, _offsetsOf(outHeights), [1, coutP, h, w], coutP);
  }

  /// 分块 ReLU：逐带执行（布局/分块不变）。
  GpuNnBandedTensor reluGpuBanded(GpuNnBandedTensor x) => GpuNnBandedTensor(
      [for (final b in x.bands) reluGpu(b)],
      x.bandOffsets,
      x.shape,
      x.channelsPadded);

  /// 分块 MaxPool 2x2/s2/p0：逐带直接执行（非末带须偶高，由带规划保证；
  /// 末带高 1 的空输出带丢弃）。奇偶约束不满足抛 [UnsupportedError]。
  GpuNnBandedTensor maxPool2x2GpuBanded(GpuNnBandedTensor x) {
    final n = x.bands.length;
    final outBands = <GpuNnTensor>[];
    final outOffsets = <int>[];
    var inOff = 0, outOff = 0;
    for (var i = 0; i < n; i++) {
      final th = x.bands[i].shape[2];
      if (i < n - 1 && (th.isOdd || inOff.isOdd)) {
        throw UnsupportedError('GpuNnBackend 分块 maxpool 奇偶约束不满足: '
            '带 $i 高 $th 起始行 $inOff（调用方应回退 CPU）');
      }
      final q = th ~/ 2;
      if (q > 0) {
        outBands.add(maxPool2x2Gpu(x.bands[i]));
        outOffsets.add(outOff);
        outOff += q;
      }
      inOff += th;
    }
    if (outBands.isEmpty) {
      throw UnsupportedError('GpuNnBackend 分块 maxpool 输出为空: ${x.shape}');
    }
    return GpuNnBandedTensor(outBands, outOffsets,
        [1, x.channelsPadded, x.height ~/ 2, x.width ~/ 2],
        x.channelsPadded);
  }

  /// 分块 DISTS L2pooling：逐输出带 stitch padded 输入带（输出带
  /// [p, p+q) 需输入全局行 [2p-1, 2p+2q)，p 为输出侧起始行）后按带
  /// 执行（uYOff=1）。无奇偶约束。
  GpuNnBandedTensor l2PoolDistsGpuBanded(GpuNnBandedTensor x) {
    final outBands = <GpuNnTensor>[];
    final outOffsets = <int>[];
    var outOff = 0;
    try {
      for (var i = 0; i < x.bands.length; i++) {
        final th = x.bands[i].shape[2];
        final q = (th + 1) ~/ 2;
        final padded = _stitchBand(x, 2 * outOff, 2 * q);
        // padded 输入为 2q+2 行（末行冗余），输出高须显式取 q——不能走
        // l2PoolDistsGpu 的 (输入高+1)~/2 推导（那会得 q+1）。
        outBands.add(
            _poolGpu(_l2pool, padded, q, (x.width + 1) ~/ 2, yOff: 1.0));
        padded.dispose();
        outOffsets.add(outOff);
        outOff += q;
      }
    } catch (_) {
      for (final b in outBands) {
        b.dispose();
      }
      rethrow;
    }
    return GpuNnBandedTensor(outBands, outOffsets,
        [1, x.channelsPadded, (x.height + 1) ~/ 2, (x.width + 1) ~/ 2],
        x.channelsPadded);
  }

  /// 分块回读：逐带异步读出并解包进完整 NCHW 缓冲（丢弃 pad 通道）。
  Future<NnTensor> downloadFeatureMapBanded(GpuNnBandedTensor t,
      {int? channels}) async {
    final cout = channels ?? t.shape[1];
    final h = t.height, w = t.width;
    final out = Float32List(cout * h * w);
    for (var i = 0; i < t.bands.length; i++) {
      final band = t.bands[i];
      final halves = await _readback(band.tex);
      unpackFeatureBandInto(halves, out, cout, h, w, t.channelsPadded,
          t.bandOffsets[i], band.shape[2]);
    }
    return NnTensor(out, [1, cout, h, w]);
  }

  // ------------------------------------------------------------------
  // 便捷异步入口（上传 → 多 pass 渲染 → 回读）
  // ------------------------------------------------------------------

  /// torch F.conv2d 受限子集（见 [isSupportedConv]），batch 须为 1；
  /// 不支持的形态抛 [UnsupportedError]，由调用方回退 CPU。
  Future<NnTensor> conv2dAsync(
    NnTensor x,
    NnTensor weight, {
    Float32List? bias,
    int strideH = 1,
    int strideW = 1,
    int padH = 0,
    int padW = 0,
    int groups = 1,
  }) async {
    _requireSupported(x, weight,
        strideH: strideH,
        strideW: strideW,
        padH: padH,
        padW: padW,
        groups: groups);
    var wgt = weight;
    if (weight.shape[2] == 1) wgt = embed1x1(weight);
    final cinP = (x.channels + 3) & ~3;
    final xGpu = await uploadFeatureMap(x);
    final wGpu = await uploadConvWeights(wgt, cinP, bias: bias);
    try {
      final outGpu = conv2dGpu(xGpu, wGpu);
      try {
        return await downloadFeatureMap(outGpu, channels: weight.shape[0]);
      } finally {
        outGpu.dispose();
      }
    } finally {
      xGpu.dispose();
      wGpu.dispose();
    }
  }

  // ------------------------------------------------------------------
  // NnBackend 同步接口：conv2d 因 dart:ui 上传/回读仅异步 API 而无法
  // 同步实现，与其余 op 一样抛异常，由调用方回退 CPU（或改用异步入口）。
  // ------------------------------------------------------------------

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
      throw UnimplementedError('GPU conv2d 为异步（纹理上传/回读仅异步 API），'
          '请改用 conv2dAsync；同步调用方应回退 CPU 后端');

  @override
  Float32List gemm(Float32List a, Float32List b, int m, int n, int k,
          {bool transA = false,
          bool transB = false,
          double alpha = 1.0,
          double beta = 0.0,
          Float32List? c}) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor linear(NnTensor x, NnTensor weight, {Float32List? bias}) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor matmul(NnTensor a, NnTensor b) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor batchMatmul(NnTensor a, NnTensor b) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor relu(NnTensor x) => throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor gelu(NnTensor x) => throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor maxPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
          int strideW, int padH, int padW) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor avgPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
          int strideW, int padH, int padW,
          {bool countIncludePad = true}) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor layerNorm(NnTensor x, List<int> normalizedShape,
          Float32List? weight, Float32List? bias,
          {double eps = 1e-5}) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor groupNorm(NnTensor x, int groups, Float32List? weight,
          Float32List? bias,
          {double eps = 1e-5}) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor softmax(NnTensor x) => throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor resizeBilinear(NnTensor x, int outH, int outW) =>
      throw UnimplementedError('由调用方回退 CPU');

  @override
  NnTensor resizeBicubic(NnTensor x, int outH, int outW) =>
      throw UnimplementedError('由调用方回退 CPU');
}
