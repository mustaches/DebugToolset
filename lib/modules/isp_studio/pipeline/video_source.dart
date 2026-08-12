/// Video 源节点的视频帧解码：经 ffmpeg 逐帧抽取（MP4/MKV/AVI/MOV 等，
/// 取决于 ffmpeg 构建支持的封装与编码）。
///
/// 纯 Dart + 外部 ffmpeg 进程（[findFfmpeg] 定位），可在后台 isolate
/// 中运行。每帧独立起进程：`-ss` 在 `-i` 前做输入跳转（关键帧定位 +
/// accurate_seek 精确到目标时刻），开销与关键帧间距成正比而非全片。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'exporters.dart' show findFfmpeg;

/// 视频文件的元信息。
class VideoInfo {
  final int width;
  final int height;

  /// 帧率（解析失败时回退 25）。
  final double fps;

  /// 帧数 = 时长 × 帧率向下取整（无 ffprobe，只能估算；解码越界帧时
  /// ffmpeg 会返回空，由解码方报"超出视频范围"）。
  final int frameCount;

  /// 是否含音频流（`ffmpeg -i` 输出中有 Audio: 行）。
  final bool hasAudio;

  const VideoInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.frameCount,
    required this.hasAudio,
  });
}

/// 元信息缓存（按 路径|ffmpeg 键）：播放中每帧都会查尺寸/帧数，
/// 缓存避免每帧多起一个 ffmpeg 进程。
final Map<String, VideoInfo> _infoCache = {};

/// 解析视频元信息（`ffmpeg -i` 的 stderr：Duration 与 Video 流行）。
/// 文件不存在、ffmpeg 不可用或解析失败时抛 [StateError]。
Future<VideoInfo> videoFileInfo(String path, {String ffmpegPath = ''}) async {
  final key = '$path|$ffmpegPath';
  final cached = _infoCache[key];
  if (cached != null) return cached;
  if (!await File(path).exists()) throw StateError('视频文件不存在: $path');
  final ffmpeg = await findFfmpeg(overridePath: ffmpegPath);
  if (ffmpeg == null) throw StateError('找不到 ffmpeg，无法解码视频');
  final result = await Process.run(ffmpeg, ['-hide_banner', '-i', path]);
  final text = result.stderr.toString();

  final sizeM =
      RegExp(r'Video:.*?[,\s](\d{1,5})x(\d{1,5})[\s,\[]').firstMatch(text);
  if (sizeM == null) throw StateError('无法解析视频分辨率: $path');
  final width = int.parse(sizeM.group(1)!);
  final height = int.parse(sizeM.group(2)!);

  final fpsM = RegExp(r'(\d+(?:\.\d+)?)\s*fps').firstMatch(text);
  final fps = fpsM != null ? double.parse(fpsM.group(1)!) : 25.0;

  final durM = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)')
      .firstMatch(text);
  if (durM == null) throw StateError('无法解析视频时长: $path');
  final duration = int.parse(durM.group(1)!) * 3600 +
      int.parse(durM.group(2)!) * 60 +
      double.parse(durM.group(3)!);
  final frameCount = (duration * fps).floor();
  if (frameCount < 1) throw StateError('视频没有可解码的帧: $path');

  final info = VideoInfo(
      width: width,
      height: height,
      fps: fps,
      frameCount: frameCount,
      hasAudio: RegExp(r'Stream.*Audio:').hasMatch(text));
  _infoCache[key] = info;
  return info;
}

/// 解码第 [frameIndex] 帧为 16 位量级的交织 RGB（长度 w*h*3），
/// 返回 (数据, 宽, 高)。8 位样本按比例放大到 [maxValue]。
/// 帧越界或解码失败时抛 [StateError]。
Future<(Uint16List, int, int)> decodeVideoFrameToRgb16(
  String path,
  int frameIndex, {
  required int maxValue,
  String ffmpegPath = '',
}) async {
  final info = await videoFileInfo(path, ffmpegPath: ffmpegPath);
  if (frameIndex < 0 || frameIndex >= info.frameCount) {
    throw StateError('帧 $frameIndex 超出视频范围（共 ${info.frameCount} 帧）');
  }
  final ffmpeg = (await findFfmpeg(overridePath: ffmpegPath))!;
  final t = frameIndex / info.fps;
  final process = await Process.start(ffmpeg, [
    '-hide_banner', '-loglevel', 'error',
    '-ss', t.toStringAsFixed(6),
    '-i', path,
    '-frames:v', '1',
    '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1',
  ]);
  final out = BytesBuilder(copy: false);
  // stderr 必须排空，否则管道缓冲打满会互相等待。
  final outDone = process.stdout.forEach(out.add);
  final errDone = process.stderr.drain<void>();
  await Future.wait([outDone, errDone]);
  final code = await process.exitCode;
  final bytes = out.takeBytes();
  if (code != 0) {
    throw StateError('ffmpeg 解码失败 (exit $code): $path');
  }
  final pixels = info.width * info.height;
  if (bytes.length < pixels * 4) {
    throw StateError('帧 $frameIndex 解码失败（可能超出视频末尾）: $path');
  }
  return (rgba8ToRgb16(bytes, info.width, info.height, maxValue).$1,
      info.width, info.height);
}

/// RGBA8888 → 16 位量级交织 RGB（丢弃 alpha），返回 (数据, 宽, 高)。
/// 8 位样本按比例放大到 [maxValue]。
(Uint16List, int, int) rgba8ToRgb16(
    Uint8List rgba, int width, int height, int maxValue) {
  final pixels = width * height;
  final out = Uint16List(pixels * 3);
  final scale = maxValue / 255;
  var i = 0;
  for (var j = 0; j < pixels * 4; j += 4) {
    out[i++] = (rgba[j] * scale).round();
    out[i++] = (rgba[j + 1] * scale).round();
    out[i++] = (rgba[j + 2] * scale).round();
  }
  return (out, width, height);
}

/// 顺序视频帧流：ffmpeg 进程与帧切片运行在专用 isolate（[_streamWorker]），
/// UI isolate 不接触管道。
///
/// 1080p60 是 ~500MB/s 的管道数据：若在 UI isolate 上按 ~64KB 块消费，
/// 每帧要 ~130 次事件循环调度，事件循环一忙（重绘/GC）解码速率就崩。
/// worker isolate 事件循环空闲，全速 drain 管道；整帧经
/// TransferableTypedData 零拷贝送达，每帧仅 1 次消息调度。
///
/// 背压用"信用额度"：worker 最多持有 [_kStreamPoolSize] 个帧缓冲，
/// 缓冲随帧流向 UI，消费方 [recycle] 归还（同样零拷贝）后才能再切片——
/// UI 不消费，worker 就没有缓冲可用，ffmpeg 管道自然阻塞。
/// 随机跳帧时 [dispose] 后重新 [start]。
class VideoFrameStream {
  VideoFrameStream._(this.info, this.nextIndex);

  /// 视频元信息（尺寸/帧率/帧数）。
  final VideoInfo info;

  /// 下一帧序号（从 startFrame 起随 [next] 递增）。
  int nextIndex;

  Isolate? _isolate;
  SendPort? _workerPort;
  StreamSubscription<Object?>? _sub;
  final Queue<Uint8List> _frames = Queue();
  Completer<void>? _notEmpty;
  String? _error;
  var _eof = false;
  var _disposed = false;

  int get _frameBytes => info.width * info.height * 4;

  /// 从 [startFrame] 起顺序解码（-ss 输入跳转到最近关键帧再精确到
  /// 目标时刻，之后连续解码不回退）。
  static Future<VideoFrameStream> start(String path, int startFrame,
      {String ffmpegPath = ''}) async {
    final info = await videoFileInfo(path, ffmpegPath: ffmpegPath);
    if (startFrame < 0 || startFrame >= info.frameCount) {
      throw StateError('帧 $startFrame 超出视频范围（共 ${info.frameCount} 帧）');
    }
    final ffmpeg = (await findFfmpeg(overridePath: ffmpegPath))!;
    final stream = VideoFrameStream._(info, startFrame);
    final port = ReceivePort();
    final ready = Completer<void>();
    stream._sub = port.listen((msg) {
      if (msg is SendPort) {
        stream._workerPort = msg;
        ready.complete();
        return;
      }
      stream._onMessage(msg);
    });
    stream._isolate = await Isolate.spawn(
        _streamWorker,
        _StreamWorkerConfig(port.sendPort, ffmpeg, path, startFrame,
            info.width, info.height, info.fps));
    await ready.future;
    return stream;
  }

  void _onMessage(Object? msg) {
    if (msg is TransferableTypedData) {
      _frames.add(msg.materialize().asUint8List());
    } else if (msg is List && msg.isNotEmpty && msg[0] == 'error') {
      _error = msg.length > 1 ? msg[1]?.toString() : '视频解码失败';
      _eof = true;
    } else {
      _eof = true; // null：EOF 或已停止
    }
    _notEmpty?.complete();
    _notEmpty = null;
  }

  /// 取下一帧（RGBA8888，w*h*4）；EOF 后无帧返回 null。
  /// 解码失败抛 [StateError]。
  Future<Uint8List?> next() async {
    while (_frames.isEmpty) {
      if (_error != null) throw StateError(_error!);
      if (_eof || _disposed) return null;
      _notEmpty = Completer<void>();
      await _notEmpty!.future;
    }
    final frame = _frames.removeFirst();
    nextIndex++;
    return frame;
  }

  /// 归还 [next] 返回的帧缓冲（内容消费完毕后调用）：
  /// 零拷贝送回 worker 复用；不归还则 worker 用完信用额度后停等。
  void recycle(Uint8List frame) {
    if (_disposed || frame.length != _frameBytes) return;
    _workerPort?.send(TransferableTypedData.fromList([frame]));
  }

  /// 终止解码：通知 worker 杀 ffmpeg 进程并等其收尾，再结束 isolate。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _workerPort?.send('stop');
    // worker 清理完（杀进程）会发 null；等它，超时兜底。
    if (!_eof) {
      final done = Completer<void>();
      _notEmpty = done;
      await done.future
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    await _sub?.cancel();
    _sub = null;
    _isolate?.kill();
    _isolate = null;
    _frames.clear();
    _notEmpty?.complete();
    _notEmpty = null;
  }
}

/// [_streamWorker] 的启动参数（Isolate 消息只能含可发送类型）。
class _StreamWorkerConfig {
  final SendPort uiPort;
  final String ffmpeg;
  final String path;
  final int startFrame;
  final int width;
  final int height;
  final double fps;

  const _StreamWorkerConfig(this.uiPort, this.ffmpeg, this.path,
      this.startFrame, this.width, this.height, this.fps);
}

/// worker 同时最多持有的帧缓冲数（信用额度；1080p ≈ 130MB）。
const int _kStreamPoolSize = 16;

/// 帧流 worker（独立 isolate）：起 ffmpeg 进程，drain stdout 切片整帧，
/// 经 TransferableTypedData 发给 UI；缓冲用完后等 UI 归还（背压）。
/// 收到 'stop' 或进程结束：发 null 收尾。异常发 ['error', 消息] 后收尾。
@pragma('vm:entry-point')
Future<void> _streamWorker(_StreamWorkerConfig cfg) async {
  final control = ReceivePort();
  cfg.uiPort.send(control.sendPort);
  final pool = <Uint8List>[];
  var allocated = 0;
  var stopped = false;
  Completer<void>? bufferReturned;
  control.listen((msg) {
    if (msg is TransferableTypedData) {
      pool.add(msg.materialize().asUint8List()); // UI 归还的缓冲
      bufferReturned?.complete();
      bufferReturned = null;
    } else if (msg == 'stop') {
      stopped = true;
      bufferReturned?.complete();
      bufferReturned = null;
    }
  });
  final frameBytes = cfg.width * cfg.height * 4;
  final chunks = <List<int>>[];
  var chunksLen = 0;
  Process? process;
  try {
    process = await Process.start(cfg.ffmpeg, [
      '-hide_banner', '-loglevel', 'error',
      if (cfg.startFrame > 0)
        ...['-ss', (cfg.startFrame / cfg.fps).toStringAsFixed(6)],
      '-i', cfg.path,
      '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1',
    ]);
    // stderr 必须排空，否则管道缓冲打满会互相等待。
    process.stderr.drain<void>();
    await for (final chunk in process.stdout) {
      chunks.add(chunk);
      chunksLen += chunk.length;
      while (chunksLen >= frameBytes && !stopped) {
        // 信用背压：没有空闲缓冲就等 UI 归还（ffmpeg 管道自然阻塞）。
        while (pool.isEmpty && allocated >= _kStreamPoolSize && !stopped) {
          bufferReturned = Completer<void>();
          await bufferReturned!.future;
        }
        if (stopped) break;
        final Uint8List frame;
        if (pool.isNotEmpty) {
          frame = pool.removeLast();
        } else {
          allocated++;
          frame = Uint8List(frameBytes);
        }
        var off = 0;
        while (off < frameBytes) {
          final head = chunks.first;
          final take = math.min(head.length, frameBytes - off);
          frame.setRange(off, off + take, head);
          off += take;
          chunksLen -= take;
          if (take == head.length) {
            chunks.removeAt(0);
          } else {
            chunks[0] = head.sublist(take);
          }
        }
        cfg.uiPort.send(TransferableTypedData.fromList([frame]));
      }
      if (stopped) break;
    }
  } catch (e) {
    cfg.uiPort.send(['error', e.toString()]);
  }
  // 杀进程后要等它真正退出（释放文件句柄）再发收尾信号，否则
  // dispose 返回后调用方立刻删除/重开视频文件可能撞到占用
  // （Windows 上句柄释放有延迟，尤为常见）。
  final proc = process;
  if (proc != null) {
    proc.kill();
    await proc.exitCode
        .timeout(const Duration(seconds: 2), onTimeout: () => -1);
  }
  cfg.uiPort.send(null); // EOF / 停止
  control.close();
}
