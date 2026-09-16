// KID 逐帧累计出分基准（优化 17）：模拟视频播放场景 F 帧 × Δ patch/侧
// 的累计过程，对比旧路径（每帧全量 kidCompute 重算 Gram）与新路径
//（KidGramAccum 增量核矩阵）的总耗时，并逐帧断言分数逐位一致（==）。
// 特征用固定种子随机数（点积耗时与数据无关，计时口径不受影响）。
// 运行：dart run scratch/kid_accum_bench.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';

void main() {
  const frames = 15; // 模拟帧数
  const delta = 100; // 每帧每侧 patch 数（1688×3000 帧约 190）
  const dim = fidFeatureDim;
  final rng = math.Random(7);

  Float32List randFeats(int n) {
    final out = Float32List(n * dim);
    for (var i = 0; i < out.length; i++) {
      out[i] = rng.nextDouble();
    }
    return out;
  }

  // 预生成全部帧的特征（生成耗时不计入）。
  final refFrames = [for (var f = 0; f < frames; f++) randFeats(delta)];
  final testFrames = [for (var f = 0; f < frames; f++) randFeats(delta)];

  var oldTotal = 0, newTotal = 0;
  final accum = KidGramAccum();
  // 旧路径的全量特征缓冲（每帧 concat 口径）。
  final refAll = Float32List(frames * delta * dim);
  final testAll = Float32List(frames * delta * dim);
  for (var f = 0; f < frames; f++) {
    refAll.setRange(f * delta * dim, (f + 1) * delta * dim, refFrames[f]);
    testAll.setRange(f * delta * dim, (f + 1) * delta * dim, testFrames[f]);
    final n = (f + 1) * delta;

    var sw = Stopwatch()..start();
    final oldScore = kidCompute(refAll, n, testAll, n);
    sw.stop();
    oldTotal += sw.elapsedMicroseconds;
    final oldUs = sw.elapsedMicroseconds;

    sw
      ..reset()
      ..start();
    accum.addBatch(refFrames[f], delta, testFrames[f], delta);
    final newScore = accum.score();
    sw.stop();
    newTotal += sw.elapsedMicroseconds;

    final match = oldScore == newScore ? '位级一致' : '不一致!!';
    // ignore: avoid_print
    print('帧 ${f + 1}/$frames n=$n：旧 ${oldUs / 1000}ms '
        '新 ${sw.elapsedMicroseconds / 1000}ms $match');
    if (oldScore != newScore) {
      // ignore: avoid_print
      print('  old=$oldScore new=$newScore');
    }
  }
  // ignore: avoid_print
  print('总耗时：旧 ${oldTotal / 1000}ms 新 ${newTotal / 1000}ms '
      '（加速 ${oldTotal / math.max(1, newTotal)}×）');
}
