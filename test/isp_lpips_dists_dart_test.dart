// LPIPS / DISTS 进程内 Dart 实现（metrics/lpips_dart.dart、
// metrics/dists_dart.dart）的测试：自洽性（自比对、同步与池并行
// 位级一致）与（Python 环境可用时的）端到端对拍。
//
// 对拍经 tools/iqa/iqa_bridge.py 一次性模式取 Python 参考分
// （scratch/eval_venv，torch/lpips/pyiqa），相对误差 ≤1e-3。
// Python 环境或 .nnw 权重缺失时自动跳过（同 test/isp_pyiqa_test.dart
// 的跳过模式）。busyFrame 图案与 test/isp_pyiqa_test.dart 相同。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/dists_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';

void main() {
  /// 高纹理彩色测试帧（图案同 test/isp_pyiqa_test.dart 的 busyFrame，
  /// 尺寸参数化）。
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

  bool weightsExist() =>
      File(lpipsVggWeightsPath).existsSync() &&
      File(lpipsLinWeightsPath).existsSync() &&
      File(distsVggWeightsPath).existsSync() &&
      File(distsWeightsPath).existsSync();

  group('自洽性（需 .nnw 权重，无需 Python）', () {
    test('自比对分数≈0', () {
      if (!weightsExist()) return;
      const w = 96, h = 72;
      final a = busyFrame(w, h);
      expect(lpipsScore(a, a, w, h).abs(), lessThan(1e-6));
      expect(distsScore(a, a, w, h).abs(), lessThan(1e-5));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('同步与池并行结果位级一致', () async {
      if (!weightsExist()) return;
      const w = 96, h = 72;
      final a = busyFrame(w, h);
      final b = busyFrame(w, h, noisy: true);
      expect(await lpipsScoreParallel(a, b, w, h, workers: 4),
          lpipsScore(a, b, w, h));
      expect(await distsScoreParallel(a, b, w, h, workers: 4),
          distsScore(a, b, w, h));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('与 Python 参考对拍（需 eval_venv）', () {
    /// 调 iqa_bridge.py 一次性模式取参考分（stdout 里混入 torch/lpips
    /// 的提示文本，取首个以 '{' 开头的 JSON 行）。
    Future<double> pyRef(String metric, String aPath, String bPath) async {
      final res = await Process.run(
          pyIqaPythonPath,
          [pyIqaBridgePath, '--metric', metric, '--a', aPath, '--b', bPath],
          workingDirectory: Directory.current.path);
      for (final line in const LineSplitter().convert(res.stdout as String)) {
        final t = line.trimLeft();
        if (!t.startsWith('{')) continue;
        final obj = jsonDecode(t) as Map<String, Object?>;
        if (obj['ok'] == true) {
          return (obj['score'] as num).toDouble();
        }
        throw StateError('桥接一次性模式失败（$metric）: $t');
      }
      throw StateError('桥接一次性模式无 JSON 应答（$metric）: '
          'exit=${res.exitCode} stdout=${res.stdout} stderr=${res.stderr}');
    }

    void expectClose(double dartV, double pyV, String what) {
      final rel = (dartV - pyV).abs() / pyV.abs();
      // ignore: avoid_print
      print('$what: dart=$dartV python=$pyV relErr=$rel');
      expect(rel, lessThanOrEqualTo(1e-3), reason: what);
    }

    test('LPIPS 256×192 busyFrame 对', () async {
      if (!PyIqaWorker.available || !weightsExist()) return;
      const w = 256, h = 192;
      final aPath = await pyIqaWriteTempPng(busyFrame(w, h), w, h);
      final bPath =
          await pyIqaWriteTempPng(busyFrame(w, h, noisy: true), w, h);
      final pyV = await pyRef('lpips', aPath, bPath);
      final dartV = await lpipsScoreParallel(
          busyFrame(w, h), busyFrame(w, h, noisy: true), w, h);
      expectClose(dartV, pyV, 'LPIPS 256x192');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('DISTS 256×192 busyFrame 对', () async {
      if (!PyIqaWorker.available || !weightsExist()) return;
      const w = 256, h = 192;
      final aPath = await pyIqaWriteTempPng(busyFrame(w, h), w, h);
      final bPath =
          await pyIqaWriteTempPng(busyFrame(w, h, noisy: true), w, h);
      final pyV = await pyRef('dists', aPath, bPath);
      final dartV = await distsScoreParallel(
          busyFrame(w, h), busyFrame(w, h, noisy: true), w, h);
      expectClose(dartV, pyV, 'DISTS 256x192');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('奇数尺寸 301×199（验证 L2pooling 奇数尺寸语义）', () async {
      if (!PyIqaWorker.available || !weightsExist()) return;
      const w = 301, h = 199;
      final aPath = await pyIqaWriteTempPng(busyFrame(w, h), w, h);
      final bPath =
          await pyIqaWriteTempPng(busyFrame(w, h, noisy: true), w, h);
      final lpipsPy = await pyRef('lpips', aPath, bPath);
      final distsPy = await pyRef('dists', aPath, bPath);
      final a = busyFrame(w, h);
      final b = busyFrame(w, h, noisy: true);
      expectClose(
          await lpipsScoreParallel(a, b, w, h), lpipsPy, 'LPIPS 301x199');
      expectClose(
          await distsScoreParallel(a, b, w, h), distsPy, 'DISTS 301x199');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
