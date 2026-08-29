import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../modules/isp_studio/models/isp_align_mode.dart';
import '../modules/isp_studio/models/isp_graph.dart';
import '../modules/isp_studio/models/isp_node.dart';
import '../modules/isp_studio/pipeline/audio_analysis.dart';
import '../modules/isp_studio/pipeline/audio_player.dart';
import '../modules/isp_studio/pipeline/exporters.dart';
import '../modules/isp_studio/pipeline/image_source.dart';
import '../modules/isp_studio/pipeline/instrument_worker.dart';
import '../modules/isp_studio/pipeline/instruments.dart';
import '../modules/isp_studio/pipeline/pipeline_runner.dart';
import '../modules/isp_studio/pipeline/pipeline_worker.dart';
import '../modules/isp_studio/pipeline/dng_source.dart';
import '../modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import '../modules/isp_studio/pipeline/raw_sidecar.dart';
import '../modules/isp_studio/pipeline/video_source.dart';
import '../modules/isp_studio/widgets/node_layout.dart';

/// GPU 平面预览帧：视频 yuv444p 直出帧原样打包成的单张纹理
/// （宽 w/4、高 h*3，RGBA 纹素各装 4 个连续样本）+ 显示模式。
/// 由 shaders/yuv_planes.frag 在 GPU 上解包上色，CPU 零逐像素工作。
class PlanePreviewFrame {
  /// 打包纹理（同帧所有预览节点共享，只随换帧释放一次）。
  final ui.Image packed;

  /// 0=YUV→RGB 彩色；1/2/3=Y/U/V 平面灰度。
  final int mode;

  /// 逻辑图像尺寸（视频原始宽高）。
  final int width;
  final int height;

  /// 源是否 limited range（tv）：shader 里做范围扩展。
  final bool limited;

  const PlanePreviewFrame(
      this.packed, this.mode, this.width, this.height, this.limited);
}

/// GPU 前缀覆盖去重的处理链视图：透传汇点（preview/histogram）不参与
/// 处理比对——其显示 = 前一节点输出帧的默认色调映射；调节器汇点的
/// 显示 = 自身输出。
List<Map<String, Object?>> gpuProcChainOf(List<Map<String, Object?>> chain) =>
    switch (chain.last['typeId']) {
      'preview' || 'histogram' => chain.sublist(0, chain.length - 1),
      _ => chain,
    };

/// GPU 主链覆盖判定：[sub] 链（的处理段）是否为 [mainIds] 主链的前缀、
/// 可由主链顺带捕获出图。含 gamma 的链出图参数与默认色调映射不同，
/// 不做合并捕获。
///
/// 透传汇点（preview/histogram）不在主链上时的额外约束：汇点的显示 =
/// 其**输入端口**数据，而前缀覆盖的捕获点落在处理链末端节点的**主帧**。
/// 仅当汇点输入来自上游主帧别名端口（out / out_rgb / out_yuv /
/// out_hsl）时两者才等价；输入来自侧向端口（分路器 out_y/out_u/out_v、
/// edge_extract out_mono 等）时数据与主帧不同，拒绝覆盖——该链另作
/// GPU 主链独立执行（否则单通道预览会错显示为上游主帧，如 Y 通道
/// 预览显示成全彩 YUV 图）。汇点在主链上时捕获点即汇点自身（GPU
/// 执行到该节点时 frame 正是其输入帧），无此问题。
bool gpuChainPrefixCovered(
    List<Map<String, Object?>> sub, List<String> mainIds) {
  final proc = gpuProcChainOf(sub);
  if (proc.length > mainIds.length) return false;
  for (var i = 0; i < proc.length; i++) {
    // 含 gamma 的链出图参数与默认色调映射不同，不做合并捕获。
    if (proc[i]['typeId'] == 'gamma') return false;
    if (proc[i]['nodeId'] != mainIds[i]) return false;
  }
  final sink = sub.last;
  if ((sink['typeId'] == 'preview' || sink['typeId'] == 'histogram') &&
      !mainIds.contains(sink['nodeId'])) {
    const mainAliases = {'out', 'out_rgb', 'out_yuv', 'out_hsl'};
    final sinkInputs = sink['inputs'] as Map<String, Object?>?;
    if (sinkInputs != null) {
      for (final port
          in const ['in', 'in_yuv', 'in_hsl', 'in_mono', 'in_raw']) {
        final conn = sinkInputs[port] as Map<String, Object?>?;
        if (conn == null) continue;
        final fromPort = conn['fromPort'] as String? ?? 'out';
        if (!mainAliases.contains(fromPort)) return false;
        break;
      }
    }
  }
  return true;
}

/// ISP Studio 模块状态：节点图、画布变换、执行与导出编排。
class IspStudioState extends ChangeNotifier {
  /// 创建空图（画布无预置节点）的初始状态。
  IspStudioState() : graph = IspGraph();

  /// 以预置默认流程图（Bayer→Preview 完整链路）初始化。
  IspStudioState.withDefaultGraph() : graph = defaultGraph();

  /// 测试专用：与默认构造相同，保留命名以便测试代码语义清晰。
  IspStudioState.empty() : graph = IspGraph();

  final IspGraph graph;

  static const double kGridSize = 10.0;

  final List<String> selectedNodeIds = [];

  /// 多选连线集合（链路选中高亮）：由 [selectChain] 整链设置；普通
  /// 点选节点/连线时清空。与单选 [selectedConnectionId] 互斥使用，
  /// 多选连线不显示删除控制点（避免满链删除按钮）。
  final Set<String> selectedConnectionIds = {};

  String? get primarySelectedNodeId =>
      selectedNodeIds.isNotEmpty ? selectedNodeIds.first : selectedNodeId;

  IspNode? get primarySelectedNode =>
      primarySelectedNodeId != null ? graph.nodes[primarySelectedNodeId] : null;

  Rect? selectionBoxRect;

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

  /// 进度显示信号：状态栏百分比唯一监听它（逐 tick 更新），避免
  /// 走 notifyListeners 引发全树重建。显示值在事件锚点之间由
  /// 定时器平滑逼近（见 [_advanceProgress]），百分比连续递增
  /// 而非固定值跳变；显示值永不越过锚点（不会虚报进度）。
  final ValueNotifier<double> progressTick = ValueNotifier(0);
  double _progressAnchor = 0;
  Timer? _progressTimer;

  /// 把进度锚点推进到 [target]（0..1）；显示值以约 100ms 时间常数
  /// 追赶锚点。只前进不后退。
  void _advanceProgress(double target) {
    if (target <= _progressAnchor) return;
    _progressAnchor = target;
    progress = target;
    if (_progressTimer != null) return;
    _progressTimer =
        Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final gap = _progressAnchor - progressTick.value;
      if (gap <= 0.004) {
        progressTick.value = _progressAnchor;
        timer.cancel();
        _progressTimer = null;
      } else {
        progressTick.value += gap * 0.15;
      }
    });
  }

  /// 归零进度（运行开始/结束时调用）：停表、锚点与显示值同时复位。
  void _resetProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _progressAnchor = 0;
    progress = 0;
    progressTick.value = 0;
  }

  // ---- 预览 ----

  /// 主预览图（向后兼容：取 previewImages 中的第一个条目，如没有则 null）。
  ui.Image? get previewImage =>
      previewImages.isEmpty ? _legacyPreviewImage : previewImages.values.first;

  /// 旧单链预览路径的图像引用。**非持有别名**：指向 previewImages
  /// 中第一个预览节点的图像，释放统一由 previewImages 的清理负责，
  /// 任何路径都不得单独 dispose 它（否则与 previewImages 双重释放）。
  ui.Image? _legacyPreviewImage;

  int previewFrame = 0;
  int previewWidth = 0;
  int previewHeight = 0;
  int? totalFrames;

  /// 最近一次预览运行时采样到的各节点输出
  /// （nodeId → `{'format': String, 'length': int, 'sample': List<int>}`），
  /// 供代码标签页的变量表显示运行值；图被修改后清空。
  Map<String, Map<String, Object?>> nodeOutputCaptures = {};

  /// 最近一次预览运行时测得的各节点执行耗时（nodeId → 微秒），
  /// 供节点卡片标题栏显示节点工作时间；与 [nodeOutputCaptures]
  /// 同样规则过期（图被修改后清空）。
  Map<String, int> nodeRunTimesUs = {};

  /// 最近一次预览运行各节点的执行后端（nodeId → true 为 GPU 快路径、
  /// false 为 CPU isolate 路径；GPU 主链节点优先，CPU 闭包用
  /// putIfAbsent 合并不覆盖）。供右侧面板的流程摘要显示。
  Map<String, bool> nodeRunOnGpu = {};

  /// 图片源解码缓存：filePath → (RGBA8888, 宽, 高, 文件修改时间ms, 文件大小)。
  /// 大图（如 20MP JPEG）纯 Dart 解码需秒级；同一文件在一次运行中被
  /// 多条预览链引用时只解码一次（各链经 sourceRgba 注入共享），跨次
  /// 运行文件未变（按 mtime+大小校验）也直接复用。
  final Map<String, (Uint8List, int, int, int, int)> _imageSourceRgbaCache = {};

  /// 取图片源的 RGBA8888 解码结果（缓存命中直接返回；未命中后台
  /// isolate 解码并缓存）。文件不存在/无法解码时抛 [StateError]。
  Future<(Uint8List, int, int)> _imageSourceRgba(String filePath) async {
    final stat = await File(filePath).stat();
    final mtime = stat.modified.millisecondsSinceEpoch;
    final cached = _imageSourceRgbaCache[filePath];
    if (cached != null && cached.$4 == mtime && cached.$5 == stat.size) {
      return (cached.$1, cached.$2, cached.$3);
    }
    // 简易容量上限：图片帧很大（20MP ≈ 81MB），不长期累积。
    if (_imageSourceRgbaCache.length >= 4) _imageSourceRgbaCache.clear();
    final (rgba, w, h) = await compute(decodeImageFileToRgba8, filePath);
    _imageSourceRgbaCache[filePath] = (rgba, w, h, mtime, stat.size);
    return (rgba, w, h);
  }

  /// GPU 预览加速开关（默认开）：单帧预览的算子链优先在 GPU 上执行
  /// （16 位打包纹理 + FragmentShader），任一环节不支持/失败自动回退
  /// CPU isolate 路径，行为不变。
  bool gpuPreviewEnabled = true;

  /// GPU 链执行器（懒加载；加载失败置 [_gpuUnavailable] 不再重试）。
  GpuPipeline? _gpu;
  bool _gpuUnavailable = false;

  Future<GpuPipeline?> _gpuPipeline() async {
    if (!gpuPreviewEnabled || _gpuUnavailable) return null;
    final g = _gpu ??= await GpuPipeline.tryCreate();
    if (g == null) _gpuUnavailable = true;
    return g;
  }

  /// 仪器节点最近一次分析结果（nodeId → analyzeInstrumentInIsolate 的
  /// 返回 map），随预览运行刷新；直方图数据由节点控件直接绘制。
  Map<String, Map<String, Object?>> instrumentResults = {};

  /// 波形/矢量示波器节点的显示图像（nodeId → 计数表映射的亮度图）。
  final Map<String, ui.Image> instrumentImages = {};

  /// 直方图节点的通道可见性（nodeId → 可见通道，缺省全部）。
  final Map<String, Set<String>> _histogramChannels = {};

  /// 直方图节点当前可见的通道集合（连接 MONO 时默认 Y，连接 RGB/YUV/HSL 时默认 R/G/B）。
  Set<String> histogramChannels(String nodeId) {
    if (_histogramChannels.containsKey(nodeId)) {
      return _histogramChannels[nodeId]!;
    }
    if (graph.connectionAt(nodeId, 'in_mono') != null) {
      return _histogramChannels[nodeId] = {'y'};
    }
    return _histogramChannels[nodeId] = {'r', 'g', 'b'};
  }

  /// 切换直方图节点某通道的显示（Y 与 R/G/B 互斥；关闭 Y 时 R/G/B 默认全开；当 R/G/B 全关时自动激活 Y）。
  void toggleHistogramChannel(String nodeId, String channel) {
    final set = histogramChannels(nodeId);
    if (channel == 'y') {
      if (set.contains('y')) {
        set.clear();
        set.addAll(['r', 'g', 'b']);
      } else {
        set.clear();
        set.add('y');
      }
    } else {
      if (set.contains('y')) {
        set.clear();
        set.add(channel);
      } else {
        if (set.contains(channel)) {
          set.remove(channel);
          if (set.isEmpty) {
            set.add('y');
          }
        } else {
          set.add(channel);
        }
      }
    }
    notifyListeners();
  }

  // ---- 预览节点屏幕尺寸（附加区高度，画布坐标）----
  static const double kDefaultPreviewExtraHeight = 160;
  static const double kMinPreviewExtraHeight = 100;
  static const double kMaxPreviewExtraHeight = 800;
  static const double kMinPreviewNodeWidth = 140;
  static const double kMaxPreviewNodeWidth = 800;

  /// 节点宽度上限：调节器（HSL/RGB/YUV、色饱和度/亮度、亮度/对比度、
  /// 色彩平衡、色温）、高频边缘提取与曲线调节器为附加显示区需要更宽，
  /// 放宽到全局上限的 1.6 倍，其余节点用全局上限。
  static double maxNodeWidthFor(String typeId) =>
      (typeId == 'hsl_debugger' ||
          typeId == 'rgb_debugger' ||
          typeId == 'yuv_debugger' ||
          typeId == 'sat_bright_adjuster' ||
          typeId == 'bright_contrast_adjuster' ||
          typeId == 'color_balance' ||
          typeId == 'color_temp_adjuster' ||
          typeId == 'edge_extract' ||
          typeId == 'levels_curves')
          ? kMaxPreviewNodeWidth * 1.6
          : kMaxPreviewNodeWidth;
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
    final vp = canvasViewport;
    if (graph.nodes.isEmpty || vp == null || vp.width <= 0 || vp.height <= 0) {
      canvasOffset = Offset.zero;
      canvasZoom = 1.0;
      notifyListeners();
      return;
    }

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final node in graph.nodes.values) {
      final type = IspNodeRegistry.byId(node.typeId);
      final h = type != null
          ? nodeHeight(type, previewExtraHeight: previewExtraHeight(node.id))
          : 100.0;
      if (node.x < minX) minX = node.x;
      if (node.y < minY) minY = node.y;
      if (node.x + node.width > maxX) maxX = node.x + node.width;
      if (node.y + h > maxY) maxY = node.y + h;
    }

    const margin = 40.0;
    final contentW = (maxX - minX) + margin * 2;
    final contentH = (maxY - minY) + margin * 2;

    final scaleX = vp.width / contentW;
    final scaleY = vp.height / contentH;
    final zoom = math.min(scaleX, scaleY).clamp(0.25, 1.0);

    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;

    canvasZoom = zoom;
    canvasOffset = Offset(
      vp.width / 2 - cx * zoom,
      vp.height / 2 - cy * zoom,
    );
    notifyListeners();
  }

  // ---- 节点操作 ----

  void addNodeAt(String typeId, Offset canvasPos) {
    final snappedX = snapToGrid(canvasPos.dx);
    final snappedY = snapToGrid(canvasPos.dy);
    final id = graph.addNode(typeId, snappedX, snappedY);
    selectedNodeId = id;
    notifyListeners();
  }

  // Accumulated sub-pixel drag delta per node (cleared on endNodeDrag).
  final Map<String, Offset> _nodeDragAccum = {};

  /// 当前拖动组：拖动开始时若被拖节点在多选集合内，整组同步移动。
  final Set<String> _dragGroupIds = {};

  void beginNodeDrag(String nodeId) {
    _dragGroupIds
      ..clear()
      ..add(nodeId);
    if (selectedNodeIds.length > 1 && selectedNodeIds.contains(nodeId)) {
      _dragGroupIds.addAll(selectedNodeIds);
    }
    for (final id in _dragGroupIds) {
      _nodeDragAccum[id] = Offset.zero;
    }
  }

  void endNodeDrag() {
    _dragGroupIds.clear();
    _nodeDragAccum.clear();
  }

  void removeNode(String id) {
    graph.removeNode(id);
    closeCodeTab(id);
    nodeOutputCaptures = {};
    nodeRunTimesUs = {}; // 运行值已过期
    nodeRunOnGpu = {}; // 同上
    _instrumentSrcCache.clear();
    instrumentResults.remove(id);
    instrumentImages.remove(id)?.dispose();
    brightContrastWaveforms.remove(id)?.dispose();
    brightContrastInputWaveforms.remove(id)?.dispose();
    hslVectorscopes.remove(id)?.dispose();
    hslInputVectorscopes.remove(id)?.dispose();
    levelsHistograms.remove(id);
    levelsOutputHistograms.remove(id);
    measuredColorTemps.remove(id);
    colorTempHistograms.remove(id);
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
    // 多选时删除全部选中节点（而非仅黄色高亮的主选中节点）。
    final ids = selectedNodeIds.toList();
    if (ids.isEmpty) {
      final id = selectedNodeId;
      if (id != null) removeNode(id);
      return;
    }
    for (final id in ids) {
      removeNode(id);
    }
    selectedNodeIds.clear();
    selectedNodeId = null;
  }

  static double snapToGrid(double val, {double step = 10.0}) {
    return (val / step).round() * step;
  }

  // ---- 节点复制 / 粘贴 ----

  /// 节点剪贴板（应用内，不随流程保存）：节点快照 + 选中集内部连线 +
  /// 被完整包含的编组。
  List<Map<String, Object?>>? _nodeClipboard;
  List<IspConnection>? _connClipboard;
  List<({Set<String> nodeIds, String name})>? _groupClipboard;

  /// 粘贴次数（每次粘贴级联偏移，避免与原节点/上次粘贴重叠）。
  int _pasteSerial = 0;

  /// 复制选中节点：选中集内部的连线与完整包含的编组一并入剪贴板。
  void copySelectedNodes() {
    final ids = selectedNodeIds
        .where((id) => graph.nodes.containsKey(id))
        .toSet();
    if (ids.isEmpty) return;
    _nodeClipboard = [
      for (final id in ids)
        {
          'ref': id,
          'typeId': graph.nodes[id]!.typeId,
          'x': graph.nodes[id]!.x,
          'y': graph.nodes[id]!.y,
          'width': graph.nodes[id]!.width,
          'extraHeight': graph.nodes[id]!.extraHeight,
          'params': Map<String, Object?>.from(graph.nodes[id]!.paramValues),
        },
    ];
    _connClipboard = [
      for (final c in graph.connections)
        if (ids.contains(c.fromNodeId) && ids.contains(c.toNodeId)) c,
    ];
    _groupClipboard = [
      for (final g in graph.groups)
        if (ids.containsAll(g.nodeIds))
          (nodeIds: Set<String>.of(g.nodeIds), name: g.name),
    ];
    _pasteSerial = 0;
    statusMessage = '已复制 ${ids.length} 个节点';
    notifyListeners();
  }

  /// 粘贴剪贴板节点：新 id 新实例名（自动编号），位置按粘贴次数级联
  /// 偏移（+20×N），内部连线与完整编组一并复制，粘贴后选中新节点。
  void pasteNodes() {
    final clip = _nodeClipboard;
    if (clip == null || clip.isEmpty) return;
    _pasteSerial++;
    final d = 20.0 * _pasteSerial;
    final idMap = <String, String>{};
    for (final e in clip) {
      final newId = graph.addNode(e['typeId'] as String,
          (e['x'] as num).toDouble() + d, (e['y'] as num).toDouble() + d);
      final node = graph.nodes[newId]!;
      node.width = (e['width'] as num).toDouble();
      node.extraHeight = (e['extraHeight'] as num).toDouble();
      node.paramValues
        ..clear()
        ..addAll((e['params'] as Map).cast<String, Object?>());
      idMap[e['ref'] as String] = newId;
    }
    for (final c in _connClipboard ?? const <IspConnection>[]) {
      graph.connections.add(IspConnection(
        id: 'c${graph.nextId++}',
        fromNodeId: idMap[c.fromNodeId]!,
        fromPort: c.fromPort,
        toNodeId: idMap[c.toNodeId]!,
        toPort: c.toPort,
      ));
    }
    for (final g in _groupClipboard ??
        const <({Set<String> nodeIds, String name})>[]) {
      graph.groups.add(IspNodeGroup(
          'g${graph.nextId++}', {for (final id in g.nodeIds) idMap[id]!},
          name: g.name));
    }
    // 选中新节点（编组联动可能造成整组已选，contains 判重防止反复反选）。
    selectNode(null);
    for (final id in idMap.values) {
      if (!selectedNodeIds.contains(id)) {
        selectNode(id, multiSelect: true);
      }
    }
    statusMessage = '已粘贴 ${idMap.length} 个节点';
    notifyListeners();
  }

  Size? canvasViewport;

  final Map<String, ui.Image> previewImages = {};

  /// 调节器节点的「调整前」输入对比图（hsl_debugger / rgb_debugger /
  /// yuv_debugger / sat_bright_adjuster / bright_contrast_adjuster /
  /// color_balance / color_temp_adjuster / edge_extract 使用，键为节点
  /// id）。
  /// 所有权与释放规则同 [previewImages]：
  /// 替换前先 dispose 旧值，统一清理由 _replaceGraph / dispose 负责。
  final Map<String, ui.Image> previewInputImages = {};

  /// 亮度/对比度调节器节点的 Y 通道波形图（bright_contrast_adjuster
  /// 使用，键为节点 id；由输出链末端 RGBA 经 waveformLuma 统计渲染）。
  /// 所有权与释放规则同 [previewImages]。
  final Map<String, ui.Image> brightContrastWaveforms = {};

  /// 亮度/对比度调节器的「调整前」输入波形图（由输入链末端 RGBA 统计，
  /// 示波器左半区显示）。所有权与释放规则同 [previewImages]。
  final Map<String, ui.Image> brightContrastInputWaveforms = {};

  /// HSL 调节器节点的矢量示波器图（hsl_debugger 使用，键为节点 id；
  /// 由输出链末端 RGBA 经 vectorscope 统计渲染，与 vectorscope 仪器
  /// 同一口径）。所有权与释放规则同 [previewImages]。
  final Map<String, ui.Image> hslVectorscopes = {};

  /// HSL 调节器的「调整前」输入矢量示波器图（由输入链末端 RGBA 统计，
  /// 左半区显示）。所有权与释放规则同 [previewImages]。
  final Map<String, ui.Image> hslInputVectorscopes = {};

  /// 曲线调节器节点的输入 Y 直方图（levels_curves 使用，键为节点 id；
  /// 由输入链末端 RGBA 经 histogramRgb 统计，曲线编辑器背景显示）。
  /// 纯计数表，无需 dispose。
  final Map<String, Uint32List> levelsHistograms = {};

  /// 曲线调节器节点的输出（调节后）Y 直方图（键为节点 id；由该节点
  /// 输出链末端 RGBA 经 histogramRgb 统计，与输入直方图同口径，
  /// 曲线编辑器中叠加显示）。纯计数表，无需 dispose。
  final Map<String, Uint32List> levelsOutputHistograms = {};

  /// 色温调节器节点的实测色温（键为节点 id，开尔文）：运行预览时由
  /// 输入链末端 RGBA 经 McCamy 公式估计（measureCctFromRgba），节点
  /// 附加区显示为可点击按钮——点击后滑块设为该测量值（见
  /// [applyMeasuredColorTemp]）。
  final Map<String, int> measuredColorTemps = {};

  /// 色温调节器节点的调整后 RGB 直方图（键为节点 id，R/G/B 三个 256
  /// 桶计数表；由该节点输出链末端 RGBA 经 histogramRgb 统计，节点
  /// 右下角显示）。纯计数表，无需 dispose。
  final Map<String, (Uint32List, Uint32List, Uint32List)>
      colorTempHistograms = {};

  /// 把色温调节器的滑块（目标色温）设定为实测色温：同时把参考色温
  /// 隐式参数 measured_cct 设为同一值（目标==参考 → 增益恒等，即以
  /// 当前测量为基准），然后重跑预览。未测量（未运行）时无操作。
  /// 返回重跑的 Future（UI 点击可忽略，测试可 await）。
  Future<void> applyMeasuredColorTemp(String nodeId) async {
    final m = measuredColorTemps[nodeId];
    final node = graph.nodes[nodeId];
    if (m == null || node == null) return;
    setParam(nodeId, 'measured_cct', m);
    setParam(nodeId, 'temperature', m.toDouble());
    await runPreview();
  }

  final Map<String, Set<String>> _waveformChannels = {};

  Set<String> waveformChannels(String nodeId) {
    if (_waveformChannels.containsKey(nodeId)) {
      return _waveformChannels[nodeId]!;
    }
    if (graph.connectionAt(nodeId, 'in_mono') != null) {
      return _waveformChannels[nodeId] = {'y'};
    }
    return _waveformChannels[nodeId] = {'r', 'g', 'b'};
  }

  /// 播放中各预览节点的 GPU 平面帧（非空时优先于 [previewImages] 显示；
  /// 同帧所有节点共享一张打包纹理）。
  Map<String, PlanePreviewFrame> previewPlanes = {};

  /// yuv_planes.frag 着色器实例（GPU 平面预览播放时加载；失败回退 CPU）。
  ui.FragmentShader? yuvPlaneShader;

  /// 释放共享打包纹理并清空平面预览（换帧/单次运行时调用）。
  void _clearPlanePreviews() {
    if (previewPlanes.isNotEmpty) {
      previewPlanes.values.first.packed.dispose();
      previewPlanes = {};
    }
  }

  /// 预览节点的 GPU 平面模式：1/2/3 = Y/U/V 平面灰度（in_mono 追溯到
  /// 源分路器的 out_y/out_u/out_v，中间可隔透传预览）；0 = 彩色
  /// （输入为视频源 out_yuv 直连，或输入可证明恒等的 YUV 合路器）。
  /// 无法证明时返回 null（整体回退 CPU 流水线出图）。
  int? _previewPlaneMode(String previewId, [int depth = 0]) {
    if (depth > 8) return null;
    final node = graph.nodes[previewId];
    if (node == null || node.typeId != 'preview') return null;
    final monoConn = graph.connectionAt(previewId, 'in_mono');
    if (monoConn != null) {
      final plane =
          _resolveSplitterPlane(monoConn.fromNodeId, monoConn.fromPort, 0);
      return plane == null ? null : plane + 1;
    }
    final conn = graph.connectionAt(previewId, 'in_yuv') ??
        graph.connectionAt(previewId, 'in');
    if (conn == null) return null;
    final up = graph.nodes[conn.fromNodeId];
    if (up == null) return null;
    if (up.typeId == 'video_source' && conn.fromPort == 'out_yuv') return 0;
    if (up.typeId == 'yuv_combiner' && conn.fromPort == 'out') {
      return _combinerIsPlaneIdentity(conn.fromNodeId) ? 0 : null;
    }
    if (up.typeId == 'preview') {
      return _previewPlaneMode(conn.fromNodeId, depth + 1);
    }
    return null;
  }

  /// 追溯 [nodeId] 的 [port] 输出是否源于 YUV 分路器的某个平面
  /// （中间允许隔透传预览），是则返回平面序号（0/1/2），否则 null。
  int? _resolveSplitterPlane(String nodeId, String port, int depth) {
    if (depth > 8) return null;
    final node = graph.nodes[nodeId];
    if (node == null) return null;
    if (node.typeId == 'yuv_splitter') {
      return switch (port) {
        'out_y' => 0,
        'out_u' => 1,
        'out_v' => 2,
        _ => null,
      };
    }
    if (node.typeId == 'preview') {
      final conn = graph.connectionAt(nodeId, 'in_mono') ??
          graph.connectionAt(nodeId, 'in_yuv') ??
          graph.connectionAt(nodeId, 'in');
      if (conn == null) return null;
      return _resolveSplitterPlane(conn.fromNodeId, conn.fromPort, depth + 1);
    }
    return null;
  }

  /// YUV 合路器的三路输入是否分别源于同一分路器的 Y/U/V 平面
  /// （恒等合路：输出与源帧内容一致，平面轨道下共享引用）。
  bool _combinerIsPlaneIdentity(String combinerId) {
    for (final (inPort, expected) in [
      ('in_y', 0),
      ('in_u', 1),
      ('in_v', 2),
    ]) {
      final conn = graph.connectionAt(combinerId, inPort);
      if (conn == null) return false;
      if (_resolveSplitterPlane(conn.fromNodeId, conn.fromPort, 0) !=
          expected) {
        return false;
      }
    }
    return true;
  }

  /// 切换波形示波器节点某通道的显示（Y 与 R/G/B 互斥；关闭 Y 时 R/G/B 默认全开；当 R/G/B 全关时自动激活 Y）。
  void toggleWaveformChannel(String nodeId, String channel) {
    final set = waveformChannels(nodeId);
    if (channel == 'y') {
      if (set.contains('y')) {
        set.clear();
        set.addAll(['r', 'g', 'b']);
      } else {
        set.clear();
        set.add('y');
      }
    } else {
      if (set.contains('y')) {
        set.clear();
        set.add(channel);
      } else {
        if (set.contains(channel)) {
          set.remove(channel);
          if (set.isEmpty) {
            set.add('y');
          }
        } else {
          set.add(channel);
        }
      }
    }
    final result = instrumentResults[nodeId];
    if (result != null) {
      if (result['bmp'] is Uint8List) {
        // 播放中的 worker 预渲染结果不含计数表，无法本地重绘：
        // 刷新已不限频，下一批（最近一帧内）会按新通道组合出图。
      } else {
        // 异步解码完成后必须递增 instrumentTick：仪器附加区靠它局部
        // 重建；同步的 notifyListeners 触发重建时新图还没解码好，
        // 少了这一步显示会停在旧通道组合上，直到下次刷新/缩放。
        unawaited(_updateInstrumentImage(nodeId, result).then((_) {
          instrumentTick.value++;
        }));
      }
    }
    notifyListeners();
  }


  /// 一次节点尺寸拖动的累计位移（beginNodeResize 清零）：用于判断
  /// 主拖动方向，决定比例适配时哪一维跟随另一维。
  Offset _resizeDragAcc = Offset.zero;

  /// 节点显示区内容的长宽比（内容区宽/高）；null 表示内容自适应填充
  /// 或尚无运行结果（不约束）。供拖动调整尺寸时对齐内容比例。
  double? _displayContentAspect(IspNode node) {
    switch (node.typeId) {
      case 'preview':
        final img = previewImages[node.id];
        if (img != null && img.height > 0) return img.width / img.height;
        final plane = previewPlanes[node.id];
        if (plane != null && plane.height > 0) {
          return plane.width / plane.height;
        }
        return null;
      case 'rgb_debugger':
      case 'yuv_debugger':
      case 'sat_bright_adjuster':
      case 'color_balance':
      case 'color_temp_adjuster':
      case 'edge_extract':
        // 双联对比图（左调整前/右调整后），每格内容为图像本身。
        final img = previewImages[node.id] ?? previewInputImages[node.id];
        if (img != null && img.height > 0) return 2.0 * img.width / img.height;
        return null;
      case 'hsl_debugger':
        return 2.0; // 双联方形矢量示波器
      case 'levels_curves':
      case 'vectorscope':
        return 1.0; // 方形内容区（曲线编辑器 / 矢量示波器）
      default:
        return null; // 波形/直方图/音频仪器等自适应填充，无固定比例
    }
  }

  /// 显示区的固定装饰开销（横向内边距，纵向控制条/滑块行/手柄等）：
  /// 内容区 = (node.width − w) × (extraHeight − h)。
  /// 双窗格类型的横向开销含两格之间 4px 间隔。
  static (double, double) _displayChrome(String typeId) => switch (typeId) {
        'preview' => (16.0, 40.0), // 横 8+8；纵 4+控制条 26+手柄 10
        'rgb_debugger' ||
        'yuv_debugger' ||
        'hsl_debugger' ||
        'color_balance' =>
          (20.0, 86.0), // 横 8+4+8；纵 4+滑块 24*3+手柄 10
        'sat_bright_adjuster' => (20.0, 62.0), // 滑块 24*2
        'edge_extract' => (20.0, 62.0), // 滑块 24*2
        'color_temp_adjuster' => (20.0, 126.0), // 温度行 24+滑块 24+底行 64
        _ => (16.0, 14.0), // levels_curves/vectorscope：纵 4+手柄 10
      };

  void beginNodeResize(String nodeId) {
    _resizeDragAcc = Offset.zero;
  }

  void resizeNodeBy(String nodeId, Offset delta) {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    final type = IspNodeRegistry.byId(node.typeId);

    // Snap the absolute right edge: rightX = node.x + width → snap rightX.
    final oldRight = node.x + node.width;
    final snappedRight = snapToGrid(oldRight + delta.dx);
    var newWidth = (snappedRight - node.x)
        .clamp(kMinPreviewNodeWidth, maxNodeWidthFor(node.typeId));

    // Snap the absolute bottom edge: bottomY = node.y + baseHeight + extraHeight.
    // Snapping only extraHeight fails when baseHeight is not a multiple of the grid.
    final oldExtra = previewExtraHeight(nodeId);
    final baseHeight = type != null ? nodeHeight(type, previewExtraHeight: 0) : 0.0;
    final oldBottom = node.y + baseHeight + oldExtra;
    final snappedBottom = snapToGrid(oldBottom + delta.dy);
    var newExtra = (snappedBottom - node.y - baseHeight)
        .clamp(kMinPreviewExtraHeight, kMaxPreviewExtraHeight);

    // 内容比例适配：显示内容有固定长宽比时，非主拖动维自动跟随，
    // 使内容区恰好匹配内容比例，消除显示区留白（提高画布利用率）。
    // 主方向按本次拖动的累计位移判断；比例适配优先于网格吸附。
    final aspect = _displayContentAspect(node);
    if (aspect != null) {
      _resizeDragAcc += delta;
      final (chromeW, chromeH) = _displayChrome(node.typeId);
      if (_resizeDragAcc.dx.abs() >= _resizeDragAcc.dy.abs()) {
        // 横向为主：高度跟随宽度。
        newExtra = ((newWidth - chromeW) / aspect + chromeH)
            .clamp(kMinPreviewExtraHeight, kMaxPreviewExtraHeight);
      } else {
        // 纵向为主（中部手柄恒为纵向）：宽度跟随高度。
        newWidth = ((newExtra - chromeH) * aspect + chromeW)
            .clamp(kMinPreviewNodeWidth, maxNodeWidthFor(node.typeId));
      }
    }

    node.width = newWidth;
    node.extraHeight = newExtra;
    _previewExtraHeights[nodeId] = newExtra;
    notifyListeners();
  }

  void endNodeResize() {}

  void selectNode(String? id, {bool multiSelect = false}) {
    // 编组联动：点选组内任一成员等同于选中/取消整组。
    final gid = id == null ? null : groupIdOf(id);
    final members = gid == null
        ? null
        : graph.groups.firstWhere((g) => g.id == gid).nodeIds;
    if (id == null) {
      selectedNodeIds.clear();
      selectedNodeId = null;
    } else if (multiSelect) {
      if (members != null) {
        if (members.every(selectedNodeIds.contains)) {
          selectedNodeIds.removeWhere(members.contains);
        } else {
          for (final m in members) {
            if (!selectedNodeIds.contains(m)) selectedNodeIds.add(m);
          }
        }
      } else if (selectedNodeIds.contains(id)) {
        selectedNodeIds.remove(id);
      } else {
        selectedNodeIds.add(id);
      }
      selectedNodeId = selectedNodeIds.firstOrNull;
    } else {
      selectedNodeIds.clear();
      if (members != null) {
        selectedNodeIds.addAll(members);
      } else {
        selectedNodeIds.add(id);
      }
      selectedNodeId = id;
    }
    selectedConnectionId = null;
    selectedConnectionIds.clear();
    notifyListeners();
  }

  /// 选中汇点链路：该链（compileChain 实际编译结果）上的全部节点与
  /// 连线一并选中高亮（右侧流程摘要点击链路时调用）。链不可编译
  /// （缺源/多源/环等）时无操作。
  void selectChain(String sinkNodeId) {
    final List<Map<String, Object?>> chain;
    try {
      chain = compileChain(graph, sinkNodeId);
    } catch (_) {
      return;
    }
    final ids = {for (final op in chain) op['nodeId'] as String};
    selectedNodeIds
      ..clear()
      ..addAll(ids);
    selectedNodeId = sinkNodeId;
    selectedConnectionId = null;
    selectedConnectionIds
      ..clear()
      ..addAll([
        for (final c in graph.connections)
          if (ids.contains(c.fromNodeId) && ids.contains(c.toNodeId)) c.id,
      ]);
    notifyListeners();
  }

  /// 节点所属编组 id；未编组返回 null。
  String? groupIdOf(String nodeId) {
    for (final g in graph.groups) {
      if (g.nodeIds.contains(nodeId)) return g.id;
    }
    return null;
  }

  /// 把当前多选节点编为一组。一个节点至多属于一个组：成员先从
  /// 旧组摘除，旧组剩余不足 2 个节点时自动解散。
  /// [name] 缺省时自动生成「编组#N」。
  void groupSelectedNodes({String? name}) {
    final members =
        selectedNodeIds.where((id) => graph.nodes.containsKey(id)).toSet();
    if (members.length < 2) return;
    for (final g in graph.groups) {
      g.nodeIds.removeAll(members);
    }
    graph.groups.removeWhere((g) => g.nodeIds.length < 2);
    graph.groups.add(IspNodeGroup('g${graph.nextId++}', members,
        name: name ?? graph.uniqueGroupName()));
    notifyListeners();
  }

  /// 重命名编组。
  void renameGroup(String groupId, String name) {
    for (final g in graph.groups) {
      if (g.id == groupId) {
        g.name = name;
        notifyListeners();
        return;
      }
    }
  }

  /// 解散指定编组。
  void ungroup(String groupId) {
    final before = graph.groups.length;
    graph.groups.removeWhere((g) => g.id == groupId);
    if (graph.groups.length != before) notifyListeners();
  }

  void updateBoxSelection(Offset start, Offset end, {bool multiSelect = false}) {
    final rect = Rect.fromPoints(start, end);
    selectionBoxRect = rect;
    final touched = <String>[];
    for (final node in graph.nodes.values) {
      final type = IspNodeRegistry.byId(node.typeId);
      final h = type != null ? nodeHeight(type, previewExtraHeight: previewExtraHeight(node.id)) : 100.0;
      final nodeRect = Rect.fromLTWH(node.x, node.y, node.width, h);
      if (rect.overlaps(nodeRect)) {
        touched.add(node.id);
      }
    }
    if (!multiSelect) {
      selectedNodeIds.clear();
    }
    for (final id in touched) {
      if (!selectedNodeIds.contains(id)) {
        selectedNodeIds.add(id);
      }
    }
    selectedNodeId = selectedNodeIds.firstOrNull;
    notifyListeners();
  }

  void endBoxSelection() {
    selectionBoxRect = null;
    notifyListeners();
  }

  void resizePreview(String nodeId, dynamic arg1, [double? extraHeight]) {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    if (arg1 is Offset) {
      resizeNodeBy(nodeId, arg1);
    } else if (arg1 is num && extraHeight != null) {
      node.width = arg1
          .toDouble()
          .clamp(kMinPreviewNodeWidth, maxNodeWidthFor(node.typeId));
      final clampedH = extraHeight.clamp(kMinPreviewExtraHeight, kMaxPreviewExtraHeight);
      node.extraHeight = clampedH;
      _previewExtraHeights[nodeId] = clampedH;
      notifyListeners();
    }
  }

  void alignNodes(IspAlignMode mode) {
    final targetIds = selectedNodeIds.length >= 2
        ? selectedNodeIds
        : graph.nodes.keys.toList();
    if (targetIds.isEmpty) return;

    final targetNodes = targetIds
        .map((id) => graph.nodes[id])
        .whereType<IspNode>()
        .toList();
    if (targetNodes.isEmpty) return;

    switch (mode) {
      case IspAlignMode.left:
        final minX = targetNodes.map((n) => n.x).reduce(math.min);
        for (final n in targetNodes) {
          n.x = snapToGrid(minX);
        }
      case IspAlignMode.right:
        final maxX = targetNodes.map((n) => n.x + n.width).reduce(math.max);
        for (final n in targetNodes) {
          n.x = snapToGrid(maxX - n.width);
        }
      case IspAlignMode.horizontalCenter:
        final minX = targetNodes.map((n) => n.x).reduce(math.min);
        final maxX = targetNodes.map((n) => n.x + n.width).reduce(math.max);
        final centerX = (minX + maxX) / 2;
        for (final n in targetNodes) {
          n.x = snapToGrid(centerX - n.width / 2);
        }
      case IspAlignMode.top:
        final minY = targetNodes.map((n) => n.y).reduce(math.min);
        for (final n in targetNodes) {
          n.y = snapToGrid(minY);
        }
      case IspAlignMode.bottom:
        final maxY = targetNodes
            .map((n) =>
                n.y +
                nodeHeight(IspNodeRegistry.byId(n.typeId)!,
                    previewExtraHeight: previewExtraHeight(n.id)))
            .reduce(math.max);
        for (final n in targetNodes) {
          final h = nodeHeight(IspNodeRegistry.byId(n.typeId)!,
              previewExtraHeight: previewExtraHeight(n.id));
          n.y = snapToGrid(maxY - h);
        }
      case IspAlignMode.verticalCenter:
        final minY = targetNodes.map((n) => n.y).reduce(math.min);
        final maxY = targetNodes
            .map((n) =>
                n.y +
                nodeHeight(IspNodeRegistry.byId(n.typeId)!,
                    previewExtraHeight: previewExtraHeight(n.id)))
            .reduce(math.max);
        final centerY = (minY + maxY) / 2;
        for (final n in targetNodes) {
          final h = nodeHeight(IspNodeRegistry.byId(n.typeId)!,
              previewExtraHeight: previewExtraHeight(n.id));
          n.y = snapToGrid(centerY - h / 2);
        }
      case IspAlignMode.distributeHorizontal:
        if (targetNodes.length <= 2) break;
        targetNodes.sort((a, b) => a.x.compareTo(b.x));
        final first = targetNodes.first;
        final last = targetNodes.last;
        final totalWidthSum =
            targetNodes.map((n) => n.width).reduce((a, b) => a + b);
        final totalSpan = (last.x + last.width) - first.x;
        final gap = (totalSpan - totalWidthSum) / (targetNodes.length - 1);
        var currX = first.x;
        for (var i = 0; i < targetNodes.length; i++) {
          final n = targetNodes[i];
          n.x = snapToGrid(currX);
          currX += n.width + gap;
        }
      case IspAlignMode.distributeVertical:
        if (targetNodes.length <= 2) break;
        targetNodes.sort((a, b) => a.y.compareTo(b.y));
        final first = targetNodes.first;
        final last = targetNodes.last;
        final totalHeightSum = targetNodes
            .map((n) => nodeHeight(IspNodeRegistry.byId(n.typeId)!,
                previewExtraHeight: previewExtraHeight(n.id)))
            .reduce((a, b) => a + b);
        final totalSpan = (last.y + nodeHeight(IspNodeRegistry.byId(last.typeId)!, previewExtraHeight: previewExtraHeight(last.id))) - first.y;
        final gap = (totalSpan - totalHeightSum) / (targetNodes.length - 1);
        var currY = first.y;
        for (var i = 0; i < targetNodes.length; i++) {
          final n = targetNodes[i];
          final h = nodeHeight(IspNodeRegistry.byId(n.typeId)!,
              previewExtraHeight: previewExtraHeight(n.id));
          n.y = snapToGrid(currY);
          currY += h + gap;
        }
    }
    notifyListeners();
  }

  void matchSelectedNodesSize() {
    final primaryId = primarySelectedNodeId;
    if (primaryId == null) return;
    final primaryNode = graph.nodes[primaryId];
    if (primaryNode == null) return;
    final w = primaryNode.width;
    final h = previewExtraHeight(primaryId);
    for (final id in selectedNodeIds) {
      if (id == primaryId) continue;
      final n = graph.nodes[id];
      if (n != null) {
        n.width = w;
        n.extraHeight = h;
        _previewExtraHeights[id] = h;
      }
    }
    notifyListeners();
  }

  void matchSelectedNodesWidth() {
    final primaryId = primarySelectedNodeId;
    if (primaryId == null) return;
    final primaryNode = graph.nodes[primaryId];
    if (primaryNode == null) return;
    final w = primaryNode.width;
    for (final id in selectedNodeIds) {
      if (id == primaryId) continue;
      final n = graph.nodes[id];
      if (n != null) {
        n.width = w;
      }
    }
    notifyListeners();
  }

  void matchSelectedNodesHeight() {
    final primaryId = primarySelectedNodeId;
    if (primaryId == null) return;
    final primaryNode = graph.nodes[primaryId];
    if (primaryNode == null) return;
    final h = previewExtraHeight(primaryId);
    for (final id in selectedNodeIds) {
      if (id == primaryId) continue;
      final n = graph.nodes[id];
      if (n != null) {
        n.extraHeight = h;
        _previewExtraHeights[id] = h;
      }
    }
    notifyListeners();
  }

  void selectConnection(String? id) {
    if (selectedConnectionId != id) {
      selectedConnectionId = id;
      if (id != null) {
        selectedNodeId = null;
        selectedNodeIds.clear();
      }
      selectedConnectionIds.clear();
      notifyListeners();
    }
  }

  /// 选中连接被级联删除（如删节点）时清掉选中态。
  void _clearStaleConnectionSelection() {
    final id = selectedConnectionId;
    if (id != null && !graph.connections.any((c) => c.id == id)) {
      selectedConnectionId = null;
    }
    if (selectedConnectionIds.isNotEmpty) {
      selectedConnectionIds
          .removeWhere((cid) => !graph.connections.any((c) => c.id == cid));
    }
  }

  void moveNode(String id, Offset delta) {
    // 多选同步拖动：被拖节点在拖动组内时整组移动，各节点独立做
    // 亚像素累积与网格吸附（起始均在网格上，相对位置保持不变）。
    final group = _dragGroupIds.length > 1 && _dragGroupIds.contains(id)
        ? _dragGroupIds
        : {id};
    for (final gid in group) {
      final node = graph.nodes[gid];
      if (node == null) continue;
      if (_nodeDragAccum.containsKey(gid)) {
        // Accumulate sub-pixel delta during drag; snap whole position to grid.
        final accum = _nodeDragAccum[gid]! + delta;
        final targetX = node.x + accum.dx;
        final targetY = node.y + accum.dy;
        final snappedX = snapToGrid(targetX);
        final snappedY = snapToGrid(targetY);
        // Only count what we actually moved; leave the remainder in accum.
        final movedDx = snappedX - node.x;
        final movedDy = snappedY - node.y;
        _nodeDragAccum[gid] = Offset(accum.dx - movedDx, accum.dy - movedDy);
        node.x = snappedX;
        node.y = snappedY;
      } else {
        node.x += delta.dx;
        node.y += delta.dy;
      }
    }
    notifyListeners();
  }

  void setParam(String nodeId, String key, Object? value) {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    node.paramValues[key] = value;
    totalFrames = null; // 源参数可能变了
    nodeOutputCaptures = {};
    nodeRunTimesUs = {}; // 运行值已过期
    nodeRunOnGpu = {}; // 同上
    notifyListeners();
    // RAW 源设置了文件路径：DNG 解析文件头自动填充尺寸/位深/排列/
    // 黑电平；普通 RAW 尝试从同名 txt 自动填充尺寸与黑电平。
    if (key == 'filePath' &&
        rawSourceTypes.contains(node.typeId) &&
        value is String &&
        value.isNotEmpty) {
      if (isDngPath(value)) {
        autoFillFromDng(nodeId); // 异步，失败弹状态栏消息
      } else {
        autoFillFromSidecar(nodeId); // 异步，失败静默
      }
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
      nodeOutputCaptures = {};
    nodeRunTimesUs = {}; // 运行值已过期
    nodeRunOnGpu = {}; // 同上
      statusMessage =
          '已从 ${p.basename(p.setExtension(rawPath, '.txt'))} 读取参数'
          '${w != null && h != null ? '（${w}x$h）' : ''}';
      notifyListeners();
    }
  }

  /// 读取 RAW 源节点文件路径对应的 DNG 文件头：把宽度/高度/位深/
  /// Bayer 排列/字节序填入源节点参数，黑电平（按 CFA 相位映射为
  /// R/Gr/Gb/B）填入该源下游的所有黑电平校正节点。
  /// 解析失败时在状态栏提示原因（不支持的压缩/Tile/位深等）。
  Future<void> autoFillFromDng(String sourceId) async {
    final node = graph.nodes[sourceId];
    if (node == null) return;
    final path = node.paramValues['filePath']?.toString() ?? '';
    if (path.isEmpty) return;
    DngInfo info;
    try {
      info = await readDngInfo(path);
    } catch (e) {
      statusMessage = 'DNG 解析失败: ${e.toString().replaceFirst('Bad state: ', '')}';
      notifyListeners();
      return;
    }
    var changed = false;
    void setIfPresent(String key, Object? value) {
      if (node.paramValues.containsKey(key) && node.paramValues[key] != value) {
        node.paramValues[key] = value;
        changed = true;
      }
    }

    setIfPresent('width', info.width);
    setIfPresent('height', info.height);
    setIfPresent('bitDepth', '${info.bitDepth}');
    setIfPresent('packing', 'unpacked_lsb');
    setIfPresent('littleEndian', info.littleEndian);
    if (info.cfaPattern != null) setIfPresent('bayerPattern', info.cfaPattern);

    // 黑电平（2x2 相位行主序）→ R/Gr/Gb/B：相位 0=(0,0)、1=(0,1)、
    // 2=(1,0)、3=(1,1)；G 在第 0 行为 Gr、第 1 行为 Gb。
    final levels = info.blackLevels;
    final colors = info.cfaColors;
    if (levels != null && colors != null) {
      double? r, gr, gb, b;
      for (var i = 0; i < 4; i++) {
        final color = colors[i];
        final v = levels[i];
        if (color == 0) {
          r = v;
        } else if (color == 2) {
          b = v;
        } else if (i < 2) {
          gr = v;
        } else {
          gb = v;
        }
      }
      if (r != null && gr != null && gb != null && b != null) {
        for (final e in graph.nodes.entries) {
          if (e.value.typeId != 'black_level') continue;
          if (!graph.upstreamOf(e.key).contains(sourceId)) continue;
          e.value.paramValues['r'] = r;
          e.value.paramValues['gr'] = gr;
          e.value.paramValues['gb'] = gb;
          e.value.paramValues['b'] = b;
          changed = true;
        }
      }
    }
    if (changed) {
      totalFrames = null; // 单帧字节数变了
      nodeOutputCaptures = {};
      nodeRunTimesUs = {}; // 运行值已过期
      nodeRunOnGpu = {}; // 同上
      var lensNote = '';
      if (info.gainMaps.isNotEmpty) {
        lensNote = '，镜头阴影校正表已加载（解码时自动应用）';
      }
      if (info.warp != null && !info.warp!.isIdentity) {
        lensNote += '，畸变校正参数暂未应用';
      }
      statusMessage = '已从 ${p.basename(path)} 读取参数'
          '（${info.width}x${info.height} ${info.bitDepth}bit'
          '${info.cfaPattern != null ? ' ${info.cfaPattern}' : ''}）$lensNote';
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
    if (error == null) {
      nodeOutputCaptures = {};
    nodeRunTimesUs = {}; // 连接变了，运行值已过期
      nodeRunOnGpu = {}; // 同上
      _instrumentSrcCache.clear();
      final type = graph.nodes[toNodeId]?.typeId;
      if (type == 'histogram' || type == 'waveform') {
        if (toPort == 'in_mono') {
          _histogramChannels[toNodeId] = {'y'};
          _waveformChannels[toNodeId] = {'y'};
        } else if (toPort == 'in' || toPort == 'in_yuv' || toPort == 'in_hsl') {
          _histogramChannels[toNodeId] = {'r', 'g', 'b'};
          _waveformChannels[toNodeId] = {'r', 'g', 'b'};
        }
      }
    }
    notifyListeners();
    return error;
  }

  void disconnectInput(String nodeId, String port) {
    graph.disconnectInput(nodeId, port);
    nodeOutputCaptures = {};
    nodeRunTimesUs = {};
    nodeRunOnGpu = {};
    _instrumentSrcCache.clear();
    _clearStaleConnectionSelection();
    notifyListeners();
  }

  /// 按连接 id 断开（连线中点控制点、Delete 键走这里）。
  void removeConnection(String connectionId) {
    graph.disconnect(connectionId);
    nodeOutputCaptures = {};
    nodeRunTimesUs = {};
    nodeRunOnGpu = {};
    _instrumentSrcCache.clear();
    if (selectedConnectionId == connectionId) selectedConnectionId = null;
    notifyListeners();
  }

  // ---- 执行 ----

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

  /// GPU 快路径：从可编译预览链中选最长的 GPU 支持链单次执行，
  /// 其余「链为其前缀」的预览节点经 displayCaptures 顺带捕获出图，
  /// 已连接仪器经 RGBA 回读端口馈源。返回被覆盖的 key（预览节点 id
  /// 及 'id#in' 输入链 key），调用方跳过这些链的 CPU 执行。
  /// 任何失败抛异常，由调用方整体回退 CPU。
  Future<Set<String>> _tryGpuPreview(
    Map<String, List<Map<String, Object?>>> chains,
    Map<String, List<Map<String, Object?>>> inputChains,
    int frame,
    void Function(String nodeId)? onNodeStart, {
    Map<String, (Uint8List, int, int)> imageSources = const {},
  }) async {
    final gpu = await _gpuPipeline();
    if (gpu == null) return const {};
    // 透传汇点（preview/histogram）不参与处理比对：其显示 = 前一节点
    // 输出帧的默认色调映射；调节器汇点的显示 = 自身输出。覆盖判定见
    // 顶层函数 gpuChainPrefixCovered（含侧向输入端口约束）。

    // GPU 主链集合：全部 GPU 支持链按链长降序，未被已选主链前缀覆盖
    // 的各自作为主链独立执行——多源/多分支流程（如 ICG 荧光融合的
    // 融合预览链 + 伪彩预览链）可多条链全 GPU；同源分叉链的共享前缀
    // 节点会重复执行，产物等价、以耗时换通用性。
    final candidates = [
      for (final e in chains.entries)
        if (GpuPipeline.isSupportedChain(e.value)) e,
    ]..sort((a, b) => b.value.length - a.value.length);
    if (candidates.isEmpty) return const {};
    final covered = <String>{};
    // 链 key → 覆盖它的主链 sink：选择阶段只定归属，displayCaptures/
    // 馈源等覆盖产物在各自主链的执行阶段生成。
    final coveredBy = <String, String>{};
    final mains = <MapEntry<String, List<Map<String, Object?>>>>[];
    for (final e in candidates) {
      if (coveredBy.containsKey(e.key)) continue;
      mains.add(e);
      final ids = [for (final op in e.value) op['nodeId'] as String];
      for (final o in candidates) {
        if (o.key == e.key || coveredBy.containsKey(o.key)) continue;
        if (gpuChainPrefixCovered(o.value, ids)) coveredBy[o.key] = e.key;
      }
    }

    // 单条主链的执行与产物合并（多主链时逐条调用）。
    Future<void> runMainChain(
        String mainSink, List<Map<String, Object?>> mainChain) async {
      final mainIds = [for (final op in mainChain) op['nodeId'] as String];
      // GPU 主链节点的执行后端标记（供右侧面板流程摘要显示）。
      for (final id in mainIds) {
        nodeRunOnGpu[id] = true;
      }
      covered.add(mainSink);

      final displayCaptures = <String, String>{};
      for (final e in chains.entries) {
        if (e.key == mainSink || coveredBy[e.key] != mainSink) continue;
        if (!gpuChainPrefixCovered(e.value, mainIds)) continue;
        final last = e.value.last;
        final sinkId = last['nodeId'] as String;
        // 汇点预览本身是主链中间节点（分支出图，如分路器后的单通道预览，
        // 其输入不是主帧）时，捕获点设在预览节点自身——GPU 执行到该节点
        // 时 frame 正是其输入帧；否则捕获处理链末端（主帧即汇点输入，
        // 与在汇点捕获等价；输入来自侧向端口的汇点已在
        // gpuChainPrefixCovered 中拒绝覆盖，不会走到这里）。
        final isPassthroughSink =
            last['typeId'] == 'preview' || last['typeId'] == 'histogram';
        displayCaptures[e.key] = isPassthroughSink && mainIds.contains(sinkId)
            ? sinkId
            : gpuProcChainOf(e.value).last['nodeId'] as String;
        covered.add(e.key);
        // 前缀覆盖链的出图同样由 GPU 主链顺带产生：汇点预览标记 GPU 后端，
        // 避免「不在主链又跳过 CPU」导致后端/耗时栏空白。
        nodeRunOnGpu[sinkId] = true;
      }
      for (final e in inputChains.entries) {
        final inKey = '${e.key}#in';
        // 输入链不参与主链竞选：第一个能前缀覆盖它的主链认领。
        if (coveredBy[inKey] != null && coveredBy[inKey] != mainSink) continue;
        if (!gpuChainPrefixCovered(e.value, mainIds)) continue;
        displayCaptures[inKey] =
            gpuProcChainOf(e.value).last['nodeId'] as String;
        coveredBy[inKey] = mainSink;
        covered.add(inKey);
      }
      // 仪器馈源回读端口（指向主链节点的连接）。
      final readbackPorts = <String>{};
      final mainIdSet = mainIds.toSet();
      for (final node in graph.nodes.values) {
        if (!allInstrumentTypes.contains(node.typeId) ||
            audioInstrumentTypes.contains(node.typeId)) {
          continue;
        }
        final type = IspNodeRegistry.byId(node.typeId)!;
        for (final spec in type.inputs) {
          final conn = graph.connectionAt(node.id, spec.name);
          if (conn != null && mainIdSet.contains(conn.fromNodeId)) {
            readbackPorts.add('${conn.fromNodeId}:${conn.fromPort}');
          }
        }
      }
      // HSL 调节器矢量示波器馈源：被 GPU 覆盖的 hsl_debugger 节点不再走
      // CPU 闭包（其矢量图在那里由链末端 RGBA 统计），此处对其自身输出
      // 与输入链末端端口做同样的 RGBA 回读，运行后据此渲染矢量图。
      // 键为回读端口 'nodeId:port'，值为目标缓存 key（节点 id = 调整后，
      // 'id#in' = 调整前）。
      final hslScopeFeeds = <String, String>{};
      for (final node in graph.nodes.values) {
        if (node.typeId != 'hsl_debugger') continue;
        if (covered.contains(node.id) || node.id == mainSink) {
          final key = '${node.id}:out';
          readbackPorts.add(key);
          hslScopeFeeds[key] = node.id;
        }
        if (covered.contains('${node.id}#in')) {
          final conn = graph.connectionAt(node.id, 'in');
          if (conn != null && mainIdSet.contains(conn.fromNodeId)) {
            final key = '${conn.fromNodeId}:${conn.fromPort}';
            readbackPorts.add(key);
            hslScopeFeeds[key] = '${node.id}#in';
          }
        }
      }
      // 曲线调节器馈源（链被 GPU 覆盖时不走 CPU 闭包，回读补齐）：
      // 输入链末端端口 → 输入 Y 直方图；自身输出端口 → 调整后 Y 直方图
      // （与 CPU 闭包同一口径，均为 histogramRgb 的第 4 路）。
      final levelsHistFeeds = <String, String>{}; // 'nodeId:port' -> 节点 id
      final levelsOutFeeds = <String, String>{}; // 同上，自身输出端口
      for (final node in graph.nodes.values) {
        if (node.typeId != 'levels_curves') continue;
        if (covered.contains('${node.id}#in')) {
          final conn = graph.connectionAt(node.id, 'in');
          if (conn != null && mainIdSet.contains(conn.fromNodeId)) {
            final key = '${conn.fromNodeId}:${conn.fromPort}';
            readbackPorts.add(key);
            levelsHistFeeds[key] = node.id;
          }
        }
        if (covered.contains(node.id) || node.id == mainSink) {
          final key = '${node.id}:out';
          readbackPorts.add(key);
          levelsOutFeeds[key] = node.id;
        }
      }
      // 色温调节器馈源：链被 GPU 覆盖时不走 CPU 闭包（测量/调整后直方图
      // 在那里由链 RGBA 统计），此处回读上游端口（色温测量）与自身输出
      // 端口（调整后 RGB 直方图）补齐。
      final colorTempFeeds = <String, String>{}; // 'nodeId:port' -> 节点 id
      final colorTempOutFeeds = <String, String>{}; // 同上，自身输出端口
      for (final node in graph.nodes.values) {
        if (node.typeId != 'color_temp_adjuster') continue;
        if (covered.contains('${node.id}#in')) {
          final conn = graph.connectionAt(node.id, 'in');
          if (conn != null && mainIdSet.contains(conn.fromNodeId)) {
            final key = '${conn.fromNodeId}:${conn.fromPort}';
            readbackPorts.add(key);
            colorTempFeeds[key] = node.id;
          }
        }
        if (covered.contains(node.id) || node.id == mainSink) {
          final key = '${node.id}:out';
          readbackPorts.add(key);
          colorTempOutFeeds[key] = node.id;
        }
      }
      // 亮度/对比度调节器波形馈源：同理——GPU 覆盖时其双联波形（左
      // 调整前/右调整后）由 CPU 闭包统计，此处对输入连接端口与自身
      // 输出做 RGBA 回读补齐。键为回读端口，值为目标缓存 key（节点
      // id = 调整后，'id#in' = 调整前）。
      final brightContrastFeeds = <String, String>{};
      for (final node in graph.nodes.values) {
        if (node.typeId != 'bright_contrast_adjuster') continue;
        if (covered.contains('${node.id}#in')) {
          final conn = graph.connectionAt(node.id, 'in') ??
              graph.connectionAt(node.id, 'in_yuv') ??
              graph.connectionAt(node.id, 'in_hsl') ??
              graph.connectionAt(node.id, 'in_mono');
          if (conn != null && mainIdSet.contains(conn.fromNodeId)) {
            final key = '${conn.fromNodeId}:${conn.fromPort}';
            readbackPorts.add(key);
            brightContrastFeeds[key] = '${node.id}#in';
          }
        }
        if (covered.contains(node.id) || node.id == mainSink) {
          final key = '${node.id}:out';
          readbackPorts.add(key);
          brightContrastFeeds[key] = node.id;
        }
      }

      final result = await gpu.run(mainChain, frame,
          onNodeStart: onNodeStart,
          displayCaptures: displayCaptures,
          rgbaReadbackPorts: readbackPorts,
          imageSources: imageSources);

      // 产物合并：主图 + 捕获图 + 耗时 + 采样 + 仪器馈源。
      previewImages.remove(mainSink)?.dispose();
      previewImages[mainSink] = result.image;
      result.displayImages.forEach((key, img) {
        if (key.endsWith('#in')) {
          final base = key.substring(0, key.length - 3);
          previewInputImages.remove(base)?.dispose();
          previewInputImages[base] = img;
        } else {
          previewImages.remove(key)?.dispose();
          previewImages[key] = img;
        }
      });
      nodeRunTimesUs = {...nodeRunTimesUs, ...result.timingsUs};
      // 采样覆盖主链全部节点（CPU 路径仅首预览链有 captures，此为超集；
      // 多主链时逐链合并）。
      nodeOutputCaptures = {...nodeOutputCaptures, ...result.captures};
      result.portRgba.forEach((key, rgba) {
        final sep = key.indexOf(':');
        final entry = nodeOutputCaptures.putIfAbsent(key.substring(0, sep), () => {});
        entry[key.substring(sep + 1)] = {
          'data': rgba,
          'width': result.width,
          'height': result.height,
        };
      });
      // HSL 调节器矢量示波器：由回读 RGBA 统计 Cb/Cr 并渲染成图
      // （与 CPU 闭包同一渲染口径）。统计走仪器 worker 池（降采样 +
      // 后台 isolate）；Future 创建即启动，先全部发出再逐个收取。
      final hslScopeJobs = <(String, Future<ui.Image?>)>[
        for (final e in hslScopeFeeds.entries)
          if (result.portRgba[e.key] != null)
            (e.value,
                _hslVectorscopeImage(
                    result.portRgba[e.key]!, result.width, result.height)),
      ];
      for (final (target, job) in hslScopeJobs) {
        final img = await job;
        if (img == null) continue;
        if (target.endsWith('#in')) {
          final base = target.substring(0, target.length - 3);
          hslInputVectorscopes.remove(base)?.dispose();
          hslInputVectorscopes[base] = img;
        } else {
          hslVectorscopes.remove(target)?.dispose();
          hslVectorscopes[target] = img;
        }
      }
      // 曲线调节器：回读 RGBA 统计输入 Y 直方图（与 CPU 闭包同一口径）。
      for (final e in levelsHistFeeds.entries) {
        final rgba = result.portRgba[e.key];
        if (rgba == null) continue;
        final src = result.width > 64 && result.height > 64
            ? downsampleRgba82x(rgba, result.width, result.height)
            : (rgba, result.width, result.height);
        levelsHistograms[e.value] = histogramRgb(src.$1).$4;
      }
      // 曲线调节器：自身输出端口回读统计调整后 Y 直方图（同一口径）。
      for (final e in levelsOutFeeds.entries) {
        final rgba = result.portRgba[e.key];
        if (rgba == null) continue;
        final src = result.width > 64 && result.height > 64
            ? downsampleRgba82x(rgba, result.width, result.height)
            : (rgba, result.width, result.height);
        levelsOutputHistograms[e.value] = histogramRgb(src.$1).$4;
      }
      // 色温调节器：回读 RGBA 估计输入色温（与 CPU 闭包同一口径）。
      for (final e in colorTempFeeds.entries) {
        final rgba = result.portRgba[e.key];
        if (rgba == null) continue;
        final src = result.width > 64 && result.height > 64
            ? downsampleRgba82x(rgba, result.width, result.height)
            : (rgba, result.width, result.height);
        final m = measureCctFromRgba(src.$1, src.$2, src.$3);
        if (m != null) measuredColorTemps[e.value] = m;
      }
      // 色温调节器：自身输出端口回读统计调整后 RGB 直方图（同一口径）。
      for (final e in colorTempOutFeeds.entries) {
        final rgba = result.portRgba[e.key];
        if (rgba == null) continue;
        final src = result.width > 64 && result.height > 64
            ? downsampleRgba82x(rgba, result.width, result.height)
            : (rgba, result.width, result.height);
        final hr = histogramRgb(src.$1);
        colorTempHistograms[e.value] = (hr.$1, hr.$2, hr.$3);
      }
      // 亮度/对比度调节器：回读 RGBA 统计 Y 波形并渲染（与 CPU 闭包同一
      // 口径），补齐 GPU 覆盖链的双联示波器（右半调整后/左半调整前）。
      for (final e in brightContrastFeeds.entries) {
        final rgba = result.portRgba[e.key];
        if (rgba == null) continue;
        final img =
            await _brightWaveformImage(rgba, result.width, result.height);
        final target = e.value;
        if (target.endsWith('#in')) {
          final base = target.substring(0, target.length - 3);
          brightContrastInputWaveforms.remove(base)?.dispose();
          brightContrastInputWaveforms[base] = img;
        } else {
          brightContrastWaveforms.remove(target)?.dispose();
          brightContrastWaveforms[target] = img;
        }
      }
    }

    for (final me in mains) {
      await runMainChain(me.key, me.value);
    }
    return covered;
  }

  /// 亮度/对比度调节器的 Y 通道波形图（与 waveform 仪器同一口径；
  /// GPU 回读馈源使用，与 runPreview CPU 闭包的渲染路径一致）。
  Future<ui.Image> _brightWaveformImage(Uint8List rgba, int w, int h) {
    final (counts, cols) = waveformLuma(rgba, w, h);
    final wrgba = waveformIntensityRgba(
        {'counts': counts}, cols, kWaveformLevels, {'y'});
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(wrgba, cols, kWaveformLevels,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// HSL 调节器矢量示波器出图：与 vectorscope 仪器同一口径——先按步长
  /// 抽样把输入压到 ~240p 高（抗锯齿连线成本与像素数成正比，全帧 4K
  /// 在 UI isolate 上统计需数秒，降采样后统计视觉等效），分析放仪器
  /// worker 池（UI isolate 不做全帧扫描，多核隔行条带并行），并行
  /// 路径失败回退单 worker；亮度图优先用 worker 侧渲染的 bmp。
  Future<ui.Image?> _hslVectorscopeImage(Uint8List rgba, int w, int h) async {
    if (w <= 0 || h <= 0) return null;
    var src = rgba;
    var sw = w, sh = h;
    var step = 1;
    while (sh ~/ step > 240) {
      step *= 2;
    }
    if (step > 1) {
      (src, sw, sh) = downsampleRgba8Step(rgba, w, h, step);
    }
    Map<String, Object?> result;
    try {
      result = await _instrumentAnalyzer.analyzeVectorscopeParallel(src, sw, sh);
    } catch (_) {
      result =
          await _instrumentAnalyzer.analyzeDedicated(src, sw, sh, 'vectorscope');
    }
    var bmp = result['bmp'] as Uint8List?;
    if (bmp == null) {
      final counts = result['counts'] as Uint32List?;
      if (counts == null) return null;
      bmp = intensityRgba(
          counts, kVectorscopeSize, kVectorscopeSize, 70, 235, 70);
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(bmp, kVectorscopeSize, kVectorscopeSize,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// 运行所有有效预览节点并更新预览图（previewImages 映射 + 向后兼容的
  /// _legacyPreviewImage/previewImage 入口）。
  Future<void> runPreview() async {
    if (isProcessing) return;

    // 收集所有可编译的预览节点（含调节器：作为运行目标汇点跑链，
    // 链末端帧的默认色调映射出图后存入 previewImages）。
    final previewNodes = <IspNode>[];
    for (final node in graph.nodes.values) {
      if (node.typeId == 'preview' ||
          node.typeId == 'hsl_debugger' ||
          node.typeId == 'rgb_debugger' ||
          node.typeId == 'yuv_debugger' ||
          node.typeId == 'sat_bright_adjuster' ||
          node.typeId == 'bright_contrast_adjuster' ||
          node.typeId == 'color_balance' ||
          node.typeId == 'color_temp_adjuster' ||
          node.typeId == 'edge_extract' ||
          node.typeId == 'levels_curves') {
        previewNodes.add(node);
      }
    }
    if (previewNodes.isEmpty) {
      // 无预览类节点但有已连接输入的仪器（如 源→AHE→直方图 的纯仪器
      // 流程）：仍然运行仪器分析，否则仪器永远停留在「未运行」。
      final hasConnectedInstrument = graph.nodes.values.any((node) =>
          allInstrumentTypes.contains(node.typeId) &&
          IspNodeRegistry.byId(node.typeId)!
              .inputs
              .any((p) => graph.connectionAt(node.id, p.name) != null));
      if (hasConnectedInstrument) {
        await _runInstrumentsOnly();
        return;
      }
      statusMessage = '图中没有预览节点';
      notifyListeners();
      return;
    }

    isProcessing = true;
    _resetProgress();
    statusMessage = '正在解析节点图与计算帧序列…';
    _lastPlaybackRgba = null; // 单次运行的节点捕获优先于过期播放帧
    nodeRunTimesUs = {}; // 重新测量各节点耗时
    nodeRunOnGpu = {}; // 重新标记各节点执行后端
    _clearPlanePreviews();
    notifyListeners();
    final token = ++_runToken;
    try {
      // 预编译全部预览链：既供并行执行直接复用（不再重复编译），
      // 链长（算子数）也作为各预览节点的进度权重。
      final chains = <String, List<Map<String, Object?>>>{};
      // 调节器节点的「调整前」输入链：到其上游节点为止（无输入连接或
      // 编译失败的节点没有该条目，UI 显示占位文案）。
      final inputChains = <String, List<Map<String, Object?>>>{};
      var totalChainLen = 0;
      for (final pvNode in previewNodes) {
        try {
          final c = compileChain(graph, pvNode.id);
          chains[pvNode.id] = c;
          totalChainLen += c.length;
        } catch (_) {
          // 无法编译的节点在并行执行阶段同样跳过。
        }
        if (pvNode.typeId == 'hsl_debugger' ||
            pvNode.typeId == 'rgb_debugger' ||
            pvNode.typeId == 'yuv_debugger' ||
            pvNode.typeId == 'sat_bright_adjuster' ||
            pvNode.typeId == 'bright_contrast_adjuster' ||
            pvNode.typeId == 'color_balance' ||
            pvNode.typeId == 'color_temp_adjuster' ||
            pvNode.typeId == 'edge_extract' ||
            pvNode.typeId == 'levels_curves') {
          // 注意：上游是多输出节点（如分路器）时，该链渲染的是上游节点
          // 主帧，可能与具体连接端口的数据有差异（可接受的近似）。
          // 色饱和度/亮度调节器等的输入可能接在 in/in_yuv/in_hsl/in_mono
          // 任一端口（互斥组），依次取第一个已连接者。
          final up = graph.connectionAt(pvNode.id, 'in') ??
              graph.connectionAt(pvNode.id, 'in_yuv') ??
              graph.connectionAt(pvNode.id, 'in_hsl') ??
              graph.connectionAt(pvNode.id, 'in_mono');
          if (up != null) {
            try {
              final c = compileChain(graph, up.fromNodeId);
              inputChains[pvNode.id] = c;
              totalChainLen += c.length;
            } catch (_) {
              // 输入链编译失败：仅没有「调整前」对比图，不影响输出链。
            }
          }
        }
      }
      // 以第一个预览节点为基准计算 totalFrames / dimensions。
      final firstPreview = previewNodes.first;
      final firstChain = chains[firstPreview.id];
      if (firstChain == null) {
        try {
          _compileTo(firstPreview.id); // 重跑以取得原始错误信息
        } catch (e) {
          statusMessage = e.toString().replaceFirst('Bad state: ', '');
        }
        return;
      }
      _advanceProgress(0.02); // 图解析与链编译完成
      final srcTypeId = firstChain.first['typeId'] as String;
      final srcParams = firstChain.first['params'] as Map<String, Object?>;
      totalFrames = await _previewFrameCount(firstPreview, srcTypeId, srcParams);
      final frame = previewFrame.clamp(0, totalFrames! - 1);
      previewFrame = frame;
      // 图片源整图只解码一次：各预览链（含调节器「调整前」输入链）经
      // sourceRgba 注入共享同一解码结果，避免每条链独立完整解码同一
      // 文件（大图纯 Dart 解码为秒级，多链时成倍放大）。
      final imageSrcRgba = <String, (Uint8List, int, int)>{}; // 源 nodeId → 帧
      for (final c in [...chains.values, ...inputChains.values]) {
        if (c.first['typeId'] != 'image_source') continue;
        final srcId = c.first['nodeId'] as String;
        if (imageSrcRgba.containsKey(srcId)) continue;
        final p = (c.first['params'] as Map).cast<String, Object?>();
        imageSrcRgba[srcId] = await _imageSourceRgba('${p['filePath'] ?? ''}');
      }
      final firstSrcId = firstChain.first['nodeId'] as String;
      final (w, h) = srcTypeId == 'image_source'
          ? (imageSrcRgba[firstSrcId]!.$2, imageSrcRgba[firstSrcId]!.$3)
          : await sourceDimensions(srcTypeId, srcParams);

      // 按图里实际内容分配进度区段：探针(帧数/尺寸)固定 8%，仪器
      // 有则占 18%，其余归预览节点（按链长加权）；无仪器时预览区段
      // 自然延伸到 98%，不出现无人认领的固定跳变点。
      const probeEnd = 0.08;
      final instrumentCount = _connectedImageInstrumentCount();
      final instrumentShare = instrumentCount > 0 ? 0.18 : 0.0;
      final previewShare = 0.98 - probeEnd - instrumentShare;
      _advanceProgress(probeEnd);

      var completedWeight = 0;
      final totalCount = previewNodes.length;
      var completedCount = 0;
      // 各链已完成算子数（nodeStart 回报粒度）：总进度 = 已完成算子
      // 求和 / 总算子数（totalChainLen），链完成后置为链全长。
      final chainDoneOps = <String, int>{};

      // ---- GPU 快路径：最长支持链单次执行，前缀预览链顺带捕获 ----
      var gpuCovered = <String>{};
      try {
        gpuCovered =
            await _tryGpuPreview(chains, inputChains, frame, (nodeId) {
          if (token != _runToken) return;
          final nodeType = graph.nodes[nodeId]?.typeId;
          final name = nodeType == null
              ? nodeId
              : (IspNodeRegistry.byId(nodeType)?.displayName ?? nodeId);
          statusMessage = '正在运行（GPU）：$name…';
          notifyListeners();
        }, imageSources: imageSrcRgba);
        if (token != _runToken) return;
      } catch (e) {
        debugPrint('[isp] GPU 预览失败，回退 CPU 路径: $e');
        gpuCovered = {};
      }
      // 被覆盖链的进度按全长计入。
      for (final key in gpuCovered) {
        final base = key.endsWith('#in') ? key.substring(0, key.length - 3) : key;
        final len = (key.endsWith('#in') ? inputChains[base] : chains[base])
                ?.length ??
            0;
        chainDoneOps[key] = len;
        completedWeight += len;
        if (!key.endsWith('#in')) completedCount++;
      }

      // 所有预览节点并行执行。
      await Future.wait([
        for (final pvNode in previewNodes)
          if (!gpuCovered.contains(pvNode.id))
            () async {
            try {
              final chain = chains[pvNode.id];
              if (chain == null) return;
              // 节点粒度进度回报（key 区分输出链与 HSL 调节器的输入链）：
              // 该节点刚要开始，视为前面 index 个算子已完成；与已完成链
              // 的算子数求和得总进度。
              void Function(String, int, int) progressOf(String key) {
                return (nodeId, index, total) {
                  if (token != _runToken) return;
                  chainDoneOps[key] = index;
                  final doneOps =
                      chainDoneOps.values.fold<int>(0, (a, b) => a + b);
                  if (totalChainLen > 0) {
                    _advanceProgress(probeEnd +
                        previewShare * doneOps / totalChainLen);
                  }
                  final nodeType = graph.nodes[nodeId]?.typeId;
                  final name = nodeType == null
                      ? nodeId
                      : (IspNodeRegistry.byId(nodeType)?.displayName ??
                          nodeId);
                  statusMessage =
                      '正在运行：$name [$doneOps/$totalChainLen]…';
                  notifyListeners();
                };
              }

              chainDoneOps[pvNode.id] = 0;
              // HSL 调节器：与输出链并行跑「到上游节点为止」的输入链（即
              // 输出链去掉末节点的前缀，末端 HSL 帧走既有默认色调映射），
              // 出「调整前」对比图；输入链独立容错，失败只少对比图。
              final inputChain = inputChains[pvNode.id];
              final inKey = '${pvNode.id}#in';
              if (inputChain != null) chainDoneOps[inKey] = 0;
              // 图片源注入共享解码帧（见上方 imageSrcRgba），跳过链内解码。
              final injected = imageSrcRgba[chain.first['nodeId'] as String];
              final inInjected = inputChain == null
                  ? null
                  : imageSrcRgba[inputChain.first['nodeId'] as String];
              // Future 创建即启动，两条链实际并行执行。
              final outFuture = runChainFrameWithProgress(chain, frame,
                  onNodeStart: progressOf(pvNode.id),
                  sourceRgba: injected?.$1,
                  sourceWidth: injected?.$2,
                  sourceHeight: injected?.$3);
              final inFuture = inputChain == null ||
                      gpuCovered.contains('${pvNode.id}#in')
                  ? null
                  : runChainFrameWithProgress(inputChain, frame,
                          onNodeStart: progressOf(inKey),
                          sourceRgba: inInjected?.$1,
                          sourceWidth: inInjected?.$2,
                          sourceHeight: inInjected?.$3)
                      .then<Map<String, Object?>?>((r) => r,
                          onError: (_) => null);
              final result = await outFuture;
              final inputResult = await inFuture;
              if (token != _runToken) return;
              final rgba = result['rgba'] as Uint8List;
              // 合并本条链测得的节点耗时（多链并行，共享前缀节点
              // 后完成者覆盖先完成者，数值等价故无所谓；输入链是
              // 输出链的前缀，其耗时重复故不合并）。
              nodeRunTimesUs = {
                ...nodeRunTimesUs,
                ...(result['timings'] as Map).cast<String, int>(),
              };
              // CPU 闭包跑出的节点标记为 CPU 后端（GPU 主链已标记的
              // 节点不覆盖——其耗时以 GPU 侧为准）。
              for (final id
                  in (result['timings'] as Map).cast<String, int>().keys) {
                nodeRunOnGpu.putIfAbsent(id, () => false);
              }
              if (pvNode.id == firstPreview.id) {
                nodeOutputCaptures =
                    (result['captures'] as Map).cast<String, Map<String, Object?>>();
              }
              Future<ui.Image> decode(Uint8List rgba) {
                final completer = Completer<ui.Image>();
                ui.decodeImageFromPixels(rgba, w, h,
                    ui.PixelFormat.rgba8888, completer.complete);
                return completer.future;
              }

              final image = await decode(rgba);
              // hsl_debugger 不改变帧尺寸，输入图与输出图同宽高。
              final inputRgba = inputResult?['rgba'] as Uint8List?;
              final inputImage =
                  inputRgba == null ? null : await decode(inputRgba);
              // 亮度/对比度调节器：由输出链/输入链末端 RGBA 分别统计
              // Y 通道波形（与 waveform 仪器同一口径），渲染成图供节点
              // 示波器右半（调整后）/左半（调整前）显示。
              Future<ui.Image> decodeWaveform(Uint8List src) async {
                final (counts, cols) = waveformLuma(src, w, h);
                final wrgba = waveformIntensityRgba(
                    {'counts': counts}, cols, kWaveformLevels, {'y'});
                final completer = Completer<ui.Image>();
                ui.decodeImageFromPixels(wrgba, cols, kWaveformLevels,
                    ui.PixelFormat.rgba8888, completer.complete);
                return completer.future;
              }

              ui.Image? waveformImage;
              ui.Image? inputWaveformImage;
              if (pvNode.typeId == 'bright_contrast_adjuster') {
                waveformImage = await decodeWaveform(rgba);
                if (inputRgba != null) {
                  inputWaveformImage = await decodeWaveform(inputRgba);
                }
              }
              // HSL 调节器：由输出链/输入链末端 RGBA 分别统计 Cb/Cr
              // 矢量示波器（与 vectorscope 仪器同一口径），渲染成图供
              // 节点右半（调整后）/左半（调整前）显示。统计走仪器
              // worker 池（降采样 + 后台 isolate），两图并行。
              ui.Image? vectorscopeImage;
              ui.Image? inputVectorscopeImage;
              if (pvNode.typeId == 'hsl_debugger') {
                final outScope = _hslVectorscopeImage(rgba, w, h);
                final inScope = inputRgba == null
                    ? null
                    : _hslVectorscopeImage(inputRgba, w, h);
                vectorscopeImage = await outScope;
                if (inScope != null) {
                  inputVectorscopeImage = await inScope;
                }
              }
              if (token != _runToken) {
                image.dispose();
                inputImage?.dispose();
                waveformImage?.dispose();
                inputWaveformImage?.dispose();
                vectorscopeImage?.dispose();
                inputVectorscopeImage?.dispose();
                return;
              }
              previewImages.remove(pvNode.id)?.dispose();
              previewImages[pvNode.id] = image;
              previewInputImages.remove(pvNode.id)?.dispose();
              if (inputImage != null) {
                previewInputImages[pvNode.id] = inputImage;
              }
              if (pvNode.typeId == 'bright_contrast_adjuster') {
                brightContrastWaveforms.remove(pvNode.id)?.dispose();
                if (waveformImage != null) {
                  brightContrastWaveforms[pvNode.id] = waveformImage;
                }
                brightContrastInputWaveforms.remove(pvNode.id)?.dispose();
                if (inputWaveformImage != null) {
                  brightContrastInputWaveforms[pvNode.id] =
                      inputWaveformImage;
                }
              }
              if (pvNode.typeId == 'hsl_debugger') {
                hslVectorscopes.remove(pvNode.id)?.dispose();
                if (vectorscopeImage != null) {
                  hslVectorscopes[pvNode.id] = vectorscopeImage;
                }
                hslInputVectorscopes.remove(pvNode.id)?.dispose();
                if (inputVectorscopeImage != null) {
                  hslInputVectorscopes[pvNode.id] = inputVectorscopeImage;
                }
              }
              // 曲线调节器：输入链末端 RGBA 统计 Y 直方图（2x2 降采样
              // 后统计视觉等效），曲线编辑器背景显示。输入链被 GPU
              // 覆盖时 inputRgba 为空，由 _tryGpuPreview 的回读补齐。
              if (pvNode.typeId == 'levels_curves') {
                if (inputRgba != null) {
                  final src = w > 64 && h > 64
                      ? downsampleRgba82x(inputRgba, w, h).$1
                      : inputRgba;
                  levelsHistograms[pvNode.id] = histogramRgb(src).$4;
                } else if (!gpuCovered.contains('${pvNode.id}#in')) {
                  levelsHistograms.remove(pvNode.id);
                }
                // 输出（调节后）Y 直方图：本节点输出链末端 RGBA 同一口径
                // 统计，与输入直方图叠加显示。输出链被 GPU 覆盖时本闭包
                // 不执行，由 _tryGpuPreview 的 levelsOutFeeds 回读补齐。
                final outSrc =
                    w > 64 && h > 64 ? downsampleRgba82x(rgba, w, h).$1 : rgba;
                levelsOutputHistograms[pvNode.id] = histogramRgb(outSrc).$4;
              }
              // 色温调节器：由输入链末端 RGBA 自动测量色温（McCamy 估计），
              // 存 measuredColorTemps 供节点显示；滑块不自动跟随——用户
              // 点击节点上的测量值按钮才设定（applyMeasuredColorTemp）。
              // 输入链被 GPU 覆盖时 inputRgba 为空，由 _tryGpuPreview
              // 的回读补齐测量。
              if (pvNode.typeId == 'color_temp_adjuster') {
                if (inputRgba != null) {
                  final m = measureCctFromRgba(inputRgba, w, h);
                  if (m != null) measuredColorTemps[pvNode.id] = m;
                }
                // 调整后 RGB 直方图：输出链末端 RGBA（2x2 降采样统计），
                // 节点右下角显示。
                final outSrc =
                    w > 64 && h > 64 ? downsampleRgba82x(rgba, w, h) : (rgba, w, h);
                final hr = histogramRgb(outSrc.$1);
                colorTempHistograms[pvNode.id] = (hr.$1, hr.$2, hr.$3);
              }
            } catch (_) {
              // 单个节点失败不影响其余节点。
            } finally {
              completedCount++;
              completedWeight += chains[pvNode.id]?.length ?? 0;
              completedWeight += inputChains[pvNode.id]?.length ?? 0;
              // 链结束：已完成算子数置为链全长（无论成败，不再推进）。
              chainDoneOps[pvNode.id] = chains[pvNode.id]?.length ?? 0;
              final inChain = inputChains[pvNode.id];
              if (inChain != null) {
                chainDoneOps['${pvNode.id}#in'] = inChain.length;
              }
              if (token == _runToken) {
                _advanceProgress(probeEnd +
                    previewShare *
                        (totalChainLen > 0
                            ? completedWeight / totalChainLen
                            : completedCount / totalCount));
                statusMessage = '正在渲染预览节点 [$completedCount/$totalCount]…';
                notifyListeners();
              }
            }
          }(),
      ]);
      if (token != _runToken) return;

      // 向后兼容：legacy 字段指向第一个预览图（非持有别名，所有权在
      // previewImages——此处若再 dispose 旧值，与上面闭包里
      // previewImages.remove()?.dispose() 构成双重释放，二次运行必崩，
      // 仪器刷新（在本次赋值之后）永远不会执行）。
      _legacyPreviewImage = previewImages[firstPreview.id];

      previewWidth = w;
      previewHeight = h;
      if (instrumentCount > 0) {
        statusMessage = '正在更新示波器与分析仪器…';
        notifyListeners();
      }

      // 仪器节点随预览刷新（并行分析，单个失败不影响预览）。
      await _runInstruments(frame, token,
          progressBase: probeEnd + previewShare,
          progressScale: instrumentShare);
      if (token != _runToken) return;

      progress = 1.0;
      progressTick.value = 1.0;
      statusMessage = '预览就绪 第 ${frame + 1}/$totalFrames 帧  ${w}x$h';
    } catch (e) {
      statusMessage = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      _progressTimer?.cancel();
      _progressTimer = null;
      if (token == _runToken) {
        isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// 无预览节点时的纯仪器运行（如 源→AHE→直方图 的流程）：以第一个
  /// 已连接仪器的上游链推算帧序列，只刷新仪器分析结果。
  Future<void> _runInstrumentsOnly() async {
    isProcessing = true;
    _resetProgress();
    statusMessage = '正在解析节点图与计算帧序列…';
    _lastPlaybackRgba = null; // 单次运行的节点捕获优先于过期播放帧
    notifyListeners();
    final token = ++_runToken;
    try {
      // 用第一个已连接图像仪器的上游链确定源节点与帧数；音频仪器
      // 不经营帧流水线，链不可编译时按第 0 帧运行（具体失败在仪器
      // 分析阶段记录）。
      var frame = 0;
      for (final node in graph.nodes.values) {
        if (!allInstrumentTypes.contains(node.typeId) ||
            audioInstrumentTypes.contains(node.typeId)) {
          continue;
        }
        final type = IspNodeRegistry.byId(node.typeId)!;
        final hasInput =
            type.inputs.any((p) => graph.connectionAt(node.id, p.name) != null);
        if (!hasInput) continue;
        try {
          final chain = compileChain(graph, node.id);
          final total = await sourceFrameCount(chain.first['typeId'] as String,
              chain.first['params'] as Map<String, Object?>);
          totalFrames = total;
          frame = previewFrame.clamp(0, total - 1);
          previewFrame = frame;
        } catch (_) {
          // 链不可编译：保持第 0 帧。
        }
        break;
      }
      statusMessage = '正在更新示波器与分析仪器…';
      notifyListeners();
      await _runInstruments(frame, token);
      if (token != _runToken) return;
      progress = 1.0;
      progressTick.value = 1.0;
      statusMessage = '仪器分析就绪 第 ${frame + 1}/${totalFrames ?? 1} 帧';
    } catch (e) {
      statusMessage = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      _progressTimer?.cancel();
      _progressTimer = null;
      if (token == _runToken) {
        isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// 已连接输入的图像仪器节点数（进度权重分配用；不改变任何状态）。
  int _connectedImageInstrumentCount() {
    var n = 0;
    for (final node in graph.nodes.values) {
      if (!allInstrumentTypes.contains(node.typeId) ||
          audioInstrumentTypes.contains(node.typeId)) {
        continue;
      }
      final type = IspNodeRegistry.byId(node.typeId)!;
      if (type.inputs.any((p) => graph.connectionAt(node.id, p.name) != null)) {
        n++;
      }
    }
    return n;
  }

  /// 对所有已连接输入的仪器节点并行执行分析（编译到该节点为止的链）。
  /// 音频仪器（[audioInstrumentTypes]）不走帧流水线，由
  /// [_runAudioInstruments] 按音轨 PCM 刷新。
  /// [progressBase]/[progressScale] 非空时把进度锚点推进到
  /// `base + scale * 完成数/总数`（单次运行预览用；暂停路径不传，
  /// 不动进度）。
  Future<void> _runInstruments(int frame, int token,
      {double? progressBase, double progressScale = 0}) async {
    final connected = <IspNode>[];
    for (final node in graph.nodes.values) {
      if (!allInstrumentTypes.contains(node.typeId)) continue;
      final type = IspNodeRegistry.byId(node.typeId)!;
      final hasInput =
          type.inputs.any((p) => graph.connectionAt(node.id, p.name) != null);
      if (hasInput) {
        if (!audioInstrumentTypes.contains(node.typeId)) {
          connected.add(node);
        }
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
    // 音频仪器：数据来自音轨而非帧，与图像仪器并行刷新。
    final audioFuture = _runAudioInstruments(frame, token);
    if (connected.isNotEmpty) {
      int instrumentCompleted = 0;
      final instrumentTotal = connected.length;
      await Future.wait([
        for (final node in connected)
          () async {
            try {
              final type = IspNodeRegistry.byId(node.typeId);
              Map<String, Object?> result;
              if (node.typeId == 'psnr') {
                // PSNR 数字表：双输入（参考/测试），走专用双路馈源分析。
                result = await _analyzePsnr(node, frame);
              } else {
                Uint8List? rgba;
                int? w, h;
                // 优先复用播放中最近上屏的帧（暂停场景）：视频源逐仪器
                // 重新 seek 解码要起多次 ffmpeg，耗时以秒计。
                final lastMap = _lastPlaybackRgba;
                if (lastMap != null && lastMap.isNotEmpty) {
                  final srcId = _instrumentSrcNodeId(node);
                  rgba = lastMap[srcId] ?? lastMap.values.first;
                  // GPU 平面馈源的 U/V chroma 平面是半尺寸，按条目取真实宽高，
                  // 不能用全分辨率 _lastPlaybackW/H 去索引。
                  final dim = _lastPlaybackDims?[srcId];
                  w = dim?.$1 ?? _lastPlaybackW;
                  h = dim?.$2 ?? _lastPlaybackH;
                } else if (type != null) {
                  for (final inputSpec in type.inputs) {
                    final inputConn = graph.connectionAt(node.id, inputSpec.name);
                    if (inputConn != null) {
                      final capture = nodeOutputCaptures[inputConn.fromNodeId]?[inputConn.fromPort];
                      if (capture is Map) {
                        rgba = capture['data'] as Uint8List?;
                        w = capture['width'] as int?;
                        h = capture['height'] as int?;
                        if (rgba != null) break;
                      }
                    }
                  }
                }

                if (rgba != null && w != null && h != null && w > 0 && h > 0) {
                  final (srcRgba, srcW, srcH) = w > 64 && h > 64
                      ? downsampleRgba82x(rgba, w, h)
                      : (rgba, w, h);
                  result = await _instrumentAnalyzer.analyze(srcRgba, srcW, srcH, node.typeId);
                } else {
                  final chain = compileChain(graph, node.id);
                  // 链重跑放后台 isolate：多核 RAW 算子的长链在主 isolate
                  // 执行会冻结 UI 数秒，期间仪器 worker 的回包无法被处理，
                  // 5s 超时定时器抢先触发而误报「仪器分析超时」。
                  final chainRgba = await compute(runChainFrameInIsolate,
                      {'chain': chain, 'frameIndex': frame});
                  final (dw, dh) = await sourceDimensions(
                      chain.first['typeId'] as String,
                      chain.first['params'] as Map<String, Object?>);
                  final (srcRgba, srcW, srcH) = dw > 64 && dh > 64
                      ? downsampleRgba82x(chainRgba, dw, dh)
                      : (chainRgba, dw, dh);
                  result = await _instrumentAnalyzer.analyze(srcRgba, srcW, srcH, node.typeId);
                }
              }
              if (token != _runToken) return;
              instrumentResults[node.id] = result;
              await _updateInstrumentImage(node.id, result);
            } catch (e) {
              // 链不完整等失败：保留旧结果，不影响预览，但记录便于诊断。
              debugPrint('[isp] 仪器分析失败 ${node.id}(${node.typeId}): $e');
            } finally {
              instrumentCompleted++;
              if (token == _runToken) {
                if (progressBase != null) {
                  _advanceProgress(progressBase +
                      progressScale * instrumentCompleted / instrumentTotal);
                }
                statusMessage = '正在更新仪器 [$instrumentCompleted/$instrumentTotal]…';
                notifyListeners();
              }
            }
          }(),
      ]);
    }
    await audioFuture;
    if (token == _runToken) {
      // 仪器附加区用 ValueListenableBuilder 只监听 instrumentTick，
      // 单次运行/暂停路径必须主动递增它，否则该区域在部分时序下
      // 不会因外层 notifyListeners 而可靠重建。
      instrumentTick.value++;
      notifyListeners();
    }
  }

  /// PSNR 数字表分析：取参考图（in*）与测试图（in_test*）两路的链末端
  /// 色调映射 RGBA（与直方图同一数据口径），计算 PSNR(dB)/MSE。
  /// 任一路未接入或尺寸不一致时返回带 error 提示的结果。
  Future<Map<String, Object?>> _analyzePsnr(IspNode node, int frame) async {
    // 取一路输入的 RGBA：优先复用最近一次运行的端口捕获（GPU 回读）；
    // 没有捕获则把上游节点当汇点编译链重跑（后台 isolate，同仪器
    // 通用回退路径）。
    Future<(Uint8List, int, int)?> feedOf(List<String> ports) async {
      for (final pn in ports) {
        final conn = graph.connectionAt(node.id, pn);
        if (conn == null) continue;
        final cap = nodeOutputCaptures[conn.fromNodeId]?[conn.fromPort];
        if (cap is Map && cap['data'] is Uint8List) {
          return (
            cap['data'] as Uint8List,
            cap['width'] as int,
            cap['height'] as int,
          );
        }
        final chain = compileChain(graph, conn.fromNodeId);
        // 图片源：注入共享解码缓存的 RGBA8（跨运行只解码一次，mtime/
        // 大小校验），跳过链内重复解码（20MP 解码占馈源耗时的 90%+）。
        Map<String, Object?>? inject;
        if (chain.first['typeId'] == 'image_source') {
          final p0 = chain.first['params'] as Map<String, Object?>;
          final inj =
              await _imageSourceRgba('${p0['filePath'] ?? ''}');
          inject = {
            'sourceRgba': inj.$1,
            'sourceWidth': inj.$2,
            'sourceHeight': inj.$3,
          };
        }
        // GPU 快路径：链支持时 GPU 执行（16 位帧驻留 GPU，色调映射
        // 在 GPU 上完成，仅回读 RGBA8）；失败/不支持回退 CPU isolate。
        final gpu = await _gpuPipeline();
        if (gpu != null && GpuPipeline.isSupportedChain(chain)) {
          try {
            final r = await gpu.run(chain, frame,
                imageSources: inject == null
                    ? const {}
                    : {
                        chain.first['nodeId'] as String: (
                          inject['sourceRgba'] as Uint8List,
                          inject['sourceWidth'] as int,
                          inject['sourceHeight'] as int,
                        ),
                      });
            final gpuRgba = await GpuPipeline.readbackBytes(r.image);
            r.image.dispose();
            return (gpuRgba, r.width, r.height);
          } catch (_) {
            // 回退 CPU 路径。
          }
        }
        final rgba = await compute(runChainFrameInIsolate,
            {'chain': chain, 'frameIndex': frame, ...?inject});
        final (dw, dh) = await sourceDimensions(
            chain.first['typeId'] as String,
            chain.first['params'] as Map<String, Object?>);
        return (rgba, dw, dh);
      }
      return null;
    }

    final ref = await feedOf(const ['in', 'in_yuv', 'in_hsl', 'in_mono']);
    final test = await feedOf(
        const ['in_test', 'in_test_yuv', 'in_test_hsl', 'in_test_mono']);
    if (ref == null || test == null) {
      return {'kind': 'psnr', 'error': '需要接入参考图与测试图'};
    }
    if (ref.$2 != test.$2 || ref.$3 != test.$3) {
      return {'kind': 'psnr', 'error': '两路输入尺寸不一致'};
    }
    // 与直方图同一口径：大帧 2x 降采样后统计（视觉等效，耗时 1/4）。
    final large = ref.$2 > 64 && ref.$3 > 64;
    final ra = large ? downsampleRgba82x(ref.$1, ref.$2, ref.$3).$1 : ref.$1;
    final ta =
        large ? downsampleRgba82x(test.$1, test.$2, test.$3).$1 : test.$1;
    final (mse, psnr) = psnrRgba(ra, ta);
    return {'kind': 'psnr', 'psnr': psnr, 'mse': mse};
  }

  /// 音频仪器的 WAV PCM 缓存（WAV 路径 → 解析结果）。
  final Map<String, WavPcm> _wavPcmCache = {};

  /// 加载并缓存 WAV 的 PCM（电平/波形/EQ 分析共用）；失败返回 null。
  Future<WavPcm?> _loadWavPcm(String wavPath) async {
    final cached = _wavPcmCache[wavPath];
    if (cached != null) return cached;
    try {
      final pcm = parseWavPcm(await File(wavPath).readAsBytes());
      _wavPcmCache[wavPath] = pcm;
      return pcm;
    } catch (_) {
      return null;
    }
  }

  /// 刷新所有已连接的音频仪器（电平/波形/EQ 频谱）：分析位置为
  /// [frame] 换算的秒（帧率取上游视频源的原生帧率）。分析是微秒级
  /// 小计算，直接在 UI isolate 执行。无音轨/未连接时清除结果
  /// （节点显示「未运行」）；其余失败静默（保留旧结果）。
  Future<void> _runAudioInstruments(int frame, int token) async {
    for (final node in graph.nodes.values) {
      if (!audioInstrumentTypes.contains(node.typeId)) continue;
      final conn = graph.connectionAt(node.id, 'in');
      final src = conn == null ? null : graph.nodes[conn.fromNodeId];
      if (src == null || src.typeId != 'video_source') {
        instrumentResults.remove(node.id);
        continue;
      }
      try {
        final path = src.paramValues['filePath']?.toString() ?? '';
        final ffmpegPath = src.paramValues['ffmpegPath']?.toString() ?? '';
        final info = await videoFileInfo(path, ffmpegPath: ffmpegPath);
        final wav = await ensureAudioWav(path, ffmpegPath: ffmpegPath);
        final pcm = wav == null ? null : await _loadWavPcm(wav);
        if (pcm == null) {
          instrumentResults.remove(node.id); // 无音轨或抽取失败
          continue;
        }
        if (token != _runToken) return;
        final seconds = frame / info.fps;
        instrumentResults[node.id] = switch (node.typeId) {
          'audio_level' => audioLevels(pcm, seconds),
          'audio_waveform' => audioWaveform(pcm, seconds),
          _ => audioEqBands(pcm, seconds),
        };
      } catch (_) {
        // 保留旧结果，不影响预览/播放。
      }
    }
  }

  /// 波形/矢量示波器：把计数表映射为亮度图并解码为显示图像。
  /// 播放中结果由仪器 worker 侧预渲染（'bmp'），直接解码；
  /// 暂停/单次运行结果含计数表，本地渲染。
  Future<void> _updateInstrumentImage(
      String nodeId, Map<String, Object?> result) async {
    int w, h;
    Uint8List bmp;
    final kind = result['kind'] as String?;
    final prerendered = result['bmp'] as Uint8List?;
    switch (kind) {
      case 'waveform':
        w = (result['columns'] as num?)?.toInt() ?? 512;
        h = kWaveformLevels;
        if (prerendered != null) {
          bmp = prerendered;
        } else {
          final visible = waveformChannels(nodeId);
          bmp = waveformIntensityRgba(result, w, h, visible);
        }
      case 'vectorscope':
        w = h = kVectorscopeSize;
        if (prerendered != null) {
          bmp = prerendered;
        } else {
          final counts = result['counts'];
          if (counts is! Uint32List) return;
          bmp = intensityRgba(counts, w, h, 70, 235, 70);
        }
      default:
        return; // 直方图与音频仪器由控件直绘，无需图像
    }
    // 首次运行时光栅线程可能还在忙首帧渲染/大预览纹理上传，小图解码
    // 回调会被推迟超过 2s——超时不等于解码失败，重试等引擎空闲即可。
    ui.Image? image;
    Object? lastError;
    for (var attempt = 0; attempt < 3 && image == null; attempt++) {
      final completer = Completer<ui.Image>();
      var timedOut = false;
      ui.decodeImageFromPixels(
          bmp, w, h, ui.PixelFormat.rgba8888, completer.complete);
      try {
        image = await completer.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            timedOut = true;
            throw StateError(
                'decodeImageFromPixels 超时 (${bmp.length} bytes, ${w}x$h)');
          },
        );
      } catch (e) {
        lastError = e;
        if (timedOut) {
          // 迟到的回调仍会生成图像，无人持有会泄漏 GPU 纹理。
          unawaited(completer.future.then((late) => late.dispose()));
        }
      }
    }
    if (image == null) {
      throw lastError ?? StateError('decodeImageFromPixels 失败 (${w}x$h)');
    }
    instrumentImages.remove(nodeId)?.dispose();
    instrumentImages[nodeId] = image;
  }

  void setPreviewFrame(int frame) {
    if (frame == previewFrame) return;
    previewFrame = frame;
    notifyListeners();
  }

  // ---- 连续播放 ----

  /// 是否正在连续播放预览。
  bool isPlaying = false;

  /// 播放逐帧刷新信号：每帧 +1，取代全树 notifyListeners——只有预览
  /// 附加区与状态栏监听它逐帧重建，画布/节点结构不再逐帧重排
  /// （否则缩小画布后十几个节点卡片每帧全量重建，UI isolate 被堵死，
  /// 走帧循环被饿死而连续停滞）。
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  /// 仪器结果刷新信号（波形/矢量/直方图/音频仪器附加区重建用，
  /// 播放中限频触发，暂停/单次运行由结构性 notifyListeners 覆盖）。
  final ValueNotifier<int> instrumentTick = ValueNotifier<int>(0);

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

  /// 播放中最近一次上屏帧的各预览链 RGBA（暂停时仪器刷新直接复用，
  /// 免逐仪器重新 seek 解码视频帧）。
  Map<String, Uint8List>? _lastPlaybackRgba;
  int _lastPlaybackW = 0;
  int _lastPlaybackH = 0;

  /// GPU 平面预览时 [_lastPlaybackRgba] 各条目的真实宽高（U/V chroma
  /// 平面为半尺寸）；非 GPU 平面模式为 null（所有条目同为全分辨率）。
  Map<String, (int, int)>? _lastPlaybackDims;

  /// 调试：打印播放生产各阶段耗时（基准测试用，默认关闭）。
  static bool debugPlaybackTiming = false;

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

    final validChains = <String, List<Map<String, Object?>>>{};
    for (final n in graph.nodes.values) {
      if (n.typeId == 'preview') {
        try {
          validChains[n.id] = compileChain(graph, n.id);
        } catch (_) {}
      }
    }
    if (validChains.isEmpty) {
      statusMessage = '图中没有有效的预览节点算子链';
      notifyListeners();
      return;
    }
    final firstEntry = validChains.entries.first;
    final chain = firstEntry.value;
    final srcTypeId = chain.first['typeId'] as String;
    final srcParams = chain.first['params'] as Map<String, Object?>;
    
    // 假设所有预览链源相同，取第一个计算总帧数
    totalFrames = await _previewFrameCount(graph.nodes[firstEntry.key]!, srcTypeId, srcParams);
    final total = totalFrames!;
    final (w, h) = await sourceDimensions(srcTypeId, srcParams);
    if (total <= 1) {
      await runPreview();
      return;
    }

    isProcessing = true;
    isPlaying = true;
    _clearPlanePreviews(); // 避免上一段 GPU 播放的过期帧残留
    // 播放帧由 worker isolate 的 CPU 流水线生产（GPU 仅可能用于平面
    // 预览的显示上屏，不跑链）：单次预览测得的节点后端徽标/耗时对
    // 播放不再适用，清空避免右侧面板残留误导。
    nodeRunTimesUs = {};
    nodeRunOnGpu = {};
    notifyListeners();
    final token = ++_runToken;
    try {
      final isVideo = srcTypeId == 'video_source';
      final allImageInstruments = <IspNode>[
        for (final node in graph.nodes.values)
          if (instrumentTypes.contains(node.typeId)) node,
      ];
      var frame = previewFrame.clamp(0, total - 1);
      // 全部预览链都消费 YUV 时让 ffmpeg 直出平面 YUV，配合 GPU 硬解，
      // 每条链省掉 RGBA→RGB16→YUV 两道逐像素全帧转换。
      final yuvDirect = isVideo &&
          validChains.values.every(
              (c) => (c.first['outFormat'] as String? ?? 'rgb') == 'yuv');
      // GPU 平面预览：全部预览链消费 YUV、尺寸可按 4 纹素/420 打包、
      // 且每个预览节点都能证明是源平面（或其恒等合路）的直接视图时，
      // 播放帧以解码器原生 yuv420p 原样打包上传，上色与范围扩展交给
      // GPU shader（yuv_planes.frag），CPU 不做逐像素转换。任一条件
      // 不满足则整体回退 CPU 流水线（yuv444p）。
      // 帧字节数须 < 2^24（约 5.3K）：shader 扁平字节寻址用的是
      // float，超出 24 位精度会错乱（4K = 12.4MB，余量充足）。
      var gpuPlanes = false;
      var planeModes = <String, int>{};
      // GPU 平面预览时 rgbaMap 已按 gpuStep 预降采样，仪器刷新须用
      // 降采样后的尺寸再喂给 downsampleRgba8Step，否则越界。
      var gpuStep = 1;
      // 各预览节点仪器馈源的真实宽高：U/V chroma 平面是半尺寸
      // （w/2 × h/2），与 Y/彩色全尺寸不同。
      final gpuPlaneDims = <String, (int, int)>{};
      if (yuvDirect && w % 4 == 0 && h % 2 == 0 && w * h * 3 ~/ 2 < 1 << 24) {
        final modes = <String, int>{};
        var ok = true;
        for (final id in validChains.keys) {
          final m = _previewPlaneMode(id);
          if (m == null) {
            ok = false;
            break;
          }
          modes[id] = m;
        }
        if (ok) {
          try {
            final prog = await ui.FragmentProgram.fromAsset(
                'shaders/yuv_planes.frag');
            yuvPlaneShader = prog.fragmentShader();
            gpuPlanes = true;
            planeModes = modes;
          } catch (_) {} // shader 不可用：回退 CPU 流水线
        }
      }
      final pixelFormat =
          gpuPlanes ? 'yuv420p' : (yuvDirect ? 'yuv444p' : 'rgba');
      // 视频源：从当前帧起顺序流式解码（内部前向缓冲，背压限速）。
      // 全分辨率出帧：预览按原始尺寸播放，不做降采样。
      var stream = isVideo
          ? await VideoFrameStream.start(
              srcParams['filePath']?.toString() ?? '', frame,
              ffmpegPath: srcParams['ffmpegPath']?.toString() ?? '',
              pixelFormat: pixelFormat)
          : null;
      // 音频回放（有音轨时）：ffmpeg 抽取 WAV + MCI 播放。
      final audio = MciAudioPlayer();
      var audioReady = false;
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
        } catch (_) {}
      }
      final fps = (graph.nodes[firstEntry.key]!.paramValues['fps'] as num?)?.toInt() ?? 30;
      final frameDuration =
          Duration(microseconds: (1000000 / fps.clamp(1, 60)).round());
      final videoDirect = isVideo &&
          (chain.first['outFormat'] as String? ?? 'rgb') == 'rgb' &&
          chain.skip(1).every((op) => sinkNodeTypes.contains(op['typeId']));
      final poolSize = videoDirect || gpuPlanes
          ? 0
          : math.min(validChains.length,
              math.max(1, Platform.numberOfProcessors - 1));
      final pipeline =
          videoDirect || gpuPlanes ? null : PipelineWorkerPool(count: poolSize);
      // 预热流水线 worker：isolate 启动与上面的流解码/音频初始化并行，
      // 首帧生产不再承担 ~0.5s 的 spawn 开销。
      pipeline?.warmup();
      // 仪器分析池同样预热（懒启动否则发生在首个刷新批次，阻塞走帧）。
      if (allImageInstruments.isNotEmpty) {
        unawaited(_instrumentAnalyzer.warmup());
      }
      final playSw = Stopwatch()..start();
      var pace = frameDuration;
      Duration? emaProd;
      var nextDeadline = Duration.zero;
      playbackProduced = playbackDisplayed = playbackDropped = 0;
      // 实时帧率统计：最近 1 秒上屏时间戳的滚动窗口。
      final fpsWindow = Queue<int>();

      // 取流帧串行闸：VideoFrameStream.next() 不支持并发等待，预缓冲
      // 深度为 2 时两趟生产会并发取帧，用门闩排队（解码 worker 内部有
      // 16 帧前向缓冲，取帧通常即刻返回，不会成为瓶颈）。
      Future<void> fetchGate = Future.value();

      // 生产一帧：并行跑全部有效预览链，返回像素映射与 UI 图像。
      Future<
          (
            int,
            Uint8List,
            Map<String, ui.Image>,
            Map<String, Uint8List>,
            bool,
            int,
            int,
            int
          )?> produceFrame(int f) async {
        final prodSw = Stopwatch()..start();
        var restarted = false;
        final images = <String, ui.Image>{};
        Map<String, Uint8List> rgbaMap = {};
        Uint8List? primaryRgba;

        if (isVideo) {
          final fetchSw = Stopwatch()..start();
          final prevGate = fetchGate;
          final gate = Completer<void>();
          fetchGate = gate.future;
          Uint8List? bytes;
          await prevGate;
          try {
            bytes = await stream!.next();
            if (bytes == null) {
              await stream!.dispose();
              stream = await VideoFrameStream.start(
                  srcParams['filePath']?.toString() ?? '', 0,
                  ffmpegPath: srcParams['ffmpegPath']?.toString() ?? '',
                  pixelFormat: pixelFormat);
              bytes = await stream!.next();
              if (bytes == null) return null;
              f = 0;
              restarted = true;
              try {
                audio.stop();
                audioStarted = false;
              } catch (_) {}
            }
          } finally {
            gate.complete();
          }
          playbackProduced++;
          if (fetchSw.elapsedMicroseconds > playbackMaxFetchUs) {
            playbackMaxFetchUs = fetchSw.elapsedMicroseconds;
          }
          if (fetchSw.elapsedMilliseconds > 50) playbackFetchStalls++;

          primaryRgba = bytes;

          // 全分辨率工作帧（预览按原始尺寸播放，不降采样）。
          final workBytes = bytes;
          final workW = stream!.outWidth;
          final workH = stream!.outHeight;
          final downUs = prodSw.elapsedMicroseconds;

          if (gpuPlanes) {
            // GPU 平面预览：yuv420p 帧原样打包为 (w/4)x(h*3/2) RGBA
            // 纹理上传（每纹素 4 字节，零重排零转换），上色与范围扩展
            // 在 shader 里做。仪器馈源按平面模式步长抽样合成 ~480p
            // 小图（统计类仪器不需要更高分辨率）。
            final limited = !stream!.info.fullRange;
            var step = 1;
            while (workH ~/ step > 480) {
              step *= 2;
            }
            gpuStep = step;
            final frameData = bytes;
            for (final e in planeModes.entries) {
              if (e.value == 0) {
                rgbaMap[e.key] = yuv420p8ToRgbaStep(frameData, workW, workH,
                    step, limited: limited);
                gpuPlaneDims[e.key] = (workW ~/ step, workH ~/ step);
              } else {
                // U/V chroma 平面（planeIdx = mode-1 = 1/2）半尺寸
                // （w/2 × h/2），与 Y/彩色全尺寸不同，须记录真实宽高。
                final planeIdx = e.value - 1;
                rgbaMap[e.key] = yuv420pPlaneToRgbaStep(
                    frameData, workW, workH, planeIdx, step, limited: limited);
                final pw = planeIdx == 0 ? workW : workW >> 1;
                final ph = planeIdx == 0 ? workH : workH >> 1;
                gpuPlaneDims[e.key] = (pw ~/ step, ph ~/ step);
              }
            }
            primaryRgba = rgbaMap[firstEntry.key] ?? bytes;

            final completer = Completer<ui.Image>();
            ui.decodeImageFromPixels(bytes, workW ~/ 4, workH * 3 ~/ 2,
                ui.PixelFormat.rgba8888, completer.complete);
            images[''] = await completer.future; // 打包纹理（'' 非节点 id）
            if (debugPlaybackTiming) {
              // ignore: avoid_print
              print('prod f=$f: 取流 $downUs us, GPU打包+仪器馈源 '
                  '${prodSw.elapsedMicroseconds - downUs} us');
            }
          } else if (videoDirect && validChains.length == 1) {
            final completer = Completer<ui.Image>();
            ui.decodeImageFromPixels(workBytes, workW, workH,
                ui.PixelFormat.rgba8888, completer.complete);
            images[firstEntry.key] = await completer.future;
            rgbaMap = {firstEntry.key: workBytes};
          } else {
            rgbaMap = await pipeline!.runParallel(validChains, f,
                sourceRgba: yuvDirect ? null : workBytes,
                sourceYuv: yuvDirect ? workBytes : null,
                sourceWidth: workW,
                sourceHeight: workH);
            primaryRgba = rgbaMap[firstEntry.key] ?? workBytes;
            final pipeUs = prodSw.elapsedMicroseconds;

            await Future.wait([
              for (final entry in rgbaMap.entries)
                () async {
                  final completer = Completer<ui.Image>();
                  ui.decodeImageFromPixels(entry.value, workW, workH,
                      ui.PixelFormat.rgba8888, completer.complete);
                  images[entry.key] = await completer.future;
                }(),
            ]);
            if (debugPlaybackTiming) {
              final imgUs = prodSw.elapsedMicroseconds;
              // ignore: avoid_print
              print('prod f=$f: 取流+降采样 $downUs us, 流水线 '
                  '${pipeUs - downUs} us, 图像解码 ${imgUs - pipeUs} us');
            }
          }
          if (!videoDirect || validChains.length > 1) {
            stream!.recycle(bytes);
          }
          return (
            f,
            primaryRgba,
            images,
            rgbaMap,
            restarted,
            prodSw.elapsedMicroseconds,
            workW,
            workH
          );
        } else {
          rgbaMap = await pipeline!.runParallel(validChains, f);
          primaryRgba = rgbaMap[firstEntry.key]!;

          await Future.wait([
            for (final entry in rgbaMap.entries)
              () async {
                final completer = Completer<ui.Image>();
                ui.decodeImageFromPixels(entry.value, w, h,
                    ui.PixelFormat.rgba8888, completer.complete);
                images[entry.key] = await completer.future;
              }(),
          ]);
          return (
            f,
            primaryRgba,
            images,
            rgbaMap,
            restarted,
            prodSw.elapsedMicroseconds,
            w,
            h
          );
        }
      }

      // 预缓冲：最多 2 帧在途生产（取帧经 fetchGate 串行、流水线计算
      // 在 worker 池中并行），播放节拍抖动由在途帧吸收，解码/流水线
      // 偶发慢帧不再直接造成上屏断档。
      final inflight = Queue.of([produceFrame(frame)]);
      var nextProduceFrame = (frame + 1) % total;
      void refillInflight() {
        while (inflight.length < 2) {
          final f0 = nextProduceFrame;
          inflight.add(produceFrame(f0));
          nextProduceFrame = (f0 + 1) % total;
        }
      }

      refillInflight();
      try {
        while (isPlaying && token == _runToken) {
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
          final produced = await inflight.removeFirst();
          if (produced == null) break;
          final (f, rgba, images, rgbaMap, restarted, prodUs, workW, workH) =
              produced;
          if (!isPlaying || token != _runToken) {
            for (final img in images.values) {
              img.dispose();
            }
            break;
          }
          if (restarted) {
            // EOF 重卷：在途的另一帧按旧流位置生产，丢弃并重建预缓冲队列。
            while (inflight.isNotEmpty) {
              final stale = await inflight.removeFirst();
              if (stale != null) {
                for (final img in stale.$3.values) {
                  img.dispose();
                }
              }
            }
            nextProduceFrame = (f + 1) % total;
          }
          if (playbackDisplayed == 0 || restarted) {
            nextDeadline = playSw.elapsed;
          } else if (playSw.elapsed - nextDeadline > pace * 2) {
            playbackDropped++;
            nextDeadline = playSw.elapsed;
          }
          if (gpuPlanes) {
            // 打包纹理换帧：同帧所有预览节点共享，旧纹理只释放一次。
            final packed = images['']!;
            final limited = !(stream?.info.fullRange ?? false);
            _clearPlanePreviews();
            previewPlanes = {
              for (final e in planeModes.entries)
                e.key: PlanePreviewFrame(packed, e.value, w, h, limited),
            };
          } else {
            for (final entry in images.entries) {
              previewImages.remove(entry.key)?.dispose();
              previewImages[entry.key] = entry.value;
            }
          }
          previewWidth = w;
          previewHeight = h;
          previewFrame = f;
          // 留存最近上屏帧：暂停时仪器刷新直接复用，免重新解码。
          _lastPlaybackRgba = rgbaMap;
          _lastPlaybackW = workW;
          _lastPlaybackH = workH;
          _lastPlaybackDims = gpuPlanes ? Map.of(gpuPlaneDims) : null;
          playbackDisplayed++;
          // 产能自适应：产能恢复时快速向下平滑收敛。头两帧的生产耗时
          // 含硬解初始化等一次性开销（预缓冲使其与后续帧叠加），过大的
          // 瞬时值不计入节拍估计，避免冷启动拖慢整段播放的帧率显示与
          // 走帧节奏。
          final prod = Duration(microseconds: prodUs);
          if (playbackDisplayed > 2 || prod < frameDuration * 4) {
            final prevEma = emaProd;
            final ema = prevEma == null
                ? prod
                : (prod < prevEma
                    ? prevEma * 0.2 + prod * 0.8
                    : prevEma * 0.7 + prod * 0.3);
            emaProd = ema;
            pace = ema > frameDuration ? ema : frameDuration;
          }
          playbackPaceUs = pace.inMicroseconds;
          if (prodUs > playbackMaxProdUs) playbackMaxProdUs = prodUs;
          // 实时帧率：最近 1 秒的上屏时间戳滚动窗口，窗口长度即 FPS。
          fpsWindow.add(playSw.elapsedMicroseconds);
          while (fpsWindow.isNotEmpty &&
              playSw.elapsedMicroseconds - fpsWindow.first > 1000000) {
            fpsWindow.removeFirst();
          }
          statusMessage = '播放中 第 ${f + 1}/$total 帧  '
              '${fpsWindow.length} FPS  停滞 $playbackDropped 次';
          // 逐帧刷新只走 frameTick：避免全模块重建堵死 UI isolate。
          frameTick.value++;
          if (audioReady && isVideo) {
            final videoT = f / stream!.info.fps;
            if (!audioStarted) {
              try {
                audio.playFrom(videoT);
                audioStarted = true;
              } catch (_) {
                audioReady = false;
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
          // 仪器随播放刷新：实时匹配各预览节点渲染帧，免除 RangeError，无损高帧率刷新
          final rgbaW = gpuPlanes ? workW ~/ gpuStep : workW;
          final rgbaH = gpuPlanes ? workH ~/ gpuStep : workH;
          _refreshInstrumentsFromFrame(
              rgbaMap, rgbaW, rgbaH, allImageInstruments, token,
              dims: gpuPlanes ? gpuPlaneDims : null);
          // 音频仪器（电平/波形/EQ）随播放位置刷新（限频 ~15Hz）。
          _refreshAudioInstrumentsFromPlayback(f, token);
          if (isVideo && videoDirect) {
            // 像素与仪器数据都已取走，流帧缓冲归还池。
            stream!.recycle(rgba);
          }
          // 补充在途生产（预缓冲深度 2），与下一轮的截止等待并发。
          refillInflight();
          nextDeadline += pace;
        }
      } finally {
        // 在途的预取帧（未上屏）：结果回来后释放图像，避免泄漏 GPU 纹理。
        while (inflight.isNotEmpty) {
          unawaited(inflight.removeFirst().then((p) {
            if (p != null) {
              for (final img in p.$3.values) {
                img.dispose();
              }
            }
          }, onError: (_) {}));
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

  /// 播放中：用当前帧 RGBA 后台刷新仪器分析。不做硬性限频：上一批
  /// 未完成则跳过该帧，刷新率自限到可持续速率（分析与渲染都在常驻
  /// worker 池多核并行，目标与预览走帧实时同步）。上一批未完成时
  /// 跳过不阻塞走帧。
  bool _instrumentBusy = false;

  /// 常驻仪器分析 isolate（随 state 生命周期，懒启动）。
  final InstrumentAnalyzer _instrumentAnalyzer = InstrumentAnalyzer();

  /// 音频仪器播放刷新的限频与重入闸（同 _instrumentBusy 思路）。
  bool _audioInstrumentBusy = false;
  DateTime _lastAudioInstrumentRefresh =
      DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放中：按当前帧位置刷新音频仪器（电平/波形/EQ）。限频 ~15Hz
  /// （仪表类显示足够），分析本身是微秒级小计算；首次调用要抽取/
  /// 解析音轨，异步执行不阻塞走帧。
  void _refreshAudioInstrumentsFromPlayback(int frame, int token) {
    if (_audioInstrumentBusy) return;
    if (!graph.nodes.values
        .any((n) => audioInstrumentTypes.contains(n.typeId))) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastAudioInstrumentRefresh) <
        const Duration(milliseconds: 66)) {
      return;
    }
    _lastAudioInstrumentRefresh = now;
    _audioInstrumentBusy = true;
    () async {
      try {
        await _runAudioInstruments(frame, token);
        // 播放中的音频仪器刷新只走 instrumentTick（局部重建）。
        if (token == _runToken) instrumentTick.value++;
      } finally {
        _audioInstrumentBusy = false;
      }
    }();
  }

  void _refreshInstrumentsFromFrame(Map<String, Uint8List> rgbaMap, int w,
      int h, List<IspNode> targets, int token,
      {Map<String, (int, int)>? dims}) {
    if (_instrumentBusy || targets.isEmpty || rgbaMap.isEmpty) return;
    _instrumentBusy = true;

    () async {
      try {
        // 同一馈源条目只降采样一次：多仪器共用同一预览源时省掉
        // 重复的 UI 侧抽样（每帧都要做，重复做会挤占走帧事件循环）。
        final downCache = <String, (Uint8List, int, int)>{};
        await Future.wait([
          for (final node in targets)
            () async {
              final srcNodeId = _instrumentSrcNodeId(node);
              final rgba = rgbaMap[srcNodeId] ?? rgbaMap.values.first;
              // 该条目的真实宽高：GPU 平面馈源的 U/V chroma 平面是
              // 半尺寸（w/2 × h/2），与 Y/彩色全尺寸不一致，必须按条目
              // 尺寸降采样，否则按全尺寸索引越界。
              final dim = dims?[srcNodeId];
              final ew = dim?.$1 ?? w;
              final eh = dim?.$2 ?? h;
              try {
                // 分析输入压到 ~480p：统计类仪器（波形 ≤512 列、直方图
                // 256 桶、矢量 512 网格）不需要更高分辨率；全分辨率帧
                // 用步长抽样一趟完成（4K 只读 1/64 的数据）。
                final (downRgba, dw, dh) =
                    downCache.putIfAbsent(srcNodeId ?? '#fallback', () {
                  var step = 1;
                  while (eh ~/ step > 480) {
                    step *= 2;
                  }
                  return downsampleRgba8Step(rgba, ew, eh, step);
                });
                // 波形：整机轮转分配到池内不同 worker，按可见通道选择性
                // 统计，亮度图 worker 侧渲染（结果只带 bmp）。矢量示波器：
                // 隔行条带多核并行（见下）。
                Map<String, Object?> result;
                if (node.typeId == 'vectorscope') {
                  // 矢量示波器播放走多核并行（保留连线轨迹）：抗锯齿
                  // 连线是噪声帧热点（实测单 worker 50~200ms/帧@480p），
                  // 隔行条带切给池内全部 worker，负载均衡且行间接续的
                  // 丢失视觉不可见。纯统计仪器（横轴不对应图像列）
                  // 输入再压到 ~240p：连线成本与像素数成正比，数据量
                  // 减为 1/4 而显示统计等效。
                  var vecRgba = downRgba;
                  var vw = dw, vh = dh;
                  var vstep = 1;
                  while (vh ~/ vstep > 240) {
                    vstep *= 2;
                  }
                  if (vstep > 1) {
                    (vecRgba, vw, vh) =
                        downsampleRgba8Step(downRgba, dw, dh, vstep);
                  }
                  try {
                    result = await _instrumentAnalyzer
                        .analyzeVectorscopeParallel(vecRgba, vw, vh);
                  } catch (_) {
                    // 并行路径失败：回退为池内单 worker 分析 + 本地渲染。
                    result = await _instrumentAnalyzer.analyze(
                        vecRgba, vw, vh, node.typeId);
                  }
                } else if (node.typeId == 'waveform') {
                  try {
                    result = await _instrumentAnalyzer.analyzeDedicated(
                        downRgba, dw, dh, node.typeId,
                        visible: waveformChannels(node.id));
                  } catch (_) {
                    // worker 侧渲染失败：回退为池内分析 + 本地渲染。
                    result = await _instrumentAnalyzer.analyze(
                        downRgba, dw, dh, node.typeId);
                  }
                } else {
                  result = await _instrumentAnalyzer.analyze(
                      downRgba, dw, dh, node.typeId);
                }
                if (token != _runToken) return;
                instrumentResults[node.id] = result;
                await _updateInstrumentImage(node.id, result);
              } catch (e, st) {
                // 单个仪器失败不影响播放，但记录错误便于诊断。
                debugPrint('仪器刷新失败 ${node.id}(${node.typeId}): $e\n'
                    '  entryW=$ew entryH=$eh rgbaLen=${rgba.length}\n$st');
              }
            }(),
        ]);
        // 播放中的仪器刷新只走 instrumentTick（局部重建）。
        if (token == _runToken) instrumentTick.value++;
      } finally {
        _instrumentBusy = false;
      }
    }();
  }
  /// 仪器 → 源预览节点映射缓存：播放中每轮刷新都用，而
  /// _findSourcePreviewNodeId 内部要 compileChain（拓扑排序），
  /// 开销大。图结构变化（连线/删节点）时清空。
  final Map<String, String?> _instrumentSrcCache = {};

  String? _instrumentSrcNodeId(IspNode node) => _instrumentSrcCache
      .putIfAbsent(node.id, () => _findSourcePreviewNodeId(node));

  String? _findSourcePreviewNodeId(IspNode instrument) {
    final conn = graph.connectionAt(instrument.id, 'in_mono') ??
        graph.connectionAt(instrument.id, 'in_yuv') ??
        graph.connectionAt(instrument.id, 'in_rgb') ??
        graph.connectionAt(instrument.id, 'in');
    if (conn == null) return null;
    final upstreamId = conn.fromNodeId;
    if (graph.nodes[upstreamId]?.typeId == 'preview') {
      return upstreamId;
    }
    for (final pNode in graph.nodes.values) {
      if (pNode.typeId == 'preview' &&
          _sharesUpstream(instrument, compileChain(graph, pNode.id))) {
        return pNode.id;
      }
    }
    return null;
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
  /// 优先读取状态覆盖值（用户通过手柄/右下角控制点调整后写入），
  /// 没有覆盖值时读节点模型上的 extraHeight 字段（从流程文件加载的值），
  /// 两者都没有才返回默认值。
  double previewExtraHeight(String nodeId) =>
      _previewExtraHeights[nodeId] ??
      graph.nodes[nodeId]?.extraHeight ??
      kDefaultPreviewExtraHeight;

  /// 最大化显示的节点 id；null 表示无最大化。
  String? maximizedNodeId;

  /// 最大化前的几何备份：nodeId → (x, y, width, extraHeight)。
  final Map<String, (double, double, double, double)> _maximizeBackup = {};

  /// 有显示区（可最大化）的节点：预览 + 调节器（HSL/RGB/YUV、色饱和度/
  /// 亮度、亮度/对比度、色彩平衡、色温）+ 高频边缘提取 + 曲线调节器 +
  /// 仪器（含音频仪器）。
  bool canMaximize(String nodeId) {
    final t = graph.nodes[nodeId]?.typeId;
    return t == 'preview' ||
        t == 'hsl_debugger' ||
        t == 'rgb_debugger' ||
        t == 'yuv_debugger' ||
        t == 'sat_bright_adjuster' ||
        t == 'bright_contrast_adjuster' ||
        t == 'color_balance' ||
        t == 'color_temp_adjuster' ||
        t == 'edge_extract' ||
        t == 'levels_curves' ||
        allInstrumentTypes.contains(t);
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
      _progressTimer?.cancel();
      _progressTimer = null;
      statusMessage = '已取消';
      notifyListeners();
    }
  }

  // ---- 流程图保存 / 打开 ----

  /// 把当前流程图（含工程名）写入 [path]（JSON 文本），
  /// 保存后工程名更新为文件名。
  Future<void> saveGraphToFile(String path) async {
    try {
      // 序列化用目标文件名作为工程名：另存为新文件名时文件里的
      // name 必须与文件名一致，否则重新打开时标签栏显示旧工程名。
      final name = p.basenameWithoutExtension(path);
      final json = <String, Object?>{'name': name, ...graph.toJson()};
      await File(path)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      graphName = name;
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

  /// 清空画布（复位）：移除全部节点与连线，所有运行状态（预览/仪器/
  /// 标签页/选中）失效。工程名清空，标签栏回到「缺省流程」。
  void clearGraph() {
    _replaceGraph(IspGraph(), null);
    statusMessage = '画布已清空';
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
    _instrumentSrcCache.clear(); // 仪器→源预览映射属于旧图（节点 id 可能撞名）
    openCodeTabs.clear();
    activeTab = 0;
    nodeOutputCaptures = {};
    nodeRunTimesUs = {};
    nodeRunOnGpu = {};
    instrumentResults = {};
    _histogramChannels.clear();
    for (final img in instrumentImages.values) {
      img.dispose();
    }
    instrumentImages.clear();
    totalFrames = null;
    // 非持有别名（见 runPreview）：置空即可，图像由下面的
    // previewImages 循环统一释放。
    _legacyPreviewImage = null;
    for (final img in previewImages.values) {
      img.dispose();
    }
    previewImages.clear();
    for (final img in previewInputImages.values) {
      img.dispose();
    }
    previewInputImages.clear();
    for (final img in brightContrastWaveforms.values) {
      img.dispose();
    }
    brightContrastWaveforms.clear();
    for (final img in brightContrastInputWaveforms.values) {
      img.dispose();
    }
    brightContrastInputWaveforms.clear();
    for (final img in hslVectorscopes.values) {
      img.dispose();
    }
    hslVectorscopes.clear();
    for (final img in hslInputVectorscopes.values) {
      img.dispose();
    }
    hslInputVectorscopes.clear();
    levelsHistograms.clear();
    levelsOutputHistograms.clear();
    measuredColorTemps.clear();
    colorTempHistograms.clear();
    selectedNodeId = null;
    selectedConnectionId = null;
    selectedConnectionIds.clear();
    _previewExtraHeights.clear();
    errors.clear();
    resetView();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    progressTick.dispose();
    _instrumentAnalyzer.dispose();
    cleanupAudioWavCache();
    // _legacyPreviewImage 是非持有别名，其图像含在 previewImages 中。
    for (final img in previewImages.values) {
      img.dispose();
    }
    for (final img in previewInputImages.values) {
      img.dispose();
    }
    for (final img in brightContrastWaveforms.values) {
      img.dispose();
    }
    for (final img in brightContrastInputWaveforms.values) {
      img.dispose();
    }
    for (final img in hslVectorscopes.values) {
      img.dispose();
    }
    for (final img in hslInputVectorscopes.values) {
      img.dispose();
    }
    for (final img in instrumentImages.values) {
      img.dispose();
    }
    super.dispose();
  }
}
