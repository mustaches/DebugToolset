/// 自研 RTL 网表电路图：由 [NetlistModule]（yosys 网表模型）分层布局并
/// 绘制成 Vivado Elaborated Design 版式的电路图——端口五边形符号、RTL
/// 标准单元符号（异形逻辑门/梯形 MUX/带时钟三角的 DFF/IEC 运算符框）、
/// 实例名在上/类型在下/针脚名带位宽/针脚短线接实际轮廓、**直线连线预览**
/// （默认团拓扑，可切星形）、悬停网名标注、常量引脚直接标常量值、总线加粗。
///
/// 与旧链路（yosys → netlistsvg/ELK → SVG → flutter_svg + SVG 命中模型）
/// 的差别：布局与绘制全在 Dart 侧，不依赖 Node/ELK/SVG；单元可悬停高亮
/// 其相连网络、可点击（子模块实例下钻 / 逻辑单元跳源码行）；导出 SVG/PNG
/// 复用同一布局模型，所见即所得。
library;

import 'dart:io' as io show Platform;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../codegen/netlist_channel_router.dart';
import '../codegen/netlist_layered_layout.dart';
import '../codegen/netlist_model.dart';
import '../codegen/netlist_routing_metrics.dart';
import '../codegen/netlist_symbols.dart';
import 'ip_block_diagram.dart' show SchPalette, schFitView;

/// 统一布局网格：pin、连接点与块边缘全部落在 15px 整数倍上。
const nlLayoutGrid = 15.0;
const _kGrid = nlLayoutGrid;
double _gridCeil(double v) => (v / _kGrid).ceil() * _kGrid;
double _gridFloor(double v) => (v / _kGrid).floor() * _kGrid;
double _gridRound(double v) => (v / _kGrid).round() * _kGrid;

/// 网表图布局常量。10px 字体连同上下行距至少需要 20px 行高；
/// 行高与留白均为 Grid 的整数倍，避免文字裁切并维持连接点对齐。
const _kPinRowH = 2 * _kGrid;
const _kPinPadV = _kGrid;
const _kPinPadH = 5.0;

/// 元件 pin 的强制外延伸：符号轮廓 → `pos` 先沿 pin 方向直行一个 Grid，
/// 彩色直线只从 `pos` 向外画，不得进入符号轮廓。
const _kStub = _kGrid;

/// 展开容器的留白：顶部标题带 + 左右边缘针脚区 + 底部余量。
const _kContainerHead = 2 * _kGrid;
const _kContainerPadX = 2 * _kGrid;
const _kContainerPadY = 2 * _kGrid;

/// 列间让位：保持针脚短线与相邻列块体之间的最小间距。
const _kStubClear = _kGrid;
const _kMinBlockW = 10 * _kGrid;
const _kMaxBlockW = 24 * _kGrid;
const _kColGap = 3 * _kGrid;

/// 列间通道宽度：基础 3 Grid，每多一条跨列网再加 1 Grid，封顶 8 条。
double nlChannelGap(int crossingNets) =>
    _kColGap + math.min(crossingNets, 8) * _kGrid;

/// 上下元件之间至少留出 5 条 15px 网格走线的空间；布局多留 2 Grid，
/// 供自动优化布线在不改变列内顺序的前提下上下微调元件。
const _kRowGap = 7 * _kGrid;
const _kMargin = 2 * _kGrid;
const _kPortGlyphH = _kGrid;
const _kPortGlyphW = 3 * _kGrid;
const _kPortTextGap = _kGrid;
const _kPlus = _kGrid;
const _kBoxBorder = 0.5;

/// 网表图中的一个块（单元或端口组）。
class NlBlock {
  /// 单元名（yosys）；端口组为 `#in`/`#out`。
  final String id;

  /// 符号内顶部文字（单元实例名 / 空）。
  final String title;

  /// 符号内底部文字（类型短名 / 空）。
  final String subtitle;

  final bool isIo;
  final bool isInput;

  /// 引用的网表单元（端口组为 null）。
  final NetlistCell? cell;

  final List<NlPin> ins;
  final List<NlPin> outs;

  /// 布局：列（拓扑层级，输入 -1、输出 max+1）、行、位置尺寸。
  int column = 0;
  int row = 0;
  Offset origin = Offset.zero;
  Offset boxOrigin = Offset.zero;
  Size boxSize = Size.zero;
  Size size = Size.zero;

  /// ---- 针脚样式（布局/布线优化可改写）----
  /// 针脚坐标由 [nlLayoutBlockPins] 按这些字段重排；模型构建时由
  /// mirroredBlocks/pinOrders 初始化，布线优化的镜像/引脚交换试探直接改写。
  /// 上下镜像：输入/输出槽位上下反转、顶↔底针脚互换。
  bool pinFlip = false;

  /// 左/右/上/下各边针脚槽位序（端口名；null = 声明序）。
  List<String>? inPinOrder;
  List<String>? outPinOrder;
  List<String>? topPinOrder;
  List<String>? bottomPinOrder;

  NlBlock({
    required this.id,
    required this.title,
    required this.subtitle,
    this.isIo = false,
    this.isInput = true,
    this.cell,
    this.ins = const [],
    this.outs = const [],
  });

  /// ---- 层级「原位展开」（Vivado 风格）----
  /// 展开后的容器：内部子模型（null = 折叠或非实例）。
  NetlistDiagramModel? sub;

  /// 子模型在容器内的平移（已含外框与针脚区留白）。
  Offset subOffset = Offset.zero;

  /// 容器外框尺寸（= [boxSize]）；子模型整体平移后绘制于其中。
  bool get isContainer => sub != null;

  /// 展开容器时可直接使用的内层命中信息（浅层缓存，绘制/命中遍历用）。
  List<NlWire> get subWires => sub?.wires ?? const [];

  /// 容器边缘针脚 → 子模块端口 的连接短线。
  final List<(Offset, Offset)> subLinks = [];
}

/// 一层网/针脚（含该层相对画布原点的平移）——供绘制与命中测试遍历
/// 展开容器内部的层级。
class NlLevel {
  final List<NlBlock> blocks;
  final List<NlWire> wires;
  final List<NlPin> pins;
  final List<NlPin> ports;
  final Offset offset;

  const NlLevel({
    required this.blocks,
    required this.wires,
    required this.pins,
    required this.ports,
    required this.offset,
  });
}

/// 块针脚（含显示名、位宽、是否常量/总线）。
class NlPin {
  /// yosys 端口名。
  final String port;

  /// 显示名（端口名 + 位宽范围）。
  final String display;

  final int width;
  final bool isBus;

  /// 该引脚接的常量值文本（非常量引脚为 null）。
  final String? constText;

  /// 该引脚连的网名列表（用于连线标注；常量引脚为空）。
  final List<String> netNames;

  /// 该引脚涉及的比特（网线与位域分解用）。
  final List<int> bits;

  /// 引脚内的真实网段（名称、位段范围和对应比特；用于拆分单比特/总线）。
  final List<NetlistNet> nets;

  /// 方向（输入/输出/双向）。
  final NetlistPortDir dir;

  /// 是否为顶层端口针脚（端口符号 + 名称在符号外侧 + 方向标注）。
  final bool isPort;

  /// 输入端口（端口符号朝向用；输出/双向为 false）。
  bool get isPortInput => isPort && dir == NetlistPortDir.input;

  /// 属主块标题（网名派生用：`<实例>_<端口>`）。
  String ownerTitle = '';

  /// 针脚节点 / 块边缘点（布局期填充）。
  Offset pos = Offset.zero;
  Offset edge = Offset.zero;

  NlPin({
    required this.port,
    required this.display,
    required this.width,
    required this.bits,
    this.nets = const [],
    this.isBus = false,
    this.constText,
    this.netNames = const [],
    this.dir = NetlistPortDir.input,
    this.isPort = false,
  });
}

/// 网表图的一条**网**：一个驱动引脚 → 它的全部负载引脚。
///
/// 直线预览按拓扑直接连接 [from] 与各 [loads]（团=全对、星形=到质心），
/// 不再保存正交走线段。
class NlWire {
  /// 驱动引脚。
  final NlPin from;

  /// 该网的全部负载引脚（顺序稳定：按块列/行序）。
  final List<NlPin> loads;

  /// 整网的可读名（悬停/导出时标注）。
  final String label;

  /// 该网实际承载的比特；线宽只由这个集合的位数决定。
  final List<int> bits;
  final bool isBus;

  NlWire(this.from, this.loads, this.label, {required this.bits})
    : isBus = bits.length > 1;

  /// 该网是否涉及某块（悬停高亮用：驱动块或任一负载块）。
  bool touches(NlBlock b) =>
      b.outs.contains(from) || loads.any((l) => b.ins.contains(l));
}

/// 常量参数文本的 x 坐标：左侧 pin 放到标记左侧，避免文本进入元件块；
/// 右侧及底边 pin 仍放在标记右侧。Canvas 与 SVG 共用。
double nlConstLabelX(NlPin p, double textWidth) =>
    p.pos.dx < p.edge.dx ? p.pos.dx - 13 - textWidth : p.pos.dx + 13;

/// 常量标记的气泡文本：第一行按 MSB→LSB 列出各段 pin 位域，
/// 第二行按相同顺序列出常量值；单段常量同样保持两行格式。
String nlConstTooltip(NlPin p) {
  if (p.constText == null) return '';
  if (p.nets.isEmpty) return p.constText!;
  final ranges = <String>[];
  final values = <String>[];
  var offset = 0;
  for (final net in p.nets) {
    final lo = offset;
    final hi = offset + net.bits.length - 1;
    ranges.add(lo == hi ? '[$lo]' : '[$hi:$lo]');
    values.add(net.name);
    offset += net.bits.length;
  }
  return '${ranges.reversed.join(' ')}\n${values.reversed.join(' | ')}';
}

/// 网表图模型（块 + 网 + 画布尺寸）。
class NetlistDiagramModel {
  final List<NlBlock> blocks;
  final List<NlWire> wires;
  final Size canvasSize;

  /// 模块名与规模统计（状态栏显示）。
  final String moduleName;
  final int cellCount;

  const NetlistDiagramModel({
    required this.blocks,
    required this.wires,
    required this.canvasSize,
    required this.moduleName,
    required this.cellCount,
  });

  /// 展开容器后的**层级扁平化**：本层 + 各展开容器内部的层（含平移）。
  /// 绘制与命中测试按层遍历即可，无需了解层级细节。
  List<NlLevel> flattened() {
    final out = <NlLevel>[];
    void walk(NetlistDiagramModel m, Offset off, int depth) {
      out.add(
        NlLevel(
          blocks: m.blocks,
          wires: m.wires,
          pins: [
            for (final b in m.blocks)
              if (!b.isIo) ...[...b.ins, ...b.outs],
          ],
          ports: [
            for (final b in m.blocks)
              if (b.isIo) ...[...b.ins, ...b.outs],
          ],
          offset: off,
        ),
      );
      if (depth <= 0) return;
      for (final b in m.blocks) {
        final s = b.sub;
        if (s == null) continue;
        walk(s, off + b.boxOrigin + b.subOffset, depth - 1);
      }
    }

    walk(this, Offset.zero, 6);
    return out;
  }

  /// 所有块（含展开容器内部的块），按层序。
  List<NlBlock> allBlocksRecursive() {
    final out = <NlBlock>[];
    void walk(NetlistDiagramModel m, int depth) {
      out.addAll(m.blocks);
      if (depth <= 0) return;
      for (final b in m.blocks) {
        final s = b.sub;
        if (s != null) walk(s, depth - 1);
      }
    }

    walk(this, 6);
    return out;
  }
}

/// **直线连线预览**的超边拓扑：团=同一网的所有 pin 两两相连；
/// 星形=各 pin 连到该网 pin 的质心。
enum NlNetTopology { star, clique }

/// 列分配算法：`compact` 为历史 BFS+等比压列；`layered` 为分层布局
/// （切回边 → 最长路径 → DP 压列 → 中位数排序），实验特性。
enum NlLayoutAlgorithm { compact, layered }

/// 构建网表图模型：单次确定性布局（BFS 分层 → 列内排序 → 块/针脚几何），
/// 不做任何正交布线与多轮优化——RTL 视图直接按 [NlNetTopology] 画直线。
NetlistDiagramModel buildNetlistDiagramModel(
  NetlistModule module, {
  int? columns,
  Set<String> expanded = const {},
  NetlistModule? Function(String cellType)? resolve,
  String idPrefix = '',
  int depth = 0,
  Map<int, List<String>> rowOrders = const {},
  Set<String> mirroredBlocks = const {},
  Map<String, List<String>> pinOrders = const {},
  NlLayoutAlgorithm layout = NlLayoutAlgorithm.compact,
  Map<int, int> columnGapExtra = const {},
}) {
  return _buildNetlistDiagramModelOnce(
    module,
    columns: columns,
    expanded: expanded,
    resolve: resolve,
    idPrefix: idPrefix,
    depth: depth,
    rowOrders: rowOrders,
    mirroredBlocks: mirroredBlocks,
    pinOrders: pinOrders,
    layout: layout,
    columnGapExtra: columnGapExtra,
  );
}

/// 布局目标：总直线长度 + 长线惩罚（跨列跨度/超长线）。
///
/// [longWireWeight] 为 0 时与历史口径完全一致；全局重排容易把相连块拉得很远，
/// 用该惩罚压住“横穿整图”的长线。
double nlLayoutScore(
  NetlistDiagramModel model, {
  NlNetTopology topology = NlNetTopology.clique,
  double longWireWeight = 0,
  double longWireThreshold = 600,
}) {
  var score = nlStraightLength(model, topology: topology);
  if (longWireWeight <= 0) return score;
  final pinColumn = <NlPin, int>{};
  for (final b in model.blocks) {
    for (final p in [...b.ins, ...b.outs]) {
      pinColumn[p] = b.column;
    }
  }
  for (final w in model.wires) {
    var length = 0.0;
    var minCol = pinColumn[w.from] ?? 0;
    var maxCol = minCol;
    for (final l in w.loads) {
      length += (l.pos - w.from.pos).distance;
      final c = pinColumn[l] ?? minCol;
      if (c < minCol) minCol = c;
      if (c > maxCol) maxCol = c;
    }
    if (length > longWireThreshold) {
      score += (length - longWireThreshold) * longWireWeight;
    }
    final span = maxCol - minCol;
    if (span > 4) score += (span - 4) * _kGrid * longWireWeight * 2;
  }
  return score;
}

/// 总直线长度（团=同网全对相连；星形=各 pin 到质心），布局优化目标函数。
double nlStraightLength(
  NetlistDiagramModel model, {
  NlNetTopology topology = NlNetTopology.clique,
}) {
  var total = 0.0;
  for (final w in model.wires) {
    for (final (a, b) in nlStraightWireSegments(w, topology)) {
      total += (b - a).distance;
    }
  }
  return total;
}

/// 走线密度热力图数据：按 [cellSize] 网格累计直线走线长度，归一化到 0..1。
class NlHeatmap {
  final int columns;
  final int rows;
  final double cellSize;
  final Size canvasSize;
  final List<double> values;

  const NlHeatmap({
    required this.columns,
    required this.rows,
    required this.cellSize,
    required this.canvasSize,
    required this.values,
  });

  double valueAt(int column, int row) => values[row * columns + column];
}

/// 统计当前直线走线的密度：每条直线按步长采样，把长度累加到所在网格。
///
/// 一格内叠满 [_kHeatFullWires] 根走线即为密度 1（红）。
const _kHeatFullWires = 8;

/// A* 每次转弯的代价（单位：一格）。从 0.6 提到 3.0 后，真实 39 网单趟布线
/// 折弯 153→143（P95 10→9）、交叉 115→109、平行贴近段 96→85，总长不变；
/// 再提到 6.0 会让交叉回升到 115，故取 3.0。只影响路径形状，不放松任何
/// 占用/间距约束。
const _kNlTurnCost = 3.0;

/// 异网在同一个格点拐弯的惩罚（原来 500 会把线逼出小 U 形绕行）。
const _kNlBendCost = 50.0;

/// A* 与其它网平行贴行的软惩罚：1 Grid 内/2 Grid 内。
const _kNlParallelNear = 0.45;
const _kNlParallelFar = 0.15;

NlHeatmap computeNlHeatmap(
  List<NlLevel> levels,
  Size canvasSize, {
  NlNetTopology topology = NlNetTopology.clique,
  double cellSize = 24,
  Map<NlWire, List<(Offset, Offset)>>? autoRoutes,
}) {
  final columns = math.max(1, (canvasSize.width / cellSize).ceil());
  final rows = math.max(1, (canvasSize.height / cellSize).ceil());
  final raw = List<double>.filled(columns * rows, 0);
  for (final level in levels) {
    for (final wire in level.wires) {
      final routes = autoRoutes?[wire];
      final segments = routes == null
          ? [
              for (final (a, b) in nlStraightWireSegments(wire, topology))
                (a + level.offset, b + level.offset),
            ]
          : [for (final (a, b) in routes) (a + level.offset, b + level.offset)];
      for (final (a, b) in segments) {
        final length = (b - a).distance;
        if (length < 0.01) continue;
        final steps = math.max(1, (length / (cellSize / 2)).ceil());
        final weight = length / steps;
        for (var i = 0; i <= steps; i++) {
          final t = i / steps;
          final p = Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
          final col = (p.dx / cellSize).floor().clamp(0, columns - 1);
          final row = (p.dy / cellSize).floor().clamp(0, rows - 1);
          raw[row * columns + col] += weight;
        }
      }
    }
  }
  // 绝对密度标尺 + 平方根压缩：一格内叠满 _kHeatFullWires 根走线（走线长度
  // ≈ 根数 × cellSize）即为最热（红）；单根走线只到蓝绿色。相对归一化
  // （除以最热格）在稀疏小图上会把每格都拉成 ≈1 而整片爆红，故不用。
  final reference = _kHeatFullWires * cellSize;
  final values = [
    for (final value in raw) math.sqrt((value / reference).clamp(0.0, 1.0)),
  ];
  return NlHeatmap(
    columns: columns,
    rows: rows,
    cellSize: cellSize,
    canvasSize: canvasSize,
    values: values,
  );
}

/// 密度 0..1 → 蓝→青→绿→黄→红（越红越密）。
Color nlHeatColor(double value) {
  final t = value.clamp(0.0, 1.0);
  final hue = 240 * (1 - t);
  return HSVColor.fromAHSV(0.18 + 0.45 * t, hue, 0.88, 1.0).toColor();
}

/// 走线密度热力图绘制层（半透明覆盖在网线之上、元件块之下）。
class NetlistHeatmapPainter extends CustomPainter {
  final NlHeatmap heatmap;

  const NetlistHeatmapPainter(this.heatmap);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final cell = heatmap.cellSize;
    for (var row = 0; row < heatmap.rows; row++) {
      for (var col = 0; col < heatmap.columns; col++) {
        final value = heatmap.valueAt(col, row);
        if (value < 0.03) continue;
        paint.color = nlHeatColor(value);
        canvas.drawRect(
          Rect.fromLTWH(col * cell, row * cell, cell, cell),
          paint,
        );
      }
    }
    _paintLegend(canvas, size);
  }

  void _paintLegend(Canvas canvas, Size size) {
    const chipWidth = 128.0;
    const chipHeight = 30.0;
    final left = math.max(8.0, size.width - chipWidth - 12);
    final top = math.max(8.0, size.height - chipHeight - 12);
    final chip = Rect.fromLTWH(left, top, chipWidth, chipHeight);
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, const Radius.circular(4)),
      Paint()..color = const Color(0xCC1E1E1E),
    );
    final bar = Rect.fromLTWH(left + 8, top + 7, chipWidth - 16, 8);
    final steps = math.max(2, (bar.width / 6).ceil());
    for (var i = 0; i < steps; i++) {
      final t = i / (steps - 1);
      canvas.drawRect(
        Rect.fromLTWH(
          bar.left + bar.width * i / steps,
          bar.top,
          bar.width / steps + 0.5,
          bar.height,
        ),
        Paint()..color = nlHeatColor(t),
      );
    }
    void label(String text, double x, TextAlign align) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(fontSize: 8.5, color: Colors.white70),
        ),
        textDirection: TextDirection.ltr,
        textAlign: align,
      )..layout();
      tp.paint(canvas, Offset(x, bar.bottom + 3));
    }

    label('低', bar.left, TextAlign.left);
    label('走线密度', bar.center.dx - 22, TextAlign.center);
    label('高', bar.right - 10, TextAlign.left);
  }

  @override
  bool shouldRepaint(NetlistHeatmapPainter old) =>
      !identical(old.heatmap, heatmap);
}

/// 走线诊断叠加层：交叉点红圈、长尾网琥珀加粗、高密度格淡黄、硬约束品红。
///
/// 与 `buildNlDiagnosticOverlaySvg` 同一份数据（页内与导出所见一致）。
class NetlistDiagnosticPainter extends CustomPainter {
  final NlRoutingDiagnostics diagnostics;

  const NetlistDiagnosticPainter(this.diagnostics);

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = buildNlDiagnosticOverlay(diagnostics);
    if (overlay.hotCells.isNotEmpty) {
      final fill = Paint()..color = const Color(0x30FFE066);
      for (final r in overlay.hotCells) {
        canvas.drawRect(r, fill);
      }
    }
    if (overlay.longBendWires.isNotEmpty) {
      final amber = Paint()
        ..color = const Color(0x8CFFB020)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      for (final (a, b) in overlay.longBendWires) {
        canvas.drawLine(a, b, amber);
      }
    }
    if (overlay.crossings.isNotEmpty) {
      final red = Paint()
        ..color = const Color(0xFFFF5555)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      for (final p in overlay.crossings) {
        canvas.drawCircle(p, 3.2, red);
      }
    }
    if (overlay.violations.isNotEmpty) {
      final magenta = Paint()
        ..color = const Color(0xFFFF00FF)
        ..strokeWidth = 1.4;
      for (final p in overlay.violations) {
        canvas.drawLine(p - const Offset(4, 0), p + const Offset(4, 0), magenta);
        canvas.drawLine(p - const Offset(0, 4), p + const Offset(0, 4), magenta);
      }
    }
  }

  @override
  bool shouldRepaint(NetlistDiagnosticPainter old) =>
      !identical(old.diagnostics, diagnostics);
}

/// **自动布线**：按 15px 网格对每条网做 A*（驱动 → 各负载），避开元件块，
/// 并对其它网已占用的格子加惩罚，返回画布坐标下的正交线段。
///
/// 仅用于按需查看/导出，不改变布局；失败时回退简单 Z 形路径。
/// 自动布线结果：线段 + 同网 T 型分支点（均为本层坐标）。
class NlAutoRouteResult {
  final Map<NlWire, List<(Offset, Offset)>> segments;
  final Map<NlWire, List<Offset>> junctions;
  final int fallbackCount;

  const NlAutoRouteResult({
    required this.segments,
    required this.junctions,
    this.fallbackCount = 0,
  });
}

/// **自动布线**：15px 网格 A*，按网建树（驱动 → 各负载逐条接到已有树），
/// 约束：
/// - 引脚向外至少 1 个 Grid 后才可以折弯（驱动/负载两端都加逃生段）；
/// - 不同网的**同轴线段**绝不重叠（水平/垂直边分别占用，十字交叉允许）；
/// - 同网共线合并，T 型分支点记录为实心圆点。
NlAutoRouteResult routeNetlistWires(
  List<NlLevel> levels,
  Size canvasSize, {
  double grid = 15,
  double clearance = 6,
  int orderMode = 0,
  bool nearLoadFirst = false,
}) {
  final columns = math.max(2, (canvasSize.width / grid).ceil() + 1);
  final rows = math.max(2, (canvasSize.height / grid).ceil() + 1);
  final count = columns * rows;
  final blocked = List<bool>.filled(count, false);
  final usedH = List<int>.filled(rows * (columns - 1), -1);
  final usedV = List<int>.filled((rows - 1) * columns, -1);
  final bendOwner = List<int>.filled(count, -1);

  int cellOf(Offset p) {
    final c = (p.dx / grid).round().clamp(0, columns - 1);
    final r = (p.dy / grid).round().clamp(0, rows - 1);
    return r * columns + c;
  }

  Offset pointOf(int cell) =>
      Offset((cell % columns) * grid, (cell ~/ columns) * grid);
  int colOf(int cell) => cell % columns;
  int rowOf(int cell) => cell ~/ columns;

  void markRect(Rect rect) {
    final c0 = (rect.left / grid).floor().clamp(0, columns - 1);
    final c1 = (rect.right / grid).ceil().clamp(0, columns - 1);
    final r0 = (rect.top / grid).floor().clamp(0, rows - 1);
    final r1 = (rect.bottom / grid).ceil().clamp(0, rows - 1);
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        blocked[r * columns + c] = true;
      }
    }
  }

  void markEscapeEdge(Offset from, Offset to, int wireId) {
    final a = cellOf(from), b = cellOf(to);
    if (a == b) return;
    final ca = a % columns, cb = b % columns;
    final ra = a ~/ columns, rb = b ~/ columns;
    if (ra == rb && (ca - cb).abs() == 1) {
      final idx = ra * (columns - 1) + (ca < cb ? ca : cb);
      if (usedH[idx] == -1 || usedH[idx] == wireId) usedH[idx] = wireId;
    } else if (ca == cb && (ra - rb).abs() == 1) {
      final idx = (ra < rb ? ra : rb) * columns + ca;
      if (usedV[idx] == -1 || usedV[idx] == wireId) usedV[idx] = wireId;
    }
  }

  final segmentsByWire = <NlWire, List<(Offset, Offset)>>{};
  final junctionsByWire = <NlWire, List<Offset>>{};
  var fallbackCount = 0;

  /// 该段是否未被其它网占用（与 markRun 同口径，只读）。
  bool canMarkRun(Offset a, Offset b, int wireId) {
    final ca = cellOf(a), cb = cellOf(b);
    if (ca == cb) return true;
    final ra = rowOf(ca), rb = rowOf(cb);
    final colA = colOf(ca), colB = colOf(cb);
    if (ra == rb) {
      final lo = math.min(colA, colB), hi = math.max(colA, colB);
      for (var c = lo; c < hi; c++) {
        final owner = usedH[ra * (columns - 1) + c];
        if (owner != -1 && owner != wireId) return false;
      }
    } else if (colA == colB) {
      final lo = math.min(ra, rb), hi = math.max(ra, rb);
      for (var r = lo; r < hi; r++) {
        final owner = usedV[r * columns + colA];
        if (owner != -1 && owner != wireId) return false;
      }
    }
    return true;
  }

  void markRun(Offset a, Offset b, int wireId) {
    final ca = cellOf(a), cb = cellOf(b);
    if (ca == cb) return;
    final ra = rowOf(ca), rb = rowOf(cb);
    final colA = colOf(ca), colB = colOf(cb);
    if (ra == rb) {
      final lo = math.min(colA, colB), hi = math.max(colA, colB);
      for (var c = lo; c < hi; c++) {
        final idx = ra * (columns - 1) + c;
        if (usedH[idx] == -1 || usedH[idx] == wireId) usedH[idx] = wireId;
      }
    } else if (colA == colB) {
      final lo = math.min(ra, rb), hi = math.max(ra, rb);
      for (var r = lo; r < hi; r++) {
        final idx = r * columns + colA;
        if (usedV[idx] == -1 || usedV[idx] == wireId) usedV[idx] = wireId;
      }
    }
  }

  for (final level in levels) {
    for (final block in level.blocks) {
      if (block.isIo || block.boxSize.width <= 0) continue;
      markRect(
        Rect.fromLTWH(
          block.boxOrigin.dx + level.offset.dx - clearance,
          block.boxOrigin.dy + level.offset.dy - clearance,
          block.boxSize.width + clearance * 2,
          block.boxSize.height + clearance * 2,
        ),
      );
    }

    // 先把本层所有 pin 的逃生边预留给各自网，避免别的网先占用。
    for (final wire in level.wires) {
      final id = identityHashCode(wire);
      markEscapeEdge(wire.from.pos, nlPinEscape(wire.from, grid), id);
      for (final load in wire.loads) {
        markEscapeEdge(nlPinEscape(load, grid), load.pos, id);
      }
    }

    // 通道预布线：单负载、跨相邻一列（Z 形）的网先用区间着色车道布线；
    // 布通且无冲突的网不再进 A*，其余仍交给 A*。
    final pinBlock = <NlPin, NlBlock>{};
    for (final b in level.blocks) {
      for (final p in [...b.ins, ...b.outs]) {
        pinBlock[p] = b;
      }
    }
    final channelWires = <NlWire, List<(Offset, Offset)>>{};
    final channelJunctions = <NlWire, List<Offset>>{};
    final byGap = <int, List<NlWire>>{};
    for (final wire in level.wires) {
      if (wire.loads.isEmpty) continue;
      final fb = pinBlock[wire.from];
      if (fb == null) continue;
      var sameGap = true;
      for (final load in wire.loads) {
        final lb = pinBlock[load];
        if (lb == null || lb.column != fb.column + 1) {
          sameGap = false;
          break;
        }
      }
      if (!sameGap) continue;
      (byGap[fb.column] ??= []).add(wire);
    }
    for (final group in byGap.values) {
      final nets = <NlChannelNet>[];
      final wiresById = <int, NlWire>{};
      final leftById = <int, Offset>{};
      final rightPinsById = <int, List<(Offset, NlPin)>>{};
      var xMin = double.infinity;
      var xMax = -double.infinity;
      for (var i = 0; i < group.length; i++) {
        final w = group[i];
        final a = nlPinEscape(w.from, grid);
        final rights = <(Offset, NlPin)>[
          for (final load in w.loads)
            (nlPinEscape(load, grid), load),
        ];
        if (rights.any((r) => a.dx >= r.$1.dx)) continue;
        nets.add(
          NlChannelNet.multi(
            id: i,
            leftX: a.dx,
            leftY: a.dy,
            rights: [for (final r in rights) (r.$1.dx, r.$1.dy)],
          ),
        );
        wiresById[i] = w;
        leftById[i] = a;
        rightPinsById[i] = rights;
        xMin = math.min(xMin, a.dx);
        for (final r in rights) {
          xMax = math.max(xMax, r.$1.dx);
        }
      }
      if (nets.isEmpty) continue;
      final plan = routeNlChannel(
        nets: nets,
        xMin: xMin,
        xMax: xMax,
        pitch: grid,
      );
      if (plan.unrouted.isNotEmpty || plan.conflicts.isNotEmpty) continue;
      final pending =
          <(NlWire, List<(Offset, Offset)>, List<Offset>)>[];
      var canApply = true;
      for (final route in plan.routes) {
        final w = wiresById[route.id];
        final left = leftById[route.id];
        final rights = rightPinsById[route.id];
        if (w == null || left == null || rights == null) continue;
        final segs = <(Offset, Offset)>[
          // 引脚 → 逃生点：与 A* 路径同样的 1 Grid 外延段。
          if ((w.from.pos - left).distance > 0.01) (w.from.pos, left),
          for (final s in route.segments)
            (Offset(s.$1, s.$2), Offset(s.$3, s.$4)),
          // 逃生点 → 负载引脚。
          for (final r in rights)
            if ((r.$1 - r.$2.pos).distance > 0.01) (r.$1, r.$2.pos),
        ];
        final id = identityHashCode(w);
        // 通道段不得压到其它网的逃生边/已占走线；否则整组回退 A*。
        if (!segs.every((s) => canMarkRun(s.$1, s.$2, id))) {
          canApply = false;
          break;
        }
        pending.add((
          w,
          segs,
          [for (final j in route.junctions) Offset(j.$1, j.$2)],
        ));
      }
      if (!canApply) continue;
      for (final (w, segs, junctions) in pending) {
        channelWires[w] = segs;
        channelJunctions[w] = junctions;
        final id = identityHashCode(w);
        for (final s in segs) {
          markRun(s.$1, s.$2, id);
        }
      }
    }

    // 常规模式：底边 S 引脚优先，其余按直线长度从长到短；
    // 其它 orderMode 供「自动优化布线」搜索不同布线顺序。
    bool hasBottomPin(NlWire w) => w.loads.any((p) => p.port == 'S');
    int wireCompare(NlWire a, NlWire b) {
      final la = _nlWireStraightLength(a), lb = _nlWireStraightLength(b);
      switch (orderMode) {
        case 1:
          return la.compareTo(lb);
        case 2:
          final c = b.loads.length.compareTo(a.loads.length);
          return c != 0 ? c : lb.compareTo(la);
        case 3:
          final c = a.loads.length.compareTo(b.loads.length);
          return c != 0 ? c : lb.compareTo(la);
        case 4:
        case 5:
          return _nlWireOrderHash(
            a,
            orderMode,
          ).compareTo(_nlWireOrderHash(b, orderMode));
        case 6:
          final ab = hasBottomPin(a), bb = hasBottomPin(b);
          if (ab != bb) return ab ? -1 : 1;
          return la.compareTo(lb);
        default:
          final ab = hasBottomPin(a), bb = hasBottomPin(b);
          if (ab != bb) return ab ? -1 : 1;
          return lb.compareTo(la);
      }
    }

    final wires = [...level.wires]..sort(wireCompare);
    for (final wire in wires) {
      final channel = channelWires[wire];
      if (channel != null) {
        segmentsByWire[wire] = channel;
        final junctions = channelJunctions[wire];
        if (junctions != null && junctions.isNotEmpty) {
          junctionsByWire[wire] = junctions;
        }
        continue;
      }
      final wireId = identityHashCode(wire);
      final fromEscape = nlPinEscape(wire.from, grid);
      final fromCell = cellOf(fromEscape);
      blocked[fromCell] = false;
      final treeCells = <int>{fromCell};
      markEscapeEdge(wire.from.pos, fromEscape, wireId);
      final segments = <(Offset, Offset)>[(wire.from.pos, fromEscape)];
      final driverSnap = <Offset>[fromEscape];
      _nlAppendOrthogonalPoints(driverSnap, fromEscape, pointOf(fromCell));
      for (var i = 0; i + 1 < driverSnap.length; i++) {
        if ((driverSnap[i + 1] - driverSnap[i]).distance > 0.01) {
          segments.add((driverSnap[i], driverSnap[i + 1]));
        }
      }

      final loads = [...wire.loads]
        ..sort((a, b) {
          final cmp = (a.pos - wire.from.pos).distance.compareTo(
            (b.pos - wire.from.pos).distance,
          );
          return nearLoadFirst ? cmp : -cmp;
        });
      for (final load in loads) {
        final toEscape = nlPinEscape(load, grid);
        final goalCell = cellOf(toEscape);
        blocked[goalCell] = false;
        markEscapeEdge(toEscape, load.pos, wireId);

        // 依次尝试最近的已有树节点；A* 只允许走未被其它网同轴占用的边。
        final candidates = treeCells.toList()
          ..sort(
            (a, b) =>
                ((colOf(a) - colOf(goalCell)).abs() +
                        (rowOf(a) - rowOf(goalCell)).abs())
                    .compareTo(
                      (colOf(b) - colOf(goalCell)).abs() +
                          (rowOf(b) - rowOf(goalCell)).abs(),
                    ),
          );
        List<int>? path;
        var meet = candidates.first;
        for (final candidate in candidates) {
          path = _nlAStarRoute(
            columns: columns,
            rows: rows,
            blocked: blocked,
            usedH: usedH,
            usedV: usedV,
            bendOwner: bendOwner,
            wireId: wireId,
            start: goalCell,
            goal: candidate,
            startDir: _nlDirectionOf(load.pos, toEscape),
            goalDir: _nlDirectionOf(wire.from.pos, fromEscape),
          );
          if (path != null) {
            meet = candidate;
            break;
          }
        }

        if (path != null) {
          _nlMarkPathEdges(usedH, usedV, columns, path, wireId);
          _nlMarkPathBends(
            bendOwner,
            path,
            columns,
            wireId,
            startDir: _nlDirectionOf(load.pos, toEscape),
            goalDir: _nlDirectionOf(wire.from.pos, fromEscape),
          );
          treeCells.addAll(path);
          final points = <Offset>[toEscape];
          _nlAppendOrthogonalPoints(points, toEscape, pointOf(goalCell));
          for (final cell in path.skip(1)) {
            points.add(pointOf(cell));
          }
          final simplified = _nlSimplifyPath(points);
          for (var i = 0; i + 1 < simplified.length; i++) {
            if ((simplified[i + 1] - simplified[i]).distance > 0.01) {
              segments.add((simplified[i], simplified[i + 1]));
            }
          }
        } else {
          // 极端拥堵兜底：接到最近的树节点（L 形）。正常网格间距下不应触发。
          fallbackCount++;
          final meetPoint = pointOf(meet);
          segments
            ..add((toEscape, Offset(meetPoint.dx, toEscape.dy)))
            ..add((Offset(meetPoint.dx, toEscape.dy), meetPoint));
        }
        // 逃生段：负载从外侧直线进入 pin，至少 1 Grid 后才允许拐弯。
        segments.add((toEscape, load.pos));
      }

      final merged = _nlConnectWireTree(_nlMergeSegments(segments));
      if (merged.isEmpty) continue;
      segmentsByWire[wire] = [
        for (final (a, b) in merged) (a - level.offset, b - level.offset),
      ];
      final local = [
        for (final (a, b) in merged) (a - level.offset, b - level.offset),
      ];
      final junctions = nlTreeJunctions(local);
      if (junctions.isNotEmpty) junctionsByWire[wire] = junctions;
      for (final p in nlRoutingBendPoints(local, junctions: junctions)) {
        bendOwner[cellOf(p + level.offset)] = wireId;
      }
    }
  }

  return NlAutoRouteResult(
    segments: segmentsByWire,
    junctions: junctionsByWire,
    fallbackCount: fallbackCount,
  );
}

/// 只重布一组单负载网（局部 rip-up）：其它网的几何保持不变，占用按现有
/// 结果重建；用于“移动端口/元件后只影响这几条线”的局部清理。
NlAutoRouteResult? nlRerouteWires(
  List<NlLevel> levels,
  Size canvasSize,
  NlAutoRouteResult current,
  Set<NlWire> wires, {
  double grid = 15,
  double clearance = 6,
  NlWire? firstWire,
}) {
  if (wires.isEmpty) return null;
  if (wires.any((w) => w.loads.length != 1)) return null;
  final columns = math.max(2, (canvasSize.width / grid).ceil() + 1);
  final rows = math.max(2, (canvasSize.height / grid).ceil() + 1);
  final count = columns * rows;
  final blocked = List<bool>.filled(count, false);
  final usedH = List<int>.filled(rows * (columns - 1), -1);
  final usedV = List<int>.filled((rows - 1) * columns, -1);
  final bendOwner = List<int>.filled(count, -1);

  int cellOf(Offset p) {
    final c = (p.dx / grid).round().clamp(0, columns - 1);
    final r = (p.dy / grid).round().clamp(0, rows - 1);
    return r * columns + c;
  }

  Offset pointOf(int cell) =>
      Offset((cell % columns) * grid, (cell ~/ columns) * grid);
  int colOf(int cell) => cell % columns;
  int rowOf(int cell) => cell ~/ columns;

  void markRect(Rect rect) {
    final c0 = (rect.left / grid).floor().clamp(0, columns - 1);
    final c1 = (rect.right / grid).ceil().clamp(0, columns - 1);
    final r0 = (rect.top / grid).floor().clamp(0, rows - 1);
    final r1 = (rect.bottom / grid).ceil().clamp(0, rows - 1);
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        blocked[r * columns + c] = true;
      }
    }
  }

  for (final level in levels) {
    for (final block in level.blocks) {
      if (block.isIo || block.boxSize.width <= 0) continue;
      markRect(
        Rect.fromLTWH(
          block.boxOrigin.dx + level.offset.dx - clearance,
          block.boxOrigin.dy + level.offset.dy - clearance,
          block.boxSize.width + clearance * 2,
          block.boxSize.height + clearance * 2,
        ),
      );
    }
  }

  final offsets = <NlWire, Offset>{};
  for (final level in levels) {
    for (final w in level.wires) {
      offsets[w] = level.offset;
    }
  }

  final dirtyIds = {for (final w in wires) identityHashCode(w)};
  void markSegment(Offset a, Offset b, int id) {
    final ca = cellOf(a), cb = cellOf(b);
    final ra = rowOf(ca), rb = rowOf(cb);
    final colA = colOf(ca), colB = colOf(cb);
    if (ra == rb) {
      final lo = math.min(colA, colB), hi = math.max(colA, colB);
      for (var c = lo; c < hi; c++) {
        usedH[ra * (columns - 1) + c] = id;
      }
    } else if (colA == colB) {
      final lo = math.min(ra, rb), hi = math.max(ra, rb);
      for (var r = lo; r < hi; r++) {
        usedV[r * columns + colA] = id;
      }
    }
  }

  for (final other in current.segments.keys) {
    final id = identityHashCode(other);
    if (dirtyIds.contains(id)) continue;
    final off = offsets[other] ?? Offset.zero;
    final otherSegs =
        current.segments[other] ?? const <(Offset, Offset)>[];
    for (final (a, b) in otherSegs) {
      markSegment(a + off, b + off, id);
    }
    final otherJunctions = current.junctions[other] ?? const <Offset>[];
    for (final p in otherJunctions) {
      bendOwner[cellOf(p + off)] = id;
    }
  }

  final resultSegments = <NlWire, List<(Offset, Offset)>>{
    ...current.segments,
  };
  final resultJunctions = <NlWire, List<Offset>>{...current.junctions};
  final ordered = <NlWire>[
    if (firstWire != null && wires.contains(firstWire)) firstWire,
    for (final level in levels)
      for (final w in level.wires)
        if (wires.contains(w) && !identical(w, firstWire)) w,
  ];
  for (final wire in ordered) {
    {
      final fromEscape = nlPinEscape(wire.from, grid);
      final toEscape = nlPinEscape(wire.loads.first, grid);
      final fromCell = cellOf(fromEscape);
      final toCell = cellOf(toEscape);
      blocked[fromCell] = false;
      blocked[toCell] = false;
      final path = _nlAStarRoute(
        columns: columns,
        rows: rows,
        blocked: blocked,
        usedH: usedH,
        usedV: usedV,
        bendOwner: bendOwner,
        wireId: identityHashCode(wire),
        start: toCell,
        goal: fromCell,
        startDir: _nlDirectionOf(wire.loads.first.pos, toEscape),
        goalDir: _nlDirectionOf(wire.from.pos, fromEscape),
      );
      if (path == null) return null;

      final points = <Offset>[toEscape];
      _nlAppendOrthogonalPoints(points, toEscape, pointOf(toCell));
      for (final cell in path.skip(1)) {
        points.add(pointOf(cell));
      }
      _nlAppendOrthogonalPoints(points, pointOf(fromCell), fromEscape);
      points
        ..add(wire.from.pos)
        ..add(wire.loads.first.pos);
      final simplified = _nlSimplifyPath(points);
      final rawSegments = <(Offset, Offset)>[
        for (var i = 0; i + 1 < simplified.length; i++)
          if ((simplified[i + 1] - simplified[i]).distance > 0.01)
            (simplified[i], simplified[i + 1]),
        (toEscape, wire.loads.first.pos),
        (wire.from.pos, fromEscape),
      ];
      final merged = _nlMergeSegments(rawSegments);
      if (merged.isEmpty) return null;
      final id = identityHashCode(wire);
      for (final (a, b) in merged) {
        markSegment(a, b, id);
      }
      final off = offsets[wire] ?? Offset.zero;
      final local = [
        for (final (a, b) in merged) (a - off, b - off),
      ];
      resultSegments[wire] = local;
      final junctions = nlTreeJunctions(local);
      if (junctions.isEmpty) {
        resultJunctions.remove(wire);
      } else {
        resultJunctions[wire] = junctions;
      }
      for (final p in nlRoutingBendPoints(
        local,
        junctions: junctions,
      )) {
        bendOwner[cellOf(p + off)] = id;
      }
    }
  }
  return NlAutoRouteResult(
    segments: resultSegments,
    junctions: resultJunctions,
    fallbackCount: current.fallbackCount,
  );
}

/// 单网局部重布的便捷包装。
NlAutoRouteResult? nlRerouteSingleWire(
  List<NlLevel> levels,
  Size canvasSize,
  NlAutoRouteResult current,
  NlWire wire, {
  double grid = 15,
  double clearance = 6,
}) => nlRerouteWires(
  levels,
  canvasSize,
  current,
  {wire},
  grid: grid,
  clearance: clearance,
);

/// 同一根网的折弯点：水平段与垂直段在端点相接的拐角，排除 [junctions] 中的
/// 同网 T/十字分支点。
List<Offset> nlRoutingBendPoints(
  List<(Offset, Offset)> segments, {
  List<Offset> junctions = const [],
}) {
  final orientation = <(int, int), int>{};
  final junctionKeys = <(int, int)>{
    for (final p in junctions) ((p.dx * 100).round(), (p.dy * 100).round()),
  };
  for (final segment in segments) {
    final isH = (segment.$1.dy - segment.$2.dy).abs() < 0.01;
    for (final p in [segment.$1, segment.$2]) {
      final key = ((p.dx * 100).round(), (p.dy * 100).round());
      orientation[key] = (orientation[key] ?? 0) | (isH ? 1 : 2);
    }
  }
  return [
    for (final e in orientation.entries)
      if (e.value == 3 && !junctionKeys.contains(e.key))
        Offset(e.key.$1 / 100.0, e.key.$2 / 100.0),
  ];
}

/// 不同网折弯点在同一坐标上重叠的数量（按坐标去重）。
int nlBendOverlapCount(NlAutoRouteResult result) {
  final owners = <(int, int), Set<int>>{};
  for (final entry in result.segments.entries) {
    final id = identityHashCode(entry.key);
    for (final p in nlRoutingBendPoints(
      entry.value,
      junctions: result.junctions[entry.key] ?? const [],
    )) {
      final key = ((p.dx * 100).round(), (p.dy * 100).round());
      (owners[key] ??= <int>{}).add(id);
    }
  }
  return owners.values.where((ids) => ids.length >= 2).length;
}

NlAutoRouteResult repairBendOverlaps(
  NlAutoRouteResult source,
  List<NlLevel> levels,
) {
  final segments = <NlWire, List<(Offset, Offset)>>{
    for (final e in source.segments.entries) e.key: [...e.value],
  };
  final offsets = <NlWire, Offset>{};
  final blocks = <Rect>[];
  for (final level in levels) {
    for (final b in level.blocks) {
      if (b.isIo) continue;
      blocks.add(
        Rect.fromLTWH(
          b.boxOrigin.dx + level.offset.dx,
          b.boxOrigin.dy + level.offset.dy,
          b.boxSize.width,
          b.boxSize.height,
        ),
      );
    }
  }
  for (final level in levels) {
    for (final wire in level.wires) {
      if (segments.containsKey(wire)) offsets[wire] = level.offset;
    }
  }

  bool hitsBlock(Offset a, Offset b) {
    for (final r in blocks) {
      if ((a.dy - b.dy).abs() < 0.01) {
        if (a.dy >= r.top - 0.01 &&
            a.dy <= r.bottom + 0.01 &&
            math.min(a.dx, b.dx) <= r.right + 0.01 &&
            math.max(a.dx, b.dx) >= r.left - 0.01) {
          return true;
        }
      } else if (a.dx >= r.left - 0.01 &&
          a.dx <= r.right + 0.01 &&
          math.min(a.dy, b.dy) <= r.bottom + 0.01 &&
          math.max(a.dy, b.dy) >= r.top - 0.01) {
        return true;
      }
    }
    return false;
  }

  bool overlapsOther(NlWire wire, Offset a, Offset b, Offset off) {
    for (final entry in segments.entries) {
      if (identical(entry.key, wire)) continue;
      final o = offsets[entry.key] ?? Offset.zero;
      for (final (c0, d0) in entry.value) {
        final c = c0 + o, d = d0 + o;
        if ((a.dy - b.dy).abs() < 0.01 && (c.dy - d.dy).abs() < 0.01) {
          if ((a.dy - c.dy).abs() < 0.01 &&
              math.min(a.dx, b.dx) < math.max(c.dx, d.dx) - 0.01 &&
              math.min(c.dx, d.dx) < math.max(a.dx, b.dx) - 0.01) {
            return true;
          }
        } else if ((a.dx - b.dx).abs() < 0.01 && (c.dx - d.dx).abs() < 0.01) {
          if ((a.dx - c.dx).abs() < 0.01 &&
              math.min(a.dy, b.dy) < math.max(c.dy, d.dy) - 0.01 &&
              math.min(c.dy, d.dy) < math.max(a.dy, b.dy) - 0.01) {
            return true;
          }
        }
      }
    }
    return false;
  }

  bool pinEscapesOk(NlWire wire, List<(Offset, Offset)> segs) {
    for (final pin in [wire.from, ...wire.loads]) {
      for (final (a, b) in segs) {
        if ((a - pin.pos).distance < 0.01 || (b - pin.pos).distance < 0.01) {
          if ((a - b).distance < _kGrid - 0.01) return false;
        }
      }
    }
    return true;
  }

  Set<(int, int)> otherBends(NlWire wire) {
    final out = <(int, int)>{};
    for (final entry in segments.entries) {
      if (identical(entry.key, wire)) continue;
      final off = offsets[entry.key] ?? Offset.zero;
      for (final p in nlRoutingBendPoints(
        entry.value,
        junctions: source.junctions[entry.key] ?? const [],
      )) {
        final q = p + off;
        out.add(((q.dx * 100).round(), (q.dy * 100).round()));
      }
    }
    return out;
  }

  for (var pass = 0; pass < 60; pass++) {
    final bendMap = <(int, int), List<(NlWire, Offset)>>{};
    for (final entry in segments.entries) {
      final off = offsets[entry.key] ?? Offset.zero;
      for (final p in nlRoutingBendPoints(
        entry.value,
        junctions: source.junctions[entry.key] ?? const [],
      )) {
        final q = p + off;
        final key = ((q.dx * 100).round(), (q.dy * 100).round());
        (bendMap[key] ??= []).add((entry.key, p));
      }
    }
    final collision = bendMap.entries
        .where((e) => e.value.map((v) => v.$1).toSet().length >= 2)
        .firstOrNull;
    if (collision == null) break;
    var repaired = false;
    for (final victim in collision.value.reversed) {
      final wire = victim.$1;
      final point = victim.$2;
      final list = segments[wire]!;
      final off = offsets[wire] ?? Offset.zero;
      // 不移动正好落在引脚上的折弯点，避免把引脚连接改断。
      if ([
        wire.from,
        ...wire.loads,
      ].any((p) => (p.pos - point).distance < 0.01)) {
        continue;
      }
      int? hIndex, vIndex;
      for (var i = 0; i < list.length; i++) {
        final (a, b) = list[i];
        final isH = (a.dy - b.dy).abs() < 0.01;
        final isV = (a.dx - b.dx).abs() < 0.01;
        if (isH &&
            ((a - point).distance < 0.01 || (b - point).distance < 0.01)) {
          hIndex ??= i;
        }
        if (isV &&
            ((a - point).distance < 0.01 || (b - point).distance < 0.01)) {
          vIndex ??= i;
        }
      }
      if (hIndex == null || vIndex == null) continue;
      final blockedBends = otherBends(wire);
      final candidates = [
        point + const Offset(_kGrid, 0),
        point - const Offset(_kGrid, 0),
        point + const Offset(0, _kGrid),
        point - const Offset(0, _kGrid),
      ];
      for (final nextPoint in candidates) {
        final c = nextPoint + off;
        final key = ((c.dx * 100).round(), (c.dy * 100).round());
        if (blockedBends.contains(key)) continue;
        final h = list[hIndex];
        final v = list[vIndex];
        final nh = (
          (h.$1 - point).distance < 0.01 ? nextPoint : h.$1,
          (h.$2 - point).distance < 0.01 ? nextPoint : h.$2,
        );
        final nv = (
          (v.$1 - point).distance < 0.01 ? nextPoint : v.$1,
          (v.$2 - point).distance < 0.01 ? nextPoint : v.$2,
        );
        if ((nh.$1 - nh.$2).distance < _kGrid / 2 ||
            (nv.$1 - nv.$2).distance < _kGrid / 2) {
          continue;
        }
        if (hitsBlock(nh.$1 + off, nh.$2 + off) ||
            hitsBlock(nv.$1 + off, nv.$2 + off)) {
          continue;
        }
        if (overlapsOther(wire, nh.$1 + off, nh.$2 + off, off) ||
            overlapsOther(wire, nv.$1 + off, nv.$2 + off, off)) {
          continue;
        }
        final trial = [...list];
        trial[hIndex] = nh;
        trial[vIndex] = nv;
        if (!pinEscapesOk(wire, trial)) continue;
        list[hIndex] = nh;
        list[vIndex] = nv;
        final merged = _nlMergeSegments(list);
        segments[wire] = merged;
        final junctions = nlTreeJunctions(merged);
        source.junctions[wire] = junctions;
        repaired = true;
        break;
      }
      if (repaired) break;
    }
    if (!repaired) break;
  }

  return NlAutoRouteResult(
    segments: segments,
    junctions: source.junctions,
    fallbackCount: source.fallbackCount,
  );
}

/// 端口处仍存在折弯的端口数量：端口逃生点后的第一段若不是水平段，
/// 说明端口没有和水平主线直连。
int nlPortBendCount(List<NlLevel> levels, NlAutoRouteResult result) {
  var count = 0;
  for (final level in levels) {
    for (final pin in level.ports) {
      NlWire? wire;
      for (final w in level.wires) {
        if (identical(w.from, pin) || w.loads.any((l) => identical(l, pin))) {
          wire = w;
          break;
        }
      }
      if (wire == null) continue;
      final segs = result.segments[wire] ?? const <(Offset, Offset)>[];
      // 端口连线从 pos 出发（cell 针脚的逃生点与 pos 重合；端口针脚的
      // nlPinEscape 是 pos 再向外 1 Grid），两处都算连接点——否则水平
      // 直出的端口会被误判为带折线。
      final escape = nlPinEscape(pin, _kGrid);
      bool atPin(Offset p) =>
          (p - escape).distance < 0.01 || (p - pin.pos).distance < 0.01;
      var connected = false;
      var horizontal = false;
      for (final (a, b) in segs) {
        final atA = atPin(a);
        final atB = atPin(b);
        if (!atA && !atB) continue;
        connected = true;
        if ((a.dy - b.dy).abs() < 0.01) horizontal = true;
      }
      if (!connected || !horizontal) count++;
    }
  }
  return count;
}

/// 自动布线指标：异网交叉点、同网折弯点、总长度。
class NlRoutingMetrics {
  final int crossings;
  final int bends;

  /// 单网折弯数的 P95（长尾指标；空集为 0）。
  final double bendP95;
  final double length;

  const NlRoutingMetrics({
    required this.crossings,
    required this.bends,
    required this.length,
    this.bendP95 = 0,
  });
}

/// 统计自动布线结果：
/// - 交叉点：不同网之间的水平/垂直线段交点（按坐标去重）；
/// - 折弯点：同一根网中水平段与垂直段相接的拐角，排除同网的 T/十字分支点；
/// - 走线总长：所有正交线段 `|dx| + |dy|` 之和。
NlRoutingMetrics nlRoutingMetrics(NlAutoRouteResult result) {
  final crosses = <(int, int)>{};
  final entries = result.segments.entries.toList();

  bool horizontal((Offset, Offset) s) => (s.$1.dy - s.$2.dy).abs() < 0.01;
  bool vertical((Offset, Offset) s) => (s.$1.dx - s.$2.dx).abs() < 0.01;

  void addCross((Offset, Offset) h, (Offset, Offset) v) {
    final x = v.$1.dx;
    final y = h.$1.dy;
    final hLo = math.min(h.$1.dx, h.$2.dx);
    final hHi = math.max(h.$1.dx, h.$2.dx);
    final vLo = math.min(v.$1.dy, v.$2.dy);
    final vHi = math.max(v.$1.dy, v.$2.dy);
    if (x < hLo - 0.01 || x > hHi + 0.01) return;
    if (y < vLo - 0.01 || y > vHi + 0.01) return;
    crosses.add(((x * 100).round(), (y * 100).round()));
  }

  for (var i = 0; i < entries.length; i++) {
    for (var j = i + 1; j < entries.length; j++) {
      for (final a in entries[i].value) {
        for (final b in entries[j].value) {
          if (horizontal(a) && vertical(b)) addCross(a, b);
          if (vertical(a) && horizontal(b)) addCross(b, a);
        }
      }
    }
  }

  var bends = 0;
  final bendCounts = <int>[];
  for (final entry in result.segments.entries) {
    final count = nlRoutingBendPoints(
      entry.value,
      junctions: result.junctions[entry.key] ?? const [],
    ).length;
    bends += count;
    bendCounts.add(count);
  }

  return NlRoutingMetrics(
    crossings: crosses.length,
    bends: bends,
    length: nlRoutedLength(result),
    bendP95: _nlPercentile95(bendCounts),
  );
}

/// 最近秩 P95（整数列表，空集为 0）。
double _nlPercentile95(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  final rank = (0.95 * (sorted.length - 1)).round();
  return sorted[rank].toDouble();
}

/// 异网同轴重叠的网对数（硬约束；>0 的布线结果不可接受）。
///
/// 与 `netlist_routing_metrics.dart` 的 `netOverlap` 同口径：只看不同网的
/// 水平-水平 / 垂直-垂直共线重叠，正交交叉不算。
int nlRoutingOverlapPairCount(NlAutoRouteResult result) {
  final entries = result.segments.entries.toList();
  var count = 0;
  for (var i = 0; i < entries.length; i++) {
    for (var j = i + 1; j < entries.length; j++) {
      if (_nlSegListsOverlap(entries[i].value, entries[j].value)) count++;
    }
  }
  return count;
}

/// 候选布线是否通过全部硬约束闸门（无 fallback、无异网同轴重叠）。
bool nlRouteIsClean(NlAutoRouteResult r) =>
    r.fallbackCount == 0 && nlRoutingOverlapPairCount(r) == 0;

bool _nlSegListsOverlap(  List<(Offset, Offset)> a,
  List<(Offset, Offset)> b,
) {
  for (final s in a) {
    final hA = (s.$1.dy - s.$2.dy).abs() < 0.01;
    final vA = (s.$1.dx - s.$2.dx).abs() < 0.01;
    if (!hA && !vA) continue;
    for (final t in b) {
      final hB = (t.$1.dy - t.$2.dy).abs() < 0.01;
      final vB = (t.$1.dx - t.$2.dx).abs() < 0.01;
      if (hA && hB && (s.$1.dy - t.$1.dy).abs() < 0.01) {
        final lo = math.max(
          math.min(s.$1.dx, s.$2.dx),
          math.min(t.$1.dx, t.$2.dx),
        );
        final hi = math.min(
          math.max(s.$1.dx, s.$2.dx),
          math.max(t.$1.dx, t.$2.dx),
        );
        if (hi - lo > 0.01) return true;
      }
      if (vA && vB && (s.$1.dx - t.$1.dx).abs() < 0.01) {
        final lo = math.max(
          math.min(s.$1.dy, s.$2.dy),
          math.min(t.$1.dy, t.$2.dy),
        );
        final hi = math.min(
          math.max(s.$1.dy, s.$2.dy),
          math.max(t.$1.dy, t.$2.dy),
        );
        if (hi - lo > 0.01) return true;
      }
    }
  }
  return false;
}

/// 平移一个块（连同其引脚）；手动编辑与优化共用。
void nlShiftBlock(NlBlock block, double dy) => _nlShiftBlock(block, dy);

/// 正交平移一个块（x/y 同时）；手动编辑跨列拖动用。
void nlShiftBlockXY(NlBlock block, double dx, double dy) {
  block.origin += Offset(dx, dy);
  block.boxOrigin += Offset(dx, dy);
  for (final p in [...block.ins, ...block.outs]) {
    p.pos += Offset(dx, dy);
    p.edge += Offset(dx, dy);
  }
}

/// 自动优化布线的结果（对比初始布线总长度）。
/// 上下平移一个元件（连同其引脚），用于自动优化布线的列内微调。
void _nlShiftBlock(NlBlock block, double dy) {
  block.origin += Offset(0, dy);
  block.boxOrigin += Offset(0, dy);
  for (final p in [...block.ins, ...block.outs]) {
    p.pos += Offset(0, dy);
    p.edge += Offset(0, dy);
  }
}

/// 单个块的针脚坐标重排（组合逻辑单输出居中，MUX 选择端在底边）。
///
/// 按 [NlBlock.pinFlip] 与各边槽位序字段（inPinOrder/outPinOrder/
/// topPinOrder/bottomPinOrder）摆放针脚；模型构建与布线优化的
/// 镜像/引脚交换试探共用，同一组样式字段必得同一组坐标。
void nlLayoutBlockPins(NlBlock b) {
  final symbolRect = Rect.fromLTWH(
    b.boxOrigin.dx,
    b.boxOrigin.dy,
    b.boxSize.width,
    b.boxSize.height,
  );
  final centeredSingleOutput =
      b.outs.length == 1 && netlistSymbolCentersOutput(b.cell);
  final sideIns = [
    for (final p in b.ins)
      if (!netlistSymbolIsBottomPin(b.cell, p.port)) p,
  ];
  final flipPins = b.pinFlip;
  final inputY = <NlPin, double>{};
  for (var i = 0; i < sideIns.length; i++) {
    var slot = flipPins ? sideIns.length - 1 - i : i;
    final pinOrder = b.inPinOrder;
    if (pinOrder != null) {
      // 槽位序按显示名匹配（多驱动拆分针脚共享端口名 'A'，按端口名
      // indexOf 会把 A[24:11]/A[10:0] 分到同一槽位而重叠；端口名仅作
      // 旧数据兜底）。
      var idx = pinOrder.indexOf(sideIns[i].display);
      if (idx < 0) idx = pinOrder.indexOf(sideIns[i].port);
      if (idx >= 0 && idx < sideIns.length) slot = idx;
    }
    if (centeredSingleOutput) {
      final row = slot - (sideIns.length - 1) / 2;
      inputY[sideIns[i]] = symbolRect.center.dy + row * _kPinRowH;
    } else {
      inputY[sideIns[i]] =
          b.boxOrigin.dy + _kPinPadV + slot * _kPinRowH + _kPinRowH / 2;
    }
  }
  // 顶/底边针脚（MUX 的 S）：镜像时底↔顶互换；多个同边针脚按槽位序
  // 沿边均匀分布（当前符号集每边至多一个，为引脚交换预留）。
  final topPins = <NlPin>[], bottomPins = <NlPin>[];
  for (final p in b.ins) {
    if (netlistSymbolIsBottomPin(b.cell, p.port)) {
      (flipPins ? topPins : bottomPins).add(p);
    }
  }

  void placeEdgePins(
    List<NlPin> pins,
    List<String>? order,
    double y,
    double outward,
  ) {
    final ordered = [...pins];
    if (order != null) {
      int slotOf(NlPin p) {
        final i = order.indexOf(p.display);
        return i >= 0 ? i : order.indexOf(p.port);
      }

      ordered.sort((a, b2) {
        final ia = slotOf(a);
        final ib = slotOf(b2);
        return (ia < 0 ? order.length : ia).compareTo(
          ib < 0 ? order.length : ib,
        );
      });
    }
    for (var i = 0; i < ordered.length; i++) {
      final x = ordered.length == 1
          ? symbolRect.center.dx
          : symbolRect.left + symbolRect.width * (i + 1) / (ordered.length + 1);
      ordered[i].edge = Offset(x, y);
      ordered[i].pos = Offset(x, y + outward);
    }
  }

  placeEdgePins(topPins, b.topPinOrder, symbolRect.top, -_kStub);
  placeEdgePins(bottomPins, b.bottomPinOrder, symbolRect.bottom, _kStub);
  for (final p in sideIns) {
    final y = inputY[p]!;
    final edgeX = _gridRound(netlistSymbolInputEdgeX(b.cell, symbolRect, y));
    p.edge = Offset(edgeX, y);
    p.pos = Offset(b.boxOrigin.dx - _kStub, y);
  }
  for (var i = 0; i < b.outs.length; i++) {
    // 镜像时右侧输出针脚同样上下反序（单输出为恒等）。
    var slot = flipPins ? b.outs.length - 1 - i : i;
    final outOrder = b.outPinOrder;
    if (outOrder != null) {
      var idx = outOrder.indexOf(b.outs[i].display);
      if (idx < 0) idx = outOrder.indexOf(b.outs[i].port);
      if (idx >= 0 && idx < b.outs.length) slot = idx;
    }
    final y = centeredSingleOutput
        ? symbolRect.center.dy
        : b.boxOrigin.dy + _kPinPadV + slot * _kPinRowH + _kPinRowH / 2;
    b.outs[i].edge = Offset(symbolRect.right, y);
    b.outs[i].pos = Offset(symbolRect.right + _kStub, y);
  }
}

/// 某列内允许的上下范围：受同列顺序、最小间距（5 Grid 与当前实际间距
/// 取小——「允许列内非等间距」可能把间距推挤到 2 Grid，布线移位不得把
/// 它们强制撑回 5 Grid）和“原始位置 ±10 Grid”三重约束；
/// 最顶/最底块也不能超过该上限。
(double, double) _nlVerticalLimits(
  NlBlock block,
  NlLevel level, {
  double? originalY,
  double minGapGrids = 5,
}) {
  final minGap = minGapGrids * _kGrid;
  final column = [
    for (final b in level.blocks)
      if (!b.isIo && b.column == block.column) b,
  ]..sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
  final all = [for (final b in level.blocks) b];
  final globalTop = all.map((b) => b.boxOrigin.dy).reduce(math.min);
  final globalBottom = all
      .map((b) => b.boxOrigin.dy + b.boxSize.height)
      .reduce(math.max);
  final index = column.indexWhere((b) => identical(b, block));
  double gapBefore() => index > 0
      ? block.boxOrigin.dy -
            (column[index - 1].boxOrigin.dy + column[index - 1].boxSize.height)
      : minGap;
  double gapAfter() => index >= 0 && index + 1 < column.length
      ? column[index + 1].boxOrigin.dy -
            (block.boxOrigin.dy + block.boxSize.height)
      : minGap;
  final minTop = index > 0
      ? column[index - 1].boxOrigin.dy +
            column[index - 1].boxSize.height +
            math.min(minGap, gapBefore())
      : globalTop;
  final maxTop = index >= 0 && index + 1 < column.length
      ? column[index + 1].boxOrigin.dy -
            block.boxSize.height -
            math.min(minGap, gapAfter())
      : globalBottom - block.boxSize.height;
  final base = originalY ?? block.boxOrigin.dy;
  return (
    math.max(minTop, base - 10 * _kGrid),
    math.min(maxTop, base + 10 * _kGrid),
  );
}

/// 单独平移一个端口引脚（端口不占列内行序，可直接对齐到走线）。
void _nlShiftPin(NlPin pin, double dy) {
  pin.pos += Offset(0, dy);
  pin.edge += Offset(0, dy);
}

/// 上下移动一个引脚（端口拖动/对齐共用）。
void nlShiftPin(NlPin pin, double dy) => _nlShiftPin(pin, dy);

/// 平移后列内顺序不变、相邻符号仍至少间隔 5 Grid，且不越出画布/±10 Grid。
bool _nlBlockShiftOk(
  NlBlock block,
  NlLevel level,
  double dy,
  Size canvasSize, {
  double? originalY,
  double minGapGrids = 5,
}) {
  final (minTop, maxTop) = _nlVerticalLimits(
    block,
    level,
    originalY: originalY,
    minGapGrids: minGapGrids,
  );
  final movedOrigin = block.boxOrigin.dy + dy;
  return movedOrigin >= minTop - 0.01 &&
      movedOrigin <= maxTop + 0.01 &&
      movedOrigin >= 0 &&
      movedOrigin + block.boxSize.height <= canvasSize.height;
}

/// 与交叉/折弯相关的元件：优先上下移动这些块，减少全图搜索。
Set<NlBlock> _nlHotBlocks(NlAutoRouteResult result, List<NlLevel> levels) {
  final hotWires = <NlWire>{};
  for (final entry in result.segments.entries) {
    final segs = entry.value;
    final bends = nlRoutingBendPoints(
      segs,
      junctions: result.junctions[entry.key] ?? const [],
    );
    if (bends.length >= 2) hotWires.add(entry.key);
  }
  final entries = result.segments.entries.toList();
  for (var i = 0; i < entries.length; i++) {
    for (var j = i + 1; j < entries.length; j++) {
      for (final a in entries[i].value) {
        for (final b in entries[j].value) {
          final ah = (a.$1.dy - a.$2.dy).abs() < 0.01;
          final bh = (b.$1.dy - b.$2.dy).abs() < 0.01;
          if (ah == bh) continue;
          final h = ah ? a : b;
          final v = ah ? b : a;
          final x = v.$1.dx, y = h.$1.dy;
          if (x < math.min(h.$1.dx, h.$2.dx) - 0.01 ||
              x > math.max(h.$1.dx, h.$2.dx) + 0.01 ||
              y < math.min(v.$1.dy, v.$2.dy) - 0.01 ||
              y > math.max(v.$1.dy, v.$2.dy) + 0.01) {
            continue;
          }
          hotWires
            ..add(entries[i].key)
            ..add(entries[j].key);
        }
      }
    }
  }
  final hot = <NlBlock>{};
  for (final level in levels) {
    for (final wire in level.wires) {
      if (!hotWires.contains(wire)) continue;
      for (final b in level.blocks) {
        if (!b.isIo && !b.isContainer && wire.touches(b)) hot.add(b);
      }
    }
  }
  return hot;
}

/// ε-字典序比较：交叉差 >1 才一票否决；否则看单网折弯 P95（差 >1），
/// 再看总折弯（差 >2），最后比长度。与 `netlist_route_objective.dart`
/// 的口径一致；这里只用到布线阶段已有的三个指标。
int _nlCompareMetrics(NlRoutingMetrics a, NlRoutingMetrics b) {
  final dc = a.crossings - b.crossings;
  if (dc.abs() > 1) return dc.sign;
  final dp = a.bendP95 - b.bendP95;
  if (dp.abs() > 1) return dp < 0 ? -1 : 1;
  final db = a.bends - b.bends;
  if (db.abs() > 2) return db.sign;
  return a.length.compareTo(b.length);
}

class NlRoutingOptimizationResult {
  final NlAutoRouteResult result;
  final double initialLength;
  final double length;
  final int attempts;
  final int initialCrossings;
  final int initialBends;
  final int crossings;
  final int bends;
  final int movedBlocks;

  /// 实际执行的「列内移动/针脚变换」轮数。
  final int passes;

  /// 是否自然收敛（最后一轮没有任何改善，或已无热点元件）。
  /// 达到 16 轮上限仍有改善时为 false——不得冒充最优。
  final bool converged;

  const NlRoutingOptimizationResult({
    required this.result,
    required this.initialLength,
    required this.length,
    required this.attempts,
    this.initialCrossings = 0,
    this.initialBends = 0,
    this.crossings = 0,
    this.bends = 0,
    this.movedBlocks = 0,
    this.passes = 0,
    this.converged = false,
  });

  bool get improved =>
      crossings < initialCrossings ||
      (crossings == initialCrossings && bends < initialBends) ||
      (crossings == initialCrossings &&
          bends == initialBends &&
          length < initialLength - 0.01);
}

/// 布线总长度（正交线段 = |dx| + |dy|，含 pin 逃生段）。
double nlRoutedLength(NlAutoRouteResult result) {
  var total = 0.0;
  for (final segments in result.segments.values) {
    for (final (a, b) in segments) {
      total += (a.dx - b.dx).abs() + (a.dy - b.dy).abs();
    }
  }
  return total;
}

/// **自动优化布线**：先以交叉点最少、再以折弯点最少、最后以总长最短为序；
/// 在不改变列内上下顺序的前提下，允许上下微调一个/多个元件后重跑 A*。
/// 优化过程中的阶段回调：结果对应的块位置已经稳定，可直接重绘。
typedef NlRoutingProgress =
    void Function(NlAutoRouteResult result, String stage, int step);

/// 布线优化允许的针脚变换（「布局布线设置」→ 布线优化选项）。
class NlRouteOptOptions {
  /// 上下镜像元件：输入/输出槽位反转、顶↔底针脚互换。
  final bool mirrorVertical;

  /// 左右镜像元件（预留：符号水平翻转暂未支持，设置中禁用）。
  final bool mirrorHorizontal;

  /// 交换左侧（输入）引脚槽位。
  final bool swapLeftPins;

  /// 交换右侧（输出）引脚槽位。
  final bool swapRightPins;

  /// 交换上方引脚槽位。
  final bool swapTopPins;

  /// 交换下方引脚槽位。
  final bool swapBottomPins;

  /// 允许列内非等间距（布线后期：走线不再缩短后，同列相邻块间距
  /// 可在 2~20 Grid 间调整）。
  final bool variableRowGap;

  const NlRouteOptOptions({
    this.mirrorVertical = true,
    this.mirrorHorizontal = false,
    this.swapLeftPins = true,
    this.swapRightPins = true,
    this.swapTopPins = true,
    this.swapBottomPins = true,
    this.variableRowGap = false,
  });

  /// 是否允许任何针脚变换（左右镜像暂未支持，不计入）。
  bool get allowsAny =>
      mirrorVertical ||
      swapLeftPins ||
      swapRightPins ||
      swapTopPins ||
      swapBottomPins;
}

/// 针脚样式快照：变换试探失败时恢复。
class _NlPinStyle {
  final bool flip;
  final List<String>? inOrder;
  final List<String>? outOrder;
  final List<String>? topOrder;
  final List<String>? bottomOrder;

  const _NlPinStyle(
    this.flip,
    this.inOrder,
    this.outOrder,
    this.topOrder,
    this.bottomOrder,
  );

  factory _NlPinStyle.of(NlBlock b) => _NlPinStyle(
    b.pinFlip,
    b.inPinOrder,
    b.outPinOrder,
    b.topPinOrder,
    b.bottomPinOrder,
  );

  void restore(NlBlock b) {
    b.pinFlip = flip;
    b.inPinOrder = inOrder;
    b.outPinOrder = outOrder;
    b.topPinOrder = topOrder;
    b.bottomPinOrder = bottomOrder;
  }
}

/// 块某一边的针脚（按当前坐标取有效顺序：左右边按 y、上下边按 x）。
List<NlPin> _nlEdgePins(NlBlock b, _NlEdge edge) {
  final isBottomPin = <NlPin, bool>{
    for (final p in b.ins) p: netlistSymbolIsBottomPin(b.cell, p.port),
  };
  switch (edge) {
    case _NlEdge.left:
      return [
        for (final p in b.ins)
          if (!(isBottomPin[p] ?? false)) p,
      ]..sort((a, b2) => a.pos.dy.compareTo(b2.pos.dy));
    case _NlEdge.right:
      return [...b.outs]..sort((a, b2) => a.pos.dy.compareTo(b2.pos.dy));
    case _NlEdge.top:
      return [
        for (final p in b.ins)
          if ((isBottomPin[p] ?? false) && p.edge.dy <= b.boxOrigin.dy + 0.01)
            p,
      ]..sort((a, b2) => a.pos.dx.compareTo(b2.pos.dx));
    case _NlEdge.bottom:
      return [
        for (final p in b.ins)
          if ((isBottomPin[p] ?? false) && p.edge.dy > b.boxOrigin.dy + 0.01) p,
      ]..sort((a, b2) => a.pos.dx.compareTo(b2.pos.dx));
  }
}

/// 反转块某一边的针脚槽位序（按当前坐标取有效顺序后反转）；
/// 该边不足 2 个针脚时为恒等变换，返回 false。
bool _nlReverseEdgePins(NlBlock b, _NlEdge edge) {
  final pins = _nlEdgePins(b, edge);
  if (pins.length < 2) return false;
  final reversed = [for (final p in pins.reversed) p.display];
  switch (edge) {
    case _NlEdge.left:
      b.inPinOrder = reversed;
    case _NlEdge.right:
      b.outPinOrder = reversed;
    case _NlEdge.top:
      b.topPinOrder = reversed;
    case _NlEdge.bottom:
      b.bottomPinOrder = reversed;
  }
  return true;
}

enum _NlEdge { left, right, top, bottom }

/// 按选项生成可对 [block] 尝试的针脚变换；返回 false 表示恒等（跳过）。
List<bool Function(NlBlock)> _nlPinTransforms(
  NlBlock block,
  NlRouteOptOptions options,
) {
  return [
    if (options.mirrorVertical)
      (b) {
        b.pinFlip = !b.pinFlip;
        return true;
      },
    if (options.swapLeftPins) (b) => _nlReverseEdgePins(b, _NlEdge.left),
    if (options.swapRightPins) (b) => _nlReverseEdgePins(b, _NlEdge.right),
    if (options.swapTopPins) (b) => _nlReverseEdgePins(b, _NlEdge.top),
    if (options.swapBottomPins) (b) => _nlReverseEdgePins(b, _NlEdge.bottom),
  ];
}

/// 窗口化并行映射（默认并发 = 核数−2，至少 2），保持结果顺序。
Future<List<T>> _nlParallelMap<S, T>(
  List<S> items,
  Future<T> Function(S item) run, {
  int? concurrency,
}) async {
  if (items.isEmpty) return const [];
  final conc = math.min(
    items.length,
    concurrency ?? math.max(2, io.Platform.numberOfProcessors - 2),
  );
  final out = List<T?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      out[i] = await run(items[i]);
    }
  }

  await Future.wait([for (var w = 0; w < conc; w++) worker()]);
  return [for (final v in out) v as T];
}

/// 布线候选评估任务（跨 isolate 传递；全部为可发送纯数据）。
class _NlRouteCandidateJob {
  final List<NlLevel> levels;
  final Size canvasSize;
  final int orderMode;
  final bool nearLoadFirst;

  /// 目标块（null = 只按布线顺序评估，第一阶段用）。
  final String? blockId;

  /// 变换：'shift'（value=dy）/ 'flip' / 'reverse'（value=_NlEdge.index）/
  /// 'shiftPin'（端口针脚对齐，value=dy，定位用 levelIndex/pinIndex）/
  /// 'shiftBelow'（列内非等间距：columnIndex 列中 boxOrigin.dy 超过
  /// boundaryY 的块整体平移 value=dy）。
  final String transform;
  final double value;
  final int levelIndex;
  final int pinIndex;
  final int columnIndex;
  final double boundaryY;

  const _NlRouteCandidateJob({
    required this.levels,
    required this.canvasSize,
    required this.orderMode,
    required this.nearLoadFirst,
    this.blockId,
    this.transform = 'none',
    this.value = 0,
    this.levelIndex = 0,
    this.pinIndex = 0,
    this.columnIndex = -1,
    this.boundaryY = 0,
  });
}

/// 常驻布线候选评估 worker：避免每个候选都重新 spawn isolate。
Future<void> _nlRouteEvalWorker(SendPort main) async {
  final input = ReceivePort();
  main.send(input.sendPort);
  await for (final message in input) {
    final list = message as List<Object?>;
    final job = list[0] as _NlRouteCandidateJob;
    final reply = list[1] as SendPort;
    reply.send(_nlEvalRouteCandidate(job));
  }
}

class _NlRouteEvalPool {
  _NlRouteEvalPool._(this._workers);

  final List<SendPort> _workers;
  var _cursor = 0;
  static Future<_NlRouteEvalPool>? _pending;

  static Future<_NlRouteEvalPool> instance() => _pending ??= _create();

  static Future<_NlRouteEvalPool> _create() async {
    final count = math.max(
      2,
      math.min(12, io.Platform.numberOfProcessors - 2),
    );
    final workers = <SendPort>[];
    for (var i = 0; i < count; i++) {
      final ready = ReceivePort();
      await Isolate.spawn(_nlRouteEvalWorker, ready.sendPort);
      workers.add(await ready.first as SendPort);
      ready.close();
    }
    return _NlRouteEvalPool._(workers);
  }

  Future<(int, int, double, int, int, double, int)> run(
    _NlRouteCandidateJob job,
  ) async {
    final reply = ReceivePort();
    _workers[_cursor++ % _workers.length].send([job, reply.sendPort]);
    final result = await reply.first;
    reply.close();
    return result as (int, int, double, int, int, double, int);
  }
}

/// isolate 内评估一个布线候选：应用变换后布线，返回
/// (交叉, 折弯, 总长, fallback 数, 端口折弯数, 折弯 P95, 同轴重叠对数)。
/// 端口折弯数只在 'shiftPin' 候选时计算（其余为 -1）。重叠对数是硬约束
/// 闸门：任何 >0 的候选都不允许进入择优。不返回布线结果本体——结果以主
/// isolate 的对象标识为准，获胜候选会在主 isolate 重放。
(int, int, double, int, int, double, int) _nlEvalRouteCandidate(
  _NlRouteCandidateJob job,
) {
  var portBends = -1;
  if (job.transform == 'shiftPin') {
    final pin = job.levels[job.levelIndex].ports[job.pinIndex];
    _nlShiftPin(pin, job.value);
  } else if (job.transform == 'shiftBelow') {
    for (final b in job.levels[job.levelIndex].blocks) {
      if (b.column == job.columnIndex &&
          b.boxOrigin.dy > job.boundaryY - 0.01) {
        _nlShiftBlock(b, job.value);
      }
    }
  } else if (job.blockId != null) {
    for (final level in job.levels) {
      for (final b in level.blocks) {
        if (b.id != job.blockId) continue;
        switch (job.transform) {
          case 'shift':
            _nlShiftBlock(b, job.value);
          case 'flip':
            b.pinFlip = !b.pinFlip;
            nlLayoutBlockPins(b);
          case 'reverse':
            _nlReverseEdgePins(b, _NlEdge.values[job.value.round()]);
            nlLayoutBlockPins(b);
        }
      }
    }
  }
  final r = routeNetlistWires(
    job.levels,
    job.canvasSize,
    orderMode: job.orderMode,
    nearLoadFirst: job.nearLoadFirst,
  );
  if (job.transform == 'shiftPin') {
    portBends = nlPortBendCount([job.levels[job.levelIndex]], r);
  }
  final m = nlRoutingMetrics(r);
  return (
    m.crossings,
    m.bends,
    m.length,
    r.fallbackCount,
    portBends,
    m.bendP95,
    nlRoutingOverlapPairCount(r),
  );
}

Future<NlRoutingOptimizationResult> optimizeNetlistRouting(
  List<NlLevel> levels,
  Size canvasSize, {
  NlAutoRouteResult? initial,
  int attempts = 6,
  NlRouteOptOptions? options,
  int parallelMinWires = 16,
  NlRoutingProgress? onProgress,
}) async {
  final baseline = initial ?? routeNetlistWires(levels, canvasSize);
  final totalWires = [for (final l in levels) ...l.wires].length;
  // 多 CPU 并行：候选评估（布线顺序 / 元件移位 / 针脚变换 / 端口对齐）
  // 相互独立，放 isolate 并行跑；获胜候选回主 isolate 重放（结果以主
  // isolate 对象标识为准）。小图串行——isolate 拷贝开销得不偿失。
  final parallel = totalWires >= parallelMinWires;
  final originalY = <NlBlock, double>{
    for (final level in levels)
      for (final block in level.blocks) block: block.boxOrigin.dy,
  };
  var best = baseline;
  var bestMetrics = nlRoutingMetrics(baseline);
  var bestOrder = 0;
  var bestNear = false;
  var bestClean = nlRouteIsClean(baseline);
  onProgress?.call(best, '准备布线', 0);
  await Future<void>.delayed(const Duration(milliseconds: 16));

  if (parallel) {
    // ---- 第一阶段（并行）：多种布线顺序在 isolate 同时评估 ----
    onProgress?.call(
      best,
      '并行评估 $attempts 种布线顺序（${io.Platform.numberOfProcessors} 线程）',
      0,
    );
    final jobs = [
      for (var i = 0; i < attempts; i++)
        _NlRouteCandidateJob(
          levels: levels,
          canvasSize: canvasSize,
          orderMode: i % 7,
          nearLoadFirst: i.isOdd,
        ),
    ];
    final evals = await _nlParallelMap(
      jobs,
      (j) async => (await _NlRouteEvalPool.instance()).run(j),
    );
    for (var i = 0; i < attempts; i++) {
      final (c, b2, l, fb, _, p95, ov) = evals[i];
      if (fb > 0 || ov > 0) continue;
      final metrics = NlRoutingMetrics(
        crossings: c,
        bends: b2,
        length: l,
        bendP95: p95,
      );
      if (!bestClean || _nlCompareMetrics(metrics, bestMetrics) < 0) {
        bestMetrics = metrics;
        bestOrder = i % 7;
        bestNear = i.isOdd;
        bestClean = true;
      }
    }
    // 获胜顺序在主 isolate 重放（结果以主 isolate 对象标识为准）。
    if (bestClean) {
      final replay = routeNetlistWires(
        levels,
        canvasSize,
        orderMode: bestOrder,
        nearLoadFirst: bestNear,
      );
      if (nlRouteIsClean(replay)) {
        best = replay;
        bestMetrics = nlRoutingMetrics(replay);
      } else {
        bestClean = false;
      }
    }
    onProgress?.call(best, '布线顺序已选定', 1);
    await Future<void>.delayed(const Duration(milliseconds: 16));
  } else {
    for (var i = 0; i < attempts; i++) {
      final candidate = routeNetlistWires(
        levels,
        canvasSize,
        orderMode: i % 7,
        nearLoadFirst: i.isOdd,
      );
      if (!nlRouteIsClean(candidate)) continue;
      onProgress?.call(candidate, '尝试布线顺序 ${i + 1}/$attempts', i + 1);
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final metrics = nlRoutingMetrics(candidate);
      if (!bestClean || _nlCompareMetrics(metrics, bestMetrics) < 0) {
        best = candidate;
        bestMetrics = metrics;
        bestOrder = i % 7;
        bestNear = i.isOdd;
        bestClean = true;
      }
      onProgress?.call(best, '尝试布线顺序 ${i + 1}/$attempts', i + 1);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  var movedBlocks = 0;
  var passes = 0;
  var converged = false;
  // 列内上下移动反复迭代，直到某一轮没有任何改善（不再收敛）为止。
  for (var pass = 0; pass < 16; pass++) {
    final hot = _nlHotBlocks(best, levels).toList();
    if (hot.isEmpty) {
      converged = true;
      break;
    }
    var improvedPass = false;
    for (final block in hot.take(8)) {
      final level = levels.firstWhere(
        (l) => l.blocks.any((b) => identical(b, block)),
      );
      final (minTop, maxTop) = _nlVerticalLimits(
        block,
        level,
        originalY: originalY[block],
      );
      final minDy = minTop - block.boxOrigin.dy;
      final maxDy = maxTop - block.boxOrigin.dy;
      final candidates =
          <double>{
                minDy,
                maxDy,
                minDy / 2,
                maxDy / 2,
                -4 * _kGrid,
                4 * _kGrid,
                -2 * _kGrid,
                2 * _kGrid,
                -_kGrid,
                _kGrid,
              }
              .where(
                (d) => d.abs() > 0.01 && d >= minDy - 0.01 && d <= maxDy + 0.01,
              )
              .toList()
            ..sort((a, b) => a.abs().compareTo(b.abs()));
      if (parallel) {
        // ---- 并行：该块的全部移位/针脚变换候选一次批评估 ----
        final jobs = <_NlRouteCandidateJob>[];
        final replays = <(String, double)>[];
        for (final dy in candidates) {
          if (!_nlBlockShiftOk(
            block,
            level,
            dy,
            canvasSize,
            originalY: originalY[block],
          )) {
            continue;
          }
          jobs.add(
            _NlRouteCandidateJob(
              levels: levels,
              canvasSize: canvasSize,
              orderMode: bestOrder,
              nearLoadFirst: bestNear,
              blockId: block.id,
              transform: 'shift',
              value: dy,
            ),
          );
          replays.add(('shift', dy));
        }
        final opts = options;
        if (opts != null &&
            opts.allowsAny &&
            !block.isIo &&
            !block.isContainer) {
          if (opts.mirrorVertical) {
            jobs.add(
              _NlRouteCandidateJob(
                levels: levels,
                canvasSize: canvasSize,
                orderMode: bestOrder,
                nearLoadFirst: bestNear,
                blockId: block.id,
                transform: 'flip',
              ),
            );
            replays.add(('flip', 0));
          }
          for (final (edge, enabled) in [
            (_NlEdge.left, opts.swapLeftPins),
            (_NlEdge.right, opts.swapRightPins),
            (_NlEdge.top, opts.swapTopPins),
            (_NlEdge.bottom, opts.swapBottomPins),
          ]) {
            if (!enabled || _nlEdgePins(block, edge).length < 2) continue;
            jobs.add(
              _NlRouteCandidateJob(
                levels: levels,
                canvasSize: canvasSize,
                orderMode: bestOrder,
                nearLoadFirst: bestNear,
                blockId: block.id,
                transform: 'reverse',
                value: edge.index.toDouble(),
              ),
            );
            replays.add(('reverse', edge.index.toDouble()));
          }
        }
        if (jobs.isNotEmpty) {
          onProgress?.call(
            best,
            '并行评估 ${block.title}（${jobs.length} 候选）',
            movedBlocks,
          );
          final evals = await _nlParallelMap(
            jobs,
            (j) async => (await _NlRouteEvalPool.instance()).run(j),
          );
          var win = -1;
          var winMetrics = bestMetrics;
          for (var i = 0; i < evals.length; i++) {
            final (c, b2, l, fb, _, p95, ov) = evals[i];
            if (fb > 0 || ov > 0) continue;
            final m = NlRoutingMetrics(
              crossings: c,
              bends: b2,
              length: l,
              bendP95: p95,
            );
            if (_nlCompareMetrics(m, winMetrics) < 0) {
              win = i;
              winMetrics = m;
            }
          }
          if (win >= 0) {
            // 主 isolate 重放获胜变换并重新布线。
            final (kind, v) = replays[win];
            switch (kind) {
              case 'shift':
                _nlShiftBlock(block, v);
              case 'flip':
                block.pinFlip = !block.pinFlip;
                nlLayoutBlockPins(block);
              case 'reverse':
                _nlReverseEdgePins(block, _NlEdge.values[v.round()]);
                nlLayoutBlockPins(block);
            }
            best = routeNetlistWires(
              levels,
              canvasSize,
              orderMode: bestOrder,
              nearLoadFirst: bestNear,
            );
            bestMetrics = nlRoutingMetrics(best);
            movedBlocks++;
            improvedPass = true;
            onProgress?.call(
              best,
              '${kind == 'shift' ? '移动' : '变换'} ${block.title}（第 ${pass + 1} 轮）',
              movedBlocks,
            );
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
        }
        continue;
      }
      var bestDy = 0.0;
      var bestCandidate = best;
      var bestCandidateMetrics = bestMetrics;
      var bestCandidateOrder = bestOrder;
      var bestCandidateNear = bestNear;
      for (final dy in candidates) {
        if (!_nlBlockShiftOk(
          block,
          level,
          dy,
          canvasSize,
          originalY: originalY[block],
        )) {
          continue;
        }
        _nlShiftBlock(block, dy);
        final candidate = routeNetlistWires(
          levels,
          canvasSize,
          orderMode: bestOrder,
          nearLoadFirst: bestNear,
        );
        if (candidate.fallbackCount == 0) {
          onProgress?.call(candidate, '试探 ${block.title}', movedBlocks);
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        _nlShiftBlock(block, -dy);
        onProgress?.call(best, '试探 ${block.title}', movedBlocks);
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!nlRouteIsClean(candidate)) continue;
        final metrics = nlRoutingMetrics(candidate);
        if (_nlCompareMetrics(metrics, bestCandidateMetrics) < 0) {
          bestDy = dy;
          bestCandidate = candidate;
          bestCandidateMetrics = metrics;
          bestCandidateOrder = bestOrder;
          bestCandidateNear = bestNear;
        }
      }
      if (bestDy != 0) {
        _nlShiftBlock(block, bestDy);
        best = bestCandidate;
        bestMetrics = bestCandidateMetrics;
        bestOrder = bestCandidateOrder;
        bestNear = bestCandidateNear;
        movedBlocks++;
        improvedPass = true;
        onProgress?.call(
          best,
          '移动 ${block.title}（第 ${pass + 1} 轮）',
          movedBlocks,
        );
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      // ---- 布线优化选项允许的针脚变换（镜像/引脚交换）----
      final opts = options;
      if (opts != null && opts.allowsAny && !block.isIo && !block.isContainer) {
        for (final transform in _nlPinTransforms(block, opts)) {
          final before = _NlPinStyle.of(block);
          if (!transform(block)) continue; // 恒等变换（该边不足 2 针脚）
          nlLayoutBlockPins(block);
          final candidate = routeNetlistWires(
            levels,
            canvasSize,
            orderMode: bestOrder,
            nearLoadFirst: bestNear,
          );
          final metrics = nlRouteIsClean(candidate)
              ? nlRoutingMetrics(candidate)
              : null;
          if (metrics != null && _nlCompareMetrics(metrics, bestMetrics) < 0) {
            best = candidate;
            bestMetrics = metrics;
            movedBlocks++;
            improvedPass = true;
            onProgress?.call(
              best,
              '变换 ${block.title}（第 ${pass + 1} 轮）',
              movedBlocks,
            );
            await Future<void>.delayed(const Duration(milliseconds: 16));
          } else {
            before.restore(block);
            nlLayoutBlockPins(block);
          }
        }
      }
    }
    passes = pass + 1;
    if (!improvedPass) {
      converged = true;
      break;
    }
  }

  // 端口块（输入/输出整组）也允许上下移动；只接受字典序更优的移动。
  for (final level in levels) {
    for (final block in level.blocks.where((b) => b.isIo)) {
      if (block.boxSize.width <= 0) continue;
      final all = [
        for (final b in level.blocks)
          if (b.boxSize.width > 0) b,
      ];
      final top = all.map((b) => b.boxOrigin.dy).reduce(math.min);
      final bottom = all
          .map((b) => b.boxOrigin.dy + b.boxSize.height)
          .reduce(math.max);
      final baseY = originalY[block] ?? block.boxOrigin.dy;
      final minTop = math.max(top, baseY - 10 * _kGrid);
      final maxTop = math.min(
        bottom - block.boxSize.height,
        baseY + 10 * _kGrid,
      );
      final minDy = minTop - block.boxOrigin.dy;
      final maxDy = maxTop - block.boxOrigin.dy;
      final candidates =
          <double>{minDy, maxDy, -2 * _kGrid, 2 * _kGrid, -_kGrid, _kGrid}
              .where(
                (d) => d.abs() > 0.01 && d >= minDy - 0.01 && d <= maxDy + 0.01,
              )
              .toList()
            ..sort((a, b) => a.abs().compareTo(b.abs()));
      if (parallel) {
        // ---- 并行：该端口块的全部移位候选一次批评估 ----
        final jobs = [
          for (final dy in candidates)
            _NlRouteCandidateJob(
              levels: levels,
              canvasSize: canvasSize,
              orderMode: bestOrder,
              nearLoadFirst: bestNear,
              blockId: block.id,
              transform: 'shift',
              value: dy,
            ),
        ];
        if (jobs.isNotEmpty) {
          final evals = await _nlParallelMap(
            jobs,
            (j) async => (await _NlRouteEvalPool.instance()).run(j),
          );
          var win = -1;
          var winBends = bestMetrics.bends;
          for (var i = 0; i < evals.length; i++) {
            final (c, b2, _, fb, _, _, ov) = evals[i];
            if (fb > 0 || ov > 0) continue;
            if (c == bestMetrics.crossings && b2 < winBends) {
              win = i;
              winBends = b2;
            }
          }
          if (win >= 0) {
            _nlShiftBlock(block, candidates[win]);
            best = routeNetlistWires(
              levels,
              canvasSize,
              orderMode: bestOrder,
              nearLoadFirst: bestNear,
            );
            bestMetrics = nlRoutingMetrics(best);
            movedBlocks++;
            onProgress?.call(
              best,
              '移动端口 ${block.isInput ? "IN" : "OUT"}',
              movedBlocks,
            );
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
        }
        continue;
      }
      var bestDy = 0.0;
      var bestCandidate = best;
      var bestCandidateMetrics = bestMetrics;
      for (final dy in candidates) {
        _nlShiftBlock(block, dy);
        final candidate = routeNetlistWires(
          levels,
          canvasSize,
          orderMode: bestOrder,
          nearLoadFirst: bestNear,
        );
        if (candidate.fallbackCount == 0) {
          onProgress?.call(candidate, '试探 ${block.title}', movedBlocks);
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        _nlShiftBlock(block, -dy);
        onProgress?.call(best, '试探 ${block.title}', movedBlocks);
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!nlRouteIsClean(candidate)) continue;
        final metrics = nlRoutingMetrics(candidate);
        if (metrics.crossings == bestMetrics.crossings &&
            metrics.bends < bestCandidateMetrics.bends) {
          bestDy = dy;
          bestCandidate = candidate;
          bestCandidateMetrics = metrics;
        }
      }
      if (bestDy != 0) {
        _nlShiftBlock(block, bestDy);
        best = bestCandidate;
        bestMetrics = bestCandidateMetrics;
        movedBlocks++;
        onProgress?.call(
          best,
          '移动端口 ${block.isInput ? "IN" : "OUT"}',
          movedBlocks,
        );
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
  }

  // 单个端口引脚对齐：把端口移到其所属网的水平走线高度，消掉端口处的折弯。
  // 抽取为闭包复用：第一次在布线中期调用（[maxTargets]=2，与历史一致）；
  // 布线**最后**再以完整候选集调用一次（新增规则：移动所有端口，让与
  // 端口相连的线/总线没有折线）。
  Future<void> portAlignPass({int? maxTargets}) async {
    for (final level in levels) {
      var portBends = nlPortBendCount([level], best);
      final ports = level.ports.toList()
        ..sort((a, b) => a.pos.dy.compareTo(b.pos.dy));
      for (final pin in ports) {
        await Future<void>.delayed(Duration.zero);
        NlWire? wire;
        for (final w in level.wires) {
          if (identical(w.from, pin) || w.loads.any((l) => identical(l, pin))) {
            wire = w;
            break;
          }
        }
        if (wire == null) continue;
        final segs = best.segments[wire];
        if (segs == null) continue;
        final ys =
            <double>{
              for (final (a, b) in segs)
                if ((a.dy - b.dy).abs() < 0.01) a.dy,
            }.where((y) => (y - pin.pos.dy).abs() > 0.01).toList()..sort(
              (a, b) =>
                  (a - pin.pos.dy).abs().compareTo((b - pin.pos.dy).abs()),
            );
        if (ys.isEmpty) continue;
        final direct = identical(wire.from, pin)
            ? [for (final l in wire.loads) l.pos.dy]
            : [wire.from.pos.dy];
        final targets = <double>[...direct, ...ys]
            .where((y) => (y - pin.pos.dy).abs() > 0.01)
            .toSet()
            .take(maxTargets ?? 1 << 30);
        if (parallel) {
          // ---- 并行：该端口针脚的对齐候选一次批评估 ----
          final dys = <double>[];
          final jobs = <_NlRouteCandidateJob>[];
          final pinIndex = level.ports.indexOf(pin);
          final levelIndex = levels.indexOf(level);
          for (final y in targets) {
            final dy = y - pin.pos.dy;
            final nextPinY = pin.pos.dy + dy;
            if (nextPinY < 0 || nextPinY > canvasSize.height) continue;
            final clash = level.ports.any(
              (p) => !identical(p, pin) && (p.pos.dy - y).abs() < 18,
            );
            if (clash) continue;
            dys.add(dy);
            jobs.add(
              _NlRouteCandidateJob(
                levels: levels,
                canvasSize: canvasSize,
                orderMode: bestOrder,
                nearLoadFirst: bestNear,
                transform: 'shiftPin',
                value: dy,
                levelIndex: levelIndex,
                pinIndex: pinIndex,
              ),
            );
          }
          if (jobs.isNotEmpty) {
            final evals = await _nlParallelMap(
              jobs,
              (j) async => (await _NlRouteEvalPool.instance()).run(j),
            );
            var win = -1;
            var winBends = bestMetrics.bends;
            var winPortBends = portBends;
            for (var i = 0; i < evals.length; i++) {
              final (c, b2, _, fb, pb, _, ov) = evals[i];
              if (fb > 0 || ov > 0) continue;
              final improvesMetric =
                  c <= bestMetrics.crossings && b2 < winBends;
              final improvesPort =
                  pb >= 0 &&
                  pb < winPortBends &&
                  c <= bestMetrics.crossings + 1 &&
                  b2 <= bestMetrics.bends;
              if (improvesMetric || improvesPort) {
                win = i;
                winBends = b2;
                winPortBends = pb;
              }
            }
            if (win >= 0) {
              _nlShiftPin(pin, dys[win]);
              best = routeNetlistWires(
                levels,
                canvasSize,
                orderMode: bestOrder,
                nearLoadFirst: bestNear,
              );
              bestMetrics = nlRoutingMetrics(best);
              portBends = nlPortBendCount([level], best);
              movedBlocks++;
              onProgress?.call(best, '对齐端口 ${pin.display}', movedBlocks);
              await Future<void>.delayed(const Duration(milliseconds: 16));
            }
          }
          continue;
        }
        var bestDy = 0.0;
        var bestCandidate = best;
        var bestCandidateMetrics = bestMetrics;
        var bestCandidatePortBends = portBends;
        for (final y in targets) {
          final dy = y - pin.pos.dy;
          final nextPinY = pin.pos.dy + dy;
          if (nextPinY < 0 || nextPinY > canvasSize.height) {
            continue;
          }
          final clash = level.ports.any(
            (p) => !identical(p, pin) && (p.pos.dy - y).abs() < 18,
          );
          if (clash) continue;
          _nlShiftPin(pin, dy);
          final candidate = routeNetlistWires(
            levels,
            canvasSize,
            orderMode: bestOrder,
            nearLoadFirst: bestNear,
          );
          _nlShiftPin(pin, -dy);
          await Future<void>.delayed(const Duration(milliseconds: 16));
          if (!nlRouteIsClean(candidate)) continue;
          final metrics = nlRoutingMetrics(candidate);
          final candidatePortBends = nlPortBendCount([level], candidate);
          final improvesMetric =
              metrics.crossings <= bestMetrics.crossings &&
              metrics.bends < bestCandidateMetrics.bends;
          final improvesPort =
              candidatePortBends < bestCandidatePortBends &&
              metrics.crossings <= bestMetrics.crossings &&
              metrics.bends <= bestMetrics.bends;
          if (improvesMetric || improvesPort) {
            bestDy = dy;
            bestCandidate = candidate;
            bestCandidateMetrics = metrics;
            bestCandidatePortBends = candidatePortBends;
          }
        }
        if (bestDy != 0) {
          _nlShiftPin(pin, bestDy);
          best = bestCandidate;
          bestMetrics = bestCandidateMetrics;
          portBends = bestCandidatePortBends;
          movedBlocks++;
          onProgress?.call(best, '对齐端口 ${pin.display}', movedBlocks);
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }
    }
  }

  // 中期对齐（候选取 2，与历史口径一致）。
  await portAlignPass(maxTargets: 2);

  // ---- 列内非等间距（**布线后期**：走线不再缩短后，同列相邻块间距
  // 在 2~20 Grid 间调整——不含走线的推挤、为走线留空间）----
  if (options?.variableRowGap ?? false) {
    final gapValues = <double>[for (var g = 2; g <= 20; g++) g * _kGrid];
    for (var pass = 0; pass < 8; pass++) {
      var improvedPass = false;
      for (var li = 0; li < levels.length; li++) {
        final level = levels[li];
        final byCol = <int, List<NlBlock>>{};
        for (final b in level.blocks) {
          if (!b.isIo && !b.isContainer) (byCol[b.column] ??= []).add(b);
        }
        for (final e in byCol.entries) {
          e.value.sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
          // 该列全部 (相邻对, 间距值) 候选。
          final jobs = <_NlRouteCandidateJob>[];
          final replays = <(double, double)>[]; // (相邻对下界 y, dy)
          for (var i = 0; i + 1 < e.value.length; i++) {
            final upper = e.value[i];
            final lower = e.value[i + 1];
            final boundary = upper.boxOrigin.dy + upper.boxSize.height;
            final curGap = lower.boxOrigin.dy - boundary;
            for (final v in gapValues) {
              final dy = v - curGap;
              if (dy.abs() < 0.01) continue;
              // 最底块平移后不得越出画布。
              final last = e.value.last;
              if (dy > 0 &&
                  last.boxOrigin.dy + last.boxSize.height + dy >
                      canvasSize.height + 0.01) {
                continue;
              }
              if (parallel) {
                jobs.add(
                  _NlRouteCandidateJob(
                    levels: levels,
                    canvasSize: canvasSize,
                    orderMode: bestOrder,
                    nearLoadFirst: bestNear,
                    transform: 'shiftBelow',
                    value: dy,
                    levelIndex: li,
                    columnIndex: e.key,
                    boundaryY: boundary,
                  ),
                );
              }
              replays.add((boundary, dy));
            }
          }
          if (replays.isEmpty) continue;
          if (parallel) {
            final evals = await _nlParallelMap(
              jobs,
              (j) async => (await _NlRouteEvalPool.instance()).run(j),
            );
            var win = -1;
            var winMetrics = bestMetrics;
            for (var i = 0; i < evals.length; i++) {
              final (c, b2, l, fb, _, p95, ov) = evals[i];
              if (fb > 0 || ov > 0) continue;
              final m = NlRoutingMetrics(
              crossings: c,
              bends: b2,
              length: l,
              bendP95: p95,
            );
              if (_nlCompareMetrics(m, winMetrics) < 0) {
                win = i;
                winMetrics = m;
              }
            }
            if (win >= 0) {
              final (boundary, dy) = replays[win];
              for (final b in e.value) {
                if (b.boxOrigin.dy > boundary - 0.01) _nlShiftBlock(b, dy);
              }
              best = routeNetlistWires(
                levels,
                canvasSize,
                orderMode: bestOrder,
                nearLoadFirst: bestNear,
              );
              bestMetrics = nlRoutingMetrics(best);
              movedBlocks++;
              improvedPass = true;
              onProgress?.call(best, '调整列间距（第 ${pass + 1} 轮）', movedBlocks);
              await Future<void>.delayed(const Duration(milliseconds: 16));
            }
          } else {
            var win = -1;
            var winMetrics = bestMetrics;
            for (var i = 0; i < replays.length; i++) {
              final (boundary, dy) = replays[i];
              for (final b in e.value) {
                if (b.boxOrigin.dy > boundary - 0.01) _nlShiftBlock(b, dy);
              }
              final candidate = routeNetlistWires(
                levels,
                canvasSize,
                orderMode: bestOrder,
                nearLoadFirst: bestNear,
              );
              for (final b in e.value) {
                if (b.boxOrigin.dy > boundary - 0.01) _nlShiftBlock(b, -dy);
              }
              if (!nlRouteIsClean(candidate)) continue;
              final metrics = nlRoutingMetrics(candidate);
              if (_nlCompareMetrics(metrics, winMetrics) < 0) {
                win = i;
                winMetrics = metrics;
              }
            }
            if (win >= 0) {
              final (boundary, dy) = replays[win];
              for (final b in e.value) {
                if (b.boxOrigin.dy > boundary - 0.01) _nlShiftBlock(b, dy);
              }
              best = routeNetlistWires(
                levels,
                canvasSize,
                orderMode: bestOrder,
                nearLoadFirst: bestNear,
              );
              bestMetrics = nlRoutingMetrics(best);
              movedBlocks++;
              improvedPass = true;
              onProgress?.call(best, '调整列间距（第 ${pass + 1} 轮）', movedBlocks);
              await Future<void>.delayed(const Duration(milliseconds: 16));
            }
          }
        }
      }
      if (!improvedPass) break;
    }
  }

  // ---- 端口对齐终段（布线**最后**的规则）：以完整候选集移动所有端口，
  // 让与端口相连接的线/总线没有折线 ----
  await portAlignPass();

  // ---- 端口落轨：单负载端口若"出脚后立刻竖直"，把端口针脚上下移 1~3
  // Grid 到最近的水平主线，并只重布这一条网（局部 rip-up，其它网不动）。
  // 只在线本身折弯减少、不引入硬约束、交叉不增超过 1 时采纳。----
  Future<void> portTrackPass() async {
    for (final level in levels) {
      for (final pin in level.ports) {
        // 末段每个端口都让出一次事件循环，避免连续局部重布把 UI 卡成无响应。
        await Future<void>.delayed(Duration.zero);
        NlWire? wire;
        for (final w in level.wires) {
          if (identical(w.from, pin) ||
              w.loads.any((l) => identical(l, pin))) {
            wire = w;
            break;
          }
        }
        if (wire == null || wire.loads.length != 1) continue;
        final segs = best.segments[wire];
        if (segs == null || segs.isEmpty) continue;
        final escape = nlPinEscape(pin, _kGrid);
        var dogleg = false;
        final ys = <double>{};
        for (final (a, b) in segs) {
          final isH = (a.dy - b.dy).abs() < 0.01;
          if (isH) ys.add(a.dy);
          if (!isH &&
              ((a - escape).distance < 0.01 ||
                  (b - escape).distance < 0.01)) {
            dogleg = true;
          }
        }
        if (!dogleg) continue;
        final oldBends = nlRoutingBendPoints(
          segs,
          junctions: best.junctions[wire] ?? const [],
        ).length;
        final targets = ys
            .where((y) => (y - pin.pos.dy).abs() > 2)
            .toList()
          ..sort(
            (a, b) => (a - pin.pos.dy).abs().compareTo(
              (b - pin.pos.dy).abs(),
            ),
          );
        for (final target in targets.take(2)) {
          final dy = target - pin.pos.dy;
          if (dy.abs() < 2 || dy.abs() > 3 * _kGrid) continue;
          _nlShiftPin(pin, dy);
          final candidate = nlRerouteSingleWire(
            levels,
            canvasSize,
            best,
            wire,
          );
          if (candidate != null) {
            final newBends = nlRoutingBendPoints(
              candidate.segments[wire] ?? const [],
              junctions: candidate.junctions[wire] ?? const [],
            ).length;
            final metrics = nlRoutingMetrics(candidate);
            if (nlRouteIsClean(candidate) &&
                newBends < oldBends &&
                metrics.crossings <= bestMetrics.crossings + 1) {
              best = candidate;
              bestMetrics = metrics;
              movedBlocks++;
              onProgress?.call(
                best,
                '端口落轨 ${pin.display}',
                movedBlocks,
              );
              await Future<void>.delayed(const Duration(milliseconds: 16));
              break;
            }
          }
          _nlShiftPin(pin, -dy);
        }
      }
    }
  }

  await portTrackPass();

  // ---- 元件落轨：单负载元件的引脚若"出脚后立刻竖直"，把整块上下移
  // 1~3 Grid 到最近水平主线；只局部重布该块关联的网，其它网不动。----
  Future<void> blockTrackPass() async {
    for (var pass = 0; pass < 2; pass++) {
      var improved = false;
      for (final level in levels) {
        for (final block in level.blocks) {
          // 每个元件候选前让出事件循环（局部重布是主 isolate 同步计算）。
          await Future<void>.delayed(Duration.zero);
          if (block.isIo || block.isContainer || block.boxSize.height <= 0) {
            continue;
          }
          final pins = [...block.ins, ...block.outs];
          if (pins.isEmpty) continue;
          NlWire? wireOf(NlPin p) {
            for (final w in level.wires) {
              if (identical(w.from, p) ||
                  w.loads.any((l) => identical(l, p))) {
                return w;
              }
            }
            return null;
          }

          final incident = <NlWire>{};
          for (final p in pins) {
            final w = wireOf(p);
            if (w != null) incident.add(w);
          }
          if (incident.isEmpty) continue;
          // 多负载网无法只重布一条线：整块移动后改为全图重布（数量很少）。
          final hasMulti = incident.any((w) => w.loads.length != 1);
          final doglegPins = <NlPin>[];
          final targets = <double>{};
          for (final pin in pins) {
            final wire = wireOf(pin);
            if (wire == null) continue;
            final segs = best.segments[wire];
            if (segs == null || segs.isEmpty) continue;
            final escape = nlPinEscape(pin, _kGrid);
            var dogleg = false;
            for (final (a, b) in segs) {
              final isH = (a.dy - b.dy).abs() < 0.01;
              if (isH) targets.add(a.dy);
              if (!isH &&
                  ((a - escape).distance < 0.01 ||
                      (b - escape).distance < 0.01)) {
                dogleg = true;
              }
            }
            if (dogleg) doglegPins.add(pin);
          }
          if (doglegPins.isEmpty) continue;
          var movedThisBlock = false;
          for (final pin in doglegPins) {
            final ordered = targets
                .where((y) => (y - pin.pos.dy).abs() > 2)
                .toList()
              ..sort(
                (a, b) => (a - pin.pos.dy).abs().compareTo(
                  (b - pin.pos.dy).abs(),
                ),
              );
            for (final target in ordered.take(2)) {
              final dy = target - pin.pos.dy;
              if (dy.abs() < 2 || dy.abs() > 3 * _kGrid) continue;
              final top = block.boxOrigin.dy + dy;
              if (top < 0 ||
                  top + block.boxSize.height > canvasSize.height) {
                continue;
              }
              if (!_nlBlockShiftOk(block, level, dy, canvasSize)) continue;
              _nlShiftBlock(block, dy);
              final candidate = hasMulti
                  ? routeNetlistWires(
                      levels,
                      canvasSize,
                      orderMode: bestOrder,
                      nearLoadFirst: bestNear,
                    )
                  : nlRerouteWires(levels, canvasSize, best, incident);
              if (candidate != null) {
                final metrics = nlRoutingMetrics(candidate);
                if (nlRouteIsClean(candidate) &&
                    metrics.bends < bestMetrics.bends &&
                    metrics.crossings <= bestMetrics.crossings + 1) {
                  best = candidate;
                  bestMetrics = metrics;
                  movedBlocks++;
                  improved = true;
                  movedThisBlock = true;
                  onProgress?.call(
                    best,
                    '元件落轨 ${block.title}',
                    movedBlocks,
                  );
                  await Future<void>.delayed(
                    const Duration(milliseconds: 16),
                  );
                  break;
                }
              }
              _nlShiftBlock(block, -dy);
            }
            if (movedThisBlock) break;
          }
        }
      }
      if (!improved) break;
    }
  }

  await blockTrackPass();

  onProgress?.call(best, '优化完成', movedBlocks);
  return NlRoutingOptimizationResult(
    result: best,
    initialLength: nlRoutedLength(baseline),
    length: bestMetrics.length,
    attempts: attempts,
    initialCrossings: nlRoutingMetrics(baseline).crossings,
    initialBends: nlRoutingMetrics(baseline).bends,
    crossings: bestMetrics.crossings,
    bends: bestMetrics.bends,
    movedBlocks: movedBlocks,
    passes: passes,
    converged: converged,
  );
}

/// 方向编号：0=右、1=左、2=下、3=上（与 A* 的 dx/dy 表一致）。
int _nlDirectionOf(Offset from, Offset to) {  if ((to.dx - from.dx).abs() >= (to.dy - from.dy).abs()) {
    return to.dx >= from.dx ? 0 : 1;
  }
  return to.dy >= from.dy ? 2 : 3;
}

/// 引脚向外 1 个 Grid 的逃生点：侧边按 `pos - edge` 的方向，端口按数据流方向。
Offset nlPinEscape(NlPin pin, double grid) {
  if (pin.isPort) {
    return pin.pos + Offset(pin.dir == NetlistPortDir.input ? grid : -grid, 0);
  }
  final delta = pin.pos - pin.edge;
  if (delta.dx.abs() >= delta.dy.abs() && delta.dx.abs() > 0.01) {
    return pin.pos + Offset(delta.dx.sign * grid, 0);
  }
  if (delta.dy.abs() > 0.01) {
    return pin.pos + Offset(0, delta.dy.sign * grid);
  }
  return pin.pos + Offset(grid, 0);
}

int _nlWireOrderHash(NlWire wire, int salt) {
  var hash = 17;
  final key =
      '${wire.label}|${wire.from.ownerTitle}|${wire.from.port}|'
      '${wire.loads.length}|${wire.bits.length}';
  for (final unit in key.codeUnits) {
    hash = 0x1fffffff & (hash * 31 + unit);
  }
  return hash ^ (salt * 0x9e3779b1);
}

double _nlWireStraightLength(NlWire wire) {
  var total = 0.0;
  for (final (a, b) in nlStraightWireSegments(wire)) {
    total += (b - a).distance;
  }
  return total;
}

/// 把实际引脚逃生点接到 A* 的网格起点/终点；两者可能因布局坐标带 0.5
/// 而不重合，必须用正交短折线补齐，否则线段之间会出现微小断口。
void _nlAppendOrthogonalPoints(List<Offset> out, Offset from, Offset to) {
  if ((from - to).distance < 0.01) return;
  if ((from.dx - to.dx).abs() < 0.01 || (from.dy - to.dy).abs() < 0.01) {
    out.add(to);
    return;
  }
  out
    ..add(Offset(to.dx, from.dy))
    ..add(to);
}

List<Offset> _nlSimplifyPath(List<Offset> points) {
  final out = <Offset>[];
  for (final p in points) {
    if (out.isNotEmpty && (out.last - p).distance < 0.01) continue;
    out.add(p);
  }
  var i = 1;
  while (i < out.length - 1) {
    final a = out[i - 1], b = out[i], c = out[i + 1];
    final sameX = (a.dx - b.dx).abs() < 0.01 && (b.dx - c.dx).abs() < 0.01;
    final sameY = (a.dy - b.dy).abs() < 0.01 && (b.dy - c.dy).abs() < 0.01;
    if (sameX || sameY) {
      out.removeAt(i);
    } else {
      i++;
    }
  }
  return out;
}

/// 修补 A* 网格端点与带 0.5 偏移的引脚/树节点之间的小断口，
/// 把同一根网的多个连通分量用最短正交短线接起来。
List<(Offset, Offset)> _nlConnectWireTree(List<(Offset, Offset)> segments) {
  final edges = [...segments];
  final nodes = <String, Offset>{};
  final parent = <String, String>{};
  String key(Offset p) => '${(p.dx * 100).round()},${(p.dy * 100).round()}';
  String find(String x) {
    var r = x;
    while (parent[r] != r) {
      r = parent[r]!;
    }
    return r;
  }

  void union(String a, String b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[rb] = ra;
  }

  for (final (a, b) in edges) {
    nodes[key(a)] = a;
    nodes[key(b)] = b;
    parent.putIfAbsent(key(a), () => key(a));
    parent.putIfAbsent(key(b), () => key(b));
    union(key(a), key(b));
  }
  for (var guard = 0; guard < 24; guard++) {
    final byRoot = <String, List<String>>{};
    for (final k in nodes.keys) {
      (byRoot[find(k)] ??= []).add(k);
    }
    if (byRoot.length <= 1) break;
    String? bestA, bestB;
    var bestCost = double.infinity;
    for (var i = 0; i < byRoot.length; i++) {
      for (var j = i + 1; j < byRoot.length; j++) {
        for (final ka in byRoot.values.elementAt(i)) {
          for (final kb in byRoot.values.elementAt(j)) {
            final a = nodes[ka]!, b = nodes[kb]!;
            final dx = (a.dx - b.dx).abs(), dy = (a.dy - b.dy).abs();
            final cost = dx + dy;
            if (cost > 8 * _kGrid || cost < 0.01) continue;
            if (dx < 0.01 || dy < 0.01) {
              if (cost < bestCost) {
                bestCost = cost;
                bestA = ka;
                bestB = kb;
              }
            }
          }
        }
      }
    }
    if (bestA == null || bestB == null) break;
    final a = nodes[bestA]!, b = nodes[bestB]!;
    edges.add((a, b));
    parent.putIfAbsent(bestA, () => bestA!);
    parent.putIfAbsent(bestB, () => bestB!);
    union(bestA, bestB);
  }
  return _nlMergeSegments(edges);
}

List<(Offset, Offset)> _nlMergeSegments(List<(Offset, Offset)> segments) {
  final horizontal = <int, List<(double, double)>>{};
  final vertical = <int, List<(double, double)>>{};
  for (final (a, b) in segments) {
    if ((a.dy - b.dy).abs() < 0.01) {
      final y = (a.dy * 100).round();
      (horizontal[y] ??= []).add((math.min(a.dx, b.dx), math.max(a.dx, b.dx)));
    } else if ((a.dx - b.dx).abs() < 0.01) {
      final x = (a.dx * 100).round();
      (vertical[x] ??= []).add((math.min(a.dy, b.dy), math.max(a.dy, b.dy)));
    }
  }

  List<(Offset, Offset)> flush(
    Map<int, List<(double, double)>> groups,
    bool isHorizontal,
  ) {
    final out = <(Offset, Offset)>[];
    for (final entry in groups.entries) {
      final axis = entry.key / 100.0;
      final intervals = entry.value..sort((a, b) => a.$1.compareTo(b.$1));
      var lo = intervals.first.$1;
      var hi = intervals.first.$2;
      void emit() {
        out.add(
          isHorizontal
              ? (Offset(lo, axis), Offset(hi, axis))
              : (Offset(axis, lo), Offset(axis, hi)),
        );
      }

      for (var i = 1; i < intervals.length; i++) {
        final next = intervals[i];
        if (next.$1 <= hi + 0.01) {
          hi = math.max(hi, next.$2);
        } else {
          emit();
          lo = next.$1;
          hi = next.$2;
        }
      }
      emit();
    }
    return out;
  }

  return [...flush(horizontal, true), ...flush(vertical, false)];
}

/// 同网 T/十字分支点：某点处线段方向数 ≥3 时记为分支点。
List<Offset> nlTreeJunctions(List<(Offset, Offset)> segments) {
  final points = <(int, int)>{};
  final horizontals = <(Offset, Offset)>[];
  final verticals = <(Offset, Offset)>[];
  for (final (a, b) in segments) {
    points.add(((a.dx * 100).round(), (a.dy * 100).round()));
    points.add(((b.dx * 100).round(), (b.dy * 100).round()));
    if ((a.dy - b.dy).abs() < 0.01) {
      horizontals.add((a, b));
    } else if ((a.dx - b.dx).abs() < 0.01) {
      verticals.add((a, b));
    }
  }
  for (final (h1, h2) in horizontals) {
    final y = h1.dy;
    final lo = math.min(h1.dx, h2.dx), hi = math.max(h1.dx, h2.dx);
    for (final (v1, v2) in verticals) {
      final x = v1.dx;
      final vlo = math.min(v1.dy, v2.dy), vhi = math.max(v1.dy, v2.dy);
      if (x >= lo - 0.01 &&
          x <= hi + 0.01 &&
          y >= vlo - 0.01 &&
          y <= vhi + 0.01) {
        points.add(((x * 100).round(), (y * 100).round()));
      }
    }
  }
  final out = <Offset>[];
  for (final (x, y) in points) {
    final p = Offset(x / 100.0, y / 100.0);
    var dirs = 0;
    for (final (a, b) in segments) {
      final onH = (a.dy - b.dy).abs() < 0.01 && (p.dy - a.dy).abs() < 0.01;
      final onV = (a.dx - b.dx).abs() < 0.01 && (p.dx - a.dx).abs() < 0.01;
      if (onH) {
        final lo = math.min(a.dx, b.dx), hi = math.max(a.dx, b.dx);
        if (p.dx < lo - 0.01 || p.dx > hi + 0.01) continue;
        if (p.dx > lo + 0.01 && p.dx < hi - 0.01) {
          dirs |= 0x1 | 0x2;
        } else {
          final other = (p.dx - a.dx).abs() < 0.01 ? b : a;
          dirs |= other.dx > p.dx ? 0x1 : 0x2;
        }
      } else if (onV) {
        final lo = math.min(a.dy, b.dy), hi = math.max(a.dy, b.dy);
        if (p.dy < lo - 0.01 || p.dy > hi + 0.01) continue;
        if (p.dy > lo + 0.01 && p.dy < hi - 0.01) {
          dirs |= 0x4 | 0x8;
        } else {
          final other = (p.dy - a.dy).abs() < 0.01 ? b : a;
          dirs |= other.dy > p.dy ? 0x4 : 0x8;
        }
      }
    }
    if (_nlPopCount(dirs) >= 3) out.add(p);
  }
  return out;
}

int _nlPopCount(int v) {
  var n = 0;
  while (v != 0) {
    n += v & 1;
    v >>= 1;
  }
  return n;
}

void _nlMarkPathBends(
  List<int> bendOwner,
  List<int> path,
  int columns,
  int wireId, {
  required int startDir,
  required int goalDir,
}) {
  var previous = startDir;
  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i], b = path[i + 1];
    final dir = (a % columns) != (b % columns)
        ? (b % columns > a % columns ? 0 : 1)
        : (b ~/ columns > a ~/ columns ? 2 : 3);
    if (dir != previous) {
      final owner = bendOwner[a];
      if (owner == -1 || owner == wireId) bendOwner[a] = wireId;
    }
    previous = dir;
  }
  if (path.length >= 2 && previous != goalDir) {
    final goal = path.last;
    final owner = bendOwner[goal];
    if (owner == -1 || owner == wireId) bendOwner[goal] = wireId;
  }
}

void _nlMarkPathEdges(
  List<int> usedH,
  List<int> usedV,
  int columns,
  List<int> path,
  int wireId,
) {
  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i], b = path[i + 1];
    final ca = a % columns, cb = b % columns;
    final ra = a ~/ columns, rb = b ~/ columns;
    if (ra == rb) {
      final idx = ra * (columns - 1) + (ca < cb ? ca : cb);
      usedH[idx] = wireId;
    } else {
      final idx = (ra < rb ? ra : rb) * columns + ca;
      usedV[idx] = wireId;
    }
  }
}

List<int>? _nlAStarRoute({
  required int columns,
  required int rows,
  required List<bool> blocked,
  required List<int> usedH,
  required List<int> usedV,
  required List<int> bendOwner,
  required int wireId,
  required int start,
  required int goal,
  required int startDir,
  required int goalDir,
}) {
  if (start == goal) return [start];
  final cellCount = columns * rows;
  final best = List<double>.filled(cellCount * 4, double.infinity);
  final parent = List<int>.filled(cellCount * 4, -1);
  final heap = _NlMinHeap();
  const dx = [1, -1, 0, 0];
  const dy = [0, 0, 1, -1];

  int rowOf(int cell) => cell ~/ columns;
  int colOf(int cell) => cell % columns;
  double heuristic(int cell) =>
      ((colOf(cell) - colOf(goal)).abs() + (rowOf(cell) - rowOf(goal)).abs())
          .toDouble();

  final goalCol = colOf(goal), goalRow = rowOf(goal);

  bool edgeFree(int c0, int r0, int c1, int r1, int dir) {
    if (r0 == r1) {
      final minC = c0 < c1 ? c0 : c1;
      final owner = usedH[r0 * (columns - 1) + minC];
      return owner == -1 || owner == wireId;
    }
    final owner = usedV[math.min(r0, r1) * columns + c0];
    return owner == -1 || owner == wireId;
  }

  /// 与其它网平行贴行的软惩罚：1 Grid 内重罚、2 Grid 内轻罚，让走线尽量
  /// 分散，而不是挤成一条“厚带”。同网/空行不计。
  double parallelPenalty(int c0, int r0, int c1, int r1) {
    var penalty = 0.0;
    if (r0 == r1) {
      final minC = c0 < c1 ? c0 : c1;
      for (final d in const [1, 2]) {
        for (final sign in const [-1, 1]) {
          final rr = r0 + d * sign;
          if (rr < 0 || rr >= rows) continue;
          final owner = usedH[rr * (columns - 1) + minC];
          if (owner != -1 && owner != wireId) {
            penalty += d == 1 ? _kNlParallelNear : _kNlParallelFar;
          }
        }
      }
    } else {
      final minR = math.min(r0, r1);
      for (final d in const [1, 2]) {
        for (final sign in const [-1, 1]) {
          final cc = c0 + d * sign;
          if (cc < 0 || cc >= columns) continue;
          final owner = usedV[minR * columns + cc];
          if (owner != -1 && owner != wireId) {
            penalty += d == 1 ? _kNlParallelNear : _kNlParallelFar;
          }
        }
      }
    }
    return penalty;
  }

  for (var dir = 0; dir < 4; dir++) {
    // 禁止从逃生点直接折返（会绕着引脚走一个小 U）；垂直出道计一次转弯。
    if (dir == (startDir ^ 1)) continue;
    final nc = colOf(start) + dx[dir];
    final nr = rowOf(start) + dy[dir];
    if (nc < 0 || nc >= columns || nr < 0 || nr >= rows) continue;
    final next = nr * columns + nc;
    if (blocked[next]) continue;
    final bendHit =
        dir != startDir && bendOwner[start] != -1 && bendOwner[start] != wireId;
    if (!edgeFree(colOf(start), rowOf(start), nc, nr, dir)) {
      continue;
    }
    final state = next * 4 + dir;
    final cost = 1.0 + (bendHit ? _kNlBendCost : 0.0);
    if (cost < best[state]) {
      best[state] = cost;
      parent[state] = -2;
      heap.push(cost + (nc - goalCol).abs() + (nr - goalRow).abs(), state);
    }
  }

  while (heap.isNotEmpty) {
    final (f, state) = heap.pop();
    final cell = state ~/ 4;
    final dir = state % 4;
    if (cell == goal) {
      final cells = <int>[goal];
      var s = state;
      while (true) {
        final p = parent[s];
        if (p == -2) {
          cells.add(start);
          break;
        }
        if (p < 0) break;
        cells.add(p ~/ 4);
        s = p;
      }
      return cells.reversed.toList();
    }
    final g = best[state];
    if (f > g + heuristic(cell) + 0.001) continue;
    final c = colOf(cell), r = rowOf(cell);
    for (var nd = 0; nd < 4; nd++) {
      if (nd == (dir ^ 1)) continue;
      final nc = c + dx[nd];
      final nr = r + dy[nd];
      if (nc < 0 || nc >= columns || nr < 0 || nr >= rows) continue;
      final next = nr * columns + nc;
      if (blocked[next]) continue;
      if (!edgeFree(c, r, nc, nr, nd)) continue;
      var cost = g + 1;
      if (nd != dir) cost += _kNlTurnCost;
      cost += parallelPenalty(c, r, nc, nr);
      if (nd != dir && bendOwner[cell] != -1 && bendOwner[cell] != wireId) {
        cost += _kNlBendCost;
      }
      final nextState = next * 4 + nd;
      if (cost >= best[nextState] - 0.0001) continue;
      best[nextState] = cost;
      parent[nextState] = state;
      heap.push(cost + (nc - goalCol).abs() + (nr - goalRow).abs(), nextState);
    }
  }
  return null;
}

class _NlMinHeap {
  final List<(double, int)> _items = [];

  bool get isNotEmpty => _items.isNotEmpty;

  void push(double priority, int value) {
    _items.add((priority, value));
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_items[parent].$1 <= _items[i].$1) break;
      final tmp = _items[parent];
      _items[parent] = _items[i];
      _items[i] = tmp;
      i = parent;
    }
  }

  (double, int) pop() {
    final top = _items.first;
    final last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      var i = 0;
      while (true) {
        final left = i * 2 + 1;
        final right = left + 1;
        var smallest = i;
        if (left < _items.length && _items[left].$1 < _items[smallest].$1) {
          smallest = left;
        }
        if (right < _items.length && _items[right].$1 < _items[smallest].$1) {
          smallest = right;
        }
        if (smallest == i) break;
        final tmp = _items[i];
        _items[i] = _items[smallest];
        _items[smallest] = tmp;
        i = smallest;
      }
    }
    return top;
  }
}

/// 端点数：所有有连线的 pin（去重，仅统计连线端点，不含单纯 I/O 端口）。
int nlEndpointCount(NetlistDiagramModel model) {
  final connected = <NlPin>{};
  for (final level in model.flattened()) {
    for (final wire in level.wires) {
      connected.add(wire.from);
      connected.addAll(wire.loads);
    }
  }
  return connected.length;
}

/// 布局优化进度（节点数 + 当前总直线长度 + 当前最优模型）。
class NlLayoutOptimizationProgress {
  final NetlistDiagramModel model;
  final int nodes;
  final double length;
  final double initialLength;
  final int evaluations;
  final int rounds;

  const NlLayoutOptimizationProgress({
    required this.model,
    required this.nodes,
    required this.length,
    required this.initialLength,
    required this.evaluations,
    required this.rounds,
  });
}

/// 布局优化结果（含最终采纳的行序、镜像块与引脚顺序，供重建模型复用）。
class NlLayoutOptimizationResult {
  final NetlistDiagramModel model;
  final int nodes;
  final double initialLength;
  final double length;
  final int evaluations;
  final int rounds;
  final bool improved;
  final Map<int, List<String>> rowOrders;
  final Set<String> mirroredBlocks;
  final Map<String, List<String>> pinOrders;

  const NlLayoutOptimizationResult({
    required this.model,
    required this.nodes,
    required this.initialLength,
    required this.length,
    required this.evaluations,
    required this.rounds,
    required this.improved,
    this.rowOrders = const {},
    this.mirroredBlocks = const {},
    this.pinOrders = const {},
  });
}

/// 布局候选评估任务（跨 isolate 传递；全部为可发送纯数据）。
class _NlLayoutCandidateJob {
  final YosysNetlist netlist;
  final String moduleName;
  final Set<String> expanded;
  final NlNetTopology topology;
  final Map<int, List<String>> rowOrders;
  final Map<String, List<String>> pinOrders;
  final Set<String> mirrored;
  final double longWireWeight;

  const _NlLayoutCandidateJob({
    required this.netlist,
    required this.moduleName,
    required this.expanded,
    required this.topology,
    required this.rowOrders,
    required this.pinOrders,
    required this.mirrored,
    this.longWireWeight = 0,
  });
}

/// isolate 内评估一个布局候选：构建模型并返回总直线长度。
double _nlEvalLayoutCandidate(_NlLayoutCandidateJob job) {
  final mod = job.netlist.module(job.moduleName);
  if (mod == null) return double.infinity;
  final model = buildNetlistDiagramModel(
    mod,
    expanded: job.expanded,
    resolve: (t) => job.netlist.resolveInstance(t) ?? job.netlist.module(t),
    rowOrders: job.rowOrders,
    mirroredBlocks: job.mirrored,
    pinOrders: job.pinOrders,
  );
  return nlLayoutScore(
    model,
    topology: job.topology,
    longWireWeight: job.longWireWeight,
  );
}

/// **只优化布局**（不布线）：在列内重排块的行序，按 [topology] 的总直线长度
/// 严格择优，直到一整轮没有任何改善（不动点）。每评估少量候选就让出事件
/// 循环，UI 可持续刷新进度与当前最优模型。
///
/// 收敛保证：每次采纳都使总长度严格下降（>0.5）且长度有下界，故改善次数
/// 有限，必在有限轮内到达不动点；[maxRounds] 只是防异常的死循环守卫，
/// 不得小到截断正常收敛（64 曾在 32 单元网表上提前截断：行序/引脚/镜像
/// 三阶段互相影响，需要更多轮迭代）。
///
/// 多 CPU 并行：传入 [netlist] 且单元数 ≥ [parallelMinCells] 时，候选
/// （行序移动/引脚交换/镜像）按批在 isolate 中并行构建评估（模型与网表均
/// 为纯数据可跨 isolate 传递），每批采纳最优者；小图保持串行。
Future<NlLayoutOptimizationResult> optimizeNetlistLayout(
  NetlistModule module, {
  Set<String> expanded = const {},
  NetlistModule? Function(String cellType)? resolve,
  NlNetTopology topology = NlNetTopology.clique,
  bool allowMirror = false,
  bool swapPins = false,
  bool allowGlobalReorder = false,
  double longWireWeight = 0,
  Map<int, List<String>> initialRowOrders = const {},
  Set<String> initialMirroredBlocks = const {},
  Map<String, List<String>> initialPinOrders = const {},
  int maxRounds = 512,
  YosysNetlist? netlist,
  int parallelMinCells = 12,
  void Function(NlLayoutOptimizationProgress progress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final plan = <int, List<String>>{
    for (final e in initialRowOrders.entries) e.key: [...e.value],
  };
  final pinPlan = <String, List<String>>{
    for (final e in initialPinOrders.entries) e.key: [...e.value],
  };
  var mirrored = <String>{...initialMirroredBlocks};

  NetlistDiagramModel build(
    Map<int, List<String>> orders,
    Map<String, List<String>> pinOrds,
    Set<String> mirrors,
  ) => buildNetlistDiagramModel(
    module,
    expanded: expanded,
    resolve: resolve,
    rowOrders: orders,
    mirroredBlocks: mirrors,
    pinOrders: pinOrds,
  );

  var best = build(plan, pinPlan, mirrored);
  var initialLength = nlLayoutScore(
    best,
    topology: topology,
    longWireWeight: longWireWeight,
  );
  var bestLength = initialLength;
  final nodes = best.blocks.where((b) => !b.isIo).length;
  var evaluations = 0;
  var rounds = 0;
  var improved = false;
  var improvedThisRound = false;

  /// 默认列内行序（按默认布局的行号）。
  final defaultOrders = <int, List<String>>{};
  final byColumn = <int, List<NlBlock>>{};
  for (final b in best.blocks) {
    if (b.isIo) continue;
    (byColumn[b.column] ??= []).add(b);
  }
  for (final e in byColumn.entries) {
    e.value.sort((a, b) => a.row.compareTo(b.row));
    defaultOrders[e.key] = [for (final b in e.value) b.id];
  }

  /// 每个多输入块的默认输入槽位顺序（按当前布局的针脚 y 从上到下）。
  final defaultPinOrders = <String, List<String>>{};
  for (final b in best.blocks) {
    if (b.isIo) continue;
    final side = [
      for (final p in b.ins)
        if (!netlistSymbolIsBottomPin(b.cell, p.port)) p,
    ]..sort((a, c) => a.edge.dy.compareTo(c.edge.dy));
    if (side.length >= 2) {
      // 用显示名（多驱动拆分针脚共享端口名，按端口名会撞槽位重叠）。
      defaultPinOrders[b.id] = [for (final p in side) p.display];
    }
  }

  /// 可尝试镜像的块：至少有两个引脚（单引脚镜像没有上下可换的对象）。
  final mirrorCandidates = [
    for (final b in best.blocks)
      if (!b.isIo && b.ins.length + b.outs.length >= 2) b.id,
  ];

  List<String> orderOf(int col) => plan[col] ?? defaultOrders[col] ?? const [];

  /// 全局重排：总列数（初始布局的最大列号 +1）与块的当前列（按当前
  /// plan/defaultOrders 推导）。
  final totalCols = defaultOrders.keys.isEmpty
      ? 0
      : defaultOrders.keys.reduce(math.max) + 1;

  int? columnOfBlock(String id) {
    for (var c = 0; c < totalCols; c++) {
      if (orderOf(c).contains(id)) return c;
    }
    return null;
  }

  /// 全部可移动块（初始默认列里的全部非 IO 块）。
  final allBlockIds = [for (final e in defaultOrders.entries) ...e.value];

  /// 生成把 [id] 从 [srcCol] 移到其它任意列任意槽位的候选方案。
  List<(Map<int, List<String>>, Map<String, List<String>>, Set<String>)>
  globalReorderCandidates(String id, int srcCol) {
    final batch =
        <(Map<int, List<String>>, Map<String, List<String>>, Set<String>)>[];
    for (var tc = 0; tc < totalCols; tc++) {
      if (tc == srcCol) continue;
      final tgtOrder = orderOf(tc);
      for (var slot = 0; slot <= tgtOrder.length; slot++) {
        final newSrc = [...orderOf(srcCol)]..remove(id);
        final newTgt = [...tgtOrder]..insert(slot, id);
        batch.add((
          {
            for (final e in plan.entries) e.key: [...e.value],
            srcCol: newSrc,
            tc: newTgt,
          },
          {
            for (final e in pinPlan.entries) e.key: [...e.value],
          },
          {...mirrored},
        ));
      }
    }
    return batch;
  }

  /// 引脚交换候选的当前槽位顺序：按**当前模型**的针脚 y 坐标取。
  /// 不能用 initialPinOrders/defaultPinOrders 的初始物理顺序——镜像翻转
  /// 会反转针脚位置，初始顺序在翻转后生成的交换候选恰好是恒等变换，
  /// 而真正该尝试的另一种排列永远不被生成（"要跑两次才收敛"的根因：
  /// 第二次运行按新初始模型重算默认序才试到）。
  List<String> pinsOf(String id) {
    for (final b in best.blocks) {
      if (b.id != id) continue;
      final side = [
        for (final p in b.ins)
          if (!netlistSymbolIsBottomPin(b.cell, p.port)) p,
      ]..sort((a, c) => a.edge.dy.compareTo(c.edge.dy));
      return [for (final p in side) p.display];
    }
    return pinPlan[id] ?? defaultPinOrders[id] ?? const [];
  }

  void emit() {
    onProgress?.call(
      NlLayoutOptimizationProgress(
        model: best,
        nodes: nodes,
        length: bestLength,
        initialLength: initialLength,
        evaluations: evaluations,
        rounds: rounds,
      ),
    );
  }

  NlLayoutOptimizationResult result() => NlLayoutOptimizationResult(
    model: best,
    nodes: nodes,
    initialLength: initialLength,
    length: bestLength,
    evaluations: evaluations,
    rounds: rounds,
    improved: improved,
    rowOrders: {
      for (final e in plan.entries) e.key: [...e.value],
    },
    mirroredBlocks: {...mirrored},
    pinOrders: {
      for (final e in pinPlan.entries) e.key: [...e.value],
    },
  );

  bool cancelled() => isCancelled?.call() ?? false;

  /// 评估一个候选；严格更短才接受，并把候选方案写回 [accept]。
  Future<bool> evaluate(
    NetlistDiagramModel model,
    void Function() accept,
  ) async {
    evaluations++;
    final length = nlLayoutScore(
      model,
      topology: topology,
      longWireWeight: longWireWeight,
    );
    var accepted = false;
    if (length < bestLength - 0.5) {
      best = model;
      bestLength = length;
      accept();
      improvedThisRound = true;
      improved = true;
      accepted = true;
      emit();
    }
    // 每 2 个候选让出一次事件循环，保证进度浮层与画布能刷新。
    if (evaluations % 2 == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return accepted;
  }

  /// 多 CPU 并行模式：候选按批在 isolate 构建评估，每批采纳最优者。
  final parallel = netlist != null && nodes >= parallelMinCells;

  /// 并行评估一批候选方案（完整 plan/pinPlan/mirrored 三元组）；
  /// 严格更短的最优者被采纳并本地重建模型，返回是否有采纳。
  Future<bool> evaluateBatch(
    List<(Map<int, List<String>>, Map<String, List<String>>, Set<String>)>
    batch,
  ) async {
    if (batch.isEmpty) return false;
    evaluations += batch.length;
    final jobs = [
      for (final (orders, pinOrds, mirrors) in batch)
        _NlLayoutCandidateJob(
          netlist: netlist!,
          moduleName: module.name,
          expanded: expanded,
          topology: topology,
          rowOrders: orders,
          pinOrders: pinOrds,
          mirrored: mirrors,
          longWireWeight: longWireWeight,
        ),
    ];
    final lengths = await _nlParallelMap(
      jobs,
      (j) => Isolate.run(() => _nlEvalLayoutCandidate(j)),
    );
    var win = -1;
    var winLength = bestLength;
    for (var i = 0; i < lengths.length; i++) {
      if (lengths[i] < winLength - 0.5) {
        win = i;
        winLength = lengths[i];
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (win < 0) return false;
    final (orders, pinOrds, mirrors) = batch[win];
    plan
      ..clear()
      ..addAll(orders);
    pinPlan
      ..clear()
      ..addAll(pinOrds);
    mirrored = mirrors;
    best = build(plan, pinPlan, mirrored);
    bestLength = winLength;
    improvedThisRound = true;
    improved = true;
    emit();
    return true;
  }

  emit();

  for (var round = 0; round < maxRounds; round++) {
    rounds = round + 1;
    improvedThisRound = false;

    if (parallel) {
      // ---- 列内行序（并行）：逐列批量评估全部 (from,to) 移动 ----
      for (final col in defaultOrders.keys) {
        while (true) {
          if (cancelled()) return result();
          final order = orderOf(col);
          if (order.length < 2) break;
          final batch =
              <
                (Map<int, List<String>>, Map<String, List<String>>, Set<String>)
              >[];
          for (var from = 0; from < order.length; from++) {
            for (var to = 0; to < order.length; to++) {
              if (from == to) continue;
              final candidate = [...order];
              final id = candidate.removeAt(from);
              candidate.insert(to, id);
              batch.add((
                {
                  for (final e in plan.entries) e.key: [...e.value],
                  col: candidate,
                },
                {
                  for (final e in pinPlan.entries) e.key: [...e.value],
                },
                {...mirrored},
              ));
            }
          }
          if (!await evaluateBatch(batch)) break;
        }
      }

      // ---- 全局重排（并行）：逐块批量评估全部跨列移动 ----
      if (allowGlobalReorder) {
        for (final id in allBlockIds) {
          while (true) {
            if (cancelled()) return result();
            final srcCol = columnOfBlock(id);
            if (srcCol == null) break;
            if (!await evaluateBatch(globalReorderCandidates(id, srcCol))) {
              break;
            }
          }
        }
      }

      // ---- 引脚交换（并行）：逐块批量评估全部槽位对换 ----
      if (swapPins) {
        for (final id in defaultPinOrders.keys) {
          while (true) {
            if (cancelled()) return result();
            final order = pinsOf(id);
            if (order.length < 2) break;
            final batch =
                <
                  (
                    Map<int, List<String>>,
                    Map<String, List<String>>,
                    Set<String>,
                  )
                >[];
            for (var i = 0; i < order.length; i++) {
              for (var j = i + 1; j < order.length; j++) {
                final candidate = [...order];
                final tmp = candidate[i];
                candidate[i] = candidate[j];
                candidate[j] = tmp;
                batch.add((
                  {
                    for (final e in plan.entries) e.key: [...e.value],
                  },
                  {
                    for (final e in pinPlan.entries) e.key: [...e.value],
                    id: candidate,
                  },
                  {...mirrored},
                ));
              }
            }
            if (!await evaluateBatch(batch)) break;
          }
        }
      }

      // ---- 镜像元件（并行）：批量评估全部单块翻转 ----
      if (allowMirror) {
        while (true) {
          if (cancelled()) return result();
          final batch =
              <
                (Map<int, List<String>>, Map<String, List<String>>, Set<String>)
              >[];
          for (final id in mirrorCandidates) {
            final candidate = {...mirrored};
            if (!candidate.remove(id)) candidate.add(id);
            batch.add((
              {
                for (final e in plan.entries) e.key: [...e.value],
              },
              {
                for (final e in pinPlan.entries) e.key: [...e.value],
              },
              candidate,
            ));
          }
          if (!await evaluateBatch(batch)) break;
        }
      }

      if (!improvedThisRound) break;
      continue;
    }

    // ---- 列内行序：把任一块移到该列任一槽位 ----
    // 采纳后按**新行序**重新扫描：继续用列首捕获的旧行序生成候选，会漏掉
    // 采纳后才出现的更优移动（曾是要跑两三次才收敛的原因之一）。
    for (final col in defaultOrders.keys) {
      while (true) {
        final order = orderOf(col);
        if (order.length < 2) break;
        var adopted = false;
        for (var from = 0; from < order.length && !adopted; from++) {
          for (var to = 0; to < order.length; to++) {
            if (from == to) continue;
            if (cancelled()) return result();
            final candidate = [...order];
            final id = candidate.removeAt(from);
            candidate.insert(to, id);
            final orders = {
              for (final e in plan.entries) e.key: [...e.value],
              col: candidate,
            };
            adopted = await evaluate(
              build(orders, pinPlan, mirrored),
              () => plan[col] = candidate,
            );
            if (adopted) break;
          }
        }
        if (!adopted) break;
      }
    }

    // ---- 全局重排：元件不限于原来的列，可移到任意已有列的任意槽位 ----
    if (allowGlobalReorder) {
      for (final id in allBlockIds) {
        while (true) {
          if (cancelled()) return result();
          final srcCol = columnOfBlock(id);
          if (srcCol == null) break;
          var adopted = false;
          for (var tc = 0; tc < totalCols && !adopted; tc++) {
            if (tc == srcCol) continue;
            final tgtOrder = orderOf(tc);
            for (var slot = 0; slot <= tgtOrder.length; slot++) {
              if (cancelled()) return result();
              final newSrc = [...orderOf(srcCol)]..remove(id);
              final newTgt = [...tgtOrder]..insert(slot, id);
              final orders = {
                for (final e in plan.entries) e.key: [...e.value],
                srcCol: newSrc,
                tc: newTgt,
              };
              adopted = await evaluate(build(orders, pinPlan, mirrored), () {
                plan[srcCol] = newSrc;
                plan[tc] = newTgt;
              });
              if (adopted) break;
            }
          }
          if (!adopted) break;
        }
      }
    }

    // ---- 引脚交换：交换同一多输入块内两个输入槽位 ----
    if (swapPins) {
      for (final id in defaultPinOrders.keys) {
        while (true) {
          final order = pinsOf(id);
          if (order.length < 2) break;
          var adopted = false;
          for (var i = 0; i < order.length && !adopted; i++) {
            for (var j = i + 1; j < order.length; j++) {
              if (cancelled()) return result();
              final candidate = [...order];
              final tmp = candidate[i];
              candidate[i] = candidate[j];
              candidate[j] = tmp;
              final next = {
                for (final e in pinPlan.entries) e.key: [...e.value],
                id: candidate,
              };
              adopted = await evaluate(
                build(plan, next, mirrored),
                () => pinPlan[id] = candidate,
              );
              if (adopted) break;
            }
          }
          if (!adopted) break;
        }
      }
    }

    // ---- 镜像元件：逐个块独立尝试上下镜像（不强制全部镜像）----
    if (allowMirror) {
      var adoptedAny = true;
      while (adoptedAny) {
        adoptedAny = false;
        for (final id in mirrorCandidates) {
          if (cancelled()) return result();
          final candidate = {...mirrored};
          if (!candidate.remove(id)) candidate.add(id);
          if (await evaluate(
            build(plan, pinPlan, candidate),
            () => mirrored = candidate,
          )) {
            adoptedAny = true;
          }
        }
      }
    }

    if (!improvedThisRound) break;
  }

  emit();
  return result();
}

/// 端口纵向槽位分配：保序、最小位移、整 Grid 对齐。
///
/// 输入为每个端口「理想 y」（相连引脚的行），约定相邻端口至少间隔
/// [_kPortGlyphH]。直接顺序下推（`y = max(y0, prev + 15)`）会把同一目标行的
/// 后续端口一路挤到很远；这里先做保序最小二乘（PAVA 等距回归），再整 Grid
/// 取整并前向修正间距，使整体位移最小、对齐的端口数最多。
List<(NlPin, double)> nlPlacePortRows(
  List<(NlPin, double)> targets,
  double topY,
) {
  final sorted = [...targets]..sort((a, b) {
    final c = a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$1.port.compareTo(b.$1.port);
  });
  final n = sorted.length;
  if (n == 0) return const [];
  const h = _kPortGlyphH;
  final u = [for (var i = 0; i < n; i++) sorted[i].$2 - i * h];

  // PAVA：把 u 拟合为非降序列（块内取均值），平方误差最小。
  final blocks = <({int start, int end, double sum, int count})>[];
  for (var i = 0; i < n; i++) {
    var block = (start: i, end: i, sum: u[i], count: 1);
    while (blocks.isNotEmpty &&
        blocks.last.sum / blocks.last.count > block.sum / block.count) {
      final prev = blocks.removeLast();
      block = (
        start: prev.start,
        end: block.end,
        sum: prev.sum + block.sum,
        count: prev.count + block.count,
      );
    }
    blocks.add(block);
  }
  final fitted = List<double>.filled(n, 0);
  for (final b in blocks) {
    final value = b.sum / b.count;
    for (var i = b.start; i <= b.end; i++) {
      fitted[i] = value;
    }
  }

  final out = <(NlPin, double)>[];
  var prev = double.negativeInfinity;
  for (var i = 0; i < n; i++) {
    var y = _gridRound(fitted[i] + i * h);
    if (prev.isFinite && y < prev + h) y = prev + h;
    out.add((sorted[i].$1, y));
    prev = y;
  }
  // 顶部越界时整体下移（保持相对间距）。
  final first = out.first.$2;
  if (first < topY - 0.01) {
    final shift = _gridRound(topY - first);
    for (var i = 0; i < out.length; i++) {
      out[i] = (out[i].$1, out[i].$2 + shift);
    }
  }
  return out;
}

NetlistDiagramModel _buildNetlistDiagramModelOnce(
  NetlistModule module, {
  int? columns,
  Set<String> expanded = const {},
  NetlistModule? Function(String cellType)? resolve,
  String idPrefix = '',
  int depth = 0,
  Map<int, List<String>> rowOrders = const {},
  Set<String> mirroredBlocks = const {},
  Map<String, List<String>> pinOrders = const {},
  NlLayoutAlgorithm layout = NlLayoutAlgorithm.compact,
  Map<int, int> columnGapExtra = const {},
}) {
  final blocks = <String, NlBlock>{};
  final cellBlocks = <NetlistCell, NlBlock>{};

  // ---- 单元块 ----
  for (final c in module.cells) {
    final b = NlBlock(
      id: '$idPrefix${c.name}',
      title: c.label,
      subtitle: c.typeLabel,
      cell: c,
      ins: [
        for (final p in c.ins)
          NlPin(
            port: p.port,
            display: p.display,
            width: p.width,
            bits: [for (final n in p.nets) ...n.bits],
            nets: p.nets,
            isBus: p.width > 1,
            constText: p.isConst ? p.nets.map((n) => n.name).join('|') : null,
            netNames: [
              for (final n in p.nets)
                if (!n.isConst) n.display,
            ],
          ),
      ],
      outs: [
        for (final p in c.outs)
          NlPin(
            port: p.port,
            display: p.display,
            width: p.width,
            bits: [for (final n in p.nets) ...n.bits],
            nets: p.nets,
            isBus: p.width > 1,
            constText: p.isConst ? p.nets.map((n) => n.name).join('|') : null,
            netNames: [
              for (final n in p.nets)
                if (!n.isConst) n.display,
            ],
          ),
      ],
    );
    blocks[c.name] = b;
    cellBlocks[c] = b;
  }

  // ---- 层级「原位展开」：把展开的实例块变成**容器**（内部递归构建子模型）----
  // 容器尺寸 = 子模型画布 + 外框留白 + 边缘针脚区；子模型整体平移进容器内。
  // 父级的网仍旧接容器边缘同排针脚（针脚就是实例的针脚，名与位宽不变）。
  if (expanded.isNotEmpty && resolve != null && depth < 3) {
    for (final c in module.cells) {
      if (!c.isInstance || !expanded.contains(c.name)) continue;
      final child =
          resolve(c.type) ??
          (c.moduleRef == null ? null : resolve(c.moduleRef!));
      if (child == null || child.cells.isEmpty) continue;
      final b = blocks[c.name];
      if (b == null) continue;
      b.sub = _buildNetlistDiagramModelOnce(
        child,
        expanded: expanded,
        resolve: resolve,
        idPrefix: '$idPrefix${c.name}/',
        depth: depth + 1,
      );
      // 子模型整体平移进容器：顶部标题带 + 左右边缘针脚区留白。
      b.subOffset = const Offset(_kContainerPadX, _kContainerHead);
    }
  }

  // ---- 顶层端口（输入在左；输出与双向在右，符号与标注区分方向）----
  final inPins = <NlPin>[
    for (final p in module.inputs)
      NlPin(
        port: p.name,
        display: p.name,
        width: p.net.width,
        bits: p.net.bits,
        nets: [p.net],
        isBus: p.net.width > 1,
        netNames: [p.name],
        dir: p.dir,
        isPort: true,
      ),
  ];
  final outPins = <NlPin>[
    for (final p in module.outputs)
      NlPin(
        port: p.name,
        display: p.name,
        width: p.net.width,
        bits: p.net.bits,
        nets: [p.net],
        isBus: p.net.width > 1,
        netNames: [p.name],
        dir: p.dir,
        isPort: true,
      ),
    // 双向端口与输出同列（Vivado Elaborated Design 同惯例），符号为六边形
    // 并标 `IO`。
    for (final p in module.inouts)
      NlPin(
        port: p.name,
        display: p.name,
        width: p.net.width,
        bits: p.net.bits,
        nets: [p.net],
        isBus: p.net.width > 1,
        netNames: [p.name],
        dir: p.dir,
        isPort: true,
      ),
  ];
  final inBlock = NlBlock(
    id: '#in',
    title: '',
    subtitle: '',
    isIo: true,
    isInput: true,
    outs: inPins,
  );
  final outBlock = NlBlock(
    id: '#out',
    title: '',
    subtitle: '',
    isIo: true,
    isInput: false,
    ins: outPins,
  );

  // ---- 比特 → 驱动引脚 / 负载引脚 ----
  final driver = <int, NlPin>{};
  for (final b in blocks.values) {
    for (final p in b.outs) {
      for (final bit in p.bits) {
        driver.putIfAbsent(bit, () => p);
      }
    }
  }
  for (final p in inPins) {
    for (final bit in p.bits) {
      driver[bit] = p;
    }
  }
  // 双向端口也要登记为「驱动方」，否则 inout 网没有任何驱动方 → **连线
  // 完全不画**（端口悬空在画布上）。画法上是「端口 → 被连引脚」的直线。
  for (final p in outPins) {
    if (p.dir != NetlistPortDir.inout) continue;
    for (final bit in p.bits) {
      driver.putIfAbsent(bit, () => p);
    }
  }

  // ---- 多驱动负载针脚按连续位域拆分 ----
  // 例如 B[23:0] 的三个字节来自不同 MUX 时，拆成 B[23:16]、B[15:8]、
  // B[7:0] 三个独立针脚；单驱动总线和双向端口保持原对象。
  List<NlPin> splitLoadPin(NlPin p) {
    if (p.dir == NetlistPortDir.inout || p.bits.length < 2) return [p];
    final drivers = <NlPin?>{for (final bit in p.bits) driver[bit]};
    if (drivers.length <= 1) return [p];
    final fallback = NetlistNet(name: '', bits: p.bits);
    final netOf = <int, NetlistNet>{
      for (final net in p.nets.isEmpty ? [fallback] : p.nets)
        for (final bit in net.bits) bit: net,
    };
    final runs = <({List<int> bits, NetlistNet net, int lo, int hi})>[];
    var start = 0;
    for (var i = 1; i <= p.bits.length; i++) {
      final newRun =
          i == p.bits.length ||
          !identical(driver[p.bits[i]], driver[p.bits[start]]) ||
          !identical(netOf[p.bits[i]], netOf[p.bits[start]]);
      if (!newRun) continue;
      runs.add((
        bits: p.bits.sublist(start, i),
        net: netOf[p.bits[start]] ?? fallback,
        lo: start,
        hi: i - 1,
      ));
      start = i;
    }
    runs.sort((a, b) => b.lo.compareTo(a.lo));
    return [
      for (final run in runs)
        NlPin(
          port: p.port,
          display: run.lo == 0 && run.hi == p.bits.length - 1
              ? p.display
              : run.lo == run.hi
              ? '${p.port}[${run.lo}]'
              : '${p.port}[${run.hi}:${run.lo}]',
          width: run.bits.length,
          bits: run.bits,
          nets: [run.net],
          isBus: run.bits.length > 1,
          constText: run.net.isConst ? run.net.name : null,
          netNames: [if (!run.net.isConst) run.net.display],
          dir: p.dir,
          isPort: p.isPort,
        ),
    ];
  }

  for (final b in blocks.values) {
    final split = [for (final p in b.ins) ...splitLoadPin(p)];
    b.ins
      ..clear()
      ..addAll(split);
  }
  final splitOutPins = [for (final p in outPins) ...splitLoadPin(p)];
  outPins
    ..clear()
    ..addAll(splitOutPins);

  final pinOwner = <NlPin, NlBlock>{};
  for (final b in blocks.values) {
    for (final p in [...b.ins, ...b.outs]) {
      pinOwner[p] = b;
      // 网名派生用（`<实例>_<端口>`）：须在建网之前登记。
      p.ownerTitle = b.title;
    }
  }
  // **顶层端口也必须登记属主**：否则 `colOfPin` 对端口退化成 -1、行序恒为 0，
  // 端口与针脚对不齐、网名标签错行。
  for (final p in inBlock.outs) {
    pinOwner[p] = inBlock;
  }
  for (final p in outBlock.ins) {
    pinOwner[p] = outBlock;
  }

  // ---- 网：按实际比特段与负载集合聚合 ----
  // 单比特接入总线针脚的一位时仍是一条单信号网；同一输出总线的多个
  // 命名段若连接同一组负载，则仍合并为完整总线，不画成无意义的平行线。
  final loadPinsByDriverBit = <int, Set<NlPin>>{};
  void addLoad(NlPin load) {
    for (final bit in load.bits) {
      final d = driver[bit];
      if (d == null || identical(d, load)) continue;
      (loadPinsByDriverBit[bit] ??= <NlPin>{}).add(load);
    }
  }

  for (final b in blocks.values) {
    for (final p in b.ins) {
      addLoad(p);
    }
  }
  for (final p in outPins) {
    addLoad(p);
  }

  final sourcePins = <NlPin>[
    for (final b in blocks.values) ...b.outs,
    ...inPins,
    for (final p in outPins)
      if (p.dir == NetlistPortDir.inout) p,
  ];
  bool sameLoads(Set<NlPin> a, Set<NlPin> b) =>
      a.length == b.length && a.every(b.contains);
  final wires = <NlWire>[];
  for (final from in sourcePins) {
    final groups = <({List<int> bits, Set<NlPin> loads})>[];
    final sourceNets = from.nets.isEmpty
        ? [NetlistNet(name: '', bits: from.bits)]
        : from.nets;
    for (final net in sourceNets) {
      final bits = [
        for (final bit in net.bits)
          if (identical(driver[bit], from)) bit,
      ];
      if (bits.isEmpty) continue;
      // 只保留真正连接到当前负载的比特；否则 17bit 输出只接低 8 位时，
      // 网线仍会错误携带全部 17 位，位域标签也无法确定。
      final connectedBits = [
        for (final bit in bits)
          if ((loadPinsByDriverBit[bit]?.isNotEmpty ?? false)) bit,
      ];
      if (connectedBits.isEmpty) continue;
      final loads = <NlPin>{
        for (final bit in connectedBits) ...loadPinsByDriverBit[bit]!,
      };
      var index = -1;
      for (var i = 0; i < groups.length; i++) {
        if (sameLoads(groups[i].loads, loads)) {
          index = i;
          break;
        }
      }
      if (index < 0) {
        groups.add((bits: connectedBits, loads: loads));
      } else {
        for (final bit in connectedBits) {
          if (!groups[index].bits.contains(bit)) groups[index].bits.add(bit);
        }
      }
    }
    for (final group in groups) {
      final loads = group.loads.toList();
      wires.add(
        NlWire(
          from,
          loads,
          _netLabelForBits(from, group.bits, loads),
          bits: group.bits,
        ),
      );
    }
  }

  // ---- 分层与列分配 ----
  // compact：BFS 最短路径 + 等比压列 + 依赖平均行序（历史默认）。
  // layered：DFS 切回边 + 最长路径分层 + DP 压列 + 中位数/交换排序（实验）。
  final cellDeps = <NlBlock, Set<NlBlock>>{};
  final cellLoads = <NlBlock, Set<NlBlock>>{};
  for (final w in wires) {
    final a = pinOwner[w.from];
    if (a == null || a.isIo) continue;
    for (final l in w.loads) {
      final b = pinOwner[l];
      if (b == null || identical(a, b)) continue;
      (cellDeps[b] ??= {}).add(a);
      (cellLoads[a] ??= {}).add(b);
    }
  }
  final allBlocks = [
    inBlock,
    for (final c in module.cells) blocks[c.name]!,
    outBlock,
  ];
  final idealCols = math.sqrt(math.max(1, module.cells.length) * 4.0).round();
  final rowsOf = <int, List<NlBlock>>{};
  late final int colCount;

  if (layout == NlLayoutAlgorithm.layered && module.cells.isNotEmpty) {
    final ids = [for (final c in module.cells) c.name];
    final indexOf = <String, int>{
      for (var i = 0; i < ids.length; i++) ids[i]: i,
    };
    final edges = <(int, int)>[];
    for (final b in blocks.values) {
      if (b.isIo) continue;
      final v = indexOf[b.id];
      if (v == null) continue;
      for (final d in cellDeps[b] ?? const <NlBlock>{}) {
        final u = indexOf[d.id];
        if (u != null && u != v) edges.add((u, v));
      }
    }
    final result = layoutLayeredNetlist(
      nodeCount: ids.length,
      edges: edges,
      maxColumns: math.max(6, (columns ?? idealCols).clamp(6, 24)),
    );
    for (var i = 0; i < ids.length; i++) {
      blocks[ids[i]]!.column = result.column[i];
    }
    colCount = result.columnCount;
    for (final b in blocks.values) {
      if (b.isIo) continue;
      (rowsOf[b.column] ??= []).add(b);
    }
    for (final e in rowsOf.entries) {
      final order = result.order[e.key];
      if (order == null) continue;
      final rank = <int, int>{
        for (var i = 0; i < order.length; i++) order[i]: i,
      };
      e.value.sort((a, b) {
        final ra = rank[indexOf[a.id]] ?? 1 << 20;
        final rb = rank[indexOf[b.id]] ?? 1 << 20;
        return ra != rb ? ra.compareTo(rb) : a.title.compareTo(b.title);
      });
    }
  } else {
    // ---- 分层：BFS 最短路径（环按首次到达定层）----
    // 不能用「最长路径 + 迭代松弛」：时序反馈环会让互相依赖的单元层层加码
    // （实测 32 个单元被推到几十层），压缩后全挤进首列、右侧留下成片空列。
    final level = <NlBlock, int>{};
    final bfsOrder = <NlBlock>[];
    for (final b in blocks.values) {
      if (b.isIo) continue;
      if ((cellDeps[b] ?? const <NlBlock>{}).isEmpty) {
        level[b] = 0;
        bfsOrder.add(b);
      }
    }
    var head = 0;
    while (head < bfsOrder.length) {
      final b = bfsOrder[head++];
      for (final n in cellLoads[b] ?? const <NlBlock>{}) {
        if (level.containsKey(n)) continue;
        level[n] = (level[b] ?? 0) + 1;
        bfsOrder.add(n);
      }
    }
    // 无源可达的纯环节点（无外部输入的自反馈）：按已知依赖定层。
    for (final b in blocks.values) {
      if (b.isIo || level.containsKey(b)) continue;
      var lv = 0;
      for (final d in cellDeps[b] ?? const <NlBlock>{}) {
        lv = math.max(lv, (level[d] ?? 0) + 1);
      }
      level[b] = lv;
    }
    var maxLevel = 0;
    for (final b in blocks.values) {
      if (b.isIo) continue;
      maxLevel = math.max(maxLevel, level[b] ?? 0);
    }

    // ---- 列分配：层级压缩到有限列数 ----
    // 纯最长路径分层会把长链展成 1:N 的不可读长条（实测 32 单元 → 28 列、
    // 16905×602），这里把层级等比压缩到 6~14 列（按单元数的平方根量级），
    // 列内再按依赖平均行序排序，得到接近 2:1~4:1 的版式。
    final maxCols = math.max(
      1,
      math.min(maxLevel + 1, (columns ?? idealCols).clamp(6, 24)),
    );
    int colOfLevel(int lv) => maxLevel + 1 <= maxCols
        ? lv
        : (lv * maxCols ~/ (maxLevel + 1)).clamp(0, maxCols - 1);
    colCount = module.cells.isEmpty ? 0 : colOfLevel(maxLevel) + 1;
    for (final b in blocks.values) {
      if (b.isIo) continue;
      b.column = colOfLevel(level[b] ?? 0);
    }

    /// 单元在列内的排序权重：其驱动单元的平均行序（无驱动则 0）。
    double sortKey(NlBlock b) {
      final deps = cellDeps[b];
      if (deps == null || deps.isEmpty) return 0;
      var s = 0.0;
      var n = 0;
      for (final d in deps) {
        s += (d.row + 0.5).toDouble();
        n++;
      }
      return n == 0 ? 0 : s / n;
    }

    // 逐列迭代排序（多趟使行序稳定）。
    for (final b in blocks.values) {
      if (b.isIo) continue;
      (rowsOf[b.column] ??= []).add(b);
    }
    for (final e in rowsOf.entries) {
      e.value.sort((a, b) => a.title.compareTo(b.title));
    }
    for (var pass = 0; pass < 4; pass++) {
      for (var c = 0; c < colCount; c++) {
        final list = rowsOf[c];
        if (list == null) continue;
        for (var i = 0; i < list.length; i++) {
          list[i].row = i;
        }
        list.sort((a, b) {
          final k = sortKey(a).compareTo(sortKey(b));
          return k != 0 ? k : a.title.compareTo(b.title);
        });
      }
    }
  }

  inBlock.column = -1;
  outBlock.column = colCount;
  for (final e in rowsOf.entries) {
    for (var i = 0; i < e.value.length; i++) {
      e.value[i].row = i;
    }
  }

  // ---- 行序/跨列覆盖（布局优化器用）：列号 → 块 id 顺序 ----
  // 列出的块按列出顺序进入目标列（**可以跨列移动**——「允许全局重排」
  // 的候选）；未列出的块保持原列与默认相对顺序，排在列出块之后。
  if (rowOrders.isNotEmpty) {
    // 第一遍：收集每个目标列的列出块（按列出顺序），同时从原列移除。
    final movedTo = <int, List<NlBlock>>{};
    final claimed = <NlBlock>{};
    for (final entry in rowOrders.entries) {
      if (entry.key < 0 || entry.key >= colCount) continue;
      final list = movedTo[entry.key] ??= [];
      for (final id in entry.value) {
        for (final colList in rowsOf.values) {
          final idx = colList.indexWhere(
            (b) => b.id == id && !claimed.contains(b),
          );
          if (idx < 0) continue;
          final b = colList.removeAt(idx);
          claimed.add(b);
          list.add(b);
          break;
        }
      }
    }
    // 第二遍：目标列 = 列出块（按序）+ 未列出块（默认相对顺序）；列号同步。
    for (final entry in movedTo.entries) {
      final target = rowsOf[entry.key] ??= [];
      rowsOf[entry.key] = [...entry.value, ...target];
      for (final b in entry.value) {
        b.column = entry.key;
      }
    }
    // 行号重排。
    for (final e in rowsOf.entries) {
      for (var i = 0; i < e.value.length; i++) {
        e.value[i].row = i;
      }
    }
  }

  // ---- 块尺寸 ----
  Size boxSizeOf(NlBlock b) {
    final sub = b.sub;
    if (sub != null) {
      // 容器：子模型画布 + 外框留白（顶部标题带 + 左右边缘针脚区 + 底部余量）。
      return Size(
        sub.canvasSize.width + _kContainerPadX * 2,
        _kContainerHead + sub.canvasSize.height + _kContainerPadY,
      );
    }
    final rows = math.max(1, math.max(b.ins.length, b.outs.length));
    var w = netlistSymbolMinWidth(b.cell);
    for (final p in [...b.ins, ...b.outs]) {
      w = math.max(w, _tw(p.display, 10) * 2 + 34);
    }
    w = _gridCeil(math.min(w, _kMaxBlockW));
    if (b.ins.any((p) => netlistSymbolIsBottomPin(b.cell, p.port)) &&
        (w / _kGrid).round().isOdd) {
      w += _kGrid;
    }
    var h = _kPinPadV * 2 + rows * _kPinRowH;
    if (b.outs.length == 1 && netlistSymbolCentersOutput(b.cell)) {
      // 组合符号本体最小 4 Grid 高，避免 NOT 等单输入门被压成扁平三角形；
      // 2 Grid 针脚行使输出中心与对称分布的输入针脚仍保持 Grid 对齐。
      h = math.max(h, 4 * _kGrid);
    }
    return Size(w, h);
  }

  for (final b in allBlocks) {
    b.boxSize = boxSizeOf(b);
    b.size = Size(b.boxSize.width, b.boxSize.height);
  }

  int colOfPin(NlPin p) {
    final o = pinOwner[p];
    return o == null ? -1 : o.column;
  }

  // ---- 列 x 游标（列间预留针脚让位与列间距）----
  var maxInTextW = 0.0, maxOutTextW = 0.0;
  for (final p in inPins) {
    maxInTextW = math.max(maxInTextW, _tw(p.display, 10));
  }
  for (final p in outPins) {
    maxOutTextW = math.max(maxOutTextW, _tw(p.display, 10));
  }
  maxInTextW = _gridCeil(maxInTextW);
  maxOutTextW = _gridCeil(maxOutTextW);
  const inTextLeft = _kMargin;
  final inGlyphX = inTextLeft + maxInTextW + _kPortTextGap;
  final inputAreaRight = inGlyphX + _kPortGlyphW;

  // ---- 列间通道宽度：按跨列网数预留走线车道 ----
  // 每多一条需要跨过该边界的网，就多留一个 Grid；封顶 8 条避免画布爆炸，
  // 剩余拥挤由自动路由器在块区外绕行。
  int colOfPinForGap(NlPin p) => pinOwner[p]?.column ?? -1;
  final channelLoads = <int, int>{};
  for (final wire in wires) {
    var lo = colOfPinForGap(wire.from);
    var hi = lo;
    for (final load in wire.loads) {
      final c = colOfPinForGap(load);
      lo = math.min(lo, c);
      hi = math.max(hi, c);
    }
    for (var boundary = lo; boundary < hi; boundary++) {
      channelLoads[boundary] = (channelLoads[boundary] ?? 0) + 1;
    }
  }
  double channelGap(int boundary) =>
      _kColGap +
      math.min(
        channelLoads[boundary] ?? 0,
        layout == NlLayoutAlgorithm.layered ? 4 : 8,
      ) *
          _kGrid +
      (columnGapExtra[boundary] ?? 0) * _kGrid;

  final colX = <int, double>{};
  final colW = <int, double>{};
  var cursor = inputAreaRight + _kStubClear + channelGap(-1);
  for (var c = 0; c < colCount; c++) {
    colX[c] = cursor;
    var w = _kMinBlockW;
    for (final b in rowsOf[c] ?? const <NlBlock>[]) {
      w = math.max(w, b.boxSize.width);
    }
    colW[c] = w;
    cursor += w + _kStubClear * 2 + channelGap(c);
  }
  final outputAreaLeft =
      cursor + (colCount == 0 ? 0.0 : channelGap(colCount - 1));
  final canvasW =
      outputAreaLeft +
      _kPortGlyphW +
      _kPortTextGap +
      math.max(maxOutTextW, 2 * _kGrid) +
      _kMargin;

  final topY = _kMargin;

  // ---- 列内纵向布局（短列相对最高列居中）----
  final colHeights = <int, double>{};
  for (var c = 0; c < colCount; c++) {
    var h = 0.0;
    var first = true;
    for (final b in rowsOf[c] ?? const <NlBlock>[]) {
      if (!first) h += _kRowGap;
      h += b.size.height;
      first = false;
    }
    colHeights[c] = h;
  }
  final maxColH = colHeights.values.isEmpty
      ? 0.0
      : colHeights.values.fold<double>(0, math.max);

  /// 块区底部。
  final contentBottom = topY + maxColH;
  for (var c = 0; c < colCount; c++) {
    var y =
        topY + _gridRound(math.max(0.0, (maxColH - (colHeights[c] ?? 0)) / 2));
    for (final b in rowsOf[c] ?? const <NlBlock>[]) {
      // 不同宽度的元件按列中心线居中，并以 Grid 下取整消除半格。
      final blockX = _gridFloor(colX[c]! + (colW[c]! - b.boxSize.width) / 2);
      b.origin = Offset(blockX, y);
      b.boxOrigin = Offset(blockX, y);
      y += b.size.height + _kRowGap;
    }
  }

  // ---- 针脚坐标（组合逻辑单输出居中，MUX 选择端在底边）----
  // 分层布局先做列纵向对齐：按相邻列相连块的中心中位数平移整列，
  // 收紧“短列居中”造成的阶梯状空白与长斜线（Brandes–Köpf 的简化版）。
  if (layout == NlLayoutAlgorithm.layered) {
    for (var pass = 0; pass < 2; pass++) {
      final order = [for (var c = 0; c < colCount; c++) c];
      final seq = pass.isEven ? order : order.reversed.toList();
      for (final c in seq) {
        final list = rowsOf[c];
        if (list == null || list.isEmpty) continue;
        final neighbours = <double>[];
        for (final b in list) {
          for (final n in [
            ...(cellDeps[b] ?? const <NlBlock>{}),
            ...(cellLoads[b] ?? const <NlBlock>{}),
          ]) {
            if (n.column == c) continue;
            neighbours.add(n.origin.dy + n.size.height / 2);
          }
        }
        if (neighbours.isEmpty) continue;
        neighbours.sort();
        final target = neighbours[neighbours.length ~/ 2];
        final top = list.first.origin.dy;
        final bottom = list.last.origin.dy + list.last.size.height;
        final bounds = (
          topY - top,
          contentBottom - bottom,
        );
        final raw = (target - (top + bottom) / 2).clamp(
          bounds.$1,
          bounds.$2,
        );
        // 平移必须落在 15px Grid 上：半格位移会把针脚 y 变成 x.5，路由器
        // 的逃生段/占用表按整格建模，会与其 7.5px 补线产生同轴重叠。
        final shift = _gridRound(raw.toDouble())
            .clamp(bounds.$1, bounds.$2)
            .toDouble();
        if (shift.abs() < 0.5) continue;
        for (final b in list) {
          _nlShiftBlock(b, shift);
        }
      }
    }
  }

  // ---- 针脚坐标 ----
  // 符号方向：默认按端口声明顺序；「镜像元件」（pinFlip）时输入/输出槽位
  // 上下反转（包含 MUX 的底边 S 针脚——上方/下方引脚可互相镜像）；
  // 「引脚交换」（inPinOrder）可再覆盖每个块的输入槽位顺序。
  for (final b in allBlocks) {
    if (b.isIo) continue;
    b.pinFlip = mirroredBlocks.contains(b.id);
    b.inPinOrder = pinOrders[b.id];
    nlLayoutBlockPins(b);
  }

  // ---- 展开容器：边缘针脚对齐子模块端口并记录连接短线 ----
  for (final b in allBlocks) {
    final sub = b.sub;
    if (sub == null) continue;
    // 子模型端口针脚（左输入 / 右输出+双向）。
    NlPin? inner(String port, bool input) {
      final blk = input ? sub.blocks.first : sub.blocks.last;
      for (final p in (input ? blk.outs : blk.ins)) {
        if (p.port == port || p.display == port) return p;
      }
      return null;
    }

    for (var i = 0; i < b.ins.length; i++) {
      final ip = inner(b.ins[i].port, true);
      if (ip == null) continue;
      final y = b.boxOrigin.dy + b.subOffset.dy + ip.pos.dy;
      b.ins[i].edge = Offset(b.boxOrigin.dx, y);
      b.ins[i].pos = Offset(b.boxOrigin.dx - _kStub, y);
      b.subLinks.add((b.ins[i].edge, b.boxOrigin + b.subOffset + ip.pos));
    }
    for (var i = 0; i < b.outs.length; i++) {
      final ip = inner(b.outs[i].port, false);
      if (ip == null) continue;
      final y = b.boxOrigin.dy + b.subOffset.dy + ip.pos.dy;
      b.outs[i].edge = Offset(b.boxOrigin.dx + b.boxSize.width, y);
      b.outs[i].pos = Offset(b.boxOrigin.dx + b.boxSize.width + _kStub, y);
      b.subLinks.add((b.outs[i].edge, b.boxOrigin + b.subOffset + ip.pos));
    }
  }

  // 端口纵向对齐相连针脚 ----
  double yOf(NlPin p, {required bool asSource}) {
    if (asSource) {
      // 优先对齐**相邻列**上的负载针脚：该跳会走简单 Z 并退化成直线；
      // （多负载网若对齐到远列负载，相邻列那跳反而要多一次折弯）。
      NlPin? adj, any;
      for (final w in wires) {
        if (!identical(w.from, p)) continue;
        for (final l in w.loads) {
          any ??= l;
          if (colOfPin(l) == colOfPin(p) + 1) {
            adj ??= l;
          }
        }
      }
      final t = adj ?? any;
      if (t != null) return t.pos.dy;
    } else {
      // p 是**负载**（顶层输出端口）：对齐到驱动引脚所在的行。
      for (final w in wires) {
        for (final l in w.loads) {
          if (identical(l, p)) return w.from.pos.dy;
        }
      }
    }
    return topY;
  }

  var maxInY = topY, maxOutY = topY;
  final inPlaced = nlPlacePortRows([
    for (final p in inPins) (p, yOf(p, asSource: true)),
  ], topY);
  for (final (p, y) in inPlaced) {
    p.pos = Offset(inGlyphX + _kPortGlyphW, y);
    p.edge = p.pos;
    maxInY = math.max(maxInY, y);
  }
  final outPlaced = nlPlacePortRows([
    for (final p in outPins) (p, yOf(p, asSource: false)),
  ], topY);
  for (final (p, y) in outPlaced) {
    p.pos = Offset(outputAreaLeft, y);
    p.edge = p.pos;
    maxOutY = math.max(maxOutY, y);
  }
  inBlock.boxOrigin = Offset(inTextLeft, topY);
  inBlock.origin = inBlock.boxOrigin;
  inBlock.boxSize = Size(inputAreaRight - inTextLeft, maxInY - topY);
  inBlock.size = inBlock.boxSize;
  outBlock.boxOrigin = Offset(outputAreaLeft, topY);
  outBlock.origin = outBlock.boxOrigin;
  outBlock.boxSize = Size(
    _kPortGlyphW + _kPortTextGap + maxOutTextW,
    maxOutY - topY,
  );
  outBlock.size = outBlock.boxSize;

  // ---- 画布尺寸：块区 + 端口 + 边距 ----
  // 直线预览只需覆盖块体、端口符号与针脚外伸（不需要走线轨道/通道留白）。
  final canvasH = math.max(contentBottom, math.max(maxInY, maxOutY)) + _kMargin;

  return NetlistDiagramModel(
    blocks: allBlocks,
    wires: wires,
    canvasSize: Size(canvasW, canvasH),
    moduleName: module.name,
    cellCount: module.cells.length,
  );
}

/// 一根网的显示名：优先取覆盖当前比特集合最多的**可读**网段，保留实际
/// 位段范围；全是 yosys 生成名时退回 `<实例>_<端口>` 派生名。
///
/// 与顶层端口完整同名的网**返回空串**（端口外侧已有名字）；部分位段必须
/// 保留范围标签，否则多个驱动源接到同一总线时无法区分各自占用哪些位。
String _netLabelForBits(NlPin from, List<int> bits, List<NlPin> loads) {
  bool readable(String n) =>
      n.isNotEmpty && !n.contains(r'$') && !n.contains(RegExp(r'\.v:\d+'));
  final wanted = bits.toSet();
  int coverage(NetlistNet net) {
    var n = 0;
    for (final bit in net.bits) {
      if (wanted.contains(bit)) n++;
    }
    return n;
  }

  // 优先选择覆盖当前比特集合最多的真实网段。驱动端优先用于同覆盖的
  // 平局，因此部分位段会保留 `n1_res_l[7:0]` 这样的精确范围。
  var name = '';
  var best = 0;
  for (final owner in [from, ...loads]) {
    for (final net in owner.nets) {
      if (net.isConst || !readable(net.name)) continue;
      final score = coverage(net);
      if (score > best) {
        best = score;
        name = net.display;
      }
    }
  }
  if (name.isEmpty) {
    name = '${from.ownerTitle}_${from.port}';
    // 无真实可读名时，部分位段也保留范围，避免同一针脚的派生网混淆。
    if (bits.length < from.bits.length) {
      for (final net in from.nets) {
        if (net.range.isNotEmpty && wanted.every(net.bits.contains)) {
          name += net.range;
          break;
        }
      }
    }
  }
  // 非等宽连接：标注源输出在本次连接中实际使用的连续位域，例如
  // `n1_hwrap[16:0]` 只取低 8 位时标为 `n1_hwrap[7:0]`。
  final positions = [for (final bit in bits) from.bits.indexOf(bit)]..sort();
  var usedRange = '';
  if (positions.isNotEmpty &&
      positions.length < from.bits.length &&
      positions.last - positions.first + 1 == positions.length) {
    final lo = positions.first, hi = positions.last;
    usedRange = lo == hi ? '[$lo]' : '[$hi:$lo]';
  }
  if (usedRange.isNotEmpty) {
    NetlistNet? source;
    for (final net in from.nets) {
      if (net.isConst ||
          !readable(net.name) ||
          !wanted.every(net.bits.contains)) {
        continue;
      }
      // 同源别名覆盖相同时取更宽的原始网，以便保留源总线名称。
      if (source == null || net.bits.length > source.bits.length) {
        source = net;
      }
    }
    if (source != null) {
      name = source.range == usedRange
          ? source.display
          : '${source.name}$usedRange';
    } else if (!RegExp(r'\[\d+(?::\d+)?\]$').hasMatch(name)) {
      name += usedRange;
    }
  }
  // 完整端口名已画在符号外侧，不重复标注；部分位段（如 `n[7:0]`）
  // 即使与端口同基名也必须保留，否则无法区分各驱动源占用的比特。
  final base = name.replaceFirst(RegExp(r'\[\d+(?::\d+)?\]$'), '');
  final hasRange = base != name;
  for (final p in [from, ...loads]) {
    if (!p.isPort) continue;
    if (p.display == name) return '';
    if (!hasRange) {
      final pbase = p.display.replaceFirst(RegExp(r'\[\d+(?::\d+)?\]$'), '');
      if (p.port == base || pbase == base) return '';
    }
  }
  return name;
}

/// 文本宽度近似（布局期无画布，按字号 × 字符数估算）。
double _tw(String s, double size) => s.runes.length * size * 0.56;

/// 网表电路图组件：CustomPaint 画端口/针脚/连线，Positioned 块承载单元
/// 信息；悬停高亮相连网络；点子模块实例「＋」下钻、点逻辑单元跳源码。
class NetlistDiagram extends StatefulWidget {
  final NetlistDiagramModel model;

  /// 点击单元回调（实例下钻 / 逻辑单元跳源码）。
  final void Function(NetlistCell cell)? onTapCell;

  /// 外部缩放控制器（工具栏共用）。
  final TransformationController? controller;

  /// 视口尺寸上报（「适应窗口」用）。
  final void Function(Size viewport)? onViewport;

  /// 配色：false = 暗色（默认），true = Vivado 浅色。
  final bool light;

  /// 配色覆盖（含字体族；导出位图用）。
  final SchPalette? palette;

  /// 外部选中的网（显示其网名；null = 不显示）。
  final NlWire? selectedNet;

  /// 点选网回调（点空白处传 null）——宿主可用来联动高亮源码/波形。
  final void Function(NlWire? net)? onNetSelected;

  /// 切换某实例块的**原位展开**（＋/－）。
  final void Function(NetlistCell cell)? onToggleExpand;

  /// 直线预览的超边拓扑：团=全对相连（默认），星形=各 pin 到质心。
  final NlNetTopology topology;

  /// 是否叠加上走线密度热力图。
  final bool heatmap;

  /// 走线诊断叠加层（交叉/长尾网/高密度/硬约束标记）；null = 不显示。
  final NlRoutingDiagnostics? diagnostics;

  /// 自动布线结果（wire → 本层坐标正交线段）；null 时画直线。
  final Map<NlWire, List<(Offset, Offset)>>? autoRoutes;

  /// 自动布线的同网 T 型分支点（wire → 本层坐标点）。
  final Map<NlWire, List<Offset>>? autoJunctions;

  /// 编辑模式：拖动非 I/O 元件块（竖向），松手后由宿主做事务式重布。
  final bool editMode;
  final void Function(NlBlock block)? onBlockDragStart;
  final void Function(NlBlock block, double dx, double dy)? onBlockDragEnd;
  final void Function(NlPin pin)? onPortDragStart;
  final void Function(NlPin pin, double dy)? onPortDragEnd;

  const NetlistDiagram({
    super.key,
    required this.model,
    this.onTapCell,
    this.controller,
    this.onViewport,
    this.light = false,
    this.palette,
    this.selectedNet,
    this.onNetSelected,
    this.onToggleExpand,
    this.topology = NlNetTopology.clique,
    this.heatmap = false,
    this.diagnostics,
    this.autoRoutes,
    this.autoJunctions,
    this.editMode = false,
    this.onBlockDragStart,
    this.onBlockDragEnd,
    this.onPortDragStart,
    this.onPortDragEnd,
  });

  @override
  State<NetlistDiagram> createState() => _NetlistDiagramState();
}

class _NetlistDiagramState extends State<NetlistDiagram> {
  late final TransformationController _ctrl =
      widget.controller ?? TransformationController();
  Size? _fittedFor;
  NlBlock? _hoverBlock;
  NlBlock? _hoverExpand;

  /// 鼠标悬停的常量引脚（悬停时标记方框填充为实心黄，气泡由 Tooltip 显示）。
  NlPin? _hoverConstPin;

  /// 鼠标悬停到的网（临时显示网名）与点选固定的网，含所在层的平移。
  (NlWire, Offset)? _hoverNet;
  (NlWire, Offset)? _pinnedNet;

  /// 展平后的各层（顶层 + 展开容器内部）。
  late List<NlLevel> _levels = widget.model.flattened();

  /// 走线密度热力图缓存（按模型对象与拓扑失效）。
  NlHeatmap? _heatmap;
  NetlistDiagramModel? _heatmapModel;
  NlNetTopology? _heatmapTopology;
  Object? _heatmapRoutes;

  NlHeatmap _heatmapFor(NetlistDiagramModel model) {
    if (_heatmap != null &&
        identical(_heatmapModel, model) &&
        _heatmapTopology == widget.topology &&
        identical(_heatmapRoutes, widget.autoRoutes)) {
      return _heatmap!;
    }
    _heatmap = computeNlHeatmap(
      _levels,
      model.canvasSize,
      topology: widget.topology,
      autoRoutes: widget.autoRoutes,
    );
    _heatmapModel = model;
    _heatmapTopology = widget.topology;
    _heatmapRoutes = widget.autoRoutes;
    return _heatmap!;
  }

  /// 上一次 pointer down（时刻、位置、命中的块）——用于 Listener 侧识别双击。
  (DateTime, Offset, NlBlock?)? _lastDownAt;

  /// 编辑模式拖动状态。
  NlBlock? _dragBlock;
  NlPin? _dragPort;
  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragAppliedX = 0;
  double _dragAppliedY = 0;
  double _dragTotalDy = 0;

  @override
  void initState() {
    super.initState();
    _pinnedNet = _locateNet(widget.selectedNet);
  }

  /// 在展平的各层里定位某根网（拿到它所在层的平移，悬停/选中的高亮与
  /// 网名绘制都要用）。
  (NlWire, Offset)? _locateNet(NlWire? w) {
    if (w == null) return null;
    for (final lv in _levels) {
      for (final x in lv.wires) {
        if (identical(x, w)) return (w, lv.offset);
      }
    }
    return null;
  }

  @override
  void didUpdateWidget(NetlistDiagram old) {
    super.didUpdateWidget(old);
    if (!identical(old.model, widget.model)) {
      _levels = widget.model.flattened();
      _hoverExpand = null;
      _hoverNet = null;
      _pinnedNet = null;
    }
    if (!identical(old.selectedNet, widget.selectedNet)) {
      _pinnedNet = _locateNet(widget.selectedNet);
    }
  }

  /// 命中容差（画布坐标，随缩放反向补偿：缩小时更容易命中）。
  double get _hitTol {
    final s = _ctrl.value.getMaxScaleOnAxis();
    return (5.0 / (s <= 0 ? 1 : s)).clamp(1.5, 40.0);
  }

  void _updateHover(Offset p) {
    final hit = nlWireAtLevels(
      _levels,
      p,
      _hitTol,
      widget.topology,
      widget.autoRoutes,
    );
    if (hit?.$1 == _hoverNet?.$1) return;
    setState(() => _hoverNet = hit);
  }

  void _onPointerDown(Offset p) {
    // 编辑模式：按住非 I/O 元件块开始竖向拖动。
    if (widget.editMode) {
      final port = nlPortAt(_levels, p);
      if (port != null) {
        _dragPort = port;
        _dragStartX = p.dx;
        _dragStartY = p.dy;
        _dragAppliedX = 0;
        _dragAppliedY = 0;
        _dragTotalDy = 0;
        widget.onPortDragStart?.call(port);
        _lastDownAt = null;
        return;
      }
      final blk = nlBlockAt(_levels, p);
      if (blk != null && !blk.isIo && blk.boxSize.height > 0) {
        _dragBlock = blk;
        _dragStartX = p.dx;
        _dragStartY = p.dy;
        _dragAppliedX = 0;
        _dragAppliedY = 0;
        _dragTotalDy = 0;
        widget.onBlockDragStart?.call(blk);
        _lastDownAt = null;
        return;
      }
    }
    // 先看是否点在实例块左上角的 ＋/− 上（原位展开/收起）。
    final cell = nlExpandTargetAt(_levels, p);
    if (cell != null) {
      _lastDownAt = null;
      widget.onToggleExpand?.call(cell);
      return;
    }
    // 双击块 → 进入整页下钻（在 Listener 里自己判定，不依赖层叠手势）。
    final now = DateTime.now();
    final last = _lastDownAt;
    if (last != null &&
        now.difference(last.$1) < const Duration(milliseconds: 350) &&
        (last.$2 - p).distance < 8) {
      final blk = nlBlockAt(_levels, p) ?? last.$3;
      _lastDownAt = null;
      if (blk?.cell != null && blk!.cell!.isInstance) {
        widget.onTapCell?.call(blk.cell!);
        return;
      }
    }
    _lastDownAt = (now, p, nlBlockAt(_levels, p));
    _togglePin(p);
  }

  void _onPointerMove(Offset p) {
    final block = _dragBlock;
    final port = _dragPort;
    if (block == null && port == null) return;
    // 1 Grid 步进：按相对起点的位移取整，再补差量。
    final targetY =
        ((p.dy - _dragStartY) / _kGrid).round() * _kGrid;
    final targetX =
        ((p.dx - _dragStartX) / _kGrid).round() * _kGrid;
    final dy = targetY - _dragAppliedY;
    final dx = targetX - _dragAppliedX;
    if (dy.abs() < 0.01 && (block == null || dx.abs() < 0.01)) return;
    _dragAppliedY = targetY;
    _dragAppliedX = targetX;
    if (block != null) {
      nlShiftBlockXY(block, dx, dy);
    } else {
      _nlShiftPin(port!, dy);
    }
    _dragTotalDy = targetY;
    setState(() {});
  }

  void _onPointerUp() {
    final block = _dragBlock;
    final port = _dragPort;
    if (block == null && port == null) return;
    _dragBlock = null;
    _dragPort = null;
    if (block != null) {
      widget.onBlockDragEnd?.call(block, _dragAppliedX, _dragAppliedY);
    } else {
      widget.onPortDragEnd?.call(port!, _dragTotalDy);
    }
    _dragTotalDy = 0;
  }

  void _togglePin(Offset p) {
    final hit = nlWireAtLevels(
      _levels,
      p,
      _hitTol,
      widget.topology,
      widget.autoRoutes,
    );
    final same =
        hit != null && _pinnedNet != null && identical(hit.$1, _pinnedNet!.$1);
    final next = (hit == null || same) ? null : hit;
    setState(() => _pinnedNet = next);
    widget.onNetSelected?.call(next?.$1);
  }

  @override
  void dispose() {
    if (widget.controller == null) _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette =
        widget.palette ??
        (widget.light ? SchPalette.vivadoLight : SchPalette.dark);
    return LayoutBuilder(
      builder: (context, cons) {
        final viewport = Size(cons.maxWidth, cons.maxHeight);
        widget.onViewport?.call(viewport);
        if (_fittedFor != widget.model.canvasSize &&
            viewport.width >= 200 &&
            viewport.height >= 200) {
          _fittedFor = widget.model.canvasSize;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            schFitView(_ctrl, viewport, widget.model.canvasSize);
          });
        }
        final hover = _hoverBlock;
        // 悬停/点选的网（含悬停单元的相连网）才显示网名——跨层用同一套
        // 块/网对象，展开容器内外一视同仁。
        final hiWires = <NlWire>[
          if (hover != null)
            ..._levels.expand((lv) => lv.wires).where((w) => w.touches(hover)),
        ];
        final active = <NlWire>{
          if (_hoverNet != null) _hoverNet!.$1,
          if (_pinnedNet != null) _pinnedNet!.$1,
          ...hiWires,
        };
        return ColoredBox(
          color: palette.canvasBg,
          child: InteractiveViewer(
            transformationController: _ctrl,
            constrained: false,
            panEnabled: !widget.editMode,
            minScale: 0.02,
            maxScale: 8,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: SizedBox(
              width: widget.model.canvasSize.width,
              height: widget.model.canvasSize.height,
              // 命中测试放在被变换的子层里 → localPosition 已是画布坐标。
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerHover: (e) => _updateHover(e.localPosition),
                onPointerDown: (e) => _onPointerDown(e.localPosition),
                onPointerMove: (e) => _onPointerMove(e.localPosition),
                onPointerUp: (_) => _onPointerUp(),
                onPointerCancel: (_) => _onPointerUp(),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomPaint(
                      size: widget.model.canvasSize,
                      painter: NetlistWirePainter(
                        _levels,
                        hover: hover,
                        active: active,
                        palette: palette,
                        drawLabels: false,
                        topology: widget.topology,
                        autoRoutes: widget.autoRoutes,
                        autoJunctions: widget.autoJunctions,
                        hoverConst: _hoverConstPin,
                      ),
                    ),
                    if (widget.heatmap)
                      IgnorePointer(
                        key: const ValueKey('nl-heatmap-layer'),
                        child: CustomPaint(
                          size: widget.model.canvasSize,
                          painter: NetlistHeatmapPainter(
                            _heatmapFor(widget.model),
                          ),
                        ),
                      ),
                    if (widget.diagnostics != null)
                      IgnorePointer(
                        key: const ValueKey('nl-diagnostics-layer'),
                        child: CustomPaint(
                          size: widget.model.canvasSize,
                          painter: NetlistDiagnosticPainter(
                            widget.diagnostics!,
                          ),
                        ),
                      ),
                    for (final b in widget.model.blocks)
                      if (!b.isIo) _positionedBlock(b, palette),
                    // 常量参数平时不显示，悬停到对应 10×10 标记时以气泡显示。
                    for (final lv in _levels)
                      for (final p in lv.pins)
                        if (p.constText != null)
                          Positioned(
                            left: lv.offset.dx + p.pos.dx,
                            top: lv.offset.dy + p.pos.dy - 5,
                            child: MouseRegion(
                              onEnter: (_) =>
                                  setState(() => _hoverConstPin = p),
                              onExit: (_) => setState(() {
                                if (identical(_hoverConstPin, p)) {
                                  _hoverConstPin = null;
                                }
                              }),
                              child: Tooltip(
                                message: nlConstTooltip(p),
                                waitDuration: const Duration(milliseconds: 300),
                                child: const SizedBox(width: 10, height: 10),
                              ),
                            ),
                          ),
                    // 网名与位域始终置于所有元件块及展开容器之上，避免被符号遮挡。
                    IgnorePointer(
                      key: const ValueKey('nl-label-layer'),
                      child: CustomPaint(
                        size: widget.model.canvasSize,
                        painter: NetlistWirePainter(
                          _levels,
                          hover: hover,
                          active: active,
                          palette: palette,
                          labelsOnly: true,
                          topology: widget.topology,
                          autoRoutes: widget.autoRoutes,
                          autoJunctions: widget.autoJunctions,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 顶层块（自带定位）。
  Widget _positionedBlock(NlBlock b, SchPalette palette) => Positioned(
    left: b.origin.dx,
    top: b.origin.dy,
    child: _blockContent(b, palette),
  );

  /// 实例框左上角的展开/收起按钮：两种状态共用居中几何与悬停反馈。
  Widget _expandButton(NlBlock b, SchPalette palette) {
    final cell = b.cell;
    if (cell == null) return const SizedBox.shrink();
    final expanded = b.isContainer;
    final hovered = identical(_hoverExpand, b);
    final light = identical(palette, SchPalette.vivadoLight);
    final color = light
        ? const Color(0xFFFFFFFF)
        : hovered
        ? palette.hover
        : const Color(0xFFFFFFFF);
    final fill = light
        ? hovered
              ? nlExpandLightHoverFill
              : nlExpandLightFill
        : hovered
        ? palette.hover.withValues(alpha: 0.16)
        : palette.canvasBg;
    final borderColor = light ? nlExpandLightBorder : color;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoverExpand = b),
      onExit: (_) => setState(() {
        if (identical(_hoverExpand, b)) _hoverExpand = null;
      }),
      child: Tooltip(
        message: expanded ? '收起实例' : '展开实例',
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          key: ValueKey('${expanded ? 'nl-minus' : 'nl-plus'}-${b.id}'),
          onTap: () => widget.onToggleExpand?.call(cell),
          child: Container(
            width: _kPlus,
            height: _kPlus,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: borderColor, width: _kBoxBorder),
              borderRadius: light ? BorderRadius.circular(4) : null,
            ),
            child: Icon(
              expanded ? Icons.remove : Icons.add,
              size: 8,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  /// 块内容（**不含定位**）——顶层与展开容器内部共用；容器内部由调用方
  /// 用 `Positioned` 按子模型坐标摆放（避免双重 Positioned）。
  Widget _blockContent(NlBlock b, SchPalette palette) {
    final cell = b.cell;
    final sub = b.sub;
    // 展开容器：外框 + 标题带 + 内部子模型（子模型的块递归渲染，
    // 线/针脚/端口由 painter 按层绘制）。
    if (sub != null) {
      final inside = <Widget>[
        for (final cb in sub.blocks)
          if (!cb.isIo)
            Positioned(
              left: b.subOffset.dx + cb.origin.dx,
              top: b.subOffset.dy + cb.origin.dy,
              child: _blockContent(cb, palette),
            ),
      ];
      return MouseRegion(
        onEnter: (_) => setState(() => _hoverBlock = b),
        onExit: (_) => setState(() => _hoverBlock = null),
        child: Tooltip(
          message:
              '${b.title} · ${b.subtitle} · 已展开（点击 − 收起，'
              '双击进入子模块）',
          waitDuration: const Duration(milliseconds: 600),
          child: GestureDetector(
            onDoubleTap: () => _drill(cell),
            child: SizedBox(
              width: b.size.width,
              height: b.size.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Container(
                      width: b.boxSize.width,
                      height: b.boxSize.height,
                      decoration: BoxDecoration(
                        // 半透明底：容器内部由 painter 画的网线/端口要能透出来
                        // （widget 在 CustomPaint 之上，不透明底会整块盖住）。
                        color: palette.canvasBg.withValues(alpha: 0.45),
                        border: Border.all(
                          color: identical(_hoverBlock, b)
                              ? palette.hover
                              : palette.blockBorder,
                          width: _kBoxBorder,
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  // 实例名/类型名：与其他符号一致，置于容器内部顶部/底部。
                  Positioned(
                    left: _kPlus + 6,
                    right: 4,
                    top: 5,
                    child: Text(
                      b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 7.5,
                        color: nlBlockLabelColorOf(palette),
                        fontFamily: palette.fontFamily,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 4,
                    right: 4,
                    bottom: 5,
                    child: Text(
                      b.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 6,
                        color: nlBlockLabelColorOf(palette),
                        fontFamily: palette.fontFamily,
                      ),
                    ),
                  ),
                  ...inside,
                  // 「−」收起：与折叠态「＋」一样放在容器框内左上角。
                  Positioned(left: 3, top: 3, child: _expandButton(b, palette)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final fill = netlistCellFill(cell?.kind, palette);
    final box = cell != null && !cell.isInstance
        ? SizedBox(
            width: b.boxSize.width,
            height: b.boxSize.height,
            child: CustomPaint(
              painter: NetlistCellPainter(
                block: b,
                hover: identical(_hoverBlock, b),
                palette: palette,
              ),
            ),
          )
        : Container(
            width: b.boxSize.width,
            height: b.boxSize.height,
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(
                color: identical(_hoverBlock, b)
                    ? palette.hover
                    : palette.blockBorder,
                width: _kBoxBorder,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Stack(
              children: [
                // 左上「＋」：点它**原位展开**这个实例块（逻辑单元无此图标）。
                if (cell != null && cell.isInstance)
                  Positioned(left: 3, top: 3, child: _expandButton(b, palette)),
                Padding(
                  padding: const EdgeInsets.only(
                    left: _kPinPadH,
                    right: _kPinPadH,
                    top: _kPinPadV,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final p in b.ins)
                              SizedBox(
                                height: _kPinRowH,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    p.display,
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: palette.pinText,
                                      fontFamily: palette.fontFamily,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final p in b.outs)
                              SizedBox(
                                height: _kPinRowH,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    p.display,
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: palette.pinText,
                                      fontFamily: palette.fontFamily,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );

    final content = SizedBox(
      width: b.size.width,
      height: b.size.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          box,
          // 实例名移到符号内部顶端（避开左上「＋」与顶边 S 针脚）。
          Positioned(
            left: (cell?.isInstance ?? false) ? _kPlus + 6 : 4,
            right: 4,
            top: 5,
            child: Text(
              b.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 7.5,
                color: nlBlockLabelColorOf(palette),
                fontFamily: palette.fontFamily,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // 类型名移到符号内部底端左侧（避开底边 S 针脚/最后一排针脚）。
          Positioned(
            left: 4,
            right: 4,
            bottom: 5,
            child: Text(
              b.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 6,
                color: nlBlockLabelColorOf(palette),
                fontFamily: palette.fontFamily,
              ),
            ),
          ),
        ],
      ),
    );

    final tip = cell == null
        ? null
        : '${cell.typeLabel} · ${cell.desc}'
              '${cell.source == null ? '' : ' · ${cell.source}'}'
              '${cell.memId == null ? '' : ' · ${cell.memId}'}';
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverBlock = b),
      onExit: (_) => setState(() => _hoverBlock = null),
      child: Tooltip(
        message: tip ?? '',
        waitDuration: const Duration(milliseconds: 600),
        child: cell == null
            ? content
            : cell.isInstance
            // 实例块：单击 = 原位展开/收起，双击 = 进入整页；
            // 不能与 InkWell 的 tap 识别器嵌套（双击会被单点吃掉）。
            ? GestureDetector(
                onTap: widget.editMode
                    ? null
                    : () => widget.onToggleExpand?.call(cell),
                onDoubleTap: widget.editMode ? null : () => _drill(cell),
                child: content,
              )
            : InkWell(
                onTap: widget.editMode
                    ? null
                    : () => widget.onTapCell?.call(cell),
                child: content,
              ),
      ),
    );
  }

  /// 双击块：进入整页下钻视图（原有行为）。编辑模式下禁用。
  void _drill(NetlistCell? cell) {
    if (widget.editMode) return;
    if (cell == null || !cell.isInstance) return;
    widget.onTapCell?.call(cell);
  }
}

/// 标准单元符号绘制：轮廓与 SVG 共用 [buildNetlistSymbol]，这里只负责
/// 配色和文字度量。
class NetlistCellPainter extends CustomPainter {
  final NlBlock block;
  final bool hover;
  final SchPalette palette;

  const NetlistCellPainter({
    required this.block,
    required this.hover,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final pins = <NetlistSymbolPin>[
      for (final p in block.ins)
        NetlistSymbolPin(
          port: p.port,
          display: p.display,
          edge: p.edge - block.boxOrigin,
          isInput: true,
        ),
      for (final p in block.outs)
        NetlistSymbolPin(
          port: p.port,
          display: p.display,
          edge: p.edge - block.boxOrigin,
          isInput: false,
        ),
    ];
    final geometry = buildNetlistSymbol(block.cell, rect, pins: pins);
    final fill = netlistCellFill(block.cell?.kind, palette);
    final border = hover ? palette.hover : palette.blockBorder;
    final stroke = Paint()
      ..color = border
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kBoxBorder
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(geometry.outline.toPath(), Paint()..color = fill);
    canvas.drawPath(geometry.outline.toPath(), stroke);
    for (final detail in geometry.details) {
      canvas.drawPath(detail.toPath(), stroke);
    }
    for (final bubble in geometry.bubbles) {
      canvas.drawCircle(bubble.center, bubble.radius, Paint()..color = fill);
      canvas.drawCircle(bubble.center, bubble.radius, stroke);
    }

    final label = geometry.centerLabel;
    if (label != null && label.isNotEmpty) {
      final tp = _text(label, geometry.centerLabelSize, palette.pinText);
      tp.paint(
        canvas,
        Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2),
      );
    }
    for (final p in pins) {
      final tp = _text(p.display, 10, palette.pinText);
      final at = netlistSymbolPinLabelTopLeft(
        geometry.kind,
        p,
        rect,
        Size(tp.width, tp.height),
      );
      tp.paint(canvas, at);
    }
  }

  TextPainter _text(String text, double fontSize, Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        color: color,
        fontFamily: palette.fontFamily,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  bool shouldRepaint(NetlistCellPainter old) =>
      !identical(old.block, block) ||
      old.hover != hover ||
      old.palette != palette;
}

/// 单元块配色（按类别区分，Vivado 风格淡色）。
Color netlistCellFill(NetlistCellKind? kind, SchPalette p) {
  final light =
      identical(p, SchPalette.vivadoLight) ||
      p.canvasBg.computeLuminance() > 0.5;
  switch (kind) {
    case NetlistCellKind.seq:
      return light ? const Color(0xFFD8E6F7) : const Color(0xFF233247);
    case NetlistCellKind.mem:
      return light ? const Color(0xFFF3E7C8) : const Color(0xFF3A3320);
    case NetlistCellKind.arith:
      return light ? const Color(0xFFDCEFDC) : const Color(0xFF20372A);
    case NetlistCellKind.compare:
      return light ? const Color(0xFFF7E3D0) : const Color(0xFF3A2C20);
    case NetlistCellKind.mux:
      return light ? const Color(0xFFE8E0F5) : const Color(0xFF2E2740);
    case NetlistCellKind.logic:
      return light ? const Color(0xFFE7E7E7) : const Color(0xFF2B2B2B);
    case NetlistCellKind.shift:
      return light ? const Color(0xFFDFF0F0) : const Color(0xFF203636);
    case NetlistCellKind.instance:
      return light ? const Color(0xFFDCE7F5) : const Color(0xFF252526);
    case NetlistCellKind.other:
    case null:
      return p.blockFill;
  }
}

/// 绘制连线、针脚短线、端口五边形与网名标注。
///
/// **所有网名与位域默认都不画**；仅 [active] 里的高亮网（鼠标悬停、点选
/// 或悬停单元的相连网）显示其完整标签，且底板**半透明**。
/// [showLabels] 为导出模式：全部标注。
/// 绘制针脚短线、端口符号与每网直线（团/星形拓扑）。
///
/// **所有网名与位域默认都不画**；仅 [active] 里的高亮网（鼠标悬停、点选
/// 或悬停单元的相连网）显示其完整标签，且底板**半透明**。
class NetlistWirePainter extends CustomPainter {
  /// 展平后的各层（顶层 + 展开容器内部各层，含平移）。
  final List<NlLevel> levels;
  final NlBlock? hover;

  /// 需要显示网名的网（悬停/选中的网络）。
  final Set<NlWire> active;
  final SchPalette palette;

  /// true 时只绘制网名标签，供置于元件块之上的独立图层使用。
  final bool labelsOnly;

  /// false 时跳过本层标签（配合独立的最顶层标签图层，避免重复绘制）。
  final bool drawLabels;

  /// 直线预览的超边拓扑：团=全对相连（默认），星形=各 pin 到质心。
  final NlNetTopology topology;

  /// 自动布线结果（wire → 画布坐标正交线段）；null 时画直线。
  final Map<NlWire, List<(Offset, Offset)>>? autoRoutes;

  /// 自动布线的同网 T 型分支点。
  final Map<NlWire, List<Offset>>? autoJunctions;

  /// 悬停的常量引脚：其 10×10 标记方框用悬停黄填充为实心。
  final NlPin? hoverConst;

  NetlistWirePainter(
    this.levels, {
    this.hover,
    this.active = const {},
    this.palette = SchPalette.dark,
    this.labelsOnly = false,
    this.drawLabels = true,
    this.topology = NlNetTopology.clique,
    this.autoRoutes,
    this.autoJunctions,
    this.hoverConst,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final stubPaint = Paint()
      ..color = palette.pinStrokeOrBorder
      ..strokeWidth = _kBoxBorder;
    final stubBusPaint = Paint()
      ..color = palette.pinStrokeOrBorder
      ..strokeWidth = 2.0;
    final dotPaint = Paint()..color = palette.pinStrokeOrBorder;
    final linkPaint = Paint()
      ..color = palette.pinStrokeOrBorder
      ..strokeWidth = _kBoxBorder;
    for (final lv in levels) {
      canvas.save();
      canvas.translate(lv.offset.dx, lv.offset.dy);
      if (labelsOnly) {
        paintNetlistStraightPreview(
          canvas,
          lv.wires,
          palette,
          topology: topology,
          active: active,
          body: false,
          labels: drawLabels,
          autoRoutes: autoRoutes,
          autoJunctions: autoJunctions,
        );
      } else {
        for (final p in lv.pins) {
          // 针脚自身短线用 pinStroke（未指定时跟随块边框色），总线针脚加粗到 2dp；
          // 对应网只画到外部节点 pos，不进入 edge。
          canvas.drawLine(p.edge, p.pos, p.isBus ? stubBusPaint : stubPaint);
          canvas.drawRect(
            Rect.fromCenter(center: p.edge, width: 3.0, height: 3.0),
            dotPaint,
          );
        }
        // 常量引脚：短线末端画常量标记；参数值由对应 Tooltip 悬停显示。
        // 悬停时方框用悬停黄填充为实心（高亮）。
        for (final p in lv.pins) {
          if (p.constText == null) continue;
          final hovered = identical(p, hoverConst);
          final r = Rect.fromLTWH(p.pos.dx, p.pos.dy - 5, 10, 10);
          canvas.drawRect(
            r,
            Paint()
              ..color = hovered ? palette.hover : palette.canvasBg
              ..style = PaintingStyle.fill,
          );
          canvas.drawRect(
            r,
            Paint()
              ..color = hovered ? palette.hover : palette.cellConst
              ..style = PaintingStyle.stroke
              ..strokeWidth = _kBoxBorder,
          );
        }
        // 展开容器：边缘针脚 → 子模块端口 的连接短线。
        for (final b in lv.blocks) {
          for (final (a, c) in b.subLinks) {
            canvas.drawLine(a, c, linkPaint);
          }
        }
        paintNetlistStraightPreview(
          canvas,
          lv.wires,
          palette,
          topology: topology,
          active: active,
          autoRoutes: autoRoutes,
          autoJunctions: autoJunctions,
        );
        for (final p in lv.ports) {
          _paintPort(canvas, p);
        }
      }
      canvas.restore();
    }
  }

  void _paintPort(Canvas canvas, NlPin p) {
    // 方向语义（对齐 Vivado Elaborated Design 的数据流方向）：
    // - **输入**（左侧）：符号贴线端在外、**尖端朝右**（指向设计内部）；
    // - **输出**（右侧）：贴线端为平边、**尖端朝右**（指向设计外部）；
    // - **双向**：六边形（两端都是尖），贴线端在左。
    final left = p.isPortInput ? p.pos.dx - _kPortGlyphW : p.pos.dx;
    final rect = Rect.fromLTWH(
      left,
      p.pos.dy - _kPortGlyphH / 2,
      _kPortGlyphW,
      _kPortGlyphH,
    );
    final tip = _kPortGlyphH / 2;
    final path = Path();
    if (p.dir == NetlistPortDir.inout) {
      path
        ..moveTo(rect.left + tip, rect.top)
        ..lineTo(rect.right - tip, rect.top)
        ..lineTo(rect.right, rect.center.dy)
        ..lineTo(rect.right - tip, rect.bottom)
        ..lineTo(rect.left + tip, rect.bottom)
        ..lineTo(rect.left, rect.center.dy)
        ..close();
    } else if (p.isPortInput) {
      path
        ..moveTo(rect.left, rect.top)
        ..lineTo(rect.right - tip, rect.top)
        ..lineTo(rect.right, rect.center.dy)
        ..lineTo(rect.right - tip, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..close();
    } else {
      path
        ..moveTo(rect.left, rect.top)
        ..lineTo(rect.right - tip, rect.top)
        ..lineTo(rect.right, rect.center.dy)
        ..lineTo(rect.right - tip, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..close();
    }
    final fill = switch (p.dir) {
      NetlistPortDir.input => palette.portFill,
      NetlistPortDir.output => palette.portFillOut,
      NetlistPortDir.inout => palette.portFillInout,
    };
    canvas.drawPath(
      path,
      Paint()
        ..color = fill
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = palette.portBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = _kBoxBorder,
    );
    // 符号内方向标注（`I` / `O` / `IO`）。
    final mk = TextPainter(
      text: TextSpan(
        text: p.dir.label,
        style: TextStyle(
          fontSize: p.dir == NetlistPortDir.inout ? 7.5 : 8.5,
          height: 1.0,
          fontWeight: FontWeight.w600,
          color: palette.portBorder,
          fontFamily: palette.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    mk.paint(
      canvas,
      Offset(rect.center.dx - mk.width / 2, rect.center.dy - mk.height / 2),
    );
    final tp = TextPainter(
      text: TextSpan(
        text: p.display,
        style: TextStyle(
          fontSize: 10,
          color: palette.portText,
          fontFamily: palette.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = p.isPortInput
        ? rect.left - _kPortTextGap - tp.width
        : rect.right + _kPortTextGap;
    tp.paint(canvas, Offset(x, rect.center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(NetlistWirePainter old) =>
      !identical(old.levels, levels) ||
      old.hover != hover ||
      old.palette != palette ||
      old.labelsOnly != labelsOnly ||
      old.drawLabels != drawLabels ||
      old.topology != topology ||
      !identical(old.autoRoutes, autoRoutes) ||
      !identical(old.autoJunctions, autoJunctions) ||
      old.hoverConst != hoverConst ||
      !_sameNets(old.active, active);
}

/// 命中测试（多层）：返回距 [p] 最近且在 `tol` 内的网及其所在层的平移。
(NlWire, Offset)? nlWireAtLevels(
  List<NlLevel> levels,
  Offset p, [
  double tol = 5,
  NlNetTopology topology = NlNetTopology.clique,
  Map<NlWire, List<(Offset, Offset)>>? autoRoutes,
]) {
  NlWire? best;
  var bestD = tol;
  var bestOffset = Offset.zero;
  for (final lv in levels) {
    final local = p - lv.offset;
    for (final w in lv.wires) {
      final segments = autoRoutes?[w] ?? nlStraightWireSegments(w, topology);
      for (final (a, b) in segments) {
        final d = _distToSeg(local, a, b);
        if (d <= bestD) {
          bestD = d;
          best = w;
          bestOffset = lv.offset;
        }
      }
    }
  }
  return best == null ? null : (best, bestOffset);
}

/// 命中测试：返回包含 `p` 的端口引脚（含端口图形附近 4px 容差）。
NlPin? nlPortAt(List<NlLevel> levels, Offset p) {
  for (final lv in levels) {
    for (final pin in lv.ports) {
      final left = pin.isPortInput ? pin.pos.dx - _kPortGlyphW : pin.pos.dx;
      final r = Rect.fromLTWH(
        left,
        pin.pos.dy - _kPortGlyphH / 2,
        _kPortGlyphW,
        _kPortGlyphH,
      ).inflate(4);
      if (r.contains(p)) return pin;
    }
  }
  return null;
}

/// 命中测试：返回包含 `p` 的块（跨层，用块体矩形判定）。
NlBlock? nlBlockAt(List<NlLevel> levels, Offset p) {
  for (final lv in levels) {
    for (final b in lv.blocks) {
      if (b.isIo || b.boxSize.width <= 0) continue;
      final r = Rect.fromLTWH(
        lv.offset.dx + b.boxOrigin.dx,
        lv.offset.dy + b.boxOrigin.dy,
        b.boxSize.width,
        b.boxSize.height,
      );
      if (r.contains(p)) return b;
    }
  }
  return null;
}

/// 展开/收起命中测试：`p` 是否落在某实例框内左上角的 `＋`/`−` 方块内。
/// 返回该实例单元（无则 null）。抽成纯函数便于单测与在 Listener 里直接命中
/// （避免与拖拽、层叠手势竞争）。
NetlistCell? nlExpandTargetAt(List<NlLevel> levels, Offset p) {
  const box = _kPlus + 4;
  for (final lv in levels) {
    for (final b in lv.blocks) {
      final cell = b.cell;
      if (cell == null || !cell.isInstance) continue;
      final base = lv.offset + b.boxOrigin + const Offset(3, 3);
      final r = Rect.fromLTWH(base.dx - 2, base.dy - 2, box, box);
      if (r.contains(p)) return cell;
    }
  }
  return null;
}

/// 集合是否同一批网（`setEquals` 需要 foundation 显式导入，这里自足实现）。
bool _sameNets(Set<NlWire> a, Set<NlWire> b) =>
    a.length == b.length && a.every(b.contains);

/// 星形拓扑的分支圆点：pin 数 ≥3 时在质心画一个实心点，避免多条线汇聚
/// 处看起来像“线断了/接错了”。团拓扑与两 pin 网不画。
List<Offset> nlStraightWireJunctions(
  NlWire wire, [
  NlNetTopology topology = NlNetTopology.clique,
]) {
  if (topology != NlNetTopology.star) return const [];
  final pts = [wire.from.pos, for (final l in wire.loads) l.pos];
  if (pts.length < 3) return const [];
  var cx = 0.0, cy = 0.0;
  for (final p in pts) {
    cx += p.dx;
    cy += p.dy;
  }
  return [Offset(cx / pts.length, cy / pts.length)];
}

/// 一条网的直线段集合：团=所有 pin 两两相连；星形=各 pin 连到质心。
List<(Offset, Offset)> nlStraightWireSegments(
  NlWire wire, [
  NlNetTopology topology = NlNetTopology.clique,
]) {
  final pts = [wire.from.pos, for (final l in wire.loads) l.pos];
  if (pts.length < 2) return const [];
  if (topology == NlNetTopology.clique) {
    return [
      for (var i = 0; i < pts.length; i++)
        for (var j = i + 1; j < pts.length; j++) (pts[i], pts[j]),
    ];
  }
  var cx = 0.0;
  var cy = 0.0;
  for (final q in pts) {
    cx += q.dx;
    cy += q.dy;
  }
  final c = Offset(cx / pts.length, cy / pts.length);
  return [for (final q in pts) (q, c)];
}

/// 命中测试：返回距 [p] 最近且在 `tol` 内的网（供悬停/点选显示网名）。
NlWire? nlWireAt(
  List<NlWire> wires,
  Offset p, [
  double tol = 5,
  NlNetTopology topology = NlNetTopology.clique,
]) {
  NlWire? best;
  var bestD = tol;
  for (final w in wires) {
    for (final (a, b) in nlStraightWireSegments(w, topology)) {
      final d = _distToSeg(p, a, b);
      if (d <= bestD) {
        bestD = d;
        best = w;
      }
    }
  }
  return best;
}

double _distToSeg(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx, dy = b.dy - a.dy;
  final len2 = dx * dx + dy * dy;
  if (len2 < 1e-6) return (p - a).distance;
  final t = (((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / len2).clamp(0.0, 1.0);
  return (p - Offset(a.dx + dx * t, a.dy + dy * t)).distance;
}

/// 符号内实例名/类型名标注色：暗色保持亮黄，浅色使用深蓝。
const Color nlBlockLabelColor = Color(0xFFFFD54F);
const Color nlBlockLabelLightColor = Color(0xFF24466D);
const Color nlExpandLightFill = Color(0xFF33486C);
const Color nlExpandLightHoverFill = Color(0xFF405A87);
const Color nlExpandLightBorder = Color(0xFF22385A);

Color nlBlockLabelColorOf(SchPalette palette) =>
    identical(palette, SchPalette.vivadoLight)
    ? nlBlockLabelLightColor
    : nlBlockLabelColor;

/// 走线宽度：单一 0.5dp，总线 3dp；悬停高亮时加粗。
double nlWireStrokeWidth(bool isBus, {bool active = false}) =>
    active ? (isBus ? 4.0 : 1.5) : (isBus ? 3.0 : 0.5);

/// 同网 T 型分支实心圆点半径：总线直径 8dp，单一走线直径 4dp。
double nlJunctionDotRadius(bool isBus) => isBus ? 4.0 : 2.0;

/// 绘制直线预览：每网按 [topology] 的直线。
///
/// [active] 中的网（悬停/点选及其相连网）用高亮色加粗，并在驱动端标注网名；
/// [body] 为 false 时只画标签（配合最顶层透明标签层，避免重复绘制线）。
void paintNetlistStraightPreview(
  Canvas canvas,
  List<NlWire> wires,
  SchPalette palette, {
  NlNetTopology topology = NlNetTopology.clique,
  Set<NlWire> active = const {},
  bool body = true,
  bool labels = true,
  Map<NlWire, List<(Offset, Offset)>>? autoRoutes,
  Map<NlWire, List<Offset>>? autoJunctions,
}) {
  if (body) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final w in wires) {
      final segments = autoRoutes?[w] ?? nlStraightWireSegments(w, topology);
      if (segments.isEmpty) continue;
      final hit = active.contains(w);
      line
        ..color = hit
            ? palette.hover
            : (w.isBus ? palette.wireBus : palette.wire)
        ..strokeWidth = nlWireStrokeWidth(w.isBus, active: hit);
      for (final (a, b) in segments) {
        canvas.drawLine(a, b, line);
      }
      if (autoRoutes == null) {
        for (final p in nlStraightWireJunctions(w, topology)) {
          canvas.drawCircle(
            p,
            nlJunctionDotRadius(w.isBus),
            Paint()
              ..color = hit
                  ? palette.hover
                  : (w.isBus ? palette.wireBus : palette.wire),
          );
        }
      }
    }
    // 分支圆点单独一遍，始终盖在走线之上。
    if (autoJunctions != null) {
      for (final w in wires) {
        final dots = autoJunctions[w];
        if (dots == null || dots.isEmpty) continue;
        final hit = active.contains(w);
        final dotPaint = Paint()
          ..color = hit
              ? palette.hover
              : (w.isBus ? palette.wireBus : palette.wire);
        final radius = nlJunctionDotRadius(w.isBus);
        for (final p in dots) {
          canvas.drawCircle(p, radius, dotPaint);
        }
      }
    }
  }
  if (!labels) return;
  for (final w in wires) {
    if (!active.contains(w) || w.label.isEmpty) continue;
    final tp = TextPainter(
      text: TextSpan(
        text: w.label,
        style: TextStyle(
          fontSize: 9.5,
          color: palette.netLabel,
          fontFamily: palette.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var at = w.from.pos + const Offset(5, -12);
    if (at.dx + tp.width > w.from.pos.dx + 220) {
      at = w.from.pos + Offset(-tp.width - 5, -12);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(at.dx - 2, at.dy - 1, tp.width + 4, tp.height + 2),
        const Radius.circular(2),
      ),
      Paint()..color = palette.canvasBg.withValues(alpha: 0.82),
    );
    tp.paint(canvas, at);
  }
}
