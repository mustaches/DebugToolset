// MUSIQ 进程内 Dart 实现（metrics/musiq_dart.dart）的测试：多尺度
// patch 切分参数、patch 数据、tokenizer 16384 维输出、embedding 输出
// 与最终分数的分层黄金值对拍，自洽性（同步与池并行位级一致）与
// （Python 环境可用时的）端到端桥接对拍。
//
// 黄金值由 tools/iqa/dump_musiq_golden.py 生成
// （test/golden/musiq_golden.{nnw,json}，busyFrame 256×192 干净/加噪，
// CPU fp32）；端到端对拍经 tools/iqa/iqa_bridge.py 一次性模式取
// Python 参考分，绝对误差 ≤0.05 分。Python 环境、.nnw 权重或黄金值
// 缺失时自动跳过（同 test/isp_clipiqa_dart_test.dart 的跳过模式）。
// busyFrame 图案与 test/isp_pyiqa_test.dart 相同。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/musiq_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nnw_reader.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';

void main() {
  /// 高纹理彩色测试帧（图案同 test/isp_pyiqa_test.dart 的 busyFrame）。
  Uint8List busyFrame(int w, int h, {bool noisy = false, int noiseSeed = 0}) {
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        var r = (128 +
                70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
                40 * math.sin((x + 2 * y) / 5.3))
            .clamp(0.0, 255.0)
            .toInt();
        var g = (128 +
                70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
                40 * math.cos((2 * x - y) / 6.7))
            .clamp(0.0, 255.0)
            .toInt();
        var b = (128 +
                70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
            .clamp(0.0, 255.0)
            .toInt();
        if (noisy) {
          // 确定性噪声（元素序按 RGB 三通道计）。
          final base = ((y * w + x) * 3) + noiseSeed * 7;
          r = (r + (base * 31) % 61 - 30).clamp(0, 255);
          g = (g + ((base + 1) * 31) % 61 - 30).clamp(0, 255);
          b = (b + ((base + 2) * 31) % 61 - 30).clamp(0, 255);
        }
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  bool weightsExist() => File(musiqWeightsPath).existsSync();

  const goldenNnW = 'test/golden/musiq_golden.nnw';
  const goldenJson = 'test/golden/musiq_golden.json';
  bool goldenExist() =>
      File(goldenNnW).existsSync() && File(goldenJson).existsSync();

  /// 余弦相似度（a、b 等长）。
  double cosine(Float32List a, Float32List b, [int offsetA = 0, int len = 0]) {
    final n = len > 0 ? len : a.length;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < n; i++) {
      dot += a[offsetA + i] * b[i];
      na += a[offsetA + i] * a[offsetA + i];
      nb += b[i] * b[i];
    }
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// 拼接三尺度为完整序列的 patch 数据 [S,3072] 与 hse/mask。
  (Float32List, Int32List, Int32List) concatScales(List<MusiqScalePatches> s) {
    var total = 0;
    for (final sc in s) {
      total += sc.seqLen;
    }
    final patches = Float32List(total * 3072);
    final hse = Int32List(total), mask = Int32List(total);
    var off = 0;
    for (final sc in s) {
      patches.setRange(off * 3072, (off + sc.seqLen) * 3072, sc.patches.data);
      hse.setRange(off, off + sc.seqLen, sc.hse);
      mask.setRange(off, off + sc.seqLen, sc.mask);
      off += sc.seqLen;
    }
    return (patches, hse, mask);
  }

  const cases = [('clean', false), ('noisy', true)];

  group('多尺度 patch 切分对拍（需黄金值，无需 .nnw 权重/Python）', () {
    test('rh/rw/patch 数/hse/mask 与 pyiqa 一致', () {
      if (!goldenExist()) return;
      const w = 256, h = 192;
      final meta =
          jsonDecode(File(goldenJson).readAsStringSync()) as Map<String, Object?>;
      for (final (key, noisy) in cases) {
        final info =
            (meta['images'] as Map<String, Object?>)[key]! as Map<String, Object?>;
        final scales = musiqMultiscalePatches(
            musiqInput(busyFrame(w, h, noisy: noisy), w, h));
        final refScales = info['scales']! as List;
        expect(scales.length, refScales.length, reason: key);
        var total = 0, maskSum = 0;
        for (var i = 0; i < scales.length; i++) {
          final sc = scales[i];
          final ref = refScales[i] as Map<String, Object?>;
          expect(sc.rh, ref['rh'], reason: '$key scale$i rh');
          expect(sc.rw, ref['rw'], reason: '$key scale$i rw');
          expect(sc.countH, ref['count_h'], reason: '$key scale$i count_h');
          expect(sc.countW, ref['count_w'], reason: '$key scale$i count_w');
          expect(sc.realPatches, ref['real_patches'],
              reason: '$key scale$i real_patches');
          expect(sc.seqLen, ref['seq_len'], reason: '$key scale$i seq_len');
          expect(sc.scaleId, ref['scale_id'], reason: '$key scale$i scale_id');
          // HSE 样本（真实网格的前 8 / 末 4 个 patch）。
          final hseFirst = (ref['hse_first']! as List).cast<int>();
          final hseLast = (ref['hse_last']! as List).cast<int>();
          for (var j = 0; j < hseFirst.length; j++) {
            expect(sc.hse[j], hseFirst[j], reason: '$key scale$i hse[$j]');
          }
          final real = sc.realPatches;
          for (var j = 0; j < hseLast.length; j++) {
            expect(sc.hse[real - hseLast.length + j], hseLast[j],
                reason: '$key scale$i hse 末段[$j]');
          }
          // mask：真实 patch 全 1，补零行全 0。
          for (var p = 0; p < sc.seqLen; p++) {
            expect(sc.mask[p], p < math.min(real, sc.seqLen) ? 1 : 0,
                reason: '$key scale$i mask[$p]');
          }
          total += sc.seqLen;
          maskSum += math.min(real, sc.seqLen);
        }
        expect(total, info['total_seq'], reason: '$key total_seq');
        expect(maskSum, info['mask_sum'], reason: '$key mask_sum');
      }
    });

    test('patch 数据（含 bicubic resize）与 golden 余弦 >0.99999', () {
      if (!goldenExist()) return;
      const w = 256, h = 192;
      final golden = NnwReader.open(goldenNnW);
      try {
        for (final (key, noisy) in cases) {
          final ref = golden.tensor('$key.patches').$1;
          final (patches, hse, mask) = concatScales(musiqMultiscalePatches(
              musiqInput(busyFrame(w, h, noisy: noisy), w, h)));
          expect(patches.length, ref.length, reason: '$key patches 长度');
          final refHse = golden.tensor('$key.hse').$1;
          final refMask = golden.tensor('$key.mask').$1;
          for (var i = 0; i < hse.length; i++) {
            expect(hse[i], refHse[i].round(), reason: '$key hse[$i]');
            expect(mask[i], refMask[i].round(), reason: '$key mask[$i]');
          }
          var maxDiff = 0.0;
          for (var i = 0; i < patches.length; i++) {
            final d = (patches[i] - ref[i]).abs();
            if (d > maxDiff) maxDiff = d;
          }
          final cos = cosine(patches, ref);
          // ignore: avoid_print
          print('$key patches: cosine=$cos maxDiff=$maxDiff');
          expect(cos, greaterThan(0.99999), reason: '$key patches 余弦');
          expect(maxDiff, lessThan(1e-3), reason: '$key patches 最大绝对差');
        }
      } finally {
        golden.close();
      }
    });
  });

  group('tokenizer/embedding/分数分层对拍（需 .nnw 权重与黄金值）', () {
    test('tokenizer 16384 维输出样本余弦 >0.9999', () {
      if (!weightsExist() || !goldenExist()) return;
      const w = 256, h = 192;
      final meta =
          jsonDecode(File(goldenJson).readAsStringSync()) as Map<String, Object?>;
      final model = MusiqDart.load(musiqWeightsPath);
      final golden = NnwReader.open(goldenNnW);
      try {
        for (final (key, noisy) in cases) {
          final info =
              (meta['images'] as Map<String, Object?>)[key]! as Map<String, Object?>;
          final scales = musiqMultiscalePatches(
              musiqInput(busyFrame(w, h, noisy: noisy), w, h));
          final (patches, _, _) = concatScales(scales);
          final tok = model.tokenizerForward(
              NnTensor(patches, [patches.length ~/ 3072, 3, 32, 32]));
          final flat = MusiqDart.nhwcFlatten(tok);
          for (final i in (info['tok_indices']! as List).cast<int>()) {
            final ref = golden.tensor('$key.tok$i').$1;
            final cos = cosine(flat, ref, i * 16384, 16384);
            // ignore: avoid_print
            print('$key tok$i: cosine=$cos');
            expect(cos, greaterThan(0.9999), reason: '$key tok$i');
          }
        }
      } finally {
        golden.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('embedding 输出余弦 >0.9999 且最终分数绝对误差 ≤0.05', () {
      if (!weightsExist() || !goldenExist()) return;
      const w = 256, h = 192;
      final meta =
          jsonDecode(File(goldenJson).readAsStringSync()) as Map<String, Object?>;
      final model = MusiqDart.load(musiqWeightsPath);
      final golden = NnwReader.open(goldenNnW);
      try {
        for (final (key, noisy) in cases) {
          final info =
              (meta['images'] as Map<String, Object?>)[key]! as Map<String, Object?>;
          final scales = musiqMultiscalePatches(
              musiqInput(busyFrame(w, h, noisy: noisy), w, h));
          final (patches, hse, mask) = concatScales(scales);
          final scaleIds = Int32List(hse.length);
          var off = 0;
          for (final sc in scales) {
            for (var i = 0; i < sc.seqLen; i++) {
              scaleIds[off + i] = sc.scaleId;
            }
            off += sc.seqLen;
          }
          final emb = model.embeddingForward(model.tokenizerForward(
              NnTensor(patches, [patches.length ~/ 3072, 3, 32, 32])));
          final refEmb = golden.tensor('$key.emb').$1;
          expect(emb.data.length, refEmb.length, reason: '$key emb 长度');
          final cos = cosine(emb.data, refEmb);
          // ignore: avoid_print
          print('$key emb: cosine=$cos');
          expect(cos, greaterThan(0.9999), reason: '$key emb 余弦');

          final sw = Stopwatch()..start();
          final score = model.encoderScore(emb.data, hse, scaleIds, mask);
          final pyScore = info['score']! as double;
          final diff = (score - pyScore).abs();
          // ignore: avoid_print
          print('$key score: dart=$score python(cpu)=$pyScore absErr=$diff '
              '(encoder ${sw.elapsedMilliseconds}ms)');
          expect(diff, lessThanOrEqualTo(0.05), reason: '$key 分数');
        }
      } finally {
        golden.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('自洽性（需 .nnw 权重，无需 Python）', () {
    test('同步与池并行结果位级一致', () async {
      if (!weightsExist()) return;
      const w = 96, h = 72;
      final syncV = musiqScore(busyFrame(w, h), w, h);
      final parV = await musiqScoreParallel(busyFrame(w, h), w, h, workers: 4);
      expect(parV, syncV);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('同一输入重复评分一致', () {
      if (!weightsExist()) return;
      const w = 96, h = 72;
      final a = busyFrame(w, h);
      expect(musiqScore(a, w, h), musiqScore(a, w, h));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('256×192 同步评分耗时（打印，仅作性能参考）', () {
      if (!weightsExist()) return;
      const w = 256, h = 192;
      final sw = Stopwatch()..start();
      final v = musiqScore(busyFrame(w, h), w, h);
      // ignore: avoid_print
      print('MUSIQ 256x192 同步评分: ${sw.elapsedMilliseconds}ms, score=$v');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('与 Python 参考对拍（需 eval_venv）', () {
    /// 调 iqa_bridge.py 一次性模式取参考分（stdout 里混入 torch 的
    /// 提示文本，取首个以 '{' 开头的 JSON 行）。
    Future<double> pyRef(String aPath) async {
      final res = await Process.run(
          pyIqaPythonPath,
          [pyIqaBridgePath, '--metric', 'musiq', '--a', aPath],
          workingDirectory: Directory.current.path);
      for (final line in const LineSplitter().convert(res.stdout as String)) {
        final t = line.trimLeft();
        if (!t.startsWith('{')) continue;
        final obj = jsonDecode(t) as Map<String, Object?>;
        if (obj['ok'] == true) {
          return (obj['score'] as num).toDouble();
        }
        throw StateError('桥接一次性模式失败（musiq）: $t');
      }
      throw StateError('桥接一次性模式无 JSON 应答（musiq）: '
          'exit=${res.exitCode} stdout=${res.stdout} stderr=${res.stderr}');
    }

    void expectClose(double dartV, double pyV, String what) {
      final diff = (dartV - pyV).abs();
      // ignore: avoid_print
      print('$what: dart=$dartV python=$pyV absErr=$diff');
      expect(diff, lessThanOrEqualTo(0.05), reason: what);
    }

    test('MUSIQ 256×192 busyFrame 干净图', () async {
      if (!PyIqaWorker.available || !weightsExist()) return;
      const w = 256, h = 192;
      final aPath = await pyIqaWriteTempPng(busyFrame(w, h), w, h);
      final pyV = await pyRef(aPath);
      final dartV = await musiqScoreParallel(busyFrame(w, h), w, h);
      expectClose(dartV, pyV, 'MUSIQ 256x192 clean');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('MUSIQ 256×192 busyFrame 加噪图', () async {
      if (!PyIqaWorker.available || !weightsExist()) return;
      const w = 256, h = 192;
      final bPath =
          await pyIqaWriteTempPng(busyFrame(w, h, noisy: true), w, h);
      final pyV = await pyRef(bPath);
      final dartV =
          await musiqScoreParallel(busyFrame(w, h, noisy: true), w, h);
      expectClose(dartV, pyV, 'MUSIQ 256x192 noisy');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
