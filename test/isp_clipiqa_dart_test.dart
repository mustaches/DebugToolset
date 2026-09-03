// CLIPIQA 进程内 Dart 实现（metrics/clip_rn50_dart.dart、
// metrics/clipiqa_dart.dart）的测试：RN50 特征黄金值对拍、自洽性
// （同步与池并行位级一致）与（Python 环境可用时的）端到端对拍。
//
// 特征黄金值由 tools/iqa/dump_clipiqa_feats.py 生成
// （test/golden/clipiqa_feats_golden.{nnw,json}，busyFrame 256×192
// 干净/加噪，CPU fp32）；端到端对拍经 tools/iqa/iqa_bridge.py 一次性
// 模式取 Python 参考分，相对误差 ≤1e-3。Python 环境、.nnw 权重或
// 黄金值缺失时自动跳过（同 test/isp_lpips_dists_dart_test.dart 的
// 跳过模式）。busyFrame 图案与 test/isp_pyiqa_test.dart 相同。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clip_rn50_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clipiqa_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nnw_reader.dart';
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

  bool weightsExist() => File(clipiqaWeightsPath).existsSync();

  const goldenNnW = 'test/golden/clipiqa_feats_golden.nnw';
  const goldenJson = 'test/golden/clipiqa_feats_golden.json';
  bool goldenExist() =>
      File(goldenNnW).existsSync() && File(goldenJson).existsSync();

  /// 余弦相似度（a、b 等长）。
  double cosine(Float32List a, Float32List b) {
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  group('RN50 特征黄金值对拍（需 .nnw 权重与黄金值，无需 Python）', () {
    test('busyFrame 256×192 干净/加噪特征余弦相似度 >0.99999', () {
      if (!weightsExist() || !goldenExist()) return;
      const w = 256, h = 192;
      final rn50 = ClipRn50Dart.load(clipiqaWeightsPath);
      final golden = NnwReader.open(goldenNnW);
      try {
        for (final (key, noisy) in [('clean.feats', false), ('noisy.feats', true)]) {
          final ref = golden.tensor(key).$1;
          expect(ref.length, 1024, reason: '$key 应为 1024 维');
          final feat =
              rn50.forward(clipiqaInput(busyFrame(w, h, noisy: noisy), w, h));
          final cos = cosine(feat, ref);
          // ignore: avoid_print
          print('$key: cosine=$cos');
          expect(cos, greaterThan(0.99999), reason: key);
        }
      } finally {
        golden.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('Dart 分数与黄金值内 Python 分数相对误差 ≤1e-3', () {
      if (!weightsExist() || !goldenExist()) return;
      const w = 256, h = 192;
      final meta =
          jsonDecode(File(goldenJson).readAsStringSync()) as Map<String, Object?>;
      final params = ClipIqaParams.load(clipiqaWeightsPath);
      final rn50 = ClipRn50Dart.load(clipiqaWeightsPath);
      for (final (key, noisy) in [('clean.feats', false), ('noisy.feats', true)]) {
        final pyScore =
            ((meta['images'] as Map<String, Object?>)[key]! as Map<String, Object?>)['score']
                as double;
        final feat =
            rn50.forward(clipiqaInput(busyFrame(w, h, noisy: noisy), w, h));
        final dartScore = clipiqaScoreFromFeat(feat, params);
        final rel = (dartScore - pyScore).abs() / pyScore.abs();
        // ignore: avoid_print
        print('$key: dart=$dartScore python(cpu)=$pyScore relErr=$rel');
        expect(rel, lessThanOrEqualTo(1e-3), reason: key);
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('自洽性（需 .nnw 权重，无需 Python）', () {
    test('同步与池并行结果位级一致', () async {
      if (!weightsExist()) return;
      const w = 96, h = 72;
      final syncV = clipiqaScore(busyFrame(w, h), w, h);
      final parV =
          await clipiqaScoreParallel(busyFrame(w, h), w, h, workers: 4);
      expect(parV, syncV);
      expect(syncV, inInclusiveRange(0.0, 1.0));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('同一输入重复评分一致', () {
      if (!weightsExist()) return;
      const w = 96, h = 72;
      final a = busyFrame(w, h);
      expect(clipiqaScore(a, w, h), clipiqaScore(a, w, h));
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('与 Python 参考对拍（需 eval_venv）', () {
    /// 调 iqa_bridge.py 一次性模式取参考分（stdout 里混入 torch 的
    /// 提示文本，取首个以 '{' 开头的 JSON 行）。
    Future<double> pyRef(String aPath) async {
      final res = await Process.run(
          pyIqaPythonPath,
          [pyIqaBridgePath, '--metric', 'clipiqa', '--a', aPath],
          workingDirectory: Directory.current.path);
      for (final line in const LineSplitter().convert(res.stdout as String)) {
        final t = line.trimLeft();
        if (!t.startsWith('{')) continue;
        final obj = jsonDecode(t) as Map<String, Object?>;
        if (obj['ok'] == true) {
          return (obj['score'] as num).toDouble();
        }
        throw StateError('桥接一次性模式失败（clipiqa）: $t');
      }
      throw StateError('桥接一次性模式无 JSON 应答（clipiqa）: '
          'exit=${res.exitCode} stdout=${res.stdout} stderr=${res.stderr}');
    }

    void expectClose(double dartV, double pyV, String what) {
      final rel = (dartV - pyV).abs() / pyV.abs();
      // ignore: avoid_print
      print('$what: dart=$dartV python=$pyV relErr=$rel');
      expect(rel, lessThanOrEqualTo(1e-3), reason: what);
    }

    test('CLIPIQA 256×192 busyFrame 干净图', () async {
      if (!PyIqaWorker.available || !weightsExist()) return;
      const w = 256, h = 192;
      final aPath = await pyIqaWriteTempPng(busyFrame(w, h), w, h);
      final pyV = await pyRef(aPath);
      final dartV = await clipiqaScoreParallel(busyFrame(w, h), w, h);
      expectClose(dartV, pyV, 'CLIPIQA 256x192 clean');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('CLIPIQA 256×192 busyFrame 加噪图', () async {
      if (!PyIqaWorker.available || !weightsExist()) return;
      const w = 256, h = 192;
      final bPath =
          await pyIqaWriteTempPng(busyFrame(w, h, noisy: true), w, h);
      final pyV = await pyRef(bPath);
      final dartV =
          await clipiqaScoreParallel(busyFrame(w, h, noisy: true), w, h);
      expectClose(dartV, pyV, 'CLIPIQA 256x192 noisy');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
