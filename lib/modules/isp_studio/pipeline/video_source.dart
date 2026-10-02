/// Video 源节点的视频帧解码：经 ffmpeg 逐帧抽取（MP4/MKV/AVI/MOV 等，
/// 取决于 ffmpeg 构建支持的封装与编码）。
///
/// 纯 Dart + 外部 ffmpeg 进程（[findFfmpeg] 定位），可在后台 isolate
/// 中运行。每帧独立起进程：`-ss` 在 `-i` 前做输入跳转（关键帧定位 +
/// accurate_seek 精确到目标时刻），开销与关键帧间距成正比而非全片。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;

import 'exporters.dart' show findFfmpeg;
import 'ffmpeg_pipe_win.dart';

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

  /// 是否全范围（pc/jpeg）。缺省为 limited（tv，视频的常见情形）；
  /// yuv420p 直出流程由 GPU shader / 馈源 LUT 按此标志做范围扩展。
  final bool fullRange;

  /// YUV→RGB 色彩矩阵（0=BT.601，1=BT.709，2=BT.2020；缺省 0）。
  /// 解析自 Video: 行的色彩元数据（bt2020/bt709 关键字，皆无则按
  /// BT.601——与 yuv_planes.frag 的历史默认一致）。yuv420p 平面直出
  /// 流程由 GPU shader 按此选择上色矩阵（ffmpeg 的 rgba 转换尊重帧
  /// 元数据，平面路径须保持同口径）。
  ///
  /// **口径：VideoInfo 描述「交付帧」的格式而非容器元数据**——HDR
  /// 片源解码时统一经 zscale+tonemap 映射为 BT.709 SDR 8bit 交付
  /// （见 [kHdrTonemapFilter]），故 HDR 时此字段恒报 1（BT.709），
  /// 下游（yuv_planes.frag / 仪器馈源 / ffmpeg rgba 转换）全部按
  /// 709 上色即与交付帧一致。
  final int colorMatrix;

  /// 色彩传递特性（0=SDR，1=PQ/smpte2084，2=HLG/arib-std-b67）：
  /// 解析自 Video: 行的 transfer 元数据
  /// （如 `yuv420p10le(tv, bt2020nc/bt2020/smpte2084)`）。
  final int colorTransfer;

  /// HDR 片源（PQ 或 HLG）：解码侧统一 tonemap 为 BT.709 SDR 8bit
  /// 交付（见 [kHdrTonemapFilter] 与 [buildDecodeVf]）。
  bool get isHdr => colorTransfer != 0;

  const VideoInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.frameCount,
    required this.hasAudio,
    this.fullRange = false,
    this.colorMatrix = 0,
    this.colorTransfer = 0,
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

  final transfer = parseColorTransfer(text);
  // 交付帧口径：HDR 片源解码时统一 tonemap 为 BT.709 SDR 8bit tv
  // 交付，故 colorMatrix 报 709、fullRange 报 false（无论容器元数据）；
  // SDR 片源按容器元数据。
  final (matrix, fullRange) = deliveredColorFormat(transfer,
      parseColorMatrix(text), RegExp(r'Color Range:\s*pc').hasMatch(text));
  final info = VideoInfo(
      width: width,
      height: height,
      fps: fps,
      frameCount: frameCount,
      hasAudio: RegExp(r'Stream.*Audio:').hasMatch(text),
      fullRange: fullRange,
      colorMatrix: matrix,
      colorTransfer: transfer);
  _infoCache[key] = info;
  return info;
}

/// 从 `ffmpeg -i` 横幅解析 YUV→RGB 色彩矩阵：Video: 行含 `bt2020` →
/// 2（BT.2020），含 `bt709` → 1（BT.709），否则 0（BT.601——未标注
/// 时的惯例默认，与 yuv_planes.frag 的历史行为一致）。
int parseColorMatrix(String text) {
  final line = RegExp('Video:[^\\n]*').firstMatch(text)?.group(0) ?? '';
  if (line.contains('bt2020')) return 2;
  if (line.contains('bt709')) return 1;
  return 0;
}

/// 从 `ffmpeg -i` 横幅解析色彩传递特性：Video: 行含 `smpte2084` →
/// 1（PQ），含 `arib-std-b67` → 2（HLG），否则 0（SDR）。
int parseColorTransfer(String text) {
  final line = RegExp('Video:[^\\n]*').firstMatch(text)?.group(0) ?? '';
  if (line.contains('smpte2084')) return 1;
  if (line.contains('arib-std-b67')) return 2;
  return 0;
}

/// 交付帧口径（VideoInfo 描述交付帧而非容器元数据）：HDR（[transfer]
/// ≠ 0）片源解码时统一经 [kHdrTonemapFilter] 映射为 BT.709 SDR 8bit
/// tv 交付，故 colorMatrix 恒报 1（BT.709）、fullRange 恒报 false；
/// SDR 片源按容器元数据原样返回。
(int colorMatrix, bool fullRange) deliveredColorFormat(
        int transfer, int matrix, bool fullRange) =>
    transfer != 0 ? (1, false) : (matrix, fullRange);

/// HDR→SDR 色调映射滤镜链：zscale 线性化（npl=100 标称峰值亮度）→
/// hable tonemap（desat=0）→ 重标定为 BT.709 SDR tv → yuv420p 8bit。
/// PQ（smpte2084）与 HLG（arib-std-b67）走同一链（zscale 按帧元数据
/// 识别输入 transfer）。内置 ffmpeg（gyan full build）含 zscale/
/// tonemap；实测 4K60 片源 ~55fps（8 线程，0.9x 实时）。
const String kHdrTonemapFilter = 'zscale=transfer=linear:npl=100,'
    'tonemap=hable:desat=0,'
    'zscale=transfer=bt709:primaries=bt709:matrix=bt709:range=tv,'
    'format=yuv420p';

/// 解码 -vf 滤镜链构造（纯函数，便于单测）：
/// - [isHdr]（BT.2020 PQ/HLG 片源）且 [toneMapHdr] 时前置
///   [kHdrTonemapFilter]：交付 BT.709 SDR 8bit（后续 scale/范围扩展/
///   rgba 转换都在 SDR 域进行）。
/// - [toneMapHdr] = false（预览节点的 HDR/SDR 切换选 SDR 时）：HDR
///   片源按 SDR 口径直解（不插 tonemap——发灰原样，供用户对比），
///   返回形态与 SDR 零改动红线一致；SDR 片源忽略该参数。
/// - SDR 片源链零改动（回归红线）。
/// - yuv420p 平面直出 SDR（或 HDR 直解）时无滤镜（解码器原生输出）。
String? buildDecodeVf({
  required String pixelFormat,
  required int downsampleFactor,
  required int outWidth,
  required int outHeight,
  required bool isHdr,
  bool toneMapHdr = true,
}) {
  final tm = isHdr && toneMapHdr;
  final hdr = tm ? '$kHdrTonemapFilter,' : '';
  return switch (pixelFormat) {
    'yuv444p' => downsampleFactor > 1
        ? '${hdr}scale=$outWidth:$outHeight:out_range=pc'
        : '${hdr}scale=out_range=pc',
    'yuv420p' => tm ? kHdrTonemapFilter : null,
    _ => downsampleFactor > 1
        ? '${hdr}scale=$outWidth:$outHeight'
        : (tm ? kHdrTonemapFilter : null),
  };
}

/// 解码第 [frameIndex] 帧为 16 位量级的交织 RGB（长度 w*h*3），
/// 返回 (数据, 宽, 高)。8 位样本按比例放大到 [maxValue]。
/// 帧越界或解码失败时抛 [StateError]。
Future<(Uint16List, int, int)> decodeVideoFrameToRgb16(
  String path,
  int frameIndex, {
  required int maxValue,
  String ffmpegPath = '',

  /// 预览 HDR/SDR 切换（false = HDR 片源 SDR 直解对比）；缺省 true
  /// （映射）。导出链不传该参数，恒映射。
  bool toneMapHdr = true,
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
    // HDR 片源：tonemap 为 BT.709 SDR 8bit 后再转 rgba（预览选 SDR
    // 直解时跳过）。
    if (info.isHdr && toneMapHdr) ...['-vf', kHdrTonemapFilter],
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

/// 流式解码命令参数（纯函数，便于单测）。
/// [pixelFormat]：'rgba'（w*h*4/帧）或 'yuv420p'（w*h*3/2/帧，4K 下
/// 流量为 37%，供 GPU 420 直传）；[hwaccel] 为空不加硬件加速参数；
/// [isHdr] 时插入 zscale+tonemap 链（HDR→BT.709 SDR 8bit 交付）。
List<String> videoDecodeArgs({
  required String pixelFormat,
  String hwaccel = '',
  double startSec = 0,
  bool isHdr = false,
}) {
  return [
    '-hide_banner', '-loglevel', 'error',
    if (hwaccel.isNotEmpty) ...['-hwaccel', hwaccel],
    if (startSec > 0) ...['-ss', startSec.toStringAsFixed(6)],
    '-i', '__PATH__',
    if (isHdr) ...['-vf', kHdrTonemapFilter],
    '-f', 'rawvideo', '-pix_fmt', pixelFormat, 'pipe:1',
  ];
}

/// 顺序流式解码：单条 ffmpeg 进程连续吐帧流（rawvideo pipe），替代
/// 逐帧 seek 起进程。仅适用于顺序消费场景（视频导出/播放即此形态）。
///
/// [pixelFormat]：'rgba'（RGBA8888，w*h*4/帧）或 'yuv420p'（I420 三
/// 平面，w*h*3/2/帧——4K 下流量为 37%，供 GPU 420 直传
/// （isp_yuv420p_to_rgb16 在 GPU 上做 CSC，CPU 零逐像素工作）；
/// [hwaccel]：硬件解码器（Windows 实测 d3d11va 对 10bit 4:2:2 HEVC 与
/// h264 8bit 均可用；cuvid 不支持 4:2:2 色度格式）。探测/回退由调用方
/// 决定（见 probeHwDecode），本函数不自动回退。
/// 产出为异步生成器：每次 yield 一帧；中途解码失败抛 [StateError]
/// （进程非零退出）。
Stream<Uint8List> decodeVideoStreamRgba(
  String path, {
  required int width,
  required int height,
  String ffmpegPath = '',

  /// 起始秒（精确寻址：先关键帧寻址再解码丢弃到该时刻；0 = 从头）。
  double startSec = 0,
  String pixelFormat = 'rgba',
  String hwaccel = '',

  /// true = 加 `-fps_mode passthrough`（每包恰好一帧，禁掉默认 CFR
  /// 补/丢帧；校验/分段等要求解码序列与包一一对应的场景用）。
  bool passthrough = false,

  /// 解码进程句柄回调：调用方持有后可在消费中止时 kill（流自然消费完
  /// 时进程自行退出，无需处理）。
  void Function(Process process)? onProcess,
}) async* {
  final ffmpeg = (await findFfmpeg(overridePath: ffmpegPath))!;
  final frameBytes = pixelFormat == 'yuv420p'
      ? width * height * 3 ~/ 2
      : width * height * 4;
  // HDR 片源统一 tonemap（videoFileInfo 有缓存，几乎零开销）。
  final isHdr = (await videoFileInfo(path, ffmpegPath: ffmpegPath)).isHdr;
  final args = videoDecodeArgs(
      pixelFormat: pixelFormat,
      hwaccel: hwaccel,
      startSec: startSec,
      isHdr: isHdr);
  args[args.indexOf('__PATH__')] = path;
  if (passthrough) {
    args.insert(args.indexOf('-f'), '-fps_mode');
    args.insert(args.indexOf('-f'), 'passthrough');
  }
  final process = await Process.start(ffmpeg, args);
  onProcess?.call(process);
  // stderr 必须排空，否则管道缓冲打满会互相等待。
  final errBuf = StringBuffer();
  final errDone = process.stderr
      .transform(const SystemEncoding().decoder)
      .listen(errBuf.write)
      .asFuture<void>();
  final pending = BytesBuilder(copy: false);
  await for (final chunk in process.stdout) {
    pending.add(chunk);
    while (pending.length >= frameBytes) {
      final all = pending.takeBytes();
      yield Uint8List.fromList(all.sublist(0, frameBytes));
      if (all.length > frameBytes) pending.add(all.sublist(frameBytes));
    }
  }
  await errDone;
  final code = await process.exitCode;
  if (code != 0) {
    throw StateError('ffmpeg 流式解码失败 (exit $code): $path\n$errBuf');
  }
}

/// 硬件解码可用性探测：按实际片源/尺寸/输出格式各解码 2 帧，能出帧
/// 即返回 [hwaccel]（可用），否则返回空串（调用方回退软解）。
/// Windows 上 d3d11va 对 10bit 4:2:2 HEVC 与 h264 8bit 均实测可用
/// （cuvid 不支持 4:2:2 色度格式，故统一用 d3d11va）。
Future<String> probeHwDecode(
  String ffmpegPath,
  String videoPath, {
  required int width,
  required int height,
  String pixelFormat = 'rgba',
  String hwaccel = 'd3d11va',
  double startSec = 0,
}) async {
  Process? proc;
  try {
    var got = 0;
    await for (final _ in decodeVideoStreamRgba(videoPath,
        width: width,
        height: height,
        ffmpegPath: ffmpegPath,
        startSec: startSec,
        pixelFormat: pixelFormat,
        hwaccel: hwaccel,
        onProcess: (p) => proc = p)) {
      if (++got >= 2) break;
    }
    return got >= 1 ? hwaccel : '';
  } catch (_) {
    return '';
  } finally {
    // 取够帧数即中断丢弃，解码进程可能仍在运行——主动 kill 释放源文件。
    proc?.kill();
  }
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
/// 解码优先走 GPU 硬解（`-hwaccel cuda`，显式指定 NVIDIA NVDEC；
/// 比 `-hwaccel auto` 更确定——auto 可能选中 d3d11va/qsv；cuvid 作为
/// hwaccel 名已在新版 ffmpeg 废弃；可用 [VideoFrameStream.start] 的
/// hwaccel 参数覆盖，如 4:2:2 片源传 d3d11va）；硬解初始化失败
/// （无 N 卡/驱动）时自动回退软件解码（ffmpeg 软解本身按帧多线程，
/// 吃满多核）。
///
/// [pixelFormat] 为 'yuv444p' 时直接输出平面 YUV444（全范围），
/// 供 YUV 流程免去 RGBA→RGB16→YUV 两道逐像素转换。
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
  VideoFrameStream._(this.info, this.nextIndex, this.pixelFormat,
      this.outWidth, this.outHeight);

  /// 视频元信息（尺寸/帧率/帧数）。
  final VideoInfo info;

  /// 输出像素格式：'rgba'（RGBA8888 交织，w*h*4 字节/帧）、
  /// 'yuv444p'（全范围平面 YUV444，w*h*3）或 'yuv420p'（原始范围
  /// 平面 YUV420，w*h*3/2，GPU 平面预览路径专用：解码器原生输出，
  /// 零转换；范围扩展由 shader/馈源 LUT 完成）。
  final String pixelFormat;

  /// 出帧尺寸（worker 侧按 2 的幂步长降采样后的宽高；不降采样时与
  /// [info] 一致）。高分辨率源只向 UI 送小工作帧，端口流量与 UI
  /// 堆压力下降一个数量级。
  final int outWidth;
  final int outHeight;

  /// 下一帧序号（从 startFrame 起随 [next] 递增）。
  int nextIndex;

  Isolate? _isolate;
  SendPort? _workerPort;
  StreamSubscription<Object?>? _sub;
  final Queue<Uint8List> _frames = Queue();
  // Windows 原生缓冲路径（FfmpegRawPipeWin）：帧为原生堆内存视图，
  // 归还时按视图找回地址传指针（零拷贝）。
  final _nativeAddr = Expando<int>();
  Completer<void>? _notEmpty;
  String? _error;
  var _eof = false;
  var _disposed = false;

  int get _frameBytes {
    final px = outWidth * outHeight;
    return switch (pixelFormat) {
      'yuv444p' => px * 3,
      'yuv420p' => px * 3 ~/ 2,
      _ => px * 4,
    };
  }

  /// 从 [startFrame] 起顺序解码（-ss 输入跳转到最近关键帧再精确到
  /// 目标时刻，之后连续解码不回退）。[pixelFormat] 见同名字段。
  /// [maxWorkingHeight] > 0 时由解码 worker 把出帧步长降采样到该高度
  /// 以内（因子取 2 的幂），高速预览免 UI 侧全帧搬运与降采样。
  /// [hwaccel]：首趟解码的 -hwaccel 值（默认 'cuda'，即 NVDEC；播放
  /// 路径历史行为）。4:2:2 色度的片源 cuda 不支持（会静默退为软解），
  /// 导出等场景应先经 probeHwDecode 探测（d3d11va 对 4:2:2 10bit
  /// 可用）后把探测结果传入；空串 = 直接软解。首趟一帧未出即失败时
  /// 仍自动回退软解重试。
  /// [maxFrames] > 0 时 worker 送满该帧数即按 EOF 收尾（分段导出每段
  /// 已知确切帧数：worker 送完最后一帧后等 UI 归还完在途缓冲再退出，
  /// 避免 worker 超前解码把信用额度耗尽、段尾卡死在背压等待）。
  /// [skipFrames] > 0 时 worker 丢弃解码出的前 N 帧（不计入
  /// [maxFrames]；分段导出的段重叠区跳过用，worker 内完成不占信用
  /// 额度）。[passthrough] 为 true 时加 `-fps_mode passthrough`
  /// （每包恰好出一帧，禁掉 ffmpeg 默认的 CFR 补/丢帧——VFR 片源
  /// 分段导出要求各段解码序列与包一一对应）。[concatListPath] 非空
  /// 时输入改用 concat demuxer 列表文件（`-f concat -safe 0`；
  /// [path] 仍用于探测尺寸/帧率，startFrame 须为 0）。
  static Future<VideoFrameStream> start(String path, int startFrame,
      {String ffmpegPath = '',
      String pixelFormat = 'rgba',
      int maxWorkingHeight = 0,
      String hwaccel = 'cuda',
      int maxFrames = 0,
      int skipFrames = 0,
      bool passthrough = false,
      String concatListPath = '',

      /// 预览 HDR/SDR 切换（false = HDR 片源 SDR 直解对比）；缺省 true
      /// （映射）。导出路径不传，恒映射。
      bool toneMapHdr = true}) async {
    final info = await videoFileInfo(path, ffmpegPath: ffmpegPath);
    if (startFrame < 0 || startFrame >= info.frameCount) {
      throw StateError('帧 $startFrame 超出视频范围（共 ${info.frameCount} 帧）');
    }
    final ffmpeg = (await findFfmpeg(overridePath: ffmpegPath))!;
    var factor = 1;
    if (maxWorkingHeight > 0 && pixelFormat != 'yuv420p') {
      while (info.height ~/ (factor * 2) > 0 &&
          info.height ~/ factor > maxWorkingHeight) {
        factor *= 2;
      }
    }
    final stream = VideoFrameStream._(info, startFrame, pixelFormat,
        info.width ~/ factor, info.height ~/ factor);
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
            info.width, info.height, info.fps, pixelFormat, factor, hwaccel,
            maxFrames, skipFrames, passthrough, concatListPath, info.isHdr,
            toneMapHdr));
    await ready.future;
    return stream;
  }

  void _onMessage(Object? msg) {
    if (msg is int) {
      // Windows 原生缓冲路径：指针 → 原生内存视图（零拷贝）
      final view =
          ffi.Pointer<ffi.Uint8>.fromAddress(msg).asTypedList(_frameBytes);
      _nativeAddr[view] = msg;
      _frames.add(view);
    } else if (msg is TransferableTypedData) {
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

  /// 当前已缓冲待消费的帧数（播放起步预读闸用：解码器管线填充期
  /// 交付是"先干后涌"的，起步不等够帧会把等待暴露成丢帧停滞）。
  int get bufferedCount => _frames.length;

  /// 是否已到 EOF（或解码失败/已释放）：预读闸据此提前放行。
  bool get isDrained => _eof || _disposed || _error != null;

  /// 取下一帧（RGBA8888 w*h*4 或 yuv444p 平面 w*h*3，见 [pixelFormat]）；
  /// EOF 后无帧返回 null。解码失败抛 [StateError]。
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
  /// 原生缓冲（Windows 快路径）按地址归还，Dart 堆缓冲按
  /// TransferableTypedData 归还。
  void recycle(Uint8List frame) {
    if (_disposed || frame.length != _frameBytes) return;
    final addr = _nativeAddr[frame];
    if (addr != null) {
      _nativeAddr[frame] = null; // 解除关联，防重复归还
      _workerPort?.send(addr);
      return;
    }
    _workerPort?.send(TransferableTypedData.fromList([frame]));
  }

  /// 终止解码：通知 worker 杀 ffmpeg 进程并等其收尾，再结束 isolate。
  Future<void> dispose() async {
    if (_disposed) return;
    // 队列里的帧先归还（Windows 原生缓冲须回到 worker 的池才能释放），
    // 再置 _disposed（recycle 在 _disposed 后是空操作）。
    while (_frames.isNotEmpty) {
      recycle(_frames.removeFirst());
    }
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

  /// 'rgba' | 'yuv444p'
  final String pixelFormat;

  /// 出帧降采样因子（2 的幂；1 = 不降采样）。
  final int downsampleFactor;

  /// 首趟解码的 -hwaccel 值（空串 = 直接软解；见 [VideoFrameStream.start]）。
  final String hwaccel;

  /// 送满该帧数即按 EOF 收尾（0 = 不限；见 [VideoFrameStream.start]）。
  final int maxFrames;

  /// 解码后先丢弃的帧数（不占信用额度；见 [VideoFrameStream.start]）。
  final int skipFrames;

  /// true = 输出加 `-fps_mode passthrough`（每包一帧，禁 CFR 补/丢帧）。
  final bool passthrough;

  /// 非空时输入改用 concat demuxer 列表（startFrame 须为 0）。
  final String concatListPath;

  /// HDR 片源（PQ/HLG）：解码 -vf 前置 zscale+tonemap 链（见
  /// [buildDecodeVf]），交付 BT.709 SDR 8bit。
  final bool isHdr;

  /// 预览 HDR/SDR 切换：false 时 HDR 片源按 SDR 直解（不插 tonemap）。
  final bool toneMapHdr;

  const _StreamWorkerConfig(this.uiPort, this.ffmpeg, this.path,
      this.startFrame, this.width, this.height, this.fps, this.pixelFormat,
      this.downsampleFactor, this.hwaccel, this.maxFrames, this.skipFrames,
      this.passthrough, this.concatListPath, this.isHdr, this.toneMapHdr);
}

/// worker 同时最多持有的帧缓冲数（信用额度；1080p ≈ 130MB）。
const int _kStreamPoolSize = 16;

/// 帧流 worker（独立 isolate）：起 ffmpeg 进程，drain stdout 切片整帧，
/// 经 TransferableTypedData 发给 UI；缓冲用完后等 UI 归还（背压）。
/// 收到 'stop' 或进程结束：发 null 收尾。异常发 ['error', 消息] 后收尾。
/// 首趟按 [VideoFrameStream.start] 的 hwaccel 参数硬解（默认 cuda）；
/// 一帧未出即失败时回退软件解码重试。
///
/// Windows 走 [FfmpegRawPipeWin] 快路径：CreatePipe 大缓冲 + CreateProcessW
/// + ReadFile 整帧阻塞读——dart:io 的 Process.stdout 按 ~64KB 块经事件
/// 循环分发（4K yuv420p ≈ 379 事件/帧、~30ms/帧，吞吐锁死 ~33fps），
/// 而整帧 ReadFile 单帧仅数次系统调用；帧落在原生堆（calloc），跨
/// isolate 只传指针（int），归还同样传指针，全程零字节拷贝。
@pragma('vm:entry-point')
Future<void> _streamWorker(_StreamWorkerConfig cfg) async {
  final control = ReceivePort();
  cfg.uiPort.send(control.sendPort);
  final pool = <Uint8List>[];
  final nativePool = <int>[]; // Windows 快路径：原生缓冲地址池
  var allocated = 0;
  var stopped = false;
  Completer<void>? bufferReturned;
  control.listen((msg) {
    if (msg is TransferableTypedData) {
      pool.add(msg.materialize().asUint8List()); // UI 归还的缓冲
      bufferReturned?.complete();
      bufferReturned = null;
    } else if (msg is int) {
      nativePool.add(msg); // UI 归还的原生缓冲地址
      bufferReturned?.complete();
      bufferReturned = null;
    } else if (msg == 'stop') {
      stopped = true;
      bufferReturned?.complete();
      bufferReturned = null;
    }
  });
  final is444 = cfg.pixelFormat == 'yuv444p';
  final is420 = cfg.pixelFormat == 'yuv420p';
  final factor = cfg.downsampleFactor;
  final outW = cfg.width ~/ factor;
  final outH = cfg.height ~/ factor;
  final outPx = outW * outH;
  final frameBytes = is420 ? (outPx * 3 ~/ 2) : outPx * (is444 ? 3 : 4);
  // 降采样由 ffmpeg 的 scale 滤镜完成（C 实现，远快于 Dart 逐像素
  // 抽样，且管道只流小帧）。yuv420p 是解码器原生输出（GPU 平面预览
  // 专用）：SDR 片源不做任何滤镜转换，limited range 扩展由 shader/
  // 馈源完成；HDR 片源（PQ/HLG）则必须前置 zscale+tonemap 链
  // （映射为 BT.709 SDR 8bit 交付，否则下游按 SDR 上色发灰发暗）。
  final vf = buildDecodeVf(
      pixelFormat: cfg.pixelFormat,
      downsampleFactor: factor,
      outWidth: outW,
      outHeight: outH,
      isHdr: cfg.isHdr,
      toneMapHdr: cfg.toneMapHdr);

  /// 单趟解码：返回 (送出的帧数, 错误消息)。进程出问题但已送出过帧时
  /// 按 EOF 处理（错误为 null），避免后半段已播的帧被误判为失败。
  Future<(int, String?)> runPass(bool useHwaccel) async {
    final chunks = <List<int>>[];
    var chunksLen = 0;
    var framesSent = 0;
    var framesSeen = 0; // 含被 skipFrames 丢弃的（重试时随 pass 重置）
    Process? process;
    try {
      process = await Process.start(cfg.ffmpeg, [
        '-hide_banner', '-loglevel', 'error',
        // 解码/滤镜线程封顶：默认 auto 按逻辑核数开线程，112 核机上
        // 软解会以百线程爆发式占满全核，饿死栅格线程/DWM（4K 播放
        // 栅格段实测被拖到 ~19ms/帧）；吞吐仍数倍于实时需求。
        '-threads', '8', '-filter_threads', '8',
        // GPU 硬解：ffmpeg 自动选取可用设备并在输出系统内存帧时
        // 自动插入 hwdownload + 格式转换。
        if (useHwaccel && cfg.hwaccel.isNotEmpty)
          ...['-hwaccel', cfg.hwaccel],
        if (cfg.concatListPath.isNotEmpty)
          ...['-f', 'concat', '-safe', '0', '-i', cfg.concatListPath]
        else ...[
          if (cfg.startFrame > 0)
            ...['-ss', (cfg.startFrame / cfg.fps).toStringAsFixed(6)],
          '-i', cfg.path,
        ],
        // 分段导出：每包一帧，禁掉默认 CFR 补/丢帧（VFR 精确分段前提）。
        if (cfg.passthrough) ...['-fps_mode', 'passthrough'],
        // YUV444 直出时把视频的 limited range 扩展为全范围（与 RGBA
        // 路径 ffmpeg 自动做的 mpeg→pc 扩展一致），供下游按
        // 全范围 BT.601 处理；降采样时顺带缩放到工作分辨率。
        if (vf != null) ...['-vf', vf],
        '-f', 'rawvideo',
        '-pix_fmt', is444 ? 'yuv444p' : (is420 ? 'yuv420p' : 'rgba'),
        'pipe:1',
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
          if (framesSeen < cfg.skipFrames) {
            // 重叠区跳帧：直接还池复用，不占信用额度。
            framesSeen++;
            pool.add(frame);
            continue;
          }
          cfg.uiPort.send(TransferableTypedData.fromList([frame]));
          framesSent++;
          if (cfg.maxFrames > 0 && framesSent >= cfg.maxFrames) {
            return (framesSent, null);
          }
        }
        if (stopped) break;
      }
      final code = await process.exitCode;
      if (code != 0 && framesSent == 0 && !stopped) {
        return (0, 'ffmpeg 解码失败 (exit $code): ${cfg.path}');
      }
      return (framesSent, null);
    } catch (e) {
      return (framesSent, e.toString());
    } finally {
      // 杀进程后要等它真正退出（释放文件句柄）再继续，否则 dispose
      // 返回后调用方立刻删除/重开视频文件可能撞到占用
      // （Windows 上句柄释放有延迟，尤为常见）。
      final proc = process;
      if (proc != null) {
        proc.kill();
        await proc.exitCode
            .timeout(const Duration(seconds: 2), onTimeout: () => -1);
      }
    }
  }

  /// Windows 快路径单趟解码：FFI 大缓冲管道 + ReadFile 整帧读 +
  /// 原生堆缓冲池（跨 isolate 传指针零拷贝）。语义与 [runPass] 一致。
  Future<(int, String?)> runPassWin(bool useHwaccel) async {
    final pipe = FfmpegRawPipeWin();
    var framesSent = 0;
    var framesSeen = 0; // 含被 skipFrames 丢弃的（重试时随 pass 重置）
    try {
      pipe.start(cfg.ffmpeg, [
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        // 解码/滤镜线程封顶（与上行 Process 路径同口径）。
        '-threads', '8', '-filter_threads', '8',
        if (useHwaccel && cfg.hwaccel.isNotEmpty)
          ...['-hwaccel', cfg.hwaccel],
        if (cfg.concatListPath.isNotEmpty)
          ...['-f', 'concat', '-safe', '0', '-i', cfg.concatListPath]
        else ...[
          if (cfg.startFrame > 0)
            ...['-ss', (cfg.startFrame / cfg.fps).toStringAsFixed(6)],
          '-i', cfg.path,
        ],
        if (cfg.passthrough) ...['-fps_mode', 'passthrough'],
        if (vf != null) ...['-vf', vf],
        '-f', 'rawvideo',
        '-pix_fmt', is444 ? 'yuv444p' : (is420 ? 'yuv420p' : 'rgba'),
        'pipe:1',
      ], frameBytes);
      while (!stopped) {
        // 每帧让出一次事件循环：'stop'/缓冲归还消息才有机会被处理——
        // ReadFile 是阻塞式 FFI 调用，不让出的话停止信号要到 EOF 才生效
        // （ffmpeg 进程滞留导致视频文件删除时占用）。
        await Future<void>.delayed(Duration.zero);
        // 信用背压：没有空闲原生缓冲就等 UI 归还（语义同 dart:io 路径）
        while (nativePool.isEmpty &&
            allocated >= _kStreamPoolSize &&
            !stopped) {
          bufferReturned = Completer<void>();
          await bufferReturned!.future;
        }
        if (stopped) break;
        final ffi.Pointer<ffi.Uint8> buf;
        if (nativePool.isNotEmpty) {
          buf = ffi.Pointer<ffi.Uint8>.fromAddress(nativePool.removeLast());
        } else {
          allocated++;
          buf = pkgffi.calloc<ffi.Uint8>(frameBytes);
        }
        final n = pipe.readInto(buf, frameBytes);
        if (n < frameBytes) {
          pkgffi.calloc.free(buf); // 短读/EOF：回收未用缓冲
          break;
        }
        if (framesSeen < cfg.skipFrames) {
          // 重叠区跳帧：地址直接还池复用，不占信用额度。
          framesSeen++;
          nativePool.add(buf.address);
          continue;
        }
        cfg.uiPort.send(buf.address); // 指针即帧，零拷贝
        framesSent++;
        if (cfg.maxFrames > 0 && framesSent >= cfg.maxFrames) {
          return (framesSent, null);
        }
      }
      if (framesSent == 0 && !stopped) {
        return (0, 'ffmpeg 解码失败: ${cfg.path}');
      }
      return (framesSent, null);
    } catch (e) {
      return (framesSent, e.toString());
    } finally {
      pipe.stop();
      // 释放空闲原生缓冲（仍在 UI 侧在途的随流程结束自然结束，
      // UI 侧 dispose 前会先把队列里的帧归还回来）。
      for (final addr in nativePool) {
        pkgffi.calloc.free(ffi.Pointer<ffi.Uint8>.fromAddress(addr));
      }
      nativePool.clear();
    }
  }

  // 对照开关：--dart-define=NATIVE_PIPE=false 时强制走 dart:io 路径（排障用）。
  final useNativePipe =
      bool.fromEnvironment('NATIVE_PIPE', defaultValue: true) &&
          FfmpegRawPipeWin.supported;
  var (sent, error) =
      useNativePipe ? await runPassWin(true) : await runPass(true);
  if (sent == 0 && error != null && !stopped) {
    // 硬解初始化失败（无可用 GPU/驱动）：回退软件解码重试。
    (sent, error) =
        useNativePipe ? await runPassWin(false) : await runPass(false);
  }
  if (error != null && !stopped) {
    cfg.uiPort.send(['error', error]);
  }
  // 等 UI 归还在途缓冲（maxFrames 收尾时 worker 先于 UI 消费完退出，
  // 不等着 isolate 一杀了之会让在途原生缓冲泄漏，每段最多 ~200MB）；
  // 'stop' 或超时放弃——未归还的缓冲随 isolate 退出泄漏（与既有行为
  // 一致，不会 use-after-free：只有已归还进池的才被释放）。
  if (!stopped) {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (allocated > nativePool.length + pool.length &&
        !stopped &&
        DateTime.now().isBefore(deadline)) {
      bufferReturned = Completer<void>();
      await bufferReturned!.future
          .timeout(const Duration(milliseconds: 200), onTimeout: () {});
    }
    // 等待期间归还进池的原生缓冲在此释放（runPassWin 的 finally 只
    // 覆盖到它返回时点）。
    for (final addr in nativePool) {
      pkgffi.calloc.free(ffi.Pointer<ffi.Uint8>.fromAddress(addr));
    }
    nativePool.clear();
  }
  cfg.uiPort.send(null); // EOF / 停止
  control.close();
}
