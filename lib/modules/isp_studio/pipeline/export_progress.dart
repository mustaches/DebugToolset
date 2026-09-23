/// 视频导出进度信息（纯数据 + ETA 估算 + 状态栏文案，无 Flutter 依赖）。
///
/// exportVideo 两路径（CPU 池 / GPU 链）在喂流回调里逐帧 [addFrame]，
/// 状态栏经 exportInfoTick 节流刷新展示 [statusLine]。
library;

/// 秒 → HH:MM:SS（如 84.3 → "00:01:24"，7384 → "02:03:04"；小时不封顶，
/// 超 99 小时自然扩展位数）。
String formatHhMmSs(double seconds) {
  final total = seconds.floor();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}

/// 滑动窗口帧率估算：记录最近 [windowSize] 个帧完成时刻，用窗口首尾
/// 间隔求平均帧率（比全程平均更贴合实时速度；窗口不足 2 帧时为 0，
/// 调用方按「估算中」显示）。
class ExportEtaTracker {
  final int windowSize;
  final List<int> _doneMs = [];

  ExportEtaTracker({this.windowSize = 8});

  void add(int nowMs) {
    _doneMs.add(nowMs);
    if (_doneMs.length > windowSize) _doneMs.removeAt(0);
  }

  /// 窗口平均帧率（帧/秒）；不足 2 帧返回 0。
  double get smoothFps {
    if (_doneMs.length < 2) return 0;
    final spanMs = _doneMs.last - _doneMs.first;
    if (spanMs <= 0) return 0;
    return (_doneMs.length - 1) * 1000.0 / spanMs;
  }
}

/// 一次视频导出的进度状态：输出参数 + 已完成帧数 + 实时帧率/ETA。
class ExportProgressInfo {
  final int width;
  final int height;
  final int fps;
  final int totalFrames;

  /// 输出视频总时长（秒，= totalFrames / fps）。
  final double totalSeconds;

  int doneFrames = 0;
  final ExportEtaTracker _eta;

  ExportProgressInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.totalFrames,
    int etaWindowSize = 8,
  })  : totalSeconds = totalFrames / fps,
        _eta = ExportEtaTracker(windowSize: etaWindowSize);

  /// 完成一帧（nowMs 为该帧写完时刻的毫秒时间戳）。
  void addFrame(int nowMs) {
    doneFrames++;
    _eta.add(nowMs);
  }

  /// 滑动平均实时压缩帧率；不足 2 帧返回 0。
  double get smoothFps => _eta.smoothFps;

  /// 估算剩余秒数；帧率未知（前 2 帧未出）返回 null。
  double? get etaSeconds {
    final f = smoothFps;
    if (f <= 0) return null;
    return (totalFrames - doneFrames) / f;
  }

  /// 状态栏文案，形如：
  /// 导出中 3840×2160 @60fps 时长 00:00:24 | 12/24 帧 4.3 帧/秒 剩余 00:01:23
  /// ETA 特例：帧率未知显示「剩余 估算中…」，不足 1 秒显示「剩余 <1s」。
  String statusLine() {
    final eta = etaSeconds;
    final etaText = eta == null
        ? '剩余 估算中…'
        : (eta < 1 ? '剩余 <1s' : '剩余 ${formatHhMmSs(eta)}');
    final fpsText = smoothFps > 0 ? '${smoothFps.toStringAsFixed(1)} 帧/秒' : '—';
    return '导出中 $width×$height @${fps}fps 时长 ${formatHhMmSs(totalSeconds)}'
        ' | $doneFrames/$totalFrames 帧 $fpsText $etaText';
  }
}
