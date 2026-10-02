import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'dart:ui' show Offset, Rect, Size;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;

import '../modules/isp_studio/models/isp_align_mode.dart';
import '../modules/isp_studio/models/isp_graph.dart';
import '../modules/isp_studio/models/isp_node.dart';
import '../modules/isp_studio/pipeline/audio_analysis.dart';
import '../modules/isp_studio/pipeline/audio_player.dart';
import '../modules/isp_studio/pipeline/export_progress.dart';
import '../modules/isp_studio/pipeline/export_segments.dart';
import '../modules/isp_studio/pipeline/exporters.dart';
import '../modules/isp_studio/pipeline/format_convert.dart' as fmtconv;
import '../modules/isp_studio/pipeline/video_health.dart' as vhealth;
import '../modules/isp_studio/pipeline/image_source.dart';
import '../modules/isp_studio/pipeline/ilniqe.dart';
import '../modules/isp_studio/pipeline/instrument_worker.dart';
import '../modules/isp_studio/pipeline/instruments.dart';
import '../modules/isp_studio/pipeline/metrics/clipiqa_dart.dart';
import '../modules/isp_studio/pipeline/metrics/dists_dart.dart';
import '../modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import '../modules/isp_studio/pipeline/metrics/inception_dart.dart';
import '../modules/isp_studio/pipeline/metrics/kid_score_worker.dart';
import '../modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import '../modules/isp_studio/pipeline/metrics/musiq_dart.dart';
import '../modules/isp_studio/pipeline/metrics/vgg16_gpu.dart';
import '../modules/isp_studio/pipeline/metrics/clip_rn50_gpu.dart';
import '../modules/isp_studio/pipeline/metrics/inception_v3_gpu.dart';
import '../modules/isp_studio/pipeline/node_c_code.dart';
import '../modules/isp_studio/pipeline/nn/nn_gpu.dart';
import '../modules/isp_studio/pipeline/nn/nn_pool.dart';
import '../modules/isp_studio/pipeline/pipeline_runner.dart';
import '../modules/isp_studio/pipeline/pipeline_worker.dart';
import '../modules/isp_studio/pipeline/pyiqa_worker.dart';
import '../modules/isp_studio/pipeline/dng_source.dart';
import '../modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import '../modules/isp_studio/pipeline/raw_sidecar.dart';
import '../modules/isp_studio/pipeline/video_source.dart';
import '../modules/isp_studio/widgets/node_layout.dart';

/// GPU 平面预览帧：视频 yuv420p 直出帧原样打包成的单张纹理
/// （宽 w/4、高 h*3/2，RGBA 纹素各装 4 个连续样本）+ 显示模式。
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

  /// YUV→RGB 色彩矩阵（0=BT.601，1=BT.709，2=BT.2020；随片源元数据，
  /// 见 VideoInfo.colorMatrix）。
  final int matrix;

  const PlanePreviewFrame(
      this.packed, this.mode, this.width, this.height, this.limited,
      [this.matrix = 0]);
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

/// 深度评价指标进程内 Dart 计算所需的权重文件（相对工作目录，由
/// tools/iqa/export_weights.py 一次性导出）。齐全时节点走进程内计算，
/// 不再依赖 Python 环境。测试可临时改写以模拟权重缺失（验证回退/
/// 报错路径，用后须还原）。
Map<String, List<String>> deepIqaWeightFiles = {
  'lpips': [lpipsVggWeightsPath, lpipsLinWeightsPath],
  'dists': [distsVggWeightsPath, distsWeightsPath],
  'fid': [inceptionV3WeightsPath],
  'kid': [inceptionV3WeightsPath],
  'musiq': [musiqWeightsPath],
  'clipiqa': [clipiqaWeightsPath],
};

/// [kind] 指标的进程内计算权重是否齐全（见 [deepIqaWeightFiles]）。
bool deepIqaWeightsAvailable(String kind) =>
    (deepIqaWeightFiles[kind] ?? const []).every((f) => File(f).existsSync());

/// FID 进程内（Dart 路径）的逐帧累计状态：两侧 patch 特征分块
/// 驻留，出分时拼接为 [n,2048] 连续排布交后台 isolate 计算（FID 的
/// 2048² 协方差/特征值（低秩快路径归约）为重计算，见
/// fidScoreInIsolate）。KID 的累计/出分走常驻 isolate 的增量核矩阵
///（kid_score_worker.dart / KidGramAccum），不使用本类。
class _DeepIqaDistAccum {
  final List<Float32List> refChunks = [];
  final List<Float32List> testChunks = [];
  int nRef = 0;
  int nTest = 0;

  void reset() {
    refChunks.clear();
    testChunks.clear();
    nRef = 0;
    nTest = 0;
  }

  /// 累计一帧：两侧各为 [n,2048] 连续排布的 patch 特征。
  void add(Float32List refFeats, Float32List testFeats) {
    refChunks.add(refFeats);
    nRef += refFeats.length ~/ fidFeatureDim;
    testChunks.add(testFeats);
    nTest += testFeats.length ~/ fidFeatureDim;
  }

  static Float32List _concatSide(List<Float32List> chunks, int n) {
    final out = Float32List(n * fidFeatureDim);
    var off = 0;
    for (final c in chunks) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    return out;
  }

  /// 拼接两侧特征为 [n,2048] 连续排布（出分时调用一次）。
  (Float32List, Float32List) concat() =>
      (_concatSide(refChunks, nRef), _concatSide(testChunks, nTest));
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

  /// 已打开代码标签页（按打开顺序）：节点标签存节点 id，编组标签存
  /// 'group:<编组id>' 前缀串。
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

  /// 打开（或激活）某编组的代码标签页。
  void openGroupCodeTab(String groupId) {
    if (!graph.groups.any((g) => g.id == groupId)) return;
    final key = 'group:$groupId';
    final i = openCodeTabs.indexOf(key);
    if (i >= 0) {
      activeTab = i + 1;
    } else {
      openCodeTabs.add(key);
      activeTab = openCodeTabs.length;
    }
    notifyListeners();
  }

  /// 打开编组黑盒（行级流水）代码标签页（key 前缀 'gbb:'）。
  void openGroupBlackBoxCodeTab(String groupId) {
    if (!graph.groups.any((g) => g.id == groupId)) return;
    final key = 'gbb:$groupId';
    final i = openCodeTabs.indexOf(key);
    if (i >= 0) {
      activeTab = i + 1;
    } else {
      openCodeTabs.add(key);
      activeTab = openCodeTabs.length;
    }
    notifyListeners();
  }

  /// 关闭某节点/编组的代码标签页，活动标签落到相邻标签上。
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

  /// 实时预览脏标记：拖动滑块等连续调参期间请求了重跑但当时正在运行。
  bool _livePreviewDirty = false;

  /// 连续调参（如拖动色彩控制器 ΔH 滑块）时的实时预览：空闲直接重跑，
  /// 运行中则置脏标记、当前运行结束后用最新参数合并补跑一次。
  void requestLivePreview() {
    if (isProcessing) {
      _livePreviewDirty = true;
      return;
    }
    runPreview();
  }

  double progress = 0;
  String statusMessage = '';
  final List<String> errors = [];

  /// 格式转换节点（format_converter）的内嵌终端全文：节点 id → 已追加
  /// 的 ffmpeg 输出（经 appendConsoleText 做 \r 覆盖行处理）。
  final formatConvertLogs = <String, String>{};

  /// 格式转换进行中的节点 id 集合（按钮禁用/文案切换用，防重入）。
  final formatConvertRunning = <String>{};

  /// 格式转换终端刷新信号：终端面板唯一监听它（ValueListenableBuilder
  /// 局部重建），onOutput 高频回调只动它不 notifyListeners
  /// （参照 instrumentTick 模式）。
  final ValueNotifier<int> formatConvertTick = ValueNotifier(0);

  /// 格式转换节点：实测可用的硬件编码器 id 列表（probeHwEncoders 探测
  /// 缓存，供属性面板编码器下拉与 auto 尝试链使用）。
  List<String> hwEncoders = const [];

  /// 硬件编码器探测进行中标记（属性面板据此显示「探测中…」）。
  bool hwEncoderProbing = false;

  /// 硬件编码器探测已完成标记：无硬件的机器探测结果为空表，靠它避免
  /// 属性面板每次重建都重新触发探测。
  bool hwEncoderProbed = false;

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

  /// [_imageSourceRgba] 的在途解码去重：并发调用方共享同一次后台
  /// 解码（多仪器并发启动时同一文件不再重复解码）。
  final Map<String, Future<(Uint8List, int, int)>> _imageSourceRgbaInFlight =
      {};

  /// 取图片源的 RGBA8888 解码结果（缓存命中直接返回；未命中后台
  /// isolate 解码并缓存；在途解码去重）。文件不存在/无法解码时抛
  /// [StateError]。
  Future<(Uint8List, int, int)> _imageSourceRgba(String filePath) async {
    final stat = await File(filePath).stat();
    final mtime = stat.modified.millisecondsSinceEpoch;
    final cached = _imageSourceRgbaCache[filePath];
    if (cached != null && cached.$4 == mtime && cached.$5 == stat.size) {
      return (cached.$1, cached.$2, cached.$3);
    }
    return _imageSourceRgbaInFlight.putIfAbsent(filePath, () async {
      try {
        // 简易容量上限：图片帧很大（20MP ≈ 81MB），不长期累积。
        if (_imageSourceRgbaCache.length >= 4) _imageSourceRgbaCache.clear();
        final (rgba, w, h) = await compute(decodeImageFileToRgba8, filePath);
        _imageSourceRgbaCache[filePath] = (rgba, w, h, mtime, stat.size);
        return (rgba, w, h);
      } finally {
        _imageSourceRgbaInFlight.remove(filePath);
      }
    });
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
    _gpu ??= await GpuPipeline.tryCreate();
    final g = _gpu;
    if (g == null) _gpuUnavailable = true;
    return g;
  }

  /// 仪器节点最近一次分析结果（nodeId → analyzeInstrumentInIsolate 的
  /// 返回 map），随预览运行刷新；直方图数据由节点控件直接绘制。
  Map<String, Map<String, Object?>> instrumentResults = {};

  /// 最值保持器（minmax）节点的跨帧保持值：nodeId → (保持最大, 保持最小)。
  /// 每次仪器刷新时按当帧结果累计（取历史极值），[resetMinmaxHold] 复位。
  final Map<String, (int, int)> _minmaxHold = {};

  /// FID/KID（分布级深度评价）节点的样本复位标记：nodeId → 最近一次
  /// 复位时所属的运行轮次 token。新一轮运行（token 变化）时先清空
  /// 累计样本（进程内 Dart 路径清 [_deepIqaDist]，Python 桥接路径清
  /// 桥接进程的累计特征）再逐帧 add（见 _analyzeDeepIqa/_analyzePyIqa）。
  final Map<String, int> _pyiqaDistTokens = {};

  /// FID/KID 进程内 Dart 路径的逐帧累计状态（nodeId → 两侧 patch
  /// 特征）。复位时机同 [_pyiqaDistTokens]；图替换/节点移除时清理。
  /// KID 的累计/出分已改走 [_kidWorkers]（增量核矩阵），本表仅 FID
  /// 使用。
  final Map<String, _DeepIqaDistAccum> _deepIqaDist = {};

  /// KID 节点的常驻出分 isolate（nodeId → worker，懒创建）：worker 内
  /// 持有增量核矩阵（KidGramAccum），每帧只发新增特征、只算核矩阵
  /// 新增块，替代每帧全量特征拼接 + Gram 重算；出分与全量重算逐位
  /// 一致。新一轮运行（token 变化）时 dispose 重建（见
  /// [_analyzeDeepIqa] dist 分支）；图替换/节点移除时清理。
  final Map<String, KidScoreWorker> _kidWorkers = {};

  /// 单次运行内的 Inception patch 特征缓存（双路馈源键 → 两侧特征
  /// Future）：同一次运行内 FID 与 KID 节点接同一对源时只算一次。
  /// 每次 [_runInstruments] 开始清空（与 _instrumentFeedCache 同
  /// 生命周期）。
  final Map<String, Future<(Float32List, Float32List)>> _deepIqaFeatCache =
      {};

  /// 进程内深度评价的共享 NN isolate 池（懒创建，[dispose] 时关闭）。
  NnPool? _nnPool;
  Future<NnPool>? _nnPoolStart;

  /// 取共享 NN 池（首次调用时启动；worker 数缺省按 CPU 核数 - 2，
  /// 限幅 [1,16]，见 NnPool.start）。池内请求按 id 路由应答，支持
  /// 多指标并发共用。
  Future<NnPool> _sharedNnPool() {
    final running = _nnPool;
    if (running != null) return Future.value(running);
    return _nnPoolStart ??= () async {
      final pool = NnPool();
      // worker 数显式限为 核数-4（NnPool 缺省 核数-2 不动）：给
      // UI/raster 线程留出物理核，避免 GPU 链派发与消息泵在 MUSIQ 等
      // 重 CPU 指标窗口被饿死（真机实测：MUSIQ 窗口内 LPIPS 从基准
      // 57s 被拖到 462s、标题栏「未响应」，优化 7）。
      await pool.start(math.max(2, Platform.numberOfProcessors - 4));
      _nnPool = pool;
      _nnPoolStart = null;
      return pool;
    }();
  }

  /// LPIPS/DISTS 共用的 VGG16 GPU 纹理驻留链（懒创建，仅 UI isolate
  /// 可用；shader/权重任一初始化失败则保持 null 且不再重试，指标计算
  /// 自动回退 [_sharedNnPool] 的 CPU 池路径）。
  ///
  /// 竞态修复：getter 与后端创建均**缓存 in-flight Future**（同
  /// [_sharedNnPool] 的 _nnPoolStart 模式）——并发调用共享同一次
  /// load、全部拿到同一结果；load 失败缓存 null（保持「不再重试」
  /// 语义）。此前「先置 tried 再 await」会让并发的第二个调用者拿到
  /// null 退化到 CPU 全核慢路径。
  GpuNnBackend? _gpuNnBackend;
  Future<GpuNnBackend?>? _gpuNnBackendStart;
  Vgg16Gpu? _vggGpu;
  Future<Vgg16Gpu?>? _vggGpuStart;
  ClipRn50Gpu? _rn50Gpu;
  Future<ClipRn50Gpu?>? _rn50GpuStart;
  InceptionV3Gpu? _inceptionGpu;
  Future<InceptionV3Gpu?>? _inceptionGpuStart;

  /// FID/KID patch 特征是否由 GPU 链产出（_deepIqaFeatCache 键 → 后端），
  /// 用于缓存命中时回填节点徽标。
  final Map<String, bool> _deepIqaFeatOnGpu = {};

  /// 取共享 GPU NN 后端（shader 加载一次；失败缓存 null 不再重试）。
  Future<GpuNnBackend?> _sharedGpuNnBackend() {
    final b = _gpuNnBackend;
    if (b != null) return Future.value(b);
    return _gpuNnBackendStart ??= () async {
      final g = await GpuNnBackend.tryCreate();
      _gpuNnBackend = g; // null 也缓存：shader 加载失败重试无意义
      return g;
    }();
  }

  /// 取共享 VGG16 GPU 链（权重随 [lpipsVggWeightsPath] 加载一次；
  /// 两路输入共享已上传权重、各自独立执行）。
  Future<Vgg16Gpu?> _sharedVggGpu() {
    final v = _vggGpu;
    if (v != null) return Future.value(v);
    return _vggGpuStart ??= () async {
      final g = await _sharedGpuNnBackend();
      if (g == null) return null;
      Vgg16Gpu? loaded;
      try {
        loaded = await Vgg16Gpu.load(g, lpipsVggWeightsPath);
      } catch (e) {
        // ignore: avoid_print
        print('[IspStudioState] VGG16 GPU 链初始化失败，回退 CPU 池: $e');
      }
      _vggGpu = loaded; // 失败缓存 null（不再重试）
      return loaded;
    }();
  }

  /// 取共享 RN50 GPU 链（CLIPIQA 主干，权重随 [clipiqaWeightsPath]
  /// 加载一次；AttentionPool2d 仍走 [_sharedNnPool] CPU 池）。
  Future<ClipRn50Gpu?> _sharedRn50Gpu() {
    final v = _rn50Gpu;
    if (v != null) return Future.value(v);
    return _rn50GpuStart ??= () async {
      final g = await _sharedGpuNnBackend();
      if (g == null) return null;
      ClipRn50Gpu? loaded;
      try {
        loaded = await ClipRn50Gpu.load(g, clipiqaWeightsPath);
      } catch (e) {
        // ignore: avoid_print
        print('[IspStudioState] RN50 GPU 链初始化失败，回退 CPU 池: $e');
      }
      _rn50Gpu = loaded; // 失败缓存 null（不再重试）
      return loaded;
    }();
  }

  /// 取共享 InceptionV3 GPU 链（FID/KID patch 特征，权重随
  /// [inceptionV3WeightsPath] 加载一次）。
  Future<InceptionV3Gpu?> _sharedInceptionGpu() {
    final v = _inceptionGpu;
    if (v != null) return Future.value(v);
    return _inceptionGpuStart ??= () async {
      final g = await _sharedGpuNnBackend();
      if (g == null) return null;
      InceptionV3Gpu? loaded;
      try {
        loaded = await InceptionV3Gpu.load(g, inceptionV3WeightsPath);
      } catch (e) {
        // ignore: avoid_print
        print('[IspStudioState] InceptionV3 GPU 链初始化失败，回退 CPU 池: $e');
      }
      _inceptionGpu = loaded; // 失败缓存 null（不再重试）
      return loaded;
    }();
  }

  /// GPU 链类深度评价节点（优化 6 并发治理）：共享同一 GPU 与同一 UI
  /// 派发通道，互斥执行（信号量=1）让每条链全速派发；KID 排在 FID
  /// 后还能命中 [_deepIqaFeatCache] 接近免费。
  static const _gpuChainMetricTypes = {
    'lpips', 'dists', 'fid', 'kid', 'clipiqa',
  };

  /// 重 CPU 仪器节点（优化 6 并发治理）：限并发 ≤2，避免与 NnPool
  /// worker + 嵌套 Isolate.run 叠加超订打满 CPU 核饿死 UI isolate
  /// （GPU 派发与消息泵都在 UI isolate）。
  static const _heavyCpuInstrumentTypes = {
    'musiq', 'niqe', 'brisque', 'ilniqe', 'piqe',
    'psnr', 'ssim', 'msssim', 'fsim',
  };

  /// [_gpuChainMetricTypes] 的互斥锁链（见 [_gpuMetricLock]）。
  Future<void> _gpuMetricTurn = Future.value();

  /// [_heavyCpuInstrumentTypes] 的信号量状态（见 [_heavyCpuLock]）。
  var _heavyCpuRunning = 0;
  final _heavyCpuWaiters = <Completer<void>>[];

  /// GPU 链类指标互斥执行：调用按到达顺序串行，[fn] 抛错不中断后续
  /// 排队者。token 取消语义由 [fn] 自身保持（锁不改变任何分析行为）。
  Future<T> _gpuMetricLock<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _gpuMetricTurn = _gpuMetricTurn.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 重 CPU 指标限并发执行（同时 ≤2 个，FIFO 唤醒）。
  Future<T> _heavyCpuLock<T>(Future<T> Function() fn) async {
    while (_heavyCpuRunning >= 2) {
      final waiter = Completer<void>();
      _heavyCpuWaiters.add(waiter);
      await waiter.future;
    }
    _heavyCpuRunning++;
    try {
      return await fn();
    } finally {
      _heavyCpuRunning--;
      if (_heavyCpuWaiters.isNotEmpty) {
        _heavyCpuWaiters.removeAt(0).complete();
      }
    }
  }

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

  /// 节点宽度上限：调节器（HSL/RGB/YUV、色彩控制器、色饱和度/亮度、
  /// 亮度/对比度、色彩平衡、色温）、高频边缘提取与曲线调节器为附加显示区需要更宽，
  /// 放宽到全局上限的 1.6 倍；多段色彩均衡器（示波器+预览双行，配合
  /// 加高上限需要更宽）再放宽到其 1.5 倍（全局的 2.4 倍）；预览节点
  /// 放宽到全局上限的 1.5 倍；其余节点用全局上限。
  static double maxNodeWidthFor(String typeId) =>
      typeId == 'multi_band_eq'
          ? kMaxPreviewNodeWidth * 1.6 * 1.5
          : typeId == 'format_converter' || typeId == 'video_health_check'
              // 格式转换/视频健康检查节点尺寸固定 1500x1200（min=max，不可调）。
              ? 1500
              : typeId == 'preview'
              ? kMaxPreviewNodeWidth * 1.5
              : (typeId == 'hsl_debugger' ||
                  typeId == 'color_controller' ||
                  typeId == 'rgb_debugger' ||
                  typeId == 'yuv_debugger' ||
                  typeId == 'sat_bright_adjuster' ||
                  typeId == 'bright_contrast_adjuster' ||
                  typeId == 'gaussian_blur' ||
                  typeId == 'color_balance' ||
                  typeId == 'color_temp_adjuster' ||
                  typeId == 'edge_extract' ||
                  typeId == 'levels_curves')
                  ? kMaxPreviewNodeWidth * 1.6
                  : kMaxPreviewNodeWidth;

  /// 节点宽度下限：格式转换/视频健康检查节点内嵌终端固定 1500x1200
  ///（min=max，不可调；ffmpeg 处理信息整页可读）；其余节点用全局下限。
  static double minNodeWidthFor(String typeId) =>
      typeId == 'format_converter' || typeId == 'video_health_check'
          ? 1500
          : kMinPreviewNodeWidth;

  /// 节点附加区高度下限：格式转换/视频健康检查节点 1162（标题 30 +
  /// 底部留白 8 + extra = 总高 1200）；其余节点用全局下限。
  static double minExtraHeightFor(String typeId) =>
      typeId == 'format_converter' || typeId == 'video_health_check'
          ? 1162
          : kMinPreviewExtraHeight;

  /// 节点附加区高度上限：多段色彩均衡器（矢量示波器 + 预览图双行显示，
  /// 预览图需要更大加高空间）放宽到全局上限的 2 倍；预览节点放宽到
  /// 全局上限的 1.5 倍；格式转换节点固定 1162（总高 1200，min=max 不
  /// 可调）；其余节点用全局上限。
  static double maxPreviewExtraHeightFor(String typeId) =>
      typeId == 'multi_band_eq'
          ? kMaxPreviewExtraHeight * 2
          : typeId == 'format_converter' || typeId == 'video_health_check'
              ? 1162
              : typeId == 'preview'
                  ? kMaxPreviewExtraHeight * 1.5
                  : kMaxPreviewExtraHeight;
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

  void addNodeAt(String typeId, Offset canvasPos, {bool centered = false}) {
    var dx = canvasPos.dx, dy = canvasPos.dy;
    // centered：落点 = 节点**中心**对齐聚点（大节点如 Tools 的
    // 1500x1200 按左上角落点会整体偏到视口右下，观感是"没有居中"；
    // 缺省保持左上角落点——测试与既有调用方的坐标语义不变）。
    if (centered) {
      final type = IspNodeRegistry.byId(typeId);
      if (type != null) {
        final probe = IspNode.create(type, '_probe', 0, 0);
        dx -= probe.width / 2;
        dy -= nodeHeight(type, previewExtraHeight: probe.extraHeight) / 2;
      }
    }
    final snappedX = snapToGrid(dx);
    final snappedY = snapToGrid(dy);
    final id = graph.addNode(typeId, snappedX, snappedY);
    selectedNodeId = id;
    notifyListeners();
  }

  // Accumulated sub-pixel drag delta per node (cleared on endNodeDrag).
  final Map<String, Offset> _nodeDragAccum = {};

  /// 当前拖动组：被拖节点属于编组时整组同步移动；若被拖节点还在
  /// 更大的多选集合内，则整个多选集合同步移动。
  final Set<String> _dragGroupIds = {};

  void beginNodeDrag(String nodeId) {
    _dragGroupIds
      ..clear()
      ..add(nodeId);
    // 编组联动：拖动编组内任一节点等同于拖动整个编组。
    final gid = groupIdOf(nodeId);
    if (gid != null) {
      _dragGroupIds.addAll(
          graph.groups.firstWhere((g) => g.id == gid).nodeIds);
    }
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
    _minmaxHold.remove(id);
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

  /// HSL 调节器节点的矢量示波器图（hsl_debugger / color_controller /
  /// multi_band_eq 使用，键为节点 id；由输出链末端 RGBA 经 vectorscope
  /// 统计渲染，与 vectorscope 仪器同一口径）。所有权与释放规则同
  /// [previewImages]。
  final Map<String, ui.Image> hslVectorscopes = {};

  /// 「调整前」输入矢量示波器图（由输入链末端 RGBA 统计，左半区显示；
  /// 使用节点同 [hslVectorscopes]）。所有权与释放规则同 [previewImages]。
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

  /// 换帧淘汰的打包纹理（双缓冲：延迟一帧释放——GL 纹理删除若与
  /// 上传串行，立即释放会把开销顶在发布帧上）。
  ui.Image? _planePackedRetire;

  /// yuv_planes.frag 着色器实例（GPU 平面预览播放时加载；失败回退 CPU）。
  ui.FragmentShader? yuvPlaneShader;

  /// 释放共享打包纹理并清空平面预览（播放停止/单次运行时调用；
  /// 逐帧换帧走 [_retirePlanePacked] 延迟释放）。
  void _clearPlanePreviews() {
    if (previewPlanes.isNotEmpty) {
      previewPlanes.values.first.packed.dispose();
      previewPlanes = {};
    }
    _planePackedRetire?.dispose();
    _planePackedRetire = null;
  }

  /// 换帧时淘汰上一张共享打包纹理：释放的是上上一张（延迟一帧）。
  void _retirePlanePacked() {
    final old =
        previewPlanes.isNotEmpty ? previewPlanes.values.first.packed : null;
    _planePackedRetire?.dispose();
    _planePackedRetire = old;
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


  /// 最值保持器：把当帧结果并入跨帧保持值（保持最大/最小 = 自复位
  /// 以来的历史极值），保持值写回结果 map（holdMax/holdMin）供节点显示。
  Map<String, Object?> _mergeMinmaxHold(
      String nodeId, Map<String, Object?> result) {
    final curMax = result['max'] as int?;
    final curMin = result['min'] as int?;
    if (curMax == null || curMin == null) return result;
    final prev = _minmaxHold[nodeId];
    final holdMax = prev == null ? curMax : math.max(prev.$1, curMax);
    final holdMin = prev == null ? curMin : math.min(prev.$2, curMin);
    _minmaxHold[nodeId] = (holdMax, holdMin);
    result['holdMax'] = holdMax;
    result['holdMin'] = holdMin;
    return result;
  }

  /// 复位最值保持器的跨帧保持值：清除后显示回到当前帧口径，
  /// 下一次仪器刷新从该帧重新累计。
  void resetMinmaxHold(String nodeId) {
    _minmaxHold.remove(nodeId);
    instrumentResults[nodeId]
      ?..remove('holdMax')
      ..remove('holdMin');
    // 仪器附加区靠 instrumentTick 局部重建（同波形通道切换）。
    instrumentTick.value++;
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
      case 'gaussian_blur':
      case 'color_balance':
      case 'color_temp_adjuster':
      case 'edge_extract':
        // 双联对比图（左调整前/右调整后），每格内容为图像本身。
        final img = previewImages[node.id] ?? previewInputImages[node.id];
        if (img != null && img.height > 0) return 2.0 * img.width / img.height;
        return null;
      case 'multi_band_eq':
        // 上双联矢量示波器（格 1:1，高 = 半格宽）+ 下双联对比图，
        // 内容高 = 半宽 × (1 + 图高/图宽)，故整体纵横比如下。
        final img = previewImages[node.id] ?? previewInputImages[node.id];
        if (img != null && img.height > 0) {
          return 2.0 * img.width / (img.width + img.height);
        }
        return null;
      case 'hsl_debugger':
      case 'color_controller':
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
        'color_controller' => (20.0, 134.0), // 滑块 24*5
        // 工具栏 26 + 示波器/图像行间隔 4 + 滑块 24*5
        'multi_band_eq' => (20.0, 164.0),
        'gaussian_blur' => (20.0, 62.0), // 滑块 24*2
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
        .clamp(minNodeWidthFor(node.typeId), maxNodeWidthFor(node.typeId));

    // Snap the absolute bottom edge: bottomY = node.y + baseHeight + extraHeight.
    // Snapping only extraHeight fails when baseHeight is not a multiple of the grid.
    final oldExtra = previewExtraHeight(nodeId);
    final baseHeight = type != null ? nodeHeight(type, previewExtraHeight: 0) : 0.0;
    final oldBottom = node.y + baseHeight + oldExtra;
    final snappedBottom = snapToGrid(oldBottom + delta.dy);
    var newExtra = (snappedBottom - node.y - baseHeight)
        .clamp(minExtraHeightFor(node.typeId), maxPreviewExtraHeightFor(node.typeId));

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
            .clamp(minExtraHeightFor(node.typeId), maxPreviewExtraHeightFor(node.typeId));
      } else {
        // 纵向为主（中部手柄恒为纵向）：宽度跟随高度。
        newWidth = ((newExtra - chromeH) * aspect + chromeW)
            .clamp(minNodeWidthFor(node.typeId), maxNodeWidthFor(node.typeId));
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

  /// 当前选择是否可以编组：至少 2 个节点，且没有任何成员已在编组中
  ///（已编组节点须先取消编组，才允许参与新的编组）。例外：多段色彩
  /// 均衡器等效于多个色彩控制器的混叠，单节点也允许编组（编组后即可
  /// 经右键菜单查看/导出 C 代码）。
  bool get canGroupSelectedNodes {
    if (selectedNodeIds.length == 1) {
      final id = selectedNodeIds.first;
      return groupIdOf(id) == null &&
          graph.nodes[id]?.typeId == 'multi_band_eq';
    }
    if (selectedNodeIds.length < 2) return false;
    for (final id in selectedNodeIds) {
      if (groupIdOf(id) != null) return false;
    }
    return true;
  }

  /// 当前多选是否混合了「可导出 C」（嵌入式相关，nodeCCodeFiles 中有
  /// 映射）与「不可导出 C」两类节点。混合时不允许编组：编组框用于
  /// 圈定一个可整体导出/查看的嵌入式单元，两类混合没有对应形态。
  bool get selectionMixesCExportNodes {
    var hasC = false, hasNonC = false;
    for (final id in selectedNodeIds) {
      final typeId = graph.nodes[id]?.typeId;
      if (typeId == null) continue;
      if (nodeCCodeFiles.containsKey(typeId)) {
        hasC = true;
      } else {
        hasNonC = true;
      }
      if (hasC && hasNonC) return true;
    }
    return false;
  }

  /// 把当前多选节点编为一组。选择中已含编组成员、或混合了可/不可
  /// 导出 C 两类节点时不做任何改动（见 [canGroupSelectedNodes]、
  /// [selectionMixesCExportNodes]）。一个节点至多属于一个组。
  /// [name] 缺省时自动生成「编组#N」。
  void groupSelectedNodes({String? name}) {
    final members =
        selectedNodeIds.where((id) => graph.nodes.containsKey(id)).toSet();
    // 例外：多段色彩均衡器允许单节点编组（见 canGroupSelectedNodes）。
    if (members.length < 2 &&
        !(members.length == 1 &&
            graph.nodes[members.first]?.typeId == 'multi_band_eq')) {
      return;
    }
    if (members.any((id) => groupIdOf(id) != null)) return;
    if (selectionMixesCExportNodes) return;
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

  /// 解散指定编组（同时关闭其代码标签页）。
  void ungroup(String groupId) {
    final before = graph.groups.length;
    graph.groups.removeWhere((g) => g.id == groupId);
    if (graph.groups.length != before) {
      closeCodeTab('group:$groupId');
      closeCodeTab('gbb:$groupId');
      notifyListeners();
    }
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
          .clamp(minNodeWidthFor(node.typeId), maxNodeWidthFor(node.typeId));
      final clampedH = extraHeight.clamp(
          minExtraHeightFor(node.typeId), maxPreviewExtraHeightFor(node.typeId));
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
    // 多段色彩均衡器：色彩风格预设（标题栏「（文件名）」标注）被任何
    // 配置调整后清除——选中段切换与风格名自身写入除外。
    if (node.typeId == 'multi_band_eq' &&
        key != 'sel_band' &&
        key != 'style_name') {
      node.paramValues.remove('style_name');
    }
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

  /// 批量写参数：等价于多次 [setParam] 合并为单次 notifyListeners。
  /// 不含 filePath 等键的联动副作用（目前用于多段色彩均衡器的段参数
  /// 批量写入/预设恢复）；value 为 null 时写入 null，读取侧按缺键
  /// 回退默认（「缺键=恒等」语义）。
  void setParams(String nodeId, Map<String, Object?> values) {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    node.paramValues.addAll(values);
    // 同上：批量写含配置键时清除风格名（预设读取在同一批写入
    // style_name 的情况除外——见 values 含 style_name 的保留分支）。
    if (node.typeId == 'multi_band_eq' &&
        !values.containsKey('style_name') &&
        values.keys.any((k) => k != 'sel_band' && k != 'style_name')) {
      node.paramValues.remove('style_name');
    }
    totalFrames = null;
    nodeOutputCaptures = {};
    nodeRunTimesUs = {}; // 运行值已过期
    nodeRunOnGpu = {}; // 同上
    notifyListeners();
  }

  /// 视频源文件路径对应的帧率/总帧数（ffmpeg 解析）自动填充到下游
  /// 预览节点的「播放帧率」与「预览帧数」参数；多段色彩均衡器同为
  /// 播放汇点（其附加区含播放控制条），一并填充。失败静默。
  Future<void> autoFillFromVideo(String sourceId) async {
    final node = graph.nodes[sourceId];
    if (node == null || node.typeId != 'video_source') return;
    final path = node.paramValues['filePath']?.toString() ?? '';
    if (path.isEmpty) return;
    try {
      final info = await videoFileInfo(path,
          ffmpegPath: node.paramValues['ffmpegPath']?.toString() ?? '');
      // 预览节点 HDR/SDR 切换按钮的显示形态：选完文件未播放即正确显示。
      if (playbackSrcTransfer != info.colorTransfer) {
        playbackSrcTransfer = info.colorTransfer;
        notifyListeners();
      }
      final fps = info.fps.round().clamp(1, 60);
      var changed = false;
      for (final n in graph.nodes.values) {
        if (n.typeId != 'preview' && n.typeId != 'multi_band_eq') continue;
        // 只填位于该源下游的预览/均衡器节点。
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

  /// 运行预览后：把各视频输出节点的「帧率」参数自动对齐其上游视频源的
  /// 原生帧率（ffmpeg 解析，经 videoFileInfo 缓存，重复运行无额外进程
  /// 开销）。无上游视频源或解析失败时保持参数原值。
  Future<void> _autoFillVideoOutputFps() async {
    var changed = false;
    for (final node in graph.nodes.values) {
      if (node.typeId != 'video_output') continue;
      String? srcId;
      for (final upId in graph.upstreamOf(node.id)) {
        if (graph.nodes[upId]?.typeId == 'video_source') {
          srcId = upId;
          break;
        }
      }
      if (srcId == null) continue;
      final src = graph.nodes[srcId]!;
      final path = src.paramValues['filePath']?.toString() ?? '';
      if (path.isEmpty) continue;
      try {
        final info = await videoFileInfo(path,
            ffmpegPath: src.paramValues['ffmpegPath']?.toString() ?? '');
        final fps = info.fps.round().clamp(1, 120);
        if (node.paramValues['fps'] != fps) {
          node.paramValues['fps'] = fps;
          changed = true;
        }
      } catch (_) {
        // ffmpeg 不可用或解析失败：静默，保持参数原值。
      }
    }
    if (changed) notifyListeners();
  }
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
      // HSL 调节器/色彩控制器/多段色彩均衡器矢量示波器馈源：被 GPU 覆盖
      // 的 hsl_debugger / color_controller / multi_band_eq 节点不再走
      // CPU 闭包（其矢量图在那里由链末端 RGBA 统计），此处对其自身输出
      // 与输入链末端端口做同样的 RGBA 回读，运行后据此渲染矢量图。
      // 键为回读端口 'nodeId:port'，值为目标缓存 key（节点 id = 调整后，
      // 'id#in' = 调整前）。
      final hslScopeFeeds = <String, String>{};
      for (final node in graph.nodes.values) {
        if (node.typeId != 'hsl_debugger' &&
            node.typeId != 'color_controller' &&
            node.typeId != 'multi_band_eq') {
          continue;
        }
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

  /// 停播（暂停）时刷新多段色彩均衡器的双联矢量示波器：以最后一帧
  /// 「调整后/调整前」预览图为馈源统计补齐（播放中已由
  /// [_refreshEqScopesFromPlayback] 按 ~5Hz 节流刷新，此处落定最终帧）。
  /// 统计渲染与单次预览同口径（[_hslVectorscopeImage]；CPU 路径预览图
  /// 本就是 ≤480p 解码，GPU 链路径由该函数内部降采样到 ~240p）。
  Future<void> _refreshEqScopesFromPreviews(
      List<IspNode> eqNodes, int token) async {
    for (final eq in eqNodes) {
      final pairs = [
        (false, previewImages[eq.id]),
        (true, previewInputImages[eq.id]),
      ];
      for (final (isIn, src) in pairs) {
        if (src == null) continue;
        final bd = await src.toByteData();
        if (bd == null) continue;
        final scope = await _hslVectorscopeImage(
            bd.buffer.asUint8List(), src.width, src.height);
        if (scope == null) continue;
        if (token != _runToken) {
          scope.dispose();
          return;
        }
        if (isIn) {
          hslInputVectorscopes.remove(eq.id)?.dispose();
          hslInputVectorscopes[eq.id] = scope;
        } else {
          hslVectorscopes.remove(eq.id)?.dispose();
          hslVectorscopes[eq.id] = scope;
        }
      }
    }
    if (token == _runToken) frameTick.value++;
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
          node.typeId == 'color_controller' ||
          node.typeId == 'multi_band_eq' ||
          node.typeId == 'rgb_debugger' ||
          node.typeId == 'yuv_debugger' ||
          node.typeId == 'sat_bright_adjuster' ||
          node.typeId == 'gaussian_blur' ||
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
          final c = _withHdrToneMapFlag(compileChain(graph, pvNode.id));
          chains[pvNode.id] = c;
          totalChainLen += c.length;
        } catch (_) {
          // 无法编译的节点在并行执行阶段同样跳过。
        }
        if (pvNode.typeId == 'hsl_debugger' ||
            pvNode.typeId == 'color_controller' ||
            pvNode.typeId == 'multi_band_eq' ||
            pvNode.typeId == 'rgb_debugger' ||
            pvNode.typeId == 'yuv_debugger' ||
            pvNode.typeId == 'sat_bright_adjuster' ||
            pvNode.typeId == 'gaussian_blur' ||
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
              final c = _withHdrToneMapFlag(compileChain(graph, up.fromNodeId));
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
      // 文件（大图纯 Dart 解码为秒级，多链时成倍放大）。多个源并发
      // 解码（在途去重见 _imageSourceRgbaInFlight，优化 13）。
      final imageSrcRgba = <String, (Uint8List, int, int)>{}; // 源 nodeId → 帧
      final srcFutures = <String, Future<(Uint8List, int, int)>>{};
      for (final c in [...chains.values, ...inputChains.values]) {
        if (c.first['typeId'] != 'image_source') continue;
        final srcId = c.first['nodeId'] as String;
        if (srcFutures.containsKey(srcId)) continue;
        final p = (c.first['params'] as Map).cast<String, Object?>();
        srcFutures[srcId] = _imageSourceRgba('${p['filePath'] ?? ''}');
      }
      // Future.wait 等全部落定（个别失败也在所有解码结束后抛首个
      // 错误），不留未处理的孤儿 Future。
      final decoded = await Future.wait(srcFutures.values);
      final srcIds = srcFutures.keys.toList();
      for (var i = 0; i < decoded.length; i++) {
        imageSrcRgba[srcIds[i]] = decoded[i];
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
              // HSL 调节器/色彩控制器/多段色彩均衡器：由输出链/输入链
              // 末端 RGBA 分别统计 Cb/Cr 矢量示波器（与 vectorscope 仪器
              // 同一口径），渲染成图供节点右半（调整后）/左半（调整前）
              // 显示。统计走仪器 worker 池（降采样 + 后台 isolate），
              // 两图并行。
              ui.Image? vectorscopeImage;
              ui.Image? inputVectorscopeImage;
              if (pvNode.typeId == 'hsl_debugger' ||
                  pvNode.typeId == 'color_controller' ||
                  pvNode.typeId == 'multi_band_eq') {
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
              if (pvNode.typeId == 'hsl_debugger' ||
                  pvNode.typeId == 'color_controller' ||
                  pvNode.typeId == 'multi_band_eq') {
                hslVectorscopes.remove(pvNode.id)?.dispose();
                if (vectorscopeImage != null) {
                  hslVectorscopes[pvNode.id] = vectorscopeImage;
                }
                // 输入链被 GPU 覆盖时 inputRgba 为空，输入矢量图由
                // _tryGpuPreview 的回读路径补齐，此处不能清掉。
                if (!gpuCovered.contains('${pvNode.id}#in')) {
                  hslInputVectorscopes.remove(pvNode.id)?.dispose();
                  if (inputVectorscopeImage != null) {
                    hslInputVectorscopes[pvNode.id] = inputVectorscopeImage;
                  }
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

      // 视频输出节点的「帧率」自动对齐上游视频源的原生帧率。
      await _autoFillVideoOutputFps();
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
        // 拖动调参期间积累的实时预览请求：用最新参数合并补跑一次
        if (_livePreviewDirty) {
          _livePreviewDirty = false;
          requestLivePreview();
        }
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
        _instrumentSigs.remove(node.id);
        _minmaxHold.remove(node.id);
        _deepIqaDist.remove(node.id);
        _kidWorkers.remove(node.id)?.dispose();
        instrumentImages.remove(node.id)?.dispose();
      }
    }
    // 清理已不在图中的节点残留。
    for (final id in instrumentResults.keys.toList()) {
      if (!graph.nodes.containsKey(id)) {
        instrumentResults.remove(id);
        _instrumentSigs.remove(id);
        _minmaxHold.remove(id);
        _deepIqaDist.remove(id);
        _kidWorkers.remove(id)?.dispose();
        instrumentImages.remove(id)?.dispose();
      }
    }
    // 音频仪器：数据来自音轨而非帧，与图像仪器并行刷新。
    final audioFuture = _runAudioInstruments(frame, token);
    // 单次运行的馈源/降采样/PNG 去重缓存：多个评价节点接同一对
    // 源时（如 图像评价.ispflow 的 15 指标 × 22 路馈源），每路上游
    // 只重跑/降采样/编码一次。每次运行开始清空（帧与图可能已变）。
    _instrumentFeedCache.clear();
    _instrumentFeedDownCache.clear();
    _pyiqaPngCache.clear();
    _deepIqaFeatCache.clear();
    if (connected.isNotEmpty) {
      int instrumentCompleted = 0;
      final instrumentTotal = connected.length;
      // 正在分析中的仪器节点名（并发执行，状态栏显示具体节点，
      // 最多列 3 个）。
      final instrumentsRunning = <String>{};
      void updateInstrumentStatus() {
        if (token != _runToken) return;
        final names = instrumentsRunning.take(3).join('、');
        statusMessage = names.isEmpty
            ? '正在更新仪器 [$instrumentCompleted/$instrumentTotal]…'
            : '正在更新仪器 [$instrumentCompleted/$instrumentTotal]：'
                '$names${instrumentsRunning.length > 3 ? ' 等' : ''}…';
        notifyListeners();
      }

      await Future.wait([
        for (final node in connected)
          () async {
            instrumentsRunning.add(node.name);
            updateInstrumentStatus();
            // 仪器节点耗时测量（右侧面板「节点流程图」的运行时间列）；
            // 签名命中跳过时保留上次耗时。计时在并发治理锁外开始（含
            // 排队时间，语义：节点就绪 → 出分的端到端耗时）。
            var ran = false;
            final sw = Stopwatch()..start();
            try {
              // 输入签名未变且已有结果：跳过重复分析（重复点「运行
              // 预览」时不再全量重算所有指标）；分析失败不记录签名，
              // 下次运行自动重试。
              final sig = _instrumentSignature(node, frame);
              if (_instrumentSigs[node.id] == sig &&
                  instrumentResults.containsKey(node.id)) {
                return;
              }
              ran = true;
              final type = IspNodeRegistry.byId(node.typeId);
              Map<String, Object?> result;
              if (node.typeId == 'psnr' ||
                  node.typeId == 'ssim' ||
                  node.typeId == 'msssim' ||
                  node.typeId == 'fsim') {
                // 评价算法数字表：双输入（参考/测试），走专用双路馈源分析。
                // 重 CPU（大帧嵌套 Isolate.run）：限并发（优化 6）。
                result =
                    await _heavyCpuLock(() => _analyzeDualInput(node, frame));
              } else if (node.typeId == 'ilniqe') {
                // ILNIQE 数字表：无参考单输入，但计算量远超其他仪器
                // （FFT 滤波器组 + MVG 评分），不走 5s 超时的仪器 worker，
                // 馈源与通用路径一致，计算放独立 isolate（compute）。
                // 重 CPU：限并发（优化 6）。
                result = await _heavyCpuLock(() async {
                  final feed = await _instrumentFrameFeed(node, frame, type);
                  if (feed != null) {
                    // 多核并行版：滤波器组与分块特征分多 isolate 计算，
                    // 结果与串行位级一致（见 ilniqeScoreParallel）。
                    final v = await compute(ilniqeScoreParallelInIsolate, {
                      'rgba': feed.$1,
                      'width': feed.$2,
                      'height': feed.$3,
                    });
                    return {'kind': 'ilniqe', 'ilniqe': v};
                  }
                  throw StateError('无可用馈源');
                });
              } else if (pyIqaMetrics.containsKey(node.typeId)) {
                // 深度评价数字表（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA）：
                // 权重齐全时进程内 Dart 计算（tools/iqa/weights/*.nnw，
                // 共享 NnPool 常驻 isolate 池），不齐时回退 Python 桥接
                // 进程（PyIqaWorker）；FID/KID 逐帧累计样本。
                // 优化 6 并发治理：GPU 链类互斥（共享 GPU/UI 派发通道），
                // MUSIQ 等重 CPU 限并发。
                if (_gpuChainMetricTypes.contains(node.typeId)) {
                  result = await _gpuMetricLock(
                      () => _analyzeDeepIqa(node, frame, token));
                } else if (_heavyCpuInstrumentTypes.contains(node.typeId)) {
                  result = await _heavyCpuLock(
                      () => _analyzeDeepIqa(node, frame, token));
                } else {
                  result = await _analyzeDeepIqa(node, frame, token);
                }
              } else {
                // 降采样馈源（后台 isolate 降采样 + 单次运行去重，
                // 见 _instrumentFrameFeedDown）。
                final feed = await _instrumentFrameFeedDown(node, frame, type);
                if (feed == null) {
                  throw StateError('无可用馈源');
                }
                final (srcRgba, srcW, srcH) = feed;
                // NIQE/BRISQUE/PIQE 为重 CPU：限并发（优化 6）；其余
                // 轻量仪器（直方图/波形等，5s 超时 worker）保持现状不限。
                result = _heavyCpuInstrumentTypes.contains(node.typeId)
                    ? await _heavyCpuLock(() => _instrumentAnalyzer.analyze(
                        srcRgba, srcW, srcH, node.typeId))
                    : await _instrumentAnalyzer.analyze(
                        srcRgba, srcW, srcH, node.typeId);
              }
              if (token != _runToken) return;
              instrumentResults[node.id] = node.typeId == 'minmax'
                  ? _mergeMinmaxHold(node.id, result)
                  : result;
              // 错误结果（如「需要权重文件…或 Python 环境」）不记录签名，
              // 下次运行重新尝试。
              if (result['error'] == null) {
                _instrumentSigs[node.id] = sig;
              }
              await _updateInstrumentImage(node.id, result);
            } catch (e) {
              // 链不完整等失败：保留旧结果，不影响预览，但记录便于诊断。
              debugPrint('[isp] 仪器分析失败 ${node.id}(${node.typeId}): $e');
            } finally {
              instrumentsRunning.remove(node.name);
              instrumentCompleted++;
              if (token == _runToken) {
                if (ran) {
                  nodeRunTimesUs[node.id] = sw.elapsedMicroseconds;
                  // GPU 徽标缺省 CPU：仅 LPIPS/DISTS 的 GPU 驻留链会
                  // 经 onBackend 回写 true（见 _analyzeDeepIqa）。
                  nodeRunOnGpu.putIfAbsent(node.id, () => false);
                }
                if (progressBase != null) {
                  _advanceProgress(progressBase +
                      progressScale * instrumentCompleted / instrumentTotal);
                }
                updateInstrumentStatus();
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

  /// 单次运行内的仪器馈源去重缓存：(上游节点#端口@帧) → 全分辨率
  /// 馈源 Future（存 Future 可同时去重并发中的在途计算）。每次
  /// [_runInstruments] 开始清空。
  final Map<String, Future<(Uint8List, int, int)?>> _instrumentFeedCache = {};

  /// 与 [_instrumentFeedCache] 同键的 2x 降采样馈源缓存：降采样在
  /// 后台 isolate 完成，同源多指标只降一次。
  final Map<String, Future<(Uint8List, int, int)?>> _instrumentFeedDownCache =
      {};

  /// 同一降采样缓冲的单次运行 PNG 编码缓存（键含缓冲身份与尺寸）：
  /// LPIPS/DISTS/FID/KID 共用一对源图时 8 次编码变 2 次。
  final Map<int, Future<String>> _pyiqaPngCache = {};

  /// 仪器输入签名（跨运行）：签名未变且已有结果时 [_runInstruments]
  /// 跳过该节点的重复分析。
  final Map<String, String> _instrumentSigs = {};

  /// 仪器输入签名：帧号 + 节点参数 + 各输入上游链（含图片源文件
  /// mtime/大小，同路径重存也会使签名失效）。
  String _instrumentSignature(IspNode node, int frame) {
    final parts = <Object?>[frame, node.typeId, node.paramValues];
    final type = IspNodeRegistry.byId(node.typeId);
    if (type != null) {
      for (final port in type.inputs) {
        final conn = graph.connectionAt(node.id, port.name);
        if (conn == null) continue;
        try {
          final chain = compileChain(graph, conn.fromNodeId);
          parts.add(chain);
          // 同路径图片重存（内容变、路径不变）也要失效签名。
          if (chain.first['typeId'] == 'image_source') {
            final fp =
                '${(chain.first['params'] as Map)['filePath'] ?? ''}';
            if (fp.isNotEmpty) {
              final f = File(fp);
              if (f.existsSync()) {
                final st = f.statSync();
                parts.add(
                    '$fp:${st.modified.millisecondsSinceEpoch}:${st.size}');
              }
            }
          }
        } catch (_) {
          parts.add('chain-error');
        }
      }
    }
    return jsonEncode(parts);
  }

  /// 降采样馈源（后台 isolate 执行，单次运行去重）。
  Future<(Uint8List, int, int)?> _downsampleFeed(
      String key, Future<(Uint8List, int, int)?> feed) {
    return _instrumentFeedDownCache.putIfAbsent(key, () async {
      final f = await feed;
      if (f == null) return null;
      var (rgba, w, h) = f;
      if (w > 64 && h > 64) {
        (rgba, w, h) = await compute(
            downsampleRgba82xInIsolate, {'src': rgba, 'width': w, 'height': h});
      }
      return (rgba, w, h);
    });
  }

  /// 降采样缓冲的 PNG 编码去重（单次运行内同一缓冲只编码一次）。
  Future<String> _pyIqaPngFor(Uint8List rgba, int w, int h) =>
      _pyiqaPngCache.putIfAbsent(
          Object.hash(identityHashCode(rgba), rgba.lengthInBytes, w, h),
          () => pyIqaWriteTempPng(rgba, w, h));

  /// 图像仪器的单路馈源（单次运行去重缓存入口，见
  /// [_instrumentFrameFeedUncached]）。
  Future<(Uint8List, int, int)?> _instrumentFrameFeed(
          IspNode node, int frame, IspNodeType? type) =>
      _instrumentFeedCache.putIfAbsent(_frameFeedKey(node, frame, type),
          () => _instrumentFrameFeedUncached(node, frame, type));

  /// 图像仪器的单路降采样馈源：同源多指标共享一次后台降采样。
  Future<(Uint8List, int, int)?> _instrumentFrameFeedDown(
          IspNode node, int frame, IspNodeType? type) =>
      _downsampleFeed(_frameFeedKey(node, frame, type),
          _instrumentFrameFeed(node, frame, type));

  /// 单路馈源缓存键：第一路已连接输入的 (上游节点#端口@帧)；无连接
  /// 时退化为节点自身（此时馈源必然失败，键不重要）。
  String _frameFeedKey(IspNode node, int frame, IspNodeType? type) {
    if (type != null) {
      for (final port in type.inputs) {
        final conn = graph.connectionAt(node.id, port.name);
        if (conn != null) return '${conn.fromNodeId}#${conn.fromPort}@$frame';
      }
    }
    return '${node.id}@$frame';
  }

  /// 图像仪器的单路馈源：优先复用播放中最近上屏的帧（含分路器通道
  /// 端口修正），其次端口捕获（GPU 回读），都没有则把仪器当汇点编译
  /// 链重跑（后台 isolate）。返回原始 RGBA 帧与宽高（不降采样——
  /// 调用侧按需处理，如通用仪器分析压到一半、ILNIQE 内部归一化到
  /// 524×524）；无法获取返回 null。
  Future<(Uint8List, int, int)?> _instrumentFrameFeedUncached(
      IspNode node, int frame, IspNodeType? type) async {
    // 优先复用播放中最近上屏的帧（暂停场景）：视频源逐仪器
    // 重新 seek 解码要起多次 ffmpeg，耗时以秒计。
    final lastMap = _lastPlaybackRgba;
    if (lastMap != null && lastMap.isNotEmpty) {
      final srcId = _instrumentSrcNodeId(node);
      var rgba = lastMap[srcId] ?? lastMap.values.first;
      // GPU 平面馈源的 U/V chroma 平面是半尺寸，按条目取真实宽高，
      // 不能用全分辨率 _lastPlaybackW/H 去索引。
      final dim = _lastPlaybackDims?[srcId];
      final w = dim?.$1 ?? _lastPlaybackW;
      final h = dim?.$2 ?? _lastPlaybackH;
      // 分路器通道输出（out_r/g/b 等）的端口修正：同分路器下
      // 多台仪器复用到同一帧时提取各自通道（同播放路径，
      // 见 _instrumentChannelFeed）。
      rgba = _instrumentChannelFeed(node, srcId, rgba);
      if (w > 0 && h > 0) {
        return (rgba, w, h);
      }
    } else if (type != null) {
      for (final inputSpec in type.inputs) {
        final inputConn = graph.connectionAt(node.id, inputSpec.name);
        if (inputConn != null) {
          final capture = nodeOutputCaptures[inputConn.fromNodeId]?[inputConn.fromPort];
          if (capture is Map) {
            final rgba = capture['data'] as Uint8List?;
            final w = capture['width'] as int?;
            final h = capture['height'] as int?;
            if (rgba != null && w != null && h != null && w > 0 && h > 0) {
              return (rgba, w, h);
            }
          }
        }
      }
    }
    final chain = compileChain(graph, node.id);
    // 图片源：注入共享解码缓存的 RGBA8（跨运行只解码一次，mtime/
    // 大小校验），跳过链内重复解码——单输入仪器（NIQE/BRISQUE/
    // PIQE/ILNIQE/MUSIQ/CLIPIQA 等）此前每个节点各解码一遍，20MP
    // 图每次 1.5~2s（与 _instrumentFeedOf 双路馈源同一口径）。
    Map<String, Object?>? inject;
    if (chain.first['typeId'] == 'image_source') {
      final p0 = chain.first['params'] as Map<String, Object?>;
      // 8 位单节点 out_rgb 链短路（与 _instrumentFeedOfUncached 同
      // 口径）：共享解码缓存即链输出，跳过 16 位往返与链重跑。
      final bitDepth = '${p0['bitDepth'] ?? ''}';
      if (chain.length == 1 &&
          (chain.first['outFormat'] ?? 'rgb') == 'rgb' &&
          (bitDepth.isEmpty || bitDepth == '8')) {
        var rgbPort = false;
        if (type != null) {
          for (final inputSpec in type.inputs) {
            final c = graph.connectionAt(node.id, inputSpec.name);
            if (c != null) {
              rgbPort = c.fromPort == 'out_rgb';
              break;
            }
          }
        }
        if (rgbPort) {
          return _imageSourceRgba('${p0['filePath'] ?? ''}');
        }
      }
      final inj = await _imageSourceRgba('${p0['filePath'] ?? ''}');
      inject = {
        'sourceRgba': inj.$1,
        'sourceWidth': inj.$2,
        'sourceHeight': inj.$3,
      };
    }
    // 链重跑放后台 isolate：多核 RAW 算子的长链在主 isolate
    // 执行会冻结 UI 数秒，期间仪器 worker 的回包无法被处理，
    // 5s 超时定时器抢先触发而误报「仪器分析超时」。
    final chainRgba = await compute(runChainFrameInIsolate,
        {'chain': chain, 'frameIndex': frame, ...?inject});
    final (dw, dh) = await sourceDimensions(
        chain.first['typeId'] as String,
        chain.first['params'] as Map<String, Object?>);
    return (chainRgba, dw, dh);
  }

  /// 双输入仪器的单路馈源（单次运行去重缓存入口，见
  /// [_instrumentFeedOfUncached]）。
  Future<(Uint8List, int, int)?> _instrumentFeedOf(
      IspNode node, List<String> ports, int frame) {
    final key = _feedOfKey(node, ports, frame);
    if (key == null) return Future.value(null);
    return _instrumentFeedCache.putIfAbsent(
        key, () => _instrumentFeedOfUncached(node, ports, frame));
  }

  /// 双输入仪器的单路降采样馈源（后台 isolate 降采样 + 去重）。
  Future<(Uint8List, int, int)?> _instrumentFeedOfDown(
      IspNode node, List<String> ports, int frame) {
    final key = _feedOfKey(node, ports, frame);
    if (key == null) return Future.value(null);
    return _downsampleFeed(key, _instrumentFeedOf(node, ports, frame));
  }

  /// 双路馈源缓存键：[ports] 中第一路已连接输入的 (上游节点#端口@帧)。
  String? _feedOfKey(IspNode node, List<String> ports, int frame) {
    for (final pn in ports) {
      final conn = graph.connectionAt(node.id, pn);
      if (conn != null) return '${conn.fromNodeId}#${conn.fromPort}@$frame';
    }
    return null;
  }

  /// 双输入仪器（PSNR/SSIM 数字表）的单路馈源：取 [ports] 中第一路
  /// 已连接输入的链末端色调映射 RGBA（与直方图同一数据口径）。
  /// 优先复用最近一次运行的端口捕获（GPU 回读）；没有捕获则把上游
  /// 节点当汇点编译链重跑（后台 isolate，同仪器通用回退路径）。
  Future<(Uint8List, int, int)?> _instrumentFeedOfUncached(
      IspNode node, List<String> ports, int frame) async {
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
        // 8 位单节点 out_rgb 链短路：共享解码缓存即链输出
        //（rgba8ToRgb16 + tonemap 在 maxValue=255/gamma=1.0 下恒等，
        // 已验证位级一致），跳过 16 位往返、GPU/CPU 链重跑与 ~81MB
        // isolate 消息（20MP 每路省 2~3s）。
        final bitDepth = '${p0['bitDepth'] ?? ''}';
        if (chain.length == 1 &&
            conn.fromPort == 'out_rgb' &&
            (chain.first['outFormat'] ?? 'rgb') == 'rgb' &&
            (bitDepth.isEmpty || bitDepth == '8')) {
          return _imageSourceRgba('${p0['filePath'] ?? ''}');
        }
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

  /// 双输入评价数字表（PSNR/SSIM/MS-SSIM/FSIM）分析：取参考图（in*）与
  /// 测试图（in_test*）两路的链末端色调映射 RGBA（与直方图同一数据
  /// 口径），按节点类型计算对应指标（计算在后台 isolate 执行，见
  /// dualMetricInIsolate）。任一路未接入或尺寸不一致时
  /// 返回带 error 提示的结果。
  Future<Map<String, Object?>> _analyzeDualInput(IspNode node, int frame) async {
    final kind = node.typeId;
    // 降采样馈源（后台 isolate 降采样，同源多指标去重共享）。
    // 两路并行取：冷缓存时两张图的解码并发进行（优化 13）。
    final feeds = await Future.wait([
      _instrumentFeedOfDown(
          node, const ['in', 'in_yuv', 'in_hsl', 'in_mono'], frame),
      _instrumentFeedOfDown(node,
          const ['in_test', 'in_test_yuv', 'in_test_hsl', 'in_test_mono'], frame),
    ]);
    final ref = feeds[0];
    final test = feeds[1];
    if (ref == null || test == null) {
      return {'kind': kind, 'error': '需要接入参考图与测试图'};
    }
    if (ref.$2 != test.$2 || ref.$3 != test.$3) {
      return {'kind': kind, 'error': '两路输入尺寸不一致'};
    }
    // 调用侧已限定 psnr/ssim/msssim/fsim（见 _analyzeInstruments 分支）。
    final res = await compute(dualMetricInIsolate, {
      'kind': kind,
      'ref': ref.$1,
      'test': test.$1,
      'width': ref.$2,
      'height': ref.$3,
    });
    return res;
  }

  /// 深度评价数字表（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA）分析的首选路径：
  /// 权重（[deepIqaWeightFiles]）齐全时进程内 Dart 计算（metrics/
  /// *_dart.dart，多 isolate 并行，共享 [_sharedNnPool] 常驻池）；
  /// 不齐且 Python 桥接可用时回退 [_analyzePyIqa]；两者皆缺返回带
  /// error 提示的结果。馈源口径与 [_analyzePyIqa] 一致（双路/单路
  /// 2x 降采样）；FID/KID 逐帧累计（新一轮运行 token 变化时复位，
  /// 见 [_pyiqaDistTokens]），同一次运行内 FID 与 KID 节点接同一对
  /// 源时共享 Inception patch 特征（[_deepIqaFeatCache]）。
  Future<Map<String, Object?>> _analyzeDeepIqa(
      IspNode node, int frame, int token) async {
    final kind = node.typeId;
    final info = pyIqaMetrics[kind]!;
    if (!deepIqaWeightsAvailable(kind)) {
      if (PyIqaWorker.available) {
        // 回退 Python 桥接进程：非本应用 GPU 路径，徽标按 CPU 显示。
        nodeRunOnGpu[node.id] = false;
        return _analyzePyIqa(node, frame, token);
      }
      final missing = [
        for (final f in deepIqaWeightFiles[kind]!)
          if (!File(f).existsSync()) f,
      ];
      return {
        'kind': kind,
        'error': '需要权重文件 tools/iqa/weights/…（缺 '
            '${missing.join('、')}）或 Python 环境',
      };
    }
    if (info.kind == 'single') {
      final type = IspNodeRegistry.byId(kind);
      // 降采样馈源（后台 isolate 降采样，同源多指标去重共享）。
      final feed = await _instrumentFrameFeedDown(node, frame, type);
      if (feed == null) return {'kind': kind, 'error': '需要接入输入图'};
      final (rgba, w, h) = feed;
      if (kind == 'musiq') {
        // MUSIQ 的进程内实现走 CPU isolate 池（无 GPU 后端）：整体经
        // compute 在后台 isolate 执行（其内自起 NnPool 跑 tokenizer/
        // embedding/transformer 的全部 GEMM），UI isolate 不再被
        // transformer 的同步计算冻结（优化 10）；结果与 musiqScore
        // 位级一致。
        nodeRunOnGpu[node.id] = false;
        final v = await compute(musiqScoreInIsolate,
            {'rgba': rgba, 'width': w, 'height': h});
        return {'kind': kind, kind: v};
      }
      final pool = await _sharedNnPool();
      // CLIPIQA：RN50 主干优先走 GPU 纹理驻留链（ClipRn50Gpu），
      // attention 走 CPU 池；GPU 任一步失败整链回退 CPU 池。
      final v = await clipiqaScoreParallel(rgba, w, h,
          pool: pool,
          gpuTrunk: await _sharedRn50Gpu(),
          onBackend: (g) => nodeRunOnGpu[node.id] = g);
      return {'kind': kind, kind: v};
    }
    // pair / dist：双路降采样馈源（与 PSNR 同端口）。两路并行取
    // （优化 13，同 [_analyzeDualInput]）。
    final feeds = await Future.wait([
      _instrumentFeedOfDown(
          node, const ['in', 'in_yuv', 'in_hsl', 'in_mono'], frame),
      _instrumentFeedOfDown(node,
          const ['in_test', 'in_test_yuv', 'in_test_hsl', 'in_test_mono'],
          frame),
    ]);
    final ref = feeds[0];
    final test = feeds[1];
    if (ref == null || test == null) {
      return {'kind': kind, 'error': '需要接入参考图与测试图'};
    }
    if (ref.$2 != test.$2 || ref.$3 != test.$3) {
      return {'kind': kind, 'error': '两路输入尺寸不一致'};
    }
    final (ra, rw, rh) = ref;
    final ta = test.$1;
    if (info.kind == 'pair') {
      final pool = await _sharedNnPool();
      // 权重与 GPU 可用时优先走 VGG16 GPU 纹理驻留链（失败自动整链
      // 回退 CPU 池，见 lpipsScoreParallel/distsScoreParallel）。
      final vggGpu = await _sharedVggGpu();
      // 实际后端（GPU 驻留链或 CPU 池）回写到节点徽标。
      void markBackend(bool usedGpu) => nodeRunOnGpu[node.id] = usedGpu;
      final v = kind == 'lpips'
          ? await lpipsScoreParallel(ra, ta, rw, rh,
              pool: pool, vggForward: vggGpu, onBackend: markBackend)
          : await distsScoreParallel(ra, ta, rw, rh,
              pool: pool, vggForward: vggGpu, onBackend: markBackend);
      return {'kind': kind, kind: v};
    }
    // dist：新一轮运行先复位累计，再逐帧向两侧各 add 一帧的 patch 特征。
    // KID 的累计/出分走常驻 isolate（[_kidWorkers]，增量核矩阵），
    // _deepIqaDist 仅 FID 使用；KID 新一轮运行时 dispose 旧 worker
    // （懒创建的新 worker 即空状态，等效 reset）。
    final accum = kind == 'kid'
        ? null
        : _deepIqaDist.putIfAbsent(node.id, _DeepIqaDistAccum.new);
    if (_pyiqaDistTokens[node.id] != token) {
      _pyiqaDistTokens[node.id] = token;
      accum?.reset();
      _kidWorkers.remove(node.id)?.dispose();
    }
    // FID 与 KID 节点共用同一对源时特征只算一次（键含双路馈源键，
    // 馈源键本身含帧号）。
    final refKey =
        _feedOfKey(node, const ['in', 'in_yuv', 'in_hsl', 'in_mono'], frame);
    final testKey = _feedOfKey(node,
        const ['in_test', 'in_test_yuv', 'in_test_hsl', 'in_test_mono'],
        frame);
    // FID 与 KID 节点共用同一对源时特征只算一次（键含双路馈源键，
    // 馈源键本身含帧号）。InceptionV3 有 GPU 纹理驻留链时两侧逐
    // patch 串行提取（UI isolate），失败回退 isolate 并行 CPU 路径。
    final incGpu = await _sharedInceptionGpu();
    final featKey = '$refKey|$testKey';
    final (fr, ft) = await _deepIqaFeatCache.putIfAbsent(featKey, () async {
      if (incGpu != null && InceptionV3Gpu.enabled) {
        try {
          final fr2 =
              await inceptionPatchFeaturesParallel(ra, rw, rh, gpuNet: incGpu);
          final ft2 =
              await inceptionPatchFeaturesParallel(ta, rw, rh, gpuNet: incGpu);
          _deepIqaFeatOnGpu[featKey] = true;
          return (fr2, ft2);
        } catch (e) {
          // ignore: avoid_print
          print('[IspStudioState] InceptionV3 GPU 特征提取失败，回退 CPU 池: $e');
        }
      }
      _deepIqaFeatOnGpu[featKey] = false;
      // 两侧并行（各自内部再按 patch 分 isolate，见
      // inceptionPatchFeaturesParallel）。
      final r = await Future.wait([
        inceptionPatchFeaturesParallel(ra, rw, rh),
        inceptionPatchFeaturesParallel(ta, rw, rh),
      ]);
      return (r[0], r[1]);
    });
    if (kind == 'kid') {
      // KID：累计与出分在常驻 isolate 的增量核矩阵
      //（kid_score_worker.dart / KidGramAccum）——每帧只发本帧新增
      // 特征（fp32 拷贝，fr/ft 与 FID/特征缓存共享所有权），worker 内
      // 只算核矩阵新增块（每帧 O(n·Δ·d) 替代全量重算 O(n²·d)），出分
      // 与全量 kidCompute 逐位一致（测试断言 ==）。
      var worker = _kidWorkers[node.id];
      if (worker == null) {
        worker = KidScoreWorker();
        await worker.start();
        _kidWorkers[node.id] = worker;
      }
      final (nRef, nTest) = await worker.add(fr, ft);
      if (nRef < 2 || nTest < 2) {
        // 样本不足（任一侧 <2 个 patch）：只显示累计进度。
        return {'kind': kind, 'n_ref': nRef, 'n_test': nTest};
      }
      // 特征提取可能走 GPU（见上），统计计算在常驻 isolate（CPU）。
      nodeRunOnGpu[node.id] = _deepIqaFeatOnGpu[featKey] ?? false;
      final v = await worker.score();
      return {
        'kind': kind,
        kind: v,
        'n_ref': nRef,
        'n_test': nTest,
      };
    }
    accum!.add(fr, ft);
    if (accum.nRef < 2 || accum.nTest < 2) {
      // 样本不足（任一侧 <2 个 patch）：只显示累计进度。
      return {'kind': kind, 'n_ref': accum.nRef, 'n_test': accum.nTest};
    }
    // FID 的特征提取可能走 GPU（见上），统计计算走 CPU isolate。
    nodeRunOnGpu[node.id] = _deepIqaFeatOnGpu[featKey] ?? false;
    final (featsRef, featsTest) = accum.concat();
    // FID 的 2048² 协方差/特征值求解为重计算，放后台 isolate
    //（compute），不在 UI isolate 执行。
    final v = await compute(fidScoreInIsolate, {
      'ref': featsRef,
      'nRef': accum.nRef,
      'test': featsTest,
      'nTest': accum.nTest,
    });
    return {
      'kind': kind,
      kind: v,
      'n_ref': accum.nRef,
      'n_test': accum.nTest,
    };
  }

  /// 深度评价数字表（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA）分析：馈源口径
  /// 与各 Dart 评价节点一致（链末端色调映射 RGBA，大帧 2x 降采样），
  /// 计算经 [PyIqaWorker] 常驻 Python 桥接进程（torch 模型）。
  /// pair（lpips/dists）与 single（musiq/clipiqa）每帧直接出分；
  /// dist（fid/kid）为分布级指标——新一轮运行（[token] 变化）先清空
  /// 桥接进程的累计特征，此后每帧向两侧各 add 一个样本，任一侧 ≥2 帧
  /// 时出分（结果带 n_ref/n_test 样本计数）。
  /// Python 环境缺失或输入未接时返回带 error 提示的结果。
  /// 进程内 Dart 实现可用时 [_analyzeDeepIqa] 优先，本方法为回退路径。
  Future<Map<String, Object?>> _analyzePyIqa(
      IspNode node, int frame, int token) async {
    final kind = node.typeId;
    final info = pyIqaMetrics[kind]!;
    if (!PyIqaWorker.available) {
      return {
        'kind': kind,
        'error': '需要 Python 环境（$pyIqaPythonPath）',
      };
    }
    if (info.kind == 'single') {
      final type = IspNodeRegistry.byId(kind);
      // 降采样馈源（后台 isolate 降采样，同源多指标去重共享）。
      final feed = await _instrumentFrameFeedDown(node, frame, type);
      if (feed == null) return {'kind': kind, 'error': '需要接入输入图'};
      final (rgba, w, h) = feed;
      final path = await _pyIqaPngFor(rgba, w, h);
      final v = await PyIqaWorker.forMetric(kind).singleScore(path);
      return {'kind': kind, kind: v};
    }
    // pair / dist：双路降采样馈源（与 PSNR 同端口）。两路并行取
    // （优化 13，同 [_analyzeDualInput]）。
    final feeds = await Future.wait([
      _instrumentFeedOfDown(
          node, const ['in', 'in_yuv', 'in_hsl', 'in_mono'], frame),
      _instrumentFeedOfDown(node,
          const ['in_test', 'in_test_yuv', 'in_test_hsl', 'in_test_mono'], frame),
    ]);
    final ref = feeds[0];
    final test = feeds[1];
    if (ref == null || test == null) {
      return {'kind': kind, 'error': '需要接入参考图与测试图'};
    }
    if (ref.$2 != test.$2 || ref.$3 != test.$3) {
      return {'kind': kind, 'error': '两路输入尺寸不一致'};
    }
    final (ra, rw, rh) = ref;
    final ta = test.$1;
    final worker = PyIqaWorker.forMetric(kind);
    if (info.kind == 'pair') {
      final pa = await _pyIqaPngFor(ra, rw, rh);
      final pb = await _pyIqaPngFor(ta, rw, rh);
      final v = await worker.pairScore(pa, pb);
      return {'kind': kind, kind: v};
    }
    // dist：新一轮运行先复位累计，再逐帧向两侧各 add 一个样本。
    if (_pyiqaDistTokens[node.id] != token) {
      _pyiqaDistTokens[node.id] = token;
      await worker.distReset();
    }
    final pa = await _pyIqaPngFor(ra, rw, rh);
    final pb = await _pyIqaPngFor(ta, rw, rh);
    final nRef = await worker.distAdd('ref', pa);
    final nTest = await worker.distAdd('test', pb);
    final s = await worker.distScore();
    if (s == null) {
      // 样本不足（任一侧 <2 帧）：只显示累计进度。
      return {'kind': kind, 'n_ref': nRef, 'n_test': nTest};
    }
    return {'kind': kind, kind: s.$1, 'n_ref': s.$2, 'n_test': s.$3};
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

  /// 当前/最近播放的视频源帧率（0 = 非视频源或未播放）：播放控制条
  /// 进度滑条右侧的「已播放时间/总时间」按它换算。播放停止后保留
  /// 最后一次的值（暂停态拖动进度条时时间文本仍正确）。
  double playbackSrcFps = 0;

  /// 当前视频源的色彩传递特性（0=SDR/1=PQ/2=HLG，VideoInfo.colorTransfer
  /// 同口径）：预览节点播放控制条的 HDR/SDR 切换按钮按它决定显示形态
  /// （0 → 静态「SDR」标识；非 0 → SDR/HDR 互斥切换）。视频源设文件
  /// （autoFillFromVideo）与播放启动（togglePlayback）时填入。
  int playbackSrcTransfer = 0;

  /// 预览 HDR/SDR 开关：true = HDR 片源经 zscale+tonemap 映射显示
  /// （默认，修复后行为）；false = HDR 片源按 SDR 直解（不插 tonemap
  /// 滤镜链，发灰原样，供对比）。只影响预览/播放路径；导出路径恒映射。
  bool hdrToneMapEnabled = true;

  /// HDR/SDR 切换（预览节点按钮）：播放中先停播（解码流已按旧口径起
  /// 好），翻转标志后重跑预览，当前帧按新口径重出。
  Future<void> toggleHdrToneMap() async {
    if (isPlaying) stopPlayback();
    hdrToneMapEnabled = !hdrToneMapEnabled;
    notifyListeners();
    runPreview();
  }

  /// 把预览 HDR/SDR 开关注入视频源链参数（在链副本上注入——
  /// compileChain 的 params 是 node.paramValues 活引用，直接写会污染
  /// 节点参数）。仅 video_source 开头的链注入；pipeline_runner /
  /// gpu_pipeline 读 '_toneMapHdr'（缺省 true）；导出链不注入，恒映射。
  List<Map<String, Object?>> _withHdrToneMapFlag(
      List<Map<String, Object?>> chain) {
    if (chain.isEmpty || chain.first['typeId'] != 'video_source') {
      return chain;
    }
    final first = chain.first;
    final params = Map<String, Object?>.from(
        (first['params'] as Map).cast<String, Object?>());
    params['_toneMapHdr'] = hdrToneMapEnabled;
    return [
      {...first, 'params': params},
      ...chain.skip(1),
    ];
  }

  /// 播放逐帧刷新信号：每帧 +1，取代全树 notifyListeners——只有预览
  /// 附加区与状态栏监听它逐帧重建，画布/节点结构不再逐帧重排
  /// （否则缩小画布后十几个节点卡片每帧全量重建，UI isolate 被堵死，
  /// 走帧循环被饿死而连续停滞）。
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  /// 视频导出进度（非空表示正在导出）：输出分辨率/帧率/总帧数 +
  /// 已完成帧数 + 实时压缩帧率与 ETA（见 export_progress.dart）。
  ExportProgressInfo? exportVideoInfo;

  /// 导出信息刷新信号（节流 250ms；状态栏左侧导出状态行只监听它，
  /// 不走 notifyListeners 引发全树重建）。
  final ValueNotifier<int> exportInfoTick = ValueNotifier<int>(0);
  int _exportInfoLastNotifyMs = 0;

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

  /// 诊断（ISP_AUTOHASH）：当前上屏帧首条链的原始字节（平面直连为
  /// YUV 平面数据，其余路径为 RGBA），供逐帧内容哈希对比实验。
  Uint8List? get debugDisplayedBytes => _lastPlaybackRgba?.values.firstOrNull;
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
      // 播放汇点：预览节点 + 多段色彩均衡器（其附加区本身就是前后双联
      // 预览 + 播放控制条；没有预览节点的图也应能以均衡器为目标播放。
      // 均衡器链同时充当其「调整后」馈源链，下游有预览链时经前缀覆盖
      // 去重，不重复计算）。
      if (n.typeId == 'preview' || n.typeId == 'multi_band_eq') {
        try {
          validChains[n.id] = compileChain(graph, n.id);
        } catch (_) {}
      }
    }
    if (validChains.isEmpty) {
      statusMessage = '图中没有有效的预览/多段色彩均衡器算子链';
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

    // ---- 多段色彩均衡器附加区预览同步 ----
    // 均衡器已计入播放汇点（validChains），此处找出位于各播放链上的
    // multi_band_eq 节点，播放逐帧顺带捕获其输出（「调整后」）与上游
    // 输出（「调整前」）：CPU 路径并入 runParallel 靠前缀覆盖捕获（链
    // 为预览链前缀时零额外计算）；GPU 链路径用 displayCaptures 顺带出图
    // （GPU 驻留免回读）。矢量示波器播放中不刷新（灰停），暂停时以最后
    // 一帧前后预览图统计补齐（见循环收尾处 _refreshEqScopesFromPreviews）。
    final eqNodes = <IspNode>[];
    final eqUpstream = <String, String>{}; // eqId → 上游节点 id
    {
      final seen = <String>{};
      for (final c in validChains.values) {
        for (final op in c) {
          if (op['typeId'] != 'multi_band_eq') continue;
          final eqId = op['nodeId'] as String;
          if (!seen.add(eqId)) continue;
          final eqNode = graph.nodes[eqId];
          if (eqNode == null) continue;
          // 与单次运行同一近似：互斥输入组取第一个已连接端口；上游多
          // 输出节点时捕获的是其主帧（端口差异可接受）。
          final conn = graph.connectionAt(eqId, 'in') ??
              graph.connectionAt(eqId, 'in_hsl') ??
              graph.connectionAt(eqId, 'in_yuv') ??
              graph.connectionAt(eqId, 'in_mono');
          if (conn == null) continue;
          eqNodes.add(eqNode);
          eqUpstream[eqId] = conn.fromNodeId;
        }
      }
    }
    // CPU 路径的额外链：键 = 汇点 nodeId（与 runParallel 前缀覆盖捕获的
    // 结果键口径一致）。输出链键 eqId；输入链键上游 id（多段共享上游时
    // 去重；上游恰为另一均衡器时其输出链已涵盖）。
    final eqExtraChains = <String, List<Map<String, Object?>>>{};
    for (final eq in eqNodes) {
      try {
        eqExtraChains[eq.id] = compileChain(graph, eq.id);
      } catch (_) {} // 编译失败：该节点不同步，不影响播放主链
      final up = eqUpstream[eq.id];
      if (up != null && !eqExtraChains.containsKey(up)) {
        try {
          eqExtraChains[up] = compileChain(graph, up);
        } catch (_) {}
      }
    }
    final cpuChains = eqExtraChains.isEmpty
        ? validChains
        : {...validChains, ...eqExtraChains};
    // 均衡器馈源图键集合（'eqId' 与 '$eqId#in'）：GPU 链路径的仪器回读
    // 循环据此剔除——馈源图不是仪器馈源，不做逐帧全幅回读。
    final eqFeedImageKeys = <String>{
      for (final eq in eqNodes) ...[eq.id, '${eq.id}#in'],
    };

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
      // GPU 链播放（gpuChain，判定在 gpuPlanes 之后）：全部预览链都有
      // GPU shader 实现且管线可用时，播放帧在 UI isolate 的 GPU 管线执行
      // （RGBA 直传免 CPU 转换 + 全 pass 驻留 + 免回读上屏），支撑 4K60
      // 级吞吐；平面直出/直连等更省的形态优先，不满足时回退 CPU worker 池。
      final gpu = isVideo ? await _gpuPipeline() : null;
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
      // GPU 链播放判定：平面直出（gpuPlanes）与直连（videoDirect）等更省
      // 的形态优先；全部预览链有 GPU 实现且管线可用时走 GPU 管线。
      // 流帧格式取解码器原生 yuv420p（数据量为 RGBA 的 1/2.67，4K60 上传
      // 带宽的关键），须宽为 4 倍数、高为偶数，否则回退 CPU worker 池。
      final videoDirect = isVideo &&
          (chain.first['outFormat'] as String? ?? 'rgb') == 'rgb' &&
          chain.skip(1).every((op) => sinkNodeTypes.contains(op['typeId']));
      // RGB 视频直连预览同样走 yuv420p 平面上屏（planeDirect）：解码器
      // 原生输出 + 打包纹理 + GPU 上色，免去 ffmpeg 侧 →rgba 全像素 CSC
      // 与 2.67 倍管道/上传流量（RGBA 直连 4K 每帧 33MB 纹理上传，产能
      // 贴帧预算抖动——4K30 观感"丢帧"的主因）。与 gpuPlanes 共用生产/
      // 显示/仪器馈源路径；条件不满足回退 RGBA 直连。
      if (!gpuPlanes &&
          videoDirect &&
          w % 4 == 0 &&
          h % 2 == 0 &&
          w * h * 3 ~/ 2 < 1 << 24) {
        try {
          yuvPlaneShader ??= (await ui.FragmentProgram.fromAsset(
                  'shaders/yuv_planes.frag'))
              .fragmentShader();
          gpuPlanes = true;
          planeModes = {firstEntry.key: 0};
        } catch (_) {} // shader 不可用：维持 RGBA 直连
      }
      final gpuChain = gpu != null &&
          !gpuPlanes &&
          !videoDirect &&
          (!isVideo || (w % 4 == 0 && h % 2 == 0)) &&
          validChains.values.every(GpuPipeline.isSupportedChain);
      final pixelFormat = gpuPlanes
          ? 'yuv420p'
          : (gpuChain ? 'yuv420p' : (yuvDirect ? 'yuv444p' : 'rgba'));
      // 播放形态标签（状态栏可见，现场确认走的哪条路径）。
      final pathTag = gpuPlanes
          ? (videoDirect ? '平面直连' : '平面')
          : (videoDirect
              ? '直连RGBA'
              : (gpuChain ? 'GPU链' : 'CPU池'));
      // 视频源：从当前帧起顺序流式解码（内部前向缓冲，背压限速）。
      // 全分辨率出帧：预览按原始尺寸播放，不做降采样。
      var stream = isVideo
          ? await VideoFrameStream.start(
              srcParams['filePath']?.toString() ?? '', frame,
              ffmpegPath: srcParams['ffmpegPath']?.toString() ?? '',
              pixelFormat: pixelFormat,
              // 每包一帧，禁掉默认 CFR 补/丢帧：VUI 标称 60fps 的 30fps
              // 片源（如手术录像 HEVC Rext）默认会被 ffmpeg 逐帧复制
              // 成 60fps 交付，播放时每帧画面停 66ms 呈 15fps 卡顿观感。
              passthrough: true,
              // 预览 HDR/SDR 开关（SDR 直解对比 / HDR tonemap 显示）。
              toneMapHdr: hdrToneMapEnabled)
          : null;
      // 起步预读闸：解码器管线填充期（帧线程延迟 + B 帧重排，HEVC
      // Rext 等高成本源尤其明显）交付是"先干后涌"，不等够帧就起步
      // 会把填充等待暴露成开播后的一串停滞（实测 2024 手术录像
      // HEVC Rext 起步 ~17s 内 5 次停滞，H.264 无 B 帧源为 0）。
      // 最多等 ~1.5s 攒够 8 帧（≈270ms@30fps）再开始走帧；弱源
      // （EOF/出错/停止）立即放行。代价仅是开播延迟最多 1.5s。
      if (isVideo && stream != null) {
        final s = stream;
        // 目标帧数封顶到剩余帧数：短素材（如 4 帧测试片）攒不满 8 帧，
        // 不设上限会白等满 1.5s 超时。
        final gateTarget =
            math.min(8, s.info.frameCount - frame).clamp(1, 8);
        final gateSw = Stopwatch()..start();
        while (s.bufferedCount < gateTarget &&
            !s.isDrained &&
            isPlaying &&
            token == _runToken &&
            gateSw.elapsedMilliseconds < 1500) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
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
      // 视频源信息标签（状态栏随播放显示）：分辨率@帧率 + SDR/HDR +
      // 当前时间/总时长。静态部分循环前拼好，当前时间逐帧更新。
      String fmtClock(double sec) {
        final s = sec.isFinite && sec > 0 ? sec.floor() : 0;
        return '${(s ~/ 60).toString().padLeft(2, '0')}:'
            '${(s % 60).toString().padLeft(2, '0')}';
      }

      var srcInfoTag = '';
      var srcInfoTotal = '';
      double srcFps = 0;
      if (isVideo) {
        final vi = stream!.info;
        final vfps = vi.fps == vi.fps.roundToDouble()
            ? '${vi.fps.toInt()}'
            : vi.fps.toStringAsFixed(2);
        final rangeTag = switch (vi.colorTransfer) {
          1 => 'HDR(PQ)',
          2 => 'HDR(HLG)',
          _ => 'SDR',
        };
        srcInfoTag = '${vi.width}x${vi.height}@$vfps $rangeTag  ';
        srcInfoTotal = fmtClock(vi.frameCount / vi.fps);
        srcFps = vi.fps;
        // 预览节点 HDR/SDR 切换按钮的显示形态随当前播放源更新。
        playbackSrcTransfer = vi.colorTransfer;
      }
      playbackSrcFps = srcFps;
      final poolSize = videoDirect || gpuPlanes || gpuChain
          ? 0
          : math.min(cpuChains.length,
              math.max(1, Platform.numberOfProcessors - 1));
      final pipeline = videoDirect || gpuPlanes || gpuChain
          ? null
          : PipelineWorkerPool(count: poolSize);
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
                  pixelFormat: pixelFormat,
                  // 同首播：每包一帧，禁 CFR 复制（防 60fps VUI 片源
                  // 重复帧导致的 15fps 卡顿观感）。
                  passthrough: true,
                  toneMapHdr: hdrToneMapEnabled);
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
            final matrix = stream!.info.colorMatrix;
            var step = 1;
            while (workH ~/ step > 480) {
              step *= 2;
            }
            gpuStep = step;
            final frameData = bytes;
            for (final e in planeModes.entries) {
              if (e.value == 0) {
                rgbaMap[e.key] = yuv420p8ToRgbaStep(frameData, workW, workH,
                    step, limited: limited, matrix: matrix);
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
          } else if (gpuChain) {
            // GPU 链播放：解码器原生 yuv420p 流帧原样上传（免 CPU 逐像素
            // 转换、上传带宽为 RGBA 的 1/2.67），CSC + 链上 pass 全 GPU
            // 执行，出图为 GPU 驻留 ui.Image 直接上屏（免回读免
            // decodeImageFromPixels）；有图像仪器时才回读 RGBA 馈源。
            // 前缀覆盖去重（口径与 _tryGpuPreview 一致）：同源的短链
            // （如「调整前」直看预览）是最长主链的前缀，由主链顺带捕获
            // 出图，不再重复上传/转换/跑链；播放跳过逐节点调试采样
            // （captureSamples=false，每个采样点是一次 GPU 管线排空）。
            final srcId = chain.first['nodeId'] as String;
            final limited = !(stream?.info.fullRange ?? false);
            final mainEntry = validChains.entries
                .reduce((a, b) => a.value.length >= b.value.length ? a : b);
            final mainIds = [
              for (final op in mainEntry.value) op['nodeId'] as String
            ];
            final displayCaptures = <String, String>{};
            final extraRuns =
                <MapEntry<String, List<Map<String, Object?>>>>[];
            for (final e in validChains.entries) {
              if (e.key == mainEntry.key) continue;
              if (gpuChainPrefixCovered(e.value, mainIds)) {
                final last = e.value.last;
                final sinkId = last['nodeId'] as String;
                displayCaptures[e.key] =
                    (last['typeId'] == 'preview' ||
                                last['typeId'] == 'histogram') &&
                            mainIds.contains(sinkId)
                        ? sinkId
                        : gpuProcChainOf(e.value).last['nodeId'] as String;
              } else {
                extraRuns.add(e);
              }
            }
            // 多段色彩均衡器附加区馈源：eq 节点与其上游都在本次执行的链
            // 上时顺带捕获出图（'eqId' 调整后 / 'eqId#in' 调整前，GPU
            // 驻留免回读）；矢量示波器播放中按 ~5Hz 节流刷新
            // （_refreshEqScopesFromPlayback 需要像素时自行回读预览图），
            // 不做逐帧端口回读。
            final eqAssigned = <String>{};
            void eqAssign(List<String> ids, Map<String, String> caps) {
              for (final eq in eqNodes) {
                if (eqAssigned.contains(eq.id)) continue;
                if (!ids.contains(eq.id)) continue;
                final up = eqUpstream[eq.id]!;
                if (!ids.contains(up)) continue;
                // 本链汇点即 eq 时主出图就是「调整后」，不再重复捕获
                // （否则 images 同键覆盖会使主出图纹理泄漏）。
                if (ids.last != eq.id) caps[eq.id] = eq.id;
                caps['${eq.id}#in'] = up;
                eqAssigned.add(eq.id);
              }
            }

            eqAssign(mainIds, displayCaptures);
            final r = await gpu.run(mainEntry.value, f,
                imageSources: {srcId: (workBytes, workW, workH)},
                streamFormat: 'yuv420p',
                streamLimited: limited,
                displayCaptures: displayCaptures,
                captureSamples: false);
            images[mainEntry.key] = r.image;
            images.addAll(r.displayImages);
            for (final e in extraRuns) {
              final ids = [for (final op in e.value) op['nodeId'] as String];
              final caps = <String, String>{};
              eqAssign(ids, caps);
              final r2 = await gpu.run(e.value, f,
                  imageSources: {srcId: (workBytes, workW, workH)},
                  streamFormat: 'yuv420p',
                  streamLimited: limited,
                  displayCaptures: caps,
                  captureSamples: false);
              images[e.key] = r2.image;
              images.addAll(r2.displayImages);
            }
            if (allImageInstruments.isNotEmpty) {
              for (final entry in images.entries) {
                // 均衡器馈源图不是仪器馈源：剔出逐帧全幅回读。
                if (eqFeedImageKeys.contains(entry.key)) continue;
                rgbaMap[entry.key] =
                    await GpuPipeline.readbackBytes(entry.value);
              }
            } else {
              // 无仪器时 rgbaMap 仅供暂停复用占位，无需逐链回读。
              rgbaMap = {firstEntry.key: workBytes};
            }
            primaryRgba = rgbaMap[firstEntry.key] ?? workBytes;
            if (debugPlaybackTiming) {
              // ignore: avoid_print
              print('prod f=$f: 取流 $downUs us, GPU链生产 '
                  '${prodSw.elapsedMicroseconds - downUs} us');
            }
          } else {
            // cpuChains = 预览链 + 均衡器附加区馈源链（输出链/输入链）。
            // 馈源链为预览链前缀时由 runParallel 前缀覆盖顺带捕获，零额外
            // 计算；捕获不安全（eq 下游还有就地改写算子）时回退单独执行。
            rgbaMap = await pipeline!.runParallel(cpuChains, f,
                sourceRgba: yuvDirect ? null : workBytes,
                sourceYuv: yuvDirect ? workBytes : null,
                sourceWidth: workW,
                sourceHeight: workH);
            primaryRgba = rgbaMap[firstEntry.key] ?? workBytes;
            final pipeUs = prodSw.elapsedMicroseconds;

            Future<ui.Image> decodeFrame(Uint8List rgba) {
              final completer = Completer<ui.Image>();
              ui.decodeImageFromPixels(rgba, workW, workH,
                  ui.PixelFormat.rgba8888, completer.complete);
              return completer.future;
            }

            // 均衡器馈源图按 ≤480p 步长抽样解码：预览格仅 ~200px，视觉
            // 等效而上传/解码数据量降为 1/64（4K）；点采样成本与输出尺寸
            // 成正比。单次运行仍用全分辨率（取色器逐像素精度）。
            Future<ui.Image> decodeEqFeed(Uint8List rgba) {
              var step = 1;
              while (workH ~/ step > 480) {
                step *= 2;
              }
              if (step <= 1) return decodeFrame(rgba);
              final (d, dw, dh) =
                  downsampleRgba8Step(rgba, workW, workH, step);
              final completer = Completer<ui.Image>();
              ui.decodeImageFromPixels(d, dw, dh, ui.PixelFormat.rgba8888,
                  completer.complete);
              return completer.future;
            }

            await Future.wait([
              // 预览汇点出图（均衡器馈源链的键在此剔除，改按下条路由）。
              for (final entry in rgbaMap.entries)
                if (!eqExtraChains.containsKey(entry.key))
                  () async {
                    images[entry.key] = await decodeFrame(entry.value);
                  }(),
              // 均衡器馈源：输出 → images[eqId]（调整后），上游输出 →
              // images['$eqId#in']（调整前）；共享上游时按段各自解码，
              // 避免同一 ui.Image 双重归属。
              for (final eq in eqNodes)
                () async {
                  final outRgba = rgbaMap[eq.id];
                  if (outRgba != null) {
                    images[eq.id] = await decodeEqFeed(outRgba);
                  }
                  final up = eqUpstream[eq.id];
                  final inRgba = up == null ? null : rgbaMap[up];
                  if (inRgba != null) {
                    images['${eq.id}#in'] = await decodeEqFeed(inRgba);
                  }
                }(),
            ]);
            if (debugPlaybackTiming) {
              final imgUs = prodSw.elapsedMicroseconds;
              // ignore: avoid_print
              print('prod f=$f: 取流+降采样 $downUs us, 流水线 '
                  '${pipeUs - downUs} us, 图像解码 ${imgUs - pipeUs} us');
            }
          }
          // 流帧缓冲归还：gpuPlanes（含 planeDirect——videoDirect 为 true
          // 时）在生产内已把帧打包上传并抽完仪器馈源，须立即归还（否则
          // 走不到 4661 的延迟归还——其归还的是降采样馈源而非流缓冲，
          // 16 帧信用额度耗尽后解码死锁）；RGBA 直连单链延迟到仪器
          // 刷新后归还（其 rgbaMap 值即流缓冲本身）。
          if (!videoDirect || validChains.length > 1 || gpuPlanes) {
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
          rgbaMap = await pipeline!.runParallel(cpuChains, f);
          primaryRgba = rgbaMap[firstEntry.key]!;

          Future<ui.Image> decodeFrame(Uint8List rgba) {
            final completer = Completer<ui.Image>();
            ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888,
                completer.complete);
            return completer.future;
          }

          // 均衡器馈源图 ≤480p 解码（口径见视频 CPU 分支注释）。
          Future<ui.Image> decodeEqFeed(Uint8List rgba) {
            var step = 1;
            while (h ~/ step > 480) {
              step *= 2;
            }
            if (step <= 1) return decodeFrame(rgba);
            final (d, dw, dh) = downsampleRgba8Step(rgba, w, h, step);
            final completer = Completer<ui.Image>();
            ui.decodeImageFromPixels(d, dw, dh, ui.PixelFormat.rgba8888,
                completer.complete);
            return completer.future;
          }

          await Future.wait([
            for (final entry in rgbaMap.entries)
              if (!eqExtraChains.containsKey(entry.key))
                () async {
                  images[entry.key] = await decodeFrame(entry.value);
                }(),
            // 均衡器馈源路由同上（视频 CPU 分支注释）。
            for (final eq in eqNodes)
              () async {
                final outRgba = rgbaMap[eq.id];
                if (outRgba != null) {
                  images[eq.id] = await decodeEqFeed(outRgba);
                }
                final up = eqUpstream[eq.id];
                final inRgba = up == null ? null : rgbaMap[up];
                if (inRgba != null) {
                  images['${eq.id}#in'] = await decodeEqFeed(inRgba);
                }
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

      // 预缓冲：最多 4 帧在途生产（取帧经 fetchGate 串行、流水线计算
      // 在 worker 池中并行），播放节拍抖动由在途帧吸收，解码/流水线
      // 偶发慢帧不再直接造成上屏断档。GPU 链播放时取流/上传/跑链
      // 三段重叠更充分（4K60 的 16.6ms 帧预算对单段延迟极敏感；
      // 实测 4 帧与 5 帧等效，不再加大内存占用）。
      final inflight = Queue.of([produceFrame(frame)]);
      var nextProduceFrame = (frame + 1) % total;
      void refillInflight() {
        while (inflight.length < 4) {
          final f0 = nextProduceFrame;
          inflight.add(produceFrame(f0));
          nextProduceFrame = (f0 + 1) % total;
        }
      }

      refillInflight();
      // vsync 对齐上屏（真机）：自由运行的秒表节拍（33.33ms ±2ms）与
      // 显示器 vsync 无锁相，发布抖动会周期性把帧推过 vsync 边界，
      // 呈现时长在 1/2/3 个 vsync 间跳变——30fps 观感"丢帧"的主因
      //（系统播放器按 vsync 对齐呈递）。改为相位累加：每个 vsync
      // acc += fps，acc >= refresh 时发布一帧并 acc -= refresh——
      // 平均帧率精确、呈现间隔以 vsync 为粒度尽量均匀（60Hz/30fps
      // 恒为 2 vsync/帧）。回退秒表节拍的情形：无绑定环境（纯单元
      // 测试 SchedulerBinding 未初始化）、取不到刷新率、帧泵停摆
      //（首个 vsync 等待超时，如自动化测试不 pump 帧或窗口被遮蔽）。
      double vsyncRefresh = 0.0;
      try {
        SchedulerBinding.instance; // 未初始化环境抛 StateError
        vsyncRefresh = ui.PlatformDispatcher.instance.views.firstOrNull
                ?.display.refreshRate ??
            0.0;
      } catch (_) {
        vsyncRefresh = 0.0;
      }
      var vsyncDead = false;
      Future<void> nextVsync() {
        final c = Completer<void>();
        SchedulerBinding.instance.scheduleFrameCallback((_) {
          if (!c.isCompleted) c.complete();
        });
        SchedulerBinding.instance.scheduleFrame();
        return c.future;
      }

      try {
        while (isPlaying && token == _runToken) {
          if (vsyncRefresh > 0 && !vsyncDead) {
            // 按需出帧（不强制满速帧泵——4K/75Hz 下每次强制出帧的呈现
            // 开销会耗尽栅格线程，实测满速泵时栅格 18ms/帧、泵被拖到
            // ~48Hz）：秒表粗等到截止前 ~6ms，再调度一帧并对齐其
            // vsync 回调，发布被引擎量化到 vsync；栅格只承担发布帧。
            var remain = nextDeadline - playSw.elapsed;
            while (remain > const Duration(milliseconds: 6) &&
                isPlaying &&
                token == _runToken) {
              await Future<void>.delayed(
                  remain - const Duration(milliseconds: 6));
              remain = nextDeadline - playSw.elapsed;
            }
            var fired = true;
            await nextVsync().timeout(const Duration(milliseconds: 250),
                onTimeout: () {
              fired = false;
            });
            if (!fired) {
              vsyncDead = true;
            }
          }
          if (vsyncRefresh <= 0 || vsyncDead) {
            var remain = nextDeadline - playSw.elapsed;
            while (remain > const Duration(milliseconds: 4) &&
                isPlaying &&
                token == _runToken) {
              await Future<void>.delayed(
                  remain - const Duration(milliseconds: 4));
              remain = nextDeadline - playSw.elapsed;
            }
            while (remain > Duration.zero &&
                isPlaying &&
                token == _runToken) {
              await Future<void>.delayed(Duration.zero);
              remain = nextDeadline - playSw.elapsed;
            }
            final over = playSw.elapsed - nextDeadline;
            if (over.inMicroseconds > playbackMaxWaitOverUs) {
              playbackMaxWaitOverUs = over.inMicroseconds;
            }
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
            // 停滞重建时间轴。
            playbackDropped++;
            nextDeadline = playSw.elapsed;
          }
          if (gpuPlanes) {
            // 打包纹理换帧：同帧所有预览节点共享；旧纹理延迟一帧释放
            //（双缓冲，避免 GL 删除开销顶在发布帧上）。
            final packed = images['']!;
            final limited = !(stream?.info.fullRange ?? false);
            final matrix = stream?.info.colorMatrix ?? 0;
            _retirePlanePacked();
            previewPlanes = {
              for (final e in planeModes.entries)
                e.key: PlanePreviewFrame(packed, e.value, w, h, limited, matrix),
            };
          } else {
            for (final entry in images.entries) {
              // 均衡器「调整前」输入图（'$eqId#in' 键）路由到
              // previewInputImages，与单次运行的合并口径一致。
              if (entry.key.endsWith('#in')) {
                final base =
                    entry.key.substring(0, entry.key.length - 3);
                previewInputImages.remove(base)?.dispose();
                previewInputImages[base] = entry.value;
              } else {
                previewImages.remove(entry.key)?.dispose();
                previewImages[entry.key] = entry.value;
              }
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
          // 瞬时尖刺（冷启动硬解初始化、取流/上传的事件循环延迟抖动）
          // 不代表持续产能，超 2 倍帧预算的样本不进入 EMA——否则少数
          // 尖刺会把节拍长期拖在低位，帧率陷在「自限平衡」里爬不上去
          // （4K60 实测教训）。
          if (prod < frameDuration * 2) {
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
          statusMessage = srcFps > 0
              ? '播放中[$pathTag] $srcInfoTag'
                  '${fmtClock(f / srcFps)}/$srcInfoTotal  '
                  '第 ${f + 1}/$total 帧  '
                  '${fpsWindow.length} FPS  停滞 $playbackDropped 次'
              : '播放中[$pathTag] 第 ${f + 1}/$total 帧  '
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
          // 多段均衡器矢量示波器随播放刷新（~5Hz 节流 + busy 闸，
          // 不阻塞走帧；详见 _refreshEqScopesFromPlayback）。
          if (eqNodes.isNotEmpty) _refreshEqScopesFromPlayback(eqNodes, token);
          // 音频仪器（电平/波形/EQ）随播放位置刷新（限频 ~15Hz）。
          _refreshAudioInstrumentsFromPlayback(f, token);
          if (isVideo && videoDirect && !gpuPlanes) {
            // 像素与仪器数据都已取走，流帧缓冲归还池（gpuPlanes 的流
            // 缓冲已在生产内归还，此处 rgba 为降采样馈源，不归还）。
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
        // 均衡器矢量示波器停播时再以最后一帧前后预览图统计补齐一次
        //（播放中已按 ~5Hz 节流刷新，此处确保停在精确的最终帧口径）。
        if (token == _runToken && eqNodes.isNotEmpty) {
          await _refreshEqScopesFromPreviews(eqNodes, token);
        }
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

  /// 多段均衡器矢量示波器播放刷新的限频与重入闸（同 _instrumentBusy
  /// 思路；连线渲染是仪器池热点，~5Hz 节流而非逐帧）。
  bool _eqScopeBusy = false;
  DateTime _lastEqScopeRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放中刷新多段色彩均衡器的前后双联矢量示波器：以当前上屏帧的
  /// 「调整后/调整前」馈源统计（优先 [_lastPlaybackRgba] 的
  /// 'eqId'/'eqId#in' 条目——CPU worker 路径经 runParallel 前缀覆盖
  /// 顺带捕获；GPU 链路径馈源是 GPU 驻留 ui.Image，回退 previewImages
  /// 回读；GPU 平面模式条目按 [_lastPlaybackDims] 的真实平面尺寸喂
  /// 数，缺失/尺寸不符跳过该次）。统计口径与停播补齐
  /// [_refreshEqScopesFromPreviews] 一致（[_hslVectorscopeImage]：
  /// ~240p 降采样 + 仪器池多核并行）。fire-and-forget + busy 闸，
  /// 不阻塞走帧；刷新只走 instrumentTick（局部重建）。
  void _refreshEqScopesFromPlayback(List<IspNode> eqNodes, int token) {
    if (eqNodes.isEmpty || _eqScopeBusy) return;
    final now = DateTime.now();
    if (now.difference(_lastEqScopeRefresh) <
        const Duration(milliseconds: 200)) {
      return;
    }
    final rgbaMap = _lastPlaybackRgba;
    if (rgbaMap == null) return;
    _lastEqScopeRefresh = now;
    _eqScopeBusy = true;
    () async {
      try {
        for (final eq in eqNodes) {
          for (final isIn in [false, true]) {
            if (token != _runToken) return;
            final key = isIn ? '${eq.id}#in' : eq.id;
            Uint8List? rgba;
            var w = 0, h = 0;
            final entry = rgbaMap[key];
            if (entry != null) {
              final dim = _lastPlaybackDims?[key];
              final ew = dim?.$1 ?? _lastPlaybackW;
              final eh = dim?.$2 ?? _lastPlaybackH;
              if (ew > 0 && eh > 0 && entry.length == ew * eh * 4) {
                rgba = entry;
                w = ew;
                h = eh;
              }
            }
            if (rgba == null) {
              final img =
                  isIn ? previewInputImages[eq.id] : previewImages[eq.id];
              if (img == null) continue;
              final bd = await img.toByteData();
              if (bd == null) continue;
              rgba = bd.buffer.asUint8List();
              w = img.width;
              h = img.height;
            }
            final scope = await _hslVectorscopeImage(rgba, w, h);
            if (scope == null) continue;
            if (token != _runToken) {
              scope.dispose();
              return;
            }
            if (isIn) {
              hslInputVectorscopes.remove(eq.id)?.dispose();
              hslInputVectorscopes[eq.id] = scope;
            } else {
              hslVectorscopes.remove(eq.id)?.dispose();
              hslVectorscopes[eq.id] = scope;
            }
          }
        }
        if (token == _runToken) instrumentTick.value++;
      } finally {
        _eqScopeBusy = false;
      }
    }();
  }

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
                // 分路器通道输出（out_r/g/b 等）的端口修正：同分路器下
                // 多台仪器复用到同一帧时提取各自通道（见
                // _instrumentChannelFeed）；非通道馈源原样返回。
                final feedRgba =
                    _instrumentChannelFeed(node, srcNodeId, downRgba);
                // 深度评价（Python 桥接）：pair/single 播放中不刷新
                // （与 PSNR/ILNIQE 一致，保留运行时结果；它们不在仪器
                // worker 的口径内，直接 analyze 会报「未知仪器类型」）；
                // dist（FID/KID）逐帧累计两侧样本后出分。
                if (pyIqaMetrics.containsKey(node.typeId)) {
                  if (pyIqaMetrics[node.typeId]!.kind != 'dist') return;
                  final r = await _pyiqaDistPlaybackFrame(node, feedRgba, dw,
                      dh, rgbaMap, w, h, dims, downCache, token);
                  if (r == null) return; // 测试路未接入/环境缺失：跳过
                  if (token != _runToken) return;
                  instrumentResults[node.id] = r;
                  return;
                }
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
                  var vecRgba = feedRgba;
                  var vw = dw, vh = dh;
                  var vstep = 1;
                  while (vh ~/ vstep > 240) {
                    vstep *= 2;
                  }
                  if (vstep > 1) {
                    (vecRgba, vw, vh) =
                        downsampleRgba8Step(feedRgba, dw, dh, vstep);
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
                        feedRgba, dw, dh, node.typeId,
                        visible: waveformChannels(node.id));
                  } catch (_) {
                    // worker 侧渲染失败：回退为池内分析 + 本地渲染。
                    result = await _instrumentAnalyzer.analyze(
                        feedRgba, dw, dh, node.typeId);
                  }
                } else {
                  result = await _instrumentAnalyzer.analyze(
                      feedRgba, dw, dh, node.typeId);
                }
                if (token != _runToken) return;
                instrumentResults[node.id] = node.typeId == 'minmax'
                    ? _mergeMinmaxHold(node.id, result)
                    : result;
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

  /// 通道端口类型 → 通道提取名（[extractChannelGray] 的 channel 参数）。
  static String? _channelOfPortType(IspPortType t) => switch (t) {
        IspPortType.r => 'r',
        IspPortType.g => 'g',
        IspPortType.b => 'b',
        IspPortType.y => 'y',
        IspPortType.u => 'u',
        IspPortType.v => 'v',
        IspPortType.h => 'h',
        IspPortType.s => 's',
        IspPortType.l => 'l',
        _ => null,
      };

  /// 仪器复用馈源的端口修正：播放/暂停复用的帧按预览节点 id 键控、
  /// 无端口维度，接在分路器通道输出（out_r/g/b、out_y/u/v、out_h/s/l）
  /// 下的多台仪器会解析到同一帧（显示数值完全一样）。仪器经 in_mono
  /// 接在通道端口、且解析到的预览并非接在同一输出端口时，从复用帧
  /// 提取对应通道灰度作为馈源；其余情况原样返回。
  Uint8List _instrumentChannelFeed(
      IspNode node, String? srcNodeId, Uint8List rgba) {
    final conn = graph.connectionAt(node.id, 'in_mono');
    if (conn == null) return rgba;
    final upstream = graph.nodes[conn.fromNodeId];
    final portType = upstream == null
        ? null
        : IspNodeRegistry.byId(upstream.typeId)
            ?.outputPort(conn.fromPort)
            ?.type;
    final channel = portType == null ? null : _channelOfPortType(portType);
    if (channel == null) return rgba;
    // 解析到的预览正好接在同一输出端口：它显示的就是该通道，无需提取。
    if (srcNodeId != null) {
      final pNode = graph.nodes[srcNodeId];
      final pType = pNode == null ? null : IspNodeRegistry.byId(pNode.typeId);
      if (pType != null) {
        for (final p in pType.inputs) {
          final pc = graph.connectionAt(srcNodeId, p.name);
          if (pc != null &&
              pc.fromNodeId == conn.fromNodeId &&
              pc.fromPort == conn.fromPort) {
            return rgba;
          }
        }
      }
    }
    return extractChannelGray(rgba, channel);
  }

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

  /// 双输入评价（FID/KID）测试路（in_test* 端口组）的预览源节点解析：
  /// 与 [_findSourcePreviewNodeId]（参考路）同思路；回退匹配改为精确
  /// 检查测试路上游节点是否在预览链内（不能用 _sharesUpstream——
  /// 仪器节点同时挂参考/测试两侧，会误配到参考路的预览）。
  String? _findTestPreviewNodeId(IspNode instrument) {
    final conn = graph.connectionAt(instrument.id, 'in_test_mono') ??
        graph.connectionAt(instrument.id, 'in_test_yuv') ??
        graph.connectionAt(instrument.id, 'in_test_hsl') ??
        graph.connectionAt(instrument.id, 'in_test');
    if (conn == null) return null;
    final upstreamId = conn.fromNodeId;
    if (graph.nodes[upstreamId]?.typeId == 'preview') {
      return upstreamId;
    }
    for (final pNode in graph.nodes.values) {
      if (pNode.typeId != 'preview') continue;
      final chain = compileChain(graph, pNode.id);
      if (chain.any((e) => e['nodeId'] == upstreamId)) return pNode.id;
    }
    return null;
  }

  /// FID/KID 播放中的逐帧累计：参考路用当前刷新帧（[feedRgba]，已按
  /// ~480p 口径降采样），测试路从 [rgbaMap] 解析 in_test* 上游预览帧
  /// （同口径）。新一轮运行（[token] 变化）先复位桥接进程的累计特征。
  /// 测试路未接入/无法解析或 Python 环境缺失时返回 null（跳过）。
  /// 注：测试路的通道修正（分路器 out_* 端口）未做——RGB 直连是常态，
  /// 通道馈源在暂停/运行路径（_analyzePyIqa）下走链重跑，口径完整。
  Future<Map<String, Object?>?> _pyiqaDistPlaybackFrame(
      IspNode node,
      Uint8List feedRgba,
      int dw,
      int dh,
      Map<String, Uint8List> rgbaMap,
      int w,
      int h,
      Map<String, (int, int)>? dims,
      Map<String, (Uint8List, int, int)> downCache,
      int token) async {
    if (!PyIqaWorker.available) return null;
    final kind = node.typeId;
    final testSrcId = _findTestPreviewNodeId(node);
    if (testSrcId == null) return null;
    final testRgba = rgbaMap[testSrcId];
    if (testRgba == null) return null;
    // 测试路同 ~480p 口径降采样（缓存键加前缀，避免与参考路串缓存）。
    final dim = dims?[testSrcId];
    final ew = dim?.$1 ?? w;
    final eh = dim?.$2 ?? h;
    final (testDown, tw, th) = downCache.putIfAbsent('#test:$testSrcId', () {
      var step = 1;
      while (eh ~/ step > 480) {
        step *= 2;
      }
      return downsampleRgba8Step(testRgba, ew, eh, step);
    });
    final worker = PyIqaWorker.forMetric(kind);
    if (_pyiqaDistTokens[node.id] != token) {
      _pyiqaDistTokens[node.id] = token;
      await worker.distReset();
    }
    final pa = await pyIqaWriteTempPng(feedRgba, dw, dh);
    final pb = await pyIqaWriteTempPng(testDown, tw, th);
    final nRef = await worker.distAdd('ref', pa);
    final nTest = await worker.distAdd('test', pb);
    final s = await worker.distScore();
    if (s == null) return {'kind': kind, 'n_ref': nRef, 'n_test': nTest};
    return {'kind': kind, kind: s.$1, 'n_ref': s.$2, 'n_test': s.$3};
  }

  /// 查询 [nodeId] 输出缓冲在 (x, y, channel) 处的值。
  ///
  /// 变量表只保留前 [kNodeOutputSampleSize] 项采样，超出部分按需重跑：
  /// 编译到该节点为止的链，在后台 isolate 执行当前预览帧并取单个元素。
  Future<int> queryNodeOutputAt(
      String nodeId, int x, int y, int channel) async {
    final chain = _withHdrToneMapFlag(compileChain(graph, nodeId));
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

  /// 有显示区（可最大化）的节点：预览 + 调节器（HSL/RGB/YUV、色彩控制器、
  /// 多段色彩均衡器、色饱和度/亮度、亮度/对比度、色彩平衡、色温）+
  /// 高频边缘提取 + 曲线调节器 + 仪器（含音频仪器）。
  bool canMaximize(String nodeId) {
    final t = graph.nodes[nodeId]?.typeId;
    return t == 'preview' ||
        t == 'hsl_debugger' ||
        t == 'color_controller' ||
        t == 'multi_band_eq' ||
        t == 'rgb_debugger' ||
        t == 'yuv_debugger' ||
        t == 'sat_bright_adjuster' ||
        t == 'bright_contrast_adjuster' ||
        t == 'gaussian_blur' ||
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
    final h = height.clamp(
        minExtraHeightFor(graph.nodes[nodeId]?.typeId ?? ''),
        maxPreviewExtraHeightFor(graph.nodes[nodeId]?.typeId ?? ''));
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

  /// 视频健康检查：内嵌终端流式输出检查报告（record-2024-09-26 卡顿
  /// 排查检查项固化，见 pipeline/video_health）。报告实时显示在节点
  /// 卡片的终端面板（[healthCheckLogs] + [healthCheckTick]）；结构化
  /// 进度（阶段/已检帧/时间/完成度/预估剩余）节流写到状态栏
  /// [statusMessage]。[stopHealthCheck] 置取消标记中止（引擎返回 -2）。
  Future<void> runHealthCheck(String nodeId) async {
    if (healthCheckRunning.contains(nodeId)) return; // 防重入
    if (isPlaying) return; // 播放中不开始检查（statusMessage 不冲突）
    final node = graph.nodes[nodeId];
    if (node == null) return;
    final p = node.paramValues;
    final input = p['inputFile']?.toString() ?? '';
    var ffmpeg = p['ffmpegPath']?.toString() ?? '';
    if (ffmpeg.isEmpty) ffmpeg = 'tools/ffmpeg/ffmpeg.exe';
    healthCheckRunning.add(nodeId);
    healthCheckLogs[nodeId] = '';
    healthCheckTick.value++;
    statusMessage = '检查中[准备] 正在读取基本信息…';
    notifyListeners();
    var lastProgMs = 0;
    try {
      final exit = await vhealth.runVideoHealthCheck(
        ffmpegPath: ffmpeg,
        inputFile: input,
        scanDepth: p['scanDepth']?.toString() ?? 'fast',
        isCancelled: () => healthCheckCancelRequested.contains(nodeId),
        onProgress: (prog) {
          // 状态栏进度 ~2Hz 节流（引擎侧已 ~4Hz）。
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastProgMs < 500) return;
          lastProgMs = now;
          statusMessage = '检查中[${prog.stageName}] 已检查 '
              '${prog.stageFramesDone}/${prog.totalFrames} 帧  '
              '${vhealth.fmtClockSec(prog.videoSecDone)}/'
              '${vhealth.fmtClockSec(prog.videoSecTotal)}  '
              '完成 ${(prog.overall * 100).toStringAsFixed(0)}%  '
              '预计剩余 ${vhealth.fmtHmsSec(prog.etaSec)}';
          notifyListeners();
        },
        onOutput: (chunk) {
          // 高频回调：只追加日志并动 tick（局部重建），不 notifyListeners。
          healthCheckLogs[nodeId] = fmtconv.appendConsoleText(
              healthCheckLogs[nodeId] ?? '', chunk);
          healthCheckTick.value++;
        },
      );
      healthCheckLogs[nodeId] = fmtconv.appendConsoleText(
          healthCheckLogs[nodeId] ?? '',
          exit == -2
              ? '\n[已中止] 检查未完成\n'
              : exit < 0
                  ? '\n[FAILED] 检查未完成（exit $exit）\n'
                  : '\n[DONE] 检查完成\n');
      statusMessage = exit == -2
          ? '检查已中止'
          : exit < 0
              ? '检查失败（exit $exit）'
              : exit == 0
                  ? '检查完成：全部正常'
                  : '检查完成：有警告（详见节点报告）';
    } finally {
      healthCheckRunning.remove(nodeId);
      healthCheckCancelRequested.remove(nodeId);
      healthCheckTick.value++;
      notifyListeners();
    }
  }

  /// 中止指定节点的视频健康检查（仅检查进行中有效）：置取消标记，
  /// 引擎在行循环/阶段边界 kill 当前 ffmpeg 子进程并返回 -2。
  void stopHealthCheck(String nodeId) {
    if (!healthCheckRunning.contains(nodeId)) return;
    healthCheckCancelRequested.add(nodeId);
  }

  /// 探测实测可用的硬件编码器（-encoders 编译支持 + 逐候选微缩试编码
  /// 验证）。幂等：探测中或已探测过且非强制时直接返回；失败静默留空表。
  Future<void> probeHwEncoders({    String ffmpegPath = 'tools/ffmpeg/ffmpeg.exe',
    bool force = false,
  }) async {
    if (hwEncoderProbing) return;
    if (!force && hwEncoderProbed) return;
    hwEncoderProbing = true;
    notifyListeners();
    try {
      hwEncoders = await fmtconv.probeHwEncoders(ffmpegPath);
    } catch (_) {
      hwEncoders = const [];
    } finally {
      hwEncoderProbing = false;
      hwEncoderProbed = true;
      notifyListeners();
    }
  }

  /// 视频健康检查节点（video_health_check）的内嵌终端全文：节点 id →
  /// 报告文本（经 appendConsoleText 做 \r 覆盖行处理）。
  final healthCheckLogs = <String, String>{};

  /// 视频健康检查进行中的节点 id 集合（按钮禁用/文案切换，防重入）。
  final healthCheckRunning = <String>{};

  /// 视频健康检查取消请求的节点 id 集合（stopHealthCheck 置位，引擎
  /// isCancelled 轮询，runHealthCheck 结束时清理）。
  final healthCheckCancelRequested = <String>{};

  /// 视频健康检查终端刷新信号（同 formatConvertTick 模式）。
  final ValueNotifier<int> healthCheckTick = ValueNotifier(0);

  /// 格式转换节点输入片源的动态范围探测结果：节点 id → 0 SDR/1 PQ/
  /// 2 HLG，-1 = 探测失败（属性面板「输入」显示与 outputRange 选项
  /// 过滤用）。
  final formatConvertInputRange = <String, int>{};

  /// 各节点最近一次探测时的 inputFile（幂等：同路径不重复探测）。
  final _formatConvertProbePath = <String, String>{};

  /// 探测格式转换节点输入片源的动态范围（videoFileInfo 有缓存；
  /// 幂等：同 inputFile 已探过直接返回；inputFile 变化后再次调用会
  /// 重新探测）。
  Future<void> probeFormatConvertInput(String nodeId) async {
    final node = graph.nodes[nodeId];
    if (node == null) return;
    final p = node.paramValues;
    final input = p['inputFile']?.toString() ?? '';
    var ffmpeg = p['ffmpegPath']?.toString() ?? '';
    if (ffmpeg.isEmpty) ffmpeg = 'tools/ffmpeg/ffmpeg.exe';
    if (_formatConvertProbePath[nodeId] == input) return;
    _formatConvertProbePath[nodeId] = input;
    if (input.isEmpty) {
      formatConvertInputRange[nodeId] = -1;
      notifyListeners();
      return;
    }
    try {
      final info = await videoFileInfo(input, ffmpegPath: ffmpeg);
      formatConvertInputRange[nodeId] = info.colorTransfer;
    } catch (_) {
      formatConvertInputRange[nodeId] = -1;
    }
    notifyListeners();
  }

  /// 格式转换（webm → mp4）：内嵌终端流式运行 ffmpeg（编码器由节点
  /// encoder 参数选择：auto 硬件优先回退 libx264；输出动态范围由
  /// outputRange 参数选择：auto 跟随片源 / SDR tonemap / HDR HEVC
  /// 10bit），输出实时显示在节点卡片的终端面板（[formatConvertLogs]
  /// + [formatConvertTick]）。
  Future<void> convertVideoFormat(String nodeId) async {
    if (formatConvertRunning.contains(nodeId)) return; // 防重入
    final node = graph.nodes[nodeId];
    if (node == null) return;
    final p = node.paramValues;
    final input = p['inputFile']?.toString() ?? '';
    final output = p['outputFile']?.toString() ?? '';
    var ffmpeg = p['ffmpegPath']?.toString() ?? '';
    if (ffmpeg.isEmpty) ffmpeg = 'tools/ffmpeg/ffmpeg.exe';
    formatConvertRunning.add(nodeId);
    formatConvertLogs[nodeId] = '';
    formatConvertTick.value++;
    notifyListeners();
    try {
      final exit = await fmtconv.runFormatConvert(
        ffmpegPath: ffmpeg,
        inputFile: input,
        outputFile: output,
        encoder: p['encoder']?.toString() ?? 'auto',
        hwEncoders: hwEncoders,
        outputRange: p['outputRange']?.toString() ?? 'auto',
        onOutput: (chunk) {
          // 高频回调：只追加日志并动 tick（ValueListenableBuilder 局部
          // 重建，参照 instrumentTick），不 notifyListeners。
          formatConvertLogs[nodeId] = fmtconv.appendConsoleText(
              formatConvertLogs[nodeId] ?? '', chunk);
          formatConvertTick.value++;
        },
      );
      formatConvertLogs[nodeId] = fmtconv.appendConsoleText(
          formatConvertLogs[nodeId] ?? '',
          exit == 0
              ? '\n[DONE] Output file: $output\n'
              : '\n[FAILED] exit $exit\n');
    } finally {
      formatConvertRunning.remove(nodeId);
      formatConvertTick.value++;
      notifyListeners();
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
    final frameRunners = <PipelineFrameRunner>[];
    final rangeRunners = <ExportRangeRunner>[];
    Process? gpuDecodeProc;
    try {
      final node = graph.nodes[nodeId]!;
      final p = node.paramValues;
      final outPath = p['filePath']?.toString() ?? '';
      if (outPath.isEmpty) throw StateError('视频输出节点未设置输出文件');
      // ffmpeg 不会自建目录：确保输出目录存在。
      await File(outPath).parent.create(recursive: true);
      final fps = (p['fps'] as num?)?.toInt() ?? 30;
      final crf = (p['crf'] as num?)?.toInt() ?? 25;
      final encoder = p['encoder']?.toString() ?? 'auto';
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

      // 导出进度状态（状态栏实时显示：分辨率/帧率/时长/ETA/实时帧率）。
      exportVideoInfo =
          ExportProgressInfo(width: w, height: h, fps: fps, totalFrames: total);
      exportInfoTick.value++;
      _exportInfoLastNotifyMs = 0;

      // 帧生产优化（2026-09 性能排查结论）：
      // - 旧实现每帧 compute() 新起 isolate（spawn 开销每帧摊一次），且
      //   视频源每帧 seek 起一次 ffmpeg（~1.2s/帧 4K）；编码侧（NVENC）
      //   实测只占 <1% GPU，瓶颈全在帧生产。
      // - 优先级：video_source 且全链 GPU 支持时走 GPU 链（流式解码
      //   yuv420p 直传上传 → GpuPipeline 离屏逐帧渲染 → 回读喂编码，
      //   CPU 只做搬运）；否则视频源走「范围任务制」CPU 池、其余源走
      //   常驻 runner 按帧并行。
      final isVideoSource = srcTypeId == 'video_source';
      final srcPath = srcParams['filePath']?.toString() ?? '';

      // ---- GPU 链判定（仅 video_source）----
      // 汇点 video_output 以视频组 in 接入时截掉汇点节点在 GPU 上执行
      //（CPU 语义同样以链尾默认色调映射收尾）；汇点接 mono 轨、链过短、
      // 含 supportedOps 外节点或 shader 不可用时回退 CPU 池并注明原因。
      var gpuChain = chain;
      String? gpuBlockReason;
      if (isVideoSource) {
        final last = chain.last;
        final lastType = last['typeId'] as String;
        final lastInputs = (last['inputs'] as Map?)?.cast<String, Object?>();
        if (lastType == 'video_output' && lastInputs?['in_mono'] == null) {
          gpuChain = chain.sublist(0, chain.length - 1);
        } else if (lastType == 'video_output') {
          gpuBlockReason = '汇点 mono 轨';
        }
        if (gpuBlockReason == null && gpuChain.length < 2) {
          gpuBlockReason = '链过短';
        }
        if (gpuBlockReason == null &&
            !GpuPipeline.isSupportedChain(gpuChain)) {
          final bad = <String>[
            for (final op in gpuChain.skip(1))
              if (!GpuPipeline.supportedOps.contains(op['typeId'] as String))
                op['typeId'] as String,
          ];
          gpuBlockReason = bad.isEmpty ? '连接形态' : bad.take(3).join('、');
        }
      }
      final gpu = gpuBlockReason == null ? await _gpuPipeline() : null;
      final useGpuChain = gpu != null && isVideoSource;
      // 420 直传需偶数高且宽为 4 的倍数，否则退化 rgba 直传（仍走 GPU 链）。
      final gpuStreamFormat =
          (w.isEven && h.isEven && w % 4 == 0) ? 'yuv420p' : 'rgba';
      // 硬解探测（按实际片源/尺寸/输出格式）；失败回退软解。
      final hwaccel = useGpuChain
          ? await probeHwDecode(ffmpeg, srcPath,
              width: w, height: h, pixelFormat: gpuStreamFormat)
          : '';
      var pathNote = useGpuChain
          ? 'GPU 链'
          : (gpuBlockReason != null
              ? 'CPU 池（链含 GPU 不支持节点：$gpuBlockReason）'
              : 'CPU 池');

      if (!useGpuChain) {
        frameRunners.addAll(List.generate(
            (Platform.numberOfProcessors - 2).clamp(2, 16),
            (_) => PipelineFrameRunner()));
        if (isVideoSource) {
          // 每个 range worker 同时跑一路 HEVC 软解 + 完整 ISP 链，按
          // 核数/4 封顶 16（实测 52 并发软解会严重争抢降速）。
          rangeRunners.addAll(List.generate(
              (Platform.numberOfProcessors ~/ 4).clamp(2, 16),
              (_) => ExportRangeRunner()));
        }
      }
      // 并发预热（spawn 开销与导出初始化重叠，长导出趋近零摊销）。
      unawaited(Future.wait([
        for (final r in frameRunners) r.warmup(),
        for (final r in rangeRunners) r.warmup(),
      ]));
      final workers = frameRunners.length;
      var next = 0;
      final pending = <int, Future<Uint8List>>{};

      // 范围任务制状态（仅 video_source）。
      final srcFps = isVideoSource
          ? (await videoFileInfo(srcParams['filePath']?.toString() ?? '',
                  ffmpegPath: srcParams['ffmpegPath']?.toString() ?? ''))
              .fps
          : 30.0;
      // GPU 不可用回退 CPU 池时若 runner 为空（shader 加载失败等），
      // 退化为小区间而非除零。
      final rangeSize = isVideoSource && rangeRunners.isNotEmpty
          ? (total / (rangeRunners.length * 8)).ceil().clamp(4, 64)
          : 4;
      var nextRange = 0;
      final pendingRanges = <int, Future<(int, List<Uint8List>)>>{};
      final rangeFrames = <int, List<Uint8List>>{};
      void scheduleRange() {
        while (pendingRanges.length < rangeRunners.length &&
            nextRange * rangeSize < total) {
          final k = nextRange++;
          final start = k * rangeSize;
          if (start >= total) break;
          final count = (total - start).clamp(0, rangeSize);
          pendingRanges[k] = rangeRunners[k % rangeRunners.length].run(
              chain,
              srcParams['filePath']?.toString() ?? '',
              ffmpeg,
              w,
              h,
              start,
              count,
              srcFps);
        }
      }

      void schedule() {
        while (pending.length < workers && next < total) {
          final i = next++;
          pending[i] = frameRunners[i % workers]
              .run(chain, i)
              .then((r) => r.$1);
        }
      }

      // JIT（debug 运行）冷启动时并行帧会挤在共享编译队列上，慢一个量级；
      // 先串行算第 0 帧热身，后续并行帧复用优化后的代码。AOT 无此问题。
      if (kDebugMode && total > 1 && !useGpuChain) {
        statusMessage = '正在导出视频（热身帧）…';
        notifyListeners();
        pending[0] = frameRunners[0].run(chain, 0).then((r) => r.$1);
        next = 1;
        await pending[0]; // 等热身完成（结果留在队列按序交付）
      }
      if (useGpuChain) {
        statusMessage = '正在导出视频（GPU 链处理）…';
        notifyListeners();
      } else if (isVideoSource) {
        scheduleRange();
      } else {
        schedule();
      }

      // GPU 链的解码流（流式直传 yuv420p/rgba → 上传纹理，CPU 零转换）。
      // 句柄留存：导出结束/失败时 kill，避免解码进程悬挂占住源文件。
      final gpuFrames = useGpuChain
          ? StreamIterator(decodeVideoStreamRgba(srcPath,
              width: w,
              height: h,
              ffmpegPath: ffmpeg,
              pixelFormat: gpuStreamFormat,
              hwaccel: hwaccel,
              // 每包一帧，禁 CFR 复制（防 60fps VUI 片源导出帧数翻倍）。
              passthrough: true,
              onProcess: (proc) => gpuDecodeProc = proc))
          : null;

      // 分段并行导出（GPU 链 + 帧数够切）：源按包拆为关键帧对齐分段，
      // 各段独立解码流（worker isolate + FfmpegRawPipeWin 整帧快读 +
      // 硬解）与编码进程（双 NVENC 引擎），渲染经异步锁串行
      // （GpuPipeline 有时域历史等实例状态），完成后 concat 无损拼接
      // 并校验帧数/时长；除取消外的任何失败回退下方单段路径。
      String? segEncoder;
      if (useGpuChain && total >= _kExportSegMinFrames) {
        statusMessage =
            '正在导出视频（GPU 链 ×$_kExportGpuSegments 段并行）…';
        notifyListeners();
        try {
          final (segEnc, segParts) = await _exportVideoGpuSegmented(
            gpuChain: gpuChain,
            gpu: gpu,
            srcPath: srcPath,
            ffmpeg: ffmpeg,
            outPath: outPath,
            w: w,
            h: h,
            fps: fps,
            crf: crf,
            encoder: encoder,
            hwaccel: hwaccel,
            gpuStreamFormat: gpuStreamFormat,
            total: total,
            srcFps: srcFps,
            token: token,
          );
          segEncoder = segEnc;
          pathNote = 'GPU 链 ×$segParts 段';
        } catch (e) {
          if (token != _runToken) rethrow; // 取消：外抛走统一收尾
          segEncoder = null;
          pathNote = 'GPU 链（分段失败回退单段：'
              '${e.toString().replaceFirst('Bad state: ', '')}）';
        }
      }

      // GPU 出图改 yuv420p：链尾 RGB→YUV420P pass（BT.601 limited，与
      // ffmpeg rgba→yuv420p 转换同口径，色度 2x2 均值有 ±1 LSB 差异），
      // 回读 12.4MB/帧（4K）替代 33MB/帧 RGBA，ffmpeg 原生吃 yuv420p。
      // 流水重叠：写第 N 帧期间预渲染第 N+1 帧（深度 1 前瞻）。
      Future<Uint8List> renderGpuFrame(int i) async {
        final it = gpuFrames!;
        if (!await it.moveNext()) {
          throw StateError('视频帧流提前结束于第 $i 帧（共 $total 帧）');
        }
        final r = await gpu!.run(gpuChain, i,
            imageSources: {
              gpuChain.first['nodeId'] as String: (it.current, w, h),
            },
            streamFormat: gpuStreamFormat,
            captureSamples: false);
        ui.Image? yuvImg;
        try {
          yuvImg = await gpu.rgba8ToYuv420p(r.image, w, h);
        } finally {
          r.image.dispose();
        }
        try {
          return await GpuPipeline.readbackBytes(yuvImg);
        } finally {
          yuvImg.dispose();
        }
      }

      Future<Uint8List>? nextGpuFrame;

      final usedEncoder = segEncoder ?? await exportMp4(
        ffmpegPath: ffmpeg,
        outputPath: outPath,
        width: w,
        height: h,
        fps: fps,
        crf: crf,
        frameCount: total,
        encoder: encoder,
        inputPixelFormat: useGpuChain ? 'yuv420p' : 'rgba',
        frameProvider: (i) async {
          if (token != _runToken) throw StateError('导出已取消');
          if (useGpuChain) {
            nextGpuFrame ??= renderGpuFrame(i);
            final bytes = await nextGpuFrame!;
            nextGpuFrame = i + 1 < total ? renderGpuFrame(i + 1) : null;
            return bytes;
          }
          if (isVideoSource) {
            final k = i ~/ rangeSize;
            if (!rangeFrames.containsKey(k)) {
              final start = k * rangeSize;
              final future = pendingRanges.remove(k);
              if (future == null) throw StateError('帧区间 $k 未在调度队列中');
              final (gotStart, frames) = await future;
              if (gotStart != start) {
                throw StateError('帧区间序号错位：期望 $start 实到 $gotStart');
              }
              rangeFrames[k] = frames;
              scheduleRange();
            }
            final frames = rangeFrames[k]!;
            final offset = i - k * rangeSize;
            if (offset >= frames.length) {
              throw StateError('帧 $i 超出已交付区间（区间长度 ${frames.length}）');
            }
            return frames[offset];
          }
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
          _advanceProgress(done / totalFrames);
          // 导出状态行（分辨率/帧率/时长/ETA/实时帧率）节流刷新：左侧
          // 信息由 exportVideoInfo + exportInfoTick 承载，不再逐帧
          // statusMessage + notifyListeners（全树重建）。
          exportVideoInfo
              ?.addFrame(DateTime.now().millisecondsSinceEpoch);
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _exportInfoLastNotifyMs >= 250) {
            _exportInfoLastNotifyMs = nowMs;
            exportInfoTick.value++;
          }
        },
      );
      gpuDecodeProc?.kill();
      for (final r in frameRunners) {
        r.dispose();
      }
      for (final r in rangeRunners) {
        r.dispose();
      }
      statusMessage = '视频导出完成 → $outPath'
          '（${usedEncoder == 'nvenc' ? 'h264_nvenc 硬件编码' : 'libx264 软件编码'}，$pathNote）';
    } catch (e) {
      statusMessage = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      gpuDecodeProc?.kill();
      for (final r in frameRunners) {
        r.dispose();
      }
      for (final r in rangeRunners) {
        r.dispose();
      }
      // 导出结束/失败/取消统一清掉状态栏导出信息。
      exportVideoInfo = null;
      exportInfoTick.value++;
      if (token == _runToken) {
        isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// 分段并行导出：段数 / 段内渲染前瞻深度 / 启用分段的最小帧数。
  /// GeForce 消费卡 NVENC 并发会话通常限 3 路，默认 2 段留有余量；
  /// 帧数太少时分段的进程启动/拼接开销得不偿失。
  static const int _kExportGpuSegments = 2;
  static const int _kExportGpuSegDepth = 1;
  static const int _kExportSegMinFrames = 16;

  /// GPU 链分段并行导出：源先经 ffmpeg 按包拆为关键帧对齐的分段
  /// （不解码，~500x 速度；每包恰好落入一段，对 VFR/时间戳异常片源
  /// 同样精确——-ss 时间寻址切分在这类片源上会落错帧），各段独立
  /// VideoFrameStream 解码（worker isolate + FfmpegRawPipeWin 快路径）
  /// 与 ffmpeg 编码进程，渲染经异步锁串行（GpuPipeline 的
  /// _temporalHistory 等实例状态不可并发），完成后
  /// `ffmpeg -f concat -c copy` 无损拼接并校验帧数/时长。
  /// 返回（实际使用的编码器 id, 分段数）。任何失败抛 [StateError]
  /// （调用方回退单段路径；取消经 token 判定直接外抛）。
  Future<(String, int)> _exportVideoGpuSegmented({
    required List<Map<String, Object?>> gpuChain,
    required GpuPipeline gpu,
    required String srcPath,
    required String ffmpeg,
    required String outPath,
    required int w,
    required int h,
    required int fps,
    required int crf,
    required String encoder,
    required String hwaccel,
    required String gpuStreamFormat,
    required int total,
    required double srcFps,
    required int token,
  }) async {
    final ff = File(ffmpeg).absolute.path;
    final segEncoder =
        await resolveMp4Encoder(ff, encoder, width: w, height: h);
    final srcId = gpuChain.first['nodeId'] as String;
    final workDir = await Directory.systemTemp.createTemp('isp_export_seg_');
    final streams = <VideoFrameStream>[];
    final encoders = <Process>[];

    /// 尽力清理：任何一步失败都不外抛（解码进程若成孤儿持有分段
    /// 临时文件，删除失败不应把已成功的导出判为失败；孤儿进程随
    /// 应用退出回收，临时目录留给系统 temp 清理）。
    Future<void> cleanup() async {
      for (final enc in encoders) {
        enc.kill();
      }
      for (final stream in streams) {
        try {
          await stream
              .dispose()
              .timeout(const Duration(seconds: 5), onTimeout: () {});
        } catch (_) {}
      }
      try {
        if (workDir.existsSync()) await workDir.delete(recursive: true);
      } catch (_) {}
    }

    try {
      // 分包预处理（不解码）+ 各段帧数统计（免解码数包）。
      final parts = await splitVideoByPackets(
          ff, srcPath, total / srcFps, _kExportGpuSegments, workDir.path);
      if (parts.length < 2) {
        throw StateError('片源关键帧过稀，无法分段');
      }
      final counts = <int>[];
      for (final part in parts) {
        final c = await countVideoFramesFast(ff, part);
        if (c == null || c <= 0) throw StateError('分段帧数统计失败');
        counts.add(c);
      }
      final offsets = <int>[];
      var grandTotal = 0;
      for (final c in counts) {
        offsets.add(grandTotal);
        grandTotal += c;
      }
      if (grandTotal != total) {
        // VFR 片源：时长×帧率的估算总帧数与实际不符，以实际为准刷新
        // 状态栏总量（单段路径在同样场景会按估算值截断/报错，分段
        // 路径按包拆分天然导出全部实际帧）。
        exportVideoInfo = ExportProgressInfo(
            width: w, height: h, fps: fps, totalFrames: grandTotal);
        exportInfoTick.value++;
      }
      final segPaths = [
        for (var s = 0; s < parts.length; s++)
          '${workDir.path}${Platform.pathSeparator}seg_$s.mp4'
      ];

      // 渲染锁：gpu.run 串行（实例状态保护），yuv 转换/回读在锁外
      // （无状态），GPU 队列保持有活。
      Future<void> lockTail = Future.value();
      Future<T> locked<T>(Future<T> Function() fn) {
        final c = Completer<T>();
        lockTail = lockTail.then((_) async {
          try {
            c.complete(await fn());
          } catch (e, st) {
            c.completeError(e, st);
          }
        });
        return c.future;
      }

      // 进度：各段完成帧数累加（与单段路径同一套状态栏/百分比口径）。
      var segDone = 0;
      void noteFrame() {
        segDone++;
        _advanceProgress(segDone / grandTotal);
        exportVideoInfo?.addFrame(DateTime.now().millisecondsSinceEpoch);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - _exportInfoLastNotifyMs >= 250) {
          _exportInfoLastNotifyMs = nowMs;
          exportInfoTick.value++;
        }
      }

      Future<void> runSeg(
          int s, String partPath, int offset, int count) async {
        // 段 s>0 的输入为 parts[0..s] 的 concat 列表 + 跳过前 offset
        // 帧：open-GOP 片源在切割点的引导 B 帧引用前一段的 GOP，单段
        // 文件独立解码会被丢弃（边界出空洞）；带上全部前缀后解码
        // 序列与源逐帧一致，passthrough 保证每包一帧。跳帧在 worker
        // 内完成（解码速度，不占渲染管线），代价远小于段并行收益。
        String concatList = '';
        if (s > 0) {
          concatList = '${workDir.path}${Platform.pathSeparator}ext_$s.txt';
          await File(concatList)
              .writeAsString(concatListContent(parts.sublist(0, s + 1)));
        }
        final stream = await VideoFrameStream.start(partPath, 0,
            ffmpegPath: ff,
            pixelFormat: gpuStreamFormat,
            hwaccel: hwaccel,
            maxFrames: count, // 送满即 EOF 收尾，段尾无背压竞赛
            skipFrames: offset,
            passthrough: true,
            concatListPath: concatList);
        streams.add(stream);
        final enc = await startMp4Encoder(
            ffmpegPath: ff,
            outputPath: segPaths[s],
            width: w,
            height: h,
            fps: fps,
            crf: crf,
            encoder: segEncoder,
            inputPixelFormat: gpuStreamFormat);
        encoders.add(enc);
        final errBuf = StringBuffer();
        final errDone = enc.stderr
            .transform(const SystemEncoding().decoder)
            .listen(errBuf.write)
            .asFuture<void>();

        final inFlight = <Future<Uint8List>>[];

        // 渲染 + yuv420p 出图 + 回读（取帧在主循环串行——
        // VideoFrameStream.next 不支持并发调用）。
        Future<Uint8List> render(Uint8List f, int i) async {
          ui.Image? img;
          await locked(() async {
            final r = await gpu.run(gpuChain, i,
                imageSources: {srcId: (f, w, h)},
                streamFormat: gpuStreamFormat,
                captureSamples: false);
            img = r.image;
          });
          stream.recycle(f);
          final img0 = img!;
          ui.Image? yuv;
          try {
            yuv = await gpu.rgba8ToYuv420p(img0, w, h);
          } finally {
            img0.dispose();
          }
          try {
            return await GpuPipeline.readbackBytes(yuv);
          } finally {
            yuv.dispose();
          }
        }

        Future<void> writeOldest() async {
          final bytes = await inFlight.removeAt(0);
          enc.stdin.add(bytes);
          await enc.stdin.flush();
          noteFrame();
        }

        for (var i = 0; i < count; i++) {
          if (token != _runToken) throw StateError('导出已取消');
          final f = await stream.next();
          if (f == null) {
            throw StateError('段 $s 帧流提前结束于第 $i 帧（共 $count 帧）');
          }
          inFlight.add(render(f, offset + i));
          if (inFlight.length > _kExportGpuSegDepth) {
            await writeOldest();
          }
        }
        while (inFlight.isNotEmpty) {
          await writeOldest();
        }
        await enc.stdin.close();
        final code = await enc.exitCode;
        await errDone;
        if (code != 0) {
          throw StateError('段 $s 编码失败 (exit $code):\n$errBuf');
        }
      }

      await Future.wait([
        for (var s = 0; s < parts.length; s++)
          runSeg(s, parts[s], offsets[s], counts[s]),
      ]);
      for (final stream in streams) {
        try {
          await stream
              .dispose()
              .timeout(const Duration(seconds: 5), onTimeout: () {});
        } catch (_) {}
      }

      // concat demuxer 无损拼接（各段编码器/参数一致，h264 裸流可直拼）。
      final listFile =
          File('${workDir.path}${Platform.pathSeparator}concat.txt');
      await listFile.writeAsString(concatListContent(segPaths));
      final r = await Process.run(ff, [
        '-y', '-f', 'concat', '-safe', '0', '-i', listFile.path,
        '-c', 'copy', outPath,
      ]);
      if (r.exitCode != 0) {
        throw StateError('分段拼接失败: ${r.stderr}');
      }

      // 产物校验：帧数（免解码数包）与时长远不符则判失败（调用方回退）。
      if (!await validateConcatOutput(ff, outPath, grandTotal, fps)) {
        final f = File(outPath);
        if (f.existsSync()) await f.delete();
        throw StateError('分段拼接产物校验失败（帧数/时长不符）');
      }
      await cleanup();
      return (segEncoder, parts.length);
    } catch (_) {
      await cleanup();
      rethrow;
    }
  }

  /// 取消正在进行的导出/播放。
  void cancelProcessing() {
    if (isProcessing) {
      _runToken++;
      isProcessing = false;
      // 同步复位播放态：播放循环 finally 只在 token 未失配时才清
      // isPlaying，这里 bump token 后必须由取消方复位，否则预览节点的
      // 播放控制条仍显示播放中（与右上角停止按钮状态脱节）。
      isPlaying = false;
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
    graph.groups
      ..clear()
      ..addAll(imported.groups);
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
    _minmaxHold.clear(); // 保持值属于旧图（节点 id 可能撞名）
    _pyiqaDistTokens.clear(); // FID/KID 样本复位标记同理
    _deepIqaDist.clear(); // FID/KID 进程内累计样本同理
    for (final w in _kidWorkers.values) {
      w.dispose();
    }
    _kidWorkers.clear(); // KID 常驻出分 isolate 同理
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
    // 进程内深度评价的共享 NN isolate 池（若曾启动）随状态销毁。
    _nnPool?.dispose();
    _nnPool = null;
    // KID 节点的常驻出分 isolate（若曾启动）随状态销毁。
    for (final w in _kidWorkers.values) {
      w.dispose();
    }
    _kidWorkers.clear();
    // VGG16 / RN50 / InceptionV3 GPU 纹理驻留链（若曾创建）随状态销毁。
    _vggGpu?.dispose();
    _vggGpu = null;
    _vggGpuStart = null;
    _rn50Gpu?.dispose();
    _rn50Gpu = null;
    _rn50GpuStart = null;
    _inceptionGpu?.dispose();
    _inceptionGpu = null;
    _inceptionGpuStart = null;
    _gpuNnBackend?.dispose();
    _gpuNnBackend = null;
    _gpuNnBackendStart = null;
    // 深度评价的 Python 桥接进程（若曾启动）随状态销毁。
    unawaited(PyIqaWorker.disposeAll());
    super.dispose();
  }
}
