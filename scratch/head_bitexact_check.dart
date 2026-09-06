// 优化 9 打分头位级一致性抽查（一次性脚本）：小尺寸随机特征上对比
// 新后台单切片实现与原同步路径的逐位一致（==，不是近似）。
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/dists_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart'
    as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';

void main() {
  final rng = math.Random(42);
  Float32List rand(int n) =>
      Float32List.fromList([for (var i = 0; i < n; i++) rng.nextDouble() * 2 - 1]);

  // ---- LPIPS 单切片：融合单遍 vs 「l2NormalizeChannels 副本 + 差方」 ----
  for (final (c, h, w) in [(3, 5, 7), (64, 33, 31), (512, 6, 5)]) {
    final f0 = rand(c * h * w);
    final f1 = rand(c * h * w);
    final linW = rand(c);
    final s = h * w;
    // 原实现（照抄 _lpipsFromFeats 的单切片部分）。
    final g0 = ops.l2NormalizeChannels(NnTensor(f0, [1, c, h, w]));
    final g1 = ops.l2NormalizeChannels(NnTensor(f1, [1, c, h, w]));
    var layerSum = 0.0;
    for (var ch = 0; ch < c; ch++) {
      final base = ch * s;
      final wv = linW[ch];
      var chSum = 0.0;
      for (var i = 0; i < s; i++) {
        final d = g0.data[base + i] - g1.data[base + i];
        chSum += d * d;
      }
      layerSum += wv * chSum;
    }
    final orig = layerSum / s;
    final fused = lpipsSliceScoreInIsolate((
      TransferableTypedData.fromList([f0]),
      TransferableTypedData.fromList([f1]),
      TransferableTypedData.fromList([linW]),
      c,
      s,
    ));
    final same = orig == fused;
    // ignore: avoid_print
    print('LPIPS_HEAD_BITEXACT c=$c ${h}x$w orig=$orig fused=$fused '
        'bitexact=$same');
    if (!same) {
      throw StateError('LPIPS 打分头位级不一致 c=$c ${h}x$w');
    }
  }

  // ---- DISTS 单切片：isolate 统计 vs 内联同式 ----
  for (final (c, h, w) in [(3, 5, 7), (64, 33, 31), (512, 6, 5)]) {
    final f0 = rand(c * h * w);
    final f1 = rand(c * h * w);
    final s = h * w;
    const c1 = 1e-6, c2 = 1e-6;
    // 原实现（照抄 _distsFromFeats 的单切片部分）。
    final refS1 = Float64List(c);
    final refS2 = Float64List(c);
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
      final varX = sumXX / s - muX * muX;
      final varY = sumYY / s - muY * muY;
      final covXY = sumXY / s - muX * muY;
      refS1[ch] = (2 * muX * muY + c1) / (muX * muX + muY * muY + c1);
      refS2[ch] = (2 * covXY + c2) / (varX + varY + c2);
    }
    final (s1s, s2s) = distsSliceStatsInIsolate((
      TransferableTypedData.fromList([f0]),
      TransferableTypedData.fromList([f1]),
      c,
      s,
    ));
    var same = true;
    for (var ch = 0; ch < c; ch++) {
      if (s1s[ch] != refS1[ch] || s2s[ch] != refS2[ch]) same = false;
    }
    // ignore: avoid_print
    print('DISTS_HEAD_BITEXACT c=$c ${h}x$w bitexact=$same');
    if (!same) {
      throw StateError('DISTS 打分头位级不一致 c=$c ${h}x$w');
    }
  }
  // ignore: avoid_print
  print('HEAD_BITEXACT_ALL_OK');
}
