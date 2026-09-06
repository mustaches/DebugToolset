// 一次性耗时测量：InceptionV3Dart 单 patch 同步耗时与整图
// （~190 patch）patch 并行耗时；2048² 特征值求解耗时（模拟 FID 出分
// 规模，10 样本协方差之积）。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';

Uint8List busyFrame(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] =
          (128 + 70 * math.sin(x / 3.1) * math.cos(y / 2.7)).clamp(0, 255)
              .toInt();
      rgba[i + 1] =
          (128 + 70 * math.cos(x / 4.1) * math.sin(y / 3.3)).clamp(0, 255)
              .toInt();
      rgba[i + 2] = (128 + 70 * math.sin((x - y) / 3.7)).clamp(0, 255).toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<void> main() async {
  final sw = Stopwatch()..start();
  final net = InceptionV3Dart.load(inceptionV3WeightsPath);
  print('权重加载：${sw.elapsed}');

  // 单 patch（299² 前向）同步耗时。
  final small = busyFrame(256, 192);
  sw.reset();
  net.inceptionPatchFeatures(small, 256, 192);
  print('单 patch 同步（首次，含 JIT 预热）：${sw.elapsed}');
  sw.reset();
  net.inceptionPatchFeatures(small, 256, 192);
  print('单 patch 同步（第二次）：${sw.elapsed}');

  // 整图 ~190 patch：2100×2048 → s=299，xs×ys。
  const w = 2100, h = 2048;
  final grid = inceptionPatchGrid(w, h);
  print('整图 $w×$h → ${grid.length} patch');
  final big = busyFrame(w, h);
  sw.reset();
  final feats = await inceptionPatchFeaturesParallel(big, w, h);
  print('整图 ${grid.length} patch 并行耗时：${sw.elapsed}'
      '（特征 ${feats.length ~/ 2048}×2048）');

  // 2048² 特征值求解（FID 出分规模：10 样本的协方差之积）。
  final rng = math.Random(0);
  final fr = Float32List(10 * 2048);
  final ft = Float32List(10 * 2048);
  for (var i = 0; i < fr.length; i++) {
    fr[i] = rng.nextDouble() * 2;
    ft[i] = rng.nextDouble() * 2;
  }
  final accR = FidAccumulator()..addBatch(fr, 10);
  final accT = FidAccumulator()..addBatch(ft, 10);
  sw.reset();
  final fid = fidCompute(accR, accT);
  print('FID 出分（10v10，含 dgemm + eig 2048²）耗时：${sw.elapsed}，'
      'fid=$fid');

  // 仅 eig 本身（σ1σ2 已算好时再测一次纯求解耗时）。
  final (mu1, s1) = accR.meanCov();
  final (mu2, s2) = accT.meanCov();
  final prod = Float64List(2048 * 2048);
  sw.reset();
  dgemmNn(s1, s2, prod, 2048, 2048, 2048);
  print('dgemm 2048³ 耗时：${sw.elapsed}');
  sw.reset();
  final ev = eigvalsReal(prod, 2048);
  print('eigvalsReal 2048² 耗时：${sw.elapsed}（maxIm='
      '${ev.im.map((v) => v.abs()).reduce(math.max).toStringAsExponential(2)}）');
}
