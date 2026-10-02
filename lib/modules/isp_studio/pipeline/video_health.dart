// 视频健康检查器（video_health_check）的检查引擎：固化 record-2024-09-26
// 卡顿排查的检查项——VUI 虚标帧率（CFR 复制/丢帧）、时间戳异常（gap/
// 非单调/重复）、冻结帧、关键帧间隔、元数据（codec/profile/pix_fmt/色彩
// 三要素/音频）。报告逐项 [✓]/[⚠]/[✗] 中文行，经 onOutput 流式输出。
//
// 内置 ffmpeg 无 ffprobe：包级信息经 `-loglevel debug -debug_ts`（包
// pts/dts 打 stderr）与 `-vf showinfo`（解码帧 pts/checksum）获得。
//
// 纯 Dart，无 Flutter 依赖。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'video_source.dart' show videoFileInfo;

/// showinfo 输出行解析：提取 n / pts_time / checksum
///（形如 `[Parsed_showinfo_0 @ ...] n:  12 pts: ... pts_time:1.234 ... checksum:ABCD...`）。
/// 非 showinfo 行或字段缺失返回 null。
(int n, double ptsTime, String checksum)? parseShowinfoLine(String line) {
  if (!line.contains('showinfo')) return null;
  final nM = RegExp(r'\bn:\s*(\d+)').firstMatch(line);
  final tM = RegExp(r'pts_time:([-\d.]+)').firstMatch(line);
  if (nM == null || tM == null) return null;
  final cM = RegExp(r'checksum:([0-9A-Fa-f]+)').firstMatch(line);
  return (
    int.parse(nM.group(1)!),
    double.parse(tM.group(1)!),
    cM?.group(1) ?? '',
  );
}

/// pts 序列分析：间隔 min/median/max、>2× 中位数的大跳变（位置+时长）、
/// 非单调（回退，B 帧重排或时间戳错误）与重复计数。
({
  double min,
  double median,
  double max,
  List<(double pos, double dur)> gaps,
  int nonMonotonic,
  int duplicates,
}) analyzePts(List<double> pts) {
  if (pts.length < 2) {
    return (
      min: 0,
      median: 0,
      max: 0,
      gaps: const [],
      nonMonotonic: 0,
      duplicates: 0,
    );
  }
  final intervals = [for (var i = 1; i < pts.length; i++) pts[i] - pts[i - 1]];
  final sorted = [...intervals]..sort();
  final median = sorted[sorted.length ~/ 2];
  var nonMonotonic = 0, duplicates = 0;
  final gaps = <(double, double)>[];
  for (var i = 0; i < intervals.length; i++) {
    final d = intervals[i];
    if (d < 0) nonMonotonic++;
    if (d == 0) duplicates++;
    // >2× 中位数且 >40ms 才算跳变（滤掉 VFR 的正常抖动）。
    if (median > 0 && d > 2 * median && d > 0.04) gaps.add((pts[i], d));
  }
  return (
    min: sorted.first,
    median: median,
    max: sorted.last,
    gaps: gaps,
    nonMonotonic: nonMonotonic,
    duplicates: duplicates,
  );
}

String _fmtFps(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// 帧率三角一致性判定：avg（banner fps）/ VUI（r_frame_rate≈banner tbr）
/// / 实际（pts 中位间隔换算）。三者一致 → ok；VUI 与实际偏差 >1% →
/// warn（CFR 复制/丢帧风险）；avg 与实际不一致 → warn（疑似 VFR）。
(String level, String text) fpsVerdict({
  required double avgFps,
  required double rFrameRate,
  required double medianPtsFps,
}) {
  bool close(double a, double b) =>
      a <= 0 || b <= 0 || (a - b).abs() / b <= 0.01;
  if (close(avgFps, rFrameRate) && close(avgFps, medianPtsFps)) {
    return ('ok',
        'avg ${_fmtFps(avgFps)} / VUI ${_fmtFps(rFrameRate)} / pts ${_fmtFps(medianPtsFps)} fps 一致');
  }
  if (!close(rFrameRate, medianPtsFps)) {
    return ('warn',
        'VUI 标称 ${_fmtFps(rFrameRate)} fps 与实际 ${_fmtFps(medianPtsFps)} fps 不符：'
        'ffmpeg 默认 CFR 会复制/丢弃帧（播放等效降帧观感）；'
        '本应用播放/导出已强制 passthrough 免疫，部分播放器可能受影响');
  }
  return ('warn',
      'avg ${_fmtFps(avgFps)} fps 与 pts 中位 ${_fmtFps(medianPtsFps)} fps 不一致'
      '（VUI ${_fmtFps(rFrameRate)}）——片源可能为 VFR');
}

/// 冻结帧：相邻 checksum 相同的连续段（>0.5s 才报）。返回段列表
/// （start,end，秒）与重复帧总数。元素为 (pts, checksum) 二元组。
(List<(double start, double end)> segments, int dupFrames) analyzeFreeze(
    List<(double, String)> frames) {
  final segs = <(double, double)>[];
  var dups = 0;
  double? segStart;
  for (var i = 1; i < frames.length; i++) {
    if (frames[i].$2 == frames[i - 1].$2) {
      segStart ??= frames[i - 1].$1;
      dups++;
    } else if (segStart != null) {
      if (frames[i].$1 - segStart > 0.5) segs.add((segStart, frames[i].$1));
      segStart = null;
    }
  }
  if (segStart != null &&
      frames.isNotEmpty &&
      frames.last.$1 - segStart > 0.5) {
    segs.add((segStart, frames.last.$1));
  }
  return (segs, dups);
}

/// 关键帧间隔统计（秒）：min/avg/max；不足 2 个关键帧返回 null。
(double min, double avg, double max)? gopStats(List<double> keyframePts) {
  if (keyframePts.length < 2) return null;
  final intervals = [
    for (var i = 1; i < keyframePts.length; i++)
      keyframePts[i] - keyframePts[i - 1]
  ];
  final sum = intervals.reduce((a, b) => a + b);
  return (
    intervals.reduce(math.min),
    sum / intervals.length,
    intervals.reduce(math.max),
  );
}

/// -debug_ts 的 demuxer 包行解析：`demuxer -> ist_index:0:0 type:video
/// pkt_pts:100 pkt_pts_time:0.0333 pkt_dts:...`。非视频包行返回 null。
(double ptsTime, double dtsTime)? parseDebugTsPacketLine(String line) {
  if (!line.contains('demuxer ->') || !line.contains('type:video')) {
    return null;
  }
  final pM = RegExp(r'pkt_pts_time:([-\d.]+)').firstMatch(line);
  final dM = RegExp(r'pkt_dts_time:([-\d.]+)').firstMatch(line);
  if (pM == null || dM == null) return null;
  return (double.parse(pM.group(1)!), double.parse(dM.group(1)!));
}

/// freezedetect 行解析：`lavfi.freezedetect.freeze_start: 0.0667` 等。
(String key, double value)? parseFreezeLine(String line) {
  if (!line.contains('freezedetect')) return null;
  final m = RegExp(r'freezedetect\.(freeze_start|freeze_end|freeze_duration):'
          r'\s*([-\d.]+)')
      .firstMatch(line);
  if (m == null) return null;
  return (m.group(1)!, double.parse(m.group(2)!));
}

/// ffmpeg stderr 末尾的 `frame=  N` 统计（-f null 解码计数）。
int? parseFinalFrameCount(String text) {
  int? last;
  for (final m in RegExp(r'frame=\s*(\d+)').allMatches(text)) {
    last = int.tryParse(m.group(1)!);
  }
  return last;
}

/// 报告项级别。
const kLvOk = '✓';
const kLvWarn = '⚠';
const kLvFail = '✗';
const kLvInfo = 'ℹ';

/// 检查阶段（fast 模式只跑前两个）。
enum HealthCheckStage { packets, keyframes, pass1, pass2 }

/// 各阶段在整体进度中的权重（fast 模式只跑 packets/keyframes，归一化）。
const kStageWeights = {
  HealthCheckStage.packets: 0.10,
  HealthCheckStage.keyframes: 0.05,
  HealthCheckStage.pass1: 0.55,
  HealthCheckStage.pass2: 0.30,
};

const _kStageNames = {
  HealthCheckStage.packets: '包级扫描',
  HealthCheckStage.keyframes: '关键帧扫描',
  HealthCheckStage.pass1: '全片解码(1/2)',
  HealthCheckStage.pass2: '交付计数(2/2)',
};

/// 结构化进度：阶段、本阶段已处理帧、总帧、已检视频秒（内容时间）、
/// 总视频秒、整体完成度 0..1、预估剩余秒（elapsed×(1/完成度−1)）。
class HealthCheckProgress {
  final HealthCheckStage stage;
  final int stageFramesDone;
  final int totalFrames;
  final double videoSecDone;
  final double videoSecTotal;
  final double overall;
  final double etaSec;

  const HealthCheckProgress({
    required this.stage,
    required this.stageFramesDone,
    required this.totalFrames,
    required this.videoSecDone,
    required this.videoSecTotal,
    required this.overall,
    required this.etaSec,
  });

  String get stageName => _kStageNames[stage] ?? stage.name;
}

/// 整体完成度（纯函数）：已完成阶段权重和 + 当前阶段权重×阶段内进度；
/// fast 模式按 packets/keyframes 两项归一化。
double overallProgress(HealthCheckStage stage, double stageFrac, bool full) {
  final order = full
      ? const [
          HealthCheckStage.packets,
          HealthCheckStage.keyframes,
          HealthCheckStage.pass1,
          HealthCheckStage.pass2,
        ]
      : const [HealthCheckStage.packets, HealthCheckStage.keyframes];
  final totalW = order.fold<double>(0, (s, st) => s + kStageWeights[st]!);
  var acc = 0.0;
  for (final st in order) {
    if (st == stage) {
      return (acc + kStageWeights[st]! * stageFrac.clamp(0.0, 1.0)) / totalW;
    }
    acc += kStageWeights[st]!;
  }
  return 1.0;
}

/// ETA（纯函数）：elapsed × (1/完成度 − 1)；完成度 0 时为 0。
double etaSeconds(double elapsedSec, double overall) =>
    overall <= 0 ? 0 : elapsedSec * (1 / overall - 1);

/// mm:ss 格式化（补零；状态栏已检/总时间用）。
String fmtClockSec(double sec) {
  final s = sec.isFinite && sec > 0 ? sec.floor() : 0;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';
}

/// hh:mm:ss 格式化（补零；状态栏预计剩余用）。
String fmtHmsSec(double sec) {
  final s = sec.isFinite && sec > 0 ? sec.ceil() : 0;
  return '${(s ~/ 3600).toString().padLeft(2, '0')}:'
      '${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';
}

/// 视频健康检查：fast（仅元数据与索引，不解码全片）/ full（含全片解码
/// 扫描：交付帧数对比 + 冻结帧）。返回 0=完成无警告，1=完成有警告，
/// -2=用户中止，其它 <0=检查失败。报告经 [onOutput] 流式输出（含末尾
/// 汇总行）；[onProgress] 按 ~4Hz 节流回报结构化进度（状态栏显示用）；
/// [isCancelled] 在行处理循环与阶段边界检查，触发时 kill 当前 ffmpeg
/// 子进程、报告中保留已产出阶段结果、返回 -2。
Future<int> runVideoHealthCheck({
  required String ffmpegPath,
  required String inputFile,
  String scanDepth = 'fast',
  required void Function(String chunk) onOutput,
  void Function(HealthCheckProgress p)? onProgress,
  bool Function()? isCancelled,
}) async {
  if (inputFile.trim().isEmpty) {
    onOutput('[$kLvFail] 未设置视频文件\n');
    return -1;
  }
  if (ffmpegPath.trim().isEmpty) {
    onOutput('[$kLvFail] 未设置 ffmpeg 路径\n');
    return -1;
  }
  final ffmpeg = File(ffmpegPath).absolute.path;
  final input = File(inputFile).absolute.path;
  if (!File(ffmpeg).existsSync()) {
    onOutput('[$kLvFail] ffmpeg 不存在：$ffmpeg\n');
    return -1;
  }
  if (!File(input).existsSync()) {
    onOutput('[$kLvFail] 视频文件不存在：$input\n');
    return -1;
  }
  final full = scanDepth == 'full';
  var warns = 0, fails = 0;
  void emit(String level, String item, String detail) {
    if (level == kLvWarn) warns++;
    if (level == kLvFail) fails++;
    onOutput('[$level] $item：$detail\n');
  }

  // 取消：行循环里 kill 当前子进程（exit 非 0 阶段即结束），阶段边界
  // 统一收口返回 -2（已产出的阶段结果保留在报告中）。
  var cancelled = false;
  Process? activeProc;
  bool checkCancel() {
    if (cancelled) return true;
    if (isCancelled?.call() ?? false) {
      cancelled = true;
      activeProc?.kill();
    }
    return cancelled;
  }

  int abortIfCancelled() {
    if (!cancelled) return 0;
    onOutput('[$kLvWarn] [已中止] 用户中断检查\n');
    return -2;
  }

  // 进度：整体完成度按阶段加权（kStageWeights），ETA = elapsed×(1/p−1)。
  final sw = Stopwatch()..start();
  var lastProgressMs = 0;
  var totalFramesEst = 0;
  var videoSecTotal = 0.0;
  void reportProgress(HealthCheckStage stage, int done, double videoSec,
      double stageFrac,
      {bool force = false}) {
    if (onProgress == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - lastProgressMs < 250) return; // ~4Hz 节流
    lastProgressMs = now;
    final overall = overallProgress(stage, stageFrac, full);
    onProgress(HealthCheckProgress(
      stage: stage,
      stageFramesDone: done,
      totalFrames: totalFramesEst,
      videoSecDone: videoSec,
      videoSecTotal: videoSecTotal,
      overall: overall,
      etaSec: etaSeconds(sw.elapsedMilliseconds / 1000, overall),
    ));
  }

  onOutput('==== 视频健康检查（${full ? '完整' : '快速'}模式）====\n');
  onOutput('Input : $input\n\n');

  // 起一个 ffmpeg 子进程，stderr 全文收集（frame= 计数等解析用）。
  // 注意：只有存在监听者时才能 close 行流——无监听的单订阅控制器
  // close() 不完成，会让 VM 以「事件队列空」干净退出（表现为静默截断）。
  Future<(int, String)> runFf(List<String> args,
      {void Function(String line)? onLine}) async {
    final proc = await Process.start(ffmpeg, args);
    activeProc = proc;
    final buf = StringBuffer();
    final lineQ = StreamController<String>();
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      buf.write(chunk);
      if (onLine != null) lineQ.add(chunk);
    });
    proc.stdout.drain<void>();
    StreamSubscription<String>? lineSub;
    if (onLine != null) {
      lineSub =
          lineQ.stream.transform(const LineSplitter()).listen(onLine);
    }
    final code = await proc.exitCode;
    if (lineSub != null) await lineQ.close();
    if (identical(activeProc, proc)) activeProc = null;
    return (code, buf.toString());
  }

  // ---- 1. 基本信息（banner + videoFileInfo 缓存探测）----
  String banner;
  try {
    final r = await Process.run(ffmpeg, ['-hide_banner', '-i', input]);
    banner = r.stderr.toString();
  } catch (e) {
    onOutput('[$kLvFail] 无法运行 ffmpeg 读取基本信息：$e\n');
    return -3;
  }
  final videoLine =
      RegExp('Stream[^\n]*Video:[^\\n]*').firstMatch(banner)?.group(0) ?? '';
  if (videoLine.isEmpty) {
    onOutput('[$kLvFail] 文件中未找到视频流\n');
    return -3;
  }
  final codec =
      RegExp(r'Video:\s*([^\s,]+(?:\s*\([^)]*\))?)').firstMatch(videoLine);
  final pixFmt = RegExp(r',\s*([a-z0-9]+)\(').firstMatch(videoLine);
  final durM =
      RegExp(r'Duration:\s*([0-9:.]+)').firstMatch(banner)?.group(1) ?? '?';
  final bitrate =
      RegExp(r'bitrate:\s*([0-9]+)').firstMatch(banner)?.group(1) ?? '?';
  double bannerNum(String key) {
    final m = RegExp('([0-9.]+)\\s*$key').firstMatch(videoLine);
    return m != null ? double.parse(m.group(1)!) : 0;
  }

  final avgFps = bannerNum('fps');
  final tbr = bannerNum('tbr');
  emit(kLvInfo, '基本信息',
      '${codec?.group(1) ?? '?'} ${pixFmt?.group(1) ?? '?'}，'
      '时长 $durM，码率 $bitrate kb/s');

  double width = 0, height = 0, fps = 0;
  var frameCount = 0;
  var hasAudio = false;
  var colorMatrix = 0, colorTransfer = 0;
  try {
    final info = await videoFileInfo(input, ffmpegPath: ffmpeg);
    width = info.width.toDouble();
    height = info.height.toDouble();
    fps = info.fps;
    frameCount = info.frameCount;
    hasAudio = info.hasAudio;
    colorMatrix = info.colorMatrix;
    colorTransfer = info.colorTransfer;
  } catch (_) {}
  totalFramesEst = frameCount;
  if (frameCount > 0 && fps > 0) videoSecTotal = frameCount / fps;
  final matrixTag = switch (colorMatrix) {
    1 => 'BT.709',
    2 => 'BT.2020',
    _ => 'BT.601',
  };
  final rangeTag = switch (colorTransfer) {
    1 => 'HDR(PQ)',
    2 => 'HDR(HLG)',
    _ => 'SDR',
  };
  emit(kLvInfo, '分辨率/帧数',
      '${width.toInt()}x${height.toInt()}，约 $frameCount 帧（avg ${_fmtFps(fps > 0 ? fps : avgFps)} fps）');
  emit(kLvInfo, '色彩/动态范围',
      '$matrixTag / $rangeTag（transfer=${switch (colorTransfer) {
        1 => 'smpte2084',
        2 => 'arib-std-b67',
        _ => 'bt709/未标注',
      }}）');
  // field_order / has_b_frames：banner 不可见（无 ffprobe）；B 帧重排在
  // 包时间戳分析里实证。
  emit(kLvInfo, '场序', '未知（无 ffprobe，banner 不含 field_order）');
  final audioLine =
      RegExp('Stream[^\n]*Audio:[^\\n]*').firstMatch(banner)?.group(0);
  if (audioLine != null) {
    final ac = RegExp(r'Audio:\s*([^,]+)').firstMatch(audioLine);
    emit(kLvInfo, '音频', ac?.group(1)?.trim() ?? '有音轨');
  } else {
    emit(kLvInfo, '音频', hasAudio ? '有音轨' : '无音轨');
  }

  // ---- 2. 包级扫描（不解码）：包数 + pts/dts 序列 ----
  onOutput('\n---- 包级扫描（-debug_ts，不解码）----\n');
  final pktPts = <double>[];
  var lastProgress = 0;
  var scanFailed = false;
  {
    final (code, _) = await runFf([
      '-hide_banner', '-loglevel', 'debug',
      '-i', input,
      '-map', '0:v:0', '-c', 'copy', '-f', 'null', '-debug_ts', '-',
    ], onLine: (line) {
      final pkt = parseDebugTsPacketLine(line);
      if (pkt == null) return;
      pktPts.add(pkt.$1);
      checkCancel();
      final frac = totalFramesEst > 0
          ? pktPts.length / totalFramesEst
          : (videoSecTotal > 0 ? pkt.$1 / videoSecTotal : 0.0);
      reportProgress(HealthCheckStage.packets, pktPts.length, pkt.$1, frac);
      if (pktPts.length - lastProgress >= 5000) {
        lastProgress = pktPts.length;
        onOutput('  …已扫描 ${pktPts.length} 包\n');
      }
    });
    if (code != 0 && !cancelled) {
      scanFailed = true;
      emit(kLvFail, '包级扫描', 'ffmpeg 退出码 $code');
    }
    reportProgress(HealthCheckStage.packets, pktPts.length,
        pktPts.isEmpty ? 0 : pktPts.last, 1,
        force: true);
    final ab = abortIfCancelled();
    if (ab != 0) return ab;
  }
  double medianPtsFps = 0;
  if (!scanFailed && pktPts.isNotEmpty) {
    emit(kLvOk, '包数', '${pktPts.length} 个视频包');
    // 包按 dts（解码序）到达：含 B 帧时到达序 pts 本身是抖动的——
    // 间隔/gap 统计必须按时间轴排序后的序列；到达序只用于 B 帧重排
    // 计数（pts 回退 = 重排，非时间戳错误）。
    final sortedPts = [...pktPts]..sort();
    final pa = analyzePts(sortedPts);
    final reorder = analyzePts(pktPts).nonMonotonic;
    medianPtsFps = pa.median > 0 ? 1 / pa.median : 0;
    emit(
        pa.gaps.isEmpty ? kLvOk : kLvWarn,
        '时间戳间隔',
        'min ${pa.min.toStringAsFixed(4)}s / 中位 ${pa.median.toStringAsFixed(4)}s'
            ' / max ${pa.max.toStringAsFixed(4)}s'
            '${pa.gaps.isEmpty ? '' : '，${pa.gaps.length} 处大跳变'}');
    for (final g in pa.gaps) {
      emit(kLvWarn, '时间戳跳变',
          '${g.$1.toStringAsFixed(3)}s 处空洞 ${g.$2.toStringAsFixed(3)}s');
    }
    if (reorder > 0) {
      emit(kLvInfo, 'B 帧', 'pts 到达序存在 $reorder 次回退——存在 B 帧重排（正常现象）');
    } else {
      emit(kLvInfo, 'B 帧', 'pts 到达序单调——无 B 帧重排');
    }
    if (pa.duplicates > 0) {
      emit(kLvWarn, '重复时间戳', '${pa.duplicates} 个包的 pts 与前一包相同');
    }
  }

  // ---- 3. 帧率三角一致性 ----
  if (medianPtsFps > 0 || avgFps > 0) {
    final (lv, text) = fpsVerdict(
        avgFps: avgFps > 0 ? avgFps : fps,
        rFrameRate: tbr,
        medianPtsFps: medianPtsFps > 0 ? medianPtsFps : (fps > 0 ? fps : tbr));
    emit(lv == 'ok' ? kLvOk : kLvWarn, '帧率一致性', text);
  }

  // ---- 4. 关键帧间隔（只解关键帧 + showinfo）----
  onOutput('\n---- 关键帧扫描（-skip_frame nokey）----\n');
  final keyPts = <double>[];
  {
    final (code, _) = await runFf([
      '-hide_banner', '-loglevel', 'info',
      // 解码/滤镜线程封顶 8（112 核机默认 auto 百线程爆发式占满全核）。
      '-threads', '8', '-filter_threads', '8',
      '-skip_frame', 'nokey', '-i', input,
      '-map', '0:v:0', '-vf', 'showinfo', '-f', 'null', '-',
    ], onLine: (line) {
      final si = parseShowinfoLine(line);
      if (si != null) {
        keyPts.add(si.$2);
        checkCancel();
        final frac =
            videoSecTotal > 0 ? si.$2 / videoSecTotal : 0.0;
        reportProgress(
            HealthCheckStage.keyframes, keyPts.length, si.$2, frac);
      }
    });
    if (code != 0 && !cancelled) {
      emit(kLvWarn, '关键帧扫描', 'ffmpeg 退出码 $code（跳过间隔统计）');
    }
    reportProgress(HealthCheckStage.keyframes, keyPts.length,
        keyPts.isEmpty ? 0 : keyPts.last, 1,
        force: true);
    final ab = abortIfCancelled();
    if (ab != 0) return ab;
  }
  if (keyPts.length >= 2) {
    final g = gopStats(keyPts)!;
    emit(kLvOk, '关键帧间隔',
        '${keyPts.length} 个关键帧，间隔 min ${g.$1.toStringAsFixed(2)}s / '
        'avg ${g.$2.toStringAsFixed(2)}s / max ${g.$3.toStringAsFixed(2)}s');
  } else if (keyPts.isNotEmpty) {
    // 单关键帧只在长片才构成问题（无随机 seek 锚点）；短片正常。
    final durSec = frameCount > 0 && fps > 0 ? frameCount / fps : 0.0;
    emit(durSec > 60 ? kLvWarn : kLvInfo, '关键帧间隔',
        '全片仅 1 个关键帧${durSec > 60 ? '（无随机seek锚点）' : ''}');
  }

  // ---- 5/6. 全片解码扫描（仅 full 模式）----
  if (full) {
    onOutput('\n---- 全片解码扫描（交付帧数对比 + 冻结帧，较慢）----\n');
    // pass A：passthrough + showinfo + freezedetect（一并拿帧 pts/checksum、
    // 冻结段与 passthrough 交付帧数——比 record-2024 排查的三趟合并为两趟）。
    final framePtsCk = <(double, String)>[];
    final freezeSegs = <(double, double)>[];
    double? freezeStart;
    onOutput('[pass 1/2] passthrough + freezedetect 全片解码…\n');
    String tailA = '';
    {
      final (code, text) = await runFf([
        '-hide_banner', '-loglevel', 'info',
        '-threads', '8', '-filter_threads', '8',
        '-i', input, '-map', '0:v:0',
        '-fps_mode', 'passthrough',
        '-vf', 'showinfo,freezedetect=n=0.001:d=0.5',
        '-f', 'null', '-',
      ], onLine: (line) {
        final si = parseShowinfoLine(line);
        if (si != null) {
          framePtsCk.add((si.$2, si.$3));
          checkCancel();
          final frac = totalFramesEst > 0
              ? framePtsCk.length / totalFramesEst
              : (videoSecTotal > 0 ? si.$2 / videoSecTotal : 0.0);
          reportProgress(
              HealthCheckStage.pass1, si.$1 + 1, si.$2, frac);
          return;
        }
        final fz = parseFreezeLine(line);
        if (fz == null) return;
        if (fz.$1 == 'freeze_start') {
          freezeStart = fz.$2;
        } else if (fz.$1 == 'freeze_end' && freezeStart != null) {
          freezeSegs.add((freezeStart!, fz.$2));
          freezeStart = null;
        }
      });
      tailA = text;
      if (code != 0 && !cancelled) {
        emit(kLvFail, '全片解码(pass 1)', 'ffmpeg 退出码 $code');
      }
      reportProgress(
          HealthCheckStage.pass1,
          framePtsCk.length,
          framePtsCk.isEmpty ? 0 : framePtsCk.last.$1, 1,
          force: true);
      final ab = abortIfCancelled();
      if (ab != 0) return ab;
    }
    final passAFrames = parseFinalFrameCount(tailA) ?? framePtsCk.length;
    // pass B：默认 CFR 计数（record-2024 元凶检查：VUI 60→逐帧复制 2×）。
    // 逐帧统计不转终端（buf 仍收集供 frame= 计数），进度经 frame= 行解析
    // 回报 onProgress。
    onOutput('\n[pass 2/2] 默认 CFR 全片解码计数…\n');
    String tailB = '';
    var pass2Done = 0;
    {
      final (code, text) = await runFf([
        '-hide_banner', '-loglevel', 'info',
        '-threads', '8', '-filter_threads', '8',
        '-i', input, '-map', '0:v:0', '-f', 'null', '-',
      ], onLine: (line) {
        // 进度行以 \r 分隔：一行可能含多个 frame= 更新，取最后一个。
        int? n;
        for (final m in RegExp(r'frame=\s*(\d+)').allMatches(line)) {
          n = int.tryParse(m.group(1)!);
        }
        if (n == null) return;
        pass2Done = n;
        checkCancel();
        final frac =
            totalFramesEst > 0 ? n / totalFramesEst : 0.0;
        reportProgress(HealthCheckStage.pass2, n,
            fps > 0 ? n / fps : 0.0, frac);
      });
      tailB = text;
      if (code != 0 && !cancelled) {
        emit(kLvFail, '全片解码(pass 2)', 'ffmpeg 退出码 $code');
      }
      reportProgress(HealthCheckStage.pass2, pass2Done,
          fps > 0 ? pass2Done / fps : 0.0, 1,
          force: true);
      final ab = abortIfCancelled();
      if (ab != 0) return ab;
    }
    final passBFrames = parseFinalFrameCount(tailB);
    if (passBFrames != null && passAFrames > 0) {
      if (passBFrames == passAFrames) {
        emit(kLvOk, '交付帧数对比',
            '默认 CFR $passBFrames 帧 = passthrough $passAFrames 帧（无复制/丢帧）');
      } else {
        final ratio = passBFrames / passAFrames;
        emit(kLvWarn, '交付帧数对比',
            '默认输出 $passBFrames 帧 / passthrough $passAFrames 帧：'
            'CFR 按 VUI 复制/丢弃 ${ratio.toStringAsFixed(2)}×');
      }
    }
    // 冻结帧：freezedetect 官方段 + checksum 连续重复段（>0.5s）。
    final (ckSegs, dupFrames) = analyzeFreeze(framePtsCk);
    final allSegs = [...freezeSegs, ...ckSegs];
    if (allSegs.isEmpty && dupFrames == 0) {
      emit(kLvOk, '冻结帧', '未发现重复帧段（freezedetect + checksum 双口径）');
    } else {
      if (dupFrames > 0) {
        emit(kLvWarn, '冻结帧', '共 $dupFrames 帧与前一帧 checksum 相同');
      }
      for (final s in allSegs) {
        emit(kLvWarn, '冻结帧段',
            '${s.$1.toStringAsFixed(3)}s ~ ${s.$2.toStringAsFixed(3)}s'
            '（${(s.$2 - s.$1).toStringAsFixed(3)}s）');
      }
    }
  } else {
    emit(kLvInfo, '深度扫描', '快速模式跳过：交付帧数对比（CFR 复制检测）与冻结帧扫描'
        '（scanDepth 选「完整」启用）');
  }

  // ---- 汇总 ----
  onOutput('\n==== 汇总 ====\n');
  if (fails > 0) {
    onOutput('[✗] $fails 项检查失败，$warns 项警告\n');
    return 1;
  }
  if (warns > 0) {
    onOutput('[⚠] $warns 项警告，其余正常\n');
    return 1;
  }
  onOutput('[✓] 全部正常\n');
  return 0;
}
