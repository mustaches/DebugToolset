import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

/// HDR10（PQ）片源 banner（Sony 4K HDR Demo Video.webm 形态）。
const _pqBanner = '''
  Duration: 00:00:30.00, start: 0.000000, bitrate: 50000 kb/s
  Stream #0:0: Video: vp9 (Profile 2), yuv420p10le(tv, bt2020nc/bt2020/smpte2084), 3840x2160, SAR 1:1 DAR 16:9, 59.94 fps, 59.94 tbr, 1k tbn (default)
''';

/// HLG 片源 banner（仓库无样片，按 ffmpeg 标准输出形态构造）。
const _hlgBanner = '''
  Stream #0:0: Video: hevc (Main 10), yuv420p10le(tv, bt2020nc/bt2020/arib-std-b67), 3840x2160 [SAR 1:1 DAR 16:9], 50 fps, 50 tbr, 90k tbn
''';

/// SDR BT.709 片源 banner。
const _sdr709Banner = '''
  Stream #0:0: Video: h264 (High), yuv420p(tv, bt709, progressive), 1920x1080 [SAR 1:1 DAR 16:9], 30 fps, 30 tbr, 15360 tbn
''';

/// VUI 虚标片源 banner（record-2024-09-26 手术录像形态：avg 30 / tbr 60）。
const _vuiLieBanner = '''
  Stream #0:0(und): Video: hevc (Rext), yuv422p10le(tv, bt2020nc/bt2020/bt2020-12), 3840x2160, 16000 kb/s, SAR 1:1 DAR 16:9, 30 fps, 60 tbr, 3k tbn (default)
''';

VideoInfo _info({double fps = 30, double tbr = 0, String pixFmt = ''}) =>
    VideoInfo(
        width: 3840,
        height: 2160,
        fps: fps,
        frameCount: 27000,
        hasAudio: false,
        tbr: tbr,
        pixFmt: pixFmt);

void main() {
  group('parseColorTransfer / parseColorMatrix', () {
    test('PQ（smpte2084）/ HLG（arib-std-b67）/ SDR 三类解析', () {
      expect(parseColorTransfer(_pqBanner), 1);
      expect(parseColorTransfer(_hlgBanner), 2);
      expect(parseColorTransfer(_sdr709Banner), 0);
      // 色彩矩阵解析不受 transfer 影响。
      expect(parseColorMatrix(_pqBanner), 2); // bt2020
      expect(parseColorMatrix(_sdr709Banner), 1); // bt709
      expect(parseColorMatrix('Video: mpeg4, yuv420p, 720x576'), 0); // 601
    });
  });

  group('deliveredColorFormat（交付帧口径）', () {
    test('HDR 恒报 BT.709 tv（tonemap 后交付帧）', () {
      // PQ 容器元数据是 bt2020/tv，交付帧是 bt709/tv。
      expect(deliveredColorFormat(1, 2, false), (1, false));
      // HLG 同口径；即使容器标 pc 也压回 tv（tonemap 链 range=tv）。
      expect(deliveredColorFormat(2, 2, true), (1, false));
    });

    test('SDR 按容器元数据原样返回', () {
      expect(deliveredColorFormat(0, 1, false), (1, false));
      expect(deliveredColorFormat(0, 0, true), (0, true));
    });
  });

  group('VideoInfo.isHdr', () {
    VideoInfo info(int transfer) => VideoInfo(
        width: 16,
        height: 16,
        fps: 25,
        frameCount: 1,
        hasAudio: false,
        colorTransfer: transfer);

    test('PQ/HLG 为 HDR，SDR 否', () {
      expect(info(1).isHdr, isTrue);
      expect(info(2).isHdr, isTrue);
      expect(info(0).isHdr, isFalse);
    });
  });

  group('buildDecodeVf', () {
    test('HDR：rgba 档插入完整 tonemap 链', () {
      final vf = buildDecodeVf(
          pixelFormat: 'rgba',
          downsampleFactor: 1,
          outWidth: 3840,
          outHeight: 2160,
          isHdr: true);
      expect(vf, kHdrTonemapFilter);
      expect(vf, contains('zscale=transfer=linear'));
      expect(vf, contains('tonemap=hable:desat=0'));
      expect(vf, contains('matrix=bt709'));
      expect(vf, contains('format=yuv420p'));
    });

    test('HDR：降采样/444/平面直出各形态链式拼接', () {
      // rgba + 降采样：tonemap 链在前、scale 在后。
      expect(
          buildDecodeVf(
              pixelFormat: 'rgba',
              downsampleFactor: 2,
              outWidth: 1920,
              outHeight: 1080,
              isHdr: true),
          '$kHdrTonemapFilter,scale=1920:1080');
      // yuv444p：tonemap 链在前、范围扩展在后。
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv444p',
              downsampleFactor: 1,
              outWidth: 3840,
              outHeight: 2160,
              isHdr: true),
          '$kHdrTonemapFilter,scale=out_range=pc');
      // yuv420p 平面直出：HDR 也必须 tonemap（否则发灰发暗）。
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv420p',
              downsampleFactor: 1,
              outWidth: 3840,
              outHeight: 2160,
              isHdr: true),
          kHdrTonemapFilter);
    });

    test('SDR：滤镜链零改动（回归红线）', () {
      expect(
          buildDecodeVf(
              pixelFormat: 'rgba',
              downsampleFactor: 1,
              outWidth: 1920,
              outHeight: 1080,
              isHdr: false),
          isNull);
      expect(
          buildDecodeVf(
              pixelFormat: 'rgba',
              downsampleFactor: 2,
              outWidth: 960,
              outHeight: 540,
              isHdr: false),
          'scale=960:540');
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv420p',
              downsampleFactor: 1,
              outWidth: 1920,
              outHeight: 1080,
              isHdr: false),
          isNull);
      // yuv420p 降采样（平面直连的显示自适应降档）：插 scale。
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv420p',
              downsampleFactor: 2,
              outWidth: 960,
              outHeight: 540,
              isHdr: false),
          'scale=960:540');
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv420p',
              downsampleFactor: 2,
              outWidth: 960,
              outHeight: 540,
              isHdr: true),
          // HDR 降档：先 scale 后 tonemap（计算量按面积缩）。
          'scale=960:540,$kHdrTonemapFilter');
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv444p',
              downsampleFactor: 1,
              outWidth: 1920,
              outHeight: 1080,
              isHdr: false),
          'scale=out_range=pc');
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv444p',
              downsampleFactor: 2,
              outWidth: 960,
              outHeight: 540,
              isHdr: false),
          'scale=960:540:out_range=pc');
    });

    test('HDR + toneMapHdr=false：SDR 直解（与 SDR 同形态，无 tonemap）', () {
      for (final fmt in ['rgba', 'yuv420p', 'yuv444p']) {
        for (final factor in [1, 2]) {
          final direct = buildDecodeVf(
              pixelFormat: fmt,
              downsampleFactor: factor,
              outWidth: 960,
              outHeight: 540,
              isHdr: true,
              toneMapHdr: false);
          final sdr = buildDecodeVf(
              pixelFormat: fmt,
              downsampleFactor: factor,
              outWidth: 960,
              outHeight: 540,
              isHdr: false);
          expect(direct, sdr, reason: '$fmt factor=$factor');
          if (direct != null) expect(direct, isNot(contains('tonemap')));
        }
      }
    });

    test('HDR + toneMapHdr=true（缺省）：完整 tonemap 链', () {
      // 缺省参数即 true。
      expect(
          buildDecodeVf(
              pixelFormat: 'yuv420p',
              downsampleFactor: 1,
              outWidth: 3840,
              outHeight: 2160,
              isHdr: true),
          kHdrTonemapFilter);
    });
  });

  group('videoDecodeArgs', () {
    test('HDR 插入 tonemap 链，SDR 无 -vf', () {
      final hdr = videoDecodeArgs(pixelFormat: 'rgba', isHdr: true);
      final vfAt = hdr.indexOf('-vf');
      expect(vfAt, greaterThan(0));
      expect(hdr[vfAt + 1], kHdrTonemapFilter);
      // -vf 在 -i 之后、-f 之前。
      expect(vfAt, greaterThan(hdr.indexOf('-i')));
      expect(vfAt, lessThan(hdr.indexOf('-f')));

      expect(videoDecodeArgs(pixelFormat: 'rgba'), isNot(contains('-vf')));
      expect(videoDecodeArgs(pixelFormat: 'yuv420p', isHdr: true),
          contains('-vf'));
      expect(videoDecodeArgs(pixelFormat: 'yuv420p'),
          isNot(contains('-vf')));
    });
  });

  group('parseTbr / videoPlaybackIssues（片源病灶检测）', () {
    test('tbr 解析：有/无 tbr 字段', () {
      expect(parseTbr(_vuiLieBanner), 60);
      expect(parseTbr(_sdr709Banner), 30);
      expect(parseTbr('Stream #0:0: Video: h264, 1920x1080'), 0);
    });

    test('pixFmt 解析：420/422 10bit', () {
      expect(parsePixFmt(_vuiLieBanner), 'yuv422p10le');
      expect(parsePixFmt(_sdr709Banner), 'yuv420p');
      expect(parsePixFmt(_pqBanner), 'yuv420p10le');
      expect(parsePixFmt('garbage'), '');
    });

    test('NVDEC 可硬解像素格式判定', () {
      expect(hwDecodablePixFmt('yuv420p'), isTrue);
      expect(hwDecodablePixFmt('yuv420p10le'), isTrue);
      expect(hwDecodablePixFmt('yuv422p10le'), isFalse);
      expect(hwDecodablePixFmt('yuv444p'), isFalse);
      expect(hwDecodablePixFmt(''), isTrue); // 未知不误报
    });

    test('正常片源：无病灶', () {
      expect(videoPlaybackIssues(_info(fps: 30, tbr: 30), softwareDecode: false),
          isEmpty);
      // tbr 未知（0）不误报。
      expect(videoPlaybackIssues(_info(fps: 59.94), softwareDecode: false),
          isEmpty);
      // 偏差 ≤3% 不误报（29.97 vs 30）。
      expect(videoPlaybackIssues(_info(fps: 30, tbr: 29.97), softwareDecode: false),
          isEmpty);
    });

    test('VUI 虚标：报帧率标称异常并说明已按实际帧率播放', () {
      final issues =
          videoPlaybackIssues(_info(fps: 30, tbr: 60), softwareDecode: false);
      expect(issues.length, 1);
      expect(issues.single.$1, contains('VUI'));
      expect(issues.single.$1, contains('60'));
      expect(issues.single.$2, contains('实际帧率'));
    });

    test('软解回退：报无硬件解码支持', () {
      final issues =
          videoPlaybackIssues(_info(fps: 30, tbr: 30), softwareDecode: true);
      expect(issues.length, 1);
      expect(issues.single.$1, contains('软件解码'));
    });

    test('格式预判软解：yuv422p10le 超出 NVDEC（worker 不上报也报）', () {
      final issues = videoPlaybackIssues(
          _info(fps: 30, tbr: 30, pixFmt: 'yuv422p10le'),
          softwareDecode: false);
      expect(issues.length, 1);
      expect(issues.single.$1, contains('软件解码'));
      expect(issues.single.$1, contains('yuv422p10le'));
    });

    test('手术录像形态（虚标 + 4:2:2 软解）：两条病灶', () {
      final issues = videoPlaybackIssues(
          _info(fps: 30, tbr: 60, pixFmt: 'yuv422p10le'),
          softwareDecode: false);
      expect(issues.length, 2);
    });
  });

  group('IspStudioState HDR/SDR 切换', () {
    test('默认 HDR 映射（hdrToneMapEnabled=true、transfer=SDR）', () {
      final state = IspStudioState.empty();
      expect(state.hdrToneMapEnabled, isTrue);
      expect(state.playbackSrcTransfer, 0);
    });

    test('toggleHdrToneMap 翻转标志（空图 runPreview 安全返回）', () async {
      final state = IspStudioState.empty();
      await state.toggleHdrToneMap();
      expect(state.hdrToneMapEnabled, isFalse);
      await state.toggleHdrToneMap();
      expect(state.hdrToneMapEnabled, isTrue);
    });
  });
}
