// 一次性：真实 4K 4:2:2 片源的播放基准（复现用户场景，量化各环节）。
// 运行: flutter test scratch/playback_bench_4k.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  test('4K Rext 播放基准', () async {
    const video = r'H:\Surgery_video\record-2024-09-26-12-03-24.mp4';
    if (!File(video).existsSync()) return;
    IspStudioState.debugPlaybackTiming = true;
    final state = IspStudioState.withDefaultGraph();
    final prevId = state.graph.nodes.entries
        .firstWhere((e) => e.value.typeId == 'preview')
        .key;
    final srcId = state.graph.addNode('video_source', 0, 0);
    expect(state.graph.connect(srcId, 'out_rgb', prevId, 'in'), isNull);
    state.setParam(srcId, 'filePath', video);
    await state.autoFillFromVideo(srcId);

    final playing = state.togglePlayback();
    await Future<void>.delayed(const Duration(seconds: 12));
    state.stopPlayback();
    await playing;
    // ignore: avoid_print
    print('BENCH produced=${state.playbackProduced} displayed='
        '${state.playbackDisplayed} dropped=${state.playbackDropped} '
        'pace=${state.playbackPaceUs}us maxProd=${state.playbackMaxProdUs}us '
        'maxFetch=${state.playbackMaxFetchUs}us x${state.playbackFetchStalls} '
        'waitOver=${state.playbackMaxWaitOverUs}us '
        'planes=${state.previewPlanes.isNotEmpty}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
