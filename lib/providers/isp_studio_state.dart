import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:path/path.dart' as p;

import '../modules/isp_studio/models/isp_graph.dart';
import '../modules/isp_studio/models/isp_node.dart';
import '../modules/isp_studio/pipeline/audio_player.dart';
import '../modules/isp_studio/pipeline/exporters.dart';
import '../modules/isp_studio/pipeline/instrument_worker.dart';
import '../modules/isp_studio/pipeline/instruments.dart';
import '../modules/isp_studio/pipeline/pipeline_runner.dart';
import '../modules/isp_studio/pipeline/pipeline_worker.dart';
import '../modules/isp_studio/pipeline/raw_sidecar.dart';
import '../modules/isp_studio/pipeline/video_source.dart';
import '../modules/isp_studio/widgets/node_layout.dart';

/// ISP Studio 模块状态：节点图、画布变换、执行与导出编排。
class IspStudioState extends ChangeNotifier {
  IspStudioState() : graph = defaultGraph();

  final IspGraph graph;

  /// 流程图工程名；null 或空表示默认流程图（标签页显示「缺省流程」）。
  String? graphName;

  /// 流程图标签页标题。
  String get graphTabTitle =>
      (graphName?.isNotEmpty ?? false) ? graphName! : '缺省流程';

  // ---- 编辑器标签页 ----

  /// 已打开代码标签页的节点 id（按打开顺序）。
  final List<String> openCodeTabs = [];

  /// 当前活动标签：0 = 流程图，i >= 1 对应 openCodeTabs[i - 1]。
  int activeTab = 0;

  /// 打开（或激活）某节点的代码标签页。
  void openCodeTab(String nodeId) {
    if (!graph.nodes.containsKey(nodeId)) return;
    final i = openCodeTabs.indexOf(nodeId);
    if (i >= 0) {
      activeTab = i + 1;
    } else {
      openCodeTabs.add(nodeId);
      activeTab = openCodeTabs.length;
    }
    notifyListeners();
  }

  /// 关闭某节点的代码标签页，活动标签落到相邻标签上。
  void closeCodeTab(String nodeId) {
    final i = openCodeTabs.indexOf(nodeId);
    if (i < 0) return;
    openCodeTabs.removeAt(i);
    if (activeTab > openCodeTabs.length) {
      activeTab = openCodeTabs.length;
    } else if (activeTab > i) {
      activeTab--;
    }
    notifyListeners();
  }

  /// 切换活动标签（0 = 流程图）。
  void setActiveTab(int index) {
    final clamped = index.clamp(0, openCodeTabs.length);
    if (clamped == activeTab) return;
    activeTab = clamped;
    notifyListeners();
  }

  // ---- 画布 ----
  Offset canvasOffset = Offset.zero;
  double canvasZoom = 1.0;
  String? selectedNodeId;
  String? selectedConnectionId;

  // ---- 连线拖拽暂态 ----
  String? dragFromNodeId;
  String? dragFromPort;
  Offset dragCurrentPos = Offset.zero;

  // ---- 执行状态 ----
  bool isProcessing = false;
  double progress = 0;
  String statusMessage = '';
  final List<String> errors = [];

  // ---- 预览 ----
  ui.Image? previewImage;
  int previewFrame = 0;
  int previewWidth = 0;
  int previewHeight = 0;
  int? totalFrames;

  /// 最近一次预览运行时采样到的各节点输出
  /// （nodeId → `{'format': String, 'length': int, 'sample': List<int>}`），
  /// 供代码标签页的变量表显示运行值；图被修改后清空。
  Map<String, Map<String, Object?>> nodeOutputCaptures = {};

  /// 仪器节点最近一次分析结果（nodeId → analyzeInstrumentInIsolate 的
  /// 返回 map），随预览运行刷新；直方图数据由节点控件直接绘制。
  Map<String, Map<String, Object?>> instrumentResults = {};

  /// 波形/矢量示波器节点的显示图像（nodeId → 计数表映射的亮度图）。
  final Map<String, ui.Image> instrumentImages = {};

  /// 直方图节点的通道可见性（nodeId → 可见通道，缺省全部）。
  final Map<String, Set<String>> _histogramChannels = {};

  /// 直方图节点当前可见的通道集合（'r'/'g'/'b'）。
  Set<String> histogramChannels(String nodeId) =>
      _histogramChannels[nodeId] ??= {'r', 'g', 'b'};

  /// 切换直方图节点某通道的显示。
  void toggleHistogramChannel(String nodeId, String channel) {
    final set = histogramChannels(nodeId);
    if (!set.remove(channel)) set.add(channel);
    notifyListeners();
  }

  // ---- 预览节点屏幕尺寸（附加区高度，画布坐标）----
  static const double kDefaultPreviewExtraHeight = 160;
  static const double kMinPreviewExtraHeight = 100;
  static const double kMaxPreviewExtraHeight = 800;
  static const double kMinPreviewNodeWidth = 140;
  static const double kMaxPreviewNodeWidth = 800;
  final Map<String, double> _previewExtraHeights = {};

  int _runToken = 0;

  // ---- 画布操作 ----

  void panBy(Offset delta) {
    canvasOffset += delta;
    notifyListeners();
  }

  /// 以 [focal]（画布局部坐标）为中心缩放。
  void zoomAt(Offset focal, double scale) {
    final newZoom = (canvasZoom * scale).clamp(0.25, 2.0);
    if (newZoom == canvasZoom) return;
    canvasOffset = focal - (focal - canvasOffset) * (newZoom / canvasZoom);
    canvasZoom = newZoom;
    notifyListeners();
  }

  void resetView() {
    canvasOffset = Offset.zero;
    canvasZoom = 1.0;
    notifyListeners();
  }

  // ---- 节点操作 ----

  void addNodeAt(String typeId, Offset canvasPos) {
    final id = graph.addNode(typeId, canvasPos.dx, canvasPos.dy);
    selectedNodeId = id;
    notifyListeners();
  }

  void removeNode(String id) {
    graph.removeNode(id);
    closeCodeTab(id);
    nodeOutputCaptures = {}; // 运行值已过期
    instrumentResults.remove(id);
    instrumentImages.remove(id)?.dispose();
    _histogramChannels.remove(id);
    if (selectedNodeId == id) selectedNodeId = null;
    if (maximizedNodeId == id) maximizedNodeId = null;
    _maximizeBackup.remove(id);
    _clearStaleConnectionSelection();
    notifyListeners();
  }

  void removeSelected() {
    final connId = selectedConnectionId;
    if (connId != null) {
      removeConnection(connId);
      return;
    }
    final id = selectedNodeId;
    if (id != null) removeNode(id);
  }

  void selectNode(String? id) {
    if (selectedNodeId != id) {
      selectedNodeId = id;
      if (id != null) selectedConnectionId = null;
      notifyListeners();
    }
  }

  void selectConnection(String? id) {
    if (selectedConnectionId != id) {
      selectedConnectionId = id;
      if (id != null) selectedNodeId = null;
      notifyListeners();
    }
  }

  /// 选中连接被级联删除（如删节点）时清掉选中态。
  void _clearStaleConnectionSelection() {
    final id = selectedConnectionId;
    if (id != null && !graph.connections.any((c) => c.id == id)) {
      selectedConnectionId = null;
    }
  }

  void moveNode(String id, Offset delta) {
    final node = graph.nodes[id];
    if (node == null) return;
    node.x += delta.dx;
    node.y += delta.dy;
    notifyListeners();
  }

  void setParam(String nodeId, String key, Object? value) {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    node.paramValues[key] = value;
    totalFrames = null; // 源参数可能变了
    nodeOutputCaptures = {}; // 运行值已过期
    notifyListeners();
    // RAW 源设置了文件路径：尝试从同名 txt 自动填充尺寸与黑电平。
    if (key == 'filePath' &&
        rawSourceTypes.contains(node.typeId) &&
        value is String &&
        value.isNotEmpty) {
      autoFillFromSidecar(nodeId); // 异步，失败静默
    }
    // 视频源设置了文件路径：用 ffmpeg 解析帧率/总帧数，自动填充下游
    // 预览节点的播放帧率与预览帧数。
    if (key == 'filePath' &&
        node.typeId == 'video_source' &&
        value is String &&
        value.isNotEmpty) {
      autoFillFromVideo(nodeId); // 异步，失败静默
    }
  }

  /// 视频源文件路径对应的帧率/总帧数（ffmpeg 解析）自动填充到下游
  /// 预览节点的「播放帧率」与「预览帧数」参数。失败静默。
  Future<void> autoFillFromVideo(String sourceId) async {
    final node = graph.nodes[sourceId];
    if (node == null || node.typeId != 'video_source') return;
    final path = node.paramValues['filePath']?.toString() ?? '';
    if (path.isEmpty) return;
    try {
      final info = await videoFileInfo(path,
          ffmpegPath: node.paramValues['ffmpegPath']?.toString() ?? '');
      final fps = info.fps.round().clamp(1, 60);
      var changed = false;
      for (final n in graph.nodes.values) {
        if (n.typeId != 'preview') continue;
        // 只填位于该源下游的预览节点。
        if (!graph.upstreamOf(n.id).contains(sourceId)) continue;
        n.paramValues['fps'] = fps;
        n.paramValues['frameCount'] = info.frameCount;
        changed = true;
      }
      if (changed) {
        totalFrames = null; // 预览帧数变了，下次运行重算
        notifyListeners();
      }
    } catch (_) {
      // ffmpeg 不可用或解析失败：静默，保持参数原值。
    }
  }

  /// 读取 RAW 源节点文件路径对应的同名 .txt（`[common]` 节）：
  /// 有 Width/Height 则更新源节点的宽/高参数；有 BlackLevel_*（16 倍
  /// 刻度 ÷ 16）则填入该源下游的所有黑电平校正节点。
  /// txt 缺失或字段不全时对应部分不做任何事。
  Future<void> autoFillFromSidecar(String sourceId) async {
    final node = graph.nodes[sourceId];
    final rawPath = node?.paramValues['filePath']?.toString() ?? '';
    if (rawPath.isEmpty) return;
    final common = await readRawSidecarCommon(rawPath);
    if (common == null) return;
    var changed = false;

    // 尺寸信息 → 源节点参数。
    final w = int.tryParse(common['Width'] ?? '');
    final h = int.tryParse(common['Height'] ?? '');
    if (node != null && w != null && w > 0 && h != null && h > 0) {
      if (node.paramValues['width'] != w ||
          node.paramValues['height'] != h) {
        node.paramValues['width'] = w;
        node.paramValues['height'] = h;
        totalFrames = null; // 单帧字节数变了
        changed = true;
      }
    }

    // 黑电平 → 下游黑电平校正节点。
    final levels = await readRawSidecarBlackLevels(rawPath);
    if (levels != null) {
      for (final e in graph.nodes.entries) {
        if (e.value.typeId != 'black_level') continue;
        if (!graph.upstreamOf(e.key).contains(sourceId)) continue;
        e.value.paramValues['r'] = levels.$1;
        e.value.paramValues['gr'] = levels.$2;
        e.value.paramValues['gb'] = levels.$3;
        e.value.paramValues['b'] = levels.$4;
        changed = true;
      }
    }
    if (changed) {
      nodeOutputCaptures = {}; // 运行值已过期
      statusMessage =
          '已从 ${p.basename(p.setExtension(rawPath, '.txt'))} 读取参数'
          '${w != null && h != null ? '（${w}x$h）' : ''}';
      notifyListeners();
    }
  }

  // ---- 连线 ----

  void beginConnectionDrag(String nodeId, String port, Offset pos) {
    dragFromNodeId = nodeId;
    dragFromPort = port;
    dragCurrentPos = pos;
    notifyListeners();
  }

  void updateConnectionDrag(Offset pos) {
    dragCurrentPos = pos;
    notifyListeners();
  }

  /// 结束拖拽；[toNodeId]/[toPort] 为落点输入端口，null 表示取消。
  /// 返回错误消息（null = 成功/取消）。
  String? endConnectionDrag(String? toNodeId, String? toPort) {
    final fromId = dragFromNodeId;
    final fromPort = dragFromPort;
    dragFromNodeId = null;
    dragFromPort = null;
    notifyListeners();
    if (fromId == null || fromPort == null || toNodeId == null || toPort == null) {
      return null;
    }
    final error = graph.connect(fromId, fromPort, toNodeId, toPort);
    if (error == null) nodeOutputCaptures = {}; // 连接变了，运行值已过期
    notifyListeners();
    return error;
  }

  void disconnectInput(String nodeId, String port) {
    graph.disconnectInput(nodeId, port);
    nodeOutputCaptures = {};
    _clearStaleConnectionSelection();
    notifyListeners();
  }

  /// 按连接 id 断开（连线中点控制点、Delete 键走这里）。
  void removeConnection(String connectionId) {
    graph.disconnect(connectionId);
    nodeOutputCaptures = {};
    if (selectedConnectionId == connectionId) selectedConnectionId = null;
    notifyListeners();
  }

  // ---- 执行 ----

  IspNode? get _firstPreviewNode {
    for (final node in graph.nodes.values) {
      if (node.typeId == 'preview') return node;
    }
    return null;
  }

  List<Map<String, Object?>> _compileTo(String sinkNodeId) {
    errors
      ..clear()
      ..addAll(graph.validate());
    final chain = compileChain(graph, sinkNodeId); // 可能抛 StateError
    return chain;
  }

  /// 预览可用帧数：源文件实际帧数与预览节点「预览帧数」参数取小
  /// （参数 <= 0 视为不限制）。
  Future<int> _previewFrameCount(IspNode preview, String srcTypeId,
      Map<String, Object?> srcParams) async {
    final total = await sourceFrameCount(srcTypeId, srcParams);
    final limit = (preview.paramValues['frameCount'] as num?)?.toInt() ?? 0;
    return limit > 0 && limit < total ? limit : total;
  }

  /// 运行到第一个预览节点并更新预览图。
  Future<void> runPreview() async {
    if (isProcessing) return;
    final preview = _firstPreviewNode;
    if (preview == null) {
      statusMessage = '图中没有预览节点';
      notifyListeners();
      return;
    }
    isProcessing = true;
    progress = 0;
    statusMessage = '正在处理…';
    notifyListeners();
    final token = ++_runToken;
    try {
      final chain = _compileTo(preview.id);
      final srcTypeId = chain.first['typeId'] as String;
      final srcParams = chain.first['params'] as Map<String, Object?>;
      totalFrames = await _previewFrameCount(preview, srcTypeId, srcParams);
      final frame = previewFrame.clamp(0, totalFrames! - 1);
      previewFrame = frame;
      final result = await compute(
          runChainFrameCapturedInIsolate, {'chain': chain, 'frameIndex': frame});
      if (token != _runToken) return; // 已被更新的运行取代
      final rgba = result['rgba'] as Uint8List;
      nodeOutputCaptures =
          (result['captures'] as Map).cast<String, Map<String, Object?>>();
      final (w, h) = await sourceDimensions(srcTypeId, srcParams);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
          rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
      final image = await completer.future;
      if (token != _runToken) return;
      previewImage?.dispose();
      previewImage = image;
      previewWidth = w;
      previewHeight = h;
      statusMessage =
          '预览就绪 第 ${frame + 1}/$totalFrames 帧  ${w}x$h';
      progress = 1;
      // 仪器节点随预览刷新（并行分析，单个失败不影响预览）。
      await _runInstruments(frame, token);
    } catch (e) {
      statusMessage = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (token == _runToken) {
        isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// 对所有已连接输入的仪器节点并行执行分析（编译到该节点为止的链）。
  Future<void> _runInstruments(int frame, int token) async {
    final connected = <IspNode>[];
    for (final node in graph.nodes.values) {
      if (!instrumentTypes.contains(node.typeId)) continue;
      final type = IspNodeRegistry.byId(node.typeId)!;
      final hasInput =
          type.inputs.any((p) => graph.connectionAt(node.id, p.name) != null);
      if (hasInput) {
        connected.add(node);
      } else {
        instrumentResults.remove(node.id);
        instrumentImages.remove(node.id)?.dispose();
      }
    }
    // 清理已不在图中的节点残留。
    for (final id in instrumentResults.keys.toList()) {
      if (!graph.nodes.containsKey(id)) {
        instrumentResults.remove(id);
        instrumentImages.remove(id)?.dispose();
      }
    }
    if (connected.isEmpty) return;
    await Future.wait([
      for (final node in connected)
        () async {
          try {
            final chain = compileChain(graph, node.id);
            final result = await compute(analyzeInstrumentInIsolate,
                {'chain': chain, 'frameIndex': frame, 'kind': node.typeId});
            if (token != _runToken) return;
            instrumentResults[node.id] = result;
            await _updateInstrumentImage(node.id, result);
          } catch (_) {
            // 链不完整等失败：保留旧结果，不影响预览。
          }
        }(),
    ]);
    if (token == _runToken) notifyListeners();
  }

  /// 波形/矢量示波器：把计数表映射为亮度图并解码为显示图像。
  Future<void> _updateInstrumentImage(
      String nodeId, Map<String, Object?> result) async {
    int w, h;
    Uint8List bmp;
    switch (result['kind']) {
      case 'waveform':
        w = result['columns'] as int;
        h = kWaveformLevels;
        bmp = _intensityRgba(result['counts'] as Uint32List, w, h,
            const (r: 70, g: 235, b: 70));
      case 'vectorscope':
        w = h = kVectorscopeSize;
        bmp = _intensityRgba(result['counts'] as Uint32List, w, h,
            const (r: 70, g: 235, b: 70)); // 荧光绿，还原真实示波器显示
      default:
        return; // 直方图由控件直接绘制，无需图像
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        bmp, w, h, ui.PixelFormat.rgba8888, completer.complete);
    final image = await completer.future;
    instrumentImages.remove(nodeId)?.dispose();
    instrumentImages[nodeId] = image;
  }

  /// 计数表 → RGBA 亮度图（对数刻度；数据第 0 行在底部，图像第 0 行在顶部）。
  static Uint8List _intensityRgba(
      Uint32List counts, int w, int h, ({int r, int g, int b}) tint) {
    final out = Uint8List(w * h * 4);
    var max = 0;
    for (final c in counts) {
      if (c > max) max = c;
    }
    if (max == 0) return out;
    final logMax = math.log(max + 1);
    for (var ry = 0; ry < h; ry++) {
      final srcRow = h - 1 - ry;
      for (var x = 0; x < w; x++) {
        final c = counts[srcRow * w + x];
        if (c == 0) continue;
        final t = (math.log(c + 1) / logMax * 255).round();
        final j = (ry * w + x) * 4;
        out[j] = tint.r * t ~/ 255;
        out[j + 1] = tint.g * t ~/ 255;
        out[j + 2] = tint.b * t ~/ 255;
        out[j + 3] = 255;
      }
    }
    return out;
  }

  void setPreviewFrame(int frame) {
    if (frame == previewFrame) return;
    previewFrame = frame;
    notifyListeners();
  }

  // ---- 连续播放 ----

  /// 是否正在连续播放预览。
  bool isPlaying = false;

  /// 播放计数：取到的帧数 / 实际上屏 / 时间轴重建（停滞）次数
  /// （诊断用，每次播放清零）。
  int playbackProduced = 0;
  int playbackDisplayed = 0;
  int playbackDropped = 0;

  /// 诊断：当前走帧节奏与单帧生产耗时峰值（微秒）。
  int playbackPaceUs = 0;
  int playbackMaxProdUs = 0;

  /// 诊断：取流帧耗时峰值（微秒）与停滞（>50ms）次数。
  int playbackMaxFetchUs = 0;
  int playbackFetchStalls = 0;

  /// 诊断：等待结束后超过截止时刻的最大值（微秒）。
  int playbackMaxWaitOverUs = 0;

  /// 帧缓存总字节数上限（超出则边算边播，不缓存）。
  static const int kPlaybackCacheBytes = 1600 * 1024 * 1024;

  /// 播放/暂停切换。播放时后台并行预填帧缓存，播放循环按预览节点的
  /// 「播放帧率」参数走帧并刷新预览图（视频源打开文件时已自动填充
  /// 为视频原生帧率，即默认按原速播放）；暂停后刷新当前帧的仪器分析。
  /// 视频源不走全帧缓存，改用单个 ffmpeg 进程顺序流式解码 + 前向
  /// 帧缓冲（与系统视频播放器一致），长视频也不受每帧 seek 开销影响。
  Future<void> togglePlayback() async {
    if (isPlaying) {
      stopPlayback();
      return;
    }
    if (isProcessing) return;
    final preview = _firstPreviewNode;
    if (preview == null) {
      statusMessage = '图中没有预览节点';
      notifyListeners();
      return;
    }
    isProcessing = true;
    isPlaying = true;
    notifyListeners();
    final token = ++_runToken;
    try {
      final chain = _compileTo(preview.id);
      final srcTypeId = chain.first['typeId'] as String;
      final srcParams = chain.first['params'] as Map<String, Object?>;
      totalFrames = await _previewFrameCount(preview, srcTypeId, srcParams);
      final total = totalFrames!;
      final (w, h) = await sourceDimensions(srcTypeId, srcParams);
      if (total <= 1) {
        // 单帧源：退化为普通单帧预览。
        isPlaying = false;
        isProcessing = false;
        await runPreview();
        return;
      }
      // 内存允许则全帧缓存（后台并行预填），否则边算边播。
      // 视频源除外：走顺序流式解码，不做全帧缓存。
      final isVideo = srcTypeId == 'video_source';
      final List<Uint8List?>? cache = !isVideo &&
              total * w * h * 4 <= kPlaybackCacheBytes
          ? List<Uint8List?>.filled(total, null)
          : null;
      if (cache != null && kDebugMode) {
        // JIT 冷启动热身：先串行算出当前帧（顺带填入缓存），
        // 后续并行帧复用优化后的代码。AOT 无此问题。
        final f0 = previewFrame.clamp(0, total - 1);
        statusMessage = '播放准备中…';
        notifyListeners();
        cache[f0] = await compute(
            runChainFrameInIsolate, {'chain': chain, 'frameIndex': f0});
        if (!isPlaying || token != _runToken) return;
      }
      if (cache != null) {
        var next = 0;
        final workers = (Platform.numberOfProcessors - 1).clamp(1, 12);
        for (var k = 0; k < workers; k++) {
          () async {
            while (isPlaying && token == _runToken) {
              final i = next++;
              if (i >= total) return;
              cache[i] ??= await compute(
                  runChainFrameInIsolate, {'chain': chain, 'frameIndex': i});
            }
          }();
        }
      }
      // 与预览同上游链的仪器：播放中直接用当前帧 RGBA 刷新（不重跑流水线）。
      final liveInstruments = <IspNode>[
        for (final node in graph.nodes.values)
          if (instrumentTypes.contains(node.typeId) && _sharesUpstream(node, chain))
            node,
      ];
      var frame = previewFrame.clamp(0, total - 1);
      // 视频源：从当前帧起顺序流式解码（内部前向缓冲，背压限速）。
      var stream = isVideo
          ? await VideoFrameStream.start(
              srcParams['filePath']?.toString() ?? '', frame,
              ffmpegPath: srcParams['ffmpegPath']?.toString() ?? '')
          : null;
      // 音频回放（有音轨时）：ffmpeg 抽取 WAV + MCI 播放。起播推迟到
      // 首帧实际上屏时（起点对齐当前帧），播放中再按 MCI 播放位置做
      // 漂移修正；跟随播放循环回卷/停止。无音轨、无音频设备或抽取
      // 失败时静默跳过音频。
      final audio = MciAudioPlayer();
      var audioReady = false; // 已打开待起播
      var audioStarted = false;
      if (isVideo && stream!.info.hasAudio) {
        try {
          final wav = await ensureAudioWav(
              srcParams['filePath']?.toString() ?? '',
              ffmpegPath: srcParams['ffmpegPath']?.toString() ?? '');
          if (wav != null) {
            audio.open(wav);
            audioReady = true;
          }
        } catch (_) {
          // 音频不可用不影响视频播放。
        }
      }
      // 走帧节奏：按预览节点的「播放帧率」参数。视频源打开文件时该
      // 参数已自动填充为视频原生帧率（autoFillFromVideo），即默认
      // 按原速播放；用户也可手动改参数调速。
      final fps = (preview.paramValues['fps'] as num?)?.toInt() ?? 30;
      final frameDuration =
          Duration(microseconds: (1000000 / fps.clamp(1, 60)).round());
      // 视频源直连汇点（RGB 端口、链上无中间算子）：gamma 1.0 直通是
      // 恒等映射，流帧即为最终 RGBA，不必每帧再过流水线 isolate。
      final videoDirect = isVideo &&
          (chain.first['outFormat'] as String? ?? 'rgb') == 'rgb' &&
          chain.skip(1).every((op) => sinkNodeTypes.contains(op['typeId']));
      // 预取式走帧：上一帧上屏后立刻启动下一帧的生产（取流 / 流水线 /
      // 图像解码），与帧间隔等待并发；到截止时刻直接换图上屏，生产耗时
      // 不再与等待叠加。走帧节奏按预览节点的「播放帧率」参数：目标帧
      // 间隔 frameDuration，实际节奏 pace 按产能自适应（EMA），持续达
      // 不到目标帧率时自动降速全帧显示（分析工具每帧都可能要看，不做
      // 持续丢帧）；偶发停滞（GC/JIT 热身等）跳轴兜底。流水线走常驻
      // worker isolate（PipelineFrameRunner）——每帧 compute() 新起
      // isolate 的 spawn + JIT 冷启动会直接造成丢帧。
      final pipeline = videoDirect ? null : PipelineFrameRunner();
      final playSw = Stopwatch()..start();
      var pace = frameDuration;
      Duration? emaProd;
      var nextDeadline = Duration.zero;
      playbackProduced = playbackDisplayed = playbackDropped = 0;

      // 生产一帧：取流（EOF 回卷重起流）→ 流水线 → 解码 ui.Image。
      // 返回 (帧号, RGBA, 图像, 是否回卷重起, 生产耗时微秒)；空视频
      // 返回 null。videoDirect 的流帧缓冲不在此归还——仪器刷新还要读，
      // 由上屏后的消费方归还。
      Future<(int, Uint8List, ui.Image, bool, int)?> produceFrame(
          int f) async {
        final prodSw = Stopwatch()..start();
        var restarted = false;
        final Uint8List rgba;
        if (isVideo) {
          final fetchSw = Stopwatch()..start();
          var bytes = await stream!.next();
          if (bytes == null) {
            await stream!.dispose();
            stream = await VideoFrameStream.start(
                srcParams['filePath']?.toString() ?? '', 0,
                ffmpegPath: srcParams['ffmpegPath']?.toString() ?? '');
            bytes = await stream!.next();
            if (bytes == null) return null; // 空视频
            f = 0;
            restarted = true;
            // 回卷：音频停下，待回卷后首帧上屏时从头起播对齐。
            try {
              audio.stop();
              audioStarted = false;
            } catch (_) {
              // 音频设备异常不影响视频播放。
            }
          }
          playbackProduced++;
          if (fetchSw.elapsedMicroseconds > playbackMaxFetchUs) {
            playbackMaxFetchUs = fetchSw.elapsedMicroseconds;
          }
          if (fetchSw.elapsedMilliseconds > 50) playbackFetchStalls++;
          if (videoDirect) {
            rgba = bytes;
          } else {
            rgba = await pipeline!.run(chain, f,
                sourceRgba: bytes, sourceWidth: w, sourceHeight: h);
            // 帧字节已拷入 worker，缓冲立即归还池。
            stream!.recycle(bytes);
          }
        } else {
          rgba = cache?[f] ?? await pipeline!.run(chain, f);
        }
        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
            rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
        final image = await completer.future;
        return (f, rgba, image, restarted, prodSw.elapsedMicroseconds);
      }

      Future<(int, Uint8List, ui.Image, bool, int)?>? pending =
          produceFrame(frame);
      try {
        while (isPlaying && token == _runToken) {
          // 等截止时刻：Windows 定时器粒度粗（~15.6ms），先循环粗睡到
          // 剩几毫秒（睡过头/睡不足都由循环兜底），再用事件循环让出式
          // 等待补齐帧边界。等待期间 pending 的生产在并发推进。
          var remain = nextDeadline - playSw.elapsed;
          while (remain > const Duration(milliseconds: 4) &&
              isPlaying &&
              token == _runToken) {
            await Future<void>.delayed(
                remain - const Duration(milliseconds: 4));
            remain = nextDeadline - playSw.elapsed;
          }
          while (remain > Duration.zero && isPlaying && token == _runToken) {
            await Future<void>.delayed(Duration.zero);
            remain = nextDeadline - playSw.elapsed;
          }
          final over = playSw.elapsed - nextDeadline;
          if (over.inMicroseconds > playbackMaxWaitOverUs) {
            playbackMaxWaitOverUs = over.inMicroseconds;
          }
          // 取预取结果：生产已并发完成则立即返回；偶发停滞在此等到帧。
          // 取出后即清空 pending——该帧图像所有权转给上屏流程，finally
          // 的兜底释放只针对仍在途、未上屏的预取帧。
          final pf = pending;
          pending = null;
          final produced = await pf!;
          if (produced == null) break; // 空视频
          final (f, rgba, image, restarted, prodUs) = produced;
          if (!isPlaying || token != _runToken) {
            // 停止/重跑：该帧不再上屏；break 走循环外的暂停收尾
            // （状态栏「已暂停」与仪器刷新），不能直接 return。
            image.dispose();
            break;
          }
          if (playbackDisplayed == 0 || restarted) {
            // 首帧 / EOF 回卷首帧：以上屏时刻为时间轴零点（ffmpeg 与
            // worker 的启动开销不计入走帧，否则开局就连环丢帧）。
            nextDeadline = playSw.elapsed;
          } else if (playSw.elapsed - nextDeadline > pace * 2) {
            // 偶发停滞：不连环丢帧，把时间轴跳过停滞段立刻回到正确
            // 节奏；持续慢由 pace 自适应降速兜底（全帧显示）。
            playbackDropped++;
            nextDeadline = playSw.elapsed;
          }
          previewImage?.dispose();
          previewImage = image;
          previewWidth = w;
          previewHeight = h;
          previewFrame = f;
          playbackDisplayed++;
          // 产能自适应：持续慢于目标帧率时 pace 放宽到实测产能，
          // 全帧显示不丢帧；产能恢复后自动回到目标帧率。
          final prod = Duration(microseconds: prodUs);
          final prevEma = emaProd;
          final ema = prevEma == null ? prod : prevEma * 0.85 + prod * 0.15;
          emaProd = ema;
          pace = ema > frameDuration ? ema : frameDuration;
          playbackPaceUs = pace.inMicroseconds;
          if (prodUs > playbackMaxProdUs) playbackMaxProdUs = prodUs;
          statusMessage = (pace > frameDuration
                  ? '播放中 第 ${f + 1}/$total 帧'
                      '（约 ${(1000000 / pace.inMicroseconds).toStringAsFixed(0)} fps，已降速）'
                  : '播放中 第 ${f + 1}/$total 帧') +
              (playbackDropped > 0 ? '  停滞$playbackDropped次' : '');
          notifyListeners();
          // 音频同步：首帧上屏后起播对齐起点；此后周期性对比 MCI 播放
          // 位置与当前帧时刻，漂移超阈值重新 seek 音频（停滞跳轴、帧率
          // 取整误差、输出缓冲延迟等都会让两侧时钟渐偏）。降速播放时
          // 不校正——视频已不按原速，强行对齐只会反复卡顿。
          if (audioReady && isVideo) {
            final videoT = f / stream!.info.fps;
            if (!audioStarted) {
              try {
                audio.playFrom(videoT);
                audioStarted = true;
              } catch (_) {
                audioReady = false; // 起播失败：本段播放不再尝试音频
              }
            } else if (pace <= frameDuration &&
                playbackDisplayed % 20 == 0) {
              final pos = audio.positionSeconds();
              if (pos != null && (videoT - pos).abs() > 0.12) {
                try {
                  audio.playFrom(videoT);
                } catch (_) {
                  audioReady = false; // 设备异常：放弃音频不影响视频
                }
              }
            }
          }
          // 仪器随播放刷新（后台分析，限频且不阻塞走帧）。
          _refreshInstrumentsFromFrame(rgba, w, h, liveInstruments, token);
          if (isVideo && videoDirect) {
            // 像素与仪器数据都已取走，流帧缓冲归还池。
            stream!.recycle(rgba);
          }
          // 立刻启动下一帧生产，与下一轮的截止等待并发。
          frame = (f + 1) % total;
          pending = produceFrame(frame);
          nextDeadline += pace;
        }
      } finally {
        // 在途的预取帧（未上屏）：结果回来后释放图像，避免泄漏 GPU 纹理。
        final pf = pending;
        if (pf != null) {
          unawaited(pf.then((p) => p?.$3.dispose(), onError: (_) {}));
        }
        audio
          ..stop()
          ..close();
        pipeline?.dispose();
        await stream?.dispose();
      }
      // 暂停：刷新当前帧的仪器分析。
      if (token == _runToken) {
        await _runInstruments(previewFrame, token);
        if (token == _runToken) {
          statusMessage = '已暂停 第 ${previewFrame + 1}/$total 帧';
        }
      }
    } catch (e) {
      statusMessage = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (token == _runToken) {
        isPlaying = false;
        isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// 停止连续播放（播放循环在下一帧边界退出并做收尾）。
  void stopPlayback() {
    if (!isPlaying) return;
    isPlaying = false;
    notifyListeners();
  }

  /// 仪器节点的核心链是否与预览链相同。
  ///
  /// 两侧都去掉末端的透传汇点（预览/仪器/输出节点）后逐节点比较：
  /// 这样仪器接在 gamma 输出上和接在 预览.out 上都算同链
  /// （两种接法看到的图像相同）。
  bool _sharesUpstream(IspNode instrument, List<Map<String, Object?>> chain) {
    final type = IspNodeRegistry.byId(instrument.typeId)!;
    if (!type.inputs
        .any((p) => graph.connectionAt(instrument.id, p.name) != null)) {
      return false;
    }
    final List<Map<String, Object?>> other;
    try {
      other = compileChain(graph, instrument.id);
    } catch (_) {
      return false;
    }
    List<String> coreIds(List<Map<String, Object?>> c) {
      var end = c.length;
      while (end > 0 && sinkNodeTypes.contains(c[end - 1]['typeId'])) {
        end--;
      }
      return [for (var i = 0; i < end; i++) c[i]['nodeId'] as String];
    }

    final a = coreIds(chain);
    final b = coreIds(other);
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 播放中：用当前帧 RGBA 后台刷新仪器分析。上一批未完成或距上次
  /// 刷新不足 100ms 则跳过该帧（仪器刷新率自动低于帧率，不阻塞走帧；
  /// 示波器类显示 10Hz 足够）。分析走常驻 worker isolate。
  bool _instrumentBusy = false;
  DateTime _lastLiveInstrumentRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 常驻仪器分析 isolate（随 state 生命周期，懒启动）。
  final InstrumentAnalyzer _instrumentAnalyzer = InstrumentAnalyzer();

  void _refreshInstrumentsFromFrame(Uint8List rgba, int w, int h,
      List<IspNode> targets, int token) {
    if (_instrumentBusy || targets.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastLiveInstrumentRefresh) <
        const Duration(milliseconds: 100)) {
      return;
    }
    _lastLiveInstrumentRefresh = now;
    _instrumentBusy = true;
    // 仪器分析用 1/2 降采样帧：示波器/直方图/矢量示波器都是统计类
    // 显示，降采样后结果视觉等效、分析耗时降 4 倍。降采样在常驻
    // worker 内做——在 UI isolate 同步降采样大帧（4K 数十毫秒）会
    // 直接卡住走帧节奏。帧数据先拷一份再发：videoDirect 的流帧缓冲
    // 随后就归还解码池，而首个 analyze 要等 worker 起完才发消息。
    final frame = Uint8List.fromList(rgba);
    () async {
      try {
        for (final node in targets) {
          try {
            final result = await _instrumentAnalyzer.analyze(
                frame, w, h, node.typeId, downsample: true);
            if (token != _runToken) return;
            instrumentResults[node.id] = result;
            await _updateInstrumentImage(node.id, result);
          } catch (_) {
            // 单个仪器失败不影响播放。
          }
        }
        if (token == _runToken) notifyListeners();
      } finally {
        _instrumentBusy = false;
      }
    }();
  }

  /// 查询 [nodeId] 输出缓冲在 (x, y, channel) 处的值。
  ///
  /// 变量表只保留前 [kNodeOutputSampleSize] 项采样，超出部分按需重跑：
  /// 编译到该节点为止的链，在后台 isolate 执行当前预览帧并取单个元素。
  Future<int> queryNodeOutputAt(
      String nodeId, int x, int y, int channel) async {
    final chain = compileChain(graph, nodeId);
    return compute(runChainValueAtInIsolate, {
      'chain': chain,
      'frameIndex': previewFrame,
      'x': x,
      'y': y,
      'channel': channel,
    });
  }

  /// 预览节点附加区（屏幕 + 控制条 + 拖动手柄）高度。
  double previewExtraHeight(String nodeId) =>
      _previewExtraHeights[nodeId] ?? kDefaultPreviewExtraHeight;

  /// 最大化显示的节点 id；null 表示无最大化。
  String? maximizedNodeId;

  /// 最大化前的几何备份：nodeId → (x, y, width, extraHeight)。
  final Map<String, (double, double, double, double)> _maximizeBackup = {};

  /// 有显示区（可最大化）的节点：预览 + 仪器。
  bool canMaximize(String nodeId) {
    final t = graph.nodes[nodeId]?.typeId;
    return t == 'preview' || instrumentTypes.contains(t);
  }

  /// 最大化/还原切换：最大化 = 节点铺满 [viewportCanvas]（画布坐标
  /// 下的视口矩形，留边距），原几何入备份；再次调用或切换其他节点
  /// 时还原。宽高直接写字段，不受手动拖拽的 clamp 上限限制。
  void toggleMaximize(String nodeId, ui.Rect viewportCanvas) {
    if (maximizedNodeId == nodeId) {
      _restoreMaximized(nodeId);
      maximizedNodeId = null;
      notifyListeners();
      return;
    }
    final node = graph.nodes[nodeId];
    if (node == null || !canMaximize(nodeId)) return;
    if (maximizedNodeId != null) {
      _restoreMaximized(maximizedNodeId!); // 还原上一个最大化节点
      maximizedNodeId = null;
    }
    final type = IspNodeRegistry.byId(node.typeId)!;
    _maximizeBackup[nodeId] =
        (node.x, node.y, node.width, previewExtraHeight(nodeId));
    const margin = 12.0;
    node.x = viewportCanvas.left + margin;
    node.y = viewportCanvas.top + margin;
    node.width = viewportCanvas.width - margin * 2;
    _previewExtraHeights[nodeId] = viewportCanvas.height -
        margin * 2 -
        nodeHeight(type, previewExtraHeight: 0);
    maximizedNodeId = nodeId;
    notifyListeners();
  }

  /// 还原因最大化被改动的几何（备份缺失时不动）。
  void _restoreMaximized(String nodeId) {
    final backup = _maximizeBackup.remove(nodeId);
    final node = graph.nodes[nodeId];
    if (backup == null || node == null) return;
    node.x = backup.$1;
    node.y = backup.$2;
    node.width = backup.$3;
    _previewExtraHeights[nodeId] = backup.$4;
  }

  /// 拖动调整预览节点屏幕高度（[height] 为画布坐标下的附加区总高）。
  void setPreviewExtraHeight(String nodeId, double height) {
    final h = height.clamp(kMinPreviewExtraHeight, kMaxPreviewExtraHeight);
    if (h == previewExtraHeight(nodeId)) return;
    _previewExtraHeights[nodeId] = h;
    notifyListeners();
  }

  /// 双向调整预览节点屏幕尺寸（右下角控制点）。
  /// 宽度存在节点上，输出端口与连线几何随之更新。
  void resizePreview(String nodeId, double width, double extraHeight) {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    node.width = width.clamp(kMinPreviewNodeWidth, kMaxPreviewNodeWidth);
    _previewExtraHeights[nodeId] =
        extraHeight.clamp(kMinPreviewExtraHeight, kMaxPreviewExtraHeight);
    notifyListeners();
  }

  // ---- 导出 ----

  /// 导出图片（单帧或逐帧序列；多帧时帧级并行，见 worker 池实现）。
  Future<void> exportImages(String nodeId) async {
    if (isProcessing) return;
    isProcessing = true;
    progress = 0;
    statusMessage = '正在导出图片…';
    notifyListeners();
    final token = ++_runToken;
    try {
      final node = graph.nodes[nodeId]!;
      final p = node.paramValues;
      final dir = p['directory']?.toString() ?? '';
      if (dir.isEmpty) throw StateError('图片输出节点未设置输出目录');
      await Directory(dir).create(recursive: true); // 缺省目录可能尚不存在
      final format = p['format']?.toString() ?? 'jpg';
      final quality = (p['quality'] as num?)?.toInt() ?? 100;
      final nameTemplate = p['fileName']?.toString().isNotEmpty == true
          ? p['fileName'].toString()
          : 'isp_{frame}';

      final chain = _compileTo(nodeId);
      final total = await sourceFrameCount(chain.first['typeId'] as String,
          chain.first['params'] as Map<String, Object?>);
      // JPG 编码优先走内置 ffmpeg（mjpeg 比纯 Dart 编码器快一个量级）；
      // 找不到时由 isolate 内回退到 Dart 编码。
      final ffmpeg = format == 'jpg' ? await findFfmpeg() : null;
      // 帧级并行：多个异步 worker 抢占帧索引，各自在后台 isolate 跑完整链
      // + 编码。并发数按核数取，上限 12（4K 帧每个 isolate 峰值约几百 MB）。
      final workers = (Platform.numberOfProcessors - 1).clamp(1, 12);
      var next = 0;
      var done = 0;
      Future<bool> exportFrame(int i) async {
        final bytes = await compute(encodeFrameInIsolate, {
          'chain': chain,
          'frameIndex': i,
          'format': format,
          'quality': quality,
          'ffmpegPath': ?ffmpeg,
        });
        if (token != _runToken) return false; // 被取消，丢弃结果
        final name =
            '${nameTemplate.replaceAll('{frame}', i.toString())}.$format';
        await File('$dir${Platform.pathSeparator}$name').writeAsBytes(bytes);
        done++;
        progress = done / total;
        statusMessage = '正在导出图片 $done/$total';
        notifyListeners();
        return true;
      }

      // JIT（debug 运行）冷启动时并行帧会挤在共享编译队列上，慢一个量级；
      // 先串行导出第 0 帧热身，后续并行帧复用优化后的代码。AOT 无此问题。
      if (kDebugMode && total > 1) {
        statusMessage = '正在导出图片（热身帧）…';
        notifyListeners();
        if (!await exportFrame(next++)) return; // 被取消
      }

      Future<void> worker() async {
        while (true) {
          if (token != _runToken) return; // 被取消
          final i = next++;
          if (i >= total) return;
          if (!await exportFrame(i)) return; // 被取消
        }
      }

      await Future.wait([for (var w = 0; w < workers; w++) worker()]);
      if (token != _runToken) return; // 被取消
      statusMessage = '图片导出完成（$total 帧 → $dir）';
    } catch (e) {
      statusMessage = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (token == _runToken) {
        isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// 导出 MP4（经 ffmpeg 管道；多帧时帧级并行产帧、按序喂帧）。
  Future<void> exportVideo(String nodeId) async {
    if (isProcessing) return;
    isProcessing = true;
    progress = 0;
    statusMessage = '正在导出视频…';
    notifyListeners();
    final token = ++_runToken;
    try {
      final node = graph.nodes[nodeId]!;
      final p = node.paramValues;
      final outPath = p['filePath']?.toString() ?? '';
      if (outPath.isEmpty) throw StateError('视频输出节点未设置输出文件');
      // ffmpeg 不会自建目录：确保输出目录存在。
      await File(outPath).parent.create(recursive: true);
      final fps = (p['fps'] as num?)?.toInt() ?? 30;
      final crf = (p['crf'] as num?)?.toInt() ?? 18;
      final encoder = p['encoder']?.toString() ?? 'x264';
      final ffmpeg =
          await findFfmpeg(overridePath: p['ffmpegPath']?.toString() ?? '');
      if (ffmpeg == null) {
        throw StateError('未找到 ffmpeg.exe，请将 ffmpeg 放入 tools/ffmpeg/ '
            '或加入 PATH，或在节点参数中指定路径');
      }

      final chain = _compileTo(nodeId);
      final srcTypeId = chain.first['typeId'] as String;
      final srcParams = chain.first['params'] as Map<String, Object?>;
      final total = await sourceFrameCount(srcTypeId, srcParams);
      final (w, h) = await sourceDimensions(srcTypeId, srcParams);

      // 帧级并行 + 按序交付：最多 [workers] 帧在后台 isolate 中并行计算，
      // frameProvider 始终按 0,1,2… 顺序把帧喂给 ffmpeg stdin。
      final workers = (Platform.numberOfProcessors - 1).clamp(1, 8);
      var next = 0;
      final pending = <int, Future<Uint8List>>{};
      void schedule() {
        while (pending.length < workers && next < total) {
          final i = next++;
          pending[i] = compute(
              runChainFrameInIsolate, {'chain': chain, 'frameIndex': i});
        }
      }

      // JIT（debug 运行）冷启动时并行帧会挤在共享编译队列上，慢一个量级；
      // 先串行算第 0 帧热身，后续并行帧复用优化后的代码。AOT 无此问题。
      if (kDebugMode && total > 1) {
        statusMessage = '正在导出视频（热身帧）…';
        notifyListeners();
        pending[0] = compute(
            runChainFrameInIsolate, {'chain': chain, 'frameIndex': 0});
        next = 1;
        await pending[0]; // 等热身完成（结果留在队列按序交付）
      }
      schedule();

      await exportMp4(
        ffmpegPath: ffmpeg,
        outputPath: outPath,
        width: w,
        height: h,
        fps: fps,
        crf: crf,
        frameCount: total,
        encoder: encoder,
        frameProvider: (i) async {
          if (token != _runToken) throw StateError('导出已取消');
          final f = pending.remove(i);
          if (f == null) throw StateError('帧 $i 未在调度队列中');
          final Uint8List bytes;
          try {
            bytes = await f;
          } catch (_) {
            // 避免队列里其余 future 的错误变成未处理异常。
            for (final rest in pending.values) {
              rest.ignore();
            }
            rethrow;
          }
          schedule(); // 消费一帧，补一帧
          return bytes;
        },
        onProgress: (done, totalFrames) {
          progress = done / totalFrames;
          statusMessage = '正在编码视频 $done/$totalFrames';
          notifyListeners();
        },
      );
      statusMessage = '视频导出完成 → $outPath';
    } catch (e) {
      statusMessage = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (token == _runToken) {
        isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// 取消正在进行的导出。
  void cancelProcessing() {
    if (isProcessing) {
      _runToken++;
      isProcessing = false;
      statusMessage = '已取消';
      notifyListeners();
    }
  }

  // ---- 流程图保存 / 打开 ----

  /// 把当前流程图（含工程名）写入 [path]（JSON 文本），
  /// 保存后工程名更新为文件名。
  Future<void> saveGraphToFile(String path) async {
    try {
      final json = <String, Object?>{'name': graphName, ...graph.toJson()};
      await File(path)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      graphName = p.basenameWithoutExtension(path);
      statusMessage = '流程已保存 → $path';
    } catch (e) {
      statusMessage = '保存流程失败: $e';
    }
    notifyListeners();
  }

  /// 从 [path] 读取流程图 JSON 并替换当前图；失败只更新状态栏消息。
  Future<void> importGraphFromFile(String path) async {
    try {
      final decoded = jsonDecode(await File(path).readAsString());
      if (decoded is! Map) throw const FormatException('不是有效的流程文件');
      final m = decoded.cast<String, Object?>();
      final imported = IspGraph.fromJson(m);
      _replaceGraph(
          imported, m['name'] as String? ?? p.basenameWithoutExtension(path));
      statusMessage = '已打开流程「$graphName」';
    } catch (e) {
      statusMessage =
          '打开流程失败: ${e.toString().replaceFirst('FormatException: ', '')}';
    }
    notifyListeners();
  }

  /// 用打开的图替换当前图，并使所有运行状态（预览/采样/标签页）失效。
  void _replaceGraph(IspGraph imported, String? name) {
    graph.nodes
      ..clear()
      ..addAll(imported.nodes);
    graph.connections
      ..clear()
      ..addAll(imported.connections);
    graph.nextId = imported.nextId;
    graphName = name;
    _runToken++; // 使进行中的运行结果失效
    openCodeTabs.clear();
    activeTab = 0;
    nodeOutputCaptures = {};
    instrumentResults = {};
    _histogramChannels.clear();
    for (final img in instrumentImages.values) {
      img.dispose();
    }
    instrumentImages.clear();
    totalFrames = null;
    previewImage?.dispose();
    previewImage = null;
    selectedNodeId = null;
    selectedConnectionId = null;
    _previewExtraHeights.clear();
    errors.clear();
  }

  @override
  void dispose() {
    _instrumentAnalyzer.dispose();
    cleanupAudioWavCache();
    previewImage?.dispose();
    for (final img in instrumentImages.values) {
      img.dispose();
    }
    super.dispose();
  }
}
