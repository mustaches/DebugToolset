/// 常驻流水线 worker（独立 isolate）与 UI 侧客户端。
///
/// 播放中每一帧都要过 ISP 流水线：若像 compute() 那样每帧新起
/// isolate（spawn + debug 下 JIT 冷启动，Windows 上可阻塞 UI 事件
/// 循环上百毫秒）会直接造成播放丢帧。常驻 worker 只起一次、JIT 只
/// 热身一次，之后每帧只是端口消息往返（结果经 TransferableTypedData
/// 零拷贝送回）。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'pipeline_runner.dart' show runChainFrame;

/// 常驻 isolate 的流水线执行客户端。非线程安全：调用方自行串行化
/// （播放循环一次只生产一帧）。
class PipelineFrameRunner {
  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _port;
  StreamSubscription<Object?>? _sub;
  final Map<int, Completer<Uint8List>> _pending = {};
  var _reqId = 0;
  Completer<void>? _startCompleter;

  /// 执行一帧流水线（[chain] 见 pipeline_runner），返回 RGBA8888。
  /// [sourceRgba] 为视频源流帧（随消息送入 worker）。
  /// 执行失败抛 [StateError]。
  Future<Uint8List> run(List<Map<String, Object?>> chain, int frameIndex,
      {Uint8List? sourceRgba,
      int? sourceWidth,
      int? sourceHeight}) async {
    await _ensureStarted();
    final worker = _worker;
    if (worker == null) {
      throw StateError('流水线 worker 启动失败');
    }
    final id = _reqId++;
    final c = Completer<Uint8List>();
    _pending[id] = c;
    final payload = sourceRgba != null
        ? TransferableTypedData.fromList([sourceRgba])
        : null;
    worker.send([id, chain, frameIndex, payload, sourceWidth, sourceHeight]);
    return c.future;
  }

  Future<void> _ensureStarted() async {
    if (_worker != null) return;
    if (_startCompleter != null) {
      await _startCompleter!.future;
      return;
    }
    final ready = Completer<void>();
    _startCompleter = ready;
    final port = ReceivePort();
    _port = port;
    _sub = port.listen((msg) {
      if (msg is SendPort) {
        _worker = msg;
        ready.complete();
      } else if (msg is List) {
        final id = msg[0] as int;
        final c = _pending.remove(id);
        if (c == null) return;
        if (msg.length > 1 && msg[1] == 'error') {
          c.completeError(StateError(msg[2]?.toString() ?? '流水线执行失败'));
        } else {
          c.complete((msg[1] as TransferableTypedData).materialize().asUint8List());
        }
      }
    });
    _isolate = await Isolate.spawn(_pipelineWorkerMain, port.sendPort);
    await ready.future;
  }

  /// 结束 worker isolate（挂起的请求以错误收尾）。
  void dispose() {
    _isolate?.kill();
    _isolate = null;
    _sub?.cancel();
    _sub = null;
    _port?.close();
    _port = null;
    _worker = null;
    _startCompleter = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('流水线 worker 已终止'));
      }
    }
    _pending.clear();
  }
}

/// 多 CPU 核心 Isolate 流水线并行执行池。
///
/// 当流程图中存在多路预览（如 5 路 YUV/RGB 独立预览链）时，
/// 将各节点的算子链并行分配到线程池中多个独立的 Isolate Worker 上
/// 同时计算，充分利用多核 CPU 性能，解决单核串行排队造成的帧率卡顿。
class PipelineWorkerPool {
  final List<PipelineFrameRunner> _workers;

  PipelineWorkerPool({int count = 4})
      : _workers = List.generate(
            math.max(1, count), (_) => PipelineFrameRunner());

  /// 并行执行多条预览链，返回 `Map<String, Uint8List>`。
  Future<Map<String, Uint8List>> runParallel(
    Map<String, List<Map<String, Object?>>> validChains,
    int frameIndex, {
    Uint8List? sourceRgba,
    int? sourceWidth,
    int? sourceHeight,
  }) async {
    final results = <String, Uint8List>{};
    final entries = validChains.entries.toList();
    await Future.wait([
      for (var i = 0; i < entries.length; i++)
        () async {
          final nodeId = entries[i].key;
          final chain = entries[i].value;
          final worker = _workers[i % _workers.length];
          final rgba = await worker.run(
            chain,
            frameIndex,
            sourceRgba: sourceRgba,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
          );
          results[nodeId] = rgba;
        }(),
    ]);
    return results;
  }

  /// 释放线程池中的所有 worker isolate。
  void dispose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
  }
}

/// worker 入口：逐条处理 [id, chain, frameIndex, sourceRgba, 宽, 高]，
/// 回 [id, TransferableTypedData(rgba)]，失败回 [id, 'error', 消息]。
@pragma('vm:entry-point')
Future<void> _pipelineWorkerMain(SendPort ui) async {
  final port = ReceivePort();
  ui.send(port.sendPort);
  await for (final msg in port) {
    final req = msg as List;
    final id = req[0] as int;
    try {
      final rawSource = req[3];
      final Uint8List? sourceRgba = rawSource is TransferableTypedData
          ? rawSource.materialize().asUint8List()
          : rawSource as Uint8List?;
      final rgba = await runChainFrame(
          (req[1] as List).cast<Map<String, Object?>>(), req[2] as int,
          sourceRgba: sourceRgba,
          sourceWidth: req[4] as int?,
          sourceHeight: req[5] as int?);
      ui.send([id, TransferableTypedData.fromList([rgba])]);
    } catch (e, st) {
      ui.send([id, 'error', '$e\n$st']);
    }
  }
}
