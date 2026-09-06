/// DISTS（Deep Structure and Texture Similarity）的进程内 Dart 实现，
/// 语义忠实于 pyiqa（scratch/eval_venv/Lib/site-packages/pyiqa/archs/
/// dists_arch.py，复刻官方 DISTS_pytorch）：
///
///   x 保持 [0,1]（RGBA→[0,1] RGB planes，NCHW [1,3,H,W]）
///   h = (x − mean)/std，mean=[0.485,0.456,0.406]，std=[0.229,0.224,0.225]
///     —— 归一化只作用于进网络的输入；特征层 0 是未归一化的原图 x
///   VGG16 的 4 个 MaxPool 替换为 L2pooling（x² → depthwise 3×3
///     Hanning 核 conv s2/p1 → sqrt(·+1e-12)，奇数尺寸输出
///     floor((H+1)/2)），取 relu1_2..relu5_3
///   6 层特征（x + relu1_2..5_3）逐通道统计（空间维 H×W，有偏方差）：
///     S1 = (2μxμy+c1)/(μx²+μy²+c1)，c1=1e-6
///     σxy = mean(x·y) − μxμy，S2 = (2σxy+c2)/(σx²+σy²+c2)，c2=1e-6
///   alpha/beta（各 1475）先除以 alpha.sum()+beta.sum()，按通道数
///     [3,64,128,256,512,512] 切 6 段；dist1 = Σ alpha_k[c]·S1[c]，
///     dist2 = Σ beta_k[c]·S2[c]；score = 1 − dist1 − dist2。
///
/// 纯 Dart（无 Flutter 依赖）。[distsScoreInIsolate] 为 compute()
/// 入口，[distsScoreParallel] 走 NnPool 多 isolate 并行（与同步版
/// 位级一致）；打分头（逐通道统计）经 [_distsHeadParallel] 按切片
/// 6 路 [Isolate.run] 后台并行（优化 9，同 LPIPS 的 UI 阻塞教训），
/// 与 [_distsFromFeats] 位级一致。
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../nn/nn_pool.dart';
import '../nn/nnw_reader.dart';
import '../nn/tensor.dart';
import 'vgg16_dart.dart';

/// VGG16 主干权重的缺省路径（相对工作目录）。
const String distsVggWeightsPath = 'tools/iqa/weights/vgg16.nnw';

/// DISTS alpha/beta 权重的缺省路径（相对工作目录）。
const String distsWeightsPath = 'tools/iqa/weights/dists.nnw';

/// 进网络输入的归一化常量（ImageNet mean/std）。
const _kMean = [0.485, 0.456, 0.406];
const _kStd = [0.229, 0.224, 0.225];

/// 6 层特征的通道数（原图 x + relu1_2..relu5_3）。
const _kChns = [3, 64, 128, 256, 512, 512];

/// compute() 入口：`{'rgbaA': Uint8List, 'rgbaB': Uint8List, 'width': int,
/// 'height': int, 'vggWeightsPath': String?, 'distsWeightsPath': String?}`
/// → DISTS 分值（double）。
@pragma('vm:entry-point')
double distsScoreInIsolate(Map<String, Object?> msg) => distsScore(
      msg['rgbaA'] as Uint8List,
      msg['rgbaB'] as Uint8List,
      msg['width'] as int,
      msg['height'] as int,
      vggWeightsPath:
          (msg['vggWeightsPath'] as String?) ?? distsVggWeightsPath,
      distsWeightsPath:
          (msg['distsWeightsPath'] as String?) ?? distsWeightsPath,
    );

/// RGBA8888 → [0,1] RGB planes（[1,3,H,W]）。
NnTensor _rgbaTo01(Uint8List rgba, int width, int height) {
  final s = width * height;
  final out = NnTensor.zeros([1, 3, height, width]);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    for (var i = 0, j = c; i < s; i++, j += 4) {
      out.data[base + i] = rgba[j] / 255.0;
    }
  }
  return out;
}

/// (x − mean)/std 逐通道归一化（仅作用于进网络的输入）。
NnTensor _normalizeForNet(NnTensor x) {
  final s = x.height * x.width;
  final out = NnTensor.zeros(x.shape);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    final m = _kMean[c], sd = _kStd[c];
    for (var i = 0; i < s; i++) {
      out.data[base + i] = (x.data[base + i] - m) / sd;
    }
  }
  return out;
}

/// 加载 alpha/beta 并按 alpha.sum()+beta.sum() 归一化（torch 参考先
/// 整体归一化再按通道数切段）。
(Float32List, Float32List) _loadAlphaBeta(String distsWeightsPath) {
  final reader = NnwReader.open(distsWeightsPath);
  try {
    final alpha = Float64List.fromList(
        reader.tensor('alpha').$1.map((v) => v.toDouble()).toList());
    final beta = Float64List.fromList(
        reader.tensor('beta').$1.map((v) => v.toDouble()).toList());
    var wSum = 0.0;
    for (var i = 0; i < alpha.length; i++) {
      wSum += alpha[i] + beta[i];
    }
    final aOut = Float32List(alpha.length);
    final bOut = Float32List(beta.length);
    for (var i = 0; i < alpha.length; i++) {
      aOut[i] = alpha[i] / wSum;
      bOut[i] = beta[i] / wSum;
    }
    return (aOut, bOut);
  } finally {
    reader.close();
  }
}

/// 由 6 层特征（层 0 为未归一化原图）计算 DISTS 分值。逐通道统计
/// 用 double 累加，torch 参考为 fp32，差异远小于对拍容差。
double _distsFromFeats(List<NnTensor> feats0, List<NnTensor> feats1,
    Float32List alpha, Float32List beta) {
  const c1 = 1e-6, c2 = 1e-6;
  var dist1 = 0.0, dist2 = 0.0;
  var wOff = 0;
  for (var k = 0; k < _kChns.length; k++) {
    final f0 = feats0[k], f1 = feats1[k];
    final c = f0.channels;
    final s = f0.height * f0.width;
    for (var ch = 0; ch < c; ch++) {
      final base = ch * s;
      var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0;
      for (var i = 0; i < s; i++) {
        final xv = f0.data[base + i];
        final yv = f1.data[base + i];
        sumX += xv;
        sumY += yv;
        sumXX += xv * xv;
        sumYY += yv * yv;
        sumXY += xv * yv;
      }
      final muX = sumX / s, muY = sumY / s;
      // 有偏方差（除 HW）：mean(x²) − μ²。
      final varX = sumXX / s - muX * muX;
      final varY = sumYY / s - muY * muY;
      final covXY = sumXY / s - muX * muY;
      final s1 = (2 * muX * muY + c1) / (muX * muX + muY * muY + c1);
      final s2 = (2 * covXY + c2) / (varX + varY + c2);
      dist1 += alpha[wOff + ch] * s1;
      dist2 += beta[wOff + ch] * s2;
    }
    wOff += c;
  }
  return 1 - dist1 - dist2;
}

/// Isolate.run 入口（优化 9）：单切片的逐通道 S1/S2 统计。消息为
/// (TransferableTypedData f0, TransferableTypedData f1, c, s)，返回
/// (Float64List s1, Float64List s2)（每通道一对；统计循环与
/// [_distsFromFeats] 逐语句相同，位级一致；alpha/beta 加权与跨切片
/// 累加留在调用侧按原序执行）。
@pragma('vm:entry-point')
(Float64List, Float64List) distsSliceStatsInIsolate(
    (TransferableTypedData, TransferableTypedData, int, int) msg) {
  const c1 = 1e-6, c2 = 1e-6;
  final f0 = msg.$1.materialize().asFloat32List();
  final f1 = msg.$2.materialize().asFloat32List();
  final c = msg.$3, s = msg.$4;
  final s1s = Float64List(c);
  final s2s = Float64List(c);
  for (var ch = 0; ch < c; ch++) {
    final base = ch * s;
    var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0;
    for (var i = 0; i < s; i++) {
      final xv = f0[base + i];
      final yv = f1[base + i];
      sumX += xv;
      sumY += yv;
      sumXX += xv * xv;
      sumYY += yv * yv;
      sumXY += xv * yv;
    }
    final muX = sumX / s, muY = sumY / s;
    // 有偏方差（除 HW）：mean(x²) − μ²。
    final varX = sumXX / s - muX * muX;
    final varY = sumYY / s - muY * muY;
    final covXY = sumXY / s - muX * muY;
    s1s[ch] = (2 * muX * muY + c1) / (muX * muX + muY * muY + c1);
    s2s[ch] = (2 * covXY + c2) / (varX + varY + c2);
  }
  return (s1s, s2s);
}

/// 打分头（优化 9）：6 个切片各自 Isolate.run 后台并行（特征经
/// TransferableTypedData 零拷贝进出，调用后 feats 的底层缓冲被转移、
/// 不可再用——两条调用路径的打分头均只调用一次，无复用）；alpha/beta
/// 加权与累加按 [_distsFromFeats] 的原序（k 升序、通道升序）在调用
/// 侧执行，位级一致。
Future<double> _distsHeadParallel(List<NnTensor> feats0,
    List<NnTensor> feats1, Float32List alpha, Float32List beta) async {
  final stats = await Future.wait([
    for (var k = 0; k < _kChns.length; k++)
      Isolate.run(
          () => distsSliceStatsInIsolate((
                TransferableTypedData.fromList([feats0[k].data]),
                TransferableTypedData.fromList([feats1[k].data]),
                feats0[k].channels,
                feats0[k].height * feats0[k].width,
              ))),
  ]);
  var dist1 = 0.0, dist2 = 0.0;
  var wOff = 0;
  for (var k = 0; k < _kChns.length; k++) {
    final c = feats0[k].channels;
    final (s1s, s2s) = stats[k];
    for (var ch = 0; ch < c; ch++) {
      dist1 += alpha[wOff + ch] * s1s[ch];
      dist2 += beta[wOff + ch] * s2s[ch];
    }
    wOff += c;
  }
  return 1 - dist1 - dist2;
}

void _checkPair(Uint8List rgbaA, Uint8List rgbaB, int width, int height) {
  if (width < 1 || height < 1 || rgbaA.length < width * height * 4) {
    throw ArgumentError('distsScore: 参考帧尺寸/数据长度不符 '
        '($width×$height, ${rgbaA.length})');
  }
  if (rgbaB.length < width * height * 4) {
    throw ArgumentError('distsScore: 测试帧数据长度不符（两帧须同尺寸）');
  }
}

/// DISTS 分值（同步单线程版）。两帧均为 RGBA8888、同尺寸。
double distsScore(Uint8List rgbaA, Uint8List rgbaB, int width, int height,
    {String vggWeightsPath = distsVggWeightsPath,
    String distsWeightsPath = distsWeightsPath}) {
  _checkPair(rgbaA, rgbaB, width, height);
  final vgg = Vgg16Dart.load(vggWeightsPath);
  final (alpha, beta) = _loadAlphaBeta(distsWeightsPath);
  final x0 = _rgbaTo01(rgbaA, width, height);
  final x1 = _rgbaTo01(rgbaB, width, height);
  final feats0 = [
    x0,
    ...vgg.forward(_normalizeForNet(x0), useL2Pooling: true),
  ];
  final feats1 = [
    x1,
    ...vgg.forward(_normalizeForNet(x1), useL2Pooling: true),
  ];
  return _distsFromFeats(feats0, feats1, alpha, beta);
}

/// DISTS 分值（NnPool 多 isolate 并行版）：结果与 [distsScore]
/// 位级一致。传入共享 [pool] 时直接使用（调用侧负责其生命周期）；
/// 缺省内部启动 [workers] 个 worker（缺省按 CPU 核数），算完即销毁。
///
/// [vggForward]（可选，如 GPU 纹理驻留的 Vgg16Gpu）非空且
/// [Vgg16AsyncForward.enabled] 时优先走 GPU 驻留链（L2pooling 变体）：
/// 两路输入共享同一份已上传权重、各自独立上传输入纹理（互不污染）；
/// 任何一步失败整链回退 CPU 池路径。
Future<double> distsScoreParallel(
    Uint8List rgbaA, Uint8List rgbaB, int width, int height,
    {String vggWeightsPath = distsVggWeightsPath,
    String distsWeightsPath = distsWeightsPath,
    int? workers,
    NnPool? pool,
    Vgg16AsyncForward? vggForward,
    void Function(bool usedGpu)? onBackend}) async {
  _checkPair(rgbaA, rgbaB, width, height);
  final vgg = Vgg16Dart.load(vggWeightsPath);
  final (alpha, beta) = _loadAlphaBeta(distsWeightsPath);
  final x0 = _rgbaTo01(rgbaA, width, height);
  final x1 = _rgbaTo01(rgbaB, width, height);
  final vf = vggForward;
  if (vf != null && Vgg16AsyncForward.enabled) {
    try {
      final feats0 = [
        x0,
        ...await vf.forward(_normalizeForNet(x0), useL2Pooling: true),
      ];
      final feats1 = [
        x1,
        ...await vf.forward(_normalizeForNet(x1), useL2Pooling: true),
      ];
      onBackend?.call(true);
      return _distsHeadParallel(feats0, feats1, alpha, beta);
    } catch (e) {
      // ignore: avoid_print
      print('[distsScoreParallel] GPU 前向失败，整链回退 CPU 池: $e');
    }
  }
  onBackend?.call(false);
  final ownPool = pool == null;
  final p = pool ?? NnPool();
  if (ownPool) await p.start(workers);
  try {
    final feats0 = [
      x0,
      ...await vgg.forwardParallel(_normalizeForNet(x0), p,
          useL2Pooling: true),
    ];
    final feats1 = [
      x1,
      ...await vgg.forwardParallel(_normalizeForNet(x1), p,
          useL2Pooling: true),
    ];
    return _distsHeadParallel(feats0, feats1, alpha, beta);
  } finally {
    if (ownPool) p.dispose();
  }
}
