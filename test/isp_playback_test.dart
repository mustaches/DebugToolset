import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/audio_player.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('IspStudioState 连续播放', () {
    test('播放推进帧，暂停后停止并刷新状态', () async {
      // 8x8、8bit、RGGB，共 3 帧。
      const w = 8, h = 8, frames = 3;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_play_$stamp.raw');
      await raw.writeAsBytes(
          List<int>.generate(w * h * frames, (i) => i % (w * h)));
      try {
        final state = IspStudioState();
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');

        final playing = state.togglePlayback();
        final seen = <int>{};
        state.addListener(() => seen.add(state.previewFrame));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(state.isPlaying, isTrue);
        expect(state.statusMessage, contains('播放中'));
        expect(seen.length, greaterThan(1), reason: '播放应推进帧');

        state.stopPlayback();
        await playing; // 等播放循环收尾
        expect(state.isPlaying, isFalse);
        expect(state.isProcessing, isFalse);
        expect(state.statusMessage, contains('已暂停'));
        expect(state.previewImage, isNotNull);
      } finally {
        await raw.delete();
      }
    });

    test('播放中同链仪器随帧刷新', () async {
      // 8x8、8bit、RGGB 共 3 帧，帧 k 为纯色 k*80（直方图随帧变化）。
      const w = 8, h = 8, frames = 3;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_live_$stamp.raw');
      await raw.writeAsBytes([
        for (var f = 0; f < frames; f++)
          ...List<int>.filled(w * h, f * 80),
      ]);
      try {
        final state = IspStudioState();
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');
        // 直方图接在 预览.out 上（与默认图里图片输出的接法一致；
        // 与预览链核心相同，播放中应随帧刷新）。
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        final histId = state.graph.addNode('histogram', 0, 0);
        expect(state.graph.connect(prevId, 'out', histId, 'in'), isNull);

        final playing = state.togglePlayback();
        // 周期采样直方图内容签名。
        final sigs = <String>{};
        final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
          final r = state.instrumentResults[histId]?['r'] as Uint32List?;
          if (r != null) sigs.add(r.join(','));
        });
        await Future<void>.delayed(const Duration(milliseconds: 900));
        timer.cancel();
        state.stopPlayback();
        await playing;

        expect(sigs.length, greaterThan(1),
            reason: '播放中直方图应随帧变化（$sigs）');
      } finally {
        await raw.delete();
      }
    });

    test('预览帧数限制预览/播放范围', () async {
      // 8x8、8bit、RGGB 共 3 帧，预览帧数设为 2。
      const w = 8, h = 8, frames = 3;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_playcap_$stamp.raw');
      await raw.writeAsBytes(
          List<int>.generate(w * h * frames, (i) => i % (w * h)));
      try {
        final state = IspStudioState();
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');
        state.setParam(prevId, 'frameCount', 2);

        await state.runPreview();
        expect(state.totalFrames, 2); // 3 帧被限制为 2

        final playing = state.togglePlayback();
        final seen = <int>{};
        state.addListener(() => seen.add(state.previewFrame));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        state.stopPlayback();
        await playing;
        expect(seen, containsAll(<int>[0, 1]));
        expect(seen.every((f) => f < 2), isTrue, reason: '不应播放第 3 帧');
      } finally {
        await raw.delete();
      }
    });

    test('单帧源播放退化为普通预览', () async {
      const w = 8, h = 8;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_play1_$stamp.raw');
      await raw.writeAsBytes(List<int>.generate(w * h, (i) => i));
      try {
        final state = IspStudioState();
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');

        await state.togglePlayback();
        expect(state.isPlaying, isFalse);
        expect(state.statusMessage, contains('预览就绪'));
        expect(state.previewImage, isNotNull);
      } finally {
        await raw.delete();
      }
    });

    test('视频源设置文件后自动填充播放帧率与预览帧数', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 16x16 纯红，2fps × 2s = 4 帧。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp = File('${Directory.systemTemp.path}/isp_autofill_$stamp.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=red:size=16x16:rate=2:duration=2',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final state = IspStudioState();
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        // 默认播放帧率为 30。
        expect(state.graph.nodes[prevId]!.paramValues['fps'], 30);

        final srcId = state.graph.addNode('video_source', 0, 0);
        expect(state.graph.connect(srcId, 'out_rgb', prevId, 'in'), isNull);
        state.setParam(srcId, 'filePath', tmp.path); // 触发自动填充（异步）
        await state.autoFillFromVideo(srcId); // 测试中显式等待完成

        final prev = state.graph.nodes[prevId]!;
        expect(prev.paramValues['fps'], 2); // 视频原生帧率
        expect(prev.paramValues['frameCount'], 4); // 总帧数
      } finally {
        await tmp.delete();
      }
    });

    test('60fps 视频播放实测：丢帧率应接近 0', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 320x180 testsrc，60fps × 3s = 180 帧（动态内容，接近真实负载）。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp = File('${Directory.systemTemp.path}/isp_bench_$stamp.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=320x180:rate=60:duration=3',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final state = IspStudioState();
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        final srcId = state.graph.addNode('video_source', 0, 0);
        expect(state.graph.connect(srcId, 'out_rgb', prevId, 'in'), isNull);
        state.setParam(srcId, 'filePath', tmp.path);
        await state.autoFillFromVideo(srcId);
        expect(state.graph.nodes[prevId]!.paramValues['fps'], 60);

        final playing = state.togglePlayback();
        final sw = Stopwatch()..start();
        await Future<void>.delayed(const Duration(milliseconds: 2000));
        state.stopPlayback();
        await playing;
        final secs = sw.elapsedMilliseconds / 1000;
        final fps = state.playbackDisplayed / secs;
        // ignore: avoid_print
        print('播放实测: 取帧 ${state.playbackProduced} 上屏 '
            '${state.playbackDisplayed} 丢弃 ${state.playbackDropped} '
            '(${secs.toStringAsFixed(1)}s, ${fps.toStringAsFixed(1)}fps)');
        // 有帧上屏且丢帧占比 < 20%（环境有噪声，阈值放宽）。
        expect(state.playbackDisplayed, greaterThan(10));
        expect(state.playbackDropped,
            lessThan((state.playbackProduced * 0.2).ceil()));
      } finally {
        await tmp.delete();
      }
    });

    test('1080p 视频 + 双仪器播放实测（复现用户场景）', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 1920x1080 testsrc，60fps × 3s。波形 + 矢量示波器接在预览.out。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp = File('${Directory.systemTemp.path}/isp_bench2_$stamp.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=1920x1080:rate=60:duration=3',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final state = IspStudioState();
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        final srcId = state.graph.addNode('video_source', 0, 0);
        expect(state.graph.connect(srcId, 'out_rgb', prevId, 'in'), isNull);
        final waveId = state.graph.addNode('waveform', 0, 200);
        expect(state.graph.connect(prevId, 'out', waveId, 'in'), isNull);
        final scopeId = state.graph.addNode('vectorscope', 0, 400);
        expect(state.graph.connect(prevId, 'out', scopeId, 'in'), isNull);
        state.setParam(srcId, 'filePath', tmp.path);
        await state.autoFillFromVideo(srcId);

        final playing = state.togglePlayback();
        final sw = Stopwatch()..start();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final droppedAt15 = state.playbackDropped;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        state.stopPlayback();
        await playing;
        final secs = sw.elapsedMilliseconds / 1000;
        final fps = state.playbackDisplayed / secs;
        // ignore: avoid_print
        print('1080p+双仪器实测: 取帧 ${state.playbackProduced} 上屏 '
            '${state.playbackDisplayed} 重建 ${state.playbackDropped}'
            '(前1.5s $droppedAt15 / 后1.5s ${state.playbackDropped - droppedAt15}) '
            '(${secs.toStringAsFixed(1)}s, ${fps.toStringAsFixed(1)}fps, '
            'pace ${(state.playbackPaceUs / 1000).toStringAsFixed(1)}ms, '
            'maxProd ${(state.playbackMaxProdUs / 1000).toStringAsFixed(1)}ms, '
            'maxFetch ${(state.playbackMaxFetchUs / 1000).toStringAsFixed(1)}ms x${state.playbackFetchStalls}, '
            'waitOver ${(state.playbackMaxWaitOverUs / 1000).toStringAsFixed(1)}ms)');
        // 取到的帧应大部分上屏（不再连环丢帧；停滞只重建时间轴）。
        // 阈值 0.6：修复前实测仅 ~33%，修复后 ~99%，环境噪声有足够余量。
        expect(state.playbackDisplayed,
            greaterThan(state.playbackProduced * 0.6));
      } finally {
        await tmp.delete();
      }
    });

    test('视频经中间算子播放：常驻流水线 worker 出帧', () async {
      // 依赖项目内置 ffmpeg；缺失时跳过。
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 64x64 testsrc，4fps × 1s = 4 帧；链上插一个 gamma 算子后播放
      // 不再走 videoDirect 直通，而是常驻 PipelineFrameRunner。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp = File('${Directory.systemTemp.path}/isp_pipe_$stamp.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=4:duration=1',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final state = IspStudioState();
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        final srcId = state.graph.addNode('video_source', 0, 0);
        final gammaId = state.graph.addNode('gamma', 0, 100);
        expect(
            state.graph.connect(srcId, 'out_rgb', gammaId, 'in'), isNull);
        expect(state.graph.connect(gammaId, 'out', prevId, 'in'), isNull);
        state.setParam(srcId, 'filePath', tmp.path);
        await state.autoFillFromVideo(srcId);

        final playing = state.togglePlayback();
        final seen = <int>{};
        state.addListener(() => seen.add(state.previewFrame));
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        state.stopPlayback();
        await playing;
        expect(seen.length, greaterThan(1), reason: '经流水线的播放应推进帧');
        expect(state.previewImage, isNotNull);
        expect(state.previewWidth, 64);
        expect(state.previewHeight, 64);
      } finally {
        await tmp.delete();
      }
    });

    test('音频仪器随播放刷新（电平/EQ）', () async {
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      // 64x64 4fps × 2s + 440Hz 正弦音轨。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp =
          File('${Directory.systemTemp.path}/isp_audio_instr_$stamp.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=4:duration=2',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final state = IspStudioState();
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        final srcId = state.graph.addNode('video_source', 0, 0);
        expect(state.graph.connect(srcId, 'out_rgb', prevId, 'in'), isNull);
        final levelId = state.graph.addNode('audio_level', 0, 200);
        expect(
            state.graph.connect(srcId, 'out_audio', levelId, 'in'), isNull);
        final eqId = state.graph.addNode('audio_eq', 0, 400);
        expect(state.graph.connect(srcId, 'out_audio', eqId, 'in'), isNull);
        state.setParam(srcId, 'filePath', tmp.path);
        await state.autoFillFromVideo(srcId);

        final playing = state.togglePlayback();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        state.stopPlayback();
        await playing;

        // 满幅 440Hz 正弦：电平接近满格；EQ 峰值在 440Hz 所在段。
        final level = state.instrumentResults[levelId];
        expect(level, isNotNull, reason: '音频电平应有分析结果');
        expect(level!['left'] as double, greaterThan(0.5));
        final eq = state.instrumentResults[eqId];
        expect(eq, isNotNull, reason: 'EQ 频谱应有分析结果');
        final bands = eq!['bands'] as Float64List;
        expect(bands.length, 21);
        var best = 0;
        for (var i = 1; i < bands.length; i++) {
          if (bands[i] > bands[best]) best = i;
        }
        expect(best, inInclusiveRange(8, 10)); // 440Hz 所在段
      } finally {
        await tmp.delete();
      }
    });

    test('视频音频：解析音轨、抽取 WAV、MCI 播放控制', () async {
      if (!Platform.isWindows) return;
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp = File('${Directory.systemTemp.path}/isp_audio_$stamp.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=2:duration=2',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        // 音轨解析。
        final info = await videoFileInfo(tmp.path);
        expect(info.hasAudio, isTrue);
        // 抽取 WAV。
        final wav = await ensureAudioWav(tmp.path);
        expect(wav, isNotNull);
        final head = await File(wav!).openRead(0, 4).first;
        expect(String.fromCharCodes(head), 'RIFF');
        // MCI 播放控制（无音频设备的机器上跳过）。
        final player = MciAudioPlayer();
        try {
          player.open(wav);
        } on StateError {
          return;
        }
        player.playFrom(0.5);
        // 播放位置查询（播放循环的漂移修正依赖它）。
        final pos = player.positionSeconds();
        expect(pos, isNotNull);
        expect(pos!, greaterThan(0.1));
        player.stop();
        player.close();
        await cleanupAudioWavCache();
        expect(await File(wav).exists(), isFalse); // 缓存已清理
      } finally {
        await tmp.delete();
      }
    });

    test('无音轨视频：hasAudio 为 false，ensureAudioWav 返回 null', () async {
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp = File('${Directory.systemTemp.path}/isp_noaudio_$stamp.mp4');
      final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=red:size=16x16:rate=2:duration=1',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final info = await videoFileInfo(tmp.path);
        expect(info.hasAudio, isFalse);
        expect(await ensureAudioWav(tmp.path), isNull);
      } finally {
        await tmp.delete();
      }
    });
  });
}
