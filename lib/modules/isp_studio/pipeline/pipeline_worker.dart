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
  var _started = false;

  /// 执行一帧流水线（[chain] 见 pipeline_runner），返回 RGBA8888。
  /// [sourceRgba] 为视频源流帧（随消息拷贝进 worker，原缓冲不受影响）。
  /// 执行失败抛 [StateError]。
  Future<Uint8List> run(List<Map<String, Object?>> chain, int frameIndex,
      {Uint8List? sourceRgba, int? sourceWidth, int? sourceHeight}) async {
    await _ensureStarted();
    final id = _reqId++;
    final c = Completer<Uint8List>();
    _pending[id] = c;
    _worker!.send([id, chain, frameIndex, sourceRgba, sourceWidth, sourceHeight]);
    return c.future;
  }

  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    final port = ReceivePort();
    final ready = Completer<void>();
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
    _started = false;
    for (final c in _pending.values) {
      c.completeError(StateError('流水线 worker 已终止'));
    }
    _pending.clear();
  }
}

/// worker 入口：逐条处理 [id, chain, frameIndex, sourceRgba, 宽, 高]，
/// 回 [id, TransferableTypedData(rgba)]，失败回 [id, 'error', 消息]。
Future<void> _pipelineWorkerMain(SendPort ui) async {
  final port = ReceivePort();
  ui.send(port.sendPort);
  await for (final msg in port) {
    final req = msg as List;
    final id = req[0] as int;
    try {
      final rgba = await runChainFrame(
          (req[1] as List).cast<Map<String, Object?>>(), req[2] as int,
          sourceRgba: req[3] as Uint8List?,
          sourceWidth: req[4] as int?,
          sourceHeight: req[5] as int?);
      ui.send([id, TransferableTypedData.fromList([rgba])]);
    } catch (e) {
      ui.send([id, 'error', e.toString()]);
    }
  }
}
