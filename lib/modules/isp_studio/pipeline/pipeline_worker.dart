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
  final Map<int, Completer<(Uint8List, Map<String, Uint8List>)>> _pending = {};
  var _reqId = 0;
  Completer<void>? _startCompleter;

  /// 执行一帧流水线（[chain] 见 pipeline_runner），返回
  /// (RGBA8888, 被覆盖链汇点的显示图)。[sourceRgba] 为视频源流帧
  /// （随消息送入 worker）；[sourceYuv] 为 yuv444p 平面流帧（YUV 直出
  /// 流程，与 [sourceRgba] 二选一）。[captureSinks] 为本链顺带捕获的
  /// 被覆盖链汇点 nodeId（前缀覆盖去重，见 runParallel）。
  /// 执行失败抛 [StateError]。
  Future<(Uint8List, Map<String, Uint8List>)> run(
      List<Map<String, Object?>> chain, int frameIndex,
      {Uint8List? sourceRgba,
      Uint8List? sourceYuv,
      int? sourceWidth,
      int? sourceHeight,
      Set<String>? captureSinks}) async {
    await _ensureStarted();
    final worker = _worker;
    if (worker == null) {
      throw StateError('流水线 worker 启动失败');
    }
    final id = _reqId++;
    final c = Completer<(Uint8List, Map<String, Uint8List>)>();
    _pending[id] = c;
    final source = sourceRgba ?? sourceYuv;
    final payload =
        source != null ? TransferableTypedData.fromList([source]) : null;
    worker.send([
      id,
      chain,
      frameIndex,
      payload,
      sourceWidth,
      sourceHeight,
      sourceYuv != null && sourceRgba == null ? 'yuv444p' : 'rgba',
      captureSinks?.toList(),
    ]);
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
          final rgba =
              (msg[1] as TransferableTypedData).materialize().asUint8List();
          final caps = <String, Uint8List>{};
          if (msg.length > 3) {
            final ids = (msg[2] as List).cast<String>();
            final datas = msg[3] as List;
            for (var k = 0; k < ids.length; k++) {
              caps[ids[k]] = (datas[k] as TransferableTypedData)
                  .materialize()
                  .asUint8List();
            }
          }
          c.complete((rgba, caps));
        }
      }
    });
    _isolate = await Isolate.spawn(_pipelineWorkerMain, port.sendPort);
    await ready.future;
  }

  /// 预热：提前 spawn worker isolate（播放开始时与流解码初始化并行，
  /// 避免首帧生产承担 isolate 启动开销）。
  Future<void> warmup() => _ensureStarted();

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
  ///
  /// 前缀覆盖去重：链 A 的节点序列是链 B 的真前缀时（多路 YUV/RGB
  /// 独立预览的典型形态——几条短预览链是长汇链的前缀），A 不单独
  /// 执行，由 B 在执行中顺带捕获 A 汇点的显示图，省掉 A 的整条重复
  /// 计算。捕获不到（不支持的形式）时回退单独执行 A。
  Future<Map<String, Uint8List>> runParallel(
    Map<String, List<Map<String, Object?>>> validChains,
    int frameIndex, {
    Uint8List? sourceRgba,
    Uint8List? sourceYuv,
    int? sourceWidth,
    int? sourceHeight,
  }) async {
    final results = <String, Uint8List>{};
    final entries = validChains.entries.toList();

    // 覆盖关系：按链长降序，长链执行并覆盖其真前缀短链。
    final order = [for (var i = 0; i < entries.length; i++) i]
      ..sort((a, b) => entries[b].value.length.compareTo(entries[a].value.length));
    final coveredBy = <int, int>{}; // 被覆盖索引 → 覆盖者索引
    final captureOf = <int, Set<String>>{}; // 覆盖者索引 → 捕获的汇点 nodeId
    for (final j in order) {
      if (coveredBy.containsKey(j)) continue;
      for (final i in order) {
        if (i == j || coveredBy.containsKey(i)) continue;
        if (!_isPrefixOf(entries[i].value, entries[j].value)) continue;
        if (!_captureSafe(entries[i].value, entries[j].value)) continue;
        coveredBy[i] = j;
        (captureOf[j] ??= {}).add(entries[i].value.last['nodeId'] as String);
      }
    }

    var workerIdx = 0;
    await Future.wait([
      for (final j in order)
        if (!coveredBy.containsKey(j))
          () async {
            final worker = _workers[workerIdx++ % _workers.length];
            final (rgba, captures) = await worker.run(
              entries[j].value,
              frameIndex,
              sourceRgba: sourceRgba,
              sourceYuv: sourceYuv,
              sourceWidth: sourceWidth,
              sourceHeight: sourceHeight,
              captureSinks: captureOf[j],
            );
            results[entries[j].key] = rgba;
            results.addAll(captures);
          }(),
    ]);
    // 回退：捕获落空的被覆盖链单独执行。
    for (final i in coveredBy.keys) {
      if (results.containsKey(entries[i].key)) continue;
      final worker = _workers[workerIdx++ % _workers.length];
      final (rgba, _) = await worker.run(
        entries[i].value,
        frameIndex,
        sourceRgba: sourceRgba,
        sourceYuv: sourceYuv,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
      );
      results[entries[i].key] = rgba;
    }
    return results;
  }

  /// a 的 nodeId 序列是否为 b 的真前缀。
  static bool _isPrefixOf(
      List<Map<String, Object?>> a, List<Map<String, Object?>> b) {
    if (a.length >= b.length) return false;
    for (var k = 0; k < a.length; k++) {
      if (a[k]['nodeId'] != b[k]['nodeId']) return false;
    }
    return true;
  }

  /// 捕获安全性：mono 汇点捕获的是分路平面（不可变副本），恒安全；
  /// 透传汇点捕获的是 frame 引用，b 中被覆盖汇点之后不能有就地改写
  /// frame.data 的算子（黑电平/白平衡/CCM 等）。
  static bool _captureSafe(
      List<Map<String, Object?>> a, List<Map<String, Object?>> b) {
    final sinkInputs = a.last['inputs'] as Map<String, Object?>?;
    if (sinkInputs != null && sinkInputs.containsKey('in_mono')) return true;
    const passthroughOk = {
      'preview', 'histogram', 'waveform', 'vectorscope',
      'image_output', 'video_output',
      'audio_level', 'audio_waveform', 'audio_eq',
      'rgb_splitter', 'yuv_splitter', 'hsl_splitter',
      'rgb_combiner', 'yuv_combiner', 'hsl_combiner',
    };
    for (var k = a.length; k < b.length; k++) {
      if (!passthroughOk.contains(b[k]['typeId'])) return false;
    }
    return true;
  }

  /// 预热全部 worker（与视频流/音频初始化并行，藏掉 isolate 启动开销）。
  void warmup() {
    for (final worker in _workers) {
      unawaited(worker.warmup());
    }
  }

  /// 释放线程池中的所有 worker isolate。
  void dispose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
  }
}

/// worker 入口：逐条处理 [id, chain, frameIndex, source, 宽, 高, 格式,
/// 捕获汇点列表]，回 [id, TransferableTypedData(rgba)]（有捕获时追加
/// [捕获 nodeId 列表, 捕获数据 TTD 列表]），失败回 [id, 'error', 消息]。
/// 格式为 'yuv444p' 时 source 是平面 YUV 帧（注入 sourceYuv），
/// 否则是 RGBA8888 帧（注入 sourceRgba）。
@pragma('vm:entry-point')
Future<void> _pipelineWorkerMain(SendPort ui) async {
  final port = ReceivePort();
  ui.send(port.sendPort);
  await for (final msg in port) {
    final req = msg as List;
    final id = req[0] as int;
    try {
      final rawSource = req[3];
      final Uint8List? source = rawSource is TransferableTypedData
          ? rawSource.materialize().asUint8List()
          : rawSource as Uint8List?;
      final isYuv = req.length > 6 && req[6] == 'yuv444p';
      final captureSinks =
          req.length > 7 ? (req[7] as List?)?.cast<String>().toSet() : null;
      final captured = <String, Uint8List>{};
      final rgba = await runChainFrame(
          (req[1] as List).cast<Map<String, Object?>>(), req[2] as int,
          sourceRgba: isYuv ? null : source,
          sourceYuv: isYuv ? source : null,
          sourceWidth: req[4] as int?,
          sourceHeight: req[5] as int?,
          captureSinks: captureSinks,
          capturedRgba: captured);
      if (captured.isEmpty) {
        ui.send([id, TransferableTypedData.fromList([rgba])]);
      } else {
        ui.send([
          id,
          TransferableTypedData.fromList([rgba]),
          captured.keys.toList(),
          [
            for (final v in captured.values)
              TransferableTypedData.fromList([v])
          ],
        ]);
      }
    } catch (e, st) {
      ui.send([id, 'error', '$e\n$st']);
    }
  }
}
