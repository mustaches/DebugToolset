// 复现用户「YUV多路视频预览」流程的播放基准：
// video_source → yuv_splitter → Y/U/V 三个 mono 预览 → yuv_combiner
// → 主预览；另加全图预览、4 个波形、1 个矢量示波器。
// 全分辨率出帧（预览不缩小），分 1080p / 4K 与 仪器开/关 测稳态帧率。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/providers/isp_studio_state.dart';

Future<void> runBench(
    {required bool withInstruments,
    required int width,
    required int height}) async {
  // 依赖项目内置 ffmpeg；缺失时跳过。
  if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final tmp =
      File('${Directory.systemTemp.path}/isp_bench_multi_${width}x${height}_$stamp.mp4');
  final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi',
    '-i', 'testsrc=size=${width}x$height:rate=30:duration=6',
    '-pix_fmt', 'yuv420p', '-preset', 'ultrafast', tmp.path,
  ]);
  expect(enc.exitCode, 0);
  try {
    final state = IspStudioState.empty();
    final g = state.graph;
    final src = g.addNode('video_source', 0, 0);
    final split = g.addNode('yuv_splitter', 200, 0);
    expect(g.connect(src, 'out_yuv', split, 'in'), isNull);
    final pY = g.addNode('preview', 400, 0);
    final pU = g.addNode('preview', 400, 200);
    final pV = g.addNode('preview', 400, 400);
    expect(g.connect(split, 'out_y', pY, 'in_mono'), isNull);
    expect(g.connect(split, 'out_u', pU, 'in_mono'), isNull);
    expect(g.connect(split, 'out_v', pV, 'in_mono'), isNull);
    final comb = g.addNode('yuv_combiner', 600, 200);
    expect(g.connect(pY, 'out_mono', comb, 'in_y'), isNull);
    expect(g.connect(pU, 'out_mono', comb, 'in_u'), isNull);
    expect(g.connect(pV, 'out_mono', comb, 'in_v'), isNull);
    final pMain = g.addNode('preview', 800, 200);
    expect(g.connect(comb, 'out', pMain, 'in_yuv'), isNull);
    final pFull = g.addNode('preview', 400, 600);
    expect(g.connect(src, 'out_yuv', pFull, 'in_yuv'), isNull);
    if (withInstruments) {
      // 4 波形 + 1 矢量示波器（与用户流程一致）。
      for (final (up, port) in [
        (pFull, 'out_yuv'),
        (pY, 'out_mono'),
        (pU, 'out_mono'),
        (pV, 'out_mono'),
      ]) {
        final w = g.addNode('waveform', 1000, 0);
        expect(
            g.connect(up, port, w, port == 'out_mono' ? 'in_mono' : 'in_yuv'),
            isNull);
      }
      final vs = g.addNode('vectorscope', 1000, 400);
      expect(g.connect(comb, 'out', vs, 'in_yuv'), isNull);
    }
    state.setParam(src, 'filePath', tmp.path);
    await state.autoFillFromVideo(src);
    IspStudioState.debugPlaybackTiming = true;

    final playing = state.togglePlayback();
    final sw = Stopwatch()..start();
    // 预热 1.5s（isolate spawn / 硬解初始化），之后测稳态。
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final produced0 = state.playbackProduced;
    final displayed0 = state.playbackDisplayed;
    final t0 = sw.elapsed;
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    state.stopPlayback();
    await playing;
    final secs = (sw.elapsed - t0).inMicroseconds / 1e6;
    final produced = state.playbackProduced - produced0;
    final displayed = state.playbackDisplayed - displayed0;
    // ignore: avoid_print
    print('多路预览稳态(${width}x$height 仪器${withInstruments ? "开" : "关"}): '
        '取帧 $produced 上屏 $displayed 停滞 ${state.playbackDropped} '
        '(${secs.toStringAsFixed(1)}s, '
        '上屏 ${(displayed / secs).toStringAsFixed(1)}fps, '
        '生产 ${(produced / secs).toStringAsFixed(1)}fps, '
        'pace ${(state.playbackPaceUs / 1000).toStringAsFixed(1)}ms, '
        'maxFetch ${(state.playbackMaxFetchUs / 1000).toStringAsFixed(1)}ms '
        'x${state.playbackFetchStalls})');
    expect(displayed, greaterThan(10));
  } finally {
    // Windows 上 ffmpeg/MCI 句柄释放有延迟，删除失败时重试几次。
    for (var i = 0; i < 5; i++) {
      try {
        await tmp.delete();
        break;
      } on PathAccessException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('1080p 多路预览稳态（仪器开）',
      () => runBench(withInstruments: true, width: 1920, height: 1080));
  test('4K 多路预览稳态（仪器开）',
      () => runBench(withInstruments: true, width: 3840, height: 2160));
}
