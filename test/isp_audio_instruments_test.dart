import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/audio_analysis.dart';

/// 造一段立体声 PCM：左声道 [freqL]、右声道 [freqR] 正弦（0 = 静音），
/// 幅度 [amp]（0..1）。
WavPcm sinePcm(double freqL, double freqR,
    {double amp = 0.8, double seconds = 1.0, int sampleRate = 44100}) {
  final frames = (seconds * sampleRate).round();
  final samples = Int16List(frames * 2);
  for (var f = 0; f < frames; f++) {
    samples[f * 2] = freqL <= 0
        ? 0
        : (math.sin(2 * math.pi * freqL * f / sampleRate) * amp * 32767)
            .round();
    samples[f * 2 + 1] = freqR <= 0
        ? 0
        : (math.sin(2 * math.pi * freqR * f / sampleRate) * amp * 32767)
            .round();
  }
  return WavPcm(sampleRate, 2, samples);
}

/// 手工拼一个最小 16 位 PCM WAV 文件字节。
Uint8List buildWav(Int16List samples, int channels, int sampleRate) {
  final dataSize = samples.length * 2;
  final bd = ByteData(44 + dataSize);
  final b = bd.buffer.asUint8List();
  b.setRange(0, 4, 'RIFF'.codeUnits);
  bd.setUint32(4, 36 + dataSize, Endian.little);
  b.setRange(8, 12, 'WAVE'.codeUnits);
  b.setRange(12, 16, 'fmt '.codeUnits);
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * 2, Endian.little);
  bd.setUint16(32, channels * 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  b.setRange(36, 40, 'data'.codeUnits);
  bd.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return b;
}

int argmax(Float64List v) {
  var best = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[best]) best = i;
  }
  return best;
}

void main() {
  group('parseWavPcm', () {
    test('解析 16 位 PCM WAV 往返一致', () {
      final src = sinePcm(440, 880, seconds: 0.1);
      final pcm = parseWavPcm(buildWav(src.samples, 2, 44100));
      expect(pcm.sampleRate, 44100);
      expect(pcm.channels, 2);
      expect(pcm.samples, src.samples);
    });

    test('拒绝非 WAV 与非 16 位 PCM', () {
      expect(() => parseWavPcm(Uint8List.fromList('not a wav'.codeUnits)),
          throwsStateError);
      // 8 位 PCM：bits 字段改为 8。
      final bad = buildWav(Int16List(16), 2, 44100);
      ByteData.sublistView(bad).setUint16(34, 8, Endian.little);
      expect(() => parseWavPcm(bad), throwsStateError);
    });
  });

  group('audioLevels', () {
    test('满幅正弦接近 1.0，静音为 0', () {
      final pcm = sinePcm(440, 440, amp: 1.0);
      final r = audioLevels(pcm, 0.5);
      expect(r['kind'], 'audio_level');
      expect(r['left'] as double, greaterThan(0.95));
      expect(r['right'] as double, greaterThan(0.95));

      final silent = sinePcm(0, 0);
      final r0 = audioLevels(silent, 0.5);
      expect(r0['left'], 0.0);
      expect(r0['right'], 0.0);
    });

    test('左右声道独立；起点之前无样本为 0（因果窗）', () {
      final pcm = sinePcm(440, 0, amp: 0.8); // 仅左声道
      final r = audioLevels(pcm, 0.5);
      expect(r['left'] as double, greaterThan(0.5));
      expect(r['right'], 0.0);
      // 位置 0：窗内无样本。
      final at0 = audioLevels(pcm, 0.0);
      expect(at0['left'], 0.0);
    });
  });

  group('audioWaveform', () {
    test('正弦波形的采样点覆盖正负摆幅，带格式信息', () {
      final pcm = sinePcm(440, 440, amp: 0.8);
      final r = audioWaveform(pcm, 0.5, points: 64);
      expect(r['kind'], 'audio_waveform');
      expect(r['sampleRate'], 44100);
      expect(r['bits'], 16);
      final l = r['l'] as Float32List;
      // 92ms 窗内约 4055 个样本，降为 64 个等距采样点。
      expect(l.length, 64);
      // 窗内有约 40 个周期：采样点整体应接近 ±0.8。
      expect(l.reduce(math.max), closeTo(0.8, 0.1));
      expect(l.reduce(math.min), closeTo(-0.8, 0.1));
      // 静音：全 0。
      final silent = audioWaveform(sinePcm(0, 0), 0.5)['l'] as Float32List;
      expect(silent.every((v) => v == 0), isTrue);
    });

    test('单声道左右相同；起点之前无样本为空（因果窗）', () {
      final stereo = sinePcm(440, 0, amp: 0.8);
      final pcm = WavPcm(stereo.sampleRate, 1,
          Int16List.fromList([
            for (var f = 0; f < stereo.frames; f++) stereo.samples[f * 2]
          ]));
      final r = audioWaveform(pcm, 0.5, points: 64);
      expect(r['l'], r['r']);
      // 位置 0：窗内无样本。
      final at0 = audioWaveform(pcm, 0.0);
      expect((at0['l'] as Float32List), isEmpty);
    });
  });

  group('audioEqBands', () {
    test('31 段，正弦峰值落在对应频段', () {
      final pcm = sinePcm(440, 440);
      final r = audioEqBands(pcm, 0.5);
      expect(r['kind'], 'audio_eq');
      final bands = r['left'] as Float64List;
      expect(bands.length, kAudioEqBands);
      // 440Hz 落在第 13 段（1/3 倍频程，段中心 20×10^1.3 ≈ 399Hz，
      // 相邻段中心 317/502Hz）；允许相邻一段的泄漏容差。
      expect(argmax(bands), inInclusiveRange(12, 14));
      // 峰值段接近满幅（Hann 还原后 ≈0.8 → -1.9dB）。
      expect(bands[argmax(bands)], greaterThan(0.8));
    });

    test('左右声道独立：440Hz 只在左，2kHz 只在右', () {
      final r = audioEqBands(sinePcm(440, 2000), 0.5);
      final left = r['left'] as Float64List;
      final right = r['right'] as Float64List;
      // 440Hz → 第 13 段；2kHz → 第 20 段（中心 20×10^2.0 = 2000Hz）。
      expect(argmax(left), inInclusiveRange(12, 14));
      expect(argmax(right), inInclusiveRange(19, 21));
      // 对侧声道在该频段基本为零（<-40dB）。
      expect(left[argmax(right)], lessThan(0.35));
      expect(right[argmax(left)], lessThan(0.35));
    });

    test('高低频分辨：100Hz 在低段，5kHz 在高段', () {
      final low =
          audioEqBands(sinePcm(100, 100), 0.5)['left'] as Float64List;
      final high =
          audioEqBands(sinePcm(5000, 5000), 0.5)['left'] as Float64List;
      // 100Hz → 第 7 段（中心 20×10^0.7 ≈ 100Hz）；5kHz → 第 24 段
      // （中心 20×10^2.4 ≈ 5024Hz）。
      expect(argmax(low), inInclusiveRange(6, 8));
      expect(argmax(high), inInclusiveRange(23, 25));
      // 静音：全 0。
      final silent =
          audioEqBands(sinePcm(0, 0), 0.5)['left'] as Float64List;
      expect(silent.every((v) => v == 0), isTrue);
    });
  });
}
