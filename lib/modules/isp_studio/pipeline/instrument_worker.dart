/// 常驻仪器分析 worker 池（独立 isolate）与 UI 侧客户端。
///
/// 播放中仪器刷新很频繁：每次都用 compute() 新起 isolate 的开销
/// （spawn + debug 下 JIT 冷启动，Windows 上可阻塞 UI 事件循环上百
/// 毫秒）会直接造成播放丢帧。常驻 worker 只起一次、JIT 只热身一次，
/// 之后每次分析只是端口消息往返。
///
/// 多核加速：直方图/波形的计数表天然可加，帧按水平条带切给池内
/// 多个 worker 并行统计，结果逐元素相加合并（mergeInstrumentResults）。
/// 矢量示波器的扫描轨迹连线逐行独立（行间接续仅占 1/行数，可忽略），
/// 播放实时刷新按**隔行**条带拆分（analyzeVectorscopeParallel）：
/// 负载天然均衡，合并与渲染在 0 号 worker 完成。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'pipeline_runner.dart' show instrumentAnalyze;
import 'instruments.dart'
    show
        intensityRgba,
        kVectorscopeSize,
        kWaveformLevels,
        mergeInstrumentResults,
        vectorscope,
        waveformIntensityRgba;

/// 单个常驻 worker isolate 的槽位：自己的端口与挂起请求表。
class _WorkerSlot {
  Isolate? _isolate;
  SendPort? _worker;
  ReceivePort? _port;
  StreamSubscription<Object?>? _sub;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  var _reqId = 0;

  /// 发送分析请求，回分析结果 map；失败抛 [StateError]。
  /// [render] 为 true 且类型为波形/矢量示波器时，worker 侧直接把计数表
  /// 渲染成亮度图随结果返回（'bmp'，不回计数表，省一次 UI 全帧渲染与
  /// 计数表端口拷贝）；[visible] 为波形的可见通道。
  /// [payload] 通常是帧 RGBA（Uint8List）；'render_vectorscope' 时是
  /// 各条带计数表的字节视图列表（`List<Uint8List>`）。
  Future<Map<String, Object?>> request(
      String kind, Object payload, int width, int height,
      {Set<String>? visible, bool render = false}) {
    final id = _reqId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _worker!.send([id, payload, width, height, kind, visible?.toList(), render]);
    return c.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pending.remove(id);
        throw StateError('仪器分析超时 ($kind ${width}x$height)');
      },
    );
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
  var _rr = 0;

  /// 整机分配到单一 worker（轮转）：播放中多台仪器并发刷新时摊到池内
  /// 不同 isolate 并行，避免全挤在 0 号 worker 串行排队。波形/矢量
  /// 示波器在 worker 侧直接渲染亮度图（结果带 'bmp'，不回计数表）。
  /// 波形按 [visible] 只统计可见通道。
  Future<Map<String, Object?>> analyzeDedicated(
      Uint8List rgba, int width, int height, String kind,
      {Set<String>? visible}) async {
    await _ensureStarted();
    final slot = _workers[_rr % _workers.length];
    _rr++;
    return slot.request(kind, rgba, width, height,
        visible: visible,
        render: kind == 'waveform' || kind == 'vectorscope');
  }

  /// 矢量示波器多核并行（播放实时刷新用，保留连线轨迹）：抗锯齿连线
  /// 是噪声帧热点（实测单 worker 50~200ms/帧@480p），必须拆分。
  /// 按**隔行**条带切给池内全部 worker（worker i 取第 i, i+n, … 行）：
  /// 相对连续条带负载天然均衡（内容/噪声集中在某一区域时连续条带
  /// 的拖尾带会拖住整帧，实测慢 2~3 倍）；代价是丢失行间接续线段
  /// （每行末→下行首，仅占 1/height，视觉不可见）与一次行收集拷贝
  /// （亚毫秒）。各带计数表一次性发给 0 号 worker 合并并渲染亮度图
  /// （8 张 512² 表若在 UI 合并，每帧 2M 次加法挤占走帧事件循环）。
  Future<Map<String, Object?>> analyzeVectorscopeParallel(
      Uint8List rgba, int width, int height) async {
    await _ensureStarted();
    // 条带数取 4 封顶：每带要回传一张 512² 计数表（1MB），带数越多
    // 端口搬运与合并开销越大，实测 4 带是分析并行度与搬运开销的拐点。
    final n = _workers.length < 4 ? _workers.length : 4;
    if (n <= 1 || height < n * 4) {
      return _workers[0]
          .request('vectorscope', rgba, width, height, render: true);
    }
    final rowBytes = width * 4;
    final parts = <Future<Map<String, Object?>>>[];
    for (var i = 0; i < n; i++) {
      var rows = 0;
      for (var y = i; y < height; y += n) {
        rows++;
      }
      final band = Uint8List(rows * rowBytes);
      var dst = 0;
      for (var y = i; y < height; y += n, dst += rowBytes) {
        band.setRange(dst, dst + rowBytes, rgba, y * rowBytes);
      }
      parts.add(_workers[i].request('vectorscope_rows', band, width, rows));
    }
    final countsList = <Uint8List>[];
    for (final p in await Future.wait(parts)) {
      final counts = p['counts'] as Uint32List;
      countsList.add(counts.buffer
          .asUint8List(counts.offsetInBytes, counts.lengthInBytes));
    }
    return _workers[0].request('render_vectorscope', countsList,
        kVectorscopeSize, kVectorscopeSize);
  }

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

  Future<void>? _starting;

  Future<void> _ensureStarted() {
    if (_started) return Future.value();
    final start = _starting;
    if (start != null) return start;
    final completer = Completer<void>();
    _starting = completer.future;
    () async {
      try {
        // 并行 spawn：串行 await 会把启动延迟叠加到首个分析请求上。
        final slots = [for (var i = 0; i < poolSize; i++) _WorkerSlot()];
        await Future.wait([for (final s in slots) s.start()]);
        _workers.addAll(slots);
        _started = true;
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _starting = null;
      }
    }();
    return completer.future;
  }

  /// 预热全部 worker（播放开始时与流解码/流水线初始化并行，
  /// 避免首个仪器刷新批次承担 isolate 启动开销）。
  Future<void> warmup() => _ensureStarted();

  /// 结束全部 worker isolate（挂起的请求以错误收尾）。
  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    _started = false;
  }
}

/// worker 入口：逐条处理 [id, rgba, 宽, 高, 仪器类型, 可见通道, 渲染]，
/// 回 [id, 结果]，失败回 [id, 'error', 消息]。渲染为 true 时波形/矢量
/// 示波器在 worker 侧出亮度图（结果含 'bmp'，不含计数表）。
/// 特殊类型：'vectorscope_rows' 为隔行条带（每行开头重置电子束起点，
/// 回计数表）；'render_vectorscope' 的 rgba 槽位携带各条带计数表的
/// 字节视图列表（`List<Uint8List>`），合并后渲染亮度图。
@pragma('vm:entry-point')
void _instrumentWorkerMain(SendPort ui) {
  final port = ReceivePort();
  ui.send(port.sendPort);
  port.listen((msg) {
    final req = msg as List;
    final id = req[0] as int;
    try {
      final kind = req[4] as String;
      final visible = (req[5] as List?)?.cast<String>().toSet();
      final render = req.length > 6 && req[6] == true;
      if (kind == 'vectorscope_rows') {
        ui.send([
          id,
          {
            'kind': 'vectorscope',
            'counts':
                vectorscope(req[1] as Uint8List, rowWidth: req[2] as int),
          }
        ]);
        return;
      }
      if (kind == 'render_vectorscope') {
        // rgba 槽位携带各条带计数表的字节视图列表：合并（首张表就地
        // 累加，消息缓冲区为本 isolate 私有副本，可写）后渲染亮度图。
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
        ui.send([
          id,
          {
            'kind': 'vectorscope',
            'bmp': intensityRgba(
                counts, kVectorscopeSize, kVectorscopeSize, 70, 235, 70),
          }
        ]);
        return;
      }
      var result = instrumentAnalyze(
          kind, req[1] as Uint8List, req[2] as int, req[3] as int,
          visible: kind == 'waveform' ? visible : null);
      if (render && kind == 'waveform') {
        final cols = (result['columns'] as num).toInt();
        final bmp =
            waveformIntensityRgba(result, cols, kWaveformLevels, visible ?? {'y'});
        result = {'kind': kind, 'columns': cols, 'bmp': bmp};
      } else if (render && kind == 'vectorscope') {
        final counts = result['counts'] as Uint32List;
        result = {
          'kind': kind,
          'bmp': intensityRgba(
              counts, kVectorscopeSize, kVectorscopeSize, 70, 235, 70),
        };
      }
      ui.send([id, result]);
    } catch (e) {
      ui.send([id, 'error', e.toString()]);
    }
  });
}
