/// CLIPIQA（CLIP RN50 + 预计算文本特征）的进程内 Dart 实现，语义忠实于
/// pyiqa 的 CLIPIQA（scratch/eval_venv/Lib/site-packages/pyiqa/archs/
/// clipiqa_arch.py，model_type='clipiqa'、pos_embedding=False）：
///
///   x = RGBA→[0,1] RGB planes（NCHW [1,3,H,W]）
///   x = (x − mean)/std，mean=[0.48145466,0.4578275,0.40821073]，
///     std=[0.26862954,0.26130258,0.27577711]（OPENAI_CLIP_MEAN/STD）
///   imgFeat = RN50(x)（1024 维，见 clip_rn50_dart.dart）→ L2 归一化
///   logits = exp(logit_scale) · (imgFeat · textFeatᵀ)（[10]，.nnw 里
///     的 logit_scale 是原始参数 log(100)，用前先 exp()；text_features
///     [10,1024] 已 L2 归一化）
///   probs = logits.reshape(5,2).softmax(-1)，取每对正例（偶数索引）
///     概率，5 对平均即分数（0..1，越大越好）。
///
/// 纯 Dart（无 Flutter 依赖）。计算量大，勿在 UI isolate 直接跑
/// 同步版；[clipiqaScoreInIsolate] 为 compute() 入口，
/// [clipiqaScoreParallel] 走 NnPool 多 isolate 并行（与同步版位级一致）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../nn/nn_pool.dart';
import '../nn/nnw_reader.dart';
import '../nn/tensor.dart';
import 'clip_rn50_dart.dart';

/// CLIPIQA RN50 权重的缺省路径（相对工作目录）。
const String clipiqaWeightsPath = 'tools/iqa/weights/clipiqa_rn50.nnw';

/// OPENAI_CLIP_MEAN / STD（pyiqa.archs.constants）。
const _kMean = [0.48145466, 0.4578275, 0.40821073];
const _kStd = [0.26862954, 0.26130258, 0.27577711];

/// 提示词对数（'Good/bad image'、'Sharp/blurry image'、
/// 'sharp/blurry edges'、'High/low resolution image'、
/// 'Noise-free/noisy image'，每对偶数索引为正例）。
const _kPairs = 5;

/// compute() 入口：`{'rgba': Uint8List, 'width': int, 'height': int,
/// 'weightsPath': String?}` → CLIPIQA 分值（double，0..1）。
@pragma('vm:entry-point')
double clipiqaScoreInIsolate(Map<String, Object?> msg) => clipiqaScore(
      msg['rgba'] as Uint8List,
      msg['width'] as int,
      msg['height'] as int,
      weightsPath: (msg['weightsPath'] as String?) ?? clipiqaWeightsPath,
    );

/// RGBA8888 → 归一化 [1,3,H,W]：先 /255 到 [0,1]，再 (x−mean)/std
/// （逐通道）。
NnTensor clipiqaInput(Uint8List rgba, int width, int height) {
  final s = width * height;
  final out = NnTensor.zeros([1, 3, height, width]);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    final mean = _kMean[c], std = _kStd[c];
    for (var i = 0, j = c; i < s; i++, j += 4) {
      out.data[base + i] = (rgba[j] / 255.0 - mean) / std;
    }
  }
  return out;
}

/// CLIPIQA 的 logit_scale（已 exp）与文本特征（[10,1024]，已 L2 归一化）。
class ClipIqaParams {
  ClipIqaParams._(this.logitScaleExp, this.textFeatures);

  /// 从 .nnw 读取（与图像编码器同一文件）。
  factory ClipIqaParams.load(String nnwPath) {
    final reader = NnwReader.open(nnwPath);
    try {
      final logitScale = math.exp(reader.tensor('logit_scale').$1[0]);
      final tf = reader.tensor('text_features').$1;
      return ClipIqaParams._(logitScale, tf);
    } finally {
      reader.close();
    }
  }

  final double logitScaleExp;

  /// [10,1024] 行主序（每行一条提示词的归一化文本特征）。
  final Float32List textFeatures;
}

/// 由 1024 维图像特征计算 CLIPIQA 分值：L2 归一化 → logits → 每对
/// softmax 取正例概率 → 5 对平均。
double clipiqaScoreFromFeat(Float32List feat, ClipIqaParams params) {
  if (feat.length != 1024 || params.textFeatures.length != 2 * _kPairs * 1024) {
    throw ArgumentError('clipiqaScoreFromFeat: 特征维度不符 '
        '(${feat.length}, textFeatures ${params.textFeatures.length})');
  }
  var norm = 0.0;
  for (final v in feat) {
    norm += v * v;
  }
  norm = math.sqrt(norm);
  final logits = List<double>.filled(2 * _kPairs, 0.0);
  for (var i = 0; i < 2 * _kPairs; i++) {
    final base = i * 1024;
    var dot = 0.0;
    for (var j = 0; j < 1024; j++) {
      dot += feat[j] * params.textFeatures[base + j];
    }
    logits[i] = params.logitScaleExp * dot / norm;
  }
  var score = 0.0;
  for (var p = 0; p < _kPairs; p++) {
    final l0 = logits[2 * p], l1 = logits[2 * p + 1];
    final m = math.max(l0, l1);
    final e0 = math.exp(l0 - m), e1 = math.exp(l1 - m);
    score += e0 / (e0 + e1); // 正例为每对偶数索引
  }
  return score / _kPairs;
}

void _checkInput(Uint8List rgba, int width, int height) {
  if (width < 1 || height < 1 || rgba.length < width * height * 4) {
    throw ArgumentError('clipiqaScore: 帧尺寸/数据长度不符 '
        '($width×$height, ${rgba.length})');
  }
}

/// CLIPIQA 分值（同步单线程版）。输入 RGBA8888，任意分辨率（无 resize）。
double clipiqaScore(Uint8List rgba, int width, int height,
    {String weightsPath = clipiqaWeightsPath}) {
  _checkInput(rgba, width, height);
  final rn50 = ClipRn50Dart.load(weightsPath);
  final params = ClipIqaParams.load(weightsPath);
  final feat = rn50.forward(clipiqaInput(rgba, width, height));
  return clipiqaScoreFromFeat(feat, params);
}

/// CLIPIQA 分值（NnPool 多 isolate 并行版）：结果与 [clipiqaScore]
/// 位级一致。传入共享 [pool] 时直接使用（调用侧负责其生命周期）；
/// 缺省内部启动 [workers] 个 worker（缺省按 CPU 核数），算完即销毁。
Future<double> clipiqaScoreParallel(Uint8List rgba, int width, int height,
    {String weightsPath = clipiqaWeightsPath, int? workers,
    NnPool? pool}) async {
  _checkInput(rgba, width, height);
  final rn50 = ClipRn50Dart.load(weightsPath);
  final params = ClipIqaParams.load(weightsPath);
  final ownPool = pool == null;
  final p = pool ?? NnPool();
  if (ownPool) await p.start(workers);
  try {
    final feat =
        await rn50.forwardParallel(clipiqaInput(rgba, width, height), p);
    return clipiqaScoreFromFeat(feat, params);
  } finally {
    if (ownPool) p.dispose();
  }
}
