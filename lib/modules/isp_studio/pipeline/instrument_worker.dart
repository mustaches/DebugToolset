/// 常驻仪器分析 worker（独立 isolate）与 UI 侧客户端。
///
/// 播放中仪器刷新很频繁：每次都用 compute() 新起 isolate 的开销
/// （spawn + debug 下 JIT 冷启动，Windows 上可阻塞 UI 事件循环上百
/// 毫秒）会直接造成播放丢帧。常驻 worker 只起一次、JIT 只热身一次，
/// 之后每次分析只是端口消息往返。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'pipeline_runner.dart' show instrumentAnalyze;

/// 常驻 isolate 的仪器分析客户端。非线程安全：调用方自行串行化
/// （IspStudioState 的 _instrumentBusy 闸保证一次只跑一批）。
class InstrumentAnalyzer {
  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _port;
  StreamSubscription<Object?>? _sub;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  var _reqId = 0;
  var _started = false;

  /// 分析一帧（直方图/波形/矢量示波器，见 pipeline_runner）。
  /// 分析失败抛 [StateError]。
  Future<Map<String, Object?>> analyze(
      Uint8List rgba, int width, int height, String kind) async {
    await _ensureStarted();
    final id = _reqId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _worker!.send([id, rgba, width, height, kind]);
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
        if (msg.length > 2 && msg[1] == 'error') {
          c.completeError(StateError(msg[2]?.toString() ?? '仪器分析失败'));
        } else {
          c.complete((msg[1] as Map).cast<String, Object?>());
        }
      }
    });
    _isolate = await Isolate.spawn(_instrumentWorkerMain, port.sendPort);
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
      c.completeError(StateError('仪器分析已终止'));
    }
    _pending.clear();
  }
}

/// worker 入口：逐条处理 [id, rgba, 宽, 高, 仪器类型]，回 [id, 结果]，
/// 失败回 [id, 'error', 消息]。
void _instrumentWorkerMain(SendPort ui) {
  final port = ReceivePort();
  ui.send(port.sendPort);
  port.listen((msg) {
    final req = msg as List;
    final id = req[0] as int;
    try {
      final result = instrumentAnalyze(
          req[4] as String, req[1] as Uint8List, req[2] as int, req[3] as int);
      ui.send([id, result]);
    } catch (e) {
      ui.send([id, 'error', e.toString()]);
    }
  });
}
