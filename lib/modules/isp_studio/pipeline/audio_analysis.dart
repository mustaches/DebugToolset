/// 音频类仪器（立体声电平/音频波形/21 段 EQ 频谱）的分析计算。
///
/// 输入为视频音轨抽取的 16 位 PCM（见 audio_player.dart 的
/// ensureAudioWav），分析围绕当前播放位置取一小段窗（因果窗：
/// 窗口结束于当前位置，显示的就是正在听的内容）。纯 Dart +
/// dart:typed_data，可在后台 isolate 中运行。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 解析后的 WAV PCM（交织样本）。
class WavPcm {
  /// 采样率（Hz）。
  final int sampleRate;

  /// 声道数（1 = 单声道，2 = 立体声）。
  final int channels;

  /// 交织样本（LRLR…；单声道即顺序样本）。
  final Int16List samples;

  const WavPcm(this.sampleRate, this.channels, this.samples);

  /// 帧数（一帧 = 所有声道各一个样本）。
  int get frames => samples.length ~/ channels;
}

/// 解析 RIFF/WAVE 为 [WavPcm]。仅支持 16 位整型 PCM（audio_player
/// 抽取的产物），其余格式抛 [StateError]。
WavPcm parseWavPcm(Uint8List bytes) {
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw StateError('不是 WAV 文件');
  }
  final bd = ByteData.sublistView(bytes);
  var offset = 12;
  var channels = 0;
  var sampleRate = 0;
  var bits = 0;
  var format = 0;
  Int16List? samples;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = bd.getUint32(offset + 4, Endian.little);
    final dataStart = offset + 8;
    if (dataStart + size > bytes.length) break;
    if (id == 'fmt ') {
      format = bd.getUint16(dataStart, Endian.little);
      channels = bd.getUint16(dataStart + 2, Endian.little);
      sampleRate = bd.getUint32(dataStart + 4, Endian.little);
      bits = bd.getUint16(dataStart + 14, Endian.little);
    } else if (id == 'data') {
      final count = size ~/ 2;
      final absolute = bytes.offsetInBytes + dataStart;
      if (absolute % 2 == 0) {
        samples = Int16List.view(bytes.buffer, absolute, count);
      } else {
        // 奇数偏移不能按 16 位视图对齐，逐样本拷贝。
        samples = Int16List(count);
        for (var i = 0; i < count; i++) {
          samples[i] = bd.getInt16(dataStart + i * 2, Endian.little);
        }
      }
    }
    offset = dataStart + size + (size & 1); // 块按偶数对齐
  }
  if (format != 1 || bits != 16) {
    throw StateError('仅支持 16 位 PCM WAV（format=$format, bits=$bits）');
  }
  if (channels < 1 || sampleRate <= 0 || samples == null) {
    throw StateError('WAV 缺少 fmt/data 块');
  }
  return WavPcm(sampleRate, channels, samples);
}

/// 电平刻度的下限（dBFS），低于它显示为 0。
const double kAudioLevelFloorDb = -60;

/// 峰值 dBFS → 0..1 显示值（[kAudioLevelFloorDb] 起步）。
double _dbToUnit(double peak) {
  final db = 20 * math.log(peak + 1e-12) / math.ln10;
  return ((db - kAudioLevelFloorDb) / -kAudioLevelFloorDb).clamp(0.0, 1.0);
}

/// 窗口范围（样本帧 [start, end)）：结束于 [seconds]、长约
/// [windowFrames] 的因果窗；位置越界时窗口缩短（可为空）。
(int, int) _window(WavPcm pcm, double seconds, int windowFrames) {
  final end = (seconds * pcm.sampleRate).round().clamp(0, pcm.frames);
  return (math.max(0, end - windowFrames), end);
}

/// 立体声电平：位置 [seconds] 之前约 [windowMs] 毫秒窗内各声道峰值，
/// 返回 `{'kind': 'audio_level', 'left': 0..1, 'right': 0..1}`。
/// 单声道时左右相同。
Map<String, Object?> audioLevels(WavPcm pcm, double seconds,
    {double windowMs = 50}) {
  final win = (pcm.sampleRate * windowMs / 1000).round();
  final (start, end) = _window(pcm, seconds, win);
  var peakL = 0, peakR = 0;
  for (var f = start; f < end; f++) {
    final l = pcm.samples[f * pcm.channels].abs();
    if (l > peakL) peakL = l;
    final r = pcm.channels > 1
        ? pcm.samples[f * pcm.channels + 1].abs()
        : l;
    if (r > peakR) peakR = r;
  }
  return {
    'kind': 'audio_level',
    'left': _dbToUnit(peakL / 32768),
    'right': _dbToUnit(peakR / 32768),
  };
}

/// 音频波形：位置 [seconds] 之前约 [windowMs] 毫秒窗，横轴压为
/// [columns] 列，每列取窗内样本的 min/max（-1..1）。返回
/// `{'kind': 'audio_waveform', 'columns': n, 'lMin/lMax/rMin/rMax': Float32List}`。
Map<String, Object?> audioWaveform(WavPcm pcm, double seconds,
    {int columns = 256, double windowMs = 92}) {
  final win = (pcm.sampleRate * windowMs / 1000).round();
  final (start, end) = _window(pcm, seconds, win);
  final lMin = Float32List(columns)..fillRange(0, columns, 1);
  final lMax = Float32List(columns)..fillRange(0, columns, -1);
  final rMin = Float32List(columns)..fillRange(0, columns, 1);
  final rMax = Float32List(columns)..fillRange(0, columns, -1);
  final span = end - start;
  for (var f = start; f < end; f++) {
    final col = span <= 0 ? 0 : (f - start) * columns ~/ span;
    final l = pcm.samples[f * pcm.channels] / 32768;
    final r = pcm.channels > 1
        ? pcm.samples[f * pcm.channels + 1] / 32768
        : l;
    if (l < lMin[col]) lMin[col] = l;
    if (l > lMax[col]) lMax[col] = l;
    if (r < rMin[col]) rMin[col] = r;
    if (r > rMax[col]) rMax[col] = r;
  }
  // 无样本的列（窗越界）收拢到 0 线。
  for (var c = 0; c < columns; c++) {
    if (lMin[c] > lMax[c]) lMin[c] = lMax[c] = 0;
    if (rMin[c] > rMax[c]) rMin[c] = rMax[c] = 0;
  }
  return {
    'kind': 'audio_waveform',
    'columns': columns,
    'lMin': lMin,
    'lMax': lMax,
    'rMin': rMin,
    'rMax': rMax,
  };
}

/// EQ 频谱段数。
const int kAudioEqBands = 21;

/// EQ 频谱下限频率（Hz）。
const double kAudioEqMinHz = 20;

/// EQ 频谱上限频率（Hz）。
const double kAudioEqMaxHz = 20000;

/// 21 段 EQ 频谱：位置 [seconds] 之前 [fftSize] 样本的 Hann 窗 FFT
/// （左右声道混合为单声道），幅度按 20Hz–20kHz 对数等分 21 段取峰值，
/// dB 刻度（[kAudioLevelFloorDb] 起步）映射到 0..1。
/// 返回 `{'kind': 'audio_eq', 'bands': Float64List(21)}`。
Map<String, Object?> audioEqBands(WavPcm pcm, double seconds,
    {int fftSize = 2048}) {
  final (start, end) = _window(pcm, seconds, fftSize);
  // 混单声道 + Hann 窗。
  final re = Float64List(fftSize);
  final n = end - start;
  for (var i = 0; i < n; i++) {
    final f = start + i;
    final l = pcm.samples[f * pcm.channels] / 32768;
    final r = pcm.channels > 1
        ? pcm.samples[f * pcm.channels + 1] / 32768
        : l;
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (fftSize - 1));
    re[i] = (l + r) * 0.5 * w;
  }
  final mags = _fftMagnitudes(re);
  // 对数等分频段：[minHz, maxHz] 等比 21 段，段界取相邻中心的几何中点。
  final ratio = math.pow(kAudioEqMaxHz / kAudioEqMinHz, 1 / kAudioEqBands);
  final binHz = pcm.sampleRate / fftSize;
  final bands = Float64List(kAudioEqBands);
  for (var b = 0; b < kAudioEqBands; b++) {
    final fLo = kAudioEqMinHz * math.pow(ratio, b - 0.5);
    final fHi = kAudioEqMinHz * math.pow(ratio, b + 0.5);
    final binLo = (fLo / binHz).floor().clamp(1, mags.length - 1);
    final binHi = (fHi / binHz).ceil().clamp(binLo + 1, mags.length);
    var peak = 0.0;
    for (var i = binLo; i < binHi; i++) {
      if (mags[i] > peak) peak = mags[i];
    }
    // Hann 窗相干增益 0.5，幅值 ×2 还原。
    bands[b] = _dbToUnit(peak * 2);
  }
  return {'kind': 'audio_eq', 'bands': bands};
}

/// 迭代基-2 FFT，返回前一半频点的归一化幅度（|X| / (N/2)）。
/// [re] 为实部（就地运算，虚部从 0 开始），长度必须是 2 的幂。
Float64List _fftMagnitudes(Float64List re) {
  final n = re.length;
  final im = Float64List(n);
  // 位反转置换。
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final t = re[i];
      re[i] = re[j];
      re[j] = t;
    }
  }
  // 逐级蝶形。
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var cwr = 1.0, cwi = 0.0;
      for (var j = 0; j < half; j++) {
        final ur = re[i + j], ui = im[i + j];
        final k = i + j + half;
        final vr = re[k] * cwr - im[k] * cwi;
        final vi = re[k] * cwi + im[k] * cwr;
        re[i + j] = ur + vr;
        im[i + j] = ui + vi;
        re[k] = ur - vr;
        im[k] = ui - vi;
        final tr = cwr * wr - cwi * wi;
        cwi = cwr * wi + cwi * wr;
        cwr = tr;
      }
    }
  }
  final mags = Float64List(n >> 1);
  for (var i = 0; i < n >> 1; i++) {
    mags[i] = math.sqrt(re[i] * re[i] + im[i] * im[i]) / (n >> 1);
  }
  return mags;
}
