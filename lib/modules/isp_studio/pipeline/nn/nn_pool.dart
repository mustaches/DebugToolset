/// 常驻 isolate 池：把重计算 op 切分到多 isolate 并行（纯 Dart，
/// 无 Flutter 依赖）。模式参照 ilniqe.dart 的 _IlniqeWorkerPool：
/// Isolate.spawn 常驻 worker + SendPort 请求/应答，避免每任务冷 spawn。
///
/// - [parallelGemm]：按 M 行块切分，各块独立 gemm 后按行拼接；
/// - [parallelConv2d]：按输出通道（groups==1）或组边界（groups>1）
///   切分，各块独立 im2col+gemm 后沿 C 维拼接。
///
/// 两种切分都不改变任一输出元素的累加顺序，结果与单线程
/// [ops.conv2d] / [sgemm] 位级一致。大缓冲经 TransferableTypedData
/// 传输（发送侧拷贝一次，接收侧零拷贝）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'gemm.dart';
import 'ops.dart';
import 'tensor.dart';

/// worker 入口：逐条处理 `[id, kind, ...payload]`，回 `[id, 结果]`，
/// 失败回 `[id, 'error', 消息]`。
/// - 'gemm'：[aTtd, bTtd, cTtd?, m, n, k, transA, transB, alpha, beta]
///   → TransferableTypedData（[m,n] 结果块）。
/// - 'conv'：[xTtd, xShape, wTtd, wShape, biasTtd?, sH, sW, pH, pW, groups]
///   → TransferableTypedData（conv2d 完整输出）。
@pragma('vm:entry-point')
void _nnPoolWorkerMain(SendPort ui) {
  final port = ReceivePort();
  ui.send(port.sendPort);
  port.listen((msg) {
    final req = msg as List;
    final id = req[0] as int;
    try {
      if (req[1] == 'gemm') {
        final a = _recvF32(req[2]);
        final b = _recvF32(req[3]);
        final m = req[5] as int, n = req[6] as int, k = req[7] as int;
        final c = req[4] != null
            ? _recvF32(req[4] as TransferableTypedData)
            : Float32List(m * n);
        sgemm(a, b, c, m, n, k,
            transA: req[8] as bool,
            transB: req[9] as bool,
            alpha: req[10] as double,
            beta: req[11] as double);
        ui.send([id, TransferableTypedData.fromList([c])]);
      } else {
        final x = NnTensor(
            _recvF32(req[2]), (req[3] as List).cast<int>());
        final w =
            NnTensor(_recvF32(req[4]), (req[5] as List).cast<int>());
        final bias =
            req[6] != null ? _recvF32(req[6] as TransferableTypedData) : null;
        final out = conv2d(x, w,
            bias: bias,
            strideH: req[7] as int,
            strideW: req[8] as int,
            padH: req[9] as int,
            padW: req[10] as int,
            groups: req[11] as int);
        ui.send([id, TransferableTypedData.fromList([out.data])]);
      }
    } catch (e) {
      ui.send([id, 'error', e.toString()]);
    }
  });
}

Float32List _recvF32(Object ttd) =>
    (ttd as TransferableTypedData).materialize().asFloat32List();

TransferableTypedData _sendF32(Float32List v) =>
    TransferableTypedData.fromList([v]);

/// 常驻 NN 计算 isolate 池。用 [start] 启动，用完 [dispose]。
class NnPool {
  final List<Isolate> _isolates = [];
  final List<ReceivePort> _ports = [];
  final List<StreamSubscription<Object?>> _subs = [];
  final List<SendPort> _send = [];
  final Map<int, Completer<Object?>> _pending = {};
  var _reqId = 0;
  var _rr = 0;

  int get workerCount => _send.length;

  bool get isRunning => _send.isNotEmpty;

  /// 启动 [workers] 个常驻 worker（缺省：CPU 核数 - 2，限幅 [1,16]）。
  Future<void> start([int? workers]) async {
    if (isRunning) {
      throw StateError('NnPool 已启动');
    }
    final n = (workers ?? (Platform.numberOfProcessors - 2)).clamp(1, 16);
    final readies = <Future<SendPort>>[];
    for (var i = 0; i < n; i++) {
      final port = ReceivePort();
      final ready = Completer<SendPort>();
      _ports.add(port);
      _subs.add(port.listen((msg) {
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
        if (resp.length > 2 && resp[1] == 'error') {
          c.completeError(StateError('NN worker 失败: ${resp[2]}'));
        } else {
          c.complete(resp[1]);
        }
      }));
      _isolates.add(await Isolate.spawn(_nnPoolWorkerMain, port.sendPort));
      readies.add(ready.future);
    }
    _send.addAll(await Future.wait(readies));
  }

  Future<Object?> _request(List<Object?> payload) {
    final id = _reqId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send[_rr % _send.length].send([id, ...payload]);
    _rr++;
    return c.future;
  }

  /// 并行 gemm：按 M 行块切分（每 worker 若干连续行），结果按行拼接。
  /// 每块的 k 维累加顺序与单线程一致，结果与 [sgemm] 位级一致。
  Future<Float32List> parallelGemm(
    Float32List a,
    Float32List b,
    int m,
    int n,
    int k, {
    bool transA = false,
    bool transB = false,
    double alpha = 1.0,
    double beta = 0.0,
    Float32List? c,
  }) async {
    final chunks = math.min(workerCount, m);
    if (chunks <= 1) {
      final out = c ?? Float32List(m * n);
      sgemm(a, b, out, m, n, k,
          transA: transA, transB: transB, alpha: alpha, beta: beta);
      return out;
    }
    final bTtd = b; // B 全量随每个任务传输
    final tasks = <Future<Object?>>[];
    final bounds = <(int, int)>[];
    for (var t = 0; t < chunks; t++) {
      final i0 = m * t ~/ chunks;
      final i1 = m * (t + 1) ~/ chunks;
      if (i0 >= i1) {
        continue;
      }
      bounds.add((i0, i1));
      final rows = i1 - i0;
      Float32List aBlock;
      if (!transA) {
        aBlock = Float32List.fromList(
            a.sublist(i0 * k, i1 * k)); // A [m,k] 行块，连续
      } else {
        // A 按 [k,m] 存储：行块是跨步列，抽出转置为连续 [rows,k]，
        // worker 端按非转置处理（读取值与单线程相同，累加顺序不变）。
        aBlock = Float32List(rows * k);
        for (var kk = 0; kk < k; kk++) {
          final srcRow = kk * m;
          for (var i = i0; i < i1; i++) {
            aBlock[(i - i0) * k + kk] = a[srcRow + i];
          }
        }
      }
      final cBlock = (c != null && beta != 0.0)
          ? Float32List.fromList(c.sublist(i0 * n, i1 * n))
          : null;
      tasks.add(_request([
        'gemm',
        _sendF32(aBlock),
        _sendF32(bTtd),
        cBlock != null ? _sendF32(cBlock) : null,
        rows,
        n,
        k,
        false, // aBlock 已规整为 [rows,k] 连续存储，worker 端无需转置
        transB,
        alpha,
        beta,
      ]));
    }
    final results = await Future.wait(tasks);
    final out = c ?? Float32List(m * n);
    for (var t = 0; t < bounds.length; t++) {
      final (i0, i1) = bounds[t];
      final block = _recvF32(results[t] as TransferableTypedData);
      out.setRange(i0 * n, i1 * n, block);
    }
    return out;
  }

  /// 并行 conv2d：groups==1 时按输出通道切块（x 全量随任务传输），
  /// groups>1 时按组边界切块（x 只取本组通道段）。各块独立
  /// im2col+gemm 后沿 C 维拼接，与单线程 [conv2d] 位级一致。
  Future<NnTensor> parallelConv2d(
    NnTensor x,
    NnTensor weight, {
    Float32List? bias,
    int strideH = 1,
    int strideW = 1,
    int padH = 0,
    int padW = 0,
    int groups = 1,
  }) async {
    final cout = weight.shape[0];
    final cin = x.channels;
    final kh = weight.shape[2], kw = weight.shape[3];
    final splitUnit = groups == 1 ? cout : groups;
    final chunks = math.min(workerCount, splitUnit);
    if (chunks <= 1) {
      return conv2d(x, weight,
          bias: bias,
          strideH: strideH,
          strideW: strideW,
          padH: padH,
          padW: padW,
          groups: groups);
    }
    final n = x.batch, h = x.height, w = x.width;
    final oh = convOutSize(h, kh, strideH, padH);
    final ow = convOutSize(w, kw, strideW, padW);
    final s = oh * ow;
    final out = NnTensor.zeros([n, cout, oh, ow]);
    final cpg = cin ~/ groups;
    final opg = cout ~/ groups;
    // 每个切分单元（groups==1 时为单个输出通道，否则为整个组）的权重数。
    final wPerUnit = (groups == 1 ? cpg : opg * cpg) * kh * kw;

    final tasks = <Future<Object?>>[];
    final meta = <(int, int)>[]; // (起始输出通道, 通道数)
    for (var t = 0; t < chunks; t++) {
      final u0 = splitUnit * t ~/ chunks;
      final u1 = splitUnit * (t + 1) ~/ chunks;
      if (u0 >= u1) {
        continue;
      }
      Float32List xChunk;
      List<int> xShape;
      int c0, cCount, chunkGroups;
      if (groups == 1) {
        c0 = u0;
        cCount = u1 - u0;
        chunkGroups = 1;
        xChunk = x.data; // 全量传输（TransferableTypedData 复制一次）
        xShape = x.shape;
      } else {
        c0 = u0 * opg;
        cCount = (u1 - u0) * opg;
        chunkGroups = u1 - u0;
        // 按 batch 抽取本组输入通道段。
        final cinChunk = chunkGroups * cpg;
        xChunk = Float32List(n * cinChunk * h * w);
        for (var b = 0; b < n; b++) {
          xChunk.setRange(
            b * cinChunk * h * w,
            (b + 1) * cinChunk * h * w,
            x.data,
            (b * cin + u0 * cpg) * h * w,
          );
        }
        xShape = [n, cinChunk, h, w];
      }
      final wChunk = Float32List.fromList(
          weight.data.sublist(u0 * wPerUnit, u1 * wPerUnit));
      final bChunk =
          bias != null ? Float32List.fromList(bias.sublist(c0, c0 + cCount)) : null;
      meta.add((c0, cCount));
      tasks.add(_request([
        'conv',
        _sendF32(xChunk),
        xShape,
        _sendF32(wChunk),
        [cCount, cpg, kh, kw],
        bChunk != null ? _sendF32(bChunk) : null,
        strideH,
        strideW,
        padH,
        padW,
        chunkGroups,
      ]));
    }
    final results = await Future.wait(tasks);
    for (var t = 0; t < meta.length; t++) {
      final (c0, cCount) = meta[t];
      final block = _recvF32(results[t] as TransferableTypedData);
      for (var b = 0; b < n; b++) {
        out.data.setRange(
          (b * cout + c0) * s,
          (b * cout + c0 + cCount) * s,
          block,
          b * cCount * s,
        );
      }
    }
    return out;
  }

  void dispose() {
    for (final i in _isolates) {
      i.kill();
    }
    for (final s in _subs) {
      s.cancel();
    }
    for (final p in _ports) {
      p.close();
    }
    for (final c in _pending.values) {
      c.completeError(StateError('NnPool 已终止'));
    }
    _pending.clear();
    _send.clear();
    _isolates.clear();
    _ports.clear();
    _subs.clear();
  }
}
