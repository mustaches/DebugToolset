/// LPIPS（vgg 主干，v0.1 口径）的进程内 Dart 实现，语义忠实于
/// lpips 包（scratch/eval_venv/Lib/site-packages/lpips/lpips.py）：
///
///   x = RGBA→[0,1] RGB planes（NCHW [1,3,H,W]）
///   x = x*2−1（调用侧馈 [0,1]，等价于参考的 normalize=True）
///   ScalingLayer：out = (in − shift)/scale，
///     shift=[−0.030,−0.088,−0.188]，scale=[0.458,0.448,0.450]
///   VGG16（maxpool 版）取 relu1_2..relu5_3 共 5 层特征
///   每层：通道维 L2 归一化（eps=1e-10 加在根号外）→ (f0−f1)²
///     → 线性头点乘（lin{k}.model.1.weight，[1,C,1,1]，无 bias）
///     → 空间均值 → 5 层求和即分数（越小越相似）。
///
/// 纯 Dart（无 Flutter 依赖）。计算量大，勿在 UI isolate 直接跑
/// 同步版；[lpipsScoreInIsolate] 为 compute() 入口，
/// [lpipsScoreParallel] 走 NnPool 多 isolate 并行（与同步版位级一致）。
library;

import 'dart:typed_data';

import '../nn/nn_pool.dart';
import '../nn/nnw_reader.dart';
import '../nn/ops.dart' as ops;
import '../nn/tensor.dart';
import 'vgg16_dart.dart';

/// VGG16 主干权重的缺省路径（相对工作目录）。
const String lpipsVggWeightsPath = 'tools/iqa/weights/vgg16.nnw';

/// LPIPS 线性头权重的缺省路径（相对工作目录）。
const String lpipsLinWeightsPath = 'tools/iqa/weights/lpips_vgg01.nnw';

/// ScalingLayer 常量（lpips.ScalingLayer 的 buffer）。
const _kShift = [-0.030, -0.088, -0.188];
const _kScale = [0.458, 0.448, 0.450];

/// compute() 入口：`{'rgbaA': Uint8List, 'rgbaB': Uint8List, 'width': int,
/// 'height': int, 'vggWeightsPath': String?, 'linWeightsPath': String?}`
/// → LPIPS 分值（double）。
@pragma('vm:entry-point')
double lpipsScoreInIsolate(Map<String, Object?> msg) => lpipsScore(
      msg['rgbaA'] as Uint8List,
      msg['rgbaB'] as Uint8List,
      msg['width'] as int,
      msg['height'] as int,
      vggWeightsPath:
          (msg['vggWeightsPath'] as String?) ?? lpipsVggWeightsPath,
      linWeightsPath:
          (msg['linWeightsPath'] as String?) ?? lpipsLinWeightsPath,
    );

/// RGBA8888 → ScalingLayer 输出（[1,3,H,W]）：先 /255 到 [0,1]，
/// 再 x*2−1，最后 (in−shift)/scale（逐通道）。
NnTensor _lpipsInput(Uint8List rgba, int width, int height) {
  final s = width * height;
  final out = NnTensor.zeros([1, 3, height, width]);
  for (var c = 0; c < 3; c++) {
    final base = c * s;
    final shift = _kShift[c], scale = _kScale[c];
    for (var i = 0, j = c; i < s; i++, j += 4) {
      out.data[base + i] = ((rgba[j] / 255.0) * 2.0 - 1.0 - shift) / scale;
    }
  }
  return out;
}

/// LPIPS 线性头权重（5 层，各 [C] 的逐通道系数）。
List<Float32List> _loadLinWeights(String linWeightsPath) {
  final reader = NnwReader.open(linWeightsPath);
  try {
    return [
      for (var k = 0; k < 5; k++) reader.tensor('lin$k.model.1.weight').$1,
    ];
  } finally {
    reader.close();
  }
}

/// 由 5 层特征计算 LPIPS 分值（归一化 → 平方差 → 线性头 → 空间均值
/// → 求和）。累加用 double，torch 参考为 fp32，差异远小于对拍容差。
double _lpipsFromFeats(
    List<NnTensor> feats0, List<NnTensor> feats1, List<Float32List> linW) {
  var score = 0.0;
  for (var k = 0; k < 5; k++) {
    final f0 = ops.l2NormalizeChannels(feats0[k]);
    final f1 = ops.l2NormalizeChannels(feats1[k]);
    final c = f0.channels;
    final s = f0.height * f0.width;
    final w = linW[k];
    var layerSum = 0.0;
    for (var ch = 0; ch < c; ch++) {
      final base = ch * s;
      final wv = w[ch];
      var chSum = 0.0;
      for (var i = 0; i < s; i++) {
        final d = f0.data[base + i] - f1.data[base + i];
        chSum += d * d;
      }
      layerSum += wv * chSum;
    }
    score += layerSum / s; // spatial_average：mean over H×W
  }
  return score;
}

void _checkPair(Uint8List rgbaA, Uint8List rgbaB, int width, int height) {
  if (width < 1 || height < 1 || rgbaA.length < width * height * 4) {
    throw ArgumentError('lpipsScore: 参考帧尺寸/数据长度不符 '
        '($width×$height, ${rgbaA.length})');
  }
  if (rgbaB.length < width * height * 4) {
    throw ArgumentError('lpipsScore: 测试帧数据长度不符（两帧须同尺寸）');
  }
}

/// LPIPS 分值（同步单线程版）。两帧均为 RGBA8888、同尺寸。
double lpipsScore(Uint8List rgbaA, Uint8List rgbaB, int width, int height,
    {String vggWeightsPath = lpipsVggWeightsPath,
    String linWeightsPath = lpipsLinWeightsPath}) {
  _checkPair(rgbaA, rgbaB, width, height);
  final vgg = Vgg16Dart.load(vggWeightsPath);
  final linW = _loadLinWeights(linWeightsPath);
  final feats0 = vgg.forward(_lpipsInput(rgbaA, width, height));
  final feats1 = vgg.forward(_lpipsInput(rgbaB, width, height));
  return _lpipsFromFeats(feats0, feats1, linW);
}

/// LPIPS 分值（NnPool 多 isolate 并行版）：结果与 [lpipsScore]
/// 位级一致。传入共享 [pool] 时直接使用（调用侧负责其生命周期，
/// 如 ISP Studio 状态持有的常驻池）；缺省内部启动 [workers] 个
/// worker（缺省按 CPU 核数），算完即销毁。
///
/// [vggForward]（可选，如 GPU 纹理驻留的 Vgg16Gpu）非空且
/// [Vgg16AsyncForward.enabled] 时优先走 GPU 驻留链：两路输入共享同
/// 一份已上传权重、各自独立上传输入纹理（互不污染）；任何一步失败
/// 整链回退 CPU 池路径。GPU 路径的分数精度见
/// test/isp_nn_gpu_vgg_test.dart 的对拍记录。
Future<double> lpipsScoreParallel(
    Uint8List rgbaA, Uint8List rgbaB, int width, int height,
    {String vggWeightsPath = lpipsVggWeightsPath,
    String linWeightsPath = lpipsLinWeightsPath,
    int? workers,
    NnPool? pool,
    Vgg16AsyncForward? vggForward,
    void Function(bool usedGpu)? onBackend}) async {
  _checkPair(rgbaA, rgbaB, width, height);
  final vgg = Vgg16Dart.load(vggWeightsPath);
  final linW = _loadLinWeights(linWeightsPath);
  final vf = vggForward;
  if (vf != null && Vgg16AsyncForward.enabled) {
    try {
      final feats0 = await vf.forward(_lpipsInput(rgbaA, width, height));
      final feats1 = await vf.forward(_lpipsInput(rgbaB, width, height));
      onBackend?.call(true);
      return _lpipsFromFeats(feats0, feats1, linW);
    } catch (e) {
      // ignore: avoid_print
      print('[lpipsScoreParallel] GPU 前向失败，整链回退 CPU 池: $e');
    }
  }
  onBackend?.call(false);
  final ownPool = pool == null;
  final p = pool ?? NnPool();
  if (ownPool) await p.start(workers);
  try {
    final feats0 =
        await vgg.forwardParallel(_lpipsInput(rgbaA, width, height), p);
    final feats1 =
        await vgg.forwardParallel(_lpipsInput(rgbaB, width, height), p);
    return _lpipsFromFeats(feats0, feats1, linW);
  } finally {
    if (ownPool) p.dispose();
  }
}
