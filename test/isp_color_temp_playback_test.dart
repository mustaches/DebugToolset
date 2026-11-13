import 'dart:io';
import 'dart:ui' as ui;

import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逐帧图像哈希（FNV-1a，同帧稳定、异帧几乎必不同）。
Future<int> _imageHash(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  var hash = 2166136261;
  for (final byte in data!.buffer.asUint8List()) {
    hash = ((hash ^ byte) * 16777619) & 0x7fffffff;
  }
  return hash;
}

Future<void> _deleteWithRetry(File f) async {
  for (var i = 0; i < 8; i++) {
    try {
      if (f.existsSync()) f.deleteSync();
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
}

/// 生成 testsrc 测试视频（4fps × 4s，16 帧，够推进到第 8 帧以上）。
/// 返回 null 表示内置 ffmpeg 缺失（用例跳过）。
Future<File?> _makeTestVideo(String tag) async {
  final ffmpeg = File('tools/ffmpeg/ffmpeg.exe');
  if (!ffmpeg.existsSync()) return null;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final tmp = File('${Directory.systemTemp.path}/${tag}_$stamp.mp4');
  final enc = await Process.run(ffmpeg.absolute.path, [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=64x64:rate=4:duration=4',
    '-pix_fmt',
    'yuv420p',
    tmp.path,
  ]);
  expect(enc.exitCode, 0, reason: '测试视频生成失败：${enc.stderr}');
  return tmp;
}

/// 视频源 → 色温调节器（色温节点自带前后双联预览，即「原图 / 调整后」）。
/// 返回（state, 视频源 id, 色温节点 id）。默认链的预览节点输入被摘掉，
/// 保证播放汇点只有色温调节器。
Future<(IspStudioState, String, String)> _buildCtFlow(File video) async {
  final state = IspStudioState.withDefaultGraph();
  final prevId = state.graph.nodes.entries
      .firstWhere((e) => e.value.typeId == 'preview')
      .key;
  state.graph.disconnectInput(prevId, 'in');
  final srcId = state.graph.addNode('video_source', 0, 0);
  final ctId = state.graph.addNode('color_temp_adjuster', 0, 100);
  expect(state.graph.connect(srcId, 'out_rgb', ctId, 'in'), isNull);
  state.setParam(srcId, 'filePath', video.path);
  await state.autoFillFromVideo(srcId);
  return (state, srcId, ctId);
}

void main() {
  test('色温流程的原图与调整后视频预览均随播放逐帧更新', () async {
    final video = await _makeTestVideo('isp_ct_play');
    if (video == null) return;
    final (state, _, ctId) = await _buildCtFlow(video);
    addTearDown(state.dispose);
    try {
      final playing = state.togglePlayback();
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while ((state.previewFrame < 2 ||
              state.previewImages[ctId] == null ||
              state.previewInputImages[ctId] == null) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.previewImages[ctId], isNotNull, reason: '「调整后」预览应有图');
      expect(state.previewInputImages[ctId], isNotNull, reason: '「原图」预览应有图');
      final firstOut = await _imageHash(state.previewImages[ctId]!);
      final firstIn = await _imageHash(state.previewInputImages[ctId]!);

      final secondDeadline = DateTime.now().add(const Duration(seconds: 25));
      while (state.previewFrame < 8 &&
          DateTime.now().isBefore(secondDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.previewFrame, greaterThanOrEqualTo(8), reason: '播放应推进到第 8 帧');
      final secondOut = await _imageHash(state.previewImages[ctId]!);
      final secondIn = await _imageHash(state.previewInputImages[ctId]!);
      state.stopPlayback();
      await playing;

      expect(secondOut, isNot(firstOut), reason: '「调整后」预览应逐帧更新');
      expect(secondIn, isNot(firstIn), reason: '「原图」预览应逐帧更新');
    } finally {
      await _deleteWithRetry(video);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('色温调节器附加区双联预览（调整前/调整后）随播放逐帧更新，停播后刷新测量值', () async {
    final video = await _makeTestVideo('isp_ct_dual');
    if (video == null) return;
    final (state, _, ctId) = await _buildCtFlow(video);
    addTearDown(state.dispose);
    try {
      final playing = state.togglePlayback();
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while ((state.previewFrame < 2 ||
              state.previewImages[ctId] == null ||
              state.previewInputImages[ctId] == null) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.previewImages[ctId], isNotNull,
          reason: '播放中「调整后」预览应有图');
      expect(state.previewInputImages[ctId], isNotNull,
          reason: '播放中「调整前」预览应有图');
      // 播放中测量值冻结，停播时以最后一帧补齐。
      state.stopPlayback();
      await playing;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(state.measuredColorTemps[ctId], isNotNull,
          reason: '停播后应刷新测量色温');
      expect(state.colorTempHistograms[ctId], isNotNull,
          reason: '停播后应刷新调整后直方图');
    } finally {
      await _deleteWithRetry(video);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
