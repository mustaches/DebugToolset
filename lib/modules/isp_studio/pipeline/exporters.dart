import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'pipeline_runner.dart';

/// Encoders and ffmpeg-based MP4 export for ISP Studio.
///
/// All functions here are pure-Dart / process based so they can run inside
/// background isolates.

/// Encode an RGBA8888 buffer to PNG (lossless).
Uint8List encodePngRgba(Uint8List rgba, int width, int height) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodePng(image);
}

/// compute() 入口：后台 isolate 内执行 [encodePngRgba]。
/// 大图的纯 Dart deflate 编码在 UI isolate 同步执行会阻塞事件循环
/// 数百毫秒，Python 桥接的临时 PNG 一律经此入口在后台编码。
Uint8List encodePngRgbaInIsolate(Map<String, Object?> args) => encodePngRgba(
    args['rgba'] as Uint8List, args['width'] as int, args['height'] as int);

/// Encode an RGBA8888 buffer to JPEG. [quality] 1-100 (100 = best).
/// 色度用 yuv420 二次抽样：JPEG 的标准做法，编码更快、文件更小，
/// 视觉上与 yuv444 几乎无差别。
Uint8List encodeJpgRgba(Uint8List rgba, int width, int height, int quality) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(image,
      quality: quality.clamp(1, 100), chroma: img.JpegChroma.yuv420);
}

/// 用 ffmpeg（mjpeg，yuvj420p）把 RGBA8888 编码为 JPEG。
/// 返回 null 表示失败，调用方回退到 [encodeJpgRgba]（纯 Dart）。
/// [quality] 1-100 映射到 mjpeg 的 q:v 31..2（数值越小质量越高）。
Future<Uint8List?> encodeJpgFfmpeg(
    String ffmpegPath, Uint8List rgba, int width, int height, int quality) {
  return () async {
    final q = (31 - (quality.clamp(1, 100) - 1) * 29 / 99).round();
    // Windows 下相对 exe 路径 CreateProcess 失败，归一化为绝对路径。
  final process = await Process.start(File(ffmpegPath).absolute.path, [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${width}x$height',
      '-i', 'pipe:0',
      '-frames:v', '1', '-pix_fmt', 'yuvj420p', '-q:v', '$q',
      '-f', 'mjpeg', 'pipe:1',
    ]);
    // 并发读写，防止管道缓冲打满互相等待。
    final out = BytesBuilder(copy: false);
    final outDone = process.stdout.forEach(out.add);
    process.stdin.add(rgba);
    await process.stdin.close();
    await outDone;
    final code = await process.exitCode;
    if (code != 0 || out.isEmpty) return null;
    return out.takeBytes();
  }().catchError((_) => null);
}

/// compute() 入口：在后台 isolate 中执行一帧并编码为 JPG/PNG。
/// [msg] = {'chain': List<Map>, 'frameIndex': int, 'format': 'jpg'|'png',
///          'quality': int, 'ffmpegPath': String?}，返回编码后的文件字节。
/// JPG 优先用 ffmpeg（mjpeg）编码，失败/未配置时回退纯 Dart 编码器。
Future<Uint8List> encodeFrameInIsolate(Map<String, Object?> msg) async {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  final frameIndex = msg['frameIndex'] as int;
  final format = msg['format'] as String? ?? 'jpg';
  final quality = msg['quality'] as int? ?? 100;
  final rgba = await runChainFrame(chain, frameIndex);
  final srcParams = chain.first['params'] as Map<String, Object?>;
  final (w, h) =
      await sourceDimensions(chain.first['typeId'] as String, srcParams);
  if (format == 'png') return encodePngRgba(rgba, w, h);
  final ffmpeg = msg['ffmpegPath'] as String?;
  if (ffmpeg != null) {
    final jpg = await encodeJpgFfmpeg(ffmpeg, rgba, w, h, quality);
    if (jpg != null) return jpg;
  }
  return encodeJpgRgba(rgba, w, h, quality);
}

/// Locate an ffmpeg executable.
///
/// Search order: [overridePath] (if non-empty) → `tools/ffmpeg/ffmpeg.exe`
/// relative to the working directory → 同路径相对于可执行文件所在目录
/// （安装版的工作目录不一定是安装目录）→ `ffmpeg` on PATH.
/// 返回值统一归一化为绝对路径（Windows 下 Dart Process 用相对 exe 路径
/// 会 CreateProcess 失败）。
/// Returns null when nothing is found.
Future<String?> findFfmpeg({String overridePath = ''}) async {
  String abs(String path) => File(path).absolute.path;
  if (overridePath.isNotEmpty && await File(overridePath).exists()) {
    return abs(overridePath);
  }
  const bundled = 'tools/ffmpeg/ffmpeg.exe';
  if (await File(bundled).exists()) return abs(bundled);
  final besideExe = p.join(p.dirname(Platform.resolvedExecutable), bundled);
  if (await File(besideExe).exists()) return besideExe;
  try {
    final result = await Process.run(
      Platform.isWindows ? 'where' : 'which',
      ['ffmpeg'],
    );
    if (result.exitCode == 0) {
      final first =
          result.stdout.toString().split(RegExp(r'\r?\n')).first.trim();
      if (first.isNotEmpty && await File(first).exists()) return abs(first);
    }
  } catch (_) {
    // ffmpeg not on PATH
  }
  return null;
}

/// 各编码器的 ffmpeg 参数（纯函数，便于单测）。
/// - x264：libx264 默认预设 + -crf；
/// - x264_fast：veryfast 预设（快约 2.6 倍、文件略大）；
/// - nvenc：NVIDIA GPU 硬件编码，preset p6（质量/速度均衡档）+ -cq
///   （cq 与 crf 同为 0..51 目标质量值，语义近似但不完全等价，直接用
///   节点 CRF 参数映射，注释见 exportMp4）。
List<String> mp4CodecArgs(String encoder, int crf) {
  final q = '${crf.clamp(0, 51)}';
  return switch (encoder) {
    'x264_fast' =>
      ['-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-crf', q],
    'nvenc' =>
      ['-c:v', 'h264_nvenc', '-preset', 'p6', '-pix_fmt', 'yuv420p', '-cq', q],
    _ => ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', q],
  };
}

/// NVENC 可用性探测结果缓存（按 ffmpeg 路径 + 帧尺寸记键：NVENC 对
/// 过小帧尺寸会报 Invalid argument，探测须按实际导出尺寸做）。
final Map<String, bool> _nvencProbeCache = {};

/// 探测本机 h264_nvenc 对指定帧尺寸是否可用（编码器在 ffmpeg 构建里
/// 自带，但运行期才加载 NVIDIA 驱动 DLL——只有真跑一次才知道显卡/驱动
/// 是否可用；且 NVENC 对过小帧尺寸会报 Invalid argument，故探测按实际
/// 导出尺寸做）。用 lavfi 生成 [width]x[height] 测试图试编码几帧到临时
/// mp4（`-f null` 不被该编码器接受，必须落真实文件），exitCode == 0 即可用。
Future<bool> probeNvencEncoder(String ffmpegPath,
    {int width = 320, int height = 180}) async {
  final key = '$ffmpegPath|${width}x$height';
  final cached = _nvencProbeCache[key];
  if (cached != null) return cached;
  final probeFile = File(
      '${Directory.systemTemp.path}/isp_nvenc_probe_${DateTime.now().microsecondsSinceEpoch}.mp4');
  try {
    // Windows 下相对 exe 路径 CreateProcess 失败，归一化为绝对路径。
    final r = await Process.run(File(ffmpegPath).absolute.path, [
      '-hide_banner', '-y',
      '-f', 'lavfi', '-i', 'testsrc=duration=0.2:size=${width}x$height:rate=30',
      '-c:v', 'h264_nvenc', '-pix_fmt', 'yuv420p',
      probeFile.path,
    ]);
    return _nvencProbeCache[key] =
        r.exitCode == 0 && probeFile.lengthSync() > 0;
  } catch (_) {
    return _nvencProbeCache[key] = false;
  } finally {
    if (probeFile.existsSync()) probeFile.delete();
  }
}

/// Export a frame sequence to an H.264 MP4 by piping raw RGBA frames to
/// ffmpeg's stdin.
///
/// [frameProvider] is called with each frame index (0..frameCount-1) and must
/// return that frame as RGBA8888 bytes (width*height*4). Frames are pulled
/// one at a time so multi-frame 4K exports never reside in memory at once.
/// [encoder]：'auto'（默认：先经 [probeNvencEncoder] 探测，可用则
/// h264_nvenc 硬件编码，否则回退 libx264 软件编码）/ 'x264' / 'x264_fast'
/// / 'nvenc'（显式指定 NVIDIA 硬件，探测/失败不自动回退）。
/// NVENC 的 -cq 与 libx264 的 -crf 同为 0..51 目标质量值，语义近似
/// （nvenc 的 cq 是 VBR 目标质量，并非严格等价 crf——同一数值直接用，
/// 用户按观感微调即可）。
/// 返回实际使用的编码器 id（'nvenc' / 'x264' / 'x264_fast'），供导出
/// 完成提示标注「硬件/软件」。
/// Throws [ProcessException]-style [StateError] with a Chinese message on
/// failure.
/// 解析导出编码器：'auto' 经 [probeNvencEncoder] 探测决定（可用则
/// 'nvenc'，否则 'x264'）；显式指定原样返回。分段并行导出在起多个编码
/// 进程前解析一次共用，避免各段重复探测。
Future<String> resolveMp4Encoder(String ffmpegPath, String encoder,
    {required int width, required int height}) async {
  if (encoder != 'auto') return encoder;
  return await probeNvencEncoder(ffmpegPath, width: width, height: height)
      ? 'nvenc'
      : 'x264';
}

/// 起 ffmpeg 编码进程（rawvideo stdin → MP4），返回进程句柄；调用方逐帧
/// 写 stdin、自行 drain stderr（不排空会管道互锁）并收尾
///（close + exitCode）。分段并行导出每段一个进程；单段导出见
/// [exportMp4]。
Future<Process> startMp4Encoder({
  required String ffmpegPath,
  required String outputPath,
  required int width,
  required int height,
  required int fps,
  required int crf,

  /// 已解析的具体编码器（'nvenc'/'x264'/'x264_fast'，见
  /// [resolveMp4Encoder]）。
  required String encoder,
  String inputPixelFormat = 'rgba',
}) {
  final codecArgs = mp4CodecArgs(encoder, crf);
  // Windows 下相对 exe 路径 CreateProcess 失败，归一化为绝对路径。
  return Process.start(File(ffmpegPath).absolute.path, [
    '-y',
    '-f', 'rawvideo',
    '-pix_fmt', inputPixelFormat,
    '-s', '${width}x$height',
    '-r', '$fps',
    '-i', '-',
    ...codecArgs,
    outputPath,
  ]);
}

Future<String> exportMp4({
  required String ffmpegPath,
  required String outputPath,
  required int width,
  required int height,
  required int fps,
  required int crf,
  required int frameCount,
  required Future<Uint8List> Function(int frameIndex) frameProvider,
  String encoder = 'auto',
  void Function(int framesDone, int totalFrames)? onProgress,

  /// 输入像素格式：'rgba'（默认，w*h*4/帧）或 'yuv420p'（I420 平面，
  /// w*h*3/2/帧——GPU 出图直接以 yuv420p 回读喂入时使用，免 ffmpeg
  /// 内部 rgba→yuv420p 的 CPU 转换且管道流量降为 37%）。
  String inputPixelFormat = 'rgba',

  /// 编码器实时输出（stderr 的 frame=/fps=/size=/bitrate=/speed= 进度
  /// 行等，含 \r 覆盖；解析选定的编码器也会经此先行上报）。
  void Function(String chunk)? onOutput,
}) async {
  // 自动模式：先探测后选定。探测只花 1 帧开销，可在帧流开始前决定用哪
  // 套参数——导出帧源是按序单遍拉取的（上游调度队列不可重放），不能
  // 编码到一半换编码器重跑，故回退发生在开始之前而不是中途。
  final useEncoder =
      await resolveMp4Encoder(ffmpegPath, encoder, width: width, height: height);
  onOutput?.call('编码器: $useEncoder（CRF $crf，$width×$height @${fps}fps）\n');
  final process = await startMp4Encoder(
      ffmpegPath: ffmpegPath,
      outputPath: outputPath,
      width: width,
      height: height,
      fps: fps,
      crf: crf,
      encoder: useEncoder,
      inputPixelFormat: inputPixelFormat);
  final stderrBuf = StringBuffer();
  final stderrDone = process.stderr
      .transform(const SystemEncoding().decoder)
      .listen((chunk) {
        stderrBuf.write(chunk);
        onOutput?.call(chunk);
      })
      .asFuture<void>();

  try {
    for (var i = 0; i < frameCount; i++) {
      final frame = await frameProvider(i);
      process.stdin.add(frame);
      await process.stdin.flush();
      onProgress?.call(i + 1, frameCount);
    }
    await process.stdin.close();
  } catch (e) {
    process.kill();
    rethrow;
  }

  final exitCode = await process.exitCode;
  await stderrDone;
  if (exitCode != 0) {
    throw StateError('ffmpeg 编码失败 (exit $exitCode):\n$stderrBuf');
  }
  return useEncoder;
}
