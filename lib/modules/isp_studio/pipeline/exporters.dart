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
    final process = await Process.start(ffmpegPath, [
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
/// Returns null when nothing is found.
Future<String?> findFfmpeg({String overridePath = ''}) async {
  if (overridePath.isNotEmpty && await File(overridePath).exists()) {
    return overridePath;
  }
  const bundled = 'tools/ffmpeg/ffmpeg.exe';
  if (await File(bundled).exists()) return bundled;
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
      if (first.isNotEmpty && await File(first).exists()) return first;
    }
  } catch (_) {
    // ffmpeg not on PATH
  }
  return null;
}

/// Export a frame sequence to an H.264 MP4 by piping raw RGBA frames to
/// ffmpeg's stdin.
///
/// [frameProvider] is called with each frame index (0..frameCount-1) and must
/// return that frame as RGBA8888 bytes (width*height*4). Frames are pulled
/// one at a time so multi-frame 4K exports never reside in memory at once.
/// [encoder]：'x264'（libx264 默认预设）/ 'x264_fast'（veryfast 预设，快约
/// 2.6 倍、文件略大）/ 'nvenc'（NVIDIA GPU，用 -cq 代替 -crf）。
/// Throws [ProcessException]-style [StateError] with a Chinese message on
/// failure.
Future<void> exportMp4({
  required String ffmpegPath,
  required String outputPath,
  required int width,
  required int height,
  required int fps,
  required int crf,
  required int frameCount,
  required Future<Uint8List> Function(int frameIndex) frameProvider,
  String encoder = 'x264',
  void Function(int framesDone, int totalFrames)? onProgress,
}) async {
  final codecArgs = switch (encoder) {
    'x264_fast' => [
        '-c:v', 'libx264', '-preset', 'veryfast',
        '-pix_fmt', 'yuv420p', '-crf', '${crf.clamp(0, 51)}',
      ],
    'nvenc' => [
        '-c:v', 'h264_nvenc', '-pix_fmt', 'yuv420p', '-cq', '${crf.clamp(0, 51)}',
      ],
    _ => [
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '${crf.clamp(0, 51)}',
      ],
  };
  final process = await Process.start(ffmpegPath, [
    '-y',
    '-f', 'rawvideo',
    '-pix_fmt', 'rgba',
    '-s', '${width}x$height',
    '-r', '$fps',
    '-i', '-',
    ...codecArgs,
    outputPath,
  ]);

  final stderrBuf = StringBuffer();
  final stderrDone = process.stderr
      .transform(const SystemEncoding().decoder)
      .listen(stderrBuf.write)
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
}
