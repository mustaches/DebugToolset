/// IP 包模块级框图（Vivado Elaborated Design 风格）：从编组规划 IR
///（[IpPlan]/[GroupCPlan]，与生成的 Verilog 严格同构）推导模块实例、
/// 端口针脚与网表连线，纯 Dart 绘制——不经过 yosys，信息 100% 准确。
///
/// 布局：输入端口组钉左缘、输出端口组钉右缘，节点实例按拓扑层级分列
/// （列 = 距外部输入的最长路径），列内按拓扑序堆叠；连线为三段正交肘线，
/// 中段位宽标注（`位宽b 格式`）。点节点块可打开其代码标签页。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../codegen/group_c_plan.dart';
import '../codegen/ip_gen_plan.dart';
import '../models/isp_graph.dart';
import '../models/isp_node.dart';

/// 框图针脚（端口）：名 + 位宽 + 帧格式。
class SchPin {
  final String name;
  final int bits;
  final String format;

  /// 布局后的绝对中心坐标（连线端点用）。
  Offset pos = Offset.zero;

  SchPin(this.name, this.bits, this.format);
}

/// 框图块：编组节点实例或外部 IO 端口组（id 为 `#in`/`#out`）。
class SchBlock {
  final String id;
  final String title;
  final String subtitle;
  final bool isIo;
  final List<SchPin> ins;
  final List<SchPin> outs;

  /// 布局：列（拓扑层级，#in=-1，#out=maxLevel+1）与行序。
  int column;
  int row;

  /// 布局后的左上角与尺寸。
  Offset origin = Offset.zero;
  Size size = Size.zero;

  SchBlock({
    required this.id,
    required this.title,
    required this.subtitle,
    this.isIo = false,
    this.ins = const [],
    this.outs = const [],
    this.column = 0,
    this.row = 0,
  });
}

/// 框图连线（网表网）：源针脚 → 目的针脚 + 位宽标注。
class SchWire {
  final SchPin from;
  final SchPin to;

  /// 中段位宽标注文本（如 `24b rgb`）。
  final String label;

  SchWire(this.from, this.to, this.label);
}

/// 框图模型：块 + 连线 + 画布尺寸。
class SchModel {
  final List<SchBlock> blocks;
  final List<SchWire> wires;
  final Size canvasSize;

  const SchModel(this.blocks, this.wires, this.canvasSize);
}

// ---- 布局常量 ----
const _kBlockWidth = 150.0;
const _kPinRowH = 18.0;
const _kHeaderH = 28.0;
const _kColGap = 110.0;
const _kRowGap = 42.0;
const _kMargin = 28.0;
const _kIoWidth = 96.0;

/// 从 IP 规划构建框图模型（纯 Dart，无 Flutter 依赖部分在此函数内完成
/// 布局计算，坐标供绘制层直接使用）。
///
/// 说明：本图是「生成意图的结构图」——gamma 等穿透节点按图原样显示
/// （生成的 Verilog 中其为直连导线），mux4 死支路已由规划层剔除。
SchModel buildSchModel(IpPlan plan, IspGraph graph, IspNodeGroup group) {
  final cPlan = plan.cPlan;
  final pixBits = plan.pixBits;
  int bitsOf(IspPortSpec? spec) =>
      pixBits * cChannelsOfPort(spec?.type ?? IspPortType.mono);
  String fmtOf(IspPortSpec? spec) =>
      cFrameFormatOfPort(spec?.type ?? IspPortType.mono);

  IspPortSpec? specOf(String nodeId, String port, bool input) {
    final type = IspNodeRegistry.byId(cPlan.members[nodeId]!.typeId);
    final list = input ? type?.inputs : type?.outputs;
    for (final s in list ?? const <IspPortSpec>[]) {
      if (s.name == port) return s;
    }
    return null;
  }

  final blocks = <String, SchBlock>{};

  // 节点实例块：针脚 = 组内连线占用端口 ∪ 外部输入/输出占用端口。
  for (final id in cPlan.topo) {
    final node = cPlan.members[id]!;
    final usedIns = <String>{
      for (final c in cPlan.inGroupConns)
        if (c.toNodeId == id) c.toPort,
      for (final key in cPlan.extInputs.keys)
        if (key.startsWith('$id:')) key.substring(id.length + 1),
    };
    final usedOuts = <String>{
      for (final c in cPlan.inGroupConns)
        if (c.fromNodeId == id) c.fromPort,
      for (final key in cPlan.extOutputs.keys)
        if (key.startsWith('$id:')) key.substring(id.length + 1),
    };
    final type = IspNodeRegistry.byId(node.typeId);
    blocks[id] = SchBlock(
      id: id,
      title: node.name,
      subtitle: type?.displayName ?? node.typeId,
      ins: [
        for (final p in usedIns)
          SchPin(p, bitsOf(specOf(id, p, true)), fmtOf(specOf(id, p, true))),
      ]..sort(),
      outs: [
        for (final p in usedOuts)
          SchPin(p, bitsOf(specOf(id, p, false)), fmtOf(specOf(id, p, false))),
      ]..sort(),
    );
  }

  // 外部 IO 端口组块。
  final inBlock = SchBlock(
    id: '#in',
    title: 'in',
    subtitle: '输入端口',
    isIo: true,
    outs: [
      for (final p in plan.cPlan.extInputParams)
        SchPin(p.name, pixBits * p.channels, p.format),
    ],
  );
  final outBlock = SchBlock(
    id: '#out',
    title: 'out',
    subtitle: '输出端口',
    isIo: true,
    ins: [
      for (final p in plan.cPlan.extOutputParams)
        SchPin(p.name, pixBits * p.channels, p.format),
    ],
  );

  // 连线：组内活边 + 外部输入/输出。
  final wires = <SchWire>[];
  SchPin? pinOf(String blockId, String port, bool input) {
    final b = blocks[blockId] ?? (blockId == '#in'
        ? inBlock
        : blockId == '#out'
            ? outBlock
            : null);
    if (b == null) return null;
    final list = input ? b.ins : b.outs;
    for (final p in list) {
      if (p.name == port) return p;
    }
    return null;
  }

  for (final c in cPlan.inGroupConns) {
    if (!cPlan.live.contains(c.fromNodeId) || !cPlan.live.contains(c.toNodeId)) {
      continue;
    }
    final from = pinOf(c.fromNodeId, c.fromPort, false);
    final to = pinOf(c.toNodeId, c.toPort, true);
    if (from == null || to == null) continue;
    wires.add(SchWire(from, to, '${from.bits}b ${from.format}'));
  }
  for (final e in cPlan.extInputs.entries) {
    final sep = e.key.indexOf(':');
    final nodeId = e.key.substring(0, sep);
    final port = e.key.substring(sep + 1);
    final from = pinOf('#in', e.value.name, false);
    final to = pinOf(nodeId, port, true);
    if (from == null || to == null) continue;
    wires.add(SchWire(from, to, '${from.bits}b ${from.format}'));
  }
  for (final e in cPlan.extOutputs.entries) {
    final sep = e.key.indexOf(':');
    final nodeId = e.key.substring(0, sep);
    final port = e.key.substring(sep + 1);
    final from = pinOf(nodeId, port, false);
    final to = pinOf('#out', e.value.name, true);
    if (from == null || to == null) continue;
    wires.add(SchWire(from, to, '${from.bits}b ${from.format}'));
  }

  // ---- 布局：拓扑层级分列（距外部输入的最长路径），列内按拓扑序 ----
  final level = <String, int>{};
  for (final id in cPlan.topo) {
    var lv = 0;
    for (final c in cPlan.inGroupConns) {
      if (c.toNodeId == id && level.containsKey(c.fromNodeId)) {
        lv = math.max(lv, level[c.fromNodeId]! + 1);
      }
    }
    level[id] = lv;
  }
  final maxLevel = level.values.fold<int>(0, math.max);
  final colRows = <int, int>{};
  for (final id in cPlan.topo) {
    final b = blocks[id]!;
    b.column = level[id]!;
    b.row = colRows.update(b.column, (v) => v + 1, ifAbsent: () => 0);
  }
  inBlock.column = -1;
  inBlock.row = 0;
  outBlock.column = maxLevel + 1;
  outBlock.row = 0;

  // 块尺寸与针脚坐标：块高 = 表头 + 针脚行数；列内按累积高度堆叠。
  Size blockSize(SchBlock b) {
    final rows = math.max(1, math.max(b.ins.length, b.outs.length));
    return Size(b.isIo ? _kIoWidth : _kBlockWidth,
        _kHeaderH + rows * _kPinRowH + 8);
  }

  final allBlocks = [inBlock, for (final id in cPlan.topo) blocks[id]!, outBlock];
  // 每列 x：列宽取该列最大块宽（IO 列窄）。
  final colX = <int, double>{};
  var x = _kMargin;
  for (var col = -1; col <= maxLevel + 1; col++) {
    colX[col] = x;
    var colW = _kBlockWidth;
    for (final b in allBlocks) {
      if (b.column == col) colW = math.max(colW, blockSize(b).width);
    }
    x += colW + _kColGap;
  }
  // 列内 y：按行序累积。
  final colY = <int, double>{};
  for (final b in allBlocks..sort((a, b) => a.row.compareTo(b.row))) {
    final y = colY[b.column] ?? _kMargin;
    b.origin = Offset(colX[b.column]!, y);
    b.size = blockSize(b);
    colY[b.column] = y + b.size.height + _kRowGap;
    // 针脚：输入沿左缘、输出沿右缘，自表头下方依次排。
    for (var i = 0; i < b.ins.length; i++) {
      b.ins[i].pos =
          b.origin + Offset(0, _kHeaderH + i * _kPinRowH + _kPinRowH / 2);
    }
    for (var i = 0; i < b.outs.length; i++) {
      b.outs[i].pos = b.origin +
          Offset(b.size.width, _kHeaderH + i * _kPinRowH + _kPinRowH / 2);
    }
  }
  final canvasW = x - _kColGap + _kMargin;
  final canvasH = colY.values.fold<double>(0, math.max) + _kMargin;

  return SchModel(
    [inBlock, for (final id in cPlan.topo) blocks[id]!, outBlock],
    wires,
    Size(canvasW, canvasH),
  );
}

/// 模块级框图组件：CustomPaint 画连线 + Positioned 块（块可点击打开节点
/// 代码页）；InteractiveViewer 拖动平移/滚轮缩放。
class IpBlockDiagram extends StatelessWidget {
  final SchModel model;
  final void Function(String nodeId)? onOpenNode;

  const IpBlockDiagram({super.key, required this.model, this.onOpenNode});

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      constrained: false,
      minScale: 0.1,
      maxScale: 8,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      child: SizedBox(
        width: model.canvasSize.width,
        height: model.canvasSize.height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CustomPaint(
              size: model.canvasSize,
              painter: _SchWirePainter(model.wires),
            ),
            for (final b in model.blocks) _blockWidget(b, context),
          ],
        ),
      ),
    );
  }

  Widget _blockWidget(SchBlock b, BuildContext context) {
    final block = Container(
      width: b.size.width,
      height: b.size.height,
      decoration: BoxDecoration(
        color: b.isIo ? const Color(0xFF1B2A28) : const Color(0xFF252526),
        border: Border.all(
            color: b.isIo ? const Color(0xFF4EC9B0) : const Color(0xFF3A3A3A)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 表头：实例名 + 模块类型。
          Container(
            height: _kHeaderH,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: b.isIo ? const Color(0xFF1F3A35) : const Color(0xFF2D2D30),
              border: const Border(
                  bottom: BorderSide(color: Color(0xFF3A3A3A))),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  b.title,
                  style: const TextStyle(
                      fontSize: 11, height: 1.1, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  b.subtitle,
                  style: const TextStyle(
                      fontSize: 9, height: 1.1, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // 针脚行：输入左对齐、输出右对齐，行内文本标签。
          Expanded(
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
                            child: Text(' ${p.name}',
                                style: const TextStyle(
                                    fontSize: 9, color: Colors.white70)),
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
                            child: Text('${p.name} ',
                                style: const TextStyle(
                                    fontSize: 9, color: Colors.white70)),
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
    return Positioned(
      left: b.origin.dx,
      top: b.origin.dy,
      child: b.isIo || onOpenNode == null
          ? block
          : InkWell(
              onTap: () => onOpenNode!(b.id),
              child: block,
            ),
    );
  }
}

/// 连线绘制：三段正交肘线（源针脚 → 中点竖直段 → 目的针脚）+ 中点上方
/// 位宽标注。
class _SchWirePainter extends CustomPainter {
  final List<SchWire> wires;

  _SchWirePainter(this.wires);

  @override
  void paint(Canvas canvas, Size size) {
    final wirePaint = Paint()
      ..color = const Color(0xFF4CAF50)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final pinPaint = Paint()..color = const Color(0xFF4CAF50);
    for (final w in wires) {
      final a = w.from.pos;
      final b = w.to.pos;
      final midX = (a.dx + b.dx) / 2;
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(midX, a.dy)
        ..lineTo(midX, b.dy)
        ..lineTo(b.dx, b.dy);
      canvas.drawPath(path, wirePaint);
      // 针脚端点小圆点。
      canvas.drawCircle(a, 2.5, pinPaint);
      canvas.drawCircle(b, 2.5, pinPaint);
      // 位宽标注（中点竖直段旁）。
      final tp = TextPainter(
        text: TextSpan(
          text: w.label,
          style: const TextStyle(fontSize: 9, color: Color(0xFF9CCC9C)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final midY = (a.dy + b.dy) / 2;
      tp.paint(canvas, Offset(midX + 3, midY - tp.height - 1));
    }
  }

  @override
  bool shouldRepaint(_SchWirePainter old) => !identical(old.wires, wires);
}
