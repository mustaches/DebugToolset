// MUSIQ 池并行编码器（优化 10）的位级验收：
//   dart run scratch/musiq_bitexact_check.dart
// 64×64 小输入（token 很少，秒级跑完）：
//   1) encoderScore（同步）vs encoderScoreParallel（NnPool 4 worker）
//      严格 ==；
//   2) musiqScore（同步）vs musiqScoreInIsolate（新后台路径，自起
//      NnPool）端到端严格 ==；
//   3) musiqScoreParallel（4 worker）vs 同步 ==（同 test 口径）。
// 全过打印 MUSIQ_BITEXACT 各行 true 并以 exit(0) 结束，任一不符 exit(1)。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/musiq_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';

const int kW = 64, kH = 64;
const int kPatch = 32;

/// 高纹理彩色测试帧（图案同 test/isp_pyiqa_test.dart 的 busyFrame）。
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

/// 拼接三尺度为单条序列（逐字抄自 MusiqDart._prepareSeq——私有，
/// 此处复刻以构造 encoder 输入）。
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
    print('MUSIQ_BITEXACT_ERROR 缺少权重 $musiqWeightsPath');
    exit(1);
  }
  final rgba = busyFrame(kW, kH);
  final model = MusiqDart.load(musiqWeightsPath);
  final x = musiqInput(rgba, kW, kH);
  final (patches, hse, scaleIds, mask) =
      prepareSeq(musiqMultiscalePatches(x));
  print('MUSIQ_BITEXACT ${kW}x$kH patches=${hse.length} '
      'tokens=${hse.length + 1}');
  final emb = model.embeddingForward(model.tokenizerForward(patches));

  // 1) encoder 级：同步 vs 池并行（4 worker）。
  final sw = Stopwatch()..start();
  final syncV = model.encoderScore(emb.data, hse, scaleIds, mask);
  final syncMs = sw.elapsedMilliseconds;
  final pool = NnPool();
  await pool.start(4);
  sw.reset();
  final parV =
      await model.encoderScoreParallel(emb.data, hse, scaleIds, mask, pool);
  final parMs = sw.elapsedMilliseconds;
  print('MUSIQ_BITEXACT encoder=${syncV == parV} '
      'sync=$syncV parallel=$parV (sync ${syncMs}ms / parallel ${parMs}ms)');

  // 2) 端到端：musiqScore（同步）vs musiqScoreInIsolate（后台路径）。
  sw.reset();
  final e2eSync = musiqScore(rgba, kW, kH);
  final e2eSyncMs = sw.elapsedMilliseconds;
  sw.reset();
  final e2ePar = await musiqScoreInIsolate(
      {'rgba': rgba, 'width': kW, 'height': kH});
  final e2eParMs = sw.elapsedMilliseconds;
  print('MUSIQ_BITEXACT e2e=${e2eSync == e2ePar} '
      'sync=$e2eSync isolate=$e2ePar (sync ${e2eSyncMs}ms / '
      'isolate ${e2eParMs}ms)');

  // 3) musiqScoreParallel（共享 pool 口径）vs 同步。
  final ppV = await musiqScoreParallel(rgba, kW, kH, pool: pool);
  print('MUSIQ_BITEXACT scoreParallel=${e2eSync == ppV} '
      'sync=$e2eSync parallel=$ppV');
  pool.dispose();

  final ok = syncV == parV && e2eSync == e2ePar && e2eSync == ppV;
  print('MUSIQ_BITEXACT all=$ok');
  exit(ok ? 0 : 1);
}
