// 分层布局内核（netlist_layered_layout.dart）测试：链/扇出/环/压列/排序/确定性。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_layered_layout.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('空图', () {
    final r = layoutLayeredNetlist(nodeCount: 0, edges: const []);
    expect(r.columnCount, 0);
    expect(r.column, isEmpty);
    expect(r.order, isEmpty);
  });

  test('长链按最长路径逐层展开，不压列', () {
    final r = layoutLayeredNetlist(
      nodeCount: 4,
      edges: const [(0, 1), (1, 2), (2, 3)],
      maxColumns: 10,
    );
    expect(r.layerCount, 4);
    expect(r.columnCount, 4);
    expect(r.column, [0, 1, 2, 3]);
    expect(r.crossingCount, 0);
    expect(r.cutEdges, 3);
  });

  test('链压到 2 列：单调不分叉、列非空', () {
    final r = layoutLayeredNetlist(
      nodeCount: 8,
      edges: const [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7)],
      maxColumns: 2,
    );
    expect(r.columnCount, 2);
    for (var i = 0; i + 1 < 8; i++) {
      expect(r.column[i + 1], greaterThanOrEqualTo(r.column[i]));
    }
    expect(r.order[0], isNotEmpty);
    expect(r.order[1], isNotEmpty);
    expect(r.cutEdges, 1);
  });

  test('扇出：驱动在首列，负载同列', () {
    final r = layoutLayeredNetlist(
      nodeCount: 4,
      edges: const [(0, 1), (0, 2), (0, 3)],
      maxColumns: 8,
    );
    expect(r.column, [0, 1, 1, 1]);
    expect(r.order[1], [1, 2, 3]);
  });

  test('时序反馈环不导致无限分层', () {
    // 0→1→2→0 环，2→3 输出。
    final r = layoutLayeredNetlist(
      nodeCount: 4,
      edges: const [(0, 1), (1, 2), (2, 0), (2, 3)],
      maxColumns: 8,
    );
    expect(r.layerCount, lessThanOrEqualTo(4));
    expect(r.columnCount, greaterThan(0));
    // 前向边（去掉回边后）保持单调。
    for (final (u, v) in const [(0, 1), (1, 2), (2, 3)]) {
      expect(r.column[v], greaterThanOrEqualTo(r.column[u]));
    }
  });

  test('中位数排序消除完全反转的交叉', () {
    // 两层各 4 节点，边完全反转：A0→B3, A1→B2, A2→B1, A3→B0。
    final r = layoutLayeredNetlist(
      nodeCount: 8,
      edges: const [(0, 7), (1, 6), (2, 5), (3, 4)],
      maxColumns: 2,
    );
    expect(r.columnCount, 2);
    expect(r.crossingCount, 0, reason: '第二列应按驱动顺序反转');
    expect(r.order[1], [7, 6, 5, 4]);
  });

  test('20 级链压到 5 列：每列非空且宽度均衡', () {
    final edges = [for (var i = 0; i + 1 < 20; i++) (i, i + 1)];
    final r = layoutLayeredNetlist(
      nodeCount: 20,
      edges: edges,
      maxColumns: 5,
    );
    expect(r.columnCount, 5);
    for (var c = 0; c < 5; c++) {
      expect(r.order[c], isNotEmpty, reason: '第 $c 列不能为空');
    }
    final sizes = [for (var c = 0; c < 5; c++) r.order[c]!.length];
    expect(sizes.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(6));
    expect(sizes.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(2));
  });

  test('孤立节点归入首列，不影响其它节点', () {
    final r = layoutLayeredNetlist(
      nodeCount: 4,
      edges: const [(0, 1)],
      maxColumns: 4,
    );
    expect(r.column[0], 0);
    expect(r.column[1], 1);
    expect(r.column[2], 0);
    expect(r.column[3], 0);
    expect(r.order[0], containsAll([0, 2, 3]));
  });

  test('重复边与自环被忽略，结果确定', () {
    final r1 = layoutLayeredNetlist(
      nodeCount: 3,
      edges: const [(0, 0), (0, 1), (0, 1), (1, 2)],
      maxColumns: 3,
    );
    final r2 = layoutLayeredNetlist(
      nodeCount: 3,
      edges: const [(0, 0), (0, 1), (0, 1), (1, 2)],
      maxColumns: 3,
    );
    expect(r1.column, r2.column);
    expect(r1.order, r2.order);
    expect(r1.column, [0, 1, 2]);
  });

  test('端口槽位：同目标行的端口按 PAVA 居中展开并保持整 Grid', () {
    NlPin pin(String name) {
      final p = NlPin(
        port: name,
        display: name,
        width: 1,
        bits: const [0],
        isPort: true,
      );
      p.pos = Offset.zero;
      p.edge = Offset.zero;
      return p;
    }

    final a = pin('a');
    final b = pin('b');
    final c = pin('c');
    final placed = nlPlacePortRows([
      (a, 100),
      (b, 100),
      (c, 100),
    ], 0);
    final ys = [for (final (_, y) in placed) y];
    // 目标是同一行 100（非整 Grid）；等距回归 + 整 Grid 取整得到
    // 90/105/120：总位移平方最小，末端偏差 20px；顺序下推会是
    // 100/115/130（末端偏 30px，且首项不在 Grid 上）。
    expect(ys, [90, 105, 120]);
    for (final y in ys) {
      expect((y / 15).round() * 15, closeTo(y, 0.01));
    }
    expect(ys.last - 100, lessThan(30));

    final shifted = nlPlacePortRows([(a, -30)], 0);
    expect(shifted.single.$2, 0, reason: '越出顶部时整体下移到 topY');
  });

  test('Sifting 不劣化交叉数且结果确定', () {
    final edges = <(int, int)>[];
    var seed = 12345;
    int next() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed;
    }

    for (var i = 0; i < 40; i++) {
      for (var k = 0; k < 3; k++) {
        final v = i + 1 + next() % 6;
        if (v < 40) edges.add((i, v));
      }
    }
    final base = layoutLayeredNetlist(
      nodeCount: 40,
      edges: edges,
      maxColumns: 8,
      sift: false,
    );
    final sifted = layoutLayeredNetlist(
      nodeCount: 40,
      edges: edges,
      maxColumns: 8,
    );
    expect(sifted.crossingCount, lessThanOrEqualTo(base.crossingCount));
    final again = layoutLayeredNetlist(
      nodeCount: 40,
      edges: edges,
      maxColumns: 8,
    );
    expect(again.column, sifted.column);
    expect(again.order, sifted.order);
    expect(again.crossingCount, sifted.crossingCount);
  });

  test('层平衡：出边多于入边的节点下移，缩短总边长', () {
    const edges = <(int, int)>[
      (0, 1),
      (1, 4),
      (1, 5),
      (0, 2),
      (2, 3),
      (3, 4),
      (3, 5),
    ];
    final before = layoutLayeredNetlist(
      nodeCount: 6,
      edges: edges,
      maxColumns: 10,
      balance: false,
    );
    final after = layoutLayeredNetlist(
      nodeCount: 6,
      edges: edges,
      maxColumns: 10,
    );
    int span(NlLayeredLayoutResult r) => edges.fold(
      0,
      (sum, e) => sum + (r.column[e.$2] - r.column[e.$1]),
    );
    expect(span(after), lessThan(span(before)));
    expect(after.column[1], 2);
    final again = layoutLayeredNetlist(
      nodeCount: 6,
      edges: edges,
      maxColumns: 10,
    );
    expect(again.column, after.column);
    expect(again.crossingCount, after.crossingCount);
  });

  test('真实网表：列号连续、布局确定，交叉显著低于经典布局', () {
    final file = File('scratch/ip_sch/isp_ip_eq6_axis/net.json');
    if (!file.existsSync()) {
      markTestSkipped('缺少 ${file.path}');
      return;
    }
    final netlist = YosysNetlist.parse(file.readAsStringSync());
    final module = netlist.modules.values.firstWhere(
      (m) => m.cells.length > 5,
      orElse: () => netlist.modules.values.first,
    );
    final compact = buildNetlistDiagramModel(module);
    final layered = buildNetlistDiagramModel(
      module,
      layout: NlLayoutAlgorithm.layered,
    );
    final again = buildNetlistDiagramModel(
      module,
      layout: NlLayoutAlgorithm.layered,
    );

    expect(layered.wires.length, compact.wires.length);
    expect(layered.canvasSize.width.isFinite, isTrue);
    expect(layered.canvasSize.height.isFinite, isTrue);

    final columns = [
      for (final b in layered.blocks)
        if (!b.isIo) b.column,
    ];
    final minCol = columns.reduce(math.min);
    final maxCol = columns.reduce(math.max);
    expect(minCol, 0);
    expect(
      columns.toSet().length,
      maxCol + 1,
      reason: '列号必须连续（不能出现空列）',
    );

    // 确定性：同一输入两次构建逐块同列同坐标。
    expect(again.canvasSize, layered.canvasSize);
    for (var i = 0; i < layered.blocks.length; i++) {
      final a = layered.blocks[i];
      final b = again.blocks[i];
      expect(b.column, a.column);
      expect(b.origin, a.origin);
    }

    final compactDiag = computeNlRoutingDiagnostics(
      compact.flattened(),
      compact.canvasSize,
      options: const NlMetricsOptions(checkLegality: false),
    );
    final layeredDiag = computeNlRoutingDiagnostics(
      layered.flattened(),
      layered.canvasSize,
      options: const NlMetricsOptions(checkLegality: false),
    );
    expect(
      layeredDiag.crossings,
      lessThan(compactDiag.crossings),
      reason: '分层布局应减少交叉',
    );
    expect(
      layeredDiag.crossings,
      lessThan((compactDiag.crossings * 0.7).round()),
      reason: '实测应显著优于 30% 阈值',
    );

    // 列的纵向对齐必须落在 15px Grid 上：半格位移会让针脚坐标出现 x.5，
    // 路由器按整格建模，逃生段会与 7.5px 补线同轴重叠。
    for (final b in layered.blocks) {
      expect((b.origin.dx / 15).round() * 15, closeTo(b.origin.dx, 0.01));
      expect((b.origin.dy / 15).round() * 15, closeTo(b.origin.dy, 0.01));
    }
    for (final w in layered.wires) {
      for (final p in [w.from, ...w.loads]) {
        expect((p.pos.dx / 15).round() * 15, closeTo(p.pos.dx, 0.01));
        expect((p.pos.dy / 15).round() * 15, closeTo(p.pos.dy, 0.01));
      }
    }

    // 分层布局 + 单趟正交布线：硬约束必须为零（此前半格位移会引入
    // 4 处 7.5px 同轴重叠）。
    final routes = routeNetlistWires(layered.flattened(), layered.canvasSize);
    final routedDiag = computeNlRoutingDiagnostics(
      layered.flattened(),
      layered.canvasSize,
      routes: routes.segments,
      junctions: routes.junctions,
    );
    expect(routedDiag.legal, isTrue, reason: '${routedDiag.violationCounts}');
    expect(routedDiag.detour, lessThan(1.25));
  });
}
