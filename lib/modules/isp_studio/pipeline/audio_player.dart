/// 视频预览的音频回放：ffmpeg 把视频音轨抽取为临时 WAV，经 Windows
/// MCI（winmm.dll，dart:ffi 直调，无第三方依赖）播放/暂停/定位。
///
/// 音频始终按 1x 速率播放：起播推迟到首帧实际上屏时（起点对齐），
/// 播放中由调用方周期性对比 [MciAudioPlayer.positionSeconds] 与视频
/// 帧时刻做漂移修正（停滞跳轴、帧率取整误差、输出缓冲延迟等都会让
/// 两侧时钟渐偏）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' show calloc;

import 'exporters.dart' show findFfmpeg;
import 'video_source.dart';

final _winmm = DynamicLibrary.open('winmm.dll');

typedef _MciSendStringNative = Int32 Function(
    Pointer<Uint16> cmd, Pointer<Uint16> ret, Uint32 retLen, IntPtr hwnd);
typedef _MciSendStringDart = int Function(
    Pointer<Uint16> cmd, Pointer<Uint16> ret, int retLen, int hwnd);

final _mciSendString =
    _winmm.lookupFunction<_MciSendStringNative, _MciSendStringDart>(
        'mciSendStringW');

Pointer<Uint16> _toUtf16(String s) {
  final units = s.codeUnits;
  final p = calloc<Uint16>(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    p[i] = units[i];
  }
  p[units.length] = 0;
  return p;
}

/// 发送 MCI 命令，返回错误码（0 = 成功）。
int mciSendString(String command) {
  final cmd = _toUtf16(command);
  try {
    return _mciSendString(cmd, nullptr, 0, 0);
  } finally {
    calloc.free(cmd);
  }
}

/// 发送 MCI 命令并读取返回字符串（status 查询用），失败返回 null。
String? mciSendStringQuery(String command, {int retChars = 128}) {
  final cmd = _toUtf16(command);
  final ret = calloc<Uint16>(retChars);
  try {
    if (_mciSendString(cmd, ret, retChars, 0) != 0) return null;
    final codes = <int>[];
    for (var i = 0; i < retChars && ret[i] != 0; i++) {
      codes.add(ret[i]);
    }
    return String.fromCharCodes(codes);
  } finally {
    calloc.free(cmd);
    calloc.free(ret);
  }
}

/// MCI 音频播放器（waveaudio 设备）。alias 固定，随 open/close 复用。
class MciAudioPlayer {
  static const _alias = 'ispPreviewAudio';

  var _opened = false;

  /// 打开 WAV 文件。失败抛 [StateError]（无音频设备、文件损坏等）。
  void open(String wavPath) {
    _cmd('open "$wavPath" type waveaudio alias $_alias');
    _opened = true;
  }

  /// 从 [seconds] 处开始播放（异步命令，立即返回）。
  void playFrom(double seconds) {
    _cmd('play $_alias from ${(seconds * 1000).round()}');
  }

  /// 当前播放位置（秒）；未打开或查询失败返回 null。
  double? positionSeconds() {
    if (!_opened) return null;
    final s = mciSendStringQuery('status $_alias position');
    if (s == null) return null;
    final ms = double.tryParse(s.trim());
    return ms == null ? null : ms / 1000.0;
  }

  void stop() {
    if (!_opened) return; // 未打开时静默（播放循环 finally 无条件调用）
    _cmd('stop $_alias');
  }

  /// 关闭设备（幂等，未打开时静默）。
  void close() {
    if (!_opened) return;
    _opened = false;
    try {
      _cmd('close $_alias');
    } catch (_) {
      // 设备已不在时忽略。
    }
  }

  void _cmd(String cmd) {
    final code = mciSendString(cmd);
    if (code != 0) throw StateError('MCI 命令失败 ($code): $cmd');
  }
}

/// 视频音轨 → 临时 WAV 缓存（视频路径 → WAV 路径）。
final Map<String, String> _wavCache = {};

/// 确保 [videoPath] 的音轨已抽取为 WAV，返回 WAV 路径。
/// 无音轨、ffmpeg 不可用或抽取失败返回 null（调用方安静跳过音频）。
/// [onProgress] 回调 0.0~1.0 之间的抽取进度（基于视频时长）。
Future<String?> ensureAudioWav(
  String videoPath, {
  String ffmpegPath = '',
  void Function(double progress)? onProgress,
}) async {
  final cached = _wavCache[videoPath];
  if (cached != null && await File(cached).exists()) {
    onProgress?.call(1.0);
    return cached;
  }
  final info = await videoFileInfo(videoPath, ffmpegPath: ffmpegPath);
  if (!info.hasAudio) return null;
  final ffmpeg = await findFfmpeg(overridePath: ffmpegPath);
  if (ffmpeg == null) return null;
  final wav =
      '${Directory.systemTemp.path}${Platform.pathSeparator}isp_audio_${videoPath.hashCode}.wav';

  onProgress?.call(0.0);

  final totalUs = (info.frameCount / info.fps) * 1000000;

  final process = await Process.start(ffmpeg, [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-progress',
    'pipe:1',
    '-i',
    videoPath,
    '-vn',
    '-acodec',
    'pcm_s16le',
    '-ar',
    '44100',
    '-ac',
    '2',
    wav,
  ]);

  process.stderr
      .transform(const Utf8Decoder())
      .transform(const LineSplitter())
      .drain<void>();

  final stdoutSub = process.stdout
      .transform(const Utf8Decoder())
      .transform(const LineSplitter())
      .listen((line) {
    if (line.startsWith('out_time_us=')) {
      final us = double.tryParse(line.substring('out_time_us='.length));
      if (us != null && totalUs > 0) {
        final p = (us / totalUs).clamp(0.0, 1.0);
        onProgress?.call(p);
      }
    }
  });

  final exitCode = await process.exitCode;
  await stdoutSub.cancel();

  if (exitCode != 0 || !await File(wav).exists()) return null;
  onProgress?.call(1.0);
  _wavCache[videoPath] = wav;
  return wav;
}

/// 清理全部缓存的临时 WAV（state dispose 时调用）。
Future<void> cleanupAudioWavCache() async {
  for (final p in _wavCache.values) {
    try {
      await File(p).delete();
    } catch (_) {
      // 文件被占用等：忽略。
    }
  }
  _wavCache.clear();
}
