import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:debug_tool_set/modules/isp_studio/pipeline/exporters.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('encodeJpgFfmpeg', () {
    // 4x2 渐变 RGBA。
    final rgba = Uint8List(4 * 2 * 4);
    for (var i = 0; i < 8; i++) {
      rgba[i * 4] = i * 30;
      rgba[i * 4 + 1] = 255 - i * 30;
      rgba[i * 4 + 2] = 128;
      rgba[i * 4 + 3] = 255;
    }

    test('内置 ffmpeg 产出合法 JPEG', () async {
      final jpg =
          await encodeJpgFfmpeg('tools/ffmpeg/ffmpeg.exe', rgba, 4, 2, 90);
      expect(jpg, isNotNull);
      expect((jpg![0], jpg[1]), (0xFF, 0xD8)); // SOI
      expect((jpg[jpg.length - 2], jpg.last), (0xFF, 0xD9)); // EOI
      final decoded = img.decodeJpg(jpg);
      expect((decoded?.width, decoded?.height), (4, 2));
    });

    test('ffmpeg 不可用返回 null（由调用方回退 Dart 编码）', () async {
      expect(await encodeJpgFfmpeg('no/such/ffmpeg.exe', rgba, 4, 2, 90),
          isNull);
    });
  });

  group('IspStudioState 图片导出', () {
    test('多帧 RAW 帧级并行导出，产物完整且文件名按帧替换', () async {
      // 8x8、8bit、RGGB，共 3 帧（像素值 0..63 重复）。
      const w = 8, h = 8, frames = 3;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_export_$stamp.raw');
      final dir = Directory('${Directory.systemTemp.path}/isp_export_$stamp');
      await dir.create();
      await raw.writeAsBytes(
          List<int>.generate(w * h * frames, (i) => i % (w * h)));
      try {
        final state = IspStudioState.withDefaultGraph(); // 默认图：源→…→预览→图片输出
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        final outId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'image_output')
            .key;
        state.setParam(srcId, 'filePath', raw.path);
        state.setParam(srcId, 'width', w);
        state.setParam(srcId, 'height', h);
        state.setParam(srcId, 'bitDepth', '8');
        state.setParam(outId, 'directory', dir.path);
        state.setParam(outId, 'fileName', 'f_{frame}');

        await state.exportImages(outId);

        expect(state.statusMessage, contains('图片导出完成（3 帧'));
        for (var i = 0; i < frames; i++) {
          final f = File('${dir.path}${Platform.pathSeparator}f_$i.jpg');
          expect(f.existsSync(), isTrue, reason: '缺 f_$i.jpg');
          expect(f.lengthSync(), greaterThan(0));
        }
      } finally {
        await raw.delete();
        await dir.delete(recursive: true);
      }
    });

    test('多帧 RAW 并行产帧、按序导出 MP4', () async {
      // 8x8、8bit、RGGB，共 3 帧。依赖项目内置的 tools/ffmpeg/ffmpeg.exe。
      const w = 8, h = 8, frames = 3;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_video_$stamp.raw');
      final out =
          File('${Directory.systemTemp.path}/isp_video_$stamp.mp4');
      await raw.writeAsBytes(
          List<int>.generate(w * h * frames, (i) => i % (w * h)));
      try {
        final state = IspStudioState.withDefaultGraph(); // 默认图：源→…→预览
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

        // 预览后面挂一个视频输出节点。
        final vidId = state.graph.addNode('video_output', 0, 0);
        expect(state.graph.connect(prevId, 'out', vidId, 'in'), isNull);
        state.setParam(vidId, 'filePath', out.path);

        await state.exportVideo(vidId);

        expect(state.statusMessage, contains('视频导出完成'));
        expect(out.existsSync(), isTrue);
        expect(out.lengthSync(), greaterThan(0));

        // x264_fast（veryfast 预设）同样能导出。
        state.setParam(vidId, 'encoder', 'x264_fast');
        await state.exportVideo(vidId);
        expect(state.statusMessage, contains('视频导出完成'));
        expect(out.lengthSync(), greaterThan(0));
      } finally {
        await raw.delete();
        if (out.existsSync()) await out.delete();
      }
    });
  });
}
