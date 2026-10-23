// 数字网表走线诊断（netlist_routing_metrics.dart）测试：
// 合成几何用例逐项校验口径 + 真实 yosys 网表端到端一致性（文件缺失自动 skip）。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

const _canvas = Size(200, 200);

NlPin _pin(
  String name,
  Offset pos, {
  NetlistPortDir dir = NetlistPortDir.input,
  bool isPort = false,
  int width = 1,
}) {
  final p = NlPin(
    port: name,
    display: name,
    width: width,
    bits: [for (var i = 0; i < width; i++) i],
    isBus: width > 1,
    dir: dir,
    isPort: isPort,
    netNames: const [],
  );
  p.pos = pos;
  p.edge = pos;
  return p;
}

NlBlock _block(String id, Rect rect) {
  final b = NlBlock(id: id, title: id, subtitle: '');
  b.boxOrigin = rect.topLeft;
  b.boxSize = rect.size;
  b.origin = rect.topLeft;
  b.size = rect.size;
  return b;
}

NlLevel _level(
  List<NlBlock> blocks,
  List<NlWire> wires, {
  Offset offset = Offset.zero,
}) => NlLevel(
  blocks: blocks,
  wires: wires,
  pins: const [],
  ports: const [],
  offset: offset,
);

NlWire _wire(NlPin from, List<NlPin> loads, {String label = ''}) =>
    NlWire(from, loads, label, bits: [for (var i = 0; i < from.bits.length; i++) i]);

NlRoutingDiagnostics _diagnose(
  List<NlLevel> levels, {
  Map<NlWire, List<(Offset, Offset)>>? routes,
  Map<NlWire, List<Offset>>? junctions,
  NlNetTopology topology = NlNetTopology.star,
  double grid = 15,
}) => computeNlRoutingDiagnostics(
  levels,
  _canvas,
  routes: routes,
  junctions: junctions,
  topology: topology,
  options: NlMetricsOptions(grid: grid, minParallelGap: grid),
);

void main() {
  group('直线预览', () {
    test('两条直线在已知点相交计 1 个交叉', () {
      final a = _pin('a', const Offset(0, 0), dir: NetlistPortDir.output);
      final b = _pin('b', const Offset(0, 100), dir: NetlistPortDir.output);
      final la = _pin('la', const Offset(100, 100));
      final lb = _pin('lb', const Offset(100, 0));
      final wa = _wire(a, [la], label: 'a');
      final wb = _wire(b, [lb], label: 'b');
      final d = _diagnose([
        _level([], [wa, wb]),
      ]);

      expect(d.source, 'straight');
      expect(d.crossings, 1);
      expect(d.crossingPoints.single, const Offset(50, 50));
      expect(d.bends, 0, reason: '直线预览没有折弯概念');
      expect(d.detour, isNull, reason: '团/星拓扑不是树，绕行比不可比');
      expect(d.portAlignmentRate, 1.0);
    });

    test('平行直线不产生交叉', () {
      final a = _pin('a', const Offset(0, 0), dir: NetlistPortDir.output);
      final b = _pin('b', const Offset(0, 30), dir: NetlistPortDir.output);
      final wa = _wire(a, [_pin('la', const Offset(100, 0))]);
      final wb = _wire(b, [_pin('lb', const Offset(100, 30))]);
      final d = _diagnose([
        _level([], [wa, wb]),
      ]);
      expect(d.crossings, 0);
      expect(d.crossingPoints, isEmpty);
    });

    test('扇形网（一驱多负载）按实际线段统计长度', () {
      final from = _pin('o', const Offset(0, 50), dir: NetlistPortDir.output);
      final l1 = _pin('i1', const Offset(100, 0));
      final l2 = _pin('i2', const Offset(100, 100));
      final w = _wire(from, [l1, l2]);
      final d = _diagnose([
        _level([], [w]),
      ]);
      // 星形：两条负载支路各 60.09，驱动到质心 66.67。
      expect(d.length, closeTo(66.6667 + 2 * 60.0924, 0.01));
      expect(d.hpwl, closeTo(100 + 100, 0.01));
      expect(d.wireCount, 1);
    });

    test('端口对齐只按最近一跳计：扇出端口仍算对齐', () {
      final port = _pin(
        'p',
        const Offset(0, 50),
        dir: NetlistPortDir.output,
        isPort: true,
      );
      final near = _pin('n', const Offset(100, 50));
      final far = _pin('f', const Offset(100, 150));
      final w = _wire(port, [near, far]);
      final d = _diagnose([
        _level([], [w]),
      ], topology: NlNetTopology.clique);
      expect(
        d.portAlignmentRate,
        1.0,
        reason: '扇出端口不可能对齐所有负载，最近一跳对齐即视为对齐',
      );
      expect(d.portAlignMeanDy, 0.0);
    });

    test('层级平移计入几何坐标', () {
      final from = _pin('o', const Offset(0, 0), dir: NetlistPortDir.output);
      final load = _pin('i', const Offset(100, 0));
      final w = _wire(from, [load]);
      final d = _diagnose([
        _level([], [w], offset: const Offset(1000, 500)),
      ]);
      expect(d.wireCount, 1);
      expect(d.length, closeTo(100, 0.01));
      // 平移后仍在 200×200 画布之外，但直线预览不做合法性检查。
      expect(d.violations, isEmpty);
    });
  });

  group('正交布线', () {
    test('横竖交叉 + L 形折弯', () {
      final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
      final b = _pin('b', const Offset(50, 0), dir: NetlistPortDir.output);
      final wa = _wire(a, [_pin('la', const Offset(100, 50))], label: 'a');
      final wb = _wire(b, [_pin('lb', const Offset(50, 100))], label: 'b');
      final d = _diagnose(
        [
          _level([], [wa, wb]),
        ],
        routes: {
          wa: const [(Offset(0, 50), Offset(100, 50))],
          wb: const [(Offset(50, 0), Offset(50, 100))],
        },
      );

      expect(d.source, 'routed');
      expect(d.crossings, 1);
      expect(d.bends, 0);
      expect(d.length, closeTo(200, 0.01));
      expect(d.detour, closeTo(1, 0.01));
    });

    test('分支点不计折弯，共线直段不折弯', () {
      final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
      final l1 = _pin('l1', const Offset(100, 50));
      final l2 = _pin('l2', const Offset(100, 100));
      final w = _wire(a, [l1, l2], label: 't');
      final routes = {
        w: const [
          (Offset(0, 50), Offset(100, 50)),
          (Offset(100, 50), Offset(100, 100)),
        ],
      };
      final d = _diagnose(
        [
          _level([], [w]),
        ],
        routes: routes,
        junctions: {w: const [Offset(100, 50)]},
      );
      // (100,50) 是 H/V 相接的分支点，按口径排除；没有其它拐角。
      expect(d.bends, 0);
      expect(d.wires.single.name, 't');
      expect(d.detour, closeTo(1, 0.01));
    });

    test('绕行比 = 长度 / HPWL', () {
      final a = _pin('a', const Offset(0, 0), dir: NetlistPortDir.output);
      final b = _pin('b', const Offset(100, 0));
      final w = _wire(a, [b]);
      final d = _diagnose(
        [
          _level([], [w]),
        ],
        routes: {
          w: const [
            (Offset(0, 0), Offset(0, 50)),
            (Offset(0, 50), Offset(100, 50)),
            (Offset(100, 50), Offset(100, 0)),
          ],
        },
      );
      expect(d.length, closeTo(200, 0.01));
      expect(d.hpwl, closeTo(100, 0.01));
      expect(d.detour, closeTo(2, 0.01));
    });

    test('折弯分布 P50/P95/max 按每网统计', () {
      final wires = <NlWire>[];
      final routes = <NlWire, List<(Offset, Offset)>>{};
      for (var i = 0; i < 3; i++) {
        // 目标：0 / 2 / 4 折弯。
        final from = _pin('a$i', Offset(0, i * 30.0), dir: NetlistPortDir.output);
        final loadY = i == 0 ? 0.0 : (i == 1 ? 50.0 : 60.0);
        final load = _pin('l$i', Offset(100, loadY));
        final w = _wire(from, [load], label: 'w$i');
        wires.add(w);
        final y = i * 30.0;
        routes[w] = switch (i) {
          0 => [(Offset(0, y), Offset(100, y))],
          1 => [
            (Offset(0, y), Offset(50, y)),
            (Offset(50, y), Offset(50, 50)),
            (Offset(50, 50), Offset(100, 50)),
          ],
          _ => [
            (Offset(0, y), Offset(20, y)),
            (Offset(20, y), Offset(20, y + 10)),
            (Offset(20, y + 10), Offset(40, y + 10)),
            (Offset(40, y + 10), Offset(40, y)),
            (Offset(40, y), Offset(100, y)),
          ],
        };
      }
      final d = _diagnose(
        [
          _level([], wires),
        ],
        routes: routes,
      );
      expect(d.bends, 2 + 4);
      expect(d.bendMax, 4);
      expect(d.bendP50, 2);
      expect(d.bendMean, closeTo(2, 0.01));
    });
  });

  group('硬约束', () {
    test('异网同轴重叠计 netOverlap', () {
      final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
      final b = _pin('b', const Offset(20, 50), dir: NetlistPortDir.output);
      final wa = _wire(a, [_pin('la', const Offset(100, 50))]);
      final wb = _wire(b, [_pin('lb', const Offset(80, 50))]);
      final d = _diagnose(
        [
          _level([], [wa, wb]),
        ],
        routes: {
          wa: const [(Offset(0, 50), Offset(100, 50))],
          wb: const [(Offset(20, 50), Offset(80, 50))],
        },
      );
      expect(d.legal, isFalse);
      expect(d.violationCounts['netOverlap'], 1);
      expect(d.violations.single.detail, contains('60'));
    });

    test('平行间距不足计 spacing，正常间距不计', () {
      NlRoutingDiagnostics run(double gap) {
        final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
        final b = _pin('b', Offset(0, 50 + gap), dir: NetlistPortDir.output);
        final wa = _wire(a, [_pin('la', const Offset(100, 50))]);
        final wb = _wire(b, [_pin('lb', Offset(100, 50 + gap))]);
        return _diagnose(
          [
            _level([], [wa, wb]),
          ],
          routes: {
            wa: [(Offset(0, 50), Offset(100, 50))],
            wb: [(Offset(0, 50 + gap), Offset(100, 50 + gap))],
          },
        );
      }

      expect(run(8).violationCounts['spacing'], 1);
      expect(run(8).parallelPairs, 1, reason: '8px 间距的平行段应计入贴近段');
      expect(run(20).violations, isEmpty);
      expect(run(20).parallelPairs, 1, reason: '20px 合法但仍属视觉贴近（<3 Grid）');
      expect(run(50).parallelPairs, 0, reason: '超过 3 Grid 不再计入贴近段');
    });

    test('穿元件符号区计 throughBlock', () {
      final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
      final w = _wire(a, [_pin('l', const Offset(100, 50))]);
      final d = _diagnose(
        [
          _level([_block('u1', const Rect.fromLTWH(40, 40, 20, 20))], [w]),
        ],
        routes: {
          w: const [(Offset(0, 50), Offset(100, 50))],
        },
      );
      expect(d.violationCounts['throughBlock'], 1);
      expect(d.violations.single.detail, contains('u1'));
    });

    test('引脚没有端点连接计 danglingEnd', () {
      final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
      final w = _wire(a, [_pin('l', const Offset(100, 50))]);
      final d = _diagnose(
        [
          _level([], [w]),
        ],
        routes: {
          w: const [(Offset(10, 50), Offset(100, 50))],
        },
      );
      expect(d.violationCounts['danglingEnd'], 1);
    });

    test('端点越出画布计 outsideCanvas', () {
      final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
      final w = _wire(a, [_pin('l', const Offset(300, 50))]);
      final d = _diagnose(
        [
          _level([], [w]),
        ],
        routes: {
          w: const [(Offset(0, 50), Offset(300, 50))],
        },
      );
      expect(d.violationCounts['outsideCanvas'], 1);
    });
  });

  group('报告与叠加层', () {
    test('toJson 结构稳定、数值取 3 位小数', () {
      final a = _pin('a', const Offset(0, 0), dir: NetlistPortDir.output);
      final w = _wire(a, [_pin('l', const Offset(100, 0))], label: 'n1');
      final d = _diagnose(
        [
          _level([], [w]),
        ],
        routes: {
          w: const [
            (Offset(0, 0), Offset(33.333333, 0)),
            (Offset(33.333333, 0), Offset(100, 0)),
          ],
        },
      );
      final json = jsonEncode(d.toJson());
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['source'], 'routed');
      expect(decoded['wireCount'], 1);
      expect(decoded['length'], 100.0);
      expect(decoded['wires'], hasLength(1));
      expect((decoded['wires'] as List).single['detour'], closeTo(1, 1e-6));
      expect(decoded['violations'], isA<Map<String, dynamic>>());
    });

    test('叠加层标记交叉点/长尾网/高密度格', () {
      final a = _pin('a', const Offset(0, 50), dir: NetlistPortDir.output);
      final b = _pin('b', const Offset(50, 0), dir: NetlistPortDir.output);
      final wa = _wire(a, [_pin('la', const Offset(100, 50))]);
      final wb = _wire(b, [_pin('lb', const Offset(50, 100))]);
      final d = _diagnose(
        [
          _level([], [wa, wb]),
        ],
        routes: {
          wa: const [(Offset(0, 50), Offset(100, 50))],
          wb: const [(Offset(50, 0), Offset(50, 100))],
        },
      );
      final svg = buildNlDiagnosticOverlaySvg(d, bendThreshold: 0);
      expect(svg, contains('id="nl-diagnostics"'));
      expect(svg, contains('<circle'));
      expect(svg, contains('stroke="#FF5555"'));
    });
  });

  group('真实网表', () {
    test('39 网表：直线诊断与 nlStraightLength 同口径', () {
      final file = File(
        'scratch/ip_sch/isp_ip_eq6_axis/net.json',
      );
      if (!file.existsSync()) {
        markTestSkipped('缺少 ${file.path}');
        return;
      }
      final netlist = YosysNetlist.parse(file.readAsStringSync());
      final module = netlist.modules.values.firstWhere(
        (m) => m.cells.length > 5,
        orElse: () => netlist.modules.values.first,
      );
      final model = buildNetlistDiagramModel(module);
      final levels = model.flattened();
      final straight = computeNlRoutingDiagnostics(
        levels,
        model.canvasSize,
        topology: NlNetTopology.clique,
        options: const NlMetricsOptions(checkLegality: false),
      );

      expect(straight.source, 'straight');
      expect(straight.wireCount, greaterThan(0));
      expect(straight.wireCount, lessThanOrEqualTo(model.wires.length));
      expect(straight.length, closeTo(nlStraightLength(model), 1));
      expect(straight.detour, isNull);
      expect(straight.crossings, greaterThanOrEqualTo(0));
      expect(straight.violations, isEmpty, reason: '直线预览不做硬约束判定');
      final json = jsonEncode(straight.toJson());
      expect(json.length, greaterThan(100));
    });
  });
}
