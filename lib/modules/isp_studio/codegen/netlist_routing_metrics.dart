/// 数字网表走线几何诊断（纯 Dart，无 Flutter 依赖，除 `dart:ui` 的基础几何类型）。
///
/// 面向 ISP Studio「IP Generator → 电路图浏览 → RTL 网表」的**确定性**美观度
/// 评价：不含任何模型/网络调用，同一输入逐次产出同一份指标。
///
/// 指标分两层：
/// - **硬约束**（[NlViolationKind]）：穿元件、异网同轴重叠、间距不足、断口、
///   越界。违反即“错”，任何优化结果都不得以此换分数。
/// - **可读性指标**：交叉（总数/每网/密度）、折弯（均值/P50/P95/max）、
///   绕行比（实际长 / HPWL 下界）、平行贴近段、密度峰值/熵、端口对齐率。
///
/// 直线预览（[NlNetTopology]）与正交布线（`NlAutoRouteResult.segments`）共用
/// 同一套口径；折弯、绕行、硬约束只对正交布线有意义，直线预览下如实给 0/null。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../widgets/netlist_diagram.dart';

/// 硬约束违反类型。
enum NlViolationKind {
  /// 走线进入元件（或端口）符号包围区。
  throughBlock,

  /// 不同网的同轴（水平/垂直）线段重叠。
  netOverlap,

  /// 不同网的平行线段间距小于 [NlMetricsOptions.minParallelGap]。
  spacing,

  /// 走线端点没有落在任何引脚上（断口/悬空）。
  danglingEnd,

  /// 走线端点越出画布。
  outsideCanvas,
}

/// 一条硬约束违反记录。
class NlViolation {
  final NlViolationKind kind;

  /// 相关网名（重叠类记录两根，用 ` / ` 连接）。
  final String wires;

  /// 违反位置（近似；穿块取线段与块的交点，重叠取重叠段中点）。
  final Offset at;

  /// 人类可读说明（含块名/间距等）。
  final String detail;

  const NlViolation({
    required this.kind,
    required this.wires,
    required this.at,
    required this.detail,
  });

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'wires': wires,
    'x': _round3(at.dx),
    'y': _round3(at.dy),
    'detail': detail,
  };
}

/// 单网诊断。
class NlWireDiagnostics {
  final String name;
  final int bits;
  final int loads;
  final bool isBus;

  /// 该网参与的不同网交叉点数量（每个交叉点同时记到两根网）。
  final int crossings;

  /// 同网折弯点数量（排除 T/十字分支点；直线预览恒 0）。
  final int bends;

  /// 该网全部线段长度之和。
  final double length;

  /// 绕行比 = 长度 / HPWL 包围盒下界；直线预览为 null（团拓扑不是树，
  /// 该比值不可比）。
  final double? detour;

  /// 与其它网平行且贴近的线段对数。
  final int parallelPairs;

  /// 该网在本层画布坐标下的线段（诊断叠加层用；不写入 JSON）。
  final List<(Offset, Offset)> segments;

  const NlWireDiagnostics({
    required this.name,
    required this.bits,
    required this.loads,
    required this.isBus,
    required this.crossings,
    required this.bends,
    required this.length,
    required this.detour,
    required this.parallelPairs,
    required this.segments,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'bits': bits,
    'loads': loads,
    'bus': isBus,
    'crossings': crossings,
    'bends': bends,
    'length': _round3(length),
    'detour': detour == null ? null : _round3(detour!),
    'parallelPairs': parallelPairs,
  };
}

/// 诊断选项。默认值即当前工程的硬约束口径（15px Grid）。
class NlMetricsOptions {
  final double grid;

  /// 异网平行线的最小允许间距。默认一个 Grid（与历史硬约束一致）。
  final double minParallelGap;

  /// 「平行贴近段」的统计阈值（视觉成束/发糊的观察口径，3 Grid）；
  /// 与硬约束 [minParallelGap] 分开：15px 是合法间距，但仍属视觉贴近。
  final double parallelNearGap;

  /// 是否检查硬约束。正交布线默认开，直线预览默认关（团拓扑必然穿块）。
  final bool checkLegality;

  /// 密度热力图的网格边长（与 UI 热力图同口径）。
  final double densityCell;

  const NlMetricsOptions({
    this.grid = nlLayoutGrid,
    this.minParallelGap = nlLayoutGrid,
    this.parallelNearGap = 3 * nlLayoutGrid,
    this.checkLegality = true,
    this.densityCell = 24,
  });
}

/// 整图诊断报告。
class NlRoutingDiagnostics {
  /// `straight`（直线预览）或 `routed`（正交布线）。
  final String source;

  final int wireCount;

  /// 不同网交叉点数量：每对网内部按坐标去重后逐对累加。
  final int crossings;

  /// 全局去重后的交叉点（诊断叠加层用）。
  final List<Offset> crossingPoints;

  /// 交叉密度（每百万平方像素的交叉点数；0 面积记 0）。
  final double crossingDensity;

  final int bends;
  final double bendMean;
  final double bendP50;
  final double bendP95;
  final int bendMax;

  /// 全部网线段长度之和。
  final double length;

  /// 全部网 HPWL 包围盒半周长之和（树形走线的长度下界）。
  final double hpwl;

  /// 绕行比 = [length] / [hpwl]；直线预览为 null。
  final double? detour;

  /// 异网平行贴近段对数。
  final int parallelPairs;

  /// 密度峰值（0..1，与 UI 热力图同标尺）。
  final double densityPeak;

  /// 非空网格上的归一化熵（0=全挤在一格，1=完全均匀）。
  final double densityEntropy;

  /// 密度 > 0.5 的网格数。
  final int hotCells;

  /// 端口与其最近一跳引脚纵向对齐（|Δy| ≤ grid）的比例（0..1）；
  /// 每个端口只取相连引脚中的最小偏差（扇出不可能全部对齐）。
  /// 无端口连接时为 1。
  final double portAlignmentRate;

  /// 每个端口「最近一跳」纵向偏差的均值（px）：对齐率饱和后用它看槽位
  /// 冲突造成的实际位移。
  final double portAlignMeanDy;

  final Size canvas;
  final List<NlWireDiagnostics> wires;
  final List<NlViolation> violations;

  /// 热力图数据（不写入 JSON；诊断叠加层复用）。
  final NlHeatmap heatmap;

  const NlRoutingDiagnostics({
    required this.source,
    required this.wireCount,
    required this.crossings,
    required this.crossingPoints,
    required this.crossingDensity,
    required this.bends,
    required this.bendMean,
    required this.bendP50,
    required this.bendP95,
    required this.bendMax,
    required this.length,
    required this.hpwl,
    required this.detour,
    required this.parallelPairs,
    required this.densityPeak,
    required this.densityEntropy,
    required this.hotCells,
    required this.portAlignmentRate,
    required this.portAlignMeanDy,
    required this.canvas,
    required this.wires,
    required this.violations,
    required this.heatmap,
  });

  /// 违反计数（按类型）。
  Map<String, int> get violationCounts {
    final counts = <String, int>{};
    for (final v in violations) {
      counts[v.kind.name] = (counts[v.kind.name] ?? 0) + 1;
    }
    return counts;
  }

  /// 没有硬约束违反。
  bool get legal => violations.isEmpty;

  Map<String, Object?> toJson() => {
    'source': source,
    'wireCount': wireCount,
    'canvas': {
      'w': _round3(canvas.width),
      'h': _round3(canvas.height),
      'area': _round3(canvas.width * canvas.height),
    },
    'crossings': {
      'count': crossings,
      'densityPerMpx': _round3(crossingDensity),
    },
    'bends': {
      'count': bends,
      'mean': _round3(bendMean),
      'p50': _round3(bendP50),
      'p95': _round3(bendP95),
      'max': bendMax,
    },
    'length': _round3(length),
    'hpwl': _round3(hpwl),
    'detour': detour == null ? null : _round3(detour!),
    'parallelPairs': parallelPairs,
    'density': {
      'peak': _round3(densityPeak),
      'entropy': _round3(densityEntropy),
      'hotCells': hotCells,
    },
    'portAlignment': _round3(portAlignmentRate),
    'portAlignMeanDy': _round3(portAlignMeanDy),
    'violations': violationCounts,
    'violationList': [for (final v in violations) v.toJson()],
    'wires': [for (final w in wires) w.toJson()],
  };
}

/// 计算整图诊断。
///
/// - [levels]：`NetlistDiagramModel.flattened()`（含展开容器的平移）。
/// - [routes]：正交布线结果（`NlAutoRouteResult.segments`）；null = 直线预览。
/// - [junctions]：同网 T/十字分支点（用于把分支点从折弯统计中排除）。
NlRoutingDiagnostics computeNlRoutingDiagnostics(
  List<NlLevel> levels,
  Size canvasSize, {
  Map<NlWire, List<(Offset, Offset)>>? routes,
  Map<NlWire, List<Offset>>? junctions,
  NlNetTopology topology = NlNetTopology.clique,
  NlMetricsOptions options = const NlMetricsOptions(),
}) {
  final routed = routes != null;
  final geometry = <_NlWireGeometry>[];
  for (final level in levels) {
    for (final wire in level.wires) {
      final raw =
          routes?[wire] ?? nlStraightWireSegments(wire, topology);
      final offset = level.offset;
      final segments = [
        for (final (a, b) in raw)
          if ((b - a).distance > 0.01) (a + offset, b + offset),
      ];
      if (segments.isEmpty) continue;
      final pins = <Offset>[
        wire.from.pos + offset,
        for (final l in wire.loads) l.pos + offset,
      ];
      final junctionsAbs = [
        for (final j in junctions?[wire] ?? const <Offset>[]) j + offset,
      ];
      geometry.add(
        _NlWireGeometry(
          wire: wire,
          name: _wireName(wire),
          segments: segments,
          pins: pins,
          junctions: junctionsAbs,
        ),
      );
    }
  }

  // ---- 交叉：逐对网求交；每对内部按坐标去重 ----
  final crossingPairs = <(int, int), Set<(int, int)>>{};
  final crossingPoints = <(int, int), Offset>{};
  for (var i = 0; i < geometry.length; i++) {
    final a = geometry[i];
    for (var j = i + 1; j < geometry.length; j++) {
      final b = geometry[j];
      if (!_boundsNear(a.bounds, b.bounds, options.grid)) continue;
      final hits = <(int, int)>{};
      for (final sa in a.segments) {
        for (final sb in b.segments) {
          final p = _segmentIntersection(sa, sb);
          if (p == null) continue;
          final key = _pointKey(p);
          hits.add(key);
          crossingPoints.putIfAbsent(key, () => p);
        }
      }
      if (hits.isEmpty) continue;
      crossingPairs[(i, j)] = hits;
      a.crossings += hits.length;
      b.crossings += hits.length;
    }
  }

  var crossings = 0;
  for (final hits in crossingPairs.values) {
    crossings += hits.length;
  }

  // ---- 折弯 ----
  final bendCounts = <int>[];
  var bends = 0;
  for (var i = 0; i < geometry.length; i++) {
    final g = geometry[i];
    final count = routed
        ? nlRoutingBendPoints(g.segments, junctions: g.junctions).length
        : 0;
    g.bends = count;
    bendCounts.add(count);
    bends += count;
  }

  // ---- 长度 / 绕行 ----
  var length = 0.0;
  var hpwlTotal = 0.0;
  for (final g in geometry) {
    length += g.length;
    hpwlTotal += g.hpwl;
  }
  final detour = routed && hpwlTotal > 0.01 ? length / hpwlTotal : null;

  // ---- 平行贴近段 ----
  final parallel = _parallelPairs(geometry, options);

  // ---- 密度 ----
  final heatmap = computeNlHeatmap(
    levels,
    canvasSize,
    topology: topology,
    cellSize: options.densityCell,
    autoRoutes: routes,
  );
  var peak = 0.0;
  var hotCells = 0;
  var densitySum = 0.0;
  for (final v in heatmap.values) {
    peak = math.max(peak, v);
    if (v > 0.5) hotCells++;
    densitySum += v;
  }
  // 全部网格（含空格）上的归一化熵：0=全挤在一格，1=完全均匀铺开。
  var entropy = 0.0;
  if (densitySum > 0.001 && heatmap.values.length > 1) {
    var h = 0.0;
    for (final v in heatmap.values) {
      if (v <= 0) continue;
      final p = v / densitySum;
      h -= p * math.log(p);
    }
    entropy = (h / math.log(heatmap.values.length)).clamp(0.0, 1.0);
  }

  // ---- 端口对齐 ----
  // 每个端口只取「最近一跳」的最小 |Δy|：扇出端口的多个负载分布在不同行，
  // 不可能全部对齐；对齐的目标是让端口与相邻列的负载/驱动行一致。
  final portMinDy = <NlPin, double>{};
  for (final level in levels) {
    for (final wire in level.wires) {
      final from = wire.from;
      for (final load in wire.loads) {
        if (from.isPort) {
          final d = (from.pos.dy - load.pos.dy).abs();
          final cur = portMinDy[from];
          if (cur == null || d < cur) portMinDy[from] = d;
        }
        if (load.isPort) {
          final d = (load.pos.dy - from.pos.dy).abs();
          final cur = portMinDy[load];
          if (cur == null || d < cur) portMinDy[load] = d;
        }
      }
    }
  }
  final portAlignment = portMinDy.isEmpty
      ? 1.0
      : portMinDy.values
                .where((d) => d <= options.grid + 0.01)
                .length /
            portMinDy.length;
  final portAlignMeanDy = portMinDy.isEmpty
      ? 0.0
      : portMinDy.values.reduce((a, b) => a + b) / portMinDy.length;

  // ---- 硬约束（仅正交布线）----
  final violations = <NlViolation>[];
  if (routed && options.checkLegality) {
    _checkLegality(geometry, levels, canvasSize, options, violations);
  }

  final area = canvasSize.width * canvasSize.height;
  return NlRoutingDiagnostics(
    source: routed ? 'routed' : 'straight',
    wireCount: geometry.length,
    crossings: crossings,
    crossingPoints: crossingPoints.values.toList(growable: false),
    crossingDensity: area <= 0.01 ? 0 : crossings * 1e6 / area,
    bends: bends,
    bendMean: bendCounts.isEmpty ? 0 : bends / bendCounts.length,
    bendP50: _percentile(bendCounts, 0.50),
    bendP95: _percentile(bendCounts, 0.95),
    bendMax: bendCounts.isEmpty
        ? 0
        : bendCounts.reduce((a, b) => math.max(a, b)),
    length: length,
    hpwl: hpwlTotal,
    detour: detour,
    parallelPairs: parallel,
    densityPeak: peak,
    densityEntropy: entropy,
    hotCells: hotCells,
    portAlignmentRate: portAlignment,
    portAlignMeanDy: portAlignMeanDy,
    canvas: canvasSize,
    wires: [
      for (final g in geometry)
        NlWireDiagnostics(
          name: g.name,
          bits: g.wire.bits.length,
          loads: g.wire.loads.length,
          isBus: g.wire.isBus,
          crossings: g.crossings,
          bends: g.bends,
          length: g.length,
          detour: routed && g.hpwl > 0.01 ? g.length / g.hpwl : null,
          parallelPairs: g.parallelPairs,
          segments: g.segments,
        ),
    ],
    violations: violations,
    heatmap: heatmap,
  );
}

/// 诊断叠加层数据（供绘制/导出标记问题点）。
class NlDiagnosticOverlay {
  /// 交叉点（红圈）。
  final List<Offset> crossings;

  /// 折弯数超过阈值的网的线段（琥珀色加粗）。
  final List<(Offset, Offset)> longBendWires;

  /// 高密度网格（黄色半透明方块）。
  final List<Rect> hotCells;

  /// 硬约束违反位置（品红十字）。
  final List<Offset> violations;

  const NlDiagnosticOverlay({
    required this.crossings,
    required this.longBendWires,
    required this.hotCells,
    required this.violations,
  });
}

/// 生成诊断叠加层。[bendThreshold] 默认 6（长尾网高亮阈值）。
NlDiagnosticOverlay buildNlDiagnosticOverlay(
  NlRoutingDiagnostics diagnostics, {
  int bendThreshold = 6,
  double hotThreshold = 0.5,
}) {
  final hot = <Rect>[];
  final heat = diagnostics.heatmap;
  for (var row = 0; row < heat.rows; row++) {
    for (var col = 0; col < heat.columns; col++) {
      if (heat.valueAt(col, row) <= hotThreshold) continue;
      hot.add(
        Rect.fromLTWH(
          col * heat.cellSize,
          row * heat.cellSize,
          heat.cellSize,
          heat.cellSize,
        ),
      );
    }
  }
  return NlDiagnosticOverlay(
    crossings: diagnostics.crossingPoints,
    longBendWires: [
      for (final w in diagnostics.wires)
        if (w.bends >= bendThreshold) ...w.segments,
    ],
    hotCells: hot,
    violations: [for (final v in diagnostics.violations) v.at],
  );
}

/// 诊断叠加层的 SVG 片段（不含 `<svg>` 外壳；调用方插入到 `</svg>` 之前）。
///
/// 颜色固定：交叉=#FF5555，长尾网=#FFB020，高密度=#FFE066，违反=#FF00FF。
String buildNlDiagnosticOverlaySvg(
  NlRoutingDiagnostics diagnostics, {
  int bendThreshold = 6,
  double hotThreshold = 0.5,
}) {
  final overlay = buildNlDiagnosticOverlay(
    diagnostics,
    bendThreshold: bendThreshold,
    hotThreshold: hotThreshold,
  );
  final b = StringBuffer('<g id="nl-diagnostics">\n');
  for (final cell in overlay.hotCells) {
    b.writeln(
      '  <rect x="${_n(cell.left)}" y="${_n(cell.top)}" '
      'width="${_n(cell.width)}" height="${_n(cell.height)}" '
      'fill="#FFE066" fill-opacity="0.22"/>',
    );
  }
  for (final (a, c) in overlay.longBendWires) {
    b.writeln(
      '  <line x1="${_n(a.dx)}" y1="${_n(a.dy)}" '
      'x2="${_n(c.dx)}" y2="${_n(c.dy)}" '
      'stroke="#FFB020" stroke-width="2.2" stroke-opacity="0.55"/>',
    );
  }
  for (final p in overlay.crossings) {
    b.writeln(
      '  <circle cx="${_n(p.dx)}" cy="${_n(p.dy)}" r="3.2" '
      'fill="none" stroke="#FF5555" stroke-width="1.2"/>',
    );
  }
  for (final p in overlay.violations) {
    b.writeln(
      '  <path d="M ${_n(p.dx - 4)} ${_n(p.dy)} H ${_n(p.dx + 4)} '
      'M ${_n(p.dx)} ${_n(p.dy - 4)} V ${_n(p.dy + 4)}" '
      'stroke="#FF00FF" stroke-width="1.4"/>',
    );
  }
  b.writeln('</g>');
  return b.toString();
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

/// 单网几何（绝对画布坐标）。
class _NlWireGeometry {
  final NlWire wire;
  final String name;
  final List<(Offset, Offset)> segments;
  final List<Offset> pins;
  final List<Offset> junctions;

  late final Rect bounds = _boundsOf(segments);

  /// 全部网线的包围盒半周长（HPWL 下界）；单点/空集为 0。
  late final double hpwl = _hpwlOf(pins);

  late final double length = segments.fold<double>(
    0,
    (sum, s) => sum + (s.$2 - s.$1).distance,
  );

  int crossings = 0;
  int bends = 0;
  int parallelPairs = 0;

  _NlWireGeometry({
    required this.wire,
    required this.name,
    required this.segments,
    required this.pins,
    required this.junctions,
  });
}

Rect _boundsOf(List<(Offset, Offset)> segments) {
  if (segments.isEmpty) return Rect.zero;
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final (a, b) in segments) {
    for (final p in [a, b]) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

double _hpwlOf(List<Offset> pins) {
  if (pins.length < 2) return 0;
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pins) {
    minX = math.min(minX, p.dx);
    minY = math.min(minY, p.dy);
    maxX = math.max(maxX, p.dx);
    maxY = math.max(maxY, p.dy);
  }
  return (maxX - minX) + (maxY - minY);
}

bool _boundsNear(Rect a, Rect b, double margin) {
  if (a == Rect.zero || b == Rect.zero) return true;
  return a.inflate(margin).overlaps(b.inflate(margin));
}

/// 两线段交点；平行/共线返回 null（共线重叠由硬约束单独检查）。
Offset? _segmentIntersection((Offset, Offset) s1, (Offset, Offset) s2) {
  final p = s1.$1;
  final q = s2.$1;
  final r = s1.$2 - p;
  final s = s2.$2 - q;
  final denom = r.dx * s.dy - r.dy * s.dx;
  if (denom.abs() < 1e-9) return null;
  final qp = q - p;
  final t = (qp.dx * s.dy - qp.dy * s.dx) / denom;
  final u = (qp.dx * r.dy - qp.dy * r.dx) / denom;
  const eps = 1e-6;
  if (t < -eps || t > 1 + eps || u < -eps || u > 1 + eps) return null;
  return p + r * t;
}

(int, int) _pointKey(Offset p) => ((p.dx * 100).round(), (p.dy * 100).round());

String _wireName(NlWire wire) {
  if (wire.label.isNotEmpty) return wire.label;
  final owner = wire.from.ownerTitle;
  return owner.isEmpty ? wire.from.port : '$owner.${wire.from.port}';
}

/// 平行贴近段对数（只统计水平/垂直；异网；间距 > 0 且 < [parallelNearGap]）。
int _parallelPairs(List<_NlWireGeometry> geometry, NlMetricsOptions options) {
  var count = 0;
  final gap = options.parallelNearGap;
  for (var i = 0; i < geometry.length; i++) {
    final a = geometry[i];
    for (var j = i + 1; j < geometry.length; j++) {
      final b = geometry[j];
      if (!_boundsNear(a.bounds, b.bounds, gap + options.grid)) continue;
      for (final sa in a.segments) {
        final oa = _orientation(sa);
        if (oa == 0) continue;
        for (final sb in b.segments) {
          if (_orientation(sb) != oa) continue;
          if (!_parallelClose(sa, sb, gap)) continue;
          count++;
          a.parallelPairs++;
          b.parallelPairs++;
        }
      }
    }
  }
  return count;
}

/// 1=水平，2=垂直，0=斜线。
int _orientation((Offset, Offset) s) {
  final dx = (s.$2.dx - s.$1.dx).abs();
  final dy = (s.$2.dy - s.$1.dy).abs();
  if (dy < 0.01 && dx >= 0.01) return 1;
  if (dx < 0.01 && dy >= 0.01) return 2;
  return 0;
}

bool _parallelClose((Offset, Offset) a, (Offset, Offset) b, double gap) {
  final axis = _orientation(a) == 1 ? 1 : 0; // 1=按 y 比较，0=按 x 比较
  final d = axis == 1 ? (a.$1.dy - b.$1.dy).abs() : (a.$1.dx - b.$1.dx).abs();
  if (d <= 0.01 || d >= gap - 0.01) return false;
  final aLo = axis == 1
      ? math.min(a.$1.dx, a.$2.dx)
      : math.min(a.$1.dy, a.$2.dy);
  final aHi = axis == 1
      ? math.max(a.$1.dx, a.$2.dx)
      : math.max(a.$1.dy, a.$2.dy);
  final bLo = axis == 1
      ? math.min(b.$1.dx, b.$2.dx)
      : math.min(b.$1.dy, b.$2.dy);
  final bHi = axis == 1
      ? math.max(b.$1.dx, b.$2.dx)
      : math.max(b.$1.dy, b.$2.dy);
  return math.min(aHi, bHi) - math.max(aLo, bLo) > 1.0;
}

void _checkLegality(
  List<_NlWireGeometry> geometry,
  List<NlLevel> levels,
  Size canvas,
  NlMetricsOptions options,
  List<NlViolation> out,
) {
  // ---- 穿元件（含端口符号区） ----
  for (final level in levels) {
    for (final block in level.blocks) {
      if (block.boxSize.isEmpty) continue;
      final rect = Rect.fromLTWH(
        block.boxOrigin.dx + level.offset.dx,
        block.boxOrigin.dy + level.offset.dy,
        block.boxSize.width,
        block.boxSize.height,
      ).deflate(0.5);
      if (rect.width <= 0 || rect.height <= 0) continue;
      for (final g in geometry) {
        for (final (a, b) in g.segments) {
          final hit = _clipSegmentToRect(a, b, rect);
          if (hit == null) continue;
          out.add(
            NlViolation(
              kind: NlViolationKind.throughBlock,
              wires: g.name,
              at: hit,
              detail: '走线穿入元件 ${block.title.isEmpty ? block.id : block.title}',
            ),
          );
          break;
        }
      }
    }
  }

  // ---- 异网同轴重叠 / 间距不足 ----
  const eps = 0.01;
  for (var i = 0; i < geometry.length; i++) {
    final a = geometry[i];
    for (var j = i + 1; j < geometry.length; j++) {
      final b = geometry[j];
      if (!_boundsNear(a.bounds, b.bounds, options.minParallelGap)) continue;
      for (final sa in a.segments) {
        final oa = _orientation(sa);
        if (oa == 0) continue;
        for (final sb in b.segments) {
          if (_orientation(sb) != oa) continue;
          final along = oa == 1 ? 0 : 1; // 水平段沿 x，垂直段沿 y
          final perpendicular = oa == 1 ? 1 : 0;
          final d = perpendicular == 1
              ? (sa.$1.dy - sb.$1.dy).abs()
              : (sa.$1.dx - sb.$1.dx).abs();
          final aLo = along == 0
              ? math.min(sa.$1.dx, sa.$2.dx)
              : math.min(sa.$1.dy, sa.$2.dy);
          final aHi = along == 0
              ? math.max(sa.$1.dx, sa.$2.dx)
              : math.max(sa.$1.dy, sa.$2.dy);
          final bLo = along == 0
              ? math.min(sb.$1.dx, sb.$2.dx)
              : math.min(sb.$1.dy, sb.$2.dy);
          final bHi = along == 0
              ? math.max(sb.$1.dx, sb.$2.dx)
              : math.max(sb.$1.dy, sb.$2.dy);
          final overlap = math.min(aHi, bHi) - math.max(aLo, bLo);
          if (overlap <= eps) continue;
          final mid = (math.max(aLo, bLo) + math.min(aHi, bHi)) / 2;
          final at = oa == 1
              ? Offset(mid, (sa.$1.dy + sb.$1.dy) / 2)
              : Offset((sa.$1.dx + sb.$1.dx) / 2, mid);
          if (d <= eps) {
            out.add(
              NlViolation(
                kind: NlViolationKind.netOverlap,
                wires: '${a.name} / ${b.name}',
                at: at,
                detail: '异网同轴重叠 ${_round3(overlap)}px',
              ),
            );
          } else if (d < options.minParallelGap - eps) {
            out.add(
              NlViolation(
                kind: NlViolationKind.spacing,
                wires: '${a.name} / ${b.name}',
                at: at,
                detail: '异网平行间距 ${_round3(d)}px < ${options.minParallelGap}px',
              ),
            );
          }
        }
      }
    }
  }

  // ---- 断口 / 越界 ----
  final canvasRect = Rect.fromLTWH(0, 0, canvas.width, canvas.height)
      .inflate(options.grid);
  for (final g in geometry) {
    final endpoints = <Offset>[];
    for (final (a, b) in g.segments) {
      endpoints
        ..add(a)
        ..add(b);
    }
    for (final pin in g.pins) {
      final attached = endpoints.any((e) => (e - pin).distance < 0.01);
      if (attached) continue;
      out.add(
        NlViolation(
          kind: NlViolationKind.danglingEnd,
          wires: g.name,
          at: pin,
          detail: '引脚没有走线端点连接',
        ),
      );
    }
    for (final p in endpoints) {
      if (canvasRect.contains(p)) continue;
      out.add(
        NlViolation(
          kind: NlViolationKind.outsideCanvas,
          wires: g.name,
          at: p,
          detail: '走线端点越出画布',
        ),
      );
    }
  }
}

/// 线段与矩形内部相交时的交点（取线段进入点）；不相交返回 null。
Offset? _clipSegmentToRect(Offset a, Offset b, Rect rect) {
  final d = b - a;
  var t0 = 0.0;
  var t1 = 1.0;
  bool clip(double p, double q) {
    if (p.abs() < 1e-9) return q >= -1e-9;
    final r = q / p;
    if (p < 0) {
      if (r > t1) return false;
      if (r > t0) t0 = r;
    } else {
      if (r < t0) return false;
      if (r < t1) t1 = r;
    }
    return true;
  }

  if (!clip(-d.dx, a.dx - rect.left)) return null;
  if (!clip(d.dx, rect.right - a.dx)) return null;
  if (!clip(-d.dy, a.dy - rect.top)) return null;
  if (!clip(d.dy, rect.bottom - a.dy)) return null;
  if (t1 - t0 < 1e-6) return null;
  return a + d * ((t0 + t1) / 2);
}

/// 最近秩百分位（0..100 的输入用 0..1 表示）。
double _percentile(List<int> values, double p) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  final rank = (p * (sorted.length - 1)).round().clamp(0, sorted.length - 1);
  return sorted[rank].toDouble();
}

double _round3(double v) => (v * 1000).round() / 1000;

String _n(double v) {
  final r = _round3(v);
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

/// 增量布线指标：按“单网增删/替换”维护交叉、折弯、长度与 P95。
///
/// 全量 [nlRoutingMetrics] 每次重算所有网对的交点；候选只改动少量网时，
/// 这里只重算该网与其余网的交叉，其余贡献保持不变。口径与全量完全一致
/// （同一 `_segmentIntersection`、同一按坐标去重的每对计数），可用
/// [snapshot] 直接替换 `nlRoutingMetrics` 的结果。
///
/// 复杂度：一次 [upsert] 为 O(该网段数 × 其余网段数)，k 个网变化时约为
/// 全量的 k/网数；适合“移动一个块只影响少数网”的迭代评估。
class NlIncrementalRouteMetrics {
  final Map<int, List<(Offset, Offset)>> _segments = {};
  final Map<int, int> _bends = {};
  final Map<int, double> _lengths = {};
  final Map<(int, int), int> _pairCrossings = {};
  int _crossings = 0;
  double _length = 0;

  Iterable<int> get wireIds => _segments.keys;
  bool contains(int id) => _segments.containsKey(id);
  int get crossings => _crossings;
  double get length => _length;

  /// 新增或替换一条网的几何；`junctions` 为同网 T/十字分支点。
  void upsert(
    int id,
    List<(Offset, Offset)> segments, {
    List<Offset> junctions = const [],
  }) {
    remove(id);
    final copy = List<(Offset, Offset)>.unmodifiable(segments);
    _segments[id] = copy;
    _bends[id] = nlRoutingBendPoints(copy, junctions: junctions).length;
    final length = copy.fold<double>(
      0,
      (sum, s) => sum + (s.$2 - s.$1).distance,
    );
    _lengths[id] = length;
    _length += length;
    for (final other in _segments.keys) {
      if (other == id) continue;
      final count = _crossingCount(copy, _segments[other]!);
      if (count == 0) continue;
      final key = id < other ? (id, other) : (other, id);
      _pairCrossings[key] = count;
      _crossings += count;
    }
  }

  /// 删除一条网及其全部交叉贡献。
  void remove(int id) {
    if (_segments.remove(id) == null) return;
    _bends.remove(id);
    _length -= _lengths.remove(id) ?? 0;
    final keys = [
      for (final key in _pairCrossings.keys)
        if (key.$1 == id || key.$2 == id) key,
    ];
    for (final key in keys) {
      _crossings -= _pairCrossings.remove(key)!;
    }
  }

  /// 当前指标快照（可直接与 `nlRoutingMetrics` 比较）。
  NlRoutingMetrics snapshot() {
    final counts = _bends.values.toList()..sort();
    final totalBends = counts.fold<int>(0, (sum, b) => sum + b);
    final p95 = counts.isEmpty
        ? 0.0
        : counts[(0.95 * (counts.length - 1)).round()].toDouble();
    return NlRoutingMetrics(
      crossings: _crossings,
      bends: totalBends,
      length: _length,
      bendP95: p95,
    );
  }
}

/// 两条网之间的交叉点数（每对按坐标去重）。
int _crossingCount(
  List<(Offset, Offset)> a,
  List<(Offset, Offset)> b,
) {
  final points = <(int, int)>{};
  for (final sa in a) {
    for (final sb in b) {
      final p = _segmentIntersection(sa, sb);
      if (p != null) points.add(_pointKey(p));
    }
  }
  return points.length;
}
