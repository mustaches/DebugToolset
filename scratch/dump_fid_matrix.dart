// 一次性：提取 eval_set 10 帧的 Inception 特征（并行），构建 FID 的
// σ1σ2 并保存到 scratch/eig_stuck.f64（fp64 LE 行主序 2048²），
// 供 eig 求解器收敛性调试（避免每次重跑特征提取）。
import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';
import 'package:image/image.dart' as img;

Uint8List loadRgba(String path) {
  final image = img.decodePng(File(path).readAsBytesSync())!;
  final w = image.width, h = image.height;
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      final i = (y * w + x) * 4;
      rgba[i] = p.r.toInt();
      rgba[i + 1] = p.g.toInt();
      rgba[i + 2] = p.b.toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<void> main() async {
  final accR = FidAccumulator();
  final accT = FidAccumulator();
  final sw = Stopwatch()..start();
  for (var i = 0; i < 5; i++) {
    final fr = await inceptionPatchFeaturesParallel(
        loadRgba('scratch/eval_set/ref_$i.png'), 256, 192);
    final ft = await inceptionPatchFeaturesParallel(
        loadRgba('scratch/eval_set/test_$i.png'), 256, 192);
    accR.addBatch(fr, 2);
    accT.addBatch(ft, 2);
  }
  print('特征提取 ${sw.elapsed}');
  final (_, s1) = accR.meanCov();
  final (_, s2) = accT.meanCov();
  final prod = Float64List(2048 * 2048);
  dgemmNn(s1, s2, prod, 2048, 2048, 2048);
  await File('scratch/eig_stuck.f64').writeAsBytes(
      prod.buffer.asUint8List());
  var mx = 0.0;
  for (final v in prod) {
    if (v.abs() > mx) mx = v.abs();
  }
  print('已保存 scratch/eig_stuck.f64，maxAbs=$mx');
}
