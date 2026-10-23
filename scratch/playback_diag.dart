// 一次性：诊断播放循环异常（vsync 改动后非视频源播放即停）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  test('diag playback exception', () async {
    const w = 8, h = 8, frames = 3;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final raw = File('${Directory.systemTemp.path}/isp_diag_$stamp.raw');
    await raw.writeAsBytes([
      for (final v in List<int>.generate(w * h * frames, (i) => i % (w * h))) ...[
        v & 0xFF,
        (v >> 8) & 0xFF
      ],
    ]);
    try {
      final state = IspStudioState.withDefaultGraph();
      final srcId = state.graph.nodes.entries
          .firstWhere((e) => e.value.typeId == 'bayer_source')
          .key;
      state.setParam(srcId, 'filePath', raw.path);
      state.setParam(srcId, 'width', w);
      state.setParam(srcId, 'height', h);
      state.setParam(srcId, 'bitDepth', '8');
      final playing = state.togglePlayback();
      unawaited(playing.catchError((Object e, st) {
        // ignore: avoid_print
        print('PLAY ERROR: $e\n$st');
        return null;
      }));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      // ignore: avoid_print
      print('isPlaying=${state.isPlaying} status=${state.statusMessage} '
          'produced=${state.playbackProduced} displayed='
          '${state.playbackDisplayed}');
      state.stopPlayback();
      await playing;
    } finally {
      await raw.delete();
    }
  });
}
