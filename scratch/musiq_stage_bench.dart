// MUSIQ 新并行路径的分阶段耗时定位（2592×1940，全部公开 API）：
//   dart run scratch/musiq_stage_bench.dart
// 逐段计时：预处理/多尺度 patch/tokenizer/embedding/encoder，
// 定位 musiqScoreInIsolate 端到端 310s 的大头。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/musiq_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';

const int kW = 2592, kH = 1940;
const int kPatch = 32;

Uint8List busyFrame(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 1] = (128 +
              70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
              40 * math.cos((2 * x - y) / 6.7))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 2] = (128 +
              70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
          .clamp(0.0, 255.0)
          .toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

/// 逐字抄自 MusiqDart._prepareSeq（私有，复刻以取得拼接序列）。
(NnTensor, Int32List, Int32List, Int32List) prepareSeq(
    List<MusiqScalePatches> scales) {
  var total = 0;
  for (final sc in scales) {
    total += sc.seqLen;
  }
  final patches = NnTensor.zeros([total, 3, kPatch, kPatch]);
  final hse = Int32List(total);
  final scaleIds = Int32List(total);
  final mask = Int32List(total);
  var off = 0;
  for (final sc in scales) {
    patches.data.setRange(off * 3 * kPatch * kPatch,
        (off + sc.seqLen) * 3 * kPatch * kPatch, sc.patches.data);
    hse.setRange(off, off + sc.seqLen, sc.hse);
    mask.setRange(off, off + sc.seqLen, sc.mask);
    for (var i = 0; i < sc.seqLen; i++) {
      scaleIds[off + i] = sc.scaleId;
    }
    off += sc.seqLen;
  }
  return (patches, hse, scaleIds, mask);
}

Future<void> main() async {
  if (!File(musiqWeightsPath).existsSync()) {
    print('MUSIQ_STAGE_ERROR 缺少权重 $musiqWeightsPath');
    exit(1);
  }
  print('MUSIQ_STAGE cores=${Platform.numberOfProcessors}');
  var sw = Stopwatch()..start();
  final rgba = busyFrame(kW, kH);
  final x = musiqInput(rgba, kW, kH);
  print('MUSIQ_STAGE busyFrame+preprocess = ${sw.elapsedMilliseconds}ms');

  sw = Stopwatch()..start();
  final (patches, hse, scaleIds, mask) =
      prepareSeq(musiqMultiscalePatches(x));
  print('MUSIQ_STAGE patches = ${sw.elapsedMilliseconds}ms '
      'patches=${hse.length} tokens=${hse.length + 1}');

  final model = MusiqDart.load(musiqWeightsPath);
  final pool = NnPool();
  await pool.start(math.max(2, Platform.numberOfProcessors - 4));
  print('MUSIQ_STAGE load+pool.start(${pool.workerCount}w) '
      '= ${sw.elapsedMilliseconds}ms');

  sw = Stopwatch()..start();
  final tok = await model.tokenizerForwardParallel(patches, pool);
  print('MUSIQ_STAGE tokenizer = ${sw.elapsedMilliseconds}ms');

  sw = Stopwatch()..start();
  final emb = await model.embeddingForwardParallel(tok, pool);
  print('MUSIQ_STAGE embedding = ${sw.elapsedMilliseconds}ms');

  sw = Stopwatch()..start();
  final v =
      await model.encoderScoreParallel(emb.data, hse, scaleIds, mask, pool);
  print('MUSIQ_STAGE encoder = ${sw.elapsedMilliseconds}ms score=$v');
  pool.dispose();
}
