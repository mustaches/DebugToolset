import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/format_convert.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart'
    show kHdrTonemapFilter;
import 'package:debug_tool_set/modules/isp_studio/widgets/node_layout.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('format_converter 节点注册', () {
    test('节点类型存在且无端口、参数齐全', () {
      final type = IspNodeRegistry.byId('format_converter');
      expect(type, isNotNull);
      expect(type!.displayName, '格式转换');
      // 纯工具节点：不参与图像流水线。
      expect(type.inputs, isEmpty);
      expect(type.outputs, isEmpty);
      // 不被注入 Bypass 参数（不在 processTypeIds 内）。
      expect(type.params.any((p) => p.key == 'bypass'), isFalse);

      final keys = {for (final p in type.params) p.key: p};
      expect(keys.keys,
          {'inputFile', 'outputFile', 'ffmpegPath', 'encoder', 'outputRange'});
      expect(keys['inputFile']!.type, IspParamType.filePath);
      expect(keys['inputFile']!.defaultValue, 'input.webm');
      expect(keys['outputFile']!.type, IspParamType.filePath);
      expect(keys['outputFile']!.defaultValue, 'output.mp4');
      expect(keys['ffmpegPath']!.type, IspParamType.text);
      expect(keys['ffmpegPath']!.defaultValue, 'tools/ffmpeg/ffmpeg.exe');
      // 编码器：choice，默认 auto，序列化兜底选项仅 auto/libx264
      //（硬件编码器由属性面板按探测结果动态追加）。
      expect(keys['encoder']!.type, IspParamType.choice);
      expect(keys['encoder']!.defaultValue, 'auto');
      expect(keys['encoder']!.options, ['auto', 'libx264']);
      // 输出动态范围：choice，默认 auto 跟随片源，全集 auto/sdr/hdr
      //（属性面板按输入探测结果过滤）。
      expect(keys['outputRange']!.type, IspParamType.choice);
      expect(keys['outputRange']!.defaultValue, 'auto');
      expect(keys['outputRange']!.options, ['auto', 'sdr', 'hdr']);
    });

    test('不属于汇点/仪器类型', () {
      expect(sinkNodeTypes.contains('format_converter'), isFalse);
      expect(allInstrumentTypes.contains('format_converter'), isFalse);
      expect(IspNodeRegistry.isProcessType('format_converter'), isFalse);
    });
  });

  group('format_converter 节点尺寸（固定 1500x1200，min=max 不可调）', () {
    test('IspNode.create 默认 width=1500、extraHeight=1162', () {
      final node = IspNode.create(
          IspNodeRegistry.byId('format_converter')!, 'fc1', 0, 0);
      expect(node.width, 1500);
      expect(node.extraHeight, 1162);
    });

    test('nodeHeight(extra=1162) == 1200（标题 30 + 底 8 + extra）', () {
      final type = IspNodeRegistry.byId('format_converter')!;
      expect(nodeHeight(type, previewExtraHeight: 1162), 1200);
      // extraHeight 机制生效：高度随 extra 变化。
      expect(nodeHeight(type, previewExtraHeight: 1000), 1000 + 38);
    });

    test('钳制函数：format_converter 固定 1500/1162，其它类型全局值', () {
      expect(IspStudioState.minNodeWidthFor('format_converter'), 1500);
      expect(IspStudioState.minExtraHeightFor('format_converter'), 1162);
      // 固定尺寸：上限 == 下限（拖动无效）。
      expect(IspStudioState.maxNodeWidthFor('format_converter'), 1500);
      expect(IspStudioState.maxPreviewExtraHeightFor('format_converter'),
          1162);
      expect(IspStudioState.minNodeWidthFor('preview'),
          IspStudioState.kMinPreviewNodeWidth);
      expect(IspStudioState.minExtraHeightFor('preview'),
          IspStudioState.kMinPreviewExtraHeight);
      expect(IspStudioState.minNodeWidthFor('video_source'),
          IspStudioState.kMinPreviewNodeWidth);
      expect(IspStudioState.minExtraHeightFor(''),
          IspStudioState.kMinPreviewExtraHeight);
    });
  });

  group('ensureMp4Output（输出容器兜底 .mp4）', () {
    test('.mp4 原样保留（大小写不敏感）', () {
      expect(ensureMp4Output(r'G:\a\out.mp4'), r'G:\a\out.mp4');
      expect(ensureMp4Output(r'G:\a\out.MP4'), r'G:\a\out.MP4');
    });
    test('.webm 等其它扩展名替换为 .mp4', () {
      expect(ensureMp4Output(r'G:\a\out.webm'), r'G:\a\out.mp4');
      expect(ensureMp4Output('G:/a/out.mkv'), 'G:/a/out.mp4');
    });
    test('无扩展名补上 .mp4；目录名含点不误判', () {
      expect(ensureMp4Output(r'G:\a\out'), r'G:\a\out.mp4');
      expect(ensureMp4Output(r'G:\dir.v2\out'), r'G:\dir.v2\out.mp4');
    });
  });

  group('addNodeAt centered（节点中心对齐聚点）', () {
    test('大节点（format_converter 1500x1200）中心对准，网格吸附容差内', () {
      final state = IspStudioState.empty();
      state.addNodeAt('format_converter', const Offset(2000, 1500),
          centered: true);
      final node = state.graph.nodes.values.first;
      final h = nodeHeight(IspNodeRegistry.byId('format_converter')!,
          previewExtraHeight: node.extraHeight);
      expect((node.x + node.width / 2 - 2000).abs(),
          lessThan(IspStudioState.kGridSize));
      expect((node.y + h / 2 - 1500).abs(),
          lessThan(IspStudioState.kGridSize));
    });

    test('缺省（centered: false）保持左上角落点语义', () {
      final state = IspStudioState.empty();
      state.addNodeAt('image_source', const Offset(100, 100));
      final node = state.graph.nodes.values.first;
      expect(node.x, 100);
      expect(node.y, 100);
    });
  });

  group('encoderChainFor', () {
    test('libx264：单档无回退链', () {
      expect(encoderChainFor('libx264', const []), ['libx264']);
      expect(encoderChainFor('libx264', ['h264_nvenc']), ['libx264']);
    });

    test('auto + 实测硬件表：硬件按序在前、libx264 兜底', () {
      expect(encoderChainFor('auto', ['h264_nvenc', 'h264_qsv']),
          ['h264_nvenc', 'h264_qsv', 'libx264']);
    });

    test('auto + 空硬件表：h264_nvenc 兜底（未探测时的既有行为）', () {
      expect(encoderChainFor('auto', const []), ['h264_nvenc', 'libx264']);
    });

    test('具体 id：先试该编码器、失败回退 libx264', () {
      expect(encoderChainFor('h264_qsv', const []), ['h264_qsv', 'libx264']);
      expect(encoderChainFor('hevc_amf', ['h264_nvenc']),
          ['hevc_amf', 'libx264']);
    });
  });

  group('appendConsoleText', () {
    test('普通追加', () {
      expect(appendConsoleText('abc', 'def'), 'abcdef');
      expect(appendConsoleText('', 'line1\nline2\n'), 'line1\nline2\n');
      expect(appendConsoleText('line1\n', 'line2\n'), 'line1\nline2\n');
    });

    test(r'\r 覆盖当前行', () {
      expect(appendConsoleText('', 'a=1\rb=2'), 'b=2');
      // 跨 chunk 的覆盖：current 末尾是未完成行，chunk 以 \r 开头。
      expect(appendConsoleText('hdr\na=1', '\rb=2'), 'hdr\nb=2');
      // 覆盖只回到当前行行首，不动之前的行。
      expect(appendConsoleText('x\ny\na=1', '\rb=2'), 'x\ny\nb=2');
    });

    test(r'\r\n 组合视为普通换行不截断', () {
      expect(appendConsoleText('', 'a\r\nb'), 'a\nb');
      expect(appendConsoleText('a', '\r\nb'), 'a\nb');
    });

    test('ffmpeg 进度行序列只保留最后一帧行', () {
      var log = '';
      log = appendConsoleText(log, 'frame= 1 fps=10\r');
      log = appendConsoleText(log, 'frame= 2 fps=11\r');
      log = appendConsoleText(log, 'frame= 3 fps=12\n');
      expect(log, 'frame= 3 fps=12\n');
    });

    test('maxChars 截断保留尾部（对齐换行边界）', () {
      final log = 'aaaa\nbbbb\ncccc\n';
      // 上限 10：len-maxChars=5 起最近换行在 index 9 → 保留 'cccc\n'。
      expect(appendConsoleText(log, '', maxChars: 10), 'cccc\n');
      // 换行边界恰好在裁剪点上：保留 'bbbb\ncccc\n'（10 ≤ 11）。
      expect(appendConsoleText(log, '', maxChars: 11), 'bbbb\ncccc\n');
      // 追加后超限同样截尾。
      expect(appendConsoleText('aaaa\nbbbb\n', 'cccc\n', maxChars: 10),
          'cccc\n');
    });
  });

  group('parseEncoderIds', () {
    test('只解析出编译进的候选且按候选顺序返回', () {
      const out = '''
Encoders:
 V..... = Video
 ------
 V..... libx264              libx264 H.264 / AVC / MPEG-4 AVC (codec h264)
 V..... h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
 V..... hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)
 V..... h264_qsv             H.264 (Intel Quick Sync Video acceleration) (codec h264)
 V..... libx265              libx265 H.265 / HEVC encoder (codec hevc)
''';
      // h264_nvenc/hevc_nvenc/h264_qsv 编译进；qsv 排序在 nvenc 之后
      //（按 kHwEncoderCandidates 顺序而非出现顺序）。
      expect(parseEncoderIds(out), ['h264_nvenc', 'hevc_nvenc', 'h264_qsv']);
    });

    test('描述文本不误导出未编译的候选', () {
      const out = '''
 V..... h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
''';
      // 描述里出现 "NVENC" 字样不代表 hevc_nvenc/qsv/amf 可用。
      expect(parseEncoderIds(out), ['h264_nvenc']);
    });
  });

  group('hwEncoderDisplayName', () {
    test('已知 id 的显示文案', () {
      expect(hwEncoderDisplayName('h264_nvenc'), 'NVIDIA NVENC H.264 (h264_nvenc)');
      expect(hwEncoderDisplayName('hevc_nvenc'), 'NVIDIA NVENC HEVC (hevc_nvenc)');
      expect(hwEncoderDisplayName('h264_qsv'), 'Intel QuickSync H.264 (h264_qsv)');
      expect(hwEncoderDisplayName('hevc_qsv'), 'Intel QuickSync HEVC (hevc_qsv)');
      expect(hwEncoderDisplayName('h264_amf'), 'AMD AMF H.264 (h264_amf)');
      expect(hwEncoderDisplayName('hevc_amf'), 'AMD AMF HEVC (hevc_amf)');
      // 未知 id 原样返回。
      expect(hwEncoderDisplayName('h264_mf'), 'h264_mf');
    });
  });

  group('colorTagArgs', () {
    test('PQ / HLG / SDR 三档容器标记', () {
      final pq = colorTagArgs(1).join(' ');
      expect(pq, contains('-color_trc smpte2084'));
      expect(pq, contains('-color_primaries bt2020'));
      expect(pq, contains('-colorspace bt2020nc'));
      expect(colorTagArgs(2).join(' '), contains('-color_trc arib-std-b67'));
      expect(colorTagArgs(0), isEmpty);
    });
  });

  group('encoderArgs hdrOut', () {
    test('h264 系映射到 hevc 档', () {
      final nvenc = encoderArgs('h264_nvenc', hdrOut: true).join(' ');
      expect(nvenc, contains('-c:v hevc_nvenc'));
      expect(nvenc, contains('-tag:v hvc1'));
      // hevc_nvenc 零拷贝档不带 -pix_fmt（scale_cuda 已交付 p010le
      // CUDA 帧，-pix_fmt 会触发 auto_scale 软件转换协商失败）。
      expect(nvenc, isNot(contains('-pix_fmt')));
      // qsv/amf：系统内存帧补 p010le。
      expect(encoderArgs('h264_qsv', hdrOut: true).join(' '),
          allOf(contains('-c:v hevc_qsv'), contains('-pix_fmt p010le')));
      expect(encoderArgs('h264_amf', hdrOut: true).join(' '),
          allOf(contains('-c:v hevc_amf'), contains('-pix_fmt p010le')));
      // hevc_nvenc 原样同样不带 -pix_fmt。
      expect(encoderArgs('hevc_nvenc', hdrOut: true).join(' '),
          allOf(contains('-c:v hevc_nvenc'), isNot(contains('-pix_fmt'))));
    });

    test('CPU 兜底映射到 libx265（yuv420p10le + hvc1）', () {
      final cpu = encoderArgs('libx264', hdrOut: true).join(' ');
      expect(cpu, contains('-c:v libx265'));
      expect(cpu, contains('-pix_fmt yuv420p10le'));
      expect(cpu, contains('-tag:v hvc1'));
    });

    test('hdrOut=false 现状不变（无 10bit 参数）', () {
      expect(encoderArgs('h264_nvenc').join(' '),
          allOf(contains('-c:v h264_nvenc'), isNot(contains('p010le'))));
      expect(encoderArgs('libx264').join(' '), contains('-c:v libx264'));
    });
  });

  group('inputSideArgs / stepVfFor（NVDEC 零拷贝 GPU 链）', () {
    test('NVENC + SDR 出：cuda 输入侧 + scale_cuda=format=nv12', () {
      expect(inputSideArgs('h264_nvenc', isHdr: false, hdrOut: false),
          ['-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda']);
      expect(stepVfFor('h264_nvenc', isHdr: false, hdrOut: false),
          'scale_cuda=format=nv12');
    });

    test('NVENC + HDR 出：cuda 输入侧 + scale_cuda=format=p010le', () {
      expect(inputSideArgs('h264_nvenc', isHdr: true, hdrOut: true),
          ['-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda']);
      expect(stepVfFor('h264_nvenc', isHdr: true, hdrOut: true),
          'scale_cuda=format=p010le');
      // hdrOut 时链上 id 可能是 hevc_nvenc（auto 空表兜底为 h264_nvenc，
      // encoderArgs 层映射；两 id 同形态）。
      expect(stepVfFor('hevc_nvenc', isHdr: true, hdrOut: true),
          'scale_cuda=format=p010le');
    });

    test('NVENC 但 HDR→SDR：不上 cuda，保持 CPU tonemap 链', () {
      expect(inputSideArgs('h264_nvenc', isHdr: true, hdrOut: false),
          isEmpty);
      expect(stepVfFor('h264_nvenc', isHdr: true, hdrOut: false),
          kHdrTonemapFilter);
      // libx264 档同样必须带 tonemap（否则发灰截断）。
      expect(stepVfFor('libx264', isHdr: true, hdrOut: false),
          kHdrTonemapFilter);
    });

    test('QSV/AMF/libx264/libx265：无 cuda，vf 维持现状', () {
      for (final id in ['h264_qsv', 'h264_amf', 'libx264']) {
        expect(inputSideArgs(id, isHdr: false, hdrOut: false), isEmpty);
        expect(inputSideArgs(id, isHdr: true, hdrOut: true), isEmpty);
      }
      // SDR：QSV/AMF format=yuv420p，libx264 null。
      expect(stepVfFor('h264_qsv', isHdr: false, hdrOut: false),
          'format=yuv420p');
      expect(stepVfFor('h264_amf', isHdr: false, hdrOut: false),
          'format=yuv420p');
      expect(stepVfFor('libx264', isHdr: false, hdrOut: false), isNull);
      // HDR→HDR 非 NVENC 档：format=p010le（CPU 兜底 libx265 同）。
      expect(stepVfFor('h264_qsv', isHdr: true, hdrOut: true),
          'format=p010le');
      expect(stepVfFor('libx264', isHdr: true, hdrOut: true),
          'format=p010le');
    });
  });

  group('resolveOutputRange', () {
    test('auto 跟随输入；SDR 输入选 hdr 回退 sdr', () {
      expect(resolveOutputRange(1, 'auto'), ('hdr', false));
      expect(resolveOutputRange(2, 'auto'), ('hdr', false));
      expect(resolveOutputRange(0, 'auto'), ('sdr', false));
      expect(resolveOutputRange(0, 'hdr'), ('sdr', true));
      expect(resolveOutputRange(1, 'sdr'), ('sdr', false));
      expect(resolveOutputRange(2, 'hdr'), ('hdr', false));
    });
  });
}
