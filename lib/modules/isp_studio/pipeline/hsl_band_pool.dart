/// 色彩控制器高斯色相带的常驻条带计算池与多核并行入口。
///
/// 实测每帧临时 Isolate.run 扇出的 spawn 开销约 300ms+（14 路并发空转，
/// Dart VM 的 isolate 启动相互串行），4K60（16.6ms/帧预算）完全不可行。
/// 常驻 worker 只在每个宿主 isolate 内起一次（JIT 热身一次），之后每次
/// 调用只是端口消息往返：输入帧 typed data 零拷贝共享，结果经
/// TransferableTypedData 零拷贝送回。
///
/// 池为每 isolate 单例（懒创建，[HslBandPool.instance]）：单帧预览的链
/// isolate、播放路径的常驻流水线 worker（pipeline_worker.dart）各自持
/// 有自己的池，后者逐帧复用、启动开销只付一次。
///
/// 两种消息模式：参数模式（色彩控制器，worker 内合成高斯带权重）与
/// LUT 模式（多段色彩均衡器，生成期合成的 H 域 LUT 随消息传入）。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'isp_kernels.dart';

/// 条带 worker isolate 入口。
/// 参数模式收 [replyTo, bandData, maxValue, hCenterDeg, q, hShiftDeg,
/// sGain, lGain]（bandData 为本行带切片视图）；LUT 模式收 ['lut',
/// replyTo, bandData, maxValue, shiftLut, sMulLut, lMulLut]（多段色彩
/// 均衡器，生成期合成的 H 域 LUT 随消息传入）。统一回
/// TransferableTypedData 封装的行带结果。
void _hslBandWorkerMain(SendPort ready) {
  final port = ReceivePort();
  ready.send(port.sendPort);
  port.listen((msg) {
    final m = msg as List;
    if (m[0] == 'lut') {
      final band = m[2] as Uint16List;
      final out = applyHslBandLuts(band, 0, band.length ~/ 3,
          maxValue: m[3] as int,
          shiftLut: m[4] as Int32List,
          sMulLut: m[5] as Float64List,
          lMulLut: m[6] as Float64List);
      (m[1] as SendPort).send(TransferableTypedData.fromList([out]));
      return;
    }
    final band = m[1] as Uint16List;
    final out = adjustHslBandRows(band, 0, band.length ~/ 3,
        maxValue: m[2] as int,
        hCenterDeg: m[3] as double,
        q: m[4] as double,
        hShiftDeg: m[5] as double,
        sGain: m[6] as double,
        lGain: m[7] as double);
    (m[0] as SendPort).send(TransferableTypedData.fromList([out]));
  });
}

/// 常驻条带 worker 池。非线程安全之外的多路并发由空闲队列串行化到
/// worker 上（同一 worker 同时只跑一条带）。
class HslBandPool {
  HslBandPool._();

  /// 每 isolate 的共享实例。
  static final HslBandPool instance = HslBandPool._();

  final List<SendPort> _all = [];
  final List<SendPort> _idle = [];
  final _waiters = <Completer<SendPort>>[];
  Future<void>? _starting;
  bool _broken = false;

  /// worker 数：全部核心 − 2（见 [cpuBandWorkers]）。
  int get size => cpuBandWorkers;

  /// 池是否可用（启动失败后置 false，调用方回退 Isolate.run）。
  bool get isAvailable => !_broken;

  Future<void> _ensureStarted() {
    if (_all.isNotEmpty) return Future.value();
    if (_broken) throw StateError('条带池启动失败');
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final ready = ReceivePort();
    final allReady = Completer<void>();
    final workers = <SendPort>[];
    final sub = ready.listen((msg) {
      if (msg is SendPort) {
        workers.add(msg);
        if (workers.length == size && !allReady.isCompleted) {
          allReady.complete();
        }
      }
    });
    try {
      await Future.wait([
        for (var i = 0; i < size; i++)
          Isolate.spawn(_hslBandWorkerMain, ready.sendPort),
      ]);
      await allReady.future;
      _all.addAll(workers);
      _idle.addAll(workers);
    } catch (_) {
      _broken = true;
      rethrow;
    } finally {
      await sub.cancel();
      ready.close();
    }
  }

  Future<SendPort> _takeIdle() {
    if (_idle.isNotEmpty) return Future.value(_idle.removeLast());
    final c = Completer<SendPort>();
    _waiters.add(c);
    return c.future;
  }

  void _release(SendPort w) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(w);
    } else {
      _idle.add(w);
    }
  }

  /// 在空闲 worker 上计算 [startPx, endPx) 像素区间，返回该区间的新数据。
  /// 发送端只传该行带切片（整帧广播会在调用侧串行序列化 N×全帧）；
  /// 注意必须发**普通 Uint16List 拷贝**——sublistView 视图走逐元素慢速
  /// 序列化路径（实测 4K 帧 14 路分发 380ms → 65ms）。
  Future<Uint16List> runBand(Uint16List src, int startPx, int endPx,
      {required int maxValue,
      required double hCenterDeg,
      required double q,
      required double hShiftDeg,
      required double sGain,
      required double lGain}) async {
    await _ensureStarted();
    final w = await _takeIdle();
    final reply = ReceivePort();
    w.send([
      reply.sendPort,
      src.sublist(startPx * 3, endPx * 3),
      maxValue, hCenterDeg, q, hShiftDeg, sGain, lGain,
    ]);
    final msg = await reply.first;
    reply.close();
    _release(w);
    return (msg as TransferableTypedData).materialize().asUint16List();
  }

  /// LUT 模式：在空闲 worker 上按生成期合成的 H 域 LUT 计算
  /// [startPx, endPx) 像素区间（多段色彩均衡器用），返回该区间的新
  /// 数据。LUT 各 361 项量级，随消息复制进 worker 可忽略；与串行
  /// [applyHslBandLuts] 逐位一致。
  Future<Uint16List> runBandLuts(Uint16List src, int startPx, int endPx,
      {required int maxValue,
      required Int32List shiftLut,
      required Float64List sMulLut,
      required Float64List lMulLut}) async {
    await _ensureStarted();
    final w = await _takeIdle();
    final reply = ReceivePort();
    w.send([
      'lut', reply.sendPort, //
      src.sublist(startPx * 3, endPx * 3),
      maxValue, shiftLut, sMulLut, lMulLut,
    ]);
    final msg = await reply.first;
    reply.close();
    _release(w);
    return (msg as TransferableTypedData).materialize().asUint16List();
  }
}

/// 色彩控制器多核并行路径：宽×高 ≥ 1M 像素时按行带切分提交常驻条带池
/// （池不可用时回退每路 Isolate.run），按带序确定性拼接，与串行
/// [adjustHslBand] 逐位一致；小图走串行，避免调度开销超过收益。
Future<Uint16List> adjustHslBandParallel(Uint16List hsl,
    {required int width,
    required int height,
    required int maxValue,
    double hCenterDeg = 0,
    double q = 2.0,
    double hShiftDeg = 0,
    double sGain = 1.0,
    double lGain = 1.0}) async {
  if (hShiftDeg == 0 && sGain == 1.0 && lGain == 1.0) return hsl;
  const parallelPixels = 1 << 20;
  if (width * height < parallelPixels) {
    return adjustHslBand(hsl,
        maxValue: maxValue,
        hCenterDeg: hCenterDeg,
        q: q,
        hShiftDeg: hShiftDeg,
        sGain: sGain,
        lGain: lGain);
  }
  final pool = HslBandPool.instance;
  final usePool = pool.isAvailable;
  final nw = math.min(cpuBandWorkers, height);
  final tasks = <Future<Uint16List>>[];
  for (var t = 0; t < nw; t++) {
    final y0 = height * t ~/ nw, y1 = height * (t + 1) ~/ nw;
    if (y0 >= y1) continue;
    if (usePool) {
      tasks.add(pool.runBand(hsl, y0 * width, y1 * width,
          maxValue: maxValue,
          hCenterDeg: hCenterDeg,
          q: q,
          hShiftDeg: hShiftDeg,
          sGain: sGain,
          lGain: lGain));
    } else {
      tasks.add(Isolate.run(() => adjustHslBandRows(hsl, y0 * width,
          y1 * width,
          maxValue: maxValue,
          hCenterDeg: hCenterDeg,
          q: q,
          hShiftDeg: hShiftDeg,
          sGain: sGain,
          lGain: lGain)));
    }
  }
  final bands = await Future.wait(tasks);
  final out = Uint16List(hsl.length);
  var o = 0;
  for (final b in bands) {
    out.setRange(o, o + b.length, b);
    o += b.length;
  }
  return out;
}

/// 多段色彩均衡器等「生成期合成 LUT」路径的并行查表：与
/// [adjustHslBandParallel] 同口径（宽×高 ≥ 1M 像素按行带扇出、按带序
/// 确定性拼接），各带优先提交常驻条带池（播放路径每帧 Isolate.run
/// 扇出的 spawn 开销 ~300ms 级，不可承受；池不可用时才回退
/// Isolate.run），与整幅串行 [applyHslBandLuts] 逐位一致；小图走串行。
Future<Uint16List> applyHslBandLutsParallel(Uint16List hsl,
    {required int width,
    required int height,
    required int maxValue,
    required Int32List shiftLut,
    required Float64List sMulLut,
    required Float64List lMulLut}) async {
  const parallelPixels = 1 << 20;
  if (width * height < parallelPixels) {
    return applyHslBandLuts(hsl, 0, hsl.length ~/ 3,
        maxValue: maxValue,
        shiftLut: shiftLut,
        sMulLut: sMulLut,
        lMulLut: lMulLut);
  }
  final pool = HslBandPool.instance;
  final usePool = pool.isAvailable;
  final nw = math.min(cpuBandWorkers, height);
  final tasks = <Future<Uint16List>>[];
  for (var t = 0; t < nw; t++) {
    final y0 = height * t ~/ nw, y1 = height * (t + 1) ~/ nw;
    if (y0 >= y1) continue;
    if (usePool) {
      tasks.add(pool.runBandLuts(hsl, y0 * width, y1 * width,
          maxValue: maxValue,
          shiftLut: shiftLut,
          sMulLut: sMulLut,
          lMulLut: lMulLut));
    } else {
      tasks.add(Isolate.run(() => applyHslBandLuts(hsl, y0 * width, y1 * width,
          maxValue: maxValue,
          shiftLut: shiftLut,
          sMulLut: sMulLut,
          lMulLut: lMulLut)));
    }
  }
  final bands = await Future.wait(tasks);
  final out = Uint16List(hsl.length);
  var o = 0;
  for (final b in bands) {
    out.setRange(o, o + b.length, b);
    o += b.length;
  }
  return out;
}
