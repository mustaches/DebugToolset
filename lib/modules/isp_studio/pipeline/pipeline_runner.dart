import 'dart:io';
import 'dart:typed_data';

import '../models/isp_graph.dart';
import 'frame3d.dart';
import 'image_source.dart';
import 'video_source.dart';
import 'instruments.dart';
import 'isp_kernels.dart';

/// 流水线执行器：把图编译成串行算子链并逐帧执行。
///
/// 全部为纯 Dart + dart:io（无 Flutter 依赖），可在后台 isolate 中运行。
/// 算子链用 `List<Map<String, Object?>>`（每项
/// `{'typeId':..., 'params':{...}, 'nodeId':...}`）表示，
/// 保证可以直接通过 isolate 消息传递。

/// RAW 马赛克源节点（含各 CFA 变体与 MONO）。
const rawSourceTypes = {
  'bayer_source',
  'cis_bayer_rggb',
  'cis_rccb_rccg',
  'cis_rccc',
  'cis_ryycy',
  'cis_rgb_ir',
  'cis_mono',
};

/// 全部源节点（RAW 源 + 图片文件源）。
const sourceTypes = {...rawSourceTypes, 'image_source', 'video_source'};

/// 从 [sinkNodeId] 反向收集上游节点，按拓扑序编译为算子链。
///
/// 链中必须恰好包含一个源节点（[sourceTypes] 之一）且位于链首。
/// 图片源会附加 `outFormat`（'rgb'/'yuv'/'hsl'），由其出边端口决定。
/// 抛出 [StateError]（中文消息）当：图有环、汇点不存在、缺少源节点等。
List<Map<String, Object?>> compileChain(IspGraph graph, String sinkNodeId) {
  if (!graph.nodes.containsKey(sinkNodeId)) {
    throw StateError('目标节点不存在');
  }
  final upstream = graph.upstreamOf(sinkNodeId).toSet()..add(sinkNodeId);
  final order = graph.topologicalOrder();
  if (order.isEmpty) {
    throw StateError('图中存在环路，无法执行');
  }
  final chain = <Map<String, Object?>>[];
  for (final id in order) {
    if (!upstream.contains(id)) continue;
    final node = graph.nodes[id]!;
    final inConns = <String, Map<String, String>>{};
    for (final c in graph.connections) {
      if (c.toNodeId == id) {
        inConns[c.toPort] = {
          'fromNodeId': c.fromNodeId,
          'fromPort': c.fromPort,
        };
      }
    }
    chain.add({
      'typeId': node.typeId,
      'params': node.paramValues,
      'nodeId': id,
      'inputs': inConns,
    });
  }
  final sources =
      chain.where((op) => sourceTypes.contains(op['typeId'])).length;
  if (sources == 0) {
    throw StateError('流水线缺少源节点');
  }
  if (sources > 1) {
    throw StateError('一条流水线只能有一个源节点');
  }
  if (!sourceTypes.contains(chain.first['typeId'])) {
    throw StateError('源节点必须位于流水线起点');
  }
  // 图片/视频源的输出格式由其出边端口（out_rgb/out_yuv/out_hsl）决定。
  final firstTypeId = chain.first['typeId'];
  if (firstTypeId == 'image_source' || firstTypeId == 'video_source') {
    final sourceId = chain.first['nodeId'] as String;
    final chainIds = {for (final op in chain) op['nodeId'] as String};
    String outFormat = 'rgb';
    for (final c in graph.connections) {
      if (c.fromNodeId == sourceId && chainIds.contains(c.toNodeId)) {
        outFormat = switch (c.fromPort) {
          'out_yuv' => 'yuv',
          'out_hsl' => 'hsl',
          _ => 'rgb',
        };
        break;
      }
    }
    chain.first['outFormat'] = outFormat;
  }
  return chain;
}

int _int(Map<String, Object?> p, String key) =>
    (p[key] as num?)?.toInt() ?? 0;

double _double(Map<String, Object?> p, String key) =>
    (p[key] as num?)?.toDouble() ?? 0.0;

String _str(Map<String, Object?> p, String key) => p[key]?.toString() ?? '';

BayerPacking _packingOf(String name) => switch (name) {
      'unpacked_msb' => BayerPacking.unpackedMsb,
      'mipi' => BayerPacking.mipi,
      _ => BayerPacking.unpackedLsb,
    };

int _sourceFrameBytes(Map<String, Object?> p) => frameByteSize(
      width: _int(p, 'width'),
      height: _int(p, 'height'),
      bitDepth: int.parse(_str(p, 'bitDepth').isEmpty ? '10' : _str(p, 'bitDepth')),
      packing: _packingOf(_str(p, 'packing')),
    );

/// 源节点的帧数。RAW 源 = 文件大小 / 单帧字节数；图片源恒为 1；
/// 视频源 = 时长 × 帧率（ffmpeg 解析）。文件不存在或与参数不匹配时
/// 抛 [StateError]。
Future<int> sourceFrameCount(String typeId, Map<String, Object?> params) async {
  final path = _str(params, 'filePath');
  if (typeId == 'image_source') {
    if (path.isEmpty) throw StateError('图片源未设置文件路径');
    if (!await File(path).exists()) throw StateError('图片文件不存在: $path');
    return 1;
  }
  if (typeId == 'video_source') {
    if (path.isEmpty) throw StateError('视频源未设置文件路径');
    final info =
        await videoFileInfo(path, ffmpegPath: _str(params, 'ffmpegPath'));
    return info.frameCount;
  }
  if (path.isEmpty) throw StateError('RAW 源未设置文件路径');
  final file = File(path);
  if (!await file.exists()) throw StateError('RAW 文件不存在: $path');
  final len = await file.length();
  final frameBytes = _sourceFrameBytes(params);
  if (frameBytes <= 0 || len < frameBytes) {
    throw StateError('RAW 文件大小与分辨率/位深参数不匹配');
  }
  return len ~/ frameBytes;
}

/// 源节点的像素尺寸。RAW 源取参数；图片源解码图片获得；视频源由
/// ffmpeg 解析。
Future<(int, int)> sourceDimensions(
    String typeId, Map<String, Object?> params) async {
  if (typeId == 'image_source') {
    return imageFileDimensions(_str(params, 'filePath'));
  }
  if (typeId == 'video_source') {
    final info = await videoFileInfo(_str(params, 'filePath'),
        ffmpegPath: _str(params, 'ffmpegPath'));
    return (info.width, info.height);
  }
  return (_int(params, 'width'), _int(params, 'height'));
}

/// RAW 源节点对应的 CFA 种类。
String _rawCfaOf(String typeId, Map<String, Object?> p) => switch (typeId) {
      'cis_rccb_rccg' => _str(p, 'cfaPattern') == 'RCCG' ? 'rccg' : 'rccb',
      'cis_rccc' => 'rccc',
      'cis_ryycy' => 'ryycy',
      'cis_rgb_ir' => 'rgb_ir',
      'cis_mono' => 'mono',
      _ => 'bayer',
    };

/// 链内流动的帧数据。
class _Frame {
  /// mosaic 时长度 w*h；rgb/yuv/hsl 时长度 w*h*3（三通道交织）。
  Uint16List data;

  /// 'mosaic' | 'rgb' | 'yuv' | 'hsl'
  String format;

  /// mosaic 时的 CFA 种类：'bayer'|'rccb'|'rccg'|'rccc'|'ryycy'|'rgb_ir'。
  String? cfa;
  BayerPattern? bayerPattern;
  int width;
  int height;
  int maxValue;
  double irSubtraction;

  _Frame({
    required this.data,
    required this.format,
    required this.width,
    required this.height,
    required this.maxValue,
    this.cfa,
    this.bayerPattern,
    this.irSubtraction = 0.5,
  });

  void requireMosaic(String opName) {
    if (format != 'mosaic') throw StateError('$opName需要 RAW 马赛克输入');
  }

  void requireRgb(String opName) {
    if (format != 'rgb') throw StateError('$opName需要 RGB 输入');
  }
}

/// 执行一帧：读取源 → 逐算子处理 → 返回 RGBA8888。
///
/// YUV/HSL 链在末端转回 RGB 再做色调映射。
/// 若链中没有 Gamma 节点，末尾做默认色调映射：RAW 源为线性数据，
/// 按 gamma 2.2 编码；图片/视频源本身已是 sRGB 显示数据，gamma 1.0
/// 直通（再施加 gamma 会二次提亮，画面发白）。
/// [onNodeOutput] 非空时，每个节点处理完后回调其输出数据
/// （调试用：nodeId、数据、格式 'mosaic'|'rgb'|'yuv'|'hsl'|'rgba'、帧宽、帧高）。
/// [sourceRgba] 仅用于 video_source 链：调用方（顺序流式解码）已预
/// 解码好的 RGBA8888 帧，注入后跳过每帧一次的 ffmpeg seek 解码。
Future<Uint8List> runChainFrame(
  List<Map<String, Object?>> chain,
  int frameIndex, {
  void Function(String nodeId, List<int> data, String format, int width,
      int height)? onNodeOutput,
  Uint8List? sourceRgba,
  int? sourceWidth,
  int? sourceHeight,
}) async {
  if (chain.isEmpty || !sourceTypes.contains(chain.first['typeId'])) {
    throw StateError('算子链必须以源节点开头');
  }
  final firstType = chain.first['typeId'] as String;
  final sp = (chain.first['params'] as Map?)?.cast<String, Object?>() ?? const {};

  _Frame frame;
  if (firstType == 'image_source' || firstType == 'video_source') {
    if (firstType == 'image_source' && frameIndex > 0) {
      throw StateError('图片源只有一帧');
    }
    final maxValue = bayerMaxValue(
        int.parse(_str(sp, 'bitDepth').isEmpty ? '8' : _str(sp, 'bitDepth')));
    final (rgb, w, h) = sourceRgba != null
        ? rgba8ToRgb16(sourceRgba, sourceWidth!, sourceHeight!, maxValue)
        : firstType == 'image_source'
            ? await decodeImageFileToRgb16(_str(sp, 'filePath'),
                maxValue: maxValue)
            : await decodeVideoFrameToRgb16(_str(sp, 'filePath'), frameIndex,
                maxValue: maxValue, ffmpegPath: _str(sp, 'ffmpegPath'));
    final outFormat = chain.first['outFormat'] as String? ?? 'rgb';
    frame = _Frame(
      data: switch (outFormat) {
        'yuv' => rgbToYuv(rgb, maxValue: maxValue),
        'hsl' => rgbToHsl(rgb, maxValue: maxValue),
        _ => rgb,
      },
      format: outFormat,
      width: w,
      height: h,
      maxValue: maxValue,
    );
  } else {
    final width = _int(sp, 'width');
    final height = _int(sp, 'height');
    final bitDepth =
        int.parse(_str(sp, 'bitDepth').isEmpty ? '10' : _str(sp, 'bitDepth'));
    final packing = _packingOf(_str(sp, 'packing'));
    final littleEndian = sp['littleEndian'] != false;
    final baseFrame = _int(sp, 'frameIndex');
    final maxValue = bayerMaxValue(bitDepth);

    final frameBytes = frameByteSize(
        width: width, height: height, bitDepth: bitDepth, packing: packing);
    final file = File(_str(sp, 'filePath'));
    final raf = await file.open();
    final Uint8List raw;
    try {
      await raf.setPosition((baseFrame + frameIndex) * frameBytes);
      raw = await raf.read(frameBytes);
    } finally {
      await raf.close();
    }
    if (raw.length < frameBytes) {
      throw StateError('帧 ${baseFrame + frameIndex} 超出文件范围');
    }

    final mosaic = unpackBayer(raw,
        width: width,
        height: height,
        bitDepth: bitDepth,
        packing: packing,
        littleEndian: littleEndian);
    final cfa = _rawCfaOf(firstType, sp);
    if (cfa == 'mono') {
      // MONO 无 CFA：直接复制为 RGB 灰度。
      frame = _Frame(
          data: monoToRgb(mosaic),
          format: 'rgb',
          width: width,
          height: height,
          maxValue: maxValue);
    } else {
      frame = _Frame(
        data: mosaic,
        format: 'mosaic',
        cfa: cfa,
        bayerPattern: cfa == 'bayer'
            ? BayerPattern.fromName(_str(sp, 'bayerPattern').isEmpty
                ? 'RGGB'
                : _str(sp, 'bayerPattern'))
            : null,
        width: width,
        height: height,
        maxValue: maxValue,
        irSubtraction: _double(sp, 'irSubtraction'),
      );
    }
  }
  // 源节点输出（解包/解码后的帧）。
  final firstNodeId = chain.first['nodeId'] as String? ?? 'source';
  onNodeOutput?.call(
      firstNodeId, frame.data, frame.format, frame.width, frame.height);

  final portOutputs = <String, Map<String, Uint16List>>{};
  portOutputs[firstNodeId] = {
    'out': frame.data,
    'out_rgb': frame.data,
    'out_yuv': frame.data,
    'out_hsl': frame.data,
  };

  Uint16List? getPortData(Map<String, Object?> op, String inputPortName) {
    final inputs = op['inputs'] as Map<String, Object?>?;
    if (inputs == null) return null;
    final conn = inputs[inputPortName] as Map<String, Object?>?;
    if (conn == null) return null;
    final fromNodeId = conn['fromNodeId'] as String?;
    final fromPort = conn['fromPort'] as String?;
    if (fromNodeId == null || fromPort == null) return null;
    return portOutputs[fromNodeId]?[fromPort];
  }

  Uint8List? rgba;
  for (final op in chain.skip(1)) {
    final typeId = op['typeId'] as String;
    final nodeId = op['nodeId'] as String? ?? typeId;
    final p = (op['params'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (typeId) {
      case 'black_level':
        frame.requireMosaic('黑电平校正');
        // 非 Bayer CFA 同样按 2x2 相位施加偏移（近似）。
        applyBlackLevel(frame.data,
            width: frame.width,
            height: frame.height,
            pattern: frame.bayerPattern ?? BayerPattern.rggb,
            r: _double(p, 'r'),
            gr: _double(p, 'gr'),
            gb: _double(p, 'gb'),
            b: _double(p, 'b'));
      case 'demosaic':
        frame.requireMosaic('去马赛克');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final data = frame.data;
        frame = _Frame(
          data: switch (frame.cfa) {
            'bayer' => demosaicBilinear(data,
                width: w, height: h, pattern: frame.bayerPattern!),
            'rccb' => demosaicRccb(data, width: w, height: h, maxValue: max),
            'rccg' => demosaicRccb(data,
                width: w, height: h, rccg: true, maxValue: max),
            'rccc' => demosaicRccc(data, width: w, height: h, maxValue: max),
            'ryycy' =>
              demosaicRyycy(data, width: w, height: h, maxValue: max),
            'rgb_ir' => demosaicRgbIr(data,
                width: w,
                height: h,
                maxValue: max,
                irSubtraction: frame.irSubtraction),
            _ => throw StateError('未知 CFA 种类: ${frame.cfa}'),
          },
          format: 'rgb',
          width: w,
          height: h,
          maxValue: max,
        );
      case 'white_balance':
        frame.requireRgb('白平衡');
        var rGain = _double(p, 'rGain');
        var bGain = _double(p, 'bGain');
        if (_str(p, 'mode') == 'auto') {
          final g = autoWhiteBalanceGains(frame.data);
          rGain = g.$1;
          bGain = g.$2;
        }
        applyWhiteBalance(frame.data,
            rGain: rGain <= 0 ? 1.0 : rGain,
            bGain: bGain <= 0 ? 1.0 : bGain,
            maxValue: frame.maxValue);
      case 'ccm':
        frame.requireRgb('CCM');
        final m = (p['matrix'] as List?)?.cast<double>() ??
            const [1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0];
        applyCcm(frame.data, matrix: m, maxValue: frame.maxValue);
      case 'gamma':
        frame.requireRgb('Gamma');
        rgba = tonemapToRgba(frame.data,
            maxValue: frame.maxValue,
            gamma: _double(p, 'gamma') <= 0 ? 2.2 : _double(p, 'gamma'),
            brightness: _double(p, 'brightness'),
            contrast: _double(p, 'contrast') <= 0 ? 1.0 : _double(p, 'contrast'));
      case 'rgb_splitter':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        if (frame.format == 'yuv') {
          frame = _Frame(
            data: yuvToRgb(frame.data, maxValue: max),
            format: 'rgb',
            width: w,
            height: h,
            maxValue: max,
          );
        } else if (frame.format == 'hsl') {
          frame = _Frame(
            data: hslToRgb(frame.data, maxValue: max),
            format: 'rgb',
            width: w,
            height: h,
            maxValue: max,
          );
        }
        frame.requireRgb('RGB 分路器');
        final pixels = w * h;
        final rData = Uint16List(pixels);
        final gData = Uint16List(pixels);
        final bData = Uint16List(pixels);
        for (var i = 0; i < pixels; i++) {
          rData[i] = frame.data[3 * i];
          gData[i] = frame.data[3 * i + 1];
          bData[i] = frame.data[3 * i + 2];
        }
        portOutputs[nodeId] = {
          'out_r': rData,
          'out_g': gData,
          'out_b': bData,
        };
      case 'yuv_splitter':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        if (frame.format == 'rgb') {
          frame = _Frame(
            data: rgbToYuv(frame.data, maxValue: max),
            format: 'yuv',
            width: w,
            height: h,
            maxValue: max,
          );
        }
        if (frame.format != 'yuv') throw StateError('YUV 分路器需要 YUV 输入');
        final pixels = w * h;
        final src = frame.data;
        final yData = Uint16List(pixels);
        final uData = Uint16List(pixels);
        final vData = Uint16List(pixels);
        var srcIdx = 0;
        for (var i = 0; i < pixels; i++, srcIdx += 3) {
          yData[i] = src[srcIdx];
          uData[i] = src[srcIdx + 1];
          vData[i] = src[srcIdx + 2];
        }
        portOutputs[nodeId] = {
          'out_y': yData,
          'out_u': uData,
          'out_v': vData,
        };
      case 'hsl_splitter':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        if (frame.format == 'rgb') {
          frame = _Frame(
            data: rgbToHsl(frame.data, maxValue: max),
            format: 'hsl',
            width: w,
            height: h,
            maxValue: max,
          );
        }
        if (frame.format != 'hsl') throw StateError('HSL 分路器需要 HSL 输入');
        final pixels = w * h;
        final src = frame.data;
        final hData = Uint16List(pixels);
        final sData = Uint16List(pixels);
        final lData = Uint16List(pixels);
        var srcIdx = 0;
        for (var i = 0; i < pixels; i++, srcIdx += 3) {
          hData[i] = src[srcIdx];
          sData[i] = src[srcIdx + 1];
          lData[i] = src[srcIdx + 2];
        }
        portOutputs[nodeId] = {
          'out_h': hData,
          'out_s': sData,
          'out_l': lData,
        };
      case 'rgb_combiner':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final pixels = w * h;
        final rData = getPortData(op, 'in_r');
        final gData = getPortData(op, 'in_g');
        final bData = getPortData(op, 'in_b');
        final combined = Uint16List(pixels * 3);
        var dstIdx = 0;
        for (var i = 0; i < pixels; i++, dstIdx += 3) {
          combined[dstIdx] = rData != null && i < rData.length ? rData[i] : 0;
          combined[dstIdx + 1] = gData != null && i < gData.length ? gData[i] : 0;
          combined[dstIdx + 2] = bData != null && i < bData.length ? bData[i] : 0;
        }
        frame = _Frame(
          data: combined,
          format: 'rgb',
          width: w,
          height: h,
          maxValue: max,
        );
        portOutputs[nodeId] = {'out': combined};
      case 'yuv_combiner':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final pixels = w * h;
        final yData = getPortData(op, 'in_y');
        final uData = getPortData(op, 'in_u');
        final vData = getPortData(op, 'in_v');
        final combined = Uint16List(pixels * 3);
        final mid = max >> 1;
        var dstIdx = 0;
        for (var i = 0; i < pixels; i++, dstIdx += 3) {
          combined[dstIdx] = yData != null && i < yData.length ? yData[i] : 0;
          combined[dstIdx + 1] = uData != null && i < uData.length ? uData[i] : mid;
          combined[dstIdx + 2] = vData != null && i < vData.length ? vData[i] : mid;
        }
        frame = _Frame(
          data: combined,
          format: 'yuv',
          width: w,
          height: h,
          maxValue: max,
        );
        portOutputs[nodeId] = {'out': combined};
      case 'hsl_combiner':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final pixels = w * h;
        final hData = getPortData(op, 'in_h');
        final sData = getPortData(op, 'in_s');
        final lData = getPortData(op, 'in_l');
        final combined = Uint16List(pixels * 3);
        for (var i = 0; i < pixels; i++) {
          combined[3 * i] = hData != null && i < hData.length ? hData[i] : 0;
          combined[3 * i + 1] = sData != null && i < sData.length ? sData[i] : 0;
          combined[3 * i + 2] = lData != null && i < lData.length ? lData[i] : 0;
        }
        frame = _Frame(
          data: combined,
          format: 'hsl',
          width: w,
          height: h,
          maxValue: max,
        );
        portOutputs[nodeId] = {'out': combined};
      case 'preview':
      case 'histogram':
      case 'waveform':
      case 'vectorscope':
      case 'image_output':
      case 'video_output':
        final monoData = getPortData(op, 'in_mono');
        if (monoData != null) {
          final w = frame.width;
          final h = frame.height;
          final max = frame.maxValue;
          final pixels = w * h;
          final isSingleChan = monoData.length == pixels;

          final isTargetSink = identical(op, chain.last);
          final Uint16List rgb;
          if (isTargetSink) {
            rgb = Uint16List(pixels * 3);
            for (var pIdx = 0; pIdx < pixels; pIdx++) {
              final val = isSingleChan
                  ? (pIdx < monoData.length ? monoData[pIdx] : 0)
                  : ((77 * (3 * pIdx < monoData.length ? monoData[3 * pIdx] : 0) +
                          150 * (3 * pIdx + 1 < monoData.length ? monoData[3 * pIdx + 1] : 0) +
                          29 * (3 * pIdx + 2 < monoData.length ? monoData[3 * pIdx + 2] : 0) +
                          128) >>
                      8);
              rgb[3 * pIdx] = val;
              rgb[3 * pIdx + 1] = val;
              rgb[3 * pIdx + 2] = val;
            }
          } else {
            rgb = frame.data;
          }
          frame = _Frame(
            data: rgb,
            format: isTargetSink ? 'mono' : frame.format,
            width: w,
            height: h,
            maxValue: max,
          );
          portOutputs[nodeId] = {
            'out_mono': monoData,
            'out': rgb,
            'out_rgb': rgb,
          };
        }
        break;
      case 'audio_level':
      case 'audio_waveform':
      case 'audio_eq':
        // 音频汇点，不改变数据。
        break;
      default:
        throw StateError('未知节点类型: $typeId');
    }
    portOutputs.putIfAbsent(nodeId, () => {})['out'] = frame.data;
    // 每个节点处理完后的输出（Gamma 节点之后为 RGBA）。
    onNodeOutput?.call(nodeId, rgba ?? frame.data,
        rgba != null ? 'rgba' : frame.format, frame.width, frame.height);
  }

  // 链中没有 Gamma 节点时的默认色调映射：RAW 源（线性数据）按 gamma
  // 2.2 编码；图片/视频源本身已是 sRGB 显示数据，gamma 1.0 直通。
  final defaultGamma =
      firstType == 'image_source' || firstType == 'video_source' ? 1.0 : 2.2;
  final Uint8List result = rgba ??
      switch (frame.format) {
        'rgb' || 'mono' => tonemapToRgba(frame.data,
            maxValue: frame.maxValue, gamma: defaultGamma),
        'yuv' => tonemapToRgba(yuvToRgb(frame.data, maxValue: frame.maxValue),
            maxValue: frame.maxValue, gamma: defaultGamma),
        'hsl' => tonemapToRgba(hslToRgb(frame.data, maxValue: frame.maxValue),
            maxValue: frame.maxValue, gamma: defaultGamma),
        _ => throw StateError('流水线末端不是图像数据（缺少去马赛克）'),
      };
  // 汇点（预览）节点的最终输出恒为 RGBA。
  onNodeOutput?.call(chain.last['nodeId'] as String, result, 'rgba',
      frame.width, frame.height);
  return result;
}

/// compute() 入口：在后台 isolate 中执行单帧。
/// [msg] = {'chain': List<Map>, 'frameIndex': int}，返回 RGBA8888。
/// 视频流式播放时另带 'sourceRgba'/'sourceWidth'/'sourceHeight'
/// （预解码帧，跳过源解码）。
Future<Uint8List> runChainFrameInIsolate(Map<String, Object?> msg) {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  return runChainFrame(chain, msg['frameIndex'] as int,
      sourceRgba: msg['sourceRgba'] as Uint8List?,
      sourceWidth: msg['sourceWidth'] as int?,
      sourceHeight: msg['sourceHeight'] as int?);
}

/// 每个节点输出采样的元素个数上限（防止大帧撑爆消息与界面）。
const int kNodeOutputSampleSize = 256;

/// compute() 入口：执行单帧并采样链上各节点的输出数据。
/// [msg] = `{'chain': List<Map>, 'frameIndex': int}`；
/// 返回 `{'rgba': rgba, 'captures': captures}`，其中 captures 为
/// nodeId → `{'format': String, 'length': int, 'sample': 采样值列表}`，
/// 供调试变量表展示运行值。
Future<Map<String, Object?>> runChainFrameCapturedInIsolate(
    Map<String, Object?> msg) async {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  final snapshots = <String, Map<String, Object?>>{};
  final rgba = await runChainFrame(chain, msg['frameIndex'] as int,
      onNodeOutput: (nodeId, data, format, width, height) {
    snapshots[nodeId] = {
      'format': format,
      'length': data.length,
      'width': width,
      'height': height,
      'sample': data.length <= kNodeOutputSampleSize
          ? List<int>.of(data)
          : List<int>.of(data.sublist(0, kNodeOutputSampleSize)),
    };
  });
  return {'rgba': rgba, 'captures': snapshots};
}

/// compute() 入口：执行单帧，返回链末端节点输出在 (x, y, channel) 处的值。
/// [msg] = `{'chain': List<Map>, 'frameIndex': int, 'x': int, 'y': int,
/// 'channel': int}`；供变量表的坐标查询查看采样窗口之外的元素。
/// 与运行采样一致：同一节点多次回调时取最后一次（末端节点为 RGBA）。
Future<int> runChainValueAtInIsolate(Map<String, Object?> msg) async {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  final x = msg['x'] as int;
  final y = msg['y'] as int;
  final channel = msg['channel'] as int;
  final targetId = chain.last['nodeId'] as String;
  int? value;
  try {
    await runChainFrame(chain, msg['frameIndex'] as int,
        onNodeOutput: (nodeId, data, format, width, height) {
      if (nodeId != targetId) return;
      RangeError.checkValueInInterval(x, 0, width - 1, 'x');
      RangeError.checkValueInInterval(y, 0, height - 1, 'y');
      final channels = Frame3D.channelsOf(format);
      // 末端节点先以中间格式回调、最后以 RGBA 回调：通道不够时等下一次。
      if (channel >= channels) return;
      value = data[(y * width + x) * channels + channel];
    });
  } on StateError {
    // 链末端不是图像数据（如马赛克节点）时 runChainFrame 在回调之后抛错；
    // 目标值已取到则忽略，否则（错误发生在目标节点之前）继续抛出。
    if (value == null) rethrow;
  }
  final v = value;
  if (v == null) throw StateError('通道超出范围，或未取到目标节点的输出数据');
  return v;
}

/// 按仪器类型计算分析数据（常驻 worker isolate 使用，见
/// instrument_worker.dart）。
Map<String, Object?> instrumentAnalyze(
        String kind, Uint8List rgba, int w, int h) =>
    _instrumentResult(kind, rgba, w, h);

/// 按仪器类型计算分析数据（analyze*InIsolate 共用）。
Map<String, Object?> _instrumentResult(
    String kind, Uint8List rgba, int w, int h) {
  switch (kind) {
    case 'histogram':
      final (r, g, b, y) = histogramRgb(rgba);
      return {'kind': kind, 'r': r, 'g': g, 'b': b, 'y': y};
    case 'waveform':
      final (r, g, b, y, cols) = waveformRgb(rgba, w, h);
      return {
        'kind': kind,
        'r': r,
        'g': g,
        'b': b,
        'y': y,
        'columns': cols,
      };
    case 'vectorscope':
      return {'kind': kind, 'counts': vectorscope(rgba)};
    default:
      throw StateError('未知仪器类型: $kind');
  }
}

/// compute() 入口：执行到仪器节点的一帧并计算分析数据。
/// [msg] = `{'chain': List<Map>, 'frameIndex': int,
/// 'kind': 'histogram'|'waveform'|'vectorscope'}`；
/// 返回 `{'kind': kind, ...数据}`：直方图为 r/g/b/y 四个 256 桶，
/// 波形为 counts+columns，矢量示波器为 256x256 counts。
@pragma('vm:entry-point')
Future<Map<String, Object?>> analyzeInstrumentInIsolate(
    Map<String, Object?> msg) async {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  final kind = msg['kind'] as String;
  final rgba = await runChainFrame(chain, msg['frameIndex'] as int);
  final (w, h) = await sourceDimensions(
      chain.first['typeId'] as String,
      chain.first['params'] as Map<String, Object?>);
  return _instrumentResult(kind, rgba, w, h);
}

/// compute() 入口：直接对 RGBA8888 帧计算仪器分析数据。
/// [msg] = `{'rgba': Uint8List, 'width': int, 'height': int, 'kind': ...}`；
/// 播放中复用预览已算出的帧，无需重跑流水线。
@pragma('vm:entry-point')
Future<Map<String, Object?>> analyzeRgbaInIsolate(
    Map<String, Object?> msg) async {
  return _instrumentResult(
    msg['kind'] as String,
    msg['rgba'] as Uint8List,
    msg['width'] as int,
    msg['height'] as int,
  );
}

/// 连续播放高速预览降采样（2x）：将 8 位 RGBA (w x h) 快速降采样为 (w/2 x h/2)。
/// 算法为超高速步长采样，全帧 1080p 仅需 ~1.5 毫秒。
(Uint8List, int, int) downsampleRgba82x(Uint8List src, int w, int h) {
  final outW = w >> 1;
  final outH = h >> 1;
  final dst = Uint8List(outW * outH * 4);
  final srcStride2 = w * 8; // (w * 4) * 2
  var dstIdx = 0;
  var srcRow = 0;
  for (var y = 0; y < outH; y++, srcRow += srcStride2) {
    var srcIdx = srcRow;
    for (var x = 0; x < outW; x++, srcIdx += 8, dstIdx += 4) {
      dst[dstIdx] = src[srcIdx];
      dst[dstIdx + 1] = src[srcIdx + 1];
      dst[dstIdx + 2] = src[srcIdx + 2];
      dst[dstIdx + 3] = src[srcIdx + 3];
    }
  }
  return (dst, outW, outH);
}
