// 分段计时：定位多路预览生产耗时的构成（取流帧 / 流水线 / 图像解码）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_worker.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分段计时：取流 / 并行流水线', () async {
    if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tmp = File('${Directory.systemTemp.path}/isp_bench_seg_$stamp.mp4');
    final enc = await Process.run('tools/ffmpeg/ffmpeg.exe', [
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'testsrc=size=1920x1080:rate=60:duration=4',
      '-pix_fmt', 'yuv420p', tmp.path,
    ]);
    expect(enc.exitCode, 0);
    try {
      // A: 纯取流吞吐（yuv444p）。
      var stream =
          await VideoFrameStream.start(tmp.path, 0, pixelFormat: 'yuv444p');
      var sw = Stopwatch()..start();
      var n = 0;
      Uint8List? f;
      while (n < 120 && (f = await stream.next()) != null) {
        stream.recycle(f!);
        n++;
      }
      // ignore: avoid_print
      print('A 取流(yuv444p): $n 帧 ${sw.elapsedMilliseconds}ms '
          '(${(n / sw.elapsedMilliseconds * 1000).toStringAsFixed(1)}fps)');
      await stream.dispose();

      // B: 并行流水线（5 链，540p 工作帧）。
      final state = IspStudioState.empty();
      final g = state.graph;
      final src = g.addNode('video_source', 0, 0);
      g.nodes[src]!.paramValues['filePath'] = tmp.path;
      final split = g.addNode('yuv_splitter', 200, 0);
      g.connect(src, 'out_yuv', split, 'in');
      final pY = g.addNode('preview', 400, 0);
      final pU = g.addNode('preview', 400, 200);
      final pV = g.addNode('preview', 400, 400);
      g.connect(split, 'out_y', pY, 'in_mono');
      g.connect(split, 'out_u', pU, 'in_mono');
      g.connect(split, 'out_v', pV, 'in_mono');
      final comb = g.addNode('yuv_combiner', 600, 200);
      g.connect(pY, 'out_mono', comb, 'in_y');
      g.connect(pU, 'out_mono', comb, 'in_u');
      g.connect(pV, 'out_mono', comb, 'in_v');
      final pMain = g.addNode('preview', 800, 200);
      g.connect(comb, 'out', pMain, 'in_yuv');
      final pFull = g.addNode('preview', 400, 600);
      g.connect(src, 'out_yuv', pFull, 'in_yuv');
      final chains = <String, List<Map<String, Object?>>>{};
      for (final id in [pY, pU, pV, pMain, pFull]) {
        chains[id] = compileChain(g, id);
      }
      final pool = PipelineWorkerPool(count: 5);
      final (work, ww, wh) =
          downsampleYuv444p2x(f ?? Uint8List(1920 * 1080 * 3), 1920, 1080);
      sw.reset();
      const rounds = 30;
      for (var i = 0; i < rounds; i++) {
        await pool.runParallel(chains, i,
            sourceYuv: work, sourceWidth: ww, sourceHeight: wh);
      }
      // ignore: avoid_print
      print('B 并行流水线(5链@540p): $rounds 轮 ${sw.elapsedMilliseconds}ms '
          '(平均 ${(sw.elapsedMilliseconds / rounds).toStringAsFixed(1)}ms/轮)');
      pool.dispose();

      // C: 完整复刻 produceFrame（取流 + 降采样 + 流水线 + 5 张图解码），
      // 逐段累计计时。
      stream = await VideoFrameStream.start(tmp.path, 0, pixelFormat: 'yuv444p');
      final pool2 = PipelineWorkerPool(count: 5);
      var fetchUs = 0, downUs = 0, pipeUs = 0, imgUs = 0, frames = 0;
      final totalSw = Stopwatch()..start();
      while (frames < 90) {
        var t = Stopwatch()..start();
        final b = await stream.next();
        if (b == null) break;
        fetchUs += t.elapsedMicroseconds;
        t.reset();
        final (wb, ww2, wh2) = downsampleYuv444p2x(b, 1920, 1080);
        downUs += t.elapsedMicroseconds;
        t.reset();
        final rgbaMap = await pool2.runParallel(chains, frames,
            sourceYuv: wb, sourceWidth: ww2, sourceHeight: wh2);
        stream.recycle(b);
        pipeUs += t.elapsedMicroseconds;
        t.reset();
        await Future.wait([
          for (final entry in rgbaMap.entries)
            () async {
              final completer = Completer<ui.Image>();
              ui.decodeImageFromPixels(entry.value, ww2, wh2,
                  ui.PixelFormat.rgba8888, completer.complete);
              (await completer.future).dispose();
            }(),
        ]);
        imgUs += t.elapsedMicroseconds;
        frames++;
      }
      // ignore: avoid_print
      print('C 生产复刻($frames 帧 ${totalSw.elapsedMilliseconds}ms, '
          '${(frames / totalSw.elapsedMilliseconds * 1000).toStringAsFixed(1)}fps): '
          '取流 ${fetchUs ~/ 1000}ms 降采样 ${downUs ~/ 1000}ms '
          '流水线 ${pipeUs ~/ 1000}ms 图像解码 ${imgUs ~/ 1000}ms');
      pool2.dispose();
      await stream.dispose();

      // D: 单链原始计算耗时（本 isolate，JIT），每条链 10 次取平均。
      final swD = Stopwatch()..start();
      for (final entry in chains.entries) {
        var us = 0;
        for (var i = 0; i < 10; i++) {
          swD.reset();
          await runChainFrame(entry.value, i,
              sourceYuv: work, sourceWidth: ww, sourceHeight: wh);
          us += swD.elapsedMicroseconds;
        }
        // ignore: avoid_print
        print('D 单链 ${entry.key}: 平均 ${(us / 10 / 1000).toStringAsFixed(2)}ms '
            '(${entry.value.length} 个算子)');
      }
    } finally {
      await tmp.delete();
    }
  });
}
