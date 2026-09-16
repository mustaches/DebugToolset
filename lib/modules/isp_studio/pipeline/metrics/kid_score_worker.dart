/// KID 出分的常驻 isolate 封装（纯 Dart，无 Flutter 依赖）：worker 内
/// 持有一个 [KidGramAccum]（增量核矩阵），避免每帧把全量特征/核矩阵
/// 在 isolate 间往返——每帧消息量仅新增特征（fp32 拷贝发送，特征与
/// FID/特征缓存共享所有权，不能 TransferableTypedData 移走）。
/// 模式参照 nn_pool.dart：Isolate.spawn 常驻 worker + SendPort
/// 请求/应答。出分与全量 kidCompute 逐位一致（见 KidGramAccum）。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'fid_kid_dart.dart';

/// worker 入口：逐条处理 `[id, kind, ...payload]`，失败回
/// `[id, 'error', 消息]`。
/// - 'add'：[refFeats, testFeats]（fp32，[n,2048] 连续排布）
///   → `[id, nRef, nTest]`（累计后两侧样本数）。
/// - 'score'：无 payload → `[id, kid 分值]`。
/// - 'reset'：无 payload → `[id, true]`。
@pragma('vm:entry-point')
void _kidScoreWorkerMain(SendPort ui) {
  final port = ReceivePort();
  final accum = KidGramAccum();
  ui.send(port.sendPort);
  port.listen((msg) {
    final req = msg as List;
    final id = req[0] as int;
    try {
      if (req[1] == 'add') {
        final ref = req[2] as Float32List;
        final test = req[3] as Float32List;
        accum.addBatch(ref, ref.length ~/ fidFeatureDim, test,
            test.length ~/ fidFeatureDim);
        ui.send([id, accum.nRef, accum.nTest]);
      } else if (req[1] == 'score') {
        ui.send([id, accum.score()]);
      } else {
        accum.reset();
        ui.send([id, true]);
      }
    } catch (e) {
      ui.send([id, 'error', e.toString()]);
    }
  });
}

/// KID 出分常驻 isolate。用 [start] 启动，用完 [dispose]。
class KidScoreWorker {
  Isolate? _isolate;
  ReceivePort? _port;
  StreamSubscription<Object?>? _sub;
  SendPort? _send;
  final Map<int, Completer<List<Object?>>> _pending = {};
  var _reqId = 0;

  bool get isRunning => _send != null;

  /// 启动 worker（等待就绪握手）。
  Future<void> start() async {
    if (isRunning) {
      throw StateError('KidScoreWorker 已启动');
    }
    final port = ReceivePort();
    final ready = Completer<SendPort>();
    _port = port;
    _sub = port.listen((msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) {
          ready.complete(msg);
        }
        return;
      }
      final resp = msg as List;
      final c = _pending.remove(resp[0] as int);
      if (c == null) {
        return;
      }
      if (resp.length > 1 && resp[1] == 'error') {
        c.completeError(StateError('KID worker 失败: ${resp[2]}'));
      } else {
        c.complete(resp.cast<Object?>());
      }
    });
    _isolate = await Isolate.spawn(_kidScoreWorkerMain, port.sendPort);
    _send = await ready.future;
  }

  Future<List<Object?>> _request(List<Object?> payload) {
    final id = _reqId++;
    final c = Completer<List<Object?>>();
    _pending[id] = c;
    _send!.send([id, ...payload]);
    return c.future;
  }

  /// 累计一帧：两侧各为 [n,2048] 连续排布的新增 patch 特征（fp32
  /// 拷贝发送，worker 内只算核矩阵新增块）；返回累计后两侧样本数。
  Future<(int, int)> add(Float32List refFeats, Float32List testFeats) async {
    final r = await _request(['add', refFeats, testFeats]);
    return (r[1] as int, r[2] as int);
  }

  /// 出分（无偏 MMD 子集均值，口径同 kidCompute）。
  Future<double> score() async => (await _request(['score']))[1] as double;

  /// 清空累计（新一轮运行）。
  Future<void> reset() async {
    await _request(['reset']);
  }

  /// 终止 isolate 并释放端口。
  void dispose() {
    _isolate?.kill();
    _isolate = null;
    _send = null;
    _sub?.cancel();
    _sub = null;
    _port?.close();
    _port = null;
  }
}
