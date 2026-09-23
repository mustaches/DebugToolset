/// 分段并行导出的纯逻辑：段边界划分、concat 清单与产物校验
///（仅依赖 dart:io，无 Flutter 依赖，可单测）。
library;

import 'dart:io';

/// 按包把视频拆为关键帧对齐的分段（不解码；段边界吸在关键帧上，
/// 每个包恰好落入一段 → 各段解码帧序列精确拼回完整序列，对 VFR /
/// 时间戳异常片源同样精确——这是相比 -ss 时间寻址切分的根本优势）。
///
/// [segments] 为目标段数（段时长 = durationSec/segments，实际段数与
/// 段长由关键帧位置决定）。产物为 workDir 下 part_0.mp4 … part_N.mp4
/// （每段 pts 重置从 0 起）。返回分段路径表；拆分失败或不足 2 段
/// （关键帧过稀）返回空表，调用方回退单段导出。
Future<List<String>> splitVideoByPackets(String ffmpegPath, String srcPath,
    double durationSec, int segments, String workDir) async {
  if (durationSec <= 0 || segments < 2) return const [];
  // segment muxer 在首个 pts 严格大于阈值的关键帧处切：关键帧恰落在
  // 段长整数倍上会被跳过（实测 0.400s 阈值跳过 0.400s 的关键帧），
  // 阈值微缩 0.1% 把边界关键帧纳入；对真实片源（关键帧间隔秒级）
  // 该偏移可忽略。
  final segTime = durationSec / segments * 0.999;
  final r = await Process.run(File(ffmpegPath).absolute.path, [
    '-hide_banner', '-loglevel', 'error', '-y',
    '-i', srcPath, '-map', '0:v', '-c', 'copy',
    '-f', 'segment',
    '-segment_time', segTime.toStringAsFixed(6),
    '-segment_format', 'mp4', '-reset_timestamps', '1',
    '$workDir/part_%d.mp4',
  ]);
  if (r.exitCode != 0) return const [];
  final parts = <String>[];
  for (var i = 0;; i++) {
    final p = '$workDir${Platform.pathSeparator}part_$i.mp4';
    if (!File(p).existsSync()) break;
    parts.add(p);
  }
  return parts.length >= 2 ? parts : const [];
}

/// 免解码数视频帧数（`-c copy -f null -` 数包）；失败返回 null。
Future<int?> countVideoFramesFast(String ffmpegPath, String path) async {
  try {
    final r = await Process.run(File(ffmpegPath).absolute.path, [
      '-hide_banner', '-i', path,
      '-map', '0:v:0', '-c', 'copy', '-f', 'null', '-',
    ]);
    return parseFfmpegFrameCount(r.stderr.toString());
  } catch (_) {
    return null;
  }
}

/// ffmpeg concat demuxer 清单内容（`file '<path>'` 行；Windows 路径
/// 反斜杠转正斜杠，单引号转义）。
String concatListContent(List<String> segPaths) => [
      for (final p in segPaths)
        "file '${p.replaceAll(r'\', '/').replaceAll("'", r"'\''")}'",
    ].join('\n');

/// 解析 `ffmpeg -i` stderr 里的 `Duration: HH:MM:SS.cc`（秒）；未匹配
/// 返回 null。
double? parseFfmpegDurationSec(String stderrText) {
  final m =
      RegExp(r'Duration: (\d+):(\d+):([\d.]+)').firstMatch(stderrText);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 3600 +
      int.parse(m.group(2)!) * 60 +
      double.parse(m.group(3)!);
}

/// 解析 ffmpeg 进度统计行里的已处理帧数（`frame=  123`，取最后一次
/// 出现；`-c copy -f null -` 免解码数包用）。未匹配返回 null。
int? parseFfmpegFrameCount(String stderrText) {
  final ms = RegExp(r'frame=\s*(\d+)').allMatches(stderrText);
  if (ms.isEmpty) return null;
  return int.parse(ms.last.group(1)!);
}

/// 校验 concat 拼接产物：时长 ≈ totalFrames/fps（±1 帧容差）且免解码
/// 数包帧数 == totalFrames。进程失败/解析失败/文件缺失均返回 false
///（调用方回退单段导出）。
Future<bool> validateConcatOutput(
    String ffmpegPath, String outPath, int totalFrames, int fps) async {
  try {
    final ff = File(ffmpegPath).absolute.path;
    final info = await Process.run(ff, ['-hide_banner', '-i', outPath]);
    final dur = parseFfmpegDurationSec(info.stderr.toString());
    if (dur == null ||
        (dur - totalFrames / fps).abs() > 1.0 / fps + 0.01) {
      return false;
    }
    final frames = await countVideoFramesFast(ff, outPath);
    return frames == totalFrames;
  } catch (_) {
    return false;
  }
}
