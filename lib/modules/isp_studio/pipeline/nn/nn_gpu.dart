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
///   [reluGpu]/[maxPool2x2Gpu]/[l2PoolDistsGpu]（VGG16 池化变体）与
///   [avgPool2x2Gpu]/[addReluGpu]（RN50 抗锯齿下采样与残差融合）。
/// - 仅支持 groups==1 的 3x3/pad 1（stride 1/2）与 1x1/pad 0/s1（后者
///   嵌入 3x3 中心 tap 实现）卷积形状，通道数自动零填充到 4 的倍数；
///   单 pass 覆盖 cin ≤ 256，更大 cin 自动多 pass 累加。不支持时抛
///   [UnsupportedError]，由调用方回退 CPU。
/// - 单纹理形态受折叠布局纹素数 < 2^24 约束（[isSupportedConv]）。更大
///   的特征图走**分块（banded）路径**：沿 H 切成若干等高带（每带一张
///   纹理，带高 16 的倍数、末带余量），conv/L2pooling 经
///   [shaders/nn/nn_stitch3_f16.frag] 把目标带 halo 行拼成 padded 带后
///   按带渲染（uYOff=1；s1 为 ±1 行共 th+2 行，s2 为 2th+2 行），
///   maxpool/avgpool/relu 逐带直接执行，addRelu 要求两操作数分块一致
///   （conv 可用 forceOutHeights 对齐）。入口为
///   [uploadFeatureMapBanded]/[conv2dGpuBanded]/[reluGpuBanded]/
///   [maxPool2x2GpuBanded]/[avgPool2x2GpuBanded]/[l2PoolDistsGpuBanded]/
///   [addReluGpuBanded]/[downloadFeatureMapBanded]，规划见
///   [planBandHeights]/[planConvOutBands]。小图仍走单纹理路径，行为
///   逐位不变。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'nn_engine.dart';
import 'nn_gpu_pack.dart' as pack;
import 'tensor.dart';

// fp16 位型转换已移至纯 Dart 的 nn_gpu_pack.dart（可在后台 isolate
// 使用），此处转发保持既有调用点（含测试）不变。
export 'nn_gpu_pack.dart' show floatToHalfBits, halfBitsToFloat;

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
      this.cout, this.coutPadded, this.kH, this.kW);

  final List<ui.Image> passTex;
  final List<int> passTexW, passTexH;
  final ui.Image? biasTex;
  final int cout, coutPadded;

  /// 卷积核尺寸（≤7，含非对称；打包 TAPS = kH*kW）。
  final int kH, kW;

  void dispose() {
    for (final t in passTex) {
      t.dispose();
    }
    biasTex?.dispose();
  }
}

/// GPU 纹理驻留链的派发让出器（优化 6）：conv/pool 等 pass 只能在
/// UI isolate 同步提交，整链连续派发会把事件循环饿死（Windows >5s
/// 判「未响应」）。三条链的 forward 在层间调用 [tick]：每累计
/// ≥[thresholdMs] 同步派发时间 await 一次零延迟 Future，让事件循环
/// 泵一次平台消息。纯调度，不改变任何数值。
class GpuDispatchYield {
  GpuDispatchYield({this.thresholdMs = 8});

  /// 累计同步派发时间的让出阈值（毫秒）。单层同步段最长约 1s 量级，
  /// 远小于 Windows 的 5s「未响应」判据。
  final int thresholdMs;

  final Stopwatch _sw = Stopwatch()..start();

  /// 层间调用：距上次让出已超 [thresholdMs] 时让出一次事件循环。
  Future<void> tick() async {
    if (_sw.elapsedMilliseconds >= thresholdMs) {
      _sw.reset();
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// GPU NN 后端。经 [tryCreate] 获取（shader 加载失败返回 null）。
class GpuNnBackend implements NnBackend {
  GpuNnBackend._(this._conv3x3, this._relu, this._maxpool2x2, this._l2pool,
      this._stitch, this._avgpool2x2, this._addrelu, this._pool3x3,
      this._concat4, this._dummy);

  final ui.FragmentProgram _conv3x3;

  /// 逐元素 ReLU（[reluGpu]）。
  final ui.FragmentProgram _relu;

  /// MaxPool 2x2/s2/p0（[maxPool2x2Gpu]）。
  final ui.FragmentProgram _maxpool2x2;

  /// DISTS L2pooling（[l2PoolDistsGpu]）。
  final ui.FragmentProgram _l2pool;

  /// 分块 halo 拼接（[_stitchBand]，分块路径专用）。
  final ui.FragmentProgram _stitch;

  /// AvgPool 2x2/s2/p0（[avgPool2x2Gpu]，RN50 抗锯齿下采样）。
  final ui.FragmentProgram _avgpool2x2;

  /// 残差融合 Add+ReLU（[addReluGpu]）。
  final ui.FragmentProgram _addrelu;

  /// 3x3 MaxPool/AvgPool（[pool3x3Gpu]，InceptionV3 池化分支）。
  final ui.FragmentProgram _pool3x3;

  /// ≤4 路通道拼接（[concatChannelsGpu]，Inception 分支合并）。
  final ui.FragmentProgram _concat4;

  /// 1x1 哑纹理：未使用的 sampler（uAccum/uBias/uSrcB/uSrcC 等）绑定它。
  final ui.Image _dummy;

  /// 单 pass 最大输入通道组数（与 shader MAX_CG 一致，cin ≤ 256/pass）。
  static const maxChannelGroupsPerPass = pack.kMaxChannelGroupsPerPass;

  /// 折叠布局物理纹素数上限（shader 内 float 索引须 < 2^24 保精确）。
  static const maxTexels = 1 << 24;

  /// 纹理边长上限（保守取 8192，GL/D3D 桌面普遍保证）。
  static const maxTextureDim = pack.kGpuNnMaxTextureDim;

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
  static const _avgpoolShaderAsset = 'shaders/nn/nn_avgpool2x2_f16.frag';
  static const _addreluShaderAsset = 'shaders/nn/nn_addrelu_f16.frag';
  static const _pool3x3ShaderAsset = 'shaders/nn/nn_pool3x3_f16.frag';
  static const _concat4ShaderAsset = 'shaders/nn/nn_concat4_f16.frag';

  static Future<GpuNnBackend?> tryCreate() async {
    try {
      final prog = await ui.FragmentProgram.fromAsset(_shaderAsset);
      final relu = await ui.FragmentProgram.fromAsset(_reluShaderAsset);
      final maxpool = await ui.FragmentProgram.fromAsset(_maxpoolShaderAsset);
      final l2pool = await ui.FragmentProgram.fromAsset(_l2poolShaderAsset);
      final stitch = await ui.FragmentProgram.fromAsset(_stitchShaderAsset);
      final avgpool = await ui.FragmentProgram.fromAsset(_avgpoolShaderAsset);
      final addrelu = await ui.FragmentProgram.fromAsset(_addreluShaderAsset);
      final pool3x3 = await ui.FragmentProgram.fromAsset(_pool3x3ShaderAsset);
      final concat4 = await ui.FragmentProgram.fromAsset(_concat4ShaderAsset);
      final dummy = await _upload(Uint16List(2), 1, 1);
      return GpuNnBackend._(prog, relu, maxpool, l2pool, stitch, avgpool,
          addrelu, pool3x3, concat4, dummy);
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

  /// [conv2dAsync] 支持的参数形态（kernel ≤7x7 含非对称与 1x1、pad ≤3、
  /// stride 1/2（H/W 同值）、groups==1；覆盖 VGG/RN50/InceptionV3 的
  /// 全部卷积）。depthwise、更大 kernel/stride 等返回 false。
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
    if (groups != 1 || strideH != strideW) return false;
    if (strideH != 1 && strideH != 2) return false;
    final kh = weight.shape[2], kw = weight.shape[3];
    if (kh < 1 || kh > 7 || kw < 1 || kw > 7) return false;
    if (padH < 0 || padH > 3 || padW < 0 || padW > 3) return false;
    if (weight.shape[1] != x.channels) return false;
    final cinP = (x.channels + 3) & ~3, coutP = (weight.shape[0] + 3) & ~3;
    final h = x.height, w = x.width;
    final oh = (h + 2 * padH - kh) ~/ strideH + 1;
    final ow = (w + 2 * padW - kw) ~/ strideH + 1;
    if (oh < 1 || ow < 1) return false;
    // 输入/输出折叠纹素数 = 2 * (c/4) * H * W，须 < 2^24 且摊平后可放入
    // maxTextureDim 见方的纹理。
    for (final texels in [2 * (cinP ~/ 4) * h * w, 2 * (coutP ~/ 4) * oh * ow]) {
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

  /// stride 版 stitch 覆盖校验（conv3x3/p1）：输出带 [g, g+th) 所需的
  /// 输入全局行区间——s1 为 [g-1, g+th+1)，s2 为 [2g-1, 2(g+th)+1)——
  /// 裁剪到 [0,H) 后落在源带的并集须 ≤3 张。[noHalo]（1x1 嵌入中心
  /// tap 的 conv，halo 行权重恒零）收紧为 [g, g+th)，覆盖约束更松。
  static bool stitchCoverageOkS(
      List<int> inHeights, List<int> outHeights, int stride,
      {bool noHalo = false}) {
    final inOff = _offsetsOf(inHeights);
    final h = inHeights.fold<int>(0, (a, b) => a + b);
    var g = 0;
    for (final th in outHeights) {
      final lo = noHalo
          ? g
          : (stride == 2 ? math.max(2 * g - 1, 0) : math.max(g - 1, 0));
      final hi = noHalo
          ? g + th
          : (stride == 2
              ? math.min(2 * (g + th) + 1, h)
              : math.min(g + th + 1, h));
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

  /// conv 输出分块规划。通道数不变且 s1 时直接沿用输入分块（stitch 覆
  /// 盖恒为「前/本/后」≤3 带，预算由输入侧规划保证）；否则按 padded
  /// 输入带（cinP 通道，s1: th+2 行 / s2: 2th+2 行）与输出带（coutP
  /// 通道 th 行）的合并预算取带高，并不粗于覆盖约束允许的上界（保证
  /// ≤3）。[forceOutHeights]（残差对齐用，须恰好铺满输出高）跳过自动
  /// 取高但仍做预算与覆盖校验。[noHalo] 标记 1x1 嵌入中心 tap 的
  /// conv（halo 行权重恒零）：覆盖按无 halo 区间 [g, g+th) 校验，带高
  /// 上限放宽到 2×输入非末带最小高度。不可行返回 null。
  static List<int>? planConvOutBands(
      List<int> inHeights, int h, int w, int cinP, int coutP,
      {int stride = 1, List<int>? forceOutHeights, bool noHalo = false}) {
    final outH = stride == 2 ? (h + 1) ~/ 2 : h;
    final outW = stride == 2 ? (w + 1) ~/ 2 : w;
    if (stride == 1 && coutP == cinP && forceOutHeights == null) {
      return List.of(inHeights);
    }
    final perIn = 2 * (cinP ~/ 4) * w, perOut = 2 * (coutP ~/ 4) * outW;
    if (perIn <= 0 || perOut <= 0) return null;

    bool fitsBudget(List<int> hs) {
      for (final th in hs) {
        final inRows = stride == 2 ? 2 * th + 2 : th + 2;
        if (perIn * inRows > _bandBudget || perOut * th > _bandBudget) {
          return false;
        }
      }
      return true;
    }

    if (forceOutHeights != null) {
      if (forceOutHeights.fold<int>(0, (a, b) => a + b) != outH) return null;
      return fitsBudget(forceOutHeights) &&
              stitchCoverageOkS(inHeights, forceOutHeights, stride,
                  noHalo: noHalo)
          ? List.of(forceOutHeights)
          : null;
    }

    // 单带高度上界（未取整）：s1 时与旧版一致（min(perIn,perOut) - 2，
    // cinP ≤ coutP 时退化为旧公式）；s2 时 padded 输入带 2th+2 行减半。
    final thIn = stride == 2
        ? (_bandBudget ~/ perIn - 2) ~/ 2
        : _bandBudget ~/ perIn - 2;
    final th0 = math.min(thIn, _bandBudget ~/ perOut - 2);
    if (th0 >= outH) {
      final single = [outH];
      if (stitchCoverageOkS(inHeights, single, stride, noHalo: noHalo)) {
        return single;
      }
    }
    var cap = outH;
    if (inHeights.length > 1) {
      final minIn =
          inHeights.sublist(0, inHeights.length - 1).reduce(math.min);
      // 覆盖 ≤3：s1 带高 ≤ minIn（noHalo 放宽到 2*minIn）；s2 输入区间
      // 2th+2 ≤ 2*minIn → th ≤ minIn-1。
      cap = noHalo ? 2 * minIn : (stride == 2 ? minIn - 1 : minIn);
    }
    final th = (math.min(th0, cap) ~/ 16) * 16;
    if (th < 16) return null;
    final cand = splitHeights(outH, th);
    return stitchCoverageOkS(inHeights, cand, stride, noHalo: noHalo)
        ? cand
        : null;
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
  // 打包（CPU 侧）：实现已移至纯 Dart 的 nn_gpu_pack.dart（可在后台
  // isolate 经 compute 执行，整网预打包见该文件的 pack*Weights 入口），
  // 以下静态方法签名与数值不变、仅委托。
  // ------------------------------------------------------------------

  /// 特征图 NCHW fp32 → fp16 折叠打包（返回 halves 与物理纹理尺寸）。
  static (Uint16List, int, int) packFeature(
          Float32List data, int cin, int h, int w, int cinP) =>
      pack.packFeature(data, cin, h, w, cinP);

  /// 权重 [cout, cin, kH, kW] 某 pass（输入通道组 [giBase, giBase+cinGpass)
  /// ）→ fp16 折叠打包（cell=((go*cinGpass+gi0)*TAPS+tap)*4+co，
  /// TAPS=kH*kW，tap=r*kW+c 行主序）。
  static (Uint16List, int, int) packWeightsPass(Float32List w, int cout,
          int cin, int cinP, int coutP, int giBase, int cinGpass,
          {int kH = 3, int kW = 3}) =>
      pack.packWeightsPass(w, cout, cin, cinP, coutP, giBase, cinGpass,
          kH: kH, kW: kW);

  /// 偏置 [cout] → 宽 coutG*2、高 1 的 fp16 纹理（pad 通道补 0）。
  static (Uint16List, int) packBias(Float32List? bias, int cout, int coutP) =>
      pack.packBias(bias, cout, coutP);

  /// fp16 折叠打包输出 → NCHW fp32（丢弃 pad 通道）。
  static Float32List unpackFeature(
          Uint16List halves, int cout, int h, int w, int coutP) =>
      pack.unpackFeature(halves, cout, h, w, coutP);

  /// [packFeature] 的带切片版：只装全局行 [g0, g0+th)（分块上传用）。
  static (Uint16List, int, int) packFeatureBand(Float32List data, int cin,
          int h, int w, int cinP, int g0, int th) =>
      pack.packFeatureBand(data, cin, h, w, cinP, g0, th);

  /// [unpackFeature] 的带切片版：把带 halves 解包进完整缓冲 [out] 的
  /// 全局行 [g0, g0+th)（分块回读用）。
  static void unpackFeatureBandInto(Uint16List halves, Float32List out,
          int cout, int h, int w, int coutP, int g0, int th) =>
      pack.unpackFeatureBandInto(halves, out, cout, h, w, coutP, g0, th);

  // ------------------------------------------------------------------
  // GPU 原语
  // ------------------------------------------------------------------

  static Future<ui.Image> _upload(Uint16List halves, int tw, int th) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(halves.buffer.asUint8List(), tw, th,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// 回读前先把惰性快照图物化（优化 8）：直接 toByteData 惰性图会把
  /// 全部依赖光栅化在回读时刻同步执行（实测 64ch×3000×1688 切片
  /// 13.7s）；drawImage + await toImage 先让光栅化走光栅线程管线
  /// （不堵 UI，且同源其他惰性图命中缓存变便宜），之后 toByteData
  /// 仅剩传输。惰性图本身由调用方（GpuNnTensor 持有者）管理，这里
  /// 只释放物化副本。toByteData 格式保持缺省（RGBA8 语义不变）。
  static Future<ui.Image> _materialize(ui.Image img) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImage(img, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    final out = await picture.toImage(img.width, img.height);
    picture.dispose();
    return out;
  }

  static Future<Uint16List> _readback(ui.Image img) async {
    final mat = await _materialize(img);
    try {
      final bd = await mat.toByteData();
      return bd!.buffer.asUint16List();
    } finally {
      mat.dispose();
    }
  }

  // ------------------------------------------------------------------
  // 纹理驻留 API
  // ------------------------------------------------------------------

  /// 上传特征图（通道零填充到 4 的倍数）。batch 须为 1。大输入
  /// （≥1M 元素）的 fp16 打包放后台 isolate（compute），避免大循环
  /// 阻塞 UI；小输入打包开销低于 spawn 成本，就地执行。
  Future<GpuNnTensor> uploadFeatureMap(NnTensor x) async {
    if (x.rank != 4 || x.batch != 1) {
      throw UnsupportedError('GpuNnBackend 仅支持 batch==1 的 4 维特征图');
    }
    final cin = x.channels, h = x.height, w = x.width;
    final cinP = (cin + 3) & ~3;
    final (halves, tw, th) = cin * h * w >= 1 << 20
        ? await compute(pack.packFeatureInIsolate, (x.data, cin, h, w, cinP))
        : pack.packFeature(x.data, cin, h, w, cinP);
    return GpuNnTensor(await _upload(halves, tw, th),
        List.unmodifiable(x.shape), tw, th, cinP);
  }

  /// 上传卷积权重（weight [cout, cin, kH, kW]，kH/kW ≤7 含非对称与原生
  /// 1x1）。多 pass 时每 pass 一张纹理。
  Future<GpuConvWeights> uploadConvWeights(NnTensor weight, int cinP,
      {Float32List? bias}) async {
    return uploadPackedConvWeights(
        pack.packConvWeights(weight, cinP, bias: bias));
  }

  /// 上传已在后台 isolate 预打包的卷积权重（[pack.PackedConvWeights]，
  /// 见 nn_gpu_pack.dart 的整网 pack*Weights 入口）：UI 侧仅创建纹理，
  /// 无打包大循环。
  Future<GpuConvWeights> uploadPackedConvWeights(
      pack.PackedConvWeights packed) async {
    final passTex = <ui.Image>[];
    final passTexW = <int>[], passTexH = <int>[];
    for (final (halves, tw, th) in packed.passes) {
      passTex.add(await _upload(halves, tw, th));
      passTexW.add(tw);
      passTexH.add(th);
    }
    ui.Image? biasTex;
    final biasHalves = packed.biasHalves;
    if (biasHalves != null) {
      biasTex = await _upload(biasHalves, packed.biasTexW, 1);
    }
    return GpuConvWeights(passTex, passTexW, passTexH, biasTex, packed.cout,
        packed.coutPadded, packed.kH, packed.kW);
  }

  /// 1x1/s1/p0 权重 [cout, cin, 1, 1] → 等效 3x3/s1/p1（中心 tap 嵌入）。
  static NnTensor embed1x1(NnTensor weight) => pack.embed1x1(weight);

  /// GPU 驻留 conv（kernel 尺寸/填充取 [GpuConvWeights] 与本参数；通用
  /// 形态 kH,kW ≤7、pad ≤3、stride 1/2、groups==1）：输入输出均为打包
  /// 纹理，同步执行（pass 提交为同步光栅化，不含上传/回读）。输出通
  /// 道保留 pad（取数时用 [GpuConvWeights.cout] 截断）。
  ///
  /// [stride] 为空间步长（1 或 2，H/W 同值）；[padH]/[padW] 缺省 1
  /// （3x3/p1 既有调用点行为逐位不变；1x1 等需显式传 0）；[relu] 为
  /// true 时末 pass 加 bias 后融合 max(·,0)（BasicConv2d 的 relu）。
  /// 分块路径专用参数（单纹理路径保持默认，行为逐位不变）：
  /// [yOff] 为输入垂直偏移（padded 带输入为 1.0，行 0 是上 halo）；
  /// [outH]/[outW] 为输出空间尺寸（padded 带输入时 outH = 带高，小于
  /// 输入高）。
  GpuNnTensor conv2dGpu(GpuNnTensor x, GpuConvWeights wgt,
      {double yOff = 0.0,
      int? outH,
      int? outW,
      int stride = 1,
      int padH = 1,
      int padW = 1,
      bool relu = false}) {
    final h = x.shape[2], w = x.shape[3];
    final oH = outH ?? (h + 2 * padH - wgt.kH) ~/ stride + 1;
    final oW = outW ?? (w + 2 * padW - wgt.kW) ~/ stride + 1;
    final cinG = x.channelsPadded ~/ 4;
    final coutG = wgt.coutPadded ~/ 4;
    final outTexels = 2 * coutG * oH * oW;
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
      shader.setFloat(14, oW.toDouble());
      shader.setFloat(15, oH.toDouble());
      shader.setFloat(16, stride.toDouble());
      shader.setFloat(17, wgt.kH.toDouble());
      shader.setFloat(18, wgt.kW.toDouble());
      shader.setFloat(19, padH.toDouble());
      shader.setFloat(20, padW.toDouble());
      shader.setFloat(21, relu && isLast ? 1.0 : 0.0);
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
        accum!, [1, wgt.coutPadded, oH, oW], outTW, outTH, wgt.coutPadded);
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

  /// GPU 驻留 AvgPool 2x2/s2/p0（RN50 抗锯齿下采样）：输出
  /// floor(H/2)×floor(W/2)，通道不变，与 ops.avgPool2d(k2,s2,p0)
  /// 同语义（池化窗口恒完整，除数恒 4）。
  GpuNnTensor avgPool2x2Gpu(GpuNnTensor x) =>
      _poolGpu(_avgpool2x2, x, x.shape[2] ~/ 2, x.shape[3] ~/ 2);

  /// GPU 驻留残差融合 Add+ReLU：out = max(a+b, 0)。两输入须同形状、
  /// 同物理纹理尺寸（RN50 Bottleneck 主路径与 identity 路径），否则
  /// 抛 [UnsupportedError]（调用方回退 CPU）。
  GpuNnTensor addReluGpu(GpuNnTensor a, GpuNnTensor b) {
    if (a.texW != b.texW ||
        a.texH != b.texH ||
        a.channelsPadded != b.channelsPadded ||
        a.shape[2] != b.shape[2] ||
        a.shape[3] != b.shape[3]) {
      throw UnsupportedError('GpuNnBackend addRelu 输入形状不一致: '
          '${a.shape}@${a.texW}x${a.texH} vs ${b.shape}@${b.texW}x${b.texH}'
          '（调用方应回退 CPU）');
    }
    final shader = _addrelu.fragmentShader();
    shader.setFloat(0, a.texW.toDouble());
    shader.setFloat(1, a.texH.toDouble());
    shader.setImageSampler(0, a.tex);
    shader.setImageSampler(1, b.tex);
    final out = _renderPass(shader, a.texW, a.texH);
    return GpuNnTensor(out, a.shape, a.texW, a.texH, a.channelsPadded);
  }

  /// GPU 驻留 3x3 池化（InceptionV3 池化分支）：[avg] 为 false 时
  /// MaxPool（越界 tap 跳过，等价 ops.maxPool2d），true 时 AvgPool
  /// countIncludePad=false（除数 = 窗口内有效元素数，同
  /// ops.avgPool2d(countIncludePad: false)）。输出 (H+2p-3)~/stride+1
  /// ×同宽，通道不变。
  GpuNnTensor pool3x3Gpu(GpuNnTensor x,
      {bool avg = false, int stride = 2, int pad = 0}) {
    final h = x.shape[2], w = x.shape[3];
    final oH = (h + 2 * pad - 3) ~/ stride + 1;
    final oW = (w + 2 * pad - 3) ~/ stride + 1;
    final cinG = x.channelsPadded ~/ 4;
    final outTexels = 2 * cinG * oH * oW;
    final outTW = math.min(maxTextureDim, outTexels);
    final outTH = (outTexels + outTW - 1) ~/ outTW;
    final shader = _pool3x3.fragmentShader();
    shader.setFloat(0, x.texW.toDouble());
    shader.setFloat(1, x.texH.toDouble());
    shader.setFloat(2, w.toDouble());
    shader.setFloat(3, h.toDouble());
    shader.setFloat(4, outTW.toDouble());
    shader.setFloat(5, outTH.toDouble());
    shader.setFloat(6, oW.toDouble());
    shader.setFloat(7, oH.toDouble());
    shader.setFloat(8, avg ? 1.0 : 0.0);
    shader.setFloat(9, stride.toDouble());
    shader.setFloat(10, pad.toDouble());
    shader.setImageSampler(0, x.tex);
    final out = _renderPass(shader, outTW, outTH);
    return GpuNnTensor(
        out, [1, x.channelsPadded, oH, oW], outTW, outTH, x.channelsPadded);
  }

  /// GPU 驻留通道拼接（2..4 路，Inception 分支合并）：各路须同 H×W、
  /// 通道数为 4 的倍数（通道组整组对齐）；输出通道数 = 各路之和。
  /// 纯字节拷贝（无 fp16 编解码），位级精确。
  GpuNnTensor concatChannelsGpu(List<GpuNnTensor> srcs) {
    if (srcs.length < 2 || srcs.length > 4) {
      throw UnsupportedError(
          'GpuNnBackend concat 支持 2..4 路，得到 ${srcs.length}');
    }
    final h = srcs[0].shape[2], w = srcs[0].shape[3];
    for (final s in srcs) {
      if (s.shape[2] != h || s.shape[3] != w) {
        throw UnsupportedError('GpuNnBackend concat 各路 H×W 不一致: '
            '${srcs.map((e) => e.shape).toList()}（调用方应回退 CPU）');
      }
    }
    final groupEnds = <int>[];
    var acc = 0;
    for (final s in srcs) {
      acc += s.channelsPadded ~/ 4;
      groupEnds.add(acc);
    }
    final totalG = acc;
    while (groupEnds.length < 4) {
      groupEnds.add(acc); // 高位重复总组数，使多余分支不可达
    }
    final outTexels = 2 * totalG * h * w;
    if (outTexels >= maxTexels) {
      throw UnsupportedError('GpuNnBackend concat 输出超出折叠布局约束: '
          '${totalG * 4}ch ${h}x$w（调用方应回退 CPU）');
    }
    final outTW = math.min(maxTextureDim, outTexels);
    final outTH = (outTexels + outTW - 1) ~/ outTW;
    final shader = _concat4.fragmentShader();
    shader.setFloat(0, outTW.toDouble());
    shader.setFloat(1, outTH.toDouble());
    shader.setFloat(2, w.toDouble());
    shader.setFloat(3, h.toDouble());
    for (var k = 0; k < 4; k++) {
      shader.setFloat(4 + k, groupEnds[k].toDouble());
      final present = k < srcs.length;
      shader.setFloat(8 + k * 2, present ? srcs[k].texW.toDouble() : 1.0);
      shader.setFloat(9 + k * 2, present ? srcs[k].texH.toDouble() : 1.0);
      shader.setImageSampler(k, present ? srcs[k].tex : _dummy);
    }
    final out = _renderPass(shader, outTW, outTH);
    return GpuNnTensor(out, [1, totalG * 4, h, w], outTW, outTH, totalG * 4);
  }

  /// 回读 GPU 驻留特征图为 CPU 张量（丢弃 pad 通道）。大图（≥1M 元素）
  /// 的 fp16→fp32 解包放后台 isolate（TransferableTypedData 传输，
  /// 优化 8；同一 unpack 函数，数值与就地解包逐位一致），小图就地
  /// 解包避免 spawn 开销。
  Future<NnTensor> downloadFeatureMap(GpuNnTensor t, {int? channels}) async {
    final cout = channels ?? t.shape[1];
    final h = t.shape[2], w = t.shape[3];
    final halves = await _readback(t.tex);
    if (cout * h * w >= 1 << 20) {
      final td = await compute(
          pack.unpackFeatureInIsolate,
          (TransferableTypedData.fromList([halves]), cout, h, w,
              t.channelsPadded));
      return NnTensor(
          td.materialize().asFloat32List(), [1, cout, h, w]);
    }
    return NnTensor(
        pack.unpackFeature(halves, cout, h, w, t.channelsPadded),
        [1, cout, h, w]);
  }

  /// 把后台解包的单带 NCHW 段（[cout*th*w]，每通道连续 th*w 元素）
  /// 按通道拼进完整缓冲 [out] 的全局行 [g0, g0+th)。
  static void _mergeBandInto(Float32List band, Float32List out, int cout,
      int h, int w, int g0, int th) {
    for (var co = 0; co < cout; co++) {
      out.setRange((co * h + g0) * w, (co * h + g0 + th) * w, band,
          co * th * w);
    }
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
    // 分块路径必为大图（单纹理放不下才走这里）：各带打包一次 compute
    // 放后台 isolate，避免逐带大循环阻塞 UI。
    final packed = await compute(
        pack.packFeatureBandsInIsolate, (x.data, cin, h, w, cinP, heights));
    final bands = <GpuNnTensor>[];
    try {
      for (var i = 0; i < heights.length; i++) {
        final th = heights[i];
        final (halves, tw, thTex) = packed[i];
        bands.add(GpuNnTensor(await _upload(halves, tw, thTex),
            [1, cinP, th, w], tw, thTex, cinP));
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

  /// halo 拼接：抽出全局行区间 [g0-halo, g0+th+halo)（目标带 [g0, g0+th)
  /// 加上下 halo 行）生成 padded 带纹理（空间尺寸 W×(th+2·halo)；图像
  /// 顶/底之外写零）。[halo] 为 0 时（1x1 嵌入中心 tap 的 conv，halo
  /// 行权重恒零）只抽目标带本身（th 行），覆盖校验同步收紧。源带覆盖
  /// 须 ≤3（[stitchCoverageOkS] 预检保证）。
  GpuNnTensor _stitchBand(GpuNnBandedTensor x, int g0, int th,
      {int halo = 1}) {
    final h = x.height, w = x.width;
    final cinG = x.channelsPadded ~/ 4;
    final padH = th + 2 * halo;
    final texels = 2 * cinG * padH * w;
    if (texels >= maxTexels) {
      throw UnsupportedError('GpuNnBackend stitch 带超出折叠布局约束: '
          '${x.channelsPadded}ch ${padH}x$w');
    }
    final tw = math.min(maxTextureDim, texels);
    final thTex = (texels + tw - 1) ~/ tw;

    // 覆盖 [lo, hi) 的源带（升序，1..3 张）。
    final lo = math.max(g0 - halo, 0), hi = math.min(g0 + th + halo, h);
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
    shader.setFloat(4, (g0 - halo).toDouble());
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

  /// 分块 GPU 驻留 conv3x3/p1：逐输出带 stitch padded 带后按带渲染
  /// （权重纹理由各带共享；多 pass 累加逐带进行）。[stride] 为 2 时输
  /// 出带 [g, g+th) 的输入区间为全局行 [2g-1, 2(g+th)+1)（stitch 出
  /// 2th+2 行 padded 带，uYOff=1 + uStride=2）；[forceOutHeights]（残
  /// 差对齐用）强制输出分块；[noHalo] 标记 1x1 嵌入中心 tap 的 conv
  /// （halo 行权重恒零，覆盖约束更松，深层高通道 1x1 的可行性关键）。
  /// 输出分块规划见 [planConvOutBands]，不可行抛 [UnsupportedError]
  /// （调用方回退 CPU）。
  GpuNnBandedTensor conv2dGpuBanded(GpuNnBandedTensor x, GpuConvWeights wgt,
      {int stride = 1, List<int>? forceOutHeights, bool noHalo = false}) {
    final h = x.height, w = x.width;
    final cinP = x.channelsPadded, coutP = wgt.coutPadded;
    final outHeights = planConvOutBands(x.bandHeights, h, w, cinP, coutP,
        stride: stride, forceOutHeights: forceOutHeights, noHalo: noHalo);
    if (outHeights == null) {
      throw UnsupportedError('GpuNnBackend 分块 conv 规划不可行: '
          '${x.shape} → cout=${wgt.cout} s=$stride（调用方应回退 CPU）');
    }
    final outBands = <GpuNnTensor>[];
    // noHalo（1x1 嵌入中心 tap，仅 s1）：stitch 不拼 halo 行、conv 无垂
    // 直偏移——halo 行权重恒零，省去覆盖一个额外源带的风险。
    final halo = noHalo ? 0 : 1;
    var g = 0;
    try {
      for (final th in outHeights) {
        final padded = stride == 2
            ? _stitchBand(x, 2 * g, 2 * th)
            : _stitchBand(x, g, th, halo: halo);
        final out = conv2dGpu(padded, wgt,
            yOff: halo.toDouble(), outH: th, stride: stride);
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
    final oH = stride == 2 ? (h + 1) ~/ 2 : h;
    final oW = stride == 2 ? (w + 1) ~/ 2 : w;
    return GpuNnBandedTensor(
        outBands, _offsetsOf(outHeights), [1, coutP, oH, oW], coutP);
  }

  /// 分块 ReLU：逐带执行（布局/分块不变）。
  GpuNnBandedTensor reluGpuBanded(GpuNnBandedTensor x) => GpuNnBandedTensor(
      [for (final b in x.bands) reluGpu(b)],
      x.bandOffsets,
      x.shape,
      x.channelsPadded);

  /// maxpool/avgpool 2x2/s2/p0 的分块公共逻辑：逐带直接执行（非末带
  /// 须偶高且起始行偶对齐，由带规划保证；末带高 1 的空输出带丢弃）。
  /// 奇偶约束不满足抛 [UnsupportedError]（调用方回退 CPU）。
  GpuNnBandedTensor _pool2x2GpuBanded(
      GpuNnBandedTensor x, GpuNnTensor Function(GpuNnTensor) pool) {
    final n = x.bands.length;
    final outBands = <GpuNnTensor>[];
    final outOffsets = <int>[];
    var inOff = 0, outOff = 0;
    for (var i = 0; i < n; i++) {
      final th = x.bands[i].shape[2];
      if (i < n - 1 && (th.isOdd || inOff.isOdd)) {
        throw UnsupportedError('GpuNnBackend 分块 pool2x2 奇偶约束不满足: '
            '带 $i 高 $th 起始行 $inOff（调用方应回退 CPU）');
      }
      final q = th ~/ 2;
      if (q > 0) {
        outBands.add(pool(x.bands[i]));
        outOffsets.add(outOff);
        outOff += q;
      }
      inOff += th;
    }
    if (outBands.isEmpty) {
      throw UnsupportedError('GpuNnBackend 分块 pool2x2 输出为空: ${x.shape}');
    }
    return GpuNnBandedTensor(outBands, outOffsets,
        [1, x.channelsPadded, x.height ~/ 2, x.width ~/ 2],
        x.channelsPadded);
  }

  /// 分块 MaxPool 2x2/s2/p0：见 [_pool2x2GpuBanded]。
  GpuNnBandedTensor maxPool2x2GpuBanded(GpuNnBandedTensor x) =>
      _pool2x2GpuBanded(x, maxPool2x2Gpu);

  /// 分块 AvgPool 2x2/s2/p0（RN50 抗锯齿下采样）：奇偶约束同 maxpool。
  GpuNnBandedTensor avgPool2x2GpuBanded(GpuNnBandedTensor x) =>
      _pool2x2GpuBanded(x, avgPool2x2Gpu);

  /// 分块残差融合 Add+ReLU：两输入须分块完全一致（带数/带高/带偏移逐
  /// 项相等，由 RN50 主干以 forceOutHeights 对齐保证），逐带执行。
  /// 不一致抛 [UnsupportedError]（调用方回退 CPU）。
  GpuNnBandedTensor addReluGpuBanded(GpuNnBandedTensor a, GpuNnBandedTensor b) {
    bool sameBands() {
      if (a.bands.length != b.bands.length ||
          a.channelsPadded != b.channelsPadded ||
          a.height != b.height ||
          a.width != b.width) {
        return false;
      }
      for (var i = 0; i < a.bands.length; i++) {
        if (a.bandOffsets[i] != b.bandOffsets[i] ||
            a.bands[i].shape[2] != b.bands[i].shape[2]) {
          return false;
        }
      }
      return true;
    }

    if (!sameBands()) {
      throw UnsupportedError('GpuNnBackend 分块 addRelu 输入分块不一致: '
          '${a.bandHeights}@${a.channelsPadded}ch vs '
          '${b.bandHeights}@${b.channelsPadded}ch（调用方应回退 CPU）');
    }
    return GpuNnBandedTensor(
        [for (var i = 0; i < a.bands.length; i++)
          addReluGpu(a.bands[i], b.bands[i])],
        a.bandOffsets,
        a.shape,
        a.channelsPadded);
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

  /// 分块回读：逐带「物化 + 读出」与上一带的后台解包重叠（流水线，
  /// 优化 8），解包段按带序确定性拼进完整 NCHW 缓冲（丢弃 pad 通道，
  /// 数值与就地解包逐位一致）。小图（<1M 元素）走原逐带就地解包。
  Future<NnTensor> downloadFeatureMapBanded(GpuNnBandedTensor t,
      {int? channels}) async {
    final cout = channels ?? t.shape[1];
    final h = t.height, w = t.width;
    final out = Float32List(cout * h * w);
    if (cout * h * w < 1 << 20) {
      for (var i = 0; i < t.bands.length; i++) {
        final band = t.bands[i];
        final halves = await _readback(band.tex);
        pack.unpackFeatureBandInto(halves, out, cout, h, w,
            t.channelsPadded, t.bandOffsets[i], band.shape[2]);
      }
      return NnTensor(out, [1, cout, h, w]);
    }
    Future<TransferableTypedData>? pending;
    var pendG0 = 0, pendTh = 0;
    for (var i = 0; i < t.bands.length; i++) {
      final band = t.bands[i];
      final halves = await _readback(band.tex);
      // 该带 halves 到手即派后台解包（不 await），先继续下一带的
      // 物化/传输；上一带的解包结果在派发前收账合并。
      final fut = compute(
          pack.unpackFeatureBandInIsolate,
          (TransferableTypedData.fromList([halves]), cout, h, w,
              t.channelsPadded, t.bandOffsets[i], band.shape[2]));
      if (pending != null) {
        _mergeBandInto((await pending).materialize().asFloat32List(), out,
            cout, h, w, pendG0, pendTh);
      }
      pending = fut;
      pendG0 = t.bandOffsets[i];
      pendTh = band.shape[2];
    }
    if (pending != null) {
      _mergeBandInto((await pending).materialize().asFloat32List(), out,
          cout, h, w, pendG0, pendTh);
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
    final cinP = (x.channels + 3) & ~3;
    final xGpu = await uploadFeatureMap(x);
    final wGpu = await uploadConvWeights(weight, cinP, bias: bias);
    try {
      final outGpu = conv2dGpu(xGpu, wGpu,
          stride: strideH, padH: padH, padW: padW);
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
