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
/// [lpipsScoreParallel] 走 NnPool 多 isolate 并行（与同步版位级一致）；
/// 打分头（归一化+平方差+线性头）经 [_lpipsHeadParallel] 按切片 5 路
/// [Isolate.run] 后台并行（优化 9：曾在 UI isolate 同步执行，MUSIQ
/// 争抢下实测 388s 连续 STALL），与 [_lpipsFromFeats] 位级一致。
library;

import 'dart:isolate';
import 'dart:math' as math;
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

/// Isolate.run 入口（优化 9）：单切片打分——归一化+平方差+线性头融合
/// 单遍，消掉两个全尺寸归一化副本（slice0 单张 1.3GB）的分配。
/// 位级一致要点：归一化中间值经 2 元素 fp32 scratch 强制舍入（原实现
/// 是写入 Float32List 再读出参与差方）；范数按通道序 double 累加、
/// norm=sqrt(sumSq)+1e-10（同 ops.l2NormalizeChannels）；除法→减法→
/// 乘法→加法的 IEEE 运算顺序与原实现逐元素相同。
/// 消息为 (TransferableTypedData f0, TransferableTypedData f1,
/// TransferableTypedData linW, c, s)（f0/f1 为 [c,s] NCHW 单切片），
/// 返回该切片的 layerSum/s。
@pragma('vm:entry-point')
double lpipsSliceScoreInIsolate(
    (TransferableTypedData, TransferableTypedData, TransferableTypedData,
        int, int) msg) {
  final f0 = msg.$1.materialize().asFloat32List();
  final f1 = msg.$2.materialize().asFloat32List();
  final w = msg.$3.materialize().asFloat32List();
  final c = msg.$4, s = msg.$5;
  // 各空间位置的通道 L2 范数。
  final n0 = Float64List(s);
  final n1 = Float64List(s);
  for (var i = 0; i < s; i++) {
    var sumSq0 = 0.0, sumSq1 = 0.0;
    for (var ch = 0; ch < c; ch++) {
      final v0 = f0[ch * s + i];
      final v1 = f1[ch * s + i];
      sumSq0 += v0 * v0;
      sumSq1 += v1 * v1;
    }
    n0[i] = math.sqrt(sumSq0) + 1e-10;
    n1[i] = math.sqrt(sumSq1) + 1e-10;
  }
  final scratch = Float32List(2); // 强制 fp32 舍入（位级一致关键）
  var layerSum = 0.0;
  for (var ch = 0; ch < c; ch++) {
    final base = ch * s;
    final wv = w[ch];
    var chSum = 0.0;
    for (var i = 0; i < s; i++) {
      scratch[0] = f0[base + i] / n0[i];
      scratch[1] = f1[base + i] / n1[i];
      final d = scratch[0] - scratch[1];
      chSum += d * d;
    }
    layerSum += wv * chSum;
  }
  return layerSum / s;
}

/// 打分头（优化 9）：5 个切片各自 Isolate.run 后台并行（特征经
/// TransferableTypedData 零拷贝进出，调用后 feats/linW 的底层缓冲被
/// 转移、不可再用——两条调用路径的打分头均只调用一次，无复用），
/// 按 k=0..4 序求和（累加顺序与 [_lpipsFromFeats] 相同，位级一致）。
Future<double> _lpipsHeadParallel(
    List<NnTensor> feats0, List<NnTensor> feats1,
    List<Float32List> linW) async {
  final parts = await Future.wait([
    for (var k = 0; k < 5; k++)
      Isolate.run(
          () => lpipsSliceScoreInIsolate((
                TransferableTypedData.fromList([feats0[k].data]),
                TransferableTypedData.fromList([feats1[k].data]),
                TransferableTypedData.fromList([linW[k]]),
                feats0[k].channels,
                feats0[k].height * feats0[k].width,
              ))),
  ]);
  var score = 0.0;
  for (var k = 0; k < 5; k++) {
    score += parts[k];
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
      return _lpipsHeadParallel(feats0, feats1, linW);
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
    return _lpipsHeadParallel(feats0, feats1, linW);
  } finally {
    if (ownPool) p.dispose();
  }
}
