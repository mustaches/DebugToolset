// 临时基准：多段色彩均衡器对视频播放帧率的影响（CPU 路径）。
// 对比 视频源→预览 直连 与 视频源→multi_band_eq→预览 的 1080p60 播放
// 上屏帧率，定位附加区同步引入的开销。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

Future<void> deleteWithRetry(File f) async {
  for (var i = 0; i < 50; i++) {
    try {
      await f.delete();
      return;
    } on PathAccessException {
      if (i == 49) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  test('均衡器播放开销对比', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tmp = File('${Directory.systemTemp.path}/isp_eq_bench_$stamp.mp4');
    final enc = await Process.run(File('tools/ffmpeg/ffmpeg.exe').absolute.path, [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'testsrc=size=1920x1080:rate=60:duration=3',
      '-pix_fmt', 'yuv420p', tmp.path,
    ]);
    expect(enc.exitCode, 0);
    try {
      Future<(int, int, int)> play(int mode) async {
        final state = IspStudioState.withDefaultGraph();
        final prevId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'preview')
            .key;
        final srcId = state.graph.addNode('video_source', 0, 0);
        if (mode == 1) {
          final eqId = state.graph.addNode('multi_band_eq', 0, 100);
          expect(state.graph.connect(srcId, 'out_hsl', eqId, 'in'), isNull);
          state.graph.disconnectInput(prevId, 'in');
          expect(state.graph.connect(eqId, 'out', prevId, 'in_hsl'), isNull);
          // 非恒等段（ΔH +30°）：保证均衡器算子真实参与每帧计算。
          state.setParam(eqId, 'b0_dh', 30.0);
        } else if (mode == 2) {
          // 对照：gamma 中间算子同样迫使走 GPU 链播放，但无均衡器馈源。
          final gammaId = state.graph.addNode('gamma', 0, 100);
          expect(state.graph.connect(srcId, 'out_rgb', gammaId, 'in'), isNull);
          state.graph.disconnectInput(prevId, 'in');
          expect(state.graph.connect(gammaId, 'out', prevId, 'in'), isNull);
        } else {
          expect(state.graph.connect(srcId, 'out_rgb', prevId, 'in'), isNull);
        }
        state.setParam(srcId, 'filePath', tmp.path);
        await state.autoFillFromVideo(srcId);
        IspStudioState.debugPlaybackTiming = true;

        final playing = state.togglePlayback();
        await Future<void>.delayed(const Duration(milliseconds: 8000));
        state.stopPlayback();
        await playing;
        IspStudioState.debugPlaybackTiming = false;
        return (
          state.playbackProduced,
          state.playbackDisplayed,
          state.playbackDropped
        );
      }

      final base = await play(0);
      // ignore: avoid_print
      print('无中间算子: 取帧 ${base.$1} 上屏 ${base.$2} 丢弃 ${base.$3} '
          '(8s, ${(base.$2 / 8).toStringAsFixed(1)}fps)');
      final withGamma = await play(2);
      // ignore: avoid_print
      print('gamma对照: 取帧 ${withGamma.$1} 上屏 ${withGamma.$2} '
          '丢弃 ${withGamma.$3} '
          '(8s, ${(withGamma.$2 / 8).toStringAsFixed(1)}fps)');
      final withEq = await play(1);
      // ignore: avoid_print
      print('有均衡器: 取帧 ${withEq.$1} 上屏 ${withEq.$2} 丢弃 ${withEq.$3} '
          '(8s, ${(withEq.$2 / 8).toStringAsFixed(1)}fps)');
    } finally {
      await deleteWithRetry(tmp);
    }
  });
}
