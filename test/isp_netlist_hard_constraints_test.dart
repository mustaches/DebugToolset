// 硬约束闸门：异网同轴重叠检测，以及真实 Multi_band_EQ 网表布线必须干净。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

NlPin _pin(String name, Offset p) {
  final pin = NlPin(
    port: name,
    display: name,
    width: 1,
    bits: const [0],
    dir: NetlistPortDir.output,
  );
  pin.pos = p;
  pin.edge = p;
  return pin;
}

NlWire _wire(int id) {
  final from = _pin('o$id', const Offset(0, 0));
  final load = _pin('i$id', const Offset(10, 0));
  return NlWire(from, [load], 'w$id', bits: const [0]);
}

void main() {
  test('水平同轴重叠计 1 对，正交交叉不计', () {
    final a = _wire(1);
    final b = _wire(2);
    const h1 = [((Offset(0, 50), Offset(300, 50)))];
    const h2 = [((Offset(100, 50), Offset(400, 50)))];
    const cross = [((Offset(150, 0), Offset(150, 100)))];
    final overlap = NlAutoRouteResult(
      segments: {a: h1, b: h2},
      junctions: const {},
    );
    final crossing = NlAutoRouteResult(
      segments: {a: h1, b: cross},
      junctions: const {},
    );
    expect(nlRoutingOverlapPairCount(overlap), 1);
    expect(nlRoutingOverlapPairCount(crossing), 0);
    expect(nlRouteIsClean(overlap), isFalse);
    expect(nlRouteIsClean(crossing), isTrue);
  });

  test('垂直同轴重叠同样计入；fallback 也判脏', () {
    final a = _wire(1);
    final b = _wire(2);
    const v1 = [((Offset(50, 0), Offset(50, 300)))];
    const v2 = [((Offset(50, 100), Offset(50, 400)))];
    final overlap = NlAutoRouteResult(
      segments: {a: v1, b: v2},
      junctions: const {},
    );
    expect(nlRoutingOverlapPairCount(overlap), 1);
    final fallback = NlAutoRouteResult(
      segments: {a: v1},
      junctions: const {},
      fallbackCount: 1,
    );
    expect(nlRouteIsClean(fallback), isFalse);
  });

  test('真实 Multi_band_EQ：单趟布线零硬约束', () {
    final file = File(
      'scratch/ip_sch/isp_ip_multi_band_eq_core/net.json',
    );
    if (!file.existsSync()) return;
    final nl = YosysNetlist.parse(file.readAsStringSync());
    final m = nl.modules.values.first;
    final model = buildNetlistDiagramModel(
      m,
      layout: NlLayoutAlgorithm.layered,
    );
    final routes = routeNetlistWires(model.flattened(), model.canvasSize);
    expect(nlRoutingOverlapPairCount(routes), 0);
    final diag = computeNlRoutingDiagnostics(
      model.flattened(),
      model.canvasSize,
      routes: routes.segments,
      junctions: routes.junctions,
    );
    expect(diag.violations, isEmpty);
  });
}
