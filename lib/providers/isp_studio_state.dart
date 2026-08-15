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
import '../modules/isp_studio/pipeline/instrument_worker.dart';
import '../modules/isp_studio/pipeline/instruments.dart';
import '../modules/isp_studio/pipeline/pipeline_runner.dart';
import '../modules/isp_studio/pipeline/pipeline_worker.dart';
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

  void beginNodeDrag(String nodeId) {
    _nodeDragAccum[nodeId] = Offset.zero;
  }

  void endNodeDrag() {
    _nodeDragAccum.clear();
  }

  void removeNode(String id) {
    graph.removeNode(id);
    closeCodeTab(id);
    nodeOutputCaptures = {}; // 运行值已过期
    _instrumentSrcCache.clear();
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

  static double snapToGrid(double val, {double step = 10.0}) {
    return (val / step).round() * step;
  }

  Size? canvasViewport;

  final Map<String, ui.Image> previewImages = {};

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


  void beginNodeResize(String nodeId) {}
  void resizeNodeBy(String nodeId, Offset delta) {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    final type = IspNodeRegistry.byId(node.typeId);

    // Snap the absolute right edge: rightX = node.x + width → snap rightX.
    final oldRight = node.x + node.width;
    final snappedRight = snapToGrid(oldRight + delta.dx);
    final newWidth = (snappedRight - node.x).clamp(kMinPreviewNodeWidth, kMaxPreviewNodeWidth);

    // Snap the absolute bottom edge: bottomY = node.y + baseHeight + extraHeight.
    // Snapping only extraHeight fails when baseHeight is not a multiple of the grid.
    final oldExtra = previewExtraHeight(nodeId);
    final baseHeight = type != null ? nodeHeight(type, previewExtraHeight: 0) : 0.0;
    final oldBottom = node.y + baseHeight + oldExtra;
    final snappedBottom = snapToGrid(oldBottom + delta.dy);
    final newExtra = (snappedBottom - node.y - baseHeight)
        .clamp(kMinPreviewExtraHeight, kMaxPreviewExtraHeight);

    node.width = newWidth;
    node.extraHeight = newExtra;
    _previewExtraHeights[nodeId] = newExtra;
    notifyListeners();
  }
  void endNodeResize() {}

  void selectNode(String? id, {bool multiSelect = false}) {
    if (id == null) {
      selectedNodeIds.clear();
      selectedNodeId = null;
    } else if (multiSelect) {
      if (selectedNodeIds.contains(id)) {
        selectedNodeIds.remove(id);
      } else {
        selectedNodeIds.add(id);
      }
      selectedNodeId = selectedNodeIds.firstOrNull;
    } else {
      selectedNodeIds.clear();
      selectedNodeIds.add(id);
      selectedNodeId = id;
    }
    selectedConnectionId = null;
    notifyListeners();
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
      node.width = arg1.toDouble().clamp(kMinPreviewNodeWidth, kMaxPreviewNodeWidth);
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
    if (_nodeDragAccum.containsKey(id)) {
      // Accumulate sub-pixel delta during drag; snap whole position to grid.
      final accum = _nodeDragAccum[id]! + delta;
      final targetX = node.x + accum.dx;
      final targetY = node.y + accum.dy;
      final snappedX = snapToGrid(targetX);
      final snappedY = snapToGrid(targetY);
      // Only count what we actually moved; leave the remainder in accum.
      final movedDx = snappedX - node.x;
      final movedDy = snappedY - node.y;
      _nodeDragAccum[id] = Offset(accum.dx - movedDx, accum.dy - movedDy);
      node.x = snappedX;
      node.y = snappedY;
    } else {
      node.x += delta.dx;
      node.y += delta.dy;
    }
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
    if (error == null) {
      nodeOutputCaptures = {}; // 连接变了，运行值已过期
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
    _instrumentSrcCache.clear();
    _clearStaleConnectionSelection();
    notifyListeners();
  }

  /// 按连接 id 断开（连线中点控制点、Delete 键走这里）。
  void removeConnection(String connectionId) {
    graph.disconnect(connectionId);
    nodeOutputCaptures = {};
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

  /// 运行所有有效预览节点并更新预览图（previewImages 映射 + 向后兼容的
  /// _legacyPreviewImage/previewImage 入口）。
  Future<void> runPreview() async {
    if (isProcessing) return;

    // 收集所有可编译的预览节点。
    final previewNodes = <IspNode>[];
    for (final node in graph.nodes.values) {
      if (node.typeId == 'preview') {
        previewNodes.add(node);
      }
    }
    if (previewNodes.isEmpty) {
      statusMessage = '图中没有预览节点';
      notifyListeners();
      return;
    }

    isProcessing = true;
    progress = 0.05;
    statusMessage = '正在解析节点图与计算帧序列…';
    _lastPlaybackRgba = null; // 单次运行的节点捕获优先于过期播放帧
    _clearPlanePreviews();
    notifyListeners();
    final token = ++_runToken;
    try {
      // 以第一个预览节点为基准计算 totalFrames / dimensions。
      final firstPreview = previewNodes.first;
      List<Map<String, Object?>> firstChain;
      try {
        firstChain = _compileTo(firstPreview.id);
      } catch (e) {
        statusMessage = e.toString().replaceFirst('Bad state: ', '');
        return;
      }
      final srcTypeId = firstChain.first['typeId'] as String;
      final srcParams = firstChain.first['params'] as Map<String, Object?>;
      totalFrames = await _previewFrameCount(firstPreview, srcTypeId, srcParams);
      final frame = previewFrame.clamp(0, totalFrames! - 1);
      previewFrame = frame;
      final (w, h) = await sourceDimensions(srcTypeId, srcParams);

      int completedCount = 0;
      final totalCount = previewNodes.length;

      // 所有预览节点并行执行。
      await Future.wait([
        for (final pvNode in previewNodes)
          () async {
            try {
              List<Map<String, Object?>> chain;
              try {
                chain = compileChain(graph, pvNode.id);
              } catch (_) {
                return;
              }
              final result = await compute(runChainFrameCapturedInIsolate,
                  {'chain': chain, 'frameIndex': frame});
              if (token != _runToken) return;
              final rgba = result['rgba'] as Uint8List;
              if (pvNode.id == firstPreview.id) {
                nodeOutputCaptures =
                    (result['captures'] as Map).cast<String, Map<String, Object?>>();
              }
              final completer = Completer<ui.Image>();
              ui.decodeImageFromPixels(
                  rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
              final image = await completer.future;
              if (token != _runToken) {
                image.dispose();
                return;
              }
              previewImages.remove(pvNode.id)?.dispose();
              previewImages[pvNode.id] = image;
            } catch (_) {
              // 单个节点失败不影响其余节点。
            } finally {
              completedCount++;
              if (token == _runToken) {
                progress = 0.05 + (completedCount / totalCount) * 0.70;
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
      progress = 0.80;
      statusMessage = '正在更新示波器与分析仪器…';
      notifyListeners();

      // 仪器节点随预览刷新（并行分析，单个失败不影响预览）。
      await _runInstruments(frame, token);
      if (token != _runToken) return;

      progress = 1.0;
      statusMessage = '预览就绪 第 ${frame + 1}/$totalFrames 帧  ${w}x$h';
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
  /// 音频仪器（[audioInstrumentTypes]）不走帧流水线，由
  /// [_runAudioInstruments] 按音轨 PCM 刷新。
  Future<void> _runInstruments(int frame, int token) async {
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

              Map<String, Object?> result;
              if (rgba != null && w != null && h != null && w > 0 && h > 0) {
                final (srcRgba, srcW, srcH) = w > 64 && h > 64
                    ? downsampleRgba82x(rgba, w, h)
                    : (rgba, w, h);
                result = await _instrumentAnalyzer.analyze(srcRgba, srcW, srcH, node.typeId);
              } else {
                final chain = compileChain(graph, node.id);
                final chainRgba = await runChainFrame(chain, frame);
                final (dw, dh) = await sourceDimensions(
                    chain.first['typeId'] as String,
                    chain.first['params'] as Map<String, Object?>);
                final (srcRgba, srcW, srcH) = dw > 64 && dh > 64
                    ? downsampleRgba82x(chainRgba, dw, dh)
                    : (chainRgba, dw, dh);
                result = await _instrumentAnalyzer.analyze(srcRgba, srcW, srcH, node.typeId);
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
                progress = 0.80 + (instrumentCompleted / instrumentTotal) * 0.18;
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

  /// 有显示区（可最大化）的节点：预览 + 仪器（含音频仪器）。
  bool canMaximize(String nodeId) {
    final t = graph.nodes[nodeId]?.typeId;
    return t == 'preview' || allInstrumentTypes.contains(t);
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
    // 非持有别名（见 runPreview）：置空即可，图像由下面的
    // previewImages 循环统一释放。
    _legacyPreviewImage = null;
    for (final img in previewImages.values) {
      img.dispose();
    }
    previewImages.clear();
    selectedNodeId = null;
    selectedConnectionId = null;
    _previewExtraHeights.clear();
    errors.clear();
    resetView();
  }

  @override
  void dispose() {
    _instrumentAnalyzer.dispose();
    cleanupAudioWavCache();
    // _legacyPreviewImage 是非持有别名，其图像含在 previewImages 中。
    for (final img in previewImages.values) {
      img.dispose();
    }
    for (final img in instrumentImages.values) {
      img.dispose();
    }
    super.dispose();
  }
}
