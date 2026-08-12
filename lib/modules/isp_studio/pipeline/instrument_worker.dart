/// 常驻仪器分析 worker 池（独立 isolate）与 UI 侧客户端。
///
/// 播放中仪器刷新很频繁：每次都用 compute() 新起 isolate 的开销
/// （spawn + debug 下 JIT 冷启动，Windows 上可阻塞 UI 事件循环上百
/// 毫秒）会直接造成播放丢帧。常驻 worker 只起一次、JIT 只热身一次，
/// 之后每次分析只是端口消息往返。
///
/// 多核加速：直方图/波形的计数表天然可加，帧按水平条带切给池内
/// 多个 worker 并行统计，结果逐元素相加合并（mergeInstrumentResults）。
/// 矢量示波器是扫描轨迹连线，条带边界会断线，固定由 0 号 worker
/// 整帧分析。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'pipeline_runner.dart' show instrumentAnalyze;
import 'instruments.dart' show mergeInstrumentResults;

/// 单个常驻 worker isolate 的槽位：自己的端口与挂起请求表。
class _WorkerSlot {
  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _port;
  StreamSubscription<Object?>? _sub;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  var _reqId = 0;

  /// 发送分析请求，回分析结果 map；失败抛 [StateError]。
  Future<Map<String, Object?>> request(
      String kind, Uint8List rgba, int width, int height) {
    final id = _reqId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _worker!.send([id, rgba, width, height, kind]);
    return c.future;
  }

  Future<void> start() async {
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
    for (final c in _pending.values) {
      c.completeError(StateError('仪器分析已终止'));
    }
    _pending.clear();
  }
}

/// 常驻 isolate 池的仪器分析客户端。非线程安全：调用方自行串行化
/// （IspStudioState 的 _instrumentBusy 闸保证一次只跑一批）。
class InstrumentAnalyzer {
  /// 池大小：留两核给 UI 与解码，上限 8。
  static final int poolSize =
      (Platform.numberOfProcessors - 2).clamp(1, 8);

  final List<_WorkerSlot> _workers = [];
  var _started = false;

  /// 分析一帧（直方图/波形/矢量示波器，见 pipeline_runner）。
  /// [rgba] 应已按需降采样（调用侧在抽取时完成）；直方图/波形在池内
  /// 按条带并行，矢量示波器整帧单 worker。分析失败抛 [StateError]。
  Future<Map<String, Object?>> analyze(
      Uint8List rgba, int width, int height, String kind) async {
    await _ensureStarted();
    final n = _workers.length;
    // 矢量示波器不可条带拆分；帧太矮切不出像样条带时也不拆。
    if (n <= 1 || kind == 'vectorscope' || height < n * 64) {
      return _workers[0].request(kind, rgba, width, height);
    }
    final rowsPer = height ~/ n;
    final parts = <Future<Map<String, Object?>>>[];
    for (var i = 0; i < n; i++) {
      final y0 = i * rowsPer;
      final y1 = i == n - 1 ? height : y0 + rowsPer;
      // 视图零拷贝创建；端口消息只拷条带覆盖的字节段。
      final band =
          Uint8List.sublistView(rgba, y0 * width * 4, y1 * width * 4);
      parts.add(_workers[i].request(kind, band, width, y1 - y0));
    }
    return mergeInstrumentResults(await Future.wait(parts));
  }

  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    for (var i = 0; i < poolSize; i++) {
      final slot = _WorkerSlot();
      await slot.start();
      _workers.add(slot);
    }
  }

  /// 结束全部 worker isolate（挂起的请求以错误收尾）。
  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    _started = false;
  }
}

/// worker 入口：逐条处理 [id, rgba, 宽, 高, 仪器类型]，回 [id, 结果]，
/// 失败回 [id, 'error', 消息]。
@pragma('vm:entry-point')
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
