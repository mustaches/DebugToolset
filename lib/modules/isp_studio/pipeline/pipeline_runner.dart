import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/isp_graph.dart';
import 'color_temp.dart';
import 'dng_source.dart';
import 'demosaic_advanced.dart';
import 'frame3d.dart';
import 'image_source.dart';
import 'video_source.dart';
import 'instruments.dart';
import 'brisque.dart';
import 'isp_kernels.dart';
import 'levels_curve.dart';
import 'niqe.dart';
import 'piqe.dart';

export 'levels_curve.dart'
    show
        kLevelsMax,
        kLevelsIdentityPoints,
        levelsPointsFromParam,
        normalizeLevelsPoints,
        levelsCurveIsIdentity,
        levelsCurveEval,
        levelsCurveLut;

export 'color_temp.dart'
    show
        kColorTempMin,
        kColorTempMax,
        kColorTempDefault,
        cctToWhitePoint,
        colorTempGains,
        colorTempCcm,
        measureCctFromRgba;

export 'isp_kernels.dart'
    show
        downsampleRgba82x,
        downsampleRgba82xInIsolate,
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

/// 双输入全参考评价仪器（参考图 in* + 测试图 in_test* 两路输入，
/// 各自可追溯到独立源节点）：编译到这类汇点的链允许 2 个源节点。
const dualInputMetricTypes = {
  'psnr',
  'ssim',
  'msssim',
  'fsim',
  'lpips',
  'dists',
  'fid',
  'kid',
};

/// 从 [sinkNodeId] 反向收集上游节点，按拓扑序编译为算子链。
///
/// 链中至少包含一个源节点（[sourceTypes] 之一）且位于链首；双路输入
/// 节点（荧光融合/乘法器/加法器/混叠器、PSNR 等双输入评价仪器）允许
/// 2 个源，多路选择器允许 4 个，其余链限 1 个。
/// 图片源会附加 `outFormat`（'rgb'/'yuv'/'hsl'），由其出边端口决定。
/// 抛出 [StateError]（中文消息）当：图有环、汇点不存在、缺少源节点等。
List<Map<String, Object?>> compileChain(IspGraph graph, String sinkNodeId) {
  if (!graph.nodes.containsKey(sinkNodeId)) {
    throw StateError('目标节点不存在');
  }
  // 上游追溯：多路选择器（mux4）未选中的输入支路是死路——不追溯、
  // 不参与编译（不解码、不计入源节点数）。'in$sel' 前缀同时覆盖
  // in1/in1_yuv/in1_hsl/in1_mono（组内互斥保证只有一条连接）。
  final upstream = <String>{sinkNodeId};
  final queue = [sinkNodeId];
  while (queue.isNotEmpty) {
    final id = queue.removeLast();
    final node = graph.nodes[id]!;
    final muxSel = node.typeId == 'mux4'
        ? (node.paramValues['select'] as num?)?.toInt() ?? 1
        : 0;
    for (final c in graph.connections) {
      if (c.toNodeId != id) continue;
      if (muxSel > 0 && !c.toPort.startsWith('in$muxSel')) continue;
      if (upstream.add(c.fromNodeId)) queue.add(c.fromNodeId);
    }
  }
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
  // 含荧光融合/乘法器/加法器/混叠器节点的链允许 2 个源节点（双路
  // 输入），双输入评价仪器（PSNR/LPIPS 等）同样允许 2 个（参考/测试
  // 两路），多路选择器允许 4 个（源1~源4），其余链单源。
  final maxSources = chain.any((op) => op['typeId'] == 'mux4')
      ? 4
      : chain.any((op) =>
              op['typeId'] == 'fluoro_fusion' ||
              op['typeId'] == 'multiplier' ||
              op['typeId'] == 'adder' ||
              op['typeId'] == 'blender' ||
              dualInputMetricTypes.contains(op['typeId']))
          ? 2
          : 1;
  if (sources > maxSources) {
    throw StateError(
        maxSources > 1 ? '一条流水线最多 $maxSources 个源节点' : '一条流水线只能有一个源节点');
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

  void requireYuv(String opName) {
    if (format != 'yuv') throw StateError('$opName需要 YUV 输入');
  }

  void requireHsl(String opName) {
    if (format != 'hsl') throw StateError('$opName需要 HSL 输入');
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

/// RAW 源解码结果（GPU 链执行器复用的公共形式，语义同内部 _Frame）。
typedef RawSourceFrame = ({
  Uint16List data,
  String format, // 'mosaic' | 'mono'
  int width,
  int height,
  int maxValue,
  BayerPattern? bayerPattern,
  String cfa,
});

/// 解码 RAW 源节点的一帧（读文件 + 解包），供 GPU 链执行器复用；
/// 行为与链内源节点解码完全一致。
Future<RawSourceFrame> decodeRawSourceFrame(
    String typeId, Map<String, Object?> params, int frameIndex) async {
  final f = await _decodeRawSource(typeId, params, frameIndex);
  return (
    data: f.data,
    format: f.format,
    width: f.width,
    height: f.height,
    maxValue: f.maxValue,
    bayerPattern: f.bayerPattern,
    cfa: f.cfa ?? 'bayer',
  );
}

/// 视频格式输入组端口名（与 IspNodeType.videoInputGroupPorts 一致；
/// 本地保留一份以保持本文件无模型依赖）。
const _videoInputPorts = ['in', 'in_yuv', 'in_hsl', 'in_mono', 'in_raw'];

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

  // 分支感知取帧：每个算子按其视频组输入连接（'in'/'in_mono' 等）从
  // frames 取输入帧，第二个源节点（荧光/乘法器支路，compileChain 已
  // 校验最多 2 个源）在循环内按需解码。单源分支链（同源多分支）同样
  // 依赖此路径：线性主帧携带的是拓扑前驱的输出，分支节点的前驱可能
  // 属于另一分支（如 源→边缘提取 与 源→分路器 并存时，分路器会错拿
  // 边缘图）。线性链中连接的上游即拓扑前驱，行为与旧线性路径一致。
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
    if (sourceTypes.contains(typeId)) {
      // 第二个源节点（荧光/乘法器支路）：仅支持 RAW 源，解码后入 frames。
      // 单源链经 chain.skip(1) 不会再到源节点（compileChain 已校验）。
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
    // 按视频组输入连接从 frames 取本算子的输入帧（分支感知，见上文）。
    final inputs = op['inputs'] as Map<String, Object?>?;
    if (inputs != null) {
      for (final port in _videoInputPorts) {
        final conn = inputs[port] as Map<String, Object?>?;
        final from = conn?['fromNodeId'] as String?;
        if (from == null) continue;
        final upstream = frames[from];
        if (upstream == null) continue;
        // 单通道端口（分路器 out_y / edge_extract out_mono 等）：端口数据
        // 长度 = w*h 且不是上游主帧的别名时，构造 mono 帧作为本算子输入，
        // 而不是把上游的多通道整帧塞进来（否则 in_mono 接入分路器 Y 时
        // 下游会拿到 YUV 整帧，格式与数据都错）。
        final pdata = portOutputs[from]?[conn!['fromPort'] as String? ?? ''];
        if (pdata != null &&
            !identical(pdata, upstream.data) &&
            pdata.length == upstream.width * upstream.height &&
            upstream.format != 'mono' &&
            upstream.format != 'mosaic') {
          frame = pdata is Uint8List
              ? _Frame(
                  data: Uint16List(0),
                  format: 'mono',
                  width: upstream.width,
                  height: upstream.height,
                  maxValue: upstream.maxValue,
                  mono8: pdata)
              : _Frame(
                  data: pdata as Uint16List,
                  format: 'mono',
                  width: upstream.width,
                  height: upstream.height,
                  maxValue: upstream.maxValue);
        } else {
          frame = upstream;
        }
        break;
      }
    }
    // Bypass（Process 类节点的直通开关）：主帧原样下传；in_mono 支路
    // 数据直通 out_mono（如 AHE 的 Y 支路），链语义保持不变。
    if (p['bypass'] == true) {
      final outs = portOutputs.putIfAbsent(nodeId, () => {});
      outs['out'] = frame.data;
      if (frame.format == 'mono') outs['out_mono'] = frame.data;
      final monoIn = getPortData(op, 'in_mono');
      if (monoIn != null) outs['out_mono'] = monoIn;
      frames[nodeId] = frame; // 直通帧也要入表，下游按连接取帧
      if (nodeTimingsUs != null) {
        nodeTimingsUs[nodeId] =
            (nodeTimingsUs[nodeId] ?? 0) + opSw!.elapsedMicroseconds;
      }
      onNodeOutput?.call(
          nodeId, frame.data, frame.format, frame.width, frame.height);
      continue;
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
      case 'gaussian_blur':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final fmt = frame.format;
        if (fmt != 'rgb' && fmt != 'yuv' && fmt != 'hsl' && fmt != 'mono') {
          throw StateError('高斯模糊需要 RGB/YUV/HSL/Mono 输入');
        }
        // YUV 平面轨道先物化为交织（兜底路径，非常规连接）；mono8 轨道
        // （视频分路的 8 位单通道）物化为 16 位单通道。
        final data = frame.yuvPlanes8 != null
            ? _interleavePlanes8(frame.yuvPlanes8!, w * h)
            : frame.mono8 != null
                ? Uint16List.fromList(frame.mono8!)
                : frame.data;
        applyGaussianBlur(data,
            width: w,
            height: h,
            channels: fmt == 'mono' ? 1 : 3,
            sigma: _double(p, 'sigma'),
            strength: _double(p, 'strength'));
        frame = _Frame(
          data: data,
          format: fmt,
          width: w,
          height: h,
          maxValue: max,
        );
        // out_mono：非 mono 输入时取输出帧的亮度通道（yuv→Y、hsl→L、
        // rgb→BT.601 亮度）登记为单通道端口（mono 输入由循环末统一
        // 登记 out=out_mono=主帧）。
        if (fmt != 'mono') {
          final mono = Uint16List(w * h);
          if (fmt == 'rgb') {
            for (var i = 0, j = 0; i < w * h; i++, j += 3) {
              mono[i] = (19595 * data[j] +
                      38470 * data[j + 1] +
                      7471 * data[j + 2] +
                      32768) >>
                  16;
            }
          } else {
            final ch = fmt == 'hsl' ? 2 : 0;
            for (var i = 0, j = ch; i < w * h; i++, j += 3) {
              mono[i] = data[j];
            }
          }
          portOutputs[nodeId] = {'out_mono': mono};
        }
      // ---- 高频边缘提取：亮度高通输出黑底白线边缘图（detail 按邻域
      // 均值归一化为相对对比度 rel，相对门限 + gain×√rel×maxValue
      // 显示压缩；RGB/YUV/HSL 三域通用，输出保持输入格式；非恒等
      // 算子，始终输出新帧）----
      case 'edge_extract':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final fmt = frame.format;
        if (fmt != 'rgb' && fmt != 'yuv' && fmt != 'hsl') {
          throw StateError('高频边缘提取需要 RGB/YUV/HSL 输入');
        }
        // YUV 平面轨道先物化为交织（兜底路径，非常规连接）。
        final data = frame.yuvPlanes8 != null
            ? _interleavePlanes8(frame.yuvPlanes8!, w * h)
            : frame.data;
        frame = _Frame(
          data: extractHighFreq(data,
              width: w,
              height: h,
              format: fmt,
              // 增益缺省按 1.0 处理（参数缺失时不至于输出纯中灰）。
              gain: (p['gain'] as num?)?.toDouble() ?? 1.0,
              threshold: (p['threshold'] as num?)?.toDouble() ?? 4.0,
              maxValue: max),
          format: fmt,
          width: w,
          height: h,
          maxValue: max,
        );
        // out_mono：单通道边缘亮度图（w*h）。RGB/YUV 的边缘值在 0 通道
        // （RGB 三通道同值），HSL 在 L（2 通道）；从交织输出提取。
        final monoEdge = Uint16List(w * h);
        final ch = fmt == 'hsl' ? 2 : 0;
        final edgeData = frame.data;
        for (var i = 0, j = ch; i < w * h; i++, j += 3) {
          monoEdge[i] = edgeData[j];
        }
        portOutputs[nodeId] = {'out_mono': monoEdge};
      // ---- 腐蚀/膨胀：方形结构元逐通道极小/极大滤波，RGB 与 Mono 双
      // 通路（in / in_mono 互斥，只能接入一路），输出保持输入格式 ----
      case 'morphology':
        final monoIn = getPortData(op, 'in_mono');
        final erode = _str(p, 'mode') != 'dilate';
        final radius = _int(p, 'radius');
        if (monoIn != null) {
          // in_mono 侧支路：处理端口数据而非主链帧，拷贝后处理避免污染
          // 旁路（同 ahe），结果登记 out_mono 供下游取用。
          final mono = Uint16List.fromList(monoIn);
          applyMorphology(mono,
              width: frame.width,
              height: frame.height,
              erode: erode,
              radius: radius);
          // in_mono 单接时主帧就是该 mono 的构造帧：必须同步更新主帧，
          // 否则循环末公用登记段（frame.format=='mono' 时
          // opOuts['out_mono']=frame.data）会用未处理数据覆盖 out_mono。
          // in 主链并存时主帧为 RGB，只登记 out_mono 即可。
          if (frame.format == 'mono') {
            frame = _Frame(
                data: mono,
                format: 'mono',
                width: frame.width,
                height: frame.height,
                maxValue: frame.maxValue);
          }
          portOutputs[nodeId] = {'out_mono': mono};
        } else if (frame.format == 'rgb') {
          applyMorphology(frame.data,
              width: frame.width,
              height: frame.height,
              channels: 3,
              erode: erode,
              radius: radius);
          portOutputs[nodeId] = {'out': frame.data};
        } else if (frame.format == 'mono') {
          applyMorphology(frame.data,
              width: frame.width,
              height: frame.height,
              erode: erode,
              radius: radius);
          portOutputs[nodeId] = {'out': frame.data, 'out_mono': frame.data};
        } else {
          throw StateError('腐蚀/膨胀需要 RGB 或 Mono 输入');
        }
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
      case 'csc_rgb2hsl':
        frame.requireRgb('RGB→HSL 转换');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: rgbToHsl(frame.data, maxValue: max),
          format: 'hsl',
          width: w,
          height: h,
          maxValue: max,
        );
      case 'csc_yuv2rgb':
        frame.requireYuv('YUV→RGB 转换');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: yuvToRgb(frame.data, maxValue: max),
          format: 'rgb',
          width: w,
          height: h,
          maxValue: max,
        );
      case 'csc_yuv2hsl':
        frame.requireYuv('YUV→HSL 转换');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: yuvToHsl(frame.data, maxValue: max),
          format: 'hsl',
          width: w,
          height: h,
          maxValue: max,
        );
      case 'csc_hsl2rgb':
        frame.requireHsl('HSL→RGB 转换');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: hslToRgb(frame.data, maxValue: max),
          format: 'rgb',
          width: w,
          height: h,
          maxValue: max,
        );
      case 'csc_hsl2yuv':
        frame.requireHsl('HSL→YUV 转换');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: hslToYuv(frame.data, maxValue: max),
          format: 'yuv',
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- HSL 调节器：HSL 域调参（恒等参数时核内直通不拷贝）----
      case 'hsl_debugger':        frame.requireHsl('HSL调节器');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: adjustHsl(frame.data,
              maxValue: max,
              hShiftDeg: _double(p, 'h_shift'),
              // 增益缺省按恒等 1.0 处理（参数缺失时不至于把通道清零）。
              sGain: (p['s_gain'] as num?)?.toDouble() ?? 1.0,
              lGain: (p['l_gain'] as num?)?.toDouble() ?? 1.0),
          format: 'hsl',
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- RGB 调节器：RGB 域通道增益（恒等参数时核内直通不拷贝）----
      case 'rgb_debugger':
        frame.requireRgb('RGB调节器');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: adjustRgb(frame.data,
              maxValue: max,
              // 增益缺省按恒等 1.0 处理（参数缺失时不至于把通道清零）。
              rGain: (p['r_gain'] as num?)?.toDouble() ?? 1.0,
              gGain: (p['g_gain'] as num?)?.toDouble() ?? 1.0,
              bGain: (p['b_gain'] as num?)?.toDouble() ?? 1.0),
          format: 'rgb',
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- YUV 调节器：YUV 域调参（恒等参数时核内直通不拷贝）----
      case 'yuv_debugger':
        frame.requireYuv('YUV调节器');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        frame = _Frame(
          data: adjustYuv(frame.data,
              maxValue: max,
              // 增益缺省按恒等 1.0 处理（参数缺失时不至于把通道清零）。
              yGain: (p['y_gain'] as num?)?.toDouble() ?? 1.0,
              uGain: (p['u_gain'] as num?)?.toDouble() ?? 1.0,
              vGain: (p['v_gain'] as num?)?.toDouble() ?? 1.0),
          format: 'yuv',
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- 色饱和度/亮度调节器：RGB/YUV/HSL 三域通用调参，输出保持输入
      // 格式（恒等参数时核内直通不拷贝）----
      case 'sat_bright_adjuster':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final fmt = frame.format;
        if (fmt != 'rgb' && fmt != 'yuv' && fmt != 'hsl') {
          throw StateError('色饱和度/亮度调节器需要 RGB/YUV/HSL 输入');
        }
        // YUV 平面轨道先物化为交织（兜底路径，非常规连接）。
        final data = frame.yuvPlanes8 != null
            ? _interleavePlanes8(frame.yuvPlanes8!, w * h)
            : frame.data;
        frame = _Frame(
          data: adjustSatBright(data,
              format: fmt,
              maxValue: max,
              // 增益缺省按恒等 1.0 处理（参数缺失时不至于把通道清零）。
              satGain: (p['sat_gain'] as num?)?.toDouble() ?? 1.0,
              brightGain: (p['bright_gain'] as num?)?.toDouble() ?? 1.0),
          format: fmt,
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- 亮度/对比度调节器：RGB/YUV/HSL/Mono 四域亮度/对比度调参，输出
      // 保持输入格式（bright=100 且 gain=100 时核内直通不拷贝）----
      case 'bright_contrast_adjuster':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final fmt = frame.format;
        if (fmt != 'rgb' && fmt != 'yuv' && fmt != 'hsl' && fmt != 'mono') {
          throw StateError('亮度/对比度调节器需要 RGB/YUV/HSL/Mono 输入');
        }
        // YUV 平面轨道先物化为交织（兜底路径，非常规连接）；mono8 轨道
        // （视频分路的 8 位单通道）物化为 16 位单通道。
        final data = frame.yuvPlanes8 != null
            ? _interleavePlanes8(frame.yuvPlanes8!, w * h)
            : frame.mono8 != null
                ? Uint16List.fromList(frame.mono8!)
                : frame.data;
        frame = _Frame(
          data: adjustBrightContrast(data,
              format: fmt,
              maxValue: max,
              // 缺省按恒等（100/50/100）处理。
              brightPct: (p['bright'] as num?)?.toDouble() ?? 100.0,
              baselinePct: (p['baseline'] as num?)?.toDouble() ?? 50.0,
              gainPct: (p['gain'] as num?)?.toDouble() ?? 100.0),
          format: fmt,
          width: w,
          height: h,
          maxValue: max,
        );
        // out_mono：非 mono 输入时取输出帧的亮度通道（yuv→Y、hsl→L、
        // rgb→BT.601 亮度）登记为单通道端口，供蒙版等 mono 侧端口消费
        // （mono 输入由循环末统一登记 out=out_mono=主帧）。
        if (fmt != 'mono') {
          final data = frame.data;
          final mono = Uint16List(w * h);
          if (fmt == 'rgb') {
            for (var i = 0, j = 0; i < w * h; i++, j += 3) {
              mono[i] = (19595 * data[j] +
                      38470 * data[j + 1] +
                      7471 * data[j + 2] +
                      32768) >>
                  16;
            }
          } else {
            final ch = fmt == 'hsl' ? 2 : 0;
            for (var i = 0, j = ch; i < w * h; i++, j += 3) {
              mono[i] = data[j];
            }
          }
          portOutputs[nodeId] = {'out_mono': mono};
        }
      // ---- 曲线调节器：RGB 域传递函数（曲线控制点参数 points，0..4095
      // 域；curveMode 选择生成公式：spline 单调三次样条 / bezier 贝塞尔
      // / linear 线段 / gamma（y=max·(x/max)^(1/γ)，取 gamma 参数）；
      // 恒等曲线时直通不拷贝）----
      case 'levels_curves':
        frame.requireRgb('曲线调节器');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final points = levelsPointsFromParam(p['points']);
        final mode = levelsCurveModeFromParam(p['curveMode']);
        final gamma = (p['gamma'] as num?)?.toDouble() ?? 1.0;
        // gamma 模式以 γ==1 为恒等；其余模式以控制点是否全在对角线上判定。
        final identity = mode == LevelsCurveMode.gamma
            ? gamma == 1.0
            : levelsCurveIsIdentity(points);
        frame = _Frame(
          data: identity
              ? frame.data
              : applyLevelsCurve(
                  frame.data, levelsCurveLut(points, mode: mode, gamma: gamma),
                  maxValue: max),
          format: 'rgb',
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- 色彩平衡：RGB/YUV/HSL 三域中间调加性偏移，输出保持输入格式
      // （cyan_red/magenta_green/yellow_blue 三滑杆，全 0 直通不拷贝）----
      case 'color_balance':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final fmt = frame.format;
        if (fmt != 'rgb' && fmt != 'yuv' && fmt != 'hsl') {
          throw StateError('色彩平衡需要 RGB/YUV/HSL 输入');
        }
        // YUV 平面轨道先物化为交织（兜底路径，非常规连接）。
        final data = frame.yuvPlanes8 != null
            ? _interleavePlanes8(frame.yuvPlanes8!, w * h)
            : frame.data;
        frame = _Frame(
          data: applyColorBalance(data,
              format: fmt,
              maxValue: max,
              cyanRed: _double(p, 'cyan_red'),
              magentaGreen: _double(p, 'magenta_green'),
              yellowBlue: _double(p, 'yellow_blue')),
          format: fmt,
          width: w,
          height: h,
          maxValue: max,
        );
      // ---- 色温调节器：RGB 域 von Kries 对角增益（目标色温 temperature
      // 相对参考色温 measured_cct —— 隐式参数，点击节点上的测量值按钮
      // 时写入（applyMeasuredColorTemp），缺省/未设定按 6500K；增益全 1
      // 时 adjustRgb 直通不拷贝）----
      case 'color_temp_adjuster':
        frame.requireRgb('色温调节器');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final gains = colorTempGains(
            (p['temperature'] as num?)?.toDouble() ?? kColorTempDefault,
            _int(p, 'measured_cct'));
        frame = _Frame(
          data: adjustRgb(frame.data,
              maxValue: max,
              rGain: gains[0],
              gGain: gains[1],
              bGain: gains[2]),
          format: 'rgb',
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
      // ---- 乘法器：（输入源1+offset1）×（输入源2+offset2）逐像素
      // 归一化相乘（out = (a+offset1)×(b+offset2)/maxValue），输出
      // Mono；两路输入分辨率必须一致 ----
      case 'multiplier':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        // 两路输入都按端口取数（与合路器同）：单源链的线性主帧不跟踪
        // in_mono 支路（支路末端可能是其他格式，如分路器的 YUV 帧），
        // 不能对主帧 requireMono。in_mono 未连接时才回退线性帧。
        var d1 = getPortData(op, 'in_mono');
        if (d1 == null) {
          frame.requireMono('乘法器');
          d1 = frame.data;
        }
        final d2 = getPortData(op, 'in_mono2');
        if (d2 == null) {
          throw StateError('乘法器需要接入输入源2（in_mono2 端口）');
        }
        // 分辨率一致性校验：多源链可取上游帧的精确宽高，否则按数据
        // 长度兜底（同 fluoro_fusion 的尺寸约定）。
        final conn2 = (op['inputs'] as Map<String, Object?>?)?['in_mono2']
            as Map<String, Object?>?;
        final up2 = conn2 == null
            ? null
            : frames[conn2['fromNodeId'] as String? ?? ''];
        final sameResolution = up2 != null
            ? up2.width == w && up2.height == h
            : d1.length == w * h && d2.length == w * h;
        if (!sameResolution) {
          throw StateError(up2 != null
              ? '乘法器两路输入分辨率必须一致（源1: $w×$h，源2: ${up2.width}×${up2.height}）'
              : '乘法器两路输入分辨率必须一致（源1: $w×$h）');
        }
        frame = _Frame(
            data: multiplyMono(d1, d2,
                offset1: _double(p, 'offset1'),
                offset2: _double(p, 'offset2'),
                maxValue: max),
            format: 'mono',
            width: w,
            height: h,
            maxValue: max);
      // ---- 加法器：源1×balance + 源2×(1−balance) 平衡加权混合，两路
      // mono 逐像素相加（增益总和恒为 1）；取数/校验口径同乘法器 ----
      case 'adder':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        // 两路输入都按端口取数（与乘法器同）：in_mono 未连接时回退线性帧。
        var d1 = getPortData(op, 'in_mono');
        if (d1 == null) {
          frame.requireMono('加法器');
          d1 = frame.data;
        }
        final d2 = getPortData(op, 'in_mono2');
        if (d2 == null) {
          throw StateError('加法器需要接入输入源2（in_mono2 端口）');
        }
        final conn2 = (op['inputs'] as Map<String, Object?>?)?['in_mono2']
            as Map<String, Object?>?;
        final up2 = conn2 == null
            ? null
            : frames[conn2['fromNodeId'] as String? ?? ''];
        final sameResolution = up2 != null
            ? up2.width == w && up2.height == h
            : d1.length == w * h && d2.length == w * h;
        if (!sameResolution) {
          throw StateError(up2 != null
              ? '加法器两路输入分辨率必须一致（源1: $w×$h，源2: ${up2.width}×${up2.height}）'
              : '加法器两路输入分辨率必须一致（源1: $w×$h）');
        }
        frame = _Frame(
            data: blendMono(d1, d2,
                // 缺省按平衡中点 0.5（参数缺失时不至于把源2 清零）。
                balance: (p['balance'] as num?)?.toDouble() ?? 0.5,
                maxValue: max),
            format: 'mono',
            width: w,
            height: h,
            maxValue: max);
      // ---- 混叠器：基图 + 混叠图×蒙版/maxValue×混叠强度（正常模式），
      // 输出保持基图格式（RGB/YUV/HSL/Mono）；混叠图/蒙版按侧向端口
      // 取数（同乘法器 in_mono2 口径），分辨率必须与基图一致 ----
      case 'blender':
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final fmt = frame.format;
        if (fmt != 'rgb' && fmt != 'yuv' && fmt != 'hsl' && fmt != 'mono') {
          throw StateError('混叠器需要 RGB/YUV/HSL/Mono 基图输入');
        }
        // YUV 平面轨道先物化为交织（兜底路径，非常规连接）；mono8 轨道
        // 物化为 16 位单通道（同 bright_contrast_adjuster）。
        final baseData = frame.yuvPlanes8 != null
            ? _interleavePlanes8(frame.yuvPlanes8!, w * h)
            : frame.mono8 != null
                ? Uint16List.fromList(frame.mono8!)
                : frame.data;
        final mask = getPortData(op, 'in_mask');
        if (mask == null) {
          throw StateError('混叠器需要接入蒙版（in_mask 端口）');
        }
        // 混叠图四域端口（in_blend/in_blend_yuv/in_blend_hsl/in_blend_mono）
        // 选一接入；通道数按数据长度判定（w*h*3 → 三通道，w*h → mono），
        // 兼容旧流程文件 in_blend 直接接 mono 的连法。
        List<int>? blend;
        for (final bp in const [
          'in_blend', 'in_blend_yuv', 'in_blend_hsl', 'in_blend_mono']) {
          blend = getPortData(op, bp);
          if (blend != null) break;
        }
        if (blend == null) {
          throw StateError('混叠器需要接入混叠图（in_blend 端口）');
        }
        final blendChannels = blend.length == w * h * 3
            ? 3
            : blend.length == w * h
                ? 1
                : 0;
        if (mask.length != w * h || blendChannels == 0) {
          throw StateError('混叠器蒙版/混叠图分辨率必须与基图一致');
        }
        frame = _Frame(
            data: blendMaskMono(baseData, blend, mask,
                format: fmt,
                blendChannels: blendChannels,
                // 缺省按全强度 1.0（参数缺失时不至于没有混叠效果）。
                strength: (p['strength'] as num?)?.toDouble() ?? 1.0,
                maxValue: max),
            format: fmt,
            width: w,
            height: h,
            maxValue: max);
      // ---- 多路选择器（4选1）：把 select 选中的那路源输入透传到输出
      // （不改数据，输出格式 = 所选输入格式；端口数据与上游主帧不同
      // 时按单通道端口构造 mono 帧，与取帧逻辑同口径）----
      case 'mux4':
        final sel = ((p['select'] as num?)?.toInt() ?? 1).clamp(1, 4);
        final base = 'in$sel';
        Map<String, Object?>? conn;
        for (final suffix in const ['', '_yuv', '_hsl', '_mono']) {
          final c = (op['inputs'] as Map<String, Object?>?)?['$base$suffix']
              as Map<String, Object?>?;
          if (c != null) {
            conn = c;
            break;
          }
        }
        if (conn == null) {
          throw StateError('多路选择器的源$sel 未接入输入');
        }
        final from = conn['fromNodeId'] as String? ?? '';
        final upstream = frames[from];
        if (upstream == null) {
          throw StateError('多路选择器的源$sel 上游帧缺失');
        }
        final pdata = portOutputs[from]?[conn['fromPort'] as String? ?? ''];
        if (pdata != null &&
            !identical(pdata, upstream.data) &&
            pdata.length == upstream.width * upstream.height &&
            upstream.format != 'mono' &&
            upstream.format != 'mosaic') {
          // 单通道端口（分路器 out_y 等）：构造 mono 帧透传。
          frame = pdata is Uint8List
              ? _Frame(
                  data: Uint16List(0),
                  format: 'mono',
                  width: upstream.width,
                  height: upstream.height,
                  maxValue: upstream.maxValue,
                  mono8: pdata)
              : _Frame(
                  data: pdata as Uint16List,
                  format: 'mono',
                  width: upstream.width,
                  height: upstream.height,
                  maxValue: upstream.maxValue);
        } else {
          frame = upstream;
        }
      case 'demosaic':
        frame.requireMosaic('去马赛克');
        final w = frame.width;
        final h = frame.height;
        final max = frame.maxValue;
        final data = frame.data;
        frame = _Frame(
          data: switch (frame.cfa) {
            'bayer' => switch (_str(p, 'algorithm')) {
                // 空（默认）/ bilinear：双线性。
                '' || 'bilinear' => demosaicBilinear(data,
                    width: w, height: h, pattern: frame.bayerPattern!),
                'mhc' => demosaicMhc(data,
                    width: w,
                    height: h,
                    pattern: frame.bayerPattern!,
                    maxValue: max),
                'aahd' => demosaicAahd(data,
                    width: w,
                    height: h,
                    pattern: frame.bayerPattern!,
                    maxValue: max),
                'amaze' => demosaicAmaze(data,
                    width: w,
                    height: h,
                    pattern: frame.bayerPattern!,
                    maxValue: max),
                'lmmse' => demosaicLmmse(data,
                    width: w,
                    height: h,
                    pattern: frame.bayerPattern!,
                    maxValue: max),
                'igv' => demosaicIgv(data,
                    width: w,
                    height: h,
                    pattern: frame.bayerPattern!,
                    maxValue: max),
                _ => throw StateError('未知去马赛克算法: ${_str(p, 'algorithm')}'),
              },
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
      case 'ahe':
        // RGB 与 Mono 双通路（in / in_mono 互斥，只能接入一路）。
        final monoIn = getPortData(op, 'in_mono');
        if (monoIn != null) {
          // in_mono 侧支路（如 YUV 分路器的 Y 通道接入）：处理的是端口
          // 数据而非主链帧，结果登记 out_mono 供下游（合路器/仪器）
          // 取用，主链帧原样透传。必须拷贝后处理：上游端口数据可能被
          // 其它节点共享（如分路器 out_y 同时接直方图），原地修改会
          // 污染旁路。
          final mono = Uint16List.fromList(monoIn);
          applyClaheMono(mono,
              width: frame.width,
              height: frame.height,
              blockSize: _int(p, 'blockSize'),
              clipLimit: _double(p, 'clipLimit'),
              strength: _double(p, 'strength'),
              maxValue: frame.maxValue);
          // in_mono 单接时主帧就是该 mono 的构造帧：必须同步更新主帧，
          // 否则循环末公用登记段（frame.format=='mono' 时
          // opOuts['out_mono']=frame.data）会用未处理数据覆盖 out_mono。
          // in 主链并存时主帧为 RGB，只登记 out_mono 即可。
          if (frame.format == 'mono') {
            frame = _Frame(
                data: mono,
                format: 'mono',
                width: frame.width,
                height: frame.height,
                maxValue: frame.maxValue);
          }
          portOutputs[nodeId] = {'out_mono': mono};
        } else if (frame.format == 'rgb') {
          applyClahe(frame.data,
              width: frame.width,
              height: frame.height,
              blockSize: _int(p, 'blockSize'),
              clipLimit: _double(p, 'clipLimit'),
              strength: _double(p, 'strength'),
              maxValue: frame.maxValue);
          portOutputs[nodeId] = {'out': frame.data};
        } else if (frame.format == 'mono') {
          applyClaheMono(frame.data,
              width: frame.width,
              height: frame.height,
              blockSize: _int(p, 'blockSize'),
              clipLimit: _double(p, 'clipLimit'),
              strength: _double(p, 'strength'),
              maxValue: frame.maxValue);
          portOutputs[nodeId] = {'out': frame.data, 'out_mono': frame.data};
        } else {
          throw StateError('自适应直方图均衡需要 RGB 或 Mono 输入');
        }
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
      case 'psnr':
      case 'ssim':
      case 'msssim':
      case 'fsim':
      case 'niqe':
      case 'brisque':
      case 'ilniqe':
      case 'piqe':
      case 'lpips':
      case 'dists':
      case 'fid':
      case 'kid':
      case 'musiq':
      case 'clipiqa':
      case 'minmax':
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
    frames[nodeId] = frame; // 分支感知取帧：每个节点输出都入表
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
        // RAW 马赛克直显（预览节点 in_raw 接入）：不做去马赛克，每个像素
        // 的值直接作为亮度出灰度图（棋盘格原样可见）。
        'mosaic' => monoToRgba(frame.data,
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
          // RAW 马赛克直显：像素值即亮度。
          'mosaic' => monoToRgba(f0.data,
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
/// 启动参数 `[SendPort, chain, frameIndex, sourceRgba?, sourceWidth?,
/// sourceHeight?]`；每个节点开始执行前回
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
        sourceRgba: args.length > 3 ? args[3] as Uint8List? : null,
        sourceWidth: args.length > 4 ? args[4] as int? : null,
        sourceHeight: args.length > 5 ? args[5] as int? : null,
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
/// [sourceRgba]/[sourceWidth]/[sourceHeight] 非空时注入预解码的
/// RGBA8888 源帧（同 [runChainFrame] 的对应参数），跳过源节点解码——
/// 供「一次解码、多链共享」的调用方使用。
Future<Map<String, Object?>> runChainFrameWithProgress(
  List<Map<String, Object?>> chain,
  int frameIndex, {
  void Function(String nodeId, int index, int total)? onNodeStart,
  Uint8List? sourceRgba,
  int? sourceWidth,
  int? sourceHeight,
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
  final isolate = await Isolate.spawn(_chainFrameProgressWorker,
      [port.sendPort, chain, frameIndex, sourceRgba, sourceWidth, sourceHeight]);
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
    case 'minmax':
      final (mn, mx) = minmaxMono(rgba);
      return {'kind': kind, 'min': mn, 'max': mx};
    case 'niqe':
      return {'kind': kind, 'niqe': niqeScore(rgba, w, h)};
    case 'brisque':
      return {'kind': kind, 'brisque': brisqueScore(rgba, w, h)};
    case 'piqe':
      return {'kind': kind, 'piqe': piqeScore(rgba, w, h)};
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
