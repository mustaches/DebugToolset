import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/export_segments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('splitVideoByPackets 按包分段', () {
    final ff = File('tools/ffmpeg/ffmpeg.exe').absolute.path;

    Future<String> makeSrc(String path, int frames, {int gop = 12}) async {
      final mk = await Process.run(ff, [
        '-hide_banner', '-y',
        '-f', 'lavfi', '-i',
        'testsrc=duration=${frames / 30}:size=320x180:rate=30',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '$gop', path,
      ]);
      expect(mk.exitCode, 0, reason: '${mk.stderr}');
      return path;
    }

    test('关键帧对齐拆分：段数/帧数精确、总和等于源', () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final src = '${Directory.systemTemp.path}/isp_split_$stamp.mp4';
      final dir = await Directory.systemTemp.createTemp('isp_split_');
      try {
        await makeSrc(src, 48); // 48 帧，GOP 12 → 关键帧 0/12/24/36
        final parts = await splitVideoByPackets(ff, src, 48 / 30, 2, dir.path);
        expect(parts.length, greaterThanOrEqualTo(2));
        var sum = 0;
        for (final part in parts) {
          final c = await countVideoFramesFast(ff, part);
          expect(c, isNotNull);
          expect(c, greaterThan(0));
          sum += c!;
        }
        expect(sum, 48, reason: '各段帧数总和应等于源帧数（精确划分）');
      } finally {
        final f = File(src);
        if (f.existsSync()) await f.delete();
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });

    test('关键帧过稀（GOP 大于段长）返回空表 → 调用方回退', () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final src = '${Directory.systemTemp.path}/isp_split_$stamp.mp4';
      final dir = await Directory.systemTemp.createTemp('isp_split_');
      try {
        await makeSrc(src, 24, gop: 250); // 只有起始关键帧
        final parts = await splitVideoByPackets(ff, src, 24 / 30, 2, dir.path);
        expect(parts, isEmpty);
      } finally {
        final f = File(src);
        if (f.existsSync()) await f.delete();
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });

    test('时长/段数非法返回空表', () async {
      expect(await splitVideoByPackets(ff, 'whatever.mp4', 0, 2, '.'), isEmpty);
      expect(await splitVideoByPackets(ff, 'whatever.mp4', 10, 1, '.'), isEmpty);
    });
  });

  group('concatListContent 拼接清单', () {
    test('file 行、Windows 反斜杠转正斜杠', () {
      final content = concatListContent(
          [r'C:\tmp\a.seg0.mp4', r'D:\out dir\b.seg1.mp4']);
      expect(
          content,
          "file 'C:/tmp/a.seg0.mp4'\n"
          "file 'D:/out dir/b.seg1.mp4'");
    });
  });

  group('ffmpeg 输出解析', () {
    test('parseFfmpegDurationSec', () {
      expect(
          parseFfmpegDurationSec(
              'xxx Duration: 00:00:03.00, start: 0.000000 yyy'),
          closeTo(3.0, 1e-9));
      expect(parseFfmpegDurationSec('Duration: 01:02:03.50'),
          closeTo(3723.5, 1e-9));
      expect(parseFfmpegDurationSec('no duration here'), isNull);
    });

    test('parseFfmpegFrameCount 取最后一次 frame=（进度行 \\r 覆写）', () {
      expect(parseFfmpegFrameCount('frame=   12 fps=30\rframe=  240 fps=31'),
          240);
      expect(parseFfmpegFrameCount('frame=27000 fps=15961 q=-1.0 Lsize=N/A'),
          27000);
      expect(parseFfmpegFrameCount('no frames'), isNull);
    });
  });

  group('validateConcatOutput 产物校验', () {
    final ff = File('tools/ffmpeg/ffmpeg.exe').absolute.path;

    test('文件缺失/无法解析 → false（调用方回退单段）', () async {
      expect(await validateConcatOutput(ff, 'no/such/out.mp4', 24, 30),
          isFalse);
    });

    test('帧数不符 → false', () async {
      // 造 12 帧 mp4 但按 24 帧校验。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final f = File('${Directory.systemTemp.path}/isp_segval_$stamp.mp4');
      try {
        final mk = await Process.run(ff, [
          '-hide_banner', '-y',
          '-f', 'lavfi', '-i', 'testsrc=duration=0.4:size=320x180:rate=30',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', f.path,
        ]);
        expect(mk.exitCode, 0, reason: '${mk.stderr}');
        expect(await validateConcatOutput(ff, f.path, 24, 30), isFalse);
        expect(await validateConcatOutput(ff, f.path, 12, 30), isTrue);
      } finally {
        if (f.existsSync()) await f.delete();
      }
    });
  });

  group('VideoFrameStream maxFrames 收尾', () {
    test('送满 maxFrames 即 EOF，dispose 正常返回', () async {
      // 分段导出每段按确切帧数起流：worker 送满即自行 EOF，段尾不
      // 依赖 UI 归还节奏（背压竞赛的结构性修复）。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final src = File('${Directory.systemTemp.path}/isp_maxf_$stamp.mp4');
      try {
        final ff = File('tools/ffmpeg/ffmpeg.exe').absolute.path;
        final mk = await Process.run(ff, [
          '-hide_banner', '-y',
          '-f', 'lavfi', '-i', 'testsrc=duration=0.4:size=320x180:rate=30',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', src.path,
        ]);
        expect(mk.exitCode, 0, reason: '${mk.stderr}'); // 12 帧

        final stream = await VideoFrameStream.start(src.path, 0,
            ffmpegPath: ff, pixelFormat: 'yuv420p', hwaccel: '', maxFrames: 5);
        addTearDown(stream.dispose);
        var got = 0;
        while (true) {
          final f = await stream.next()
              .timeout(const Duration(seconds: 15), onTimeout: () => null);
          if (f == null) break; // EOF（或超时——按失败处理）
          got++;
          stream.recycle(f);
          if (got > 12) break;
        }
        expect(got, 5, reason: '应恰好送出 maxFrames=5 帧后 EOF');
      } finally {
        if (src.existsSync()) await src.delete();
      }
    });
  });

  group('IspStudioState 分段并行导出', () {
    test('24 帧 video_source GPU 链分段导出：帧数/时长正确、状态栏标注段数',
        () async {
      // 24 帧（≥ _kExportSegMinFrames 16）触发分段；源带周期关键帧
      // （-g 12）保证可按包拆分。GPU 链不可用（无 shader 环境）时回退
      // CPU 池/单段，断言相应放宽。
      const w = 320, h = 180, frames = 24;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final src = File('${Directory.systemTemp.path}/isp_seg_$stamp.mp4');
      final out =
          File('${Directory.systemTemp.path}/isp_seg_out_$stamp.mp4');
      try {
        final ff = File('tools/ffmpeg/ffmpeg.exe').absolute.path;
        final mk = await Process.run(ff, [
          '-hide_banner', '-y',
          '-f', 'lavfi', '-i',
          'testsrc=duration=${frames / 30}:size=${w}x$h:rate=30',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-g', '12', src.path,
        ]);
        expect(mk.exitCode, 0, reason: '${mk.stderr}');

        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('video_source', 0, 0);
        state.setParam(srcId, 'filePath', src.path);
        final dbgId = state.graph.addNode('rgb_debugger', 200, 0);
        expect(state.graph.connect(srcId, 'out_rgb', dbgId, 'in'), isNull);
        final vidId = state.graph.addNode('video_output', 400, 0);
        expect(state.graph.connect(dbgId, 'out', vidId, 'in'), isNull);
        state.setParam(vidId, 'filePath', out.path);
        state.setParam(vidId, 'encoder', 'x264');

        await state.exportVideo(vidId);

        expect(state.statusMessage, contains('视频导出完成'));
        if (state.statusMessage.contains('GPU 链')) {
          expect(state.statusMessage, contains('×2 段'),
              reason: 'GPU 链可用时应走分段并行：${state.statusMessage}');
        }
        // 产物校验（与分段路径内部同一口径）。
        expect(out.existsSync(), isTrue);
        expect(await validateConcatOutput(ff, out.path, frames, 30), isTrue);
      } finally {
        if (src.existsSync()) await src.delete();
        if (out.existsSync()) await out.delete();
      }
    });
  });
}
