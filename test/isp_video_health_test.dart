import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_health.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_layout.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('video_health_check 节点注册', () {
    test('节点类型存在且无端口、参数齐全', () {
      final type = IspNodeRegistry.byId('video_health_check');
      expect(type, isNotNull);
      expect(type!.displayName, '视频健康检查');
      expect(type.inputs, isEmpty);
      expect(type.outputs, isEmpty);
      final keys = {for (final p in type.params) p.key: p};
      expect(keys.keys, {'inputFile', 'ffmpegPath', 'scanDepth'});
      expect(keys['inputFile']!.type, IspParamType.filePath);
      expect(keys['ffmpegPath']!.type, IspParamType.text);
      expect(keys['ffmpegPath']!.defaultValue, 'tools/ffmpeg/ffmpeg.exe');
      expect(keys['scanDepth']!.type, IspParamType.choice);
      expect(keys['scanDepth']!.defaultValue, 'fast');
      expect(keys['scanDepth']!.options, ['fast', 'full']);
      // 非汇点/仪器/Process 类型。
      expect(sinkNodeTypes.contains('video_health_check'), isFalse);
      expect(allInstrumentTypes.contains('video_health_check'), isFalse);
      expect(IspNodeRegistry.isProcessType('video_health_check'), isFalse);
    });

    test('尺寸固定 1500x1200（同 format_converter 口径）', () {
      final node = IspNode.create(
          IspNodeRegistry.byId('video_health_check')!, 'hc1', 0, 0);
      expect(node.width, 1500);
      expect(node.extraHeight, 1162);
      final type = IspNodeRegistry.byId('video_health_check')!;
      expect(nodeHeight(type, previewExtraHeight: 1162), 1200);
      expect(IspStudioState.minNodeWidthFor('video_health_check'), 1500);
      expect(IspStudioState.maxNodeWidthFor('video_health_check'), 1500);
      expect(IspStudioState.minExtraHeightFor('video_health_check'), 1162);
      expect(
          IspStudioState.maxPreviewExtraHeightFor('video_health_check'), 1162);
    });
  });

  group('parseShowinfoLine', () {
    test('正常行提取 n/pts_time/checksum', () {
      final r = parseShowinfoLine(
          '[Parsed_showinfo_0 @ 000001ab] n:  12 pts:  36000 '
          'pts_time:1.234 pos:  5678 fmt:yuv420p checksum:ABCD1234 '
          'plane_checksum:[ABCD1234]');
      expect(r, isNotNull);
      expect(r!.$1, 12);
      expect(r.$2, closeTo(1.234, 1e-9));
      expect(r.$3, 'ABCD1234');
    });

    test('非 showinfo 行/字段缺失返回 null', () {
      expect(parseShowinfoLine('frame=  100 fps=30'), isNull);
      expect(parseShowinfoLine('[Parsed_scale_0 @ x] n: 1 pts_time:0.5'),
          isNull);
      expect(parseShowinfoLine(''), isNull);
    });
  });

  group('analyzePts', () {
    test('均匀 30fps 序列：无跳变无非单调', () {
      final pts = [for (var i = 0; i < 90; i++) i / 30.0];
      final r = analyzePts(pts);
      expect(r.median, closeTo(1 / 30, 1e-6));
      expect(r.gaps, isEmpty);
      expect(r.nonMonotonic, 0);
      expect(r.duplicates, 0);
    });

    test('含开头 0.68s 空洞（record-2024 形态）：检出位置与时长', () {
      // 0, 1/30, 2/30 后跳到 0.7493（record-2024-09-26 实测形态）。
      final pts = [
        0.0, 1 / 30, 2 / 30, 0.749333, 0.782667, 0.816, 0.849333, 0.882667,
      ];
      final r = analyzePts(pts);
      expect(r.gaps.length, 1);
      expect(r.gaps.first.$1, closeTo(2 / 30, 1e-6));
      expect(r.gaps.first.$2, greaterThan(0.6));
    });

    test('重复与非单调计数', () {
      final r = analyzePts([0.0, 0.033, 0.033, 0.1, 0.05, 0.15]);
      expect(r.duplicates, 1);
      expect(r.nonMonotonic, 1);
    });
  });

  group('fpsVerdict', () {
    test('三者一致 → ok', () {
      final (lv, _) = fpsVerdict(
          avgFps: 30, rFrameRate: 30, medianPtsFps: 30);
      expect(lv, 'ok');
    });

    test('VUI 60 vs 实际 30 → warn 且文案含「复制」', () {
      final (lv, text) = fpsVerdict(
          avgFps: 30, rFrameRate: 60, medianPtsFps: 30);
      expect(lv, 'warn');
      expect(text, contains('VUI'));
      expect(text, contains('复制'));
      expect(text, contains('passthrough'));
    });

    test('avg 与 pts 不一致（VUI 一致）→ VFR warn', () {
      final (lv, text) = fpsVerdict(
          avgFps: 24, rFrameRate: 30, medianPtsFps: 30);
      expect(lv, 'warn');
      expect(text, contains('VFR'));
    });
  });

  group('analyzeFreeze', () {
    test('连续重复段 >0.5s 才报', () {
      // 30fps：0~1s 冻结（31 帧同 checksum），随后正常。
      final frames = <(double, String)>[
        for (var i = 0; i <= 30; i++) (i / 30.0, 'AAAA'),
        (31 / 30.0, 'BBBB'),
        (32 / 30.0, 'CCCC'),
      ];
      final (segs, dups) = analyzeFreeze(frames);
      expect(segs.length, 1);
      expect(segs.first.$1, 0.0);
      expect(segs.first.$2, closeTo(31 / 30.0, 1e-6));
      expect(dups, 30);
    });

    test('短重复段（<0.5s）不报', () {
      final frames = <(double, String)>[
        for (var i = 0; i < 10; i++) (i / 30.0, 'AAAA'), // 0.3s
        (10 / 30.0, 'BBBB'),
      ];
      final (segs, dups) = analyzeFreeze(frames);
      expect(segs, isEmpty);
      expect(dups, 9);
    });
  });

  group('gopStats', () {
    test('间隔 min/avg/max', () {
      final g = gopStats([0.0, 2.0, 4.5, 6.0])!;
      expect(g.$1, closeTo(1.5, 1e-9));
      expect(g.$2, closeTo(2.0, 1e-9));
      expect(g.$3, closeTo(2.5, 1e-9));
      expect(gopStats([0.0]), isNull);
      expect(gopStats(const []), isNull);
    });
  });

  group('parseDebugTsPacketLine / parseFreezeLine / parseFinalFrameCount', () {
    test('debug_ts 视频包行提取 pts/dts', () {
      final r = parseDebugTsPacketLine(
          '[vist#0:0/hevc @ 000001ab] demuxer -> ist_index:0:0 type:video '
          'pkt_pts:100 pkt_pts_time:0.0333333 pkt_dts:50 '
          'pkt_dts_time:0.0166667 duration:100');
      expect(r, isNotNull);
      expect(r!.$1, closeTo(0.0333333, 1e-9));
      expect(r.$2, closeTo(0.0166667, 1e-9));
      expect(parseDebugTsPacketLine('[out#0 @ x] muxer <- pts:1'), isNull);
    });

    test('freezedetect 行提取 key/value', () {
      final s = parseFreezeLine(
          '[Parsed_freezedetect_0 @ x] lavfi.freezedetect.freeze_start: 0.0666667');
      expect(s, isNotNull);
      expect(s!.$1, 'freeze_start');
      expect(s.$2, closeTo(0.0666667, 1e-9));
      expect(
          parseFreezeLine(
                  '[Parsed_freezedetect_0 @ x] lavfi.freezedetect.freeze_duration: 0.682667')!
              .$1,
          'freeze_duration');
      expect(parseFreezeLine('frame= 10'), isNull);
    });

    test('frame= 计数取最后一个', () {
      expect(parseFinalFrameCount('frame=   10 fps=30\rframe=  181 fps=60'),
          181);
      expect(parseFinalFrameCount('no frames'), isNull);
    });
  });

  group('进度计算（overallProgress / etaSeconds / fmt）', () {
    test('各阶段权重与归一化（fast 两项 / full 四项）', () {
      // fast：packets 0.10 / keyframes 0.05 归一化（÷0.15）。
      expect(overallProgress(HealthCheckStage.packets, 0, false), 0);
      expect(overallProgress(HealthCheckStage.packets, 0.5, false),
          closeTo(0.1 * 0.5 / 0.15, 1e-9));
      expect(overallProgress(HealthCheckStage.keyframes, 0, false),
          closeTo(0.1 / 0.15, 1e-9));
      expect(overallProgress(HealthCheckStage.keyframes, 1, false), 1);
      // full：pass1 中点 = 0.15 + 0.55×0.5 = 0.425。
      expect(overallProgress(HealthCheckStage.pass1, 0, true),
          closeTo(0.15, 1e-9));
      expect(overallProgress(HealthCheckStage.pass1, 0.5, true),
          closeTo(0.425, 1e-9));
      expect(overallProgress(HealthCheckStage.pass2, 1, true), 1);
    });

    test('完成度沿阶段单调不减', () {
      var prev = -1.0;
      for (final (stage, frac) in [
        (HealthCheckStage.packets, 0.0),
        (HealthCheckStage.packets, 1.0),
        (HealthCheckStage.keyframes, 0.5),
        (HealthCheckStage.keyframes, 1.0),
        (HealthCheckStage.pass1, 0.0),
        (HealthCheckStage.pass1, 0.7),
        (HealthCheckStage.pass2, 0.0),
        (HealthCheckStage.pass2, 1.0),
      ]) {
        final p = overallProgress(stage, frac, true);
        expect(p, greaterThanOrEqualTo(prev));
        prev = p;
      }
    });

    test('ETA 与时间格式化', () {
      expect(etaSeconds(10, 0.5), closeTo(10, 1e-9));
      expect(etaSeconds(60, 0.25), closeTo(180, 1e-9));
      expect(etaSeconds(10, 0), 0);
      expect(fmtClockSec(0), '00:00');
      expect(fmtClockSec(75.4), '01:15');
      expect(fmtHmsSec(59), '00:00:59');
      expect(fmtHmsSec(3661), '01:01:01');
    });
  });

  group('runVideoHealthCheck 取消路径', () {
    test('full 检查中途取消：返回 -2 且报告含「已中止」', () async {
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp =
          File('${Directory.systemTemp.path}/isp_health_cancel_$stamp.mp4');
      final enc = await Process.run(
          File('tools/ffmpeg/ffmpeg.exe').absolute.path, [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=10:duration=3',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        var cancel = false;
        var progresses = 0;
        final buf = StringBuffer();
        final exit = await runVideoHealthCheck(
          ffmpegPath: 'tools/ffmpeg/ffmpeg.exe',
          inputFile: tmp.path,
          scanDepth: 'full',
          isCancelled: () => cancel,
          onProgress: (_) {
            // 收到首批进度后置取消（引擎在下一行/阶段边界生效）。
            if (++progresses >= 2) cancel = true;
          },
          onOutput: buf.write,
        );
        expect(exit, -2);
        expect(buf.toString(), contains('已中止'));
        expect(progresses, greaterThan(0));
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });

    test('fast 检查不取消：onProgress 完成度终点为 1', () async {
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp =
          File('${Directory.systemTemp.path}/isp_health_prog_$stamp.mp4');
      final enc = await Process.run(
          File('tools/ffmpeg/ffmpeg.exe').absolute.path, [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=10:duration=1',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final overalls = <double>[];
        final exit = await runVideoHealthCheck(
          ffmpegPath: 'tools/ffmpeg/ffmpeg.exe',
          inputFile: tmp.path,
          scanDepth: 'fast',
          onProgress: (p) => overalls.add(p.overall),
          onOutput: (_) {},
        );
        expect(exit, 0);
        expect(overalls, isNotEmpty);
        expect(overalls.last, 1);
        // 完成度单调不减。
        for (var i = 1; i < overalls.length; i++) {
          expect(overalls[i], greaterThanOrEqualTo(overalls[i - 1]));
        }
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });
  });

  group('runVideoHealthCheck 集成（lavfi 小片，fast 模式）', () {
    test('报告含基本信息行与汇总行，exit 0', () async {
      if (!await File('tools/ffmpeg/ffmpeg.exe').exists()) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tmp =
          File('${Directory.systemTemp.path}/isp_health_$stamp.mp4');
      final enc = await Process.run(
          File('tools/ffmpeg/ffmpeg.exe').absolute.path, [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=10:duration=1',
        '-pix_fmt', 'yuv420p', tmp.path,
      ]);
      expect(enc.exitCode, 0);
      try {
        final buf = StringBuffer();
        final exit = await runVideoHealthCheck(
          ffmpegPath: 'tools/ffmpeg/ffmpeg.exe',
          inputFile: tmp.path,
          scanDepth: 'fast',
          onOutput: buf.write,
        );
        final report = buf.toString();
        expect(report, contains('视频健康检查'));
        expect(report, contains('基本信息'));
        expect(report, contains('包数'));
        expect(report, contains('帧率一致性'));
        expect(report, contains('关键帧间隔'));
        expect(report, contains('汇总'));
        // lavfi 生成的规整小片应无警告。
        expect(exit, 0);
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });
  });
}
