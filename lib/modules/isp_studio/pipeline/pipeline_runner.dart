import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/isp_graph.dart';
import 'dng_source.dart';
import 'frame3d.dart';
import 'image_source.dart';
import 'video_source.dart';
import 'instruments.dart';
import 'isp_kernels.dart';

export 'isp_kernels.dart'
    show
        downsampleRgba82x,
        downsampleYuv444p2x,
        downsampleRgba8Step,
        mono8ToRgba,
        yuv444p8ToRgba,
        yuv420p8ToRgbaStep,
        yuv420pPlaneToRgbaStep;

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
  // 含荧光融合节点的链允许 2 个源节点（白光 + 荧光双路），其余链单源。
  final hasFusion = chain.any((op) => op['typeId'] == 'fluoro_fusion');
  if (sources > (hasFusion ? 2 : 1)) {
    throw StateError(hasFusion ? '一条流水线最多两个源节点' : '一条流水线只能有一个源节点');
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
  // DNG（TIFF 容器）单帧文件：解析头部校验格式后直接返回 1。
  if (isDngPath(path)) {
    await readDngInfo(path);
    return 1;
  }
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
  /// mosaic/mono 时长度 w*h；rgb/yuv/hsl 时长度 w*h*3（三通道交织）。
  /// 平面轨道（[yuvPlanes8]/[mono8] 非空）时为空占位。
  Uint16List data;

  /// 'mosaic' | 'rgb' | 'yuv' | 'hsl' | 'mono'
  String format;

  /// 视频 yuv444p 直出的平面轨道：三个 w*h 的 8 位平面（Y/U/V）视图，
  /// 分路/合路零拷贝，仅全分辨率视频播放使用。
  List<Uint8List>? yuvPlanes8;

  /// 单通道 8 位 mono 轨道（视频分路预览汇点）：直接 LUT 出图。
  Uint8List? mono8;

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
    this.yuvPlanes8,
    this.mono8,
    this.irSubtraction = 0.5,
  });

  void requireMosaic(String opName) {
    if (format != 'mosaic') throw StateError('$opName需要 RAW 马赛克输入');
  }

  void requireRgb(String opName) {
    if (format != 'rgb') throw StateError('$opName需要 RGB 输入');
  }

  void requireMono(String opName) {
    if (format != 'mono') throw StateError('$opName需要 Mono 输入');
  }

  /// RAW 域算子：Bayer 马赛克或 16 位 mono 均可（mono 时按全像素邻域）。
  void requireMosaicOrMono(String opName) {
    if (format != 'mosaic' && format != 'mono') {
      throw StateError('$opName需要 RAW 马赛克或 Mono 输入');
    }
  }
}

/// 解码 RAW 源节点的一帧为 [_Frame]（读文件 + 解包）。
/// MONO 无 CFA：保持 16 位单通道 mono 格式（w*h）入链，不再展开为 RGB。
Future<_Frame> _decodeRawSource(
    String typeId, Map<String, Object?> sp, int frameIndex) async {
  // DNG（TIFF 容器）：尺寸/位深/排列以文件头为准，走专用解析路径。
  if (isDngPath(_str(sp, 'filePath'))) {
    return _decodeDngSource(typeId, sp, frameIndex);
  }
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
  final cfa = _rawCfaOf(typeId, sp);
  if (cfa == 'mono') {
    // MONO 无 CFA：单通道直接入链（16 位 mono 中间格式）。
    return _Frame(
        data: mosaic,
        format: 'mono',
        width: width,
        height: height,
        maxValue: maxValue);
  }
  return _Frame(
    data: mosaic,
    format: 'mosaic',
    cfa: cfa,
    bayerPattern: cfa == 'bayer'
        ? BayerPattern.fromName(
            _str(sp, 'bayerPattern').isEmpty ? 'RGGB' : _str(sp, 'bayerPattern'))
        : null,
    width: width,
    height: height,
    maxValue: maxValue,
    irSubtraction: _double(sp, 'irSubtraction'),
  );
}

/// 解码 DNG 源节点的一帧为 [_Frame]：几何（宽/高）、白电平与 Bayer
/// 排列以文件头为准（参数面板里的对应参数在选中文件时已自动填充为
/// 相同值）。DNG 恒为单帧。CFA 种类仍由节点类型决定（DNG 只有 Bayer，
/// 挂到非 Bayer 的 RAW 节点上时排列参数无意义，按直通处理）。
Future<_Frame> _decodeDngSource(
    String typeId, Map<String, Object?> sp, int frameIndex) async {
  final baseFrame = _int(sp, 'frameIndex');
  if (baseFrame + frameIndex > 0) {
    throw StateError('DNG 文件只有一帧');
  }
  final (info, mosaic) = await readDngFrame(_str(sp, 'filePath'));
  // 镜头阴影校正（GainMap 操作码）：DNG 解码的标准步骤，
  // 按相位减黑电平→乘网格增益→加回黑电平→截位到白电平。
  if (info.gainMaps.isNotEmpty) {
    applyDngGainMaps(mosaic, info.width, info.height, info.gainMaps,
        blackLevels: info.blackLevels, whiteLevel: info.whiteLevel);
  }
  final cfa = _rawCfaOf(typeId, sp);
  if (cfa == 'mono') {
    return _Frame(
        data: mosaic,
        format: 'mono',
        width: info.width,
        height: info.height,
        maxValue: info.whiteLevel);
  }
  return _Frame(
    data: mosaic,
    format: 'mosaic',
    cfa: cfa,
    bayerPattern: cfa == 'bayer'
        ? BayerPattern.fromName(info.cfaPattern ??
            (_str(sp, 'bayerPattern').isEmpty ? 'RGGB' : _str(sp, 'bayerPattern')))
        : null,
    width: info.width,
    height: info.height,
    maxValue: info.whiteLevel,
    irSubtraction: _double(sp, 'irSubtraction'),
  );
}

/// 时域 IIR 降噪节点的历史帧缓存：nodeId →
/// {'history': Uint16List, 'frame': int, 'w': int, 'h': int,
///  'alpha': double, 'motion': bool}。
/// 常驻 worker 内跨帧有效；frameIndex 不连续或尺寸/参数变化时重置。
/// compute() 单次 isolate 路径无历史则直通，行为安全。
final _temporalHistory = <String, Map<String, Object?>>{};

/// 视频格式输入组端口名（与 IspNodeType.videoInputGroupPorts 一致；
/// 本地保留一份以保持本文件无模型依赖）。
const _videoInputPorts = ['in', 'in_yuv', 'in_hsl', 'in_mono'];

/// 平面 8 位 YUV → 16 位量级交织（值域 0..255 直通）：平面轨道与仅
/// 支持交织数据的算子（如 RGB 分路器）衔接时的兜底物化。
Uint16List _interleavePlanes8(List<Uint8List> planes, int pixels) {
  final out = Uint16List(pixels * 3);
  final y = planes[0], u = planes[1], v = planes[2];
  var j = 0;
  for (var i = 0; i < pixels; i++, j += 3) {
    out[j] = y[i];
    out[j + 1] = u[i];
    out[j + 2] = v[i];
  }
  return out;
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
/// [sourceYuv] 同理：预解码的全范围平面 yuv444p 帧（w*h*3），仅当
/// 链输出格式为 yuv 时生效，比 [sourceRgba] 少两道全帧转换。
/// [captureSinks]/[capturedRgba]：多路预览的前缀覆盖去重——链 A 是
/// 链 B 的前缀时由 B 顺带捕获 A 汇点（preview 类节点）的显示图，
/// 捕获结果填入 [capturedRgba]（含 A 链末端的默认色调映射）。
/// [nodeTimingsUs] 非空时，把每个节点的执行耗时（微秒）累加进该
/// 映射（nodeId → µs）：源节点记解码耗时，其余算子记各自 case 的
/// 处理耗时，链末默认色调映射计入汇点节点。同一节点多次出现时累加。
/// [onNodeStart] 非空时，每个节点开始执行前回调其 nodeId（源节点
/// 在最前，顺序即链序），供进度显示报告当前运行位置。
Future<Uint8List> runChainFrame(
  List<Map<String, Object?>> chain,
  int frameIndex, {
  void Function(String nodeId, List<int> data, String format, int width,
      int height)? onNodeOutput,
  void Function(String nodeId)? onNodeStart,
  Uint8List? sourceRgba,
  int? sourceWidth,
  int? sourceHeight,
  Uint8List? sourceYuv,
  Set<String>? captureSinks,
  Map<String, Uint8List>? capturedRgba,
  Map<String, int>? nodeTimingsUs,
}) async {
  if (chain.isEmpty || !sourceTypes.contains(chain.first['typeId'])) {
    throw StateError('算子链必须以源节点开头');
  }
  final firstType = chain.first['typeId'] as String;
  final sp = (chain.first['params'] as Map?)?.cast<String, Object?>() ?? const {};
  final firstNodeId = chain.first['nodeId'] as String? ?? 'source';

  _Frame frame;
  final srcSw = nodeTimingsUs == null ? null : (Stopwatch()..start());
  onNodeStart?.call(firstNodeId);
  if (firstType == 'image_source' || firstType == 'video_source') {
    if (firstType == 'image_source' && frameIndex > 0) {
      throw StateError('图片源只有一帧');
    }
    final maxValue = bayerMaxValue(
        int.parse(_str(sp, 'bitDepth').isEmpty ? '8' : _str(sp, 'bitDepth')));
    final outFormat = chain.first['outFormat'] as String? ?? 'rgb';
    if (sourceYuv != null && outFormat == 'yuv') {
      // 视频流式播放的 YUV 直出帧：平面轨道（三个 8 位平面视图），
      // 分路/合路/出图全程零拷贝，无 16 位交织中间格式。
      final w0 = sourceWidth!;
      final h0 = sourceHeight!;
      final px = w0 * h0;
      if (sourceYuv.length < px * 3) {
        throw StateError('帧 $frameIndex 解码失败（可能超出视频末尾）');
      }
      frame = _Frame(
        data: Uint16List(0),
        format: 'yuv',
        width: w0,
        height: h0,
        maxValue: maxValue,
        yuvPlanes8: [
          Uint8List.sublistView(sourceYuv, 0, px),
          Uint8List.sublistView(sourceYuv, px, px * 2),
          Uint8List.sublistView(sourceYuv, px * 2, px * 3),
        ],
      );
    } else {
      final (rgb, w, h) = sourceRgba != null
          ? rgba8ToRgb16(sourceRgba, sourceWidth!, sourceHeight!, maxValue)
          : firstType == 'image_source'
              ? await decodeImageFileToRgb16(_str(sp, 'filePath'),
                  maxValue: maxValue)
              : await decodeVideoFrameToRgb16(_str(sp, 'filePath'), frameIndex,
                  maxValue: maxValue, ffmpegPath: _str(sp, 'ffmpegPath'));
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
    }
  } else {
    frame = await _decodeRawSource(firstType, sp, frameIndex);
  }
  if (nodeTimingsUs != null) {
    nodeTimingsUs[firstNodeId] = (nodeTimingsUs[firstNodeId] ?? 0) +
        srcSw!.elapsedMicroseconds;
  }
  // 源节点输出（解包/解码后的帧）。
  onNodeOutput?.call(
      firstNodeId, frame.data, frame.format, frame.width, frame.height);

  final portOutputs = <String, Map<String, List<int>>>{};
  portOutputs[firstNodeId] = {
    'out': frame.data,
    'out_rgb': frame.data,
    'out_yuv': frame.data,
    'out_hsl': frame.data,
  };

  // 多源链（含荧光融合节点，compileChain 已校验最多 2 个源）：每个算子
  // 按其视频组输入连接（'in'/'in_mono' 等）从 frames 取输入帧，第二个
  // 源节点在循环内按需解码；单源链行为完全不变（线性 frame 路径）。
  final multiSource =
      chain.where((op) => sourceTypes.contains(op['typeId'])).length > 1;
  final frames = <String, _Frame>{firstNodeId: frame};

  List<int>? getPortData(Map<String, Object?> op, String inputPortName) {
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
  // 前缀覆盖捕获暂存：nodeId → 单通道 mono 数据 / 透传帧引用。
  final monoCaptures = <String, List<int>>{};
  final passthroughCaptures = <String, _Frame>{};
  for (final op in chain.skip(1)) {
    final typeId = op['typeId'] as String;
    final nodeId = op['nodeId'] as String? ?? typeId;
    final p = (op['params'] as Map?)?.cast<String, Object?>() ?? const {};
    onNodeStart?.call(nodeId);
    final opSw = nodeTimingsUs == null ? null : (Stopwatch()..start());
    if (multiSource) {
      if (sourceTypes.contains(typeId)) {
        // 第二个源节点（荧光支路）：仅支持 RAW 源，解码后入 frames。
        if (!rawSourceTypes.contains(typeId)) {
          throw StateError('多源链的额外源节点仅支持 RAW 源');
        }
        frame = await _decodeRawSource(typeId, p, frameIndex);
        frames[nodeId] = frame;
        portOutputs[nodeId] = {'out': frame.data};
        if (nodeTimingsUs != null) {
          nodeTimingsUs[nodeId] =
              (nodeTimingsUs[nodeId] ?? 0) + opSw!.elapsedMicroseconds;
        }
        onNodeOutput?.call(
            nodeId, frame.data, frame.format, frame.width, frame.height);
        continue;
      }
      // 按视频组输入连接从 frames 取本算子的输入帧。
      final inputs = op['inputs'] as Map<String, Object?>?;
      if (inputs != null) {
        for (final port in _videoInputPorts) {
          final conn = inputs[port] as Map<String, Object?>?;
          final from = conn?['fromNodeId'] as String?;
          final upstream = from == null ? null : frames[from];
          if (upstream != null) {
            frame = upstream;
            break;
          }
        }
      }
    }
    switch (typeId) {
      case 'black_level':
        frame.requireMosaicOrMono('黑电平校正');
        if (frame.format == 'mono') {
          // mono（荧光链）：用 r 参数作为统一偏移扣除（N01–N03）。
          final off = _double(p, 'r');
          if (off != 0) {
            for (var i = 0; i < frame.data.length; i++) {
              final v = frame.data[i] - off;
              frame.data[i] = v <= 0 ? 0 : v.round();
            }
          }
          break;
        }
        // 非 Bayer CFA 同样按 2x2 相位施加偏移（近似）。
        applyBlackLevel(frame.data,
            width: frame.width,
            height: frame.height,
            pattern: frame.bayerPattern ?? BayerPattern.rggb,
            r: _double(p, 'r'),
            gr: _double(p, 'gr'),
            gb: _double(p, 'gb'),
            b: _double(p, 'b'));
      // ---- ICG 荧光内窥镜方案：RAW 域算子（mosaic/mono 双格式）----
      case 'dpc':
        frame.requireMosaicOrMono('坏点校正');
        applyDpc(frame.data,
            width: frame.width,
            height: frame.height,
            pattern: frame.format == 'mosaic' ? frame.bayerPattern : null,
            threshold: _double(p, 'threshold'),
            mode: _str(p, 'mode').isEmpty ? 'median' : _str(p, 'mode'),
            maxValue: frame.maxValue);
      case 'fpn':
        frame.requireMosaicOrMono('FPN 校正');
        applyFpn(frame.data,
            width: frame.width,
            height: frame.height,
            pattern: frame.format == 'mosaic' ? frame.bayerPattern : null,
            row: p['row'] != false,
            col: p['col'] != false,
            maxCorr: _double(p, 'maxCorr'));
      case 'lsc':
        frame.requireMosaicOrMono('镜头阴影校正');
        applyLsc(frame.data,
            width: frame.width,
            height: frame.height,
            pattern: frame.format == 'mosaic' ? frame.bayerPattern : null,
            strength: _double(p, 'strength'),
            centerX: _double(p, 'centerX'),
            centerY: _double(p, 'centerY'),
            maxValue: frame.maxValue);
      case 'grgb_balance':
        frame.requireMosaicOrMono('Gr/Gb 均衡');
        // mono 无 Gr/Gb 相位概念，直通。
        final bp = frame.format == 'mosaic' ? frame.bayerPattern : null;
        if (bp != null) {
          applyGrGbBalance(frame.data,
              width: frame.width,
              height: frame.height,
              pattern: bp,
              strength: _double(p, 'strength'));
        }
      case 'bayer_dnr':
        frame.requireMosaicOrMono('Bayer 降噪');
        applyBayerDenoise(frame.data,
            width: frame.width,
            height: frame.height,
            pattern: frame.format == 'mosaic' ? frame.bayerPattern : null,
            strength: _double(p, 'strength'));
      case 'highlight':
        frame.requireMosaicOrMono('高光恢复');
        applyHighlightRecovery(frame.data,
            width: frame.width,
            height: frame.height,
            pattern: frame.format == 'mosaic' ? frame.bayerPattern : null,
            maxValue: frame.maxValue,
            mode: _str(p, 'mode').isEmpty ? 'recover' : _str(p, 'mode'),
            knee: _double(p, 'knee'));
      // ---- RGB 域算子 ----
      case 'rgb_dnr':
        frame.requireRgb('RGB 降噪');
        applyRgbDenoise(frame.data,
            width: frame.width,
            height: frame.height,
            luma: _double(p, 'luma'),
            chroma: _double(p, 'chroma'),
            maxValue: frame.maxValue);
      case 'sharpen':
        frame.requireRgb('锐化');
        applySharpen(frame.data,
            width: frame.width,
            height: frame.height,
            amount: _double(p, 'amount'),
            threshold: _double(p, 'threshold'),
            maxValue: frame.maxValue);
      case 'csc_rgb2yuv':
        frame.requireRgb('RGB→YUV 转换');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: convertRgbToYuvCsc(frame.data,
              width: w,
              height: h,
              standard: _str(p, 'standard').isEmpty ? 'bt601' : _str(p, 'standard'),
              range: _str(p, 'range').isEmpty ? 'full' : _str(p, 'range'),
              maxValue: max),
          format: 'yuv',
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- 荧光 mono 域算子 ----
      case 'fluoro_leak':
        frame.requireMono('激发泄漏扣除');
        applyFluoroLeak(frame.data,
            level: _double(p, 'level'), maxSub: _double(p, 'maxSub'));
      case 'fluoro_background':
        frame.requireMono('背景扣除');
        applyFluoroBackground(frame.data,
            width: frame.width,
            height: frame.height,
            blockSize: _int(p, 'blockSize'),
            strength: _double(p, 'strength'));
      case 'fluoro_normalize':
        frame.requireMono('激发归一化');
        applyFluoroNormalize(frame.data,
            reference: _double(p, 'reference'),
            epsilon: _double(p, 'epsilon'),
            maxValue: frame.maxValue);
      case 'fluoro_temporal':
        frame.requireMono('时域降噪');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final alpha = _double(p, 'alpha');
        final motion = p['motionAdapt'] != false;
        // 时域历史按 nodeId 缓存：frameIndex 不连续或尺寸/参数变化时重置。
        final st = _temporalHistory[nodeId];
        final valid = st != null &&
            st['frame'] == frameIndex - 1 &&
            st['w'] == w &&
            st['h'] == h &&
            st['alpha'] == alpha &&
            st['motion'] == motion;
        final (out, newHistory) = applyTemporalIir(frame.data,
            history: valid ? st['history'] as Uint16List : null,
            alpha: alpha,
            motionAdapt: motion,
            maxValue: max);
        _temporalHistory[nodeId] = {
          'history': newHistory,
          'frame': frameIndex,
          'w': w,
          'h': h,
          'alpha': alpha,
          'motion': motion,
        };
        frame = _Frame(
            data: out, format: 'mono', width: w, height: h, maxValue: max);
      // ---- 映射/融合 ----
      case 'pseudo_color':
        frame.requireMono('伪彩映射');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: monoPseudoColor(frame.data,
              width: w,
              height: h,
              colormap: _str(p, 'colormap').isEmpty ? 'green' : _str(p, 'colormap'),
              gain: _double(p, 'gain'),
              maxValue: max),
          format: 'rgb',
          width: w,
          height: h,
          maxValue: max,
        );
      case 'fluoro_fusion':
        frame.requireRgb('荧光融合');
        // 白光 RGB（线性/多源路径的当前帧）× 荧光 mono（in_fluoro 端口）。
        final flData = getPortData(op, 'in_fluoro');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        if (flData is Uint16List && flData.length == w * h) {
          frame = _Frame(
            data: fuseFluorescence(frame.data, flData,
                width: w,
                height: h,
                mode: _str(p, 'mode').isEmpty ? 'alpha' : _str(p, 'mode'),
                threshold: _double(p, 'threshold'),
                alphaMax: _double(p, 'alphaMax'),
                colormap:
                    _str(p, 'colormap').isEmpty ? 'green' : _str(p, 'colormap'),
                offsetX: _double(p, 'offsetX'),
                offsetY: _double(p, 'offsetY'),
                maxValue: max),
            format: 'rgb',
            width: w,
            height: h,
            maxValue: max,
          );
        }
        // 荧光输入未连接或尺寸不符：白光直通。
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
          // 平面轨道先物化为交织（兜底路径，非常规连接）。
          final yuvData = frame.yuvPlanes8 != null
              ? _interleavePlanes8(frame.yuvPlanes8!, w * h)
              : frame.data;
          frame = _Frame(
            data: yuvToRgb(yuvData, maxValue: max),
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
        final planes8 = frame.yuvPlanes8;
        if (planes8 != null) {
          // 平面轨道：分路 = 三个平面的零拷贝视图。
          portOutputs[nodeId] = {
            'out_y': planes8[0],
            'out_u': planes8[1],
            'out_v': planes8[2],
          };
          break;
        }
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
        // 平面轨道：三路输入都是整帧 8 位平面时直接引用（零拷贝），
        // 数据与分路器输出同源时是纯粹的透传合路。
        if (yData is Uint8List && uData is Uint8List && vData is Uint8List &&
            yData.length == pixels &&
            uData.length == pixels &&
            vData.length == pixels) {
          frame = _Frame(
            data: Uint16List(0),
            format: 'yuv',
            width: w,
            height: h,
            maxValue: max,
            yuvPlanes8: [yData, uData, vData],
          );
          portOutputs[nodeId] = {'out': Uint16List(0)};
          break;
        }
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
          if (isTargetSink && isSingleChan && monoData is Uint8List) {
            // 8 位平面 MONO 汇点（视频分路预览零拷贝轨道）：
            // 链末端 mono8ToRgba 一趟 LUT 出图。
            frame = _Frame(
              data: Uint16List(0),
              format: 'mono',
              width: w,
              height: h,
              maxValue: max,
              mono8: monoData,
            );
            portOutputs[nodeId] = {'out_mono': monoData};
          } else {
            final Uint16List rgb;
            if (isTargetSink && isSingleChan) {
              // 单通道 MONO 汇点：保留单通道数据，链末端 monoToRgba
              // 一趟出图，免去灰度扩展 + 三通道查表。
              rgb = monoData as Uint16List;
            } else if (isTargetSink) {
              // in_mono 接的是 3 通道交织数据：按 BT.601 加权转灰度。
              rgb = Uint16List(pixels * 3);
              for (var pIdx = 0; pIdx < pixels; pIdx++) {
                final val = ((77 *
                            (3 * pIdx < monoData.length
                                ? monoData[3 * pIdx]
                                : 0) +
                        150 *
                            (3 * pIdx + 1 < monoData.length
                                ? monoData[3 * pIdx + 1]
                                : 0) +
                        29 *
                            (3 * pIdx + 2 < monoData.length
                                ? monoData[3 * pIdx + 2]
                                : 0) +
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
        }
        // 前缀覆盖捕获（多路预览去重）：本节点是被覆盖链的汇点时，
        // 记下其显示输入（单通道 mono 数据或透传帧引用），链末端统一
        // 做默认色调映射后填入 capturedRgba。
        if (captureSinks != null && captureSinks.contains(nodeId)) {
          final pixels = frame.width * frame.height;
          if (monoData != null && monoData.length == pixels) {
            monoCaptures[nodeId] = monoData;
          } else if (monoData == null) {
            passthroughCaptures[nodeId] = frame;
          }
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
    final opOuts = portOutputs.putIfAbsent(nodeId, () => {});
    opOuts['out'] = frame.data;
    // mono 帧同时登记 out_mono，供下游 in_mono/in_fluoro 连接取数。
    if (frame.format == 'mono') opOuts['out_mono'] = frame.data;
    if (multiSource) frames[nodeId] = frame;
    if (nodeTimingsUs != null) {
      nodeTimingsUs[nodeId] =
          (nodeTimingsUs[nodeId] ?? 0) + opSw!.elapsedMicroseconds;
    }
    // 每个节点处理完后的输出（Gamma 节点之后为 RGBA）。
    onNodeOutput?.call(nodeId, rgba ?? frame.data,
        rgba != null ? 'rgba' : frame.format, frame.width, frame.height);
  }

  // 链中没有 Gamma 节点时的默认色调映射：RAW 源（线性数据）按 gamma
  // 2.2 编码；图片/视频源本身已是 sRGB 显示数据，gamma 1.0 直通。
  final tailSw = nodeTimingsUs == null ? null : (Stopwatch()..start());
  final defaultGamma =
      firstType == 'image_source' || firstType == 'video_source' ? 1.0 : 2.2;
  final Uint8List result = rgba ??
      switch (frame.format) {
        'rgb' => tonemapToRgba(frame.data,
            maxValue: frame.maxValue, gamma: defaultGamma),
        // 单通道 MONO：8 位平面轨道（视频分路预览）直接 LUT；
        // 16 位单通道一趟查表；三通道灰度（RAW MONO 源等）走通用 tonemap。
        'mono' => frame.mono8 != null
            ? mono8ToRgba(frame.mono8!, gamma: defaultGamma)
            : frame.data.length == frame.width * frame.height
                ? monoToRgba(frame.data,
                    maxValue: frame.maxValue, gamma: defaultGamma)
                : tonemapToRgba(frame.data,
                    maxValue: frame.maxValue, gamma: defaultGamma),
        // 平面轨道（视频 YUV 直出/零拷贝合路）：定点 8 位一趟出图。
        'yuv' => frame.yuvPlanes8 != null
            ? yuv444p8ToRgba(frame.yuvPlanes8!, frame.width, frame.height,
                gamma: defaultGamma)
            : yuvToRgba(frame.data,
                maxValue: frame.maxValue, gamma: defaultGamma),
        'hsl' => tonemapToRgba(hslToRgb(frame.data, maxValue: frame.maxValue),
            maxValue: frame.maxValue, gamma: defaultGamma),
        _ => throw StateError('流水线末端不是图像数据（缺少去马赛克）'),
      };
  // 汇点（预览）节点的最终输出恒为 RGBA；链末默认色调映射的耗时
  // 计入汇点节点。
  final sinkNodeId = chain.last['nodeId'] as String? ?? 'sink';
  if (nodeTimingsUs != null) {
    nodeTimingsUs[sinkNodeId] =
        (nodeTimingsUs[sinkNodeId] ?? 0) + tailSw!.elapsedMicroseconds;
  }
  onNodeOutput?.call(sinkNodeId, result, 'rgba',
      frame.width, frame.height);
  // 被覆盖链汇点的显示图：与本链末端同一默认色调映射。
  if (capturedRgba != null) {
    for (final e in monoCaptures.entries) {
      final v = e.value;
      capturedRgba[e.key] = v is Uint8List
          ? mono8ToRgba(v, gamma: defaultGamma)
          : monoToRgba(v as Uint16List,
              maxValue: frame.maxValue, gamma: defaultGamma);
    }
    for (final e in passthroughCaptures.entries) {
      final f0 = e.value;
      final Uint8List? rgba2;
      if (f0.yuvPlanes8 != null) {
        rgba2 = yuv444p8ToRgba(f0.yuvPlanes8!, f0.width, f0.height,
            gamma: defaultGamma);
      } else if (f0.mono8 != null) {
        rgba2 = mono8ToRgba(f0.mono8!, gamma: defaultGamma);
      } else {
        rgba2 = switch (f0.format) {
          'rgb' => tonemapToRgba(f0.data,
              maxValue: f0.maxValue, gamma: defaultGamma),
          'mono' when f0.data.length == f0.width * f0.height =>
            monoToRgba(f0.data, maxValue: f0.maxValue, gamma: defaultGamma),
          'mono' => tonemapToRgba(f0.data,
              maxValue: f0.maxValue, gamma: defaultGamma),
          'yuv' =>
            yuvToRgba(f0.data, maxValue: f0.maxValue, gamma: defaultGamma),
          'hsl' => tonemapToRgba(hslToRgb(f0.data, maxValue: f0.maxValue),
              maxValue: f0.maxValue, gamma: defaultGamma),
          _ => null, // 非图像格式：不捕获，由调用方回退单独执行该链
        };
      }
      if (rgba2 != null) capturedRgba[e.key] = rgba2;
    }
  }
  return result;
}

/// compute() 入口：在后台 isolate 中执行单帧。
/// [msg] = {'chain': List<Map>, 'frameIndex': int}，返回 RGBA8888。
/// 视频流式播放时另带 'sourceRgba'/'sourceWidth'/'sourceHeight'
/// （预解码帧，跳过源解码）；YUV 直出流程改带 'sourceYuv'
/// （平面 yuv444p 帧）。
Future<Uint8List> runChainFrameInIsolate(Map<String, Object?> msg) {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  return runChainFrame(chain, msg['frameIndex'] as int,
      sourceRgba: msg['sourceRgba'] as Uint8List?,
      sourceWidth: msg['sourceWidth'] as int?,
      sourceHeight: msg['sourceHeight'] as int?,
      sourceYuv: msg['sourceYuv'] as Uint8List?);
}

/// 每个节点输出采样的元素个数上限（防止大帧撑爆消息与界面）。
const int kNodeOutputSampleSize = 256;

/// compute() 入口：执行单帧并采样链上各节点的输出数据。
/// [msg] = `{'chain': List<Map>, 'frameIndex': int}`；
/// 返回 `{'rgba': rgba, 'captures': captures, 'timings': timings}`，其中
/// captures 为 nodeId → `{'format': String, 'length': int, 'sample': 采样值列表}`，
/// 供调试变量表展示运行值；timings 为 nodeId → 执行耗时微秒数，
/// 供节点卡片显示节点工作时间。
Future<Map<String, Object?>> runChainFrameCapturedInIsolate(
    Map<String, Object?> msg) async {
  final chain = (msg['chain'] as List).cast<Map<String, Object?>>();
  final snapshots = <String, Map<String, Object?>>{};
  final timings = <String, int>{};
  final rgba = await runChainFrame(chain, msg['frameIndex'] as int,
      nodeTimingsUs: timings,
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
  return {'rgba': rgba, 'captures': snapshots, 'timings': timings};
}

/// [runChainFrameWithProgress] 的 worker isolate 入口。
/// 启动参数 `[SendPort, chain, frameIndex]`；每个节点开始执行前回
/// `{'type':'nodeStart', 'nodeId':..., 'index':..., 'total':...}`，
/// 完成回 `{'type':'done', 'rgba':..., 'captures':..., 'timings':...}`
/// （与 [runChainFrameCapturedInIsolate] 的返回同构），失败回
/// `{'type':'error', 'message':...}`。
@pragma('vm:entry-point')
Future<void> _chainFrameProgressWorker(List<Object?> args) async {
  final send = args[0] as SendPort;
  try {
    final chain = (args[1] as List).cast<Map<String, Object?>>();
    final snapshots = <String, Map<String, Object?>>{};
    final timings = <String, int>{};
    final total = chain.length;
    var index = 0;
    final rgba = await runChainFrame(chain, args[2] as int,
        nodeTimingsUs: timings,
        onNodeStart: (nodeId) {
      send.send(<String, Object?>{
        'type': 'nodeStart',
        'nodeId': nodeId,
        'index': index,
        'total': total,
      });
      index++;
    }, onNodeOutput: (nodeId, data, format, width, height) {
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
    send.send(<String, Object?>{
      'type': 'done',
      'rgba': rgba,
      'captures': snapshots,
      'timings': timings,
    });
  } catch (e) {
    send.send(<String, Object?>{'type': 'error', 'message': '$e'});
  }
}

/// 在独立 isolate 中执行单帧（返回与 [runChainFrameCapturedInIsolate]
/// 同构的 map），每个节点开始执行时回调 [onNodeStart]
/// （nodeId、链内序号 index、链节点总数 total）。
/// 与 compute() 的区别：compute 一次性返回结果，无法流式回报进度；
/// 这里用 Isolate.spawn + ReceivePort 换进度回报能力。
Future<Map<String, Object?>> runChainFrameWithProgress(
  List<Map<String, Object?>> chain,
  int frameIndex, {
  void Function(String nodeId, int index, int total)? onNodeStart,
}) async {
  final port = ReceivePort();
  final completer = Completer<Map<String, Object?>>();
  final sub = port.listen((msg) {
    if (msg is! Map) return;
    switch (msg['type']) {
      case 'nodeStart':
        onNodeStart?.call(msg['nodeId'] as String, msg['index'] as int,
            msg['total'] as int);
      case 'done':
        completer.complete(msg.cast<String, Object?>());
      case 'error':
        completer.completeError(
            StateError(msg['message']?.toString() ?? '流水线执行失败'));
    }
  });
  final isolate = await Isolate.spawn(
      _chainFrameProgressWorker, [port.sendPort, chain, frameIndex]);
  try {
    return await completer.future;
  } finally {
    await sub.cancel();
    port.close();
    isolate.kill();
  }
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
        String kind, Uint8List rgba, int w, int h,
        {Set<String>? visible}) =>
    _instrumentResult(kind, rgba, w, h, visible: visible);

/// 按仪器类型计算分析数据（analyze*InIsolate 共用）。
/// [visible] 仅波形使用：只统计可见通道（播放中示波器通常只看
/// 部分通道，全通道统计有 3/4 是无用功）；为 null 时全通道。
Map<String, Object?> _instrumentResult(
    String kind, Uint8List rgba, int w, int h,
    {Set<String>? visible}) {
  switch (kind) {
    case 'histogram':
      final (r, g, b, y) = histogramRgb(rgba);
      return {'kind': kind, 'r': r, 'g': g, 'b': b, 'y': y};
    case 'waveform':
      if (visible != null) {
        final (tables, cols) = waveformSelective(rgba, w, h, visible);
        return {'kind': kind, ...tables, 'columns': cols};
      }
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
