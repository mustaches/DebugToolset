/// ISP Studio「电路图」标签页：两种视图——
/// - **RTL 网表**（默认）：yosys 只做 `Verilog → 层级网表 JSON` 提取，布局与绘制
///   由应用自己完成（`netlist_diagram.dart` + `codegen/netlist_model.dart`）
///   ——不再使用 netlistsvg/ELK/SVG：无样式块兼容问题、无超大画布长条、
///   悬停高亮与点击天然可用、导出 SVG/PNG 与页内所见一致。顶层为端口 +
///   子模块实例，点实例「＋」下钻其内部网表，点逻辑单元跳其源码信号。
///
/// 从 IP 标签页工具栏「电路图浏览」打开（key 前缀 `sch:`）。工具链缺失
/// （yosys）时 RTL 视图显示提示。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../codegen/group_ip_export.dart';
import '../codegen/ip_target.dart';
import '../codegen/netlist_model.dart';
import '../codegen/netlist_routing_metrics.dart';
import '../codegen/netlist_svg.dart';
import '../codegen/yosys_schematic.dart';
import '../models/isp_graph.dart';
import 'ip_block_diagram.dart' show SchPalette, schFitView;
import 'netlist_diagram.dart';
import 'tab_toolbar.dart';

/// 编组的电路图浏览标签页（作为编辑器标签页嵌入主视图）。
class SchematicTab extends StatefulWidget {
  final String groupId;

  /// FPGA 厂商目标（决定电路图顶层封装的选择，见 schematicTopModule）。
  final IpVendor vendor;

  /// 网表提取器注入点（测试替换为假实现；缺省 extractSchematicNetlist）。
  final Future<SchNetlistResult> Function(
    Map<String, String> files, {
    required String topName,
    void Function(String chunk)? onOutput,
  })?
  renderer;

  /// IP 文件生成器注入点（测试替换；缺省 buildGroupIpFiles）。
  final Future<Map<String, String>> Function(
    IspGraph graph,
    IspNodeGroup group,
    IpGenOptions options,
  )?
  filesBuilder;

  const SchematicTab({
    super.key,
    required this.groupId,
    this.vendor = IpVendor.generic,
    this.renderer,
    this.filesBuilder,
  });

  @override
  State<SchematicTab> createState() => _SchematicTabState();
}

/// 一次手动编辑前的快照（块几何 + 布线），用于事务回滚/撤销。
class _NlEditSnapshot {
  final Map<NlBlock, Offset> origins;
  final Map<NlBlock, Offset> boxOrigins;
  final Map<NlBlock, List<Offset>> pinPos;
  final Map<NlBlock, List<Offset>> pinEdge;
  final Map<NlBlock, int> columns;
  final Map<NlBlock, bool> flips;
  final Map<NlBlock, List<String>?> inOrders;
  final Map<NlBlock, List<String>?> outOrders;
  final Map<NlBlock, List<String>?> topOrders;
  final Map<NlBlock, List<String>?> bottomOrders;
  final Map<NlPin, Offset> portPos;
  final Map<NlPin, Offset> portEdge;
  final NlAutoRouteResult? routes;

  const _NlEditSnapshot({
    required this.origins,
    required this.boxOrigins,
    required this.pinPos,
    required this.pinEdge,
    required this.columns,
    required this.flips,
    required this.inOrders,
    required this.outOrders,
    required this.topOrders,
    required this.bottomOrders,
    required this.portPos,
    required this.portEdge,
    required this.routes,
  });
}

class _SchematicTabState extends State<SchematicTab> {
  /// 提取结果与当前展示的模块（层级下钻路径，首项为顶层）。
  YosysNetlist? _netlist;
  final List<String> _path = [];

  /// 当前模块的电路图模型（缓存，避免每帧重排）。
  NetlistDiagramModel? _nlModel;

  /// 直线连线的超边拓扑：false=星形（到质心），true=团（全对相连）。
  /// RTL 视图默认使用团拓扑；在「布局布线设置」对话框中切换。
  /// 直线预览拓扑：默认星形（扇出只画一份主干 + 分支，交叉/长度显著低于团）。
  bool _cliqueTopology = false;

  /// 布局优化选项：允许逐个元件尝试上下镜像（不强制全部镜像）。
  bool _mirrorComponents = true;

  /// 布局优化选项：允许交换同一多输入符号的输入引脚槽位。
  bool _swapPins = true;

  /// 布局优化选项：允许全局重排——元件不限于原来的列，可重排到任意列。
  bool _allowGlobalReorder = false;

  /// 布局优化选项：允许列内非等间距——相邻元件间距可在 2~20 Grid 间调整。
  bool _variableRowGap = false;

  /// 布线优化选项：上下镜像元件（输入/输出槽位反转、顶↔底针脚互换）。
  bool _routeOptMirrorV = true;

  /// 布线优化选项：左右镜像元件（预留：符号水平翻转暂未支持，设置中禁用）。
  final bool _routeOptMirrorH = false;

  /// 布线优化选项：交换左侧（输入）引脚槽位。
  bool _routeOptSwapL = true;

  /// 布线优化选项：交换右侧（输出）引脚槽位。
  bool _routeOptSwapR = true;

  /// 布线优化选项：交换上方引脚槽位。
  bool _routeOptSwapT = true;

  /// 布线优化选项：交换下方引脚槽位。
  bool _routeOptSwapB = true;

  /// 是否叠加走线密度热力图（仅 RTL 视图）。
  bool _heatmap = false;

  /// 列分配算法：true=分层布局（默认），false=经典 BFS 压缩（回退）。
  bool _layeredLayout = false;

  /// 是否显示走线诊断叠加层与指标面板（仅 RTL 视图）。
  bool _diagnostics = false;

  /// 诊断缓存：按模型 / 拓扑 / 布线结果对象失效。
  NlRoutingDiagnostics? _diagCache;
  NetlistDiagramModel? _diagModel;
  NlNetTopology? _diagTopology;
  Object? _diagRoutes;

  /// 自动布线结果（wire → 本层正交线段）；null = 直线预览。
  NlAutoRouteResult? _autoRoutes;
  bool _autoRouting = false;
  bool _routingOptimizing = false;

  /// 当前布局优化结果（随模型重建复用；切换模块/重新提取时清空）。
  Map<int, List<String>> _layoutRowOrders = const {};
  Set<String> _layoutMirroredBlocks = const {};
  Map<String, List<String>> _layoutPinOrders = const {};

  /// 布局优化（只重排行序、按总直线长度择优）的进度与浮层状态。
  bool _layoutOptimizing = false;
  bool _layoutOptPanelVisible = false;

  /// 手动编辑模式（拖动元件，松手事务式重布）。
  bool _editMode = false;
  bool _manualOptPanelVisible = false;
  /// 进入编辑模式时若还是直线预览，整个编辑过程保持直线，不自动切布线。
  bool _editStraightPreview = false;
  double _editStartLength = 0;
  final List<Map<String, dynamic>> _teachRules = [];
  final List<_NlEditSnapshot> _editUndo = [];
  final List<String> _editLog = [];
  _NlEditSnapshot? _dragSnapshot;

  /// 右侧信息面板统一宽度与间距（布局/布线/诊断三窗等宽）。
  static const double _nlPanelWidth = 236;
  static const double _nlPanelGap = 8;
  int _layoutOptModules = 0;
  int _layoutOptEndpoints = 0;
  int _layoutOptInputs = 0;
  int _layoutOptOutputs = 0;
  int _layoutOptInouts = 0;
  double _layoutOptInitial = 0;
  double _layoutOptLength = 0;
  int _layoutOptSession = 0;

  /// 布局优化用时（运行中随进度回调刷新，完成后冻结）。
  final Stopwatch _layoutOptWatch = Stopwatch();
  Duration _layoutOptElapsed = Duration.zero;

  /// 布线优化（「自动布线」第二阶段）的浮层状态。
  bool _routingOptPanelVisible = false;
  int _routingOptCrossings = 0;
  int _routingOptBends = 0;
  double _routingOptLength = 0;
  String _routingOptStage = '';

  /// 布线优化会话号：恢复直线预览时递增，在途优化据此丢弃过期结果。
  int _routingOptSession = 0;

  /// 布线优化用时（同布局优化口径）。
  final Stopwatch _routingOptWatch = Stopwatch();
  Duration _routingOptElapsed = Duration.zero;

  /// 用时的 MM:SS 显示。
  static String fmtElapsed(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// **原位展开**的实例单元名集合（＋/－ 切换；切模块时清空）。
  final Set<String> _expanded = {};

  final StringBuffer _log = StringBuffer();
  bool _logVisible = false;
  String? _error;
  bool _running = false;

  /// 配色：false = 暗色（默认，与应用主题一致），true = Vivado 浅色。
  bool _light = false;

  /// RTL 网表缩放控制器（工具栏缩放按钮共用）。
  final TransformationController _nlCtrl = TransformationController();
  Size _nlViewport = Size.zero;

  /// 提取成功时的编组指纹（过期提示用，见 [_groupFingerprint]）。
  String? _renderedFingerprint;

  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_extract());
    unawaited(_loadTeaching());
  }

  @override
  void dispose() {
    _nlCtrl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  /// 编组指纹（过期提示用）：成员 id+typeId+排序参数 + 厂商 + 选项对象
  /// 同一性（选项对话框重新保存会换实例）。
  String _groupFingerprint(IspStudioState state, IspNodeGroup group) {
    final sb = StringBuffer()
      ..write(group.name)
      ..write('|')
      ..write(widget.vendor.name)
      ..write('|')
      ..write(identityHashCode(sessionIpGenOptions[widget.groupId]));
    final ids = group.nodeIds.toList()..sort();
    for (final id in ids) {
      final n = state.graph.nodes[id];
      sb
        ..write('|')
        ..write(id)
        ..write(':')
        ..write(n?.typeId);
      final pv = n?.paramValues;
      if (pv != null) {
        final keys = pv.keys.toList()..sort();
        for (final k in keys) {
          sb
            ..write(',')
            ..write(k)
            ..write('=')
            ..write(pv[k]);
        }
      }
    }
    return sb.toString();
  }

  // ---- 缩放 ----

  TransformationController get _activeCtrl => _nlCtrl;

  Size get _activeViewport => _nlViewport;

  void _zoomStep(double factor) {
    final ctrl = _activeCtrl;
    final vp = _activeViewport;
    final m = ctrl.value;
    final cur = m.getMaxScaleOnAxis();
    final next = (cur * factor).clamp(0.05, 8.0);
    final k = next / cur;
    final cx = vp.width / 2, cy = vp.height / 2;
    final t = m.getTranslation();
    ctrl.value = Matrix4.identity()
      ..translateByDouble(cx - k * (cx - t.x), cy - k * (cy - t.y), 0, 1)
      // z 必须同步缩放：getMaxScaleOnAxis 取三轴最大值，z=1 会把 <1 的
      // 缩放读成 1.0（连续缩小时缩放纵 0.8 锁死、只剩平移漂移的教训）。
      ..scaleByDouble(next, next, next, 1);
  }

  void _zoomFit() {
    final vp = _activeViewport;
    if (vp.isEmpty) return;
    final content = _nlModel?.canvasSize;
    if (content == null || content.isEmpty) return;
    schFitView(_activeCtrl, vp, content);
  }

  // ---- 提取（yosys → 层级网表 JSON → Dart 模型）----

  /// 重新提取网表。[module] 指定提取后要展示的模块（下钻目标），null 回顶层；
  /// [drillCore] 提取成功后自动下钻顶层的第一个子模块实例（框图点块入口）。
  Future<void> _extract({String? module, bool drillCore = false}) async {
    _invalidateLayoutOptimization();
    _clearLayoutPlans();
    final state = context.read<IspStudioState>();
    final group = state.graph.groups
        .where((g) => g.id == widget.groupId)
        .firstOrNull;
    if (group == null) return;
    setState(() {
      _running = true;
      _error = null;
    });
    _log.clear();
    try {
      final options =
          sessionIpGenOptions[widget.groupId] ??
          IpGenOptions(vendor: widget.vendor);
      final files = await (widget.filesBuilder ?? _defaultFiles)(
        state.graph,
        group,
        options,
      );
      final top = schematicTopModule(files, vendorHint: widget.vendor.name);
      final result = await (widget.renderer ?? extractSchematicNetlist)(
        files,
        topName: top,
        onOutput: (chunk) {
          _log.write(chunk);
          if (mounted) setState(() {});
        },
      );
      if (!mounted) return;
      if (!result.success || result.netlist == null) {
        setState(() {
          _running = false;
          _error = result.missingTool == 'yosys'
              ? '未检测到 yosys（tools/yosys 或 PATH）——RTL 网表视图需要它'
              : '电路图提取失败：\n${result.log.split('\n').lastWhere((l) => l.isNotEmpty, orElse: () => '未知错误')}';
          _logVisible = true;
        });
        return;
      }
      final nl = result.netlist!;
      final target = module ?? result.topModule ?? top;
      final mod = nl.module(target) ?? nl.module(result.topModule ?? top)!;
      setState(() {
        _running = false;
        _netlist = nl;
        _path
          ..clear()
          ..add(result.topModule ?? top);
        if (mod.name != _path.first) _path.add(mod.name);
        _expanded.clear();
        _nlModel = _buildModel(mod);
        _renderedFingerprint = _groupFingerprint(state, group);
      });
      // 框图点块入口：提取完成后自动下钻顶层的第一个子模块实例。
      if (drillCore) {
        final inst = mod.instances.firstOrNull;
        if (inst?.moduleRef != null) _showModule(inst!.moduleRef!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '电路图提取异常：$e';
        _logVisible = true;
      });
    }
  }

  /// 构建当前模块的 RTL 图模型：单次确定性布局 + 直线（团/星形）渲染。
  NetlistDiagramModel _buildModel(NetlistModule mod) {
    final nl = _netlist;
    final model = buildNetlistDiagramModel(
      mod,
      expanded: _expanded,
      // 实例类型可能是参数化名（`$paramod$hash\core`），也可能是普通模块名
      // ——两条路都要能解析出子模块。
      resolve: nl == null
          ? null
          : (type) => nl.resolveInstance(type) ?? nl.module(type),
      rowOrders: _layoutRowOrders,
      mirroredBlocks: _layoutMirroredBlocks,
      pinOrders: _layoutPinOrders,
      layout: _layeredLayout && _path.length <= 1
          ? NlLayoutAlgorithm.layered
          : NlLayoutAlgorithm.compact,
    );
    _nlModel = model;
    return model;
  }

  /// 切换某实例块的**原位展开**（＋/－），就地重算模型。
  void _toggleExpand(NetlistCell cell) {
    _invalidateLayoutOptimization();
    setState(() {
      if (!_expanded.remove(cell.name)) _expanded.add(cell.name);
      final cur = _currentModule;
      final mod = _netlist?.module(cur);
      if (mod != null) _nlModel = _buildModel(mod);
    });
  }

  /// 任何导航/提取/展开都会使正在跑的布局优化结果失效。
  void _invalidateLayoutOptimization() {
    _layoutOptSession++;
    _layoutOptimizing = false;
    _layoutOptPanelVisible = false;
  }

  /// 切换模块/重新提取时清空上一套布局优化结果。
  void _clearLayoutPlans() {
    _layoutRowOrders = const {};
    _layoutMirroredBlocks = const {};
    _layoutPinOrders = const {};
    _editLog.clear();
  }

  _NlEditSnapshot _captureNlEdit() {
    final origins = <NlBlock, Offset>{};
    final boxOrigins = <NlBlock, Offset>{};
    final pinPos = <NlBlock, List<Offset>>{};
    final pinEdge = <NlBlock, List<Offset>>{};
    final columns = <NlBlock, int>{};
    final flips = <NlBlock, bool>{};
    final inOrders = <NlBlock, List<String>?>{};
    final outOrders = <NlBlock, List<String>?>{};
    final topOrders = <NlBlock, List<String>?>{};
    final bottomOrders = <NlBlock, List<String>?>{};
    final portPos = <NlPin, Offset>{};
    final portEdge = <NlPin, Offset>{};
    for (final level in _nlModel?.flattened() ?? const <NlLevel>[]) {
      for (final p in level.ports) {
        portPos[p] = p.pos;
        portEdge[p] = p.edge;
      }
    }
    for (final b in _nlModel?.blocks ?? const <NlBlock>[]) {
      origins[b] = b.origin;
      boxOrigins[b] = b.boxOrigin;
      final pins = [...b.ins, ...b.outs];
      pinPos[b] = [for (final p in pins) p.pos];
      pinEdge[b] = [for (final p in pins) p.edge];
      columns[b] = b.column;
      flips[b] = b.pinFlip;
      inOrders[b] = b.inPinOrder == null ? null : [...b.inPinOrder!];
      outOrders[b] = b.outPinOrder == null ? null : [...b.outPinOrder!];
      topOrders[b] = b.topPinOrder == null ? null : [...b.topPinOrder!];
      bottomOrders[b] = b.bottomPinOrder == null
          ? null
          : [...b.bottomPinOrder!];
    }
    return _NlEditSnapshot(
      origins: origins,
      boxOrigins: boxOrigins,
      pinPos: pinPos,
      pinEdge: pinEdge,
      columns: columns,
      flips: flips,
      inOrders: inOrders,
      outOrders: outOrders,
      topOrders: topOrders,
      bottomOrders: bottomOrders,
      portPos: portPos,
      portEdge: portEdge,
      routes: _autoRoutes,
    );
  }

  void _restoreNlEdit(_NlEditSnapshot snap) {
    for (final level in _nlModel?.flattened() ?? const <NlLevel>[]) {
      for (final p in level.ports) {
        p.pos = snap.portPos[p] ?? p.pos;
        p.edge = snap.portEdge[p] ?? p.edge;
      }
    }
    for (final b in _nlModel?.blocks ?? const <NlBlock>[]) {
      b.origin = snap.origins[b] ?? b.origin;
      b.boxOrigin = snap.boxOrigins[b] ?? b.boxOrigin;
      b.column = snap.columns[b] ?? b.column;
      b.pinFlip = snap.flips[b] ?? b.pinFlip;
      b.inPinOrder = snap.inOrders[b];
      b.outPinOrder = snap.outOrders[b];
      b.topPinOrder = snap.topOrders[b];
      b.bottomPinOrder = snap.bottomOrders[b];
      final pins = [...b.ins, ...b.outs];
      final pos = snap.pinPos[b];
      final edge = snap.pinEdge[b];
      if (pos != null && edge != null && pos.length == pins.length) {
        for (var i = 0; i < pins.length; i++) {
          pins[i].pos = pos[i];
          pins[i].edge = edge[i];
        }
      }
    }
  }

  void _onNlPinDragStart(NlBlock block, NlPin pin) {
    if (!_editMode) return;
    _dragSnapshot = _captureNlEdit();
  }

  void _onNlPinDragUpdate(NlBlock block, NlPin pin) {
    if (!_editMode || _nlModel == null || _autoRoutes == null) return;
    final levels = _nlModel!.flattened();
    NlWire? wire;
    for (final level in levels) {
      for (final w in level.wires) {
        if (identical(w.from, pin) ||
            w.loads.any((l) => identical(l, pin))) {
          wire = w;
          break;
        }
      }
      if (wire != null) break;
    }
    if (wire == null) return;
    final next = wire.loads.length == 1
        ? nlRerouteSingleWire(levels, _nlModel!.canvasSize, _autoRoutes!, wire)
        : nlRerouteTreeWire(levels, _nlModel!.canvasSize, _autoRoutes!, wire);
    if (next != null) setState(() => _autoRoutes = next);
  }

  void _onNlPinDragEnd(NlBlock block, NlPin pin, double dy) {
    final snap = _dragSnapshot;
    _dragSnapshot = null;
    if (!_editMode || snap == null || _nlModel == null) return;
    if (dy.abs() < 1) return;
    String sideOf(NlPin p) {
      final dx = p.pos.dx - p.edge.dx;
      final dy2 = p.pos.dy - p.edge.dy;
      if (dx.abs() >= dy2.abs()) return dx < 0 ? 'left' : 'right';
      return dy2 < 0 ? 'top' : 'bottom';
    }

    final side = sideOf(pin);
    final sidePins = [
      for (final p in [...block.ins, ...block.outs])
        if (sideOf(p) == side) p,
    ]..sort((a, b) => a.pos.dy.compareTo(b.pos.dy));
    if (sidePins.length < 2) {
      nlLayoutBlockPins(block);
      setState(() {});
      return;
    }
    final target = pin.pos.dy;
    final others = [
      for (final p in sidePins)
        if (!identical(p, pin)) p,
    ];
    var insertAt = 0;
    for (final p in others) {
      if (p.pos.dy <= target) insertAt++;
    }
    final order = [...others]..insert(insertAt, pin);
    final names = [for (final p in order) p.display];
    switch (side) {
      case 'left':
        block.inPinOrder = names;
      case 'right':
        block.outPinOrder = names;
      case 'top':
        block.topPinOrder = names;
      default:
        block.bottomPinOrder = names;
    }
    nlLayoutBlockPins(block);
    if (_editStraightPreview) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add('调整引脚顺序 ${block.title}');
      });
      return;
    }
    if (_autoRoutes == null) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add('调整引脚顺序 ${block.title}');
      });
      return;
    }
    final levels = _nlModel!.flattened();
    final next = routeNetlistWires(levels, _nlModel!.canvasSize);
    // 引脚换位后即使局部拥挤也保留新顺序（走线必须跟随引脚），
    // 用户可用撤销回退；不再让引脚弹回原位。
    setState(() {
      _autoRoutes = next;
      _editUndo.add(snap);
      _editLog.add('调整引脚顺序 ${block.title}');
    });
  }

  void _onNlMirrorBlock(NlBlock block) {
    if (!_editMode || _nlModel == null) return;
    final snap = _captureNlEdit();
    block.pinFlip = !block.pinFlip;
    nlLayoutBlockPins(block);
    if (_editStraightPreview) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add('镜像 ${block.title}');
      });
      return;
    }
    if (_autoRoutes == null) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add('镜像 ${block.title}');
      });
      return;
    }
    final levels = _nlModel!.flattened();
    final next = routeNetlistWires(levels, _nlModel!.canvasSize);
    if (nlRouteIsClean(next)) {
      setState(() {
        _autoRoutes = next;
        _editUndo.add(snap);
        _editLog.add('镜像 ${block.title}');
      });
    } else {
      _restoreNlEdit(snap);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('镜像后走线无法避让，已回退')),
        );
      }
    }
  }

  void _onNlBlockDragStart(NlBlock block) {
    if (!_editMode) return;
    _dragSnapshot = _captureNlEdit();
  }

  void _onNlSegmentDragStart(NlWire wire, int index) {
    if (!_editMode) return;
    _dragSnapshot = _captureNlEdit();
  }

  bool _nlSegmentHitsBlock(
    List<NlLevel> levels,
    (Offset, Offset) seg,
  ) {
    final a = seg.$1;
    final b = seg.$2;
    final horizontal = (a.dy - b.dy).abs() < 0.01;
    for (final level in levels) {
      final off = level.offset;
      for (final block in level.blocks) {
        if (block.isIo || block.boxSize.width <= 0) continue;
        final rect = Rect.fromLTWH(
          block.boxOrigin.dx + off.dx,
          block.boxOrigin.dy + off.dy,
          block.boxSize.width,
          block.boxSize.height,
        ).inflate(6);
        if (horizontal) {
          if (a.dy >= rect.top &&
              a.dy <= rect.bottom &&
              math.max(math.min(a.dx, b.dx), rect.left) <
                  math.min(math.max(a.dx, b.dx), rect.right)) {
            return true;
          }
        } else if (a.dx >= rect.left &&
            a.dx <= rect.right &&
            math.max(math.min(a.dy, b.dy), rect.top) <
                math.min(math.max(a.dy, b.dy), rect.bottom)) {
          return true;
        }
      }
    }
    return false;
  }

  void _onNlSegmentDragUpdate(NlWire wire, int index, double du) {
    if (!_editMode || _nlModel == null || _autoRoutes == null) return;
    final levels = _nlModel!.flattened();
    final segs = _autoRoutes!.segments[wire];
    if (segs == null || index < 0 || index >= segs.length) return;
    final (a, b) = segs[index];
    final horizontal = (a.dy - b.dy).abs() < 0.01;
    final newA = horizontal ? Offset(a.dx, a.dy + du) : Offset(a.dx + du, a.dy);
    final newB = horizontal ? Offset(b.dx, b.dy + du) : Offset(b.dx + du, b.dy);
    final connectors = <(Offset, Offset)>[];
    final targetVertical = (a.dx - b.dx).abs() < 0.01;
    final nextSegs = <(Offset, Offset)>[];
    for (var i = 0; i < segs.length; i++) {
      if (i == index) {
        nextSegs.add((newA, newB));
        continue;
      }
      final p = segs[i].$1;
      final q = segs[i].$2;
      final otherVertical = (p.dx - q.dx).abs() < 0.01;
      var np = p;
      var nq = q;
      if ((p - a).distance < 0.01) {
        if (otherVertical == targetVertical) {
          connectors.add((a, newA));
        } else {
          np = newA;
        }
      } else if ((p - b).distance < 0.01) {
        if (otherVertical == targetVertical) {
          connectors.add((b, newB));
        } else {
          np = newB;
        }
      }
      if ((q - a).distance < 0.01) {
        if (otherVertical == targetVertical) {
          connectors.add((a, newA));
        } else {
          nq = newA;
        }
      } else if ((q - b).distance < 0.01) {
        if (otherVertical == targetVertical) {
          connectors.add((b, newB));
        } else {
          nq = newB;
        }
      }
      nextSegs.add((np, nq));
    }
    nextSegs.addAll(connectors);
    // 不让线段/连接段穿过元件；越界时保持上一帧合法位置。
    if (nextSegs.any((s) => _nlSegmentHitsBlock(levels, s))) return;
    final junctions = <NlWire, List<Offset>>{
      ..._autoRoutes!.junctions,
    };
    final ownJunctions = nlTreeJunctions(nextSegs);
    if (ownJunctions.isEmpty) {
      junctions.remove(wire);
    } else {
      junctions[wire] = ownJunctions;
    }
    var result = NlAutoRouteResult(
      segments: {..._autoRoutes!.segments, wire: nextSegs},
      junctions: junctions,
      fallbackCount: _autoRoutes!.fallbackCount,
    );
    // 被推开的新线段压到的其它网，逐条让开。
    final changed = <(Offset, Offset)>[(newA, newB)];
    final colliding = <NlWire>[];
    for (final level in levels) {
      for (final w in level.wires) {
        if (identical(w, wire)) continue;
        if (_nlSegListsOverlap(changed, result.segments[w] ?? const [])) {
          colliding.add(w);
        }
      }
    }
    for (final w in colliding) {
      final fixed = w.loads.length == 1
          ? nlRerouteSingleWire(levels, _nlModel!.canvasSize, result, w)
          : nlRerouteTreeWire(levels, _nlModel!.canvasSize, result, w);
      if (fixed != null) result = fixed;
    }
    setState(() => _autoRoutes = result);
  }

  NlAutoRouteResult? _nlRepairOverlaps(
    List<NlLevel> levels,
    NlAutoRouteResult result,
  ) {
    var current = result;
    for (var pass = 0; pass < 4; pass++) {
      NlWire? dirty;
      final entries = current.segments.entries.toList();
      for (var i = 0; i < entries.length && dirty == null; i++) {
        for (var j = i + 1; j < entries.length; j++) {
          if (_nlSegListsOverlap(entries[i].value, entries[j].value)) {
            dirty = entries[j].key;
            break;
          }
        }
      }
      if (dirty == null) return current;
      final fixed = dirty.loads.length == 1
          ? nlRerouteSingleWire(levels, _nlModel!.canvasSize, current, dirty)
          : nlRerouteTreeWire(levels, _nlModel!.canvasSize, current, dirty);
      if (fixed == null) return null;
      current = fixed;
    }
    return null;
  }

  void _onNlSegmentDragEnd(NlWire wire, int index) {
    if (!_editMode) return;
    final snap = _dragSnapshot;
    _dragSnapshot = null;
    if (snap == null || _autoRoutes == null) return;
    final levels = _nlModel!.flattened();
    if ((_autoRoutes!.segments[wire] ?? const []).any(
      (s) => _nlSegmentHitsBlock(levels, s),
    )) {
      _restoreNlEdit(snap);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('线段不能穿过元件，已回退')),
        );
      }
      return;
    }
    final repaired = _nlRepairOverlaps(levels, _autoRoutes!);
    if (repaired == null) {
      _restoreNlEdit(snap);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('线段调整会产生走线冲突，已回退')),
        );
      }
      return;
    }
    setState(() {
      _autoRoutes = repaired;
      _editUndo.add(snap);
      _editLog.add('调整线段 ${wire.label}');
    });
  }

  void _onNlPortDragStart(NlPin pin) {
    if (!_editMode) return;
    _dragSnapshot = _captureNlEdit();
  }

  bool _nlSegListsOverlap(
    List<(Offset, Offset)> a,
    List<(Offset, Offset)> b,
  ) {
    for (final s in a) {
      final hA = (s.$1.dy - s.$2.dy).abs() < 0.01;
      for (final t in b) {
        final hB = (t.$1.dy - t.$2.dy).abs() < 0.01;
        if (hA != hB) continue;
        if (hA && (s.$1.dy - t.$1.dy).abs() < 0.01) {
          final a0 = math.min(s.$1.dx, s.$2.dx);
          final a1 = math.max(s.$1.dx, s.$2.dx);
          final b0 = math.min(t.$1.dx, t.$2.dx);
          final b1 = math.max(t.$1.dx, t.$2.dx);
          if (math.min(a1, b1) - math.max(a0, b0) > 0.01) return true;
        } else if (!hA && (s.$1.dx - t.$1.dx).abs() < 0.01) {
          final a0 = math.min(s.$1.dy, s.$2.dy);
          final a1 = math.max(s.$1.dy, s.$2.dy);
          final b0 = math.min(t.$1.dy, t.$2.dy);
          final b1 = math.max(t.$1.dy, t.$2.dy);
          if (math.min(a1, b1) - math.max(a0, b0) > 0.01) return true;
        }
      }
    }
    return false;
  }

  void _onNlPortDragUpdate(NlPin pin, double dy) {
    if (!_editMode || _nlModel == null || _autoRoutes == null) return;
    final levels = _nlModel!.flattened();
    NlWire? wire;
    for (final level in levels) {
      for (final w in level.wires) {
        if (identical(w.from, pin) ||
            w.loads.any((l) => identical(l, pin))) {
          wire = w;
          break;
        }
      }
      if (wire != null) break;
    }
    if (wire == null) return;
    final oldPos = pin.pos - Offset(0, dy);
    var next = nlReroutePortBranch(
      levels,
      _nlModel!.canvasSize,
      _autoRoutes!,
      wire,
      oldPos,
      pin.pos,
    );
    next ??= wire.loads.length == 1
        ? nlRerouteSingleWire(levels, _nlModel!.canvasSize, _autoRoutes!, wire)
        : nlRerouteTreeWire(levels, _nlModel!.canvasSize, _autoRoutes!, wire);
    if (next != null) {
      var result = next;
      // 端口新短桩可能压到别的网：把这些被压到的网也局部让开。
      final changed =
          result.segments[wire] ?? const <(Offset, Offset)>[];
      final colliding = <NlWire>[];
      for (final level in levels) {
        for (final w in level.wires) {
          if (identical(w, wire)) continue;
          if (_nlSegListsOverlap(
            changed,
            result.segments[w] ?? const [],
          )) {
            colliding.add(w);
          }
        }
      }
      for (final w in colliding) {
        final fixed = w.loads.length == 1
            ? nlRerouteSingleWire(
                levels,
                _nlModel!.canvasSize,
                result,
                w,
              )
            : nlRerouteTreeWire(
                levels,
                _nlModel!.canvasSize,
                result,
                w,
              );
        if (fixed != null) result = fixed;
      }
      // 拖动过程只做视觉预览：允许暂时压线，松手时再统一校验/回退。
      setState(() => _autoRoutes = result);
    }
  }

  Future<void> _onNlPortDragEnd(NlPin pin, double dy) async {
    final snap = _dragSnapshot;
    _dragSnapshot = null;
    if (!_editMode || snap == null || _nlModel == null) return;
    final snapped = (dy / nlLayoutGrid).round() * nlLayoutGrid;
    nlShiftPin(pin, snapped - dy);
    if (snapped.abs() < nlLayoutGrid) {
      setState(() {});
      return;
    }
    // 端口按槽位重排：拖过相邻端口时，交换槽位（而不是拒绝），
    // 这样交叉线路可以通过调换 I/O 顺序来疏解。
    final levels = _nlModel!.flattened();
    NlLevel? level;
    for (final lv in levels) {
      if (lv.ports.any((p) => identical(p, pin))) {
        level = lv;
        break;
      }
    }
    if (level == null) {
      _restoreNlEdit(snap);
      setState(() {});
      return;
    }
    // 端口保持拖动后的 y；只把与上一个端口重叠的端口向下推，
    // 不再吸回原槽位。
    final group = level.ports
        .where((p) => p.isPortInput == pin.isPortInput)
        .toList()
      ..sort((a, b) => a.pos.dy.compareTo(b.pos.dy));
    final moved = <NlPin>{};
    double? prevY;
    for (final p in group) {
      var y = p.pos.dy;
      if (prevY != null && y < prevY + nlLayoutGrid) {
        y = prevY + nlLayoutGrid;
      }
      if ((p.pos.dy - y).abs() > 0.01) {
        p.pos = Offset(p.pos.dx, y);
        p.edge = Offset(p.edge.dx, y);
        moved.add(p);
      }
      prevY = y;
    }
    if (_editStraightPreview) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add('重排端口 ${pin.display}');
      });
      return;
    }
    final current = _autoRoutes;
    final dirty = <NlWire>{};
    for (final lv in levels) {
      for (final w in lv.wires) {
        if (moved.any(
          (p) => identical(w.from, p) || w.loads.any((l) => identical(l, p)),
        )) {
          dirty.add(w);
        }
      }
    }
    if (current == null || dirty.isEmpty) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add('重排端口 ${pin.display}');
      });
      return;
    }
    // 端口移动会改变端口短桩所在的水平车道，可能压到邻近网；
    // 松手时整图重布一次，避免只重布本网留下交叉。
    final next = routeNetlistWires(levels, _nlModel!.canvasSize);
    if (nlRouteIsClean(next)) {
      setState(() {
        _autoRoutes = next;
        _editUndo.add(snap);
        _editLog.add('重排端口 ${pin.display}');
      });
    } else {
      _restoreNlEdit(snap);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('端口重排会产生走线冲突，已回退')),
        );
      }
    }
  }

  Future<void> _onNlBlockDragEnd(
    NlBlock block,
    double dx,
    double dy,
  ) async {
    final snap = _dragSnapshot;
    _dragSnapshot = null;
    if (!_editMode || snap == null || _nlModel == null) return;
    if (dx.abs() < nlLayoutGrid && dy.abs() < nlLayoutGrid) {
      setState(() {});
      return;
    }
    final levels = _nlModel!.flattened();
    final current = _autoRoutes;
    final level = levels.firstWhere(
      (lv) => lv.blocks.any((b) => identical(b, block)),
      orElse: () => levels.first,
    );
    // 跨列：只有被拖元件的**中心落进目标列的 x 范围**才换列；否则保持原列。
    final originalBox = snap.boxOrigins[block] ?? block.boxOrigin;
    final bounds = <int, List<double>>{};
    void addBound(int column, double left, double right) {
      final b = bounds[column];
      if (b == null) {
        bounds[column] = [left, right];
      } else {
        if (left < b[0]) b[0] = left;
        if (right > b[1]) b[1] = right;
      }
    }

    addBound(
      block.column,
      originalBox.dx,
      originalBox.dx + block.boxSize.width,
    );
    for (final other in level.blocks) {
      if (identical(other, block) || other.isIo || other.boxSize.width <= 0) {
        continue;
      }
      addBound(
        other.column,
        other.boxOrigin.dx,
        other.boxOrigin.dx + other.boxSize.width,
      );
    }
    final centerX = block.boxOrigin.dx + block.boxSize.width / 2;
    int? hitColumn;
    for (final e in bounds.entries) {
      if (centerX >= e.value[0] - 0.01 && centerX <= e.value[1] + 0.01) {
        hitColumn = e.key;
        break;
      }
    }
    var targetColumn = block.column;
    final horizontalIntent =
        dx.abs() >= nlLayoutGrid && dx.abs() >= dy.abs();
    if (!horizontalIntent) {
      // 竖向拖动时不允许因手指抖动而换列：x 回到拖动前，保持原列。
      final originalX = (snap.boxOrigins[block] ?? block.boxOrigin).dx;
      nlShiftBlockXY(block, originalX - block.boxOrigin.dx, 0);
    }
    if (horizontalIntent && hitColumn != null && hitColumn != block.column) {
      targetColumn = hitColumn;
      final centers = <double>[];
      final b = bounds[targetColumn]!;
      centers.add((b[0] + b[1]) / 2);
      for (final other in level.blocks) {
        if (other.isIo || other.column != targetColumn || identical(other, block)) {
          continue;
        }
        centers.add(other.boxOrigin.dx + other.boxSize.width / 2);
      }
      final targetCx = centers.reduce((a, b) => a + b) / centers.length;
      nlShiftBlockXY(
        block,
        targetCx - (block.boxOrigin.dx + block.boxSize.width / 2),
        0,
      );
      block.column = targetColumn;
    }
    // 目标列按“拖入位置”重排：其它元件依次让位，保持 7 Grid 间距。
    final targetBlocks = [
      for (final b in level.blocks)
        if (!b.isIo && b.boxSize.height > 0 && b.column == targetColumn) b,
    ]..sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
    // 目标列只解决“覆盖”：保留元件当前 y，只把与上方重叠的元件向下推，
    // 不再从列顶重新紧凑堆叠（否则下方元件一拖就被吸回原位）。
    final movedBlocks = <NlBlock>{};
    double? prevBottom;
    for (final b in targetBlocks) {
      var y = b.boxOrigin.dy;
      if (prevBottom != null) {
        final minY = prevBottom + nlLayoutGrid;
        if (y < minY - 0.01) {
          nlShiftBlock(b, minY - y);
          movedBlocks.add(b);
          y = minY;
        }
      }
      prevBottom = y + b.boxSize.height;
    }
    // 只禁止真正的元件覆盖（重排后仍相交才回退）。
    var overlaps = false;
    for (var i = 0; i < targetBlocks.length && !overlaps; i++) {
      final a = targetBlocks[i];
      final ra = Rect.fromLTWH(
        a.boxOrigin.dx,
        a.boxOrigin.dy,
        a.boxSize.width,
        a.boxSize.height,
      );
      for (var j = i + 1; j < targetBlocks.length; j++) {
        final b = targetBlocks[j];
        final rb = Rect.fromLTWH(
          b.boxOrigin.dx,
          b.boxOrigin.dy,
          b.boxSize.width,
          b.boxSize.height,
        );
        if (ra.overlaps(rb)) {
          overlaps = true;
          break;
        }
      }
    }
    if (overlaps) {
      _restoreNlEdit(snap);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('元件覆盖被禁止，已回退')),
        );
      }
      return;
    }
    if (_editStraightPreview) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add(
          '移动 ${block.title} (${dx.toStringAsFixed(0)},'
          '${dy.toStringAsFixed(0)})',
        );
      });
      return;
    }
    if (current == null) {
      setState(() {
        _editUndo.add(snap);
        _editLog.add(
          '移动 ${block.title} (${dx.toStringAsFixed(0)},'
          '${dy.toStringAsFixed(0)})',
        );
      });
      return;
    }
    final dirty = <NlWire>{};
    for (final level in levels) {
      if (!level.blocks.any((b) => identical(b, block))) continue;
      final rect = Rect.fromLTWH(
        block.boxOrigin.dx + level.offset.dx,
        block.boxOrigin.dy + level.offset.dy,
        block.boxSize.width,
        block.boxSize.height,
      );
      for (final w in level.wires) {
        if (w.touches(block) ||
            movedBlocks.any((b) => w.touches(b))) {
          dirty.add(w);
          continue;
        }
        final segs = current.segments[w];
        if (segs == null) continue;
        final hit = segs.any((s) {
          final a = s.$1 + level.offset;
          final b = s.$2 + level.offset;
          return Rect.fromLTRB(
            math.min(a.dx, b.dx),
            math.min(a.dy, b.dy),
            math.max(a.dx, b.dx),
            math.max(a.dy, b.dy),
          ).overlaps(rect);
        });
        if (hit) dirty.add(w);
      }
    }
    NlAutoRouteResult? next;
    if (dirty.isEmpty) {
      next = current;
    } else if (dirty.any((w) => w.loads.length != 1)) {
      next = routeNetlistWires(levels, _nlModel!.canvasSize);
    } else {
      next = nlRerouteWires(levels, _nlModel!.canvasSize, current, dirty);
    }
    if (next == null || !nlRouteIsClean(next)) {
      // 局部重布不干净时退回整图重布。
      next = routeNetlistWires(levels, _nlModel!.canvasSize);
    }
    final clean = nlRouteIsClean(next);
    setState(() {
      _autoRoutes = next;
      _editUndo.add(snap);
      _editLog.add(
        '移动 ${block.title} (${dx.toStringAsFixed(0)},'
        '${dy.toStringAsFixed(0)})',
      );
    });
    if (!clean && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('元件已移动；走线仍有冲突，可继续手动调整')),
      );
    }
  }

  void _undoNlEdit() {
    if (_editUndo.isEmpty) return;
    final snap = _editUndo.removeLast();
    _restoreNlEdit(snap);
    setState(() {
      _autoRoutes = snap.routes;
      _editLog.add('撤销');
    });
  }

  /// 按当前布局结果重建页面模型（清空某个优化维度后立即回退显示）。
  void _rebuildCurrentModel() {
    final mod = _netlist?.module(_currentModule);
    if (mod != null) _nlModel = _buildModel(mod);
  }

  /// 布线优化选项切换：关闭时撤销布线优化已采纳的针脚变换与元件移动
  /// （重建模型并清除布线结果），开启时仅记录、下次优化生效。
  void _setRouteOpt(
    void Function(VoidCallback) sync,
    bool? value,
    void Function(bool) assign,
  ) {
    final v = value ?? false;
    sync(() {
      assign(v);
      if (!v) {
        _autoRoutes = null;
        _routingOptSession++;
        _routingOptimizing = false;
        _rebuildCurrentModel();
      }
    });
  }

  /// 工具栏「布局布线设置」：拓扑单选 + 镜像元件 / 引脚交换复选。
  /// 工具栏「查看网表」：弹出当前模块（可切换模块）的只读网表文本。
  void _showNetlist() {
    final netlist = _netlist;
    if (netlist == null) return;
    var module = netlist.module(_currentModule) ?? netlist.modules.values.first;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final text = netlistModuleText(module);
          return Dialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
              side: const BorderSide(color: Color(0xFF3A3A3A)),
            ),
            child: SizedBox(
              width: 780,
              height: 640,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.list_alt,
                          size: 18,
                          color: Color(0xFF4EC9B0),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '查看网表',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 260,
                          child: DropdownButton<String>(
                            value: module.name,
                            isExpanded: true,
                            dropdownColor: const Color(0xFF252526),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                            items: [
                              for (final m in netlist.modules.values)
                                DropdownMenuItem(
                                  value: m.name,
                                  child: Text(
                                    m.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(
                                () => module = netlist.modules[value]!,
                              );
                            },
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '复制网表',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('网表已复制')),
                            );
                          },
                          icon: const Icon(
                            Icons.copy,
                            size: 18,
                            color: Colors.white70,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          icon: const Icon(
                            Icons.close,
                            size: 18,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF3A3A3A)),
                  Expanded(
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          text,
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontFamilyFallback: ['monospace'],
                            fontSize: 11.5,
                            height: 1.5,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void sync(VoidCallback change) {
              setDialogState(change);
              setState(() {});
            }

            Widget topologyRadio(NlNetTopology value, String label) {
              return InkWell(
                key: ValueKey('nl-settings-${value.name}'),
                onTap: () {
                  _invalidateLayoutOptimization();
                  sync(() => _cliqueTopology = value == NlNetTopology.clique);
                },
                borderRadius: BorderRadius.circular(3),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Radio<NlNetTopology>(
                        value: value,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            Widget sectionLabel(String text) => Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            );

            return AlertDialog(
              backgroundColor: const Color(0xFF252526),
              title: const Text('布局布线设置'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sectionLabel('布局拓扑策略选择'),
                      const SizedBox(height: 4),
                      RadioGroup<NlNetTopology>(
                        groupValue: _cliqueTopology
                            ? NlNetTopology.clique
                            : NlNetTopology.star,
                        onChanged: (value) {
                          if (value == null) return;
                          _invalidateLayoutOptimization();
                          sync(
                            () =>
                                _cliqueTopology = value == NlNetTopology.clique,
                          );
                        },
                        child: Row(
                          children: [
                            topologyRadio(NlNetTopology.clique, '团形拓扑'),
                            const SizedBox(width: 16),
                            topologyRadio(NlNetTopology.star, '星形拓扑'),
                          ],
                        ),
                      ),
                      const Divider(height: 20),
                      sectionLabel('列分配算法'),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-layered'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _layeredLayout,
                        title: const Text(
                          '分层布局',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '切反馈边 + 最长路径分层 + DP 压列 + 中位数排序；'
                          '关闭则回退经典 BFS 压缩（交叉更多）',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) {
                          _invalidateLayoutOptimization();
                          _clearLayoutPlans();
                          _autoRoutes = null;
                          sync(() {
                            _layeredLayout = value ?? false;
                            _rebuildCurrentModel();
                          });
                        },
                      ),
                      const Divider(height: 20),
                      sectionLabel('布局优化选项'),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-mirror'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _mirrorComponents,
                        title: const Text(
                          '镜像元件',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布局优化时逐个元件尝试上下镜像（不强制全部镜像）',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) {
                          _invalidateLayoutOptimization();
                          sync(() {
                            _mirrorComponents = value ?? false;
                            if (!_mirrorComponents) {
                              // 关闭后立即撤销已采纳的镜像，恢复无镜像布局。
                              _layoutMirroredBlocks = const {};
                              _rebuildCurrentModel();
                            }
                          });
                        },
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-swap-pins'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _swapPins,
                        title: const Text(
                          '引脚交换',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布局优化时允许交换同一符号的输入引脚',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) {
                          _invalidateLayoutOptimization();
                          sync(() {
                            _swapPins = value ?? false;
                            if (!_swapPins) {
                              // 关闭后立即撤销已采纳的引脚交换。
                              _layoutPinOrders = const {};
                              _rebuildCurrentModel();
                            }
                          });
                        },
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-global-reorder'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _allowGlobalReorder,
                        title: const Text(
                          '允许全局重排',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布局优化时元件不限于原来的列，可重排到任意列',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) {
                          _invalidateLayoutOptimization();
                          sync(() {
                            _allowGlobalReorder = value ?? false;
                            if (!_allowGlobalReorder) {
                              // 关闭后立即撤销已采纳的行序（含跨列放置）。
                              _layoutRowOrders = const {};
                              _rebuildCurrentModel();
                            }
                          });
                        },
                      ),
                      const Divider(height: 20),
                      sectionLabel('布线优化选项'),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-row-gap'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _variableRowGap,
                        title: const Text(
                          '允许列内非等间距',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '列内相邻元件间距 2~20 Grid：不含走线的推挤到 2 Grid，'
                          '为走线最多留 20 Grid',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) => _setRouteOpt(
                          sync,
                          value,
                          (v) => _variableRowGap = v,
                        ),
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-route-mirror-v'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _routeOptMirrorV,
                        title: const Text(
                          '上下镜像元件',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布线优化时允许输入/输出槽位反转、顶↔底针脚互换',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) => _setRouteOpt(
                          sync,
                          value,
                          (v) => _routeOptMirrorV = v,
                        ),
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-route-mirror-h'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _routeOptMirrorH,
                        title: const Text(
                          '左右镜像元件',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        subtitle: const Text(
                          '待完成：符号水平翻转暂未支持',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: null,
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-route-swap-l'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _routeOptSwapL,
                        title: const Text(
                          '交换左侧引脚',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布线优化时允许反转输入侧引脚槽位顺序',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) => _setRouteOpt(
                          sync,
                          value,
                          (v) => _routeOptSwapL = v,
                        ),
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-route-swap-r'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _routeOptSwapR,
                        title: const Text(
                          '交换右侧引脚',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布线优化时允许反转输出侧引脚槽位顺序',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) => _setRouteOpt(
                          sync,
                          value,
                          (v) => _routeOptSwapR = v,
                        ),
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-route-swap-t'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _routeOptSwapT,
                        title: const Text(
                          '交换上方引脚',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布线优化时允许反转顶边引脚槽位顺序',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) => _setRouteOpt(
                          sync,
                          value,
                          (v) => _routeOptSwapT = v,
                        ),
                      ),
                      CheckboxListTile(
                        key: const ValueKey('nl-settings-route-swap-b'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _routeOptSwapB,
                        title: const Text(
                          '交换下方引脚',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          '布线优化时允许反转底边引脚槽位顺序',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        onChanged: (value) => _setRouteOpt(
                          sync,
                          value,
                          (v) => _routeOptSwapB = v,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 工具栏「自动布线」（单一功能）：按当前布局生成正交走线，并按
  /// 「布局布线设置」的布线优化选项继续自动优化布线（两阶段合并）。
  /// 已有走线时再次点击 = 按当前布局重新布线并优化。
  Future<void> _runAutoRoute() async {
    final model = _nlModel;
    if (model == null || _autoRouting || _routingOptimizing) return;
    _editStraightPreview = false;
    _routingOptSession++;
    setState(() => _autoRouting = true);
    // 先让按钮进入忙碌态，再执行网格 A*（通常几十到几百毫秒）。
    await Future<void>.delayed(const Duration(milliseconds: 32));
    if (!mounted) return;
    final routes = routeNetlistWires(model.flattened(), model.canvasSize);
    if (!mounted) return;
    if (!identical(_nlModel, model)) {
      setState(() => _autoRouting = false);
      return;
    }
    setState(() {
      _autoRoutes = routes;
      _autoRouting = false;
    });
    await _optimizeRouting();
  }

  /// 「自动布线」的第二阶段：按布线优化选项多轮优化（交叉→折弯→总长），
  /// 进度/结果显示在右上角布线优化浮层。
  Future<void> _optimizeRouting() async {
    if (_routingOptimizing || _layoutOptimizing) return;
    final model = _nlModel;
    if (model == null) return;
    final session = ++_routingOptSession;
    final initial = _autoRoutes;
    final initialMetrics = initial == null ? null : nlRoutingMetrics(initial);
    setState(() {
      _routingOptPanelVisible = true;
      _routingOptimizing = true;
      _routingOptElapsed = Duration.zero;
      if (initialMetrics != null) {
        _routingOptCrossings = initialMetrics.crossings;
        _routingOptBends = initialMetrics.bends;
        _routingOptLength = initialMetrics.length;
      } else {
        _routingOptCrossings = 0;
        _routingOptBends = 0;
        _routingOptLength = 0;
      }
    });
    _routingOptWatch
      ..reset()
      ..start();
    await Future<void>.delayed(const Duration(milliseconds: 32));
    if (!mounted) return;
    try {
      final optimized = await optimizeNetlistRouting(
        model.flattened(),
        model.canvasSize,
        initial: _autoRoutes,
        options: NlRouteOptOptions(
          mirrorVertical: _routeOptMirrorV,
          mirrorHorizontal: _routeOptMirrorH,
          swapLeftPins: _routeOptSwapL,
          swapRightPins: _routeOptSwapR,
          swapTopPins: _routeOptSwapT,
          swapBottomPins: _routeOptSwapB,
          variableRowGap: _variableRowGap,
        ),
        onProgress: (routes, stage, step) {
          if (!mounted ||
              !identical(_nlModel, model) ||
              session != _routingOptSession) {
            return;
          }
          final m = nlRoutingMetrics(routes);
          setState(() {
            _autoRoutes = routes;
            _routingOptStage = stage;
            _routingOptCrossings = m.crossings;
            _routingOptBends = m.bends;
            _routingOptLength = m.length;
            _routingOptElapsed = _routingOptWatch.elapsed;
          });
        },
      );
      if (!mounted) return;
      if (!identical(_nlModel, model) || session != _routingOptSession) {
        _routingOptWatch.stop();
        setState(() {
          _routingOptimizing = false;
          _routingOptPanelVisible = false;
        });
        return;
      }
      final metrics = nlRoutingMetrics(optimized.result);
      _routingOptWatch.stop();
      setState(() {
        _autoRoutes = optimized.result;
        _routingOptimizing = false;
        _routingOptCrossings = metrics.crossings;
        _routingOptBends = metrics.bends;
        _routingOptLength = metrics.length;
        _routingOptElapsed = _routingOptWatch.elapsed;
      });
      final before = optimized.initialLength.toStringAsFixed(0);
      final after = optimized.length.toStringAsFixed(0);
      final text = optimized.improved
          ? '布线优化：交叉 ${optimized.initialCrossings}→${optimized.crossings}，'
                '折弯 ${optimized.initialBends}→${optimized.bends}，'
                '长度 $before→$after dp'
          : '布线已是最优（交叉 ${optimized.crossings}、'
                '折弯 ${optimized.bends}、$after dp）';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } on Object catch (error) {
      if (!mounted) return;
      _routingOptWatch.stop();
      setState(() {
        _routingOptimizing = false;
        _routingOptPanelVisible = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('布线优化失败：$error')));
    }
  }

  /// 把当前（可能手工调整过的）模型的列内顺序、镜像、引脚序提取成
  /// 布局优化可用的初始解，避免一点“优化布局”就丢掉手工结果。
  Map<int, List<String>> _currentRowOrders(NetlistDiagramModel model) {
    final byColumn = <int, List<NlBlock>>{};
    for (final b in model.blocks) {
      if (b.isIo) continue;
      (byColumn[b.column] ??= []).add(b);
    }
    return {
      for (final e in byColumn.entries)
        e.key: [
          for (final b in e.value..sort(
            (a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy),
          ))
            b.id,
        ],
    };
  }

  Set<String> _currentMirrors(NetlistDiagramModel model) => {
    for (final b in model.blocks)
      if (!b.isIo && b.pinFlip) b.id,
  };

  Map<String, List<String>> _currentPinOrders(NetlistDiagramModel model) => {
    for (final b in model.blocks)
      if (!b.isIo && b.inPinOrder != null) b.id: [...b.inPinOrder!],
  };

  String get _teachingPath {
    final safe = widget.groupId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return 'IspFlow/LayoutTeaching/$safe.json';
  }

  Future<void> _loadTeaching() async {
    try {
      final f = File(_teachingPath);
      if (!await f.exists()) return;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! List) return;
      if (!mounted) return;
      setState(() {
        _teachRules
          ..clear()
          ..addAll([
            for (final e in decoded)
              if (e is Map) Map<String, dynamic>.from(e),
          ]);
      });
    } on Object {
      // 损坏/不可读的偏好文件按无学习记录处理。
    }
  }

  Future<void> _saveTeaching() async {
    try {
      final f = File(_teachingPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_teachRules));
    } on Object {
      // 写入失败不阻塞编辑。
    }
  }

  void _mergeTeachingRule(Map<String, dynamic> rule) {
    String keyOf(Map<String, dynamic> r) =>
        '${r['type']}|${r['a']}|${r['b']}|${r['cell']}|${r['side']}';
    final key = keyOf(rule);
    final i = _teachRules.indexWhere((r) => keyOf(r) == key);
    if (i >= 0) {
      _teachRules[i]['count'] = ((_teachRules[i]['count'] as int?) ?? 1) + 1;
    } else {
      _teachRules.add({...rule, 'count': 1});
    }
  }

  bool get _canLearnLayoutNow {
    if (!_editMode || !_editStraightPreview || _editStartLength <= 0) {
      return false;
    }
    final model = _nlModel;
    if (model == null) return false;
    final length = nlStraightLength(
      model,
      topology: _cliqueTopology ? NlNetTopology.clique : NlNetTopology.star,
    );
    return length < _editStartLength - 0.5;
  }

  Future<void> _learnManualLayout(NetlistDiagramModel model) async {
    if (!_editStraightPreview) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('布局学习只针对直线预览；正交走线属于布线学习（待实现）')),
        );
      }
      return;
    }
    final length = nlStraightLength(
      model,
      topology: _cliqueTopology ? NlNetTopology.clique : NlNetTopology.star,
    );
    if (_editStartLength > 0 && length >= _editStartLength - 0.5) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本次手工调整未缩短总长，暂不学习')),
        );
      }
      return;
    }
    var added = 0;
    for (final b in model.blocks) {
      if (b.isIo) continue;
      final type = b.cell?.typeLabel ?? b.title;
      if (b.pinFlip) {
        _mergeTeachingRule({'type': 'mirror', 'cell': type});
        added++;
      }
      if (b.inPinOrder != null) {
        _mergeTeachingRule({
          'type': 'pin',
          'cell': type,
          'side': 'in',
          'seq': [...b.inPinOrder!],
        });
        added++;
      }
      if (b.outPinOrder != null) {
        _mergeTeachingRule({
          'type': 'pin',
          'cell': type,
          'side': 'out',
          'seq': [...b.outPinOrder!],
        });
        added++;
      }
    }
    final byColumn = <int, List<NlBlock>>{};
    for (final b in model.blocks) {
      if (b.isIo) continue;
      (byColumn[b.column] ??= []).add(b);
    }
    for (final list in byColumn.values) {
      list.sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
      for (var i = 0; i + 1 < list.length; i++) {
        _mergeTeachingRule({
          'type': 'order',
          'a': list[i].id,
          'b': list[i + 1].id,
        });
        added++;
      }
    }
    await _saveTeaching();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已学习 $added 条手工布局偏好，规则 ${_teachRules.length} 条')),
    );
  }

  void _applyTeaching(NetlistDiagramModel model) {
    if (_teachRules.isEmpty) return;
    for (final b in model.blocks) {
      if (b.isIo) continue;
      final type = b.cell?.typeLabel ?? b.title;
      for (final r in _teachRules) {
        if (r['type'] == 'mirror' && r['cell'] == type) {
          b.pinFlip = true;
        } else if (r['type'] == 'pin' && r['cell'] == type) {
          final seq = [for (final e in (r['seq'] as List?) ?? []) '$e'];
          if (seq.isEmpty) continue;
          b.inPinOrder = r['side'] == 'in' ? seq : b.inPinOrder;
          b.outPinOrder = r['side'] == 'out' ? seq : b.outPinOrder;
          nlLayoutBlockPins(b);
        }
      }
    }
    final byColumn = <int, List<NlBlock>>{};
    for (final b in model.blocks) {
      if (b.isIo) continue;
      (byColumn[b.column] ??= []).add(b);
    }
    for (final list in byColumn.values) {
      list.sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
      var changed = true;
      var guard = 0;
      while (changed && guard++ < 32) {
        changed = false;
        for (final r in _teachRules) {
          if (r['type'] != 'order') continue;
          final ia = list.indexWhere((b) => b.id == r['a']);
          final ib = list.indexWhere((b) => b.id == r['b']);
          if (ia >= 0 && ib >= 0 && ia > ib) {
            final item = list.removeAt(ia);
            list.insert(ib, item);
            changed = true;
          }
        }
      }
      double y = list.first.boxOrigin.dy;
      for (final b in list) {
        nlShiftBlock(b, y - b.boxOrigin.dy);
        y += b.boxSize.height + 7 * nlLayoutGrid;
      }
    }
  }

  /// 工具栏「优化布局」：列内重排行序，按当前拓扑的总直线长度择优。
  Future<void> _startLayoutOptimization() async {
    final mod = _netlist?.module(_currentModule);
    if (mod == null || _layoutOptimizing || _routingOptimizing) return;
    final nl = _netlist;
    final topology = _cliqueTopology
        ? NlNetTopology.clique
        : NlNetTopology.star;
    final session = ++_layoutOptSession;
    final baseline = _nlModel;
    // 无本次手工改动时，先套用历史学习到的偏好（镜像/引脚序/相邻顺序）。
    if (baseline != null && _editLog.isEmpty) {
      _applyTeaching(baseline);
    }
    final startLength = baseline == null
        ? 0.0
        : nlStraightLength(baseline, topology: topology);
    final hasManualEdits = _editLog.isNotEmpty;
    final manualRows = hasManualEdits && baseline != null
        ? _currentRowOrders(baseline)
        : _layoutRowOrders;
    final manualMirrors = hasManualEdits && baseline != null
        ? _currentMirrors(baseline)
        : _layoutMirroredBlocks;
    final manualPinOrders = hasManualEdits && baseline != null
        ? _currentPinOrders(baseline)
        : _layoutPinOrders;
    setState(() {
      _layoutOptimizing = true;
      _layoutOptPanelVisible = true;
      _layoutOptModules = baseline?.blocks.where((b) => !b.isIo).length ?? 0;
      _layoutOptEndpoints = baseline == null ? 0 : nlEndpointCount(baseline);
      _layoutOptInputs = mod.inputs.length;
      _layoutOptOutputs = mod.outputs.length;
      _layoutOptInouts = mod.inouts.length;
      _layoutOptInitial = startLength;
      _layoutOptLength = startLength;
      _layoutOptElapsed = Duration.zero;
    });
    _layoutOptWatch
      ..reset()
      ..start();
    // 先让「布局优化中」浮层绘制一帧，再开始评估候选。
    await Future<void>.delayed(const Duration(milliseconds: 32));
    if (!mounted || session != _layoutOptSession) return;

    try {
      final result = await optimizeNetlistLayout(
        mod,
        expanded: {..._expanded},
        resolve: nl == null
            ? null
            : (type) => nl.resolveInstance(type) ?? nl.module(type),
        netlist: nl,
        topology: topology,
        allowMirror: _mirrorComponents,
        swapPins: _swapPins,
        allowGlobalReorder: _allowGlobalReorder,
        initialRowOrders: manualRows,
        initialMirroredBlocks: manualMirrors,
        initialPinOrders: manualPinOrders,
        isCancelled: () => !mounted || session != _layoutOptSession,
        onProgress: (p) {
          if (!mounted || session != _layoutOptSession) return;
          setState(() {
            _layoutOptModules = p.nodes;
            _layoutOptInitial = p.initialLength;
            _layoutOptLength = p.length;
            _layoutOptElapsed = _layoutOptWatch.elapsed;
            _nlModel = p.model;
          });
        },
      );
      if (!mounted || session != _layoutOptSession) return;
      _layoutOptWatch.stop();
      // 手工布局作为基线：优化结果没有更短就保留手工结果。
      if (baseline != null && result.length >= startLength - 0.5) {
        setState(() {
          _layoutOptimizing = false;
          _layoutOptModules = result.nodes;
          _layoutOptInitial = startLength;
          _layoutOptLength = startLength;
          _layoutOptElapsed = _layoutOptWatch.elapsed;
          _layoutRowOrders = manualRows;
          _layoutMirroredBlocks = manualMirrors;
          _layoutPinOrders = manualPinOrders;
          _nlModel = baseline;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('手工布局已更优，保留当前结果')),
          );
        }
        return;
      }
      setState(() {
        _layoutOptimizing = false;
        _layoutOptModules = result.nodes;
        _layoutOptInitial = result.initialLength;
        _layoutOptLength = result.length;
        _layoutOptElapsed = _layoutOptWatch.elapsed;
        _layoutRowOrders = result.rowOrders;
        _layoutMirroredBlocks = result.mirroredBlocks;
        _layoutPinOrders = result.pinOrders;
        _nlModel = result.model;
      });
    } on Object catch (error) {
      if (!mounted || session != _layoutOptSession) return;
      _layoutOptWatch.stop();
      setState(() {
        _layoutOptimizing = false;
        _layoutOptPanelVisible = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('布局优化失败：$error')));
    }
  }

  Future<Map<String, String>> _defaultFiles(
    IspGraph graph,
    IspNodeGroup group,
    IpGenOptions options,
  ) async => buildGroupIpFiles(graph, group, options);

  /// 切到指定模块（下钻/回退）。同模块不重复入栈。
  void _showModule(String name) {
    final nl = _netlist;
    if (nl == null) return;
    final mod = nl.module(name);
    if (mod == null) return;
    _invalidateLayoutOptimization();
    _clearLayoutPlans();
    setState(() {
      if (_path.isEmpty || _path.last != mod.name) _path.add(mod.name);
      _expanded.clear();
      _nlModel = _buildModel(mod);
    });
  }

  /// RTL 视图点单元：实例下钻；逻辑单元跳其源码信号（IP 代码页高亮）。
  void _onTapCell(NetlistCell cell) {
    if (cell.isInstance && cell.moduleRef != null) {
      _showModule(cell.moduleRef!);
      return;
    }
    // 逻辑单元：取其可读网名（输出优先）跳到 IP 代码页高亮。
    String? name;
    for (final p in [...cell.outs, ...cell.ins]) {
      for (final n in p.nets) {
        if (!n.isConst && !n.isDerived && !n.name.contains(r'$')) {
          name = n.name;
          break;
        }
      }
      if (name != null) break;
    }
    final state = context.read<IspStudioState>();
    final options =
        sessionIpGenOptions[widget.groupId] ??
        IpGenOptions(vendor: widget.vendor);
    state.openGroupIpTab(widget.groupId, options);
    if (name != null) state.ipCodeHighlight = name;
  }

  /// 回顶层（清除下钻路径）。
  void _backToTop() {
    if (_netlist == null || _path.length <= 1) return;
    _showModule(_path.first);
    setState(() => _path.removeRange(1, _path.length));
  }

  // ---- 导出（自研 SVG / 由 SVG 栅格化的 PNG）----

  SchPalette get _palette => _light ? SchPalette.vivadoLight : SchPalette.dark;

  /// 当前 RTL 视图的诊断（带缓存：悬停等高频重建不重复计算）。
  NlRoutingDiagnostics _diagnosticsFor(NetlistDiagramModel model) {
    final topology = _cliqueTopology
        ? NlNetTopology.clique
        : NlNetTopology.star;
    final routes = _autoRoutes?.segments;
    final cached = _diagCache;
    if (cached != null &&
        identical(_diagModel, model) &&
        _diagTopology == topology &&
        identical(_diagRoutes, routes)) {
      return cached;
    }
    final diag = computeNlRoutingDiagnostics(
      model.flattened(),
      model.canvasSize,
      routes: routes,
      junctions: _autoRoutes?.junctions,
      topology: topology,
    );
    _diagModel = model;
    _diagTopology = topology;
    _diagRoutes = routes;
    _diagCache = diag;
    return diag;
  }

  String _svgText() {
    final model = _nlModel;
    if (model == null) return '';
    return buildNetlistSvg(
      model,
      palette: _palette,
      fontFamily: null,
      topology: _cliqueTopology ? NlNetTopology.clique : NlNetTopology.star,
      diagnosticOverlay: _diagnostics
          ? buildNlDiagnosticOverlaySvg(_diagnosticsFor(model))
          : null,
      autoRoutes: _autoRoutes?.segments,
      autoJunctions: _autoRoutes?.junctions,
    );
  }

  String get _currentModule => _path.isEmpty ? 'sch' : _path.last;

  /// 工具栏端口方向统计文本（`· I 7 / O 5` / `+ IO 2`）。
  String get _portDirText {
    final nl = _netlist;
    if (nl == null) return '';
    final mod = nl.module(_currentModule);
    if (mod == null) return '';
    final c = mod.portDirCounts;
    final parts = <String>[
      if ((c[NetlistPortDir.input] ?? 0) > 0) 'I ${c[NetlistPortDir.input]}',
      if ((c[NetlistPortDir.output] ?? 0) > 0) 'O ${c[NetlistPortDir.output]}',
      if ((c[NetlistPortDir.inout] ?? 0) > 0) 'IO ${c[NetlistPortDir.inout]}',
    ];
    return parts.isEmpty ? '' : ' · ${parts.join(' / ')}';
  }

  Future<void> _exportSvg() async {
    final svg = _svgText();
    if (svg.isEmpty) return;
    final loc = await getSaveLocation(
      suggestedName: '${_currentModule}_sch.svg',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SVG', extensions: ['svg']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsString(svg);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已导出 SVG：${loc.path}')));
  }

  Future<void> _exportPng() async {
    final svg = _svgText();
    if (svg.isEmpty) return;
    final loc = await getSaveLocation(
      suggestedName: '${_currentModule}_sch.png',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png']),
      ],
    );
    if (loc == null) return;
    final Uint8List png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
    await File(loc.path).writeAsBytes(png);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已导出 PNG：${loc.path}')));
  }

  // ---- 视图 ----

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    final group = state.graph.groups
        .where((g) => g.id == widget.groupId)
        .firstOrNull;
    if (group == null) {
      return const Center(
        child: Text('编组已被解散', style: TextStyle(color: Colors.grey)),
      );
    }
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(group),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _buildBody(group)),
                if (_logVisible) ...[
                  Container(height: 1, color: const Color(0xFF3A3A3A)),
                  Expanded(flex: 1, child: _buildLogPanel()),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(IspNodeGroup group) {
    Widget divider() => VerticalDivider(
      width: 9,
      thickness: 1,
      indent: 5,
      endIndent: 5,
      color: Colors.grey.shade800,
    );
    return ispTabToolbarRow(
      children: [
        // 视图切换：模块级框图（编组 IR 直绘）/ RTL 网表（yosys + 自研布局）。
        // 配色切换：Vivado 浅色 / 暗色。
        ispTabIconButton(
          tooltip: _light ? '切换暗色配色' : '切换浅色配色（Vivado 风格）',
          onTap: () => setState(() => _light = !_light),
          // contrast 字形在 20px 框内视觉偏低，上移 2px 与其余图标对齐。
          icon: Transform.translate(
            offset: const Offset(0, -2),
            child: Icon(
              Icons.contrast,
              size: 20,
              color: _light ? Colors.white : Colors.white54,
            ),
          ),
        ),
        divider(),
        ispTabIconButton(
          tooltip: 'Zoom In',
          onTap: () => _zoomStep(1.25),
          icon: ispTabAssetIcon('icons/zoom-in.png'),
        ),
        ispTabIconButton(
          tooltip: 'Zoom Out',
          onTap: () => _zoomStep(1 / 1.25),
          icon: ispTabAssetIcon('icons/zoom-out.png'),
        ),
        ispTabIconButton(
          tooltip: 'Zoom Fit',
          onTap: _zoomFit,
          icon: ispTabAssetIcon('icons/screen-full.png'),
        ),
        divider(),
        ...[
          ispTabIconButton(
            key: const ValueKey('nl-settings-button'),
            tooltip: '布局布线设置',
            onTap: _showSettings,
            icon: const Icon(Icons.settings, size: 20, color: Colors.white70),
          ),
          ispTabIconButton(
            key: const ValueKey('nl-heatmap-button'),
            tooltip: _heatmap ? '关闭走线密度热力图' : '走线密度热力图',
            onTap: () => setState(() => _heatmap = !_heatmap),
            icon: Icon(
              Icons.grid_on,
              size: 20,
              color: _heatmap ? const Color(0xFF4EC9B0) : Colors.white54,
            ),
          ),
          ispTabIconButton(
            key: const ValueKey('nl-diagnostics-button'),
            tooltip: _diagnostics ? '关闭走线诊断' : '走线诊断',
            onTap: () => setState(() => _diagnostics = !_diagnostics),
            icon: Icon(
              Icons.troubleshoot,
              size: 20,
              color: _diagnostics ? const Color(0xFF4EC9B0) : Colors.white54,
            ),
          ),
          ispTabIconButton(
            key: const ValueKey('nl-edit-button'),
            tooltip: _editMode ? '退出编辑模式' : '编辑模式（拖动元件）',
            onTap: () => setState(() {
              _editMode = !_editMode;
              if (_editMode) {
                _manualOptPanelVisible = true;
                _editStraightPreview = _autoRoutes == null;
                _editStartLength = _nlModel == null
                    ? 0
                    : nlStraightLength(
                        _nlModel!,
                        topology: _cliqueTopology
                            ? NlNetTopology.clique
                            : NlNetTopology.star,
                      );
              } else {
                _editStraightPreview = false;
              }
            }),
            icon: Icon(
              Icons.open_with,
              size: 20,
              color: _editMode ? const Color(0xFF4EC9B0) : Colors.white54,
            ),
          ),
          ispTabIconButton(
            key: const ValueKey('nl-edit-undo'),
            tooltip: '撤销手动编辑',
            onTap: _editUndo.isEmpty ? null : _undoNlEdit,
            icon: Icon(
              Icons.undo,
              size: 20,
              color: _editUndo.isEmpty ? Colors.white24 : Colors.white54,
            ),
          ),
          ispTabIconButton(
            key: const ValueKey('nl-learn-layout-toolbar'),
            tooltip: _canLearnLayoutNow
                ? '学习当前布局（手工结果更优）'
                : '学习布局（当前手工结果无改善）',
            onTap: _canLearnLayoutNow && _nlModel != null
                ? () => _learnManualLayout(_nlModel!)
                : null,
            icon: Icon(
              Icons.school,
              size: 20,
              color: _canLearnLayoutNow
                  ? const Color(0xFF4EA1FF)
                  : Colors.white24,
            ),
          ),
          divider(),
          ispTabIconButton(
            key: const ValueKey('nl-optimize-button'),
            tooltip: '优化布局',
            onTap: (_layoutOptimizing || _nlModel == null)
                ? null
                : _startLayoutOptimization,
            icon: Icon(
              Icons.auto_fix_high,
              size: 20,
              color: _layoutOptimizing ? Colors.white38 : Colors.white,
            ),
          ),
          ispTabIconButton(
            key: const ValueKey('nl-autoroute-button'),
            tooltip: '自动布线',
            onTap: (_autoRouting || _routingOptimizing || _nlModel == null)
                ? null
                : _runAutoRoute,
            icon: Icon(
              Icons.alt_route,
              size: 20,
              color: (_autoRouting || _routingOptimizing)
                  ? Colors.white38
                  : Colors.white,
            ),
          ),
          ispTabIconButton(
            tooltip: '重新生成',
            onTap: _running ? null : _extract,
            icon: ispTabAssetIcon(
              'icons/refresh.png',
              color: _running ? Colors.white38 : Colors.white,
            ),
          ),
          if (_nlModel != null) divider(),
          if (_nlModel != null)
            ispTabIconButton(
              tooltip: '导出SVG',
              onTap: _exportSvg,
              icon: ispTabAssetIcon('icons/git-stash-pop.png'),
            ),
          if (_nlModel != null)
            ispTabIconButton(
              tooltip: '导出PNG',
              onTap: _exportPng,
              icon: ispTabAssetIcon('icons/save.png'),
            ),
          if (_netlist != null)
            ispTabIconButton(
              key: const ValueKey('nl-netlist-button'),
              tooltip: '查看网表',
              onTap: _showNetlist,
              icon: const Icon(Icons.list_alt, size: 20, color: Colors.white70),
            ),
          ispTabIconButton(
            tooltip: _logVisible ? '收起日志' : '查看日志',
            onTap: () => setState(() => _logVisible = !_logVisible),
            icon: const Icon(Icons.terminal, size: 20, color: Colors.white),
          ),
          if (_nlModel != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '模块 $_currentModule（${_nlModel!.cellCount} 单元$_portDirText）'
                ' · 直线·${_cliqueTopology ? '团' : '星形'}'
                ' · ${_layeredLayout ? '分层' : '压缩'}列',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          if (_path.length > 1) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: _running ? null : _backToTop,
              child: const Text(
                '回顶层',
                style: TextStyle(fontSize: 11, color: Color(0xFF4EC9B0)),
              ),
            ),
          ],
        ],
        const Spacer(),
        Flexible(
          child: Text(
            '${group.name} (${widget.groupId})',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          '编组·电路图',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(width: 6),
        Text(
          widget.vendor.shortName,
          style: const TextStyle(fontSize: 11, color: Color(0xFF4EC9B0)),
        ),
        const SizedBox(width: 8),
        ispTabToolbarReadOnly(),
      ],
    );
  }

  /// 本体：框图模式为模块级框图；RTL 模式为进度/错误/自研网表电路图
  /// （InteractiveViewer 拖动平移 + 滚轮缩放，模型构建后初始自适应；
  /// 编组变更时顶部显示过期提示条）。
  /// 优化信息浮层的文字配色（标题/正文/次要/改善注记）：浅色画布必须
  /// 用深色系——白色系文字在白底浮层上完全看不见。
  (Color, Color, Color, Color) get _panelTextColors => _light
      ? (
          const Color(0xFF1A1A1A),
          const Color(0xFF3C3C3C),
          const Color(0xFF6A6A6A),
          const Color(0xFF8A6D3B),
        )
      : (Colors.white, Colors.white70, Colors.white54, const Color(0xFFD7BA7D));

  /// 布局优化浮层（右上角）：运行中显示「布局优化中」、模块数、端点数、
  /// 输入/输出/双向端口数与总直线长度；
  /// 完成后保留最终结果，可点右上角 X 关闭。
  Widget _buildLayoutOptimizationPanel() {
    const accent = Color(0xFF4EC9B0);
    final (titleColor, bodyColor, subtleColor, noteColor) = _panelTextColors;
    final improved =
        _layoutOptInitial > 0 && _layoutOptLength < _layoutOptInitial - 0.5;
    final pct = _layoutOptInitial <= 0
        ? 0.0
        : (1 - _layoutOptLength / _layoutOptInitial) * 100;
    return IgnorePointer(
      ignoring: _layoutOptimizing,
      child: Container(
        key: const ValueKey('nl-layout-progress'),
        width: _nlPanelWidth,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
        decoration: BoxDecoration(
          color: _palette.canvasBg.withValues(alpha: 0.94),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: _layoutOptimizing
                      ? CircularProgressIndicator(
                          strokeWidth: 2.2,
                          backgroundColor: _light
                              ? Colors.black12
                              : Colors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            accent,
                          ),
                        )
                      : const Icon(Icons.check_circle, size: 18, color: accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _layoutOptimizing ? '布局优化中' : '布局优化完成',
                    style: TextStyle(fontSize: 12, color: titleColor),
                  ),
                ),
                if (!_layoutOptimizing)
                  InkWell(
                    key: const ValueKey('nl-layout-progress-close'),
                    onTap: () => setState(() => _layoutOptPanelVisible = false),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 14, color: subtleColor),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '模块数  $_layoutOptModules',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '端点数  $_layoutOptEndpoints',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '输入端口  $_layoutOptInputs',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '输出端口  $_layoutOptOutputs',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '双向端口  $_layoutOptInouts',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '总直线长度  ${_layoutOptLength.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '用时  ${fmtElapsed(_layoutOptElapsed)}',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            if (!_layoutOptimizing && improved) ...[
              const SizedBox(height: 2),
              Text(
                '初始 ${_layoutOptInitial.toStringAsFixed(0)} → 当前'
                '（−${pct.toStringAsFixed(1)}%）',
                style: TextStyle(fontSize: 10, color: noteColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 手动布局优化浮层（编辑模式自动显示，位于布局优化窗左侧）。
  Widget _buildManualLayoutPanel(NetlistDiagramModel model) {
    const accent = Color(0xFF4EC9B0);
    final (titleColor, bodyColor, subtleColor, _) = _panelTextColors;
    var modules = 0;
    var endpoints = 0;
    var inputs = 0;
    var outputs = 0;
    var inouts = 0;
    final levels = model.flattened();
    for (final level in levels) {
      for (final b in level.blocks) {
        if (b.isIo) continue;
        modules++;
        endpoints += b.ins.length + b.outs.length;
      }
      for (final p in level.ports) {
        switch (p.dir) {
          case NetlistPortDir.input:
            inputs++;
          case NetlistPortDir.output:
            outputs++;
          case NetlistPortDir.inout:
            inouts++;
        }
      }
    }
    final length = nlStraightLength(
      model,
      topology: _cliqueTopology ? NlNetTopology.clique : NlNetTopology.star,
    );
    final canLearnLayout = _editStraightPreview &&
        _editStartLength > 0 &&
        length < _editStartLength - 0.5;
    return Container(
      key: const ValueKey('nl-manual-progress'),
      width: _nlPanelWidth,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        color: _palette.canvasBg.withValues(alpha: 0.94),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '手动布局优化',
                  style: TextStyle(fontSize: 12, color: titleColor),
                ),
              ),
              InkWell(
                key: const ValueKey('nl-manual-progress-close'),
                onTap: () =>
                    setState(() => _manualOptPanelVisible = false),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: subtleColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '模块数  $modules',
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 2),
          Text(
            '端点数  $endpoints',
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 2),
          Text(
            '输入端口  $inputs',
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 2),
          Text(
            '输出端口  $outputs',
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 2),
          Text(
            '双向端口  $inouts',
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 2),
          Text(
            '总直线长度  ${length.toStringAsFixed(0)}',
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 2),
          Text(
            '已编辑  ${_editLog.length} 次',
            style: TextStyle(fontSize: 11, color: bodyColor),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '已学布局 ${_teachRules.length} 条',
                style: TextStyle(fontSize: 10, color: subtleColor),
              ),
              const Spacer(),
              InkWell(
                key: const ValueKey('nl-learn-layout'),
                onTap: canLearnLayout
                    ? () => _learnManualLayout(model)
                    : null,
                child: Text(
                  '学习布局',
                  style: TextStyle(
                    fontSize: 10,
                    color: canLearnLayout
                        ? const Color(0xFF4EA1FF)
                        : subtleColor,
                    fontWeight:
                        canLearnLayout ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                key: const ValueKey('nl-clear-learn'),
                onTap: () {
                  setState(_teachRules.clear);
                  unawaited(_saveTeaching());
                },
                child: Text(
                  '清除',
                  style: TextStyle(fontSize: 10, color: subtleColor),
                ),
              ),
            ],
          ),
          if (!_editStraightPreview) ...[
            const SizedBox(height: 3),
            Text(
              '布线学习：待实现（当前仅正交布线）',
              style: TextStyle(fontSize: 10, color: subtleColor),
            ),
          ],
        ],
      ),
    );
  }

  /// 自动优化布线浮层（右上角）：交叉点、折弯点与走线总长。
  Widget _buildRoutingOptimizationPanel() {
    const accent = Color(0xFF4EC9B0);
    final (titleColor, bodyColor, subtleColor, _) = _panelTextColors;
    return IgnorePointer(
      ignoring: _routingOptimizing,
      child: Container(
        key: const ValueKey('nl-routing-progress'),
        width: _nlPanelWidth,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
        decoration: BoxDecoration(
          color: _palette.canvasBg.withValues(alpha: 0.94),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: _routingOptimizing
                      ? CircularProgressIndicator(
                          strokeWidth: 2.2,
                          backgroundColor: _light
                              ? Colors.black12
                              : Colors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            accent,
                          ),
                        )
                      : const Icon(Icons.check_circle, size: 18, color: accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _routingOptimizing ? '布线优化中' : '布线优化完成',
                    style: TextStyle(fontSize: 12, color: titleColor),
                  ),
                ),
                if (!_routingOptimizing)
                  InkWell(
                    key: const ValueKey('nl-routing-progress-close'),
                    onTap: () =>
                        setState(() => _routingOptPanelVisible = false),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 14, color: subtleColor),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_routingOptimizing) ...[
              Text(
                _routingOptStage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: subtleColor),
              ),
              const SizedBox(height: 3),
            ],
            Text(
              '交叉点  $_routingOptCrossings',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '折弯点  $_routingOptBends',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '走线总长  ${_routingOptLength.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
            const SizedBox(height: 2),
            Text(
              '用时  ${fmtElapsed(_routingOptElapsed)}',
              style: TextStyle(fontSize: 11, color: bodyColor),
            ),
          ],
        ),
      ),
    );
  }

  /// 走线诊断浮层（左上角）：确定性指标 + 硬约束违反，供布局/布线对比。
  Widget _buildDiagnosticsPanel(NetlistDiagramModel model) {
    final d = _diagnosticsFor(model);
    final (titleColor, bodyColor, subtleColor, _) = _panelTextColors;
    const accent = Color(0xFF4EC9B0);
    const warn = Color(0xFFE0A030);
    final violations = d.violations;
    return Container(
      key: const ValueKey('nl-diagnostics-panel'),
      width: _nlPanelWidth,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        color: _palette.canvasBg.withValues(alpha: 0.94),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.troubleshoot, size: 16, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _autoRoutes == null ? '走线诊断 · 直线预览' : '走线诊断 · 正交布线',
                  style: TextStyle(fontSize: 12, color: titleColor),
                ),
              ),
              InkWell(
                key: const ValueKey('nl-diagnostics-close'),
                onTap: () => setState(() => _diagnostics = false),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: subtleColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _diagRow('交叉', '${d.crossings}  (${d.crossingDensity.toStringAsFixed(1)}/Mpx)', bodyColor),
          _diagRow(
            '折弯',
            '${d.bends} · P95 ${d.bendP95.toStringAsFixed(0)} · max ${d.bendMax}',
            bodyColor,
          ),
          _diagRow(
            '绕行比',
            d.detour == null ? '—（团拓扑）' : d.detour!.toStringAsFixed(2),
            bodyColor,
          ),
          _diagRow('平行贴近', '${d.parallelPairs}', bodyColor),
          _diagRow(
            '密度',
            '峰值 ${(d.densityPeak * 100).toStringAsFixed(0)}%'
                ' · 热格 ${d.hotCells}',
            bodyColor,
          ),
          _diagRow(
            '端口对齐',
            '${(d.portAlignmentRate * 100).toStringAsFixed(0)}%'
                ' · 均偏 ${d.portAlignMeanDy.toStringAsFixed(1)}',
            bodyColor,
          ),
          _diagRow(
            '硬约束',
            violations.isEmpty ? '0' : '${violations.length}（${d.violationCounts.keys.join(' / ')}）',
            violations.isEmpty ? bodyColor : warn,
          ),
          if (violations.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (final v in violations.take(3))
              Text(
                '· ${v.detail}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, color: warn),
              ),
            if (violations.length > 3)
              Text(
                '· 其余 ${violations.length - 3} 项…',
                style: TextStyle(fontSize: 9.5, color: subtleColor),
              ),
          ],
        ],
      ),
    );
  }

  Widget _diagRow(String label, String value, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: color.withValues(alpha: 0.62),
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: TextStyle(fontSize: 10.5, color: color)),
        ),
      ],
    ),
  );

  Widget _buildBody(IspNodeGroup group) {
    if (_running && _nlModel == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text(
              '正在提取网表（yosys → 网表 JSON → 自研布局）…',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }
    if (_error != null && _nlModel == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFFCF6679)),
          ),
        ),
      );
    }
    final model = _nlModel;
    if (model == null) {
      return const Center(
        child: Text('尚未提取网表', style: TextStyle(color: Colors.grey)),
      );
    }
    final state = context.watch<IspStudioState>();
    final stale =
        _renderedFingerprint != null &&
        _renderedFingerprint != _groupFingerprint(state, group);
    final showLayoutPanel = _layoutOptPanelVisible;
    final showRoutingPanel = _routingOptPanelVisible;
    final showManualPanel = _editMode && _manualOptPanelVisible;
    final showInfoPanels = showLayoutPanel || showRoutingPanel;
    final leftPanelRight = showInfoPanels
        ? 12 + _nlPanelWidth + _nlPanelGap
        : 12.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stale) _buildStaleBanner(),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: NetlistDiagram(
                  key: ValueKey('nl:${model.moduleName}'),
                  model: model,
                  light: _light,
                  controller: _nlCtrl,
                  onViewport: (s) => _nlViewport = s,
                  onTapCell: _onTapCell,
                  onToggleExpand: _toggleExpand,
                  topology: _cliqueTopology
                      ? NlNetTopology.clique
                      : NlNetTopology.star,
                  heatmap: _heatmap,
                  diagnostics: _diagnostics ? _diagnosticsFor(model) : null,
                  autoRoutes: (_editMode && _editStraightPreview)
                      ? null
                      : _autoRoutes?.segments,
                  autoJunctions: (_editMode && _editStraightPreview)
                      ? null
                      : _autoRoutes?.junctions,
                  straightDashed: _editMode && _editStraightPreview,
                  editMode: _editMode,
                  onBlockDragStart: _onNlBlockDragStart,
                  onBlockDragEnd: _onNlBlockDragEnd,
                  onMirrorBlock: _onNlMirrorBlock,
                  onPinDragStart: _onNlPinDragStart,
                  onPinDragUpdate: _onNlPinDragUpdate,
                  onPinDragEnd: _onNlPinDragEnd,
                  onPortDragStart: _onNlPortDragStart,
                  onPortDragEnd: _onNlPortDragEnd,
                  onPortDragUpdate: _onNlPortDragUpdate,
                  onSegmentDragStart: _onNlSegmentDragStart,
                  onSegmentDragUpdate: _onNlSegmentDragUpdate,
                  onSegmentDragEnd: _onNlSegmentDragEnd,
                ),
              ),
              // 右侧信息区：布局在上、布线在下；两者都没有时诊断独占右上。
              // 编辑模式的手动布局窗位于信息列左侧；诊断顺位到它下方。
              if (_diagnostics || showManualPanel)
                Positioned(
                  top: 12,
                  right: leftPanelRight,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (showManualPanel)
                        _buildManualLayoutPanel(model),
                      if (showManualPanel && _diagnostics)
                        const SizedBox(height: _nlPanelGap),
                      if (_diagnostics) _buildDiagnosticsPanel(model),
                    ],
                  ),
                ),
              if (showInfoPanels)
                Positioned(
                  top: 12,
                  right: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (showLayoutPanel) _buildLayoutOptimizationPanel(),
                      if (showLayoutPanel && showRoutingPanel)
                        const SizedBox(height: _nlPanelGap),
                      if (showRoutingPanel) _buildRoutingOptimizationPanel(),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 过期提示条：编组内容或参数修改后提示重新提取。
  Widget _buildStaleBanner() {
    return Container(
      color: const Color(0xFF3A2E12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 14, color: Color(0xFFE0A030)),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '编组内容或参数已变更，当前电路图可能已过期',
              style: TextStyle(fontSize: 11, color: Color(0xFFE0A030)),
            ),
          ),
          if (!_running)
            InkWell(
              onTap: _extract,
              child: const Text(
                '重新生成',
                style: TextStyle(fontSize: 11, color: Color(0xFF4EC9B0)),
              ),
            ),
        ],
      ),
    );
  }

  /// 日志面板（与仿真/编译终端同一风格）：标题栏 + 等宽输出区。
  Widget _buildLogPanel() {
    return Container(
      color: const Color(0xFF141414),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 26,
            color: const Color(0xFF1E1E1E),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Text(
                  '提取日志',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _logVisible = false),
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: _running ? Colors.white24 : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _logScroll,
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _log.toString(),
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: ['Courier New', 'monospace'],
                  fontSize: 11,
                  height: 1.4,
                  color: Color(0xFFD4D4D4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
