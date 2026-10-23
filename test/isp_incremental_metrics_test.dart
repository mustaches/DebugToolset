// 增量布线指标测试：增/删/替换后与全量 nlRoutingMetrics 逐项一致。
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

typedef _Seg = (Offset, Offset);

void main() {
  test('新增两条交叉网：交叉/长度与全量一致', () {
    final a = _wire(1);
    final b = _wire(2);
    const sa = [((Offset(0, 50), Offset(100, 50)))];
    const sb = [((Offset(50, 0), Offset(50, 100)))];
    final inc = NlIncrementalRouteMetrics()
      ..upsert(1, sa)
      ..upsert(2, sb);
    final full = nlRoutingMetrics(
      NlAutoRouteResult(segments: {a: sa, b: sb}, junctions: const {}),
    );
    expect(inc.crossings, full.crossings);
    expect(inc.snapshot().length, full.length);
    expect(inc.snapshot().bends, full.bends);
    expect(inc.crossings, 1);
  });

  test('替换一条网后交叉消失，结果仍与全量一致', () {
    final a = _wire(1);
    final b = _wire(2);
    const sa = [((Offset(0, 50), Offset(100, 50)))];
    const sb1 = [((Offset(50, 0), Offset(50, 100)))];
    const sb2 = [((Offset(50, 0), Offset(120, 0)))];
    final inc = NlIncrementalRouteMetrics()
      ..upsert(1, sa)
      ..upsert(2, sb1)
      ..upsert(2, sb2);
    final full = nlRoutingMetrics(
      NlAutoRouteResult(segments: {a: sa, b: sb2}, junctions: const {}),
    );
    expect(inc.crossings, full.crossings);
    expect(inc.crossings, 0);
    expect(inc.snapshot().length, closeTo(full.length, 0.001));
  });

  test('删除网后不再贡献交叉/折弯/长度', () {
    final a = _wire(1);
    const sa = [((Offset(0, 50), Offset(100, 50)))];
    const sb = [
      ((Offset(50, 0), Offset(50, 40))),
      ((Offset(50, 40), Offset(80, 40))),
    ];
    final inc = NlIncrementalRouteMetrics()
      ..upsert(1, sa)
      ..upsert(2, sb)
      ..remove(2);
    final full = nlRoutingMetrics(
      NlAutoRouteResult(segments: {a: sa}, junctions: const {}),
    );
    expect(inc.crossings, full.crossings);
    expect(inc.snapshot().bends, full.bends);
    expect(inc.snapshot().length, full.length);
    expect(inc.contains(2), isFalse);
    final before = inc.snapshot().length;
    inc.remove(99);
    expect(inc.snapshot().length, before);
  });

  test('折弯分布与 P95 与全量一致', () {
    final ws = [_wire(1), _wire(2), _wire(3)];
    const s1 = [((Offset(0, 0), Offset(100, 0)))];
    const s2 = [
      ((Offset(0, 20), Offset(40, 20))),
      ((Offset(40, 20), Offset(40, 60))),
    ];
    const s3 = [
      ((Offset(0, 80), Offset(20, 80))),
      ((Offset(20, 80), Offset(20, 100))),
      ((Offset(20, 100), Offset(40, 100))),
      ((Offset(40, 100), Offset(40, 80))),
    ];
    final inc = NlIncrementalRouteMetrics()
      ..upsert(1, s1)
      ..upsert(2, s2)
      ..upsert(3, s3);
    final full = nlRoutingMetrics(
      NlAutoRouteResult(
        segments: {ws[0]: s1, ws[1]: s2, ws[2]: s3},
        junctions: const {},
      ),
    );
    expect(inc.snapshot().bends, full.bends);
    expect(inc.snapshot().bendP95, full.bendP95);
  });

  test('加入顺序不影响快照（确定性）', () {
    const s1 = [((Offset(0, 50), Offset(100, 50)))];
    const s2 = [((Offset(50, 0), Offset(50, 100)))];
    const s3 = [((Offset(0, 0), Offset(50, 50)))];
    final a = NlIncrementalRouteMetrics()
      ..upsert(1, s1)
      ..upsert(2, s2)
      ..upsert(3, s3);
    final b = NlIncrementalRouteMetrics()
      ..upsert(3, s3)
      ..upsert(1, s1)
      ..upsert(2, s2);
    expect(a.snapshot().crossings, b.snapshot().crossings);
    expect(a.snapshot().bends, b.snapshot().bends);
    expect(a.snapshot().length, b.snapshot().length);
    expect(a.snapshot().bendP95, b.snapshot().bendP95);
  });

  test('固定序列多次替换：每一步都与全量一致', () {
    final wires = [for (var i = 0; i < 5; i++) _wire(i)];
    final inc = NlIncrementalRouteMetrics();
    final map = <NlWire, List<_Seg>>{};
    final ops = <(int, List<_Seg>)>[
      (0, [((Offset(0, 10), Offset(100, 10)))]),
      (1, [((Offset(0, 50), Offset(100, 50)))]),
      (2, [((Offset(50, 0), Offset(50, 80)))]),
      (3, [((Offset(10, 10), Offset(10, 90)))]),
      (4, [((Offset(0, 30), Offset(80, 30)))]),
      (1, [((Offset(0, 12), Offset(90, 12)))]),
      (2, [((Offset(60, 0), Offset(60, 70)))]),
      (0, [((Offset(5, 10), Offset(95, 10)))]),
    ];
    for (final (id, segs) in ops) {
      inc.upsert(id, segs);
      map[wires[id]] = segs;
      final full = nlRoutingMetrics(
        NlAutoRouteResult(segments: {...map}, junctions: const {}),
      );
      expect(inc.snapshot().crossings, full.crossings, reason: 'id=$id');
      expect(inc.snapshot().bends, full.bends, reason: 'id=$id');
      expect(inc.snapshot().length, closeTo(full.length, 0.001));
      expect(inc.snapshot().bendP95, full.bendP95);
    }
  });
}
