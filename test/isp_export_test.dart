import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:debug_tool_set/modules/isp_studio/pipeline/export_progress.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/exporters.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('videoDecodeArgs 流式解码参数', () {
    test('yuv420p + hwaccel + 寻址参数组装', () {
      final args = videoDecodeArgs(
          pixelFormat: 'yuv420p', hwaccel: 'd3d11va', startSec: 1.5);
      expect(
          args,
          containsAllInOrder([
            '-hwaccel', 'd3d11va',
            '-ss', '1.500000',
            '-i', '__PATH__',
            '-f', 'rawvideo', '-pix_fmt', 'yuv420p', 'pipe:1',
          ]));
      // 默认：无 hwaccel、无寻址、rgba。
      final def = videoDecodeArgs(pixelFormat: 'rgba');
      expect(def, isNot(contains('-hwaccel')));
      expect(def, isNot(contains('-ss')));
      expect(def, containsAllInOrder(['-pix_fmt', 'rgba', 'pipe:1']));
    });
  });

  group('mp4CodecArgs 编码器参数', () {
    test('nvenc 用 h264_nvenc + preset p6 + cq；x264 系用 libx264 + crf', () {
      final nvenc = mp4CodecArgs('nvenc', 18);
      expect(
          nvenc,
          containsAllInOrder([
            '-c:v', 'h264_nvenc', '-preset', 'p6', '-pix_fmt', 'yuv420p',
            '-cq', '18'
          ]));
      final x264 = mp4CodecArgs('x264', 23);
      expect(x264, containsAllInOrder(
          ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '23']));
      final fast = mp4CodecArgs('x264_fast', 20);
      expect(fast, containsAllInOrder(
          ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20']));
      // 未知编码器回退 libx264；crf 钳位 0..51。
      expect(mp4CodecArgs('???', 99),
          containsAllInOrder(['-c:v', 'libx264', '-crf', '51']));
    });

    test('内置 ffmpeg 的 NVENC 探测返回布尔（本机 RTX 4090 应为 true）',
        () async {
      expect(await probeNvencEncoder('tools/ffmpeg/ffmpeg.exe'), isTrue);
    });
  });

  /// 8bit unpacked RAW：每像素一个 16 位小端字（LSB 对齐，与位深无关）。
  List<int> raw8Le(Iterable<int> px) => [
        for (final v in px) ...[v & 0xFF, (v >> 8) & 0xFF],
      ];

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

  group('ExportEtaTracker / ExportProgressInfo', () {
    test('formatHhMmSs 秒 → HH:MM:SS（含两小时以上进位）', () {
      expect(formatHhMmSs(0), '00:00:00');
      expect(formatHhMmSs(8.9), '00:00:08');
      expect(formatHhMmSs(84.3), '00:01:24');
      expect(formatHhMmSs(600), '00:10:00');
      expect(formatHhMmSs(3661), '01:01:01');
      expect(formatHhMmSs(7384), '02:03:04'); // >2h 正常进位
      expect(formatHhMmSs(360000), '100:00:00'); // 小时超 99 自然扩展
    });

    test('滑动窗口帧率：窗口首尾间隔求平均，不足 2 帧为 0', () {
      final t = ExportEtaTracker();
      expect(t.smoothFps, 0);
      t.add(1000);
      expect(t.smoothFps, 0); // 仍不足 2 帧
      // 200ms 等间隔 → 5 帧/秒。
      for (var i = 1; i < 8; i++) {
        t.add(1000 + i * 200);
      }
      expect(t.smoothFps, closeTo(5.0, 1e-9));
      // 窗口（8）滑满后反映新速度：100ms 间隔 → 10 帧/秒。
      for (var i = 0; i < 8; i++) {
        t.add(3000 + i * 100);
      }
      expect(t.smoothFps, closeTo(10.0, 1e-9));
    });

    test('statusLine：估算中 → 剩余 HH:MM:SS → 剩余 <1s', () {
      final info = ExportProgressInfo(
          width: 1920, height: 1080, fps: 30, totalFrames: 240);
      expect(info.totalSeconds, closeTo(8.0, 1e-9));
      // 未喂帧：帧率未知。
      expect(
          info.statusLine(), contains('导出中 1920×1080 @30fps 时长 00:00:08'));
      expect(info.statusLine(), contains('0/240 帧'));
      expect(info.statusLine(), contains('估算中'));

      // 10ms 等间隔喂帧 → 100 帧/秒。
      var t = 1000;
      for (var i = 0; i < 8; i++) {
        info.addFrame(t += 10);
      }
      expect(info.smoothFps, closeTo(100.0, 1e-9));
      // done 8，剩 232 帧 @100fps ≈ 2.3s → 向下取整 00:00:02。
      expect(info.statusLine(), contains('8/240 帧'));
      expect(info.statusLine(), contains('100.0 帧/秒'));
      expect(info.statusLine(), contains('剩余 00:00:02'));

      // 喂到 done 216：剩 24 帧 @100fps = 0.24s → <1s。
      for (var i = 0; i < 208; i++) {
        info.addFrame(t += 10);
      }
      expect(info.doneFrames, 216);
      expect(info.statusLine(), contains('216/240 帧'));
      expect(info.statusLine(), contains('剩余 <1s'));
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
          raw8Le(List<int>.generate(w * h * frames, (i) => i % (w * h))));
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
      // 320x180、8bit、RGGB，共 3 帧。依赖项目内置的 tools/ffmpeg/ffmpeg.exe。
      //（NVENC 对过小尺寸报 Invalid argument，故不用 8x8。）
      const w = 320, h = 180, frames = 3;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/isp_video_$stamp.raw');
      final out =
          File('${Directory.systemTemp.path}/isp_video_$stamp.mp4');
      await raw.writeAsBytes(
          raw8Le(List<int>.generate(w * h * frames, (i) => i % (w * h))));
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
        // 默认 auto 编码器：完成提示标注实际使用的编码器（硬件/软件）。
        expect(
            state.statusMessage,
            anyOf(contains('h264_nvenc 硬件编码'),
                contains('libx264 软件编码')));
        expect(out.existsSync(), isTrue);
        expect(out.lengthSync(), greaterThan(0));

        // x264_fast（veryfast 预设）同样能导出。
        state.setParam(vidId, 'encoder', 'x264_fast');
        await state.exportVideo(vidId);
        expect(state.statusMessage, contains('视频导出完成'));
        expect(out.lengthSync(), greaterThan(0));

        // 显式 NVIDIA 硬件编码（本机 RTX 4090 可用；无 N 卡环境跳过）。
        if (await probeNvencEncoder('tools/ffmpeg/ffmpeg.exe')) {
          state.setParam(vidId, 'encoder', 'nvenc');
          await state.exportVideo(vidId);
          expect(state.statusMessage, contains('视频导出完成'));
          expect(state.statusMessage, contains('h264_nvenc 硬件编码'));
          expect(out.lengthSync(), greaterThan(0));
        }
      } finally {
        await raw.delete();
        if (out.existsSync()) await out.delete();
      }
    });

    test('video_source 范围任务制导出：帧数完整、可解码', () async {
      // 先用 ffmpeg 造 12 帧 320x180 源视频，再经 video_source →
      // video_output 走范围任务制路径导出，校验产物非空且含 12 帧。
      const w = 320, h = 180;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final src = File('${Directory.systemTemp.path}/isp_vsrc_$stamp.mp4');
      final out = File('${Directory.systemTemp.path}/isp_vsrc_out_$stamp.mp4');
      try {
        final ff = File('tools/ffmpeg/ffmpeg.exe').absolute.path;
        final mk = await Process.run(ff, [
          '-hide_banner', '-y',
          '-f', 'lavfi', '-i', 'testsrc=duration=0.4:size=${w}x$h:rate=30',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', src.path,
        ]);
        expect(mk.exitCode, 0, reason: '${mk.stderr}');

        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('video_source', 0, 0);
        state.setParam(srcId, 'filePath', src.path);
        final vidId = state.graph.addNode('video_output', 200, 0);
        expect(state.graph.connect(srcId, 'out_rgb', vidId, 'in'), isNull);
        state.setParam(vidId, 'filePath', out.path);
        state.setParam(vidId, 'encoder', 'x264');

        await state.exportVideo(vidId);

        expect(state.statusMessage, contains('视频导出完成'));
        expect(out.existsSync(), isTrue);
        expect(out.lengthSync(), greaterThan(0));
        // 帧数校验：ffmpeg -i 输出里应包含 12 帧（duration 0.4s @30fps）。
        final probe = await Process.run(
            ff, ['-hide_banner', '-i', out.path]);
        expect(probe.stderr.toString(), contains('Duration: 00:00:00.40'));
      } finally {
        if (src.existsSync()) await src.delete();
        if (out.existsSync()) await out.delete();
      }
    });

    test('导出期间 exportVideoInfo 实时可见（分辨率/总帧数），结束后清空',
        () async {
      // 12 帧 320x180 video_source → video_output；导出进行中轮询
      // state.exportVideoInfo，应能观察到非空且参数正确、doneFrames 递增；
      // 导出结束后（finally）应被清空，状态栏回退 statusMessage。
      const w = 320, h = 180;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final src = File('${Directory.systemTemp.path}/isp_einfo_$stamp.mp4');
      final out =
          File('${Directory.systemTemp.path}/isp_einfo_out_$stamp.mp4');
      try {
        final ff = File('tools/ffmpeg/ffmpeg.exe').absolute.path;
        final mk = await Process.run(ff, [
          '-hide_banner', '-y',
          '-f', 'lavfi', '-i', 'testsrc=duration=0.4:size=${w}x$h:rate=30',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', src.path,
        ]);
        expect(mk.exitCode, 0, reason: '${mk.stderr}');

        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('video_source', 0, 0);
        state.setParam(srcId, 'filePath', src.path);
        final vidId = state.graph.addNode('video_output', 200, 0);
        expect(state.graph.connect(srcId, 'out_rgb', vidId, 'in'), isNull);
        state.setParam(vidId, 'filePath', out.path);
        state.setParam(vidId, 'encoder', 'x264');
        state.setParam(vidId, 'fps', 30);

        final fut = state.exportVideo(vidId);
        var done = false;
        fut.whenComplete(() => done = true);
        ExportProgressInfo? seen;
        String? seenLine;
        var maxDone = -1;
        while (!done) {
          final info = state.exportVideoInfo;
          if (info != null) {
            seen ??= info;
            seenLine = info.statusLine();
            expect((info.width, info.height), (w, h));
            expect(info.fps, 30);
            expect(info.totalFrames, 12);
            expect(info.doneFrames, inInclusiveRange(0, 12));
            expect(info.doneFrames, greaterThanOrEqualTo(maxDone));
            maxDone = info.doneFrames;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await fut;

        expect(seen, isNotNull, reason: '导出期间应能观察到 exportVideoInfo');
        expect(seenLine, contains('导出中 320×180 @30fps 时长 00:00:00'));
        expect(seenLine, contains('/12 帧'));
        expect(maxDone, greaterThan(0), reason: '应观察到 doneFrames 递增');
        expect(state.exportVideoInfo, isNull);
        expect(state.statusMessage, contains('视频导出完成'));
      } finally {
        if (src.existsSync()) await src.delete();
        if (out.existsSync()) await out.delete();
      }
    });

    test('video_source GPU 链导出（shader 可用时走 GPU 链，否则回退 CPU 池）',
        () async {
      // video_source → rgb_debugger → video_output：rgb_debugger 在
      // GpuPipeline.supportedOps 内，链被截尾后可 GPU 执行。
      const w = 320, h = 180;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final src = File('${Directory.systemTemp.path}/isp_gpu_$stamp.mp4');
      final out = File('${Directory.systemTemp.path}/isp_gpu_out_$stamp.mp4');
      try {
        final ff = File('tools/ffmpeg/ffmpeg.exe').absolute.path;
        final mk = await Process.run(ff, [
          '-hide_banner', '-y',
          '-f', 'lavfi', '-i', 'testsrc=duration=0.4:size=${w}x$h:rate=30',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', src.path,
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
        expect(out.lengthSync(), greaterThan(0));
        // 路径标注：有 GPU 时应为 GPU 链，否则 CPU 池（便携断言二选一）。
        expect(state.statusMessage,
            anyOf(contains('GPU 链'), contains('CPU 池')));
      } finally {
        if (src.existsSync()) await src.delete();
        if (out.existsSync()) await out.delete();
      }
    });
  });
}
