/// 拆解 analyzeVectorscopeParallel 各阶段耗时（带内分析 / 端口收发 / 合并 / 渲染）。
import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart'
    show instrumentAnalyze;

Uint8List makeFrame(int w, int h, int seed, {int noise = 24}) {
  final rnd = math.Random(seed);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      out[i] = (x * 255 ~/ w + rnd.nextInt(noise)) & 0xFF;
      out[i + 1] = (y * 255 ~/ h + rnd.nextInt(noise)) & 0xFF;
      out[i + 2] = ((x + y) * 128 ~/ (w + h) + rnd.nextInt(noise)) & 0xFF;
      out[i + 3] = 255;
    }
  }
  return out;
}

void _worker(SendPort ui) {
  final port = ReceivePort();
  ui.send(port.sendPort);
  port.listen((msg) {
    final req = msg as List;
    final id = req[0] as int;
    if (req[4] == 'noop') {
      ui.send([req[0], null, 0]);
      return;
    }
    if (req[4] == 'render') {
      final sw = Stopwatch()..start();
      final list = (req[1] as List).cast<Uint8List>();
      final counts = Uint32List.view(list.first.buffer,
          list.first.offsetInBytes, list.first.lengthInBytes ~/ 4);
      for (var i = 1; i < list.length; i++) {
        final src = Uint32List.view(list[i].buffer, list[i].offsetInBytes,
            list[i].lengthInBytes ~/ 4);
        for (var j = 0; j < counts.length; j++) {
          counts[j] += src[j];
        }
      }
      final bmp = intensityRgba(counts, 512, 512, 70, 235, 70);
      ui.send([id, bmp, sw.elapsedMicroseconds]);
      return;
    }
    final sw = Stopwatch()..start();
    final counts = req[4] == 'band'
        ? vectorscope(req[1] as Uint8List, seedFirstOnly: true)
        : vectorscope(req[1] as Uint8List);
    final us = sw.elapsedMicroseconds;
    if (req[5] == true) {
      ui.send([id, counts, us]); // 回计数表（测端口开销）
    } else {
      ui.send([id, null, us]); // 只回耗时
    }
  });
}

Future<void> main(List<String> args) async {
  const w = 427, h = 240;
  final frame = makeFrame(w, h, 2, noise: int.parse(args.isEmpty ? "24" : args[0]));
  const n = 8;

  // 起 n 个 worker。
  final workers = <SendPort>[];
  final ports = <ReceivePort>[];
  final pending = <int, Completer<List>>{};
  for (var i = 0; i < n; i++) {
    final port = ReceivePort();
    final ready = Completer<SendPort>();
    port.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else {
        pending[(msg as List)[0] as int]!.complete(msg);
      }
    });
    await Isolate.spawn(_worker, port.sendPort);
    workers.add(await ready.future);
    ports.add(port);
  }

  final rowsPer = h ~/ n;
  Future<List<int>> run(bool returnCounts) async {
    final parts = <Future<List>>[];
    for (var i = 0; i < n; i++) {
      final y0 = i * rowsPer;
      final y1 = i == n - 1 ? h : y0 + rowsPer;
      final c = Completer<List>();
      pending[i] = c;
      if (i == 0) {
        workers[0].send([i, Uint8List.sublistView(frame, 0, y1 * w * 4),
            w, y1, 'full', returnCounts]);
      } else {
        workers[i].send([i,
            Uint8List.sublistView(frame, y0 * w * 4 - 4, y1 * w * 4),
            w, y1 - y0 + 1, 'band', returnCounts]);
      }
      parts.add(c.future);
    }
    final res = await Future.wait(parts);
    return [for (final r in res) r[2] as int];
  }

  for (var i = 0; i < 5; i++) {
    await run(false);
  }
  // 不回计数表：纯分析+小消息。
  var sw = Stopwatch()..start();
  List<int> us = [];
  for (var i = 0; i < 30; i++) {
    us = await run(false);
  }
  sw.stop();
  print('并行分析(不回表): ${(sw.elapsedMicroseconds / 30 / 1000).toStringAsFixed(2)} ms/帧, '
      'worker内分析各带: ${us.map((e) => (e / 1000).toStringAsFixed(1)).join(", ")} ms');

  // 回计数表：加端口拷贝。
  sw = Stopwatch()..start();
  for (var i = 0; i < 30; i++) {
    await run(true);
  }
  sw.stop();
  print('并行分析(回8张1MB表): ${(sw.elapsedMicroseconds / 30 / 1000).toStringAsFixed(2)} ms/帧');

  // 完整流程：带分析(回表) + render 请求(发表下行+渲染+bmp上行)。
  Future<void> runFull() async {
    final parts = <Future<List>>[];
    for (var i = 0; i < n; i++) {
      final y0 = i * rowsPer;
      final y1 = i == n - 1 ? h : y0 + rowsPer;
      final c = Completer<List>();
      pending[1000 + i] = c;
      if (i == 0) {
        workers[0].send([1000 + i, Uint8List.sublistView(frame, 0, y1 * w * 4),
            w, y1, 'full', true]);
      } else {
        workers[i].send([1000 + i,
            Uint8List.sublistView(frame, y0 * w * 4 - 4, y1 * w * 4),
            w, y1 - y0 + 1, 'band', true]);
      }
      parts.add(c.future);
    }
    final res = await Future.wait(parts);
    final countsList = <Uint8List>[
      for (final r in res)
        (r[1] as Uint32List).buffer.asUint8List(
            (r[1] as Uint32List).offsetInBytes,
            (r[1] as Uint32List).lengthInBytes),
    ];
    final c = Completer<List>();
    pending[2000] = c;
    workers[0].send([2000, countsList, 512, 512, 'render', false]);
    await c.future;
  }

  for (var i = 0; i < 5; i++) {
    await runFull();
  }
  sw = Stopwatch()..start();
  for (var i = 0; i < 30; i++) {
    await runFull();
  }
  sw.stop();
  print('完整并行流程(分析+回表+发表+渲染+bmp): '
      '${(sw.elapsedMicroseconds / 30 / 1000).toStringAsFixed(2)} ms/帧');

  // 空转探针：8MB 列表下行 + 立即返回。
  final probe = [for (var i = 0; i < n; i++) Uint8List(512 * 512 * 4)];
  Future<void> runNoop() async {
    final c = Completer<List>();
    pending[3000] = c;
    workers[1].send([3000, probe, 512, 512, 'noop', false]);
    await c.future;
  }
  for (var i = 0; i < 5; i++) {
    await runNoop();
  }
  sw = Stopwatch()..start();
  for (var i = 0; i < 30; i++) {
    await runNoop();
  }
  sw.stop();
  print('空转探针(8MB下行): ${(sw.elapsedMicroseconds / 30 / 1000).toStringAsFixed(2)} ms');

  // 合并耗时。
  final counts = [for (var i = 0; i < n; i++) Uint32List(512 * 512)];
  sw = Stopwatch()..start();
  for (var i = 0; i < 30; i++) {
    mergeInstrumentResults([for (final c in counts) {'counts': c}]);
  }
  sw.stop();
  print('合并(8张表): ${(sw.elapsedMicroseconds / 30 / 1000).toStringAsFixed(2)} ms');

  // 渲染耗时。
  sw = Stopwatch()..start();
  for (var i = 0; i < 30; i++) {
    intensityRgba(counts[0], 512, 512, 70, 235, 70);
  }
  sw.stop();
  print('渲染bmp: ${(sw.elapsedMicroseconds / 30 / 1000).toStringAsFixed(2)} ms');

  // 单趟整帧参考。
  sw = Stopwatch()..start();
  for (var i = 0; i < 10; i++) {
    instrumentAnalyze('vectorscope', frame, w, h);
  }
  sw.stop();
  print('单worker整帧参考: ${(sw.elapsedMicroseconds / 10 / 1000).toStringAsFixed(2)} ms');

  for (final p in ports) {
    p.close();
  }
}
