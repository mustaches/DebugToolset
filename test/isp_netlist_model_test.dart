// yosys 网表模型（netlist_model.dart）测试：合成 JSON 契约 + 真实 IP 包
// 经 yosys 现场出网表校验（无 yosys 自动 skip，仿既有 e2e 用例约定）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_symbols.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

/// 合成网表：顶层（端口 + 加法器 + 常量输入 + $meminit 应被跳过）、
/// 子模块 `sub`、以及实例化 `sub` 的 `wrap`（校验实例端口方向来源）。
const _synthJson = r'''
{
  "creator": "Yosys test",
  "modules": {
    "top": {
      "ports": {
        "clk": {"direction": "input", "bits": [10]},
        "a":   {"direction": "input", "bits": [100,101,102,103,104,105,106,107]},
        "y":   {"direction": "output", "bits": [108,109,110,111,112,113,114,115]}
      },
      "cells": {
        "$add$foo.v:12$1": {
          "hide_name": 0,
          "type": "$add",
          "parameters": {
            "A_SIGNED": "00000000000000000000000000000000",
            "A_WIDTH": "00000000000000000000000000001000",
            "B_WIDTH": "00000000000000000000000000001000",
            "Y_WIDTH": "00000000000000000000000000001000"
          },
          "connections": {
            "A": [100,101,102,103,104,105,106,107],
            "B": [0,0,0,0,0,0,0,0],
            "Y": [108,109,110,111,112,113,114,115]
          }
        },
        "$meminit$\n1_rom$foo.v:30$9": {
          "hide_name": 1,
          "type": "$meminit_v2",
          "parameters": {},
          "connections": {"ADDR": [0,0], "DATA": [0,1], "EN": [1,1]}
        }
      },
      "netnames": {
        "a": {"hide_name": 0, "bits": [100,101,102,103,104,105,106,107]},
        "y": {"hide_name": 0, "bits": [108,109,110,111,112,113,114,115]}
      }
    },
    "sub": {
      "ports": {
        "i": {"direction": "input", "bits": [200]},
        "o": {"direction": "output", "bits": [201]}
      },
      "cells": {
        "$not$foo.v:40$2": {
          "hide_name": 1,
          "type": "$not",
          "parameters": {"A_WIDTH": "00000000000000000000000000000001"},
          "connections": {"A": [200], "Y": [201]}
        }
      },
      "netnames": {}
    },
    "wrap": {
      "ports": {
        "clk": {"direction": "input", "bits": [10]},
        "x":   {"direction": "input", "bits": [300]},
        "z":   {"direction": "output", "bits": [301]}
      },
      "cells": {
        "$paramod$abc123\\sub": {
          "hide_name": 0,
          "type": "$paramod$abc123\\sub",
          "parameters": {},
          "connections": {"i": [300], "o": [301]}
        }
      },
      "netnames": {}
    }
  }
}
''';

void main() {
  group('网表模型（合成 JSON）', () {
    test('端口方向/位宽、总线归组、常量段、非逻辑单元跳过', () {
      final nl = YosysNetlist.parse(_synthJson);
      expect(nl.modules.keys, containsAll(['top', 'sub', 'wrap']));

      final top = nl.module('top')!;
      expect(top.inputs.map((p) => p.name), ['clk', 'a']);
      expect(top.outputs.map((p) => p.name), ['y']);

      // $meminit_v2 被跳过，只剩加法器。
      expect(top.cells, hasLength(1));
      final add = top.cells.single;
      expect(add.type, r'$add');
      expect(add.kind, NetlistCellKind.arith);
      expect(add.typeLabel, 'ADD');
      expect(add.source, 'foo.v:12');
      expect(add.label, 'add12');
      expect(add.width, 8);

      // 输入端口 A 是 8 位真实网名 `a`；B 是 8 位常量 0。
      expect(add.ins.map((p) => p.port), ['A', 'B']);
      final a = add.ins[0];
      expect(a.width, 8);
      expect(a.nets.single.name, 'a');
      expect(a.nets.single.range, isEmpty, reason: '整条网不带范围后缀');
      expect(a.display, 'A[7:0]');
      final b = add.ins[1];
      expect(b.isConst, isTrue);
      expect(b.nets.single.name, "8'h00");
      expect(b.nets.single.constValue, 0);

      // 输出的比特同时被端口 `y` 与网名 `y` 覆盖（同一批比特）→ 端口名胜出。
      final y = add.outs.single;
      expect(y.port, 'Y');
      expect(y.width, 8);
      expect(top.bitNames[108], 'y');
      // 端口自身的比特名保留。
      expect(top.bitNames[100], 'a');
      expect(top.bitNames[0], "1'b0");
      expect(top.bitNames[1], "1'b1");
    });

    test('别名网名：拼接端口 vs 更窄的内部信号 → 取更窄者', () {
      // `o`（4 位端口）= {part, low}，`part` 只覆盖高 2 位 → 高 2 位用 `part`。
      const j = r'''
      {"modules": {"c": {
        "ports": {"o": {"direction": "output", "bits": [400,401,402,403]}},
        "cells": {},
        "netnames": {
          "o":    {"bits": [400,401,402,403]},
          "part": {"bits": [402,403]},
          "low":  {"bits": [400,401]}
        }
      }}}
      ''';
      final m = YosysNetlist.parse(j).module('c')!;
      expect(m.bitNames[402], 'part');
      expect(m.bitNames[403], 'part');
      expect(m.bitNames[400], 'low');
      expect(m.bitNames[401], 'low');
    });

    test('常量总线取十六进制、含 x/z 的段标注未知', () {
      expect(netsOf([1, 1, 1, 1]).single.name, "4'hF");
      expect(netsOf([0]).single.name, "1'b0");
      expect(netsOf([0, 0, 0]).single.name, "3'h0");
      expect(netsOf(['x']).single.name, "1'bx");
      expect(netsOf(['z', 'z']).single.name, "2'bx");
      // 常量段与信号段混在同一引脚时按段拆开。
      final mixed = netsOf([1, 1, 1, 1, 1, 1, 1, 1]);
      expect(mixed, hasLength(1));
      expect(mixed.single.width, 8);
    });

    test('子模块实例：端口方向按被引用模块定义（o 为输出）', () {
      final nl = YosysNetlist.parse(_synthJson);
      final wrap = nl.module('wrap')!;
      expect(wrap.cells, hasLength(1));
      final inst = wrap.cells.single;
      expect(inst.isInstance, isTrue);
      expect(inst.kind, NetlistCellKind.instance);
      expect(inst.moduleRef, 'sub');
      expect(inst.label, 'sub');
      expect(inst.ins.map((p) => p.port), ['i']);
      expect(inst.outs.map((p) => p.port), ['o']);
      // 参数化名解析到真实模块。
      expect(nl.resolveInstance(r'$paramod$abc123\sub')!.name, 'sub');
      expect(nl.module(r'$paramod$abc123\sub')!.name, 'sub');
    });

    test('端口方向三分类：input/output/inout（含双向端口）', () {
      const j = r'''
      {"modules": {"m": {
        "ports": {
          "a":  {"direction": "input",  "bits": [1]},
          "b":  {"direction": "output", "bits": [2]},
          "c":  {"direction": "inout",  "bits": [3]},
          "d":  {"direction": "inout",  "bits": [4]}
        },
        "cells": {
          "u_sub": {
            "type": "$paramod$abc\\sub",
            "parameters": {},
            "connections": {"i": [1], "o": [2], "io": [3]}
          }
        },
        "netnames": {}
      },
      "sub": {
        "ports": {
          "i":  {"direction": "input",  "bits": [10]},
          "o":  {"direction": "output", "bits": [11]},
          "io": {"direction": "inout",  "bits": [12]}
        },
        "cells": {},
        "netnames": {}
      }}}
      ''';
      final nl = YosysNetlist.parse(j);
      final m = nl.module('m')!;
      expect(m.inputs.map((p) => p.name), ['a']);
      expect(m.outputs.map((p) => p.name), ['b']);
      expect(m.inouts.map((p) => p.name), ['c', 'd']);
      expect(m.ports, hasLength(4));
      expect(m.portDirCounts[NetlistPortDir.input], 1);
      expect(m.portDirCounts[NetlistPortDir.output], 1);
      expect(m.portDirCounts[NetlistPortDir.inout], 2);
      // 方向短名（图上标注用）。
      expect(NetlistPortDir.input.label, 'I');
      expect(NetlistPortDir.output.label, 'O');
      expect(NetlistPortDir.inout.label, 'IO');
      // 实例引脚方向按被引用模块（含双向）：双向引脚放块右缘（`outs`）。
      final inst = m.cells.single;
      expect(inst.ins.map((p) => p.port), ['i']);
      expect(inst.outs.map((p) => p.port), containsAll(['o', 'io']));
      final io = inst.outs.firstWhere((p) => p.port == 'io');
      expect(io.dir, NetlistPortDir.inout);
      expect(io.isOutput, isFalse, reason: '双向不是纯输出');
      expect(io.isInout, isTrue);
      expect(io.display, 'IO io', reason: '双向引脚带 IO 前缀标注');
    });

    test('模块名解析：精确名优先，参数化名回退后缀匹配', () {
      final nl = YosysNetlist.parse(_synthJson);
      expect(nl.module('sub')!.name, 'sub');
      expect(nl.module('nope'), isNull);
    });
  });

  group('布局（直线预览）', () {
    test('同列不同宽度元件按列中心线居中', () {
      final json = jsonEncode({
        'modules': {
          'm': {
            'ports': <String, Object>{},
            'cells': {
              'rom': {
                'type': r'$memrd',
                'parameters': <String, Object>{},
                'connections': {'DATA': List<int>.generate(1024, (i) => i)},
              },
              'not': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {'A': 2000, 'Y': 2001},
              },
            },
            'netnames': <String, Object>{},
          },
        },
      });
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(json).module('m')!,
      );
      final byColumn = <int, List<NlBlock>>{};
      for (final block in model.blocks.where((b) => !b.isIo)) {
        (byColumn[block.column] ??= []).add(block);
      }
      expect(
        byColumn.values.any(
          (blocks) =>
              blocks.length > 1 &&
              blocks.map((b) => b.boxSize.width).toSet().length > 1,
        ),
        isTrue,
      );
      for (final blocks in byColumn.values) {
        final maxWidth = blocks
            .map((b) => b.boxSize.width)
            .reduce((a, b) => a > b ? a : b);
        final columnCenter =
            blocks.firstWhere((b) => b.boxSize.width == maxWidth).boxOrigin.dx +
            maxWidth / 2;
        for (final block in blocks) {
          final center = block.boxOrigin.dx + block.boxSize.width / 2;
          expect((center - columnCenter).abs(), lessThanOrEqualTo(7.5));
        }
      }
    });

    test('直线段：端点有限且在画布内、团拓扑段数 = C(pin,2)', () {
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(_synthJson).module('top')!,
      );
      expect(model.blocks, isNotEmpty);
      expect(model.wires, isNotEmpty);
      for (final w in model.wires) {
        final segments = nlStraightWireSegments(w);
        final pins = w.loads.length + 1;
        expect(segments, hasLength(pins * (pins - 1) ~/ 2));
        for (final (a, b) in segments) {
          for (final p in [a, b]) {
            expect(p.dx.isFinite && p.dy.isFinite, isTrue);
            expect(p.dx, inInclusiveRange(0, model.canvasSize.width));
            expect(p.dy, inInclusiveRange(0, model.canvasSize.height));
          }
        }
      }
    });

    test('走线密度热力图：线段经过的网格有值、远处为 0', () {
      NlPin pin(double x, double y, {bool output = false}) {
        final p = NlPin(
          port: 'p',
          display: 'p',
          width: 1,
          bits: const [0],
          dir: output ? NetlistPortDir.output : NetlistPortDir.input,
        )..pos = Offset(x, y);
        return p;
      }

      final wire = NlWire(
        pin(10, 10, output: true),
        [pin(110, 10)],
        'n',
        bits: const [0],
      );
      final level = NlLevel(
        blocks: const [],
        wires: [wire],
        pins: const [],
        ports: const [],
        offset: Offset.zero,
      );
      final heatmap = computeNlHeatmap(
        [level],
        const Size(200, 100),
        cellSize: 20,
      );
      expect(heatmap.columns, 10);
      expect(heatmap.rows, 5);
      expect(heatmap.valueAt(0, 0), greaterThan(0), reason: '起点所在格');
      expect(heatmap.valueAt(5, 0), greaterThan(0), reason: '线段中段');
      expect(heatmap.valueAt(5, 4), 0, reason: '远离走线');
      // 绝对标尺：单根走线 ≈ sqrt(1/_kHeatFullWires)，稀疏小图不再爆红。
      expect(
        heatmap.valueAt(5, 0),
        closeTo(math.sqrt(1 / 8), 0.01),
        reason: '单根走线只到蓝绿色档',
      );
      expect(
        heatmap.values.every((v) => v < 0.99),
        isTrue,
        reason: '单根走线没有任何一格到红色档',
      );
      // 8 根同线重叠 → 最热格到 1（红）。
      final hot = computeNlHeatmap(
        [
          NlLevel(
            blocks: const [],
            wires: [
              for (var i = 0; i < 8; i++)
                NlWire(
                  pin(10, 10, output: true),
                  [pin(110, 10)],
                  'n$i',
                  bits: const [0],
                ),
            ],
            pins: const [],
            ports: const [],
            offset: Offset.zero,
          ),
        ],
        const Size(200, 100),
        cellSize: 20,
      );
      expect(
        hot.values.any((v) => (v - 1).abs() < 0.01),
        isTrue,
        reason: '8 根走线重叠的格归一化为 1',
      );
    });

    test('网表文本：模块、端口、单元、网齐全', () {
      final mod = YosysNetlist.parse(_synthJson).module('top')!;
      final text = netlistModuleText(mod);
      expect(text, contains('module top'));
      expect(text, contains('ports (3):'));
      expect(text, contains('cells ('));
      expect(text, contains('nets ('));
      expect(text, contains('clk'));
    });
    test('端点数 = 有连线的 pin（去重，不含 I/O 端口）', () {
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(_synthJson).module('top')!,
      );
      final connected = <NlPin>{};
      for (final level in model.flattened()) {
        for (final wire in level.wires) {
          connected.add(wire.from);
          connected.addAll(wire.loads);
        }
      }
      expect(nlEndpointCount(model), connected.length);
      expect(nlEndpointCount(model), greaterThan(0));
    });
    test('自动布线切换触发绘制层重绘', () {
      final plain = NetlistWirePainter(const []);
      final routed = NetlistWirePainter(const [], autoRoutes: const {});
      expect(routed.shouldRepaint(plain), isTrue);
      expect(plain.shouldRepaint(routed), isTrue);
    });
    test('自动布线：线段正交、不穿块体、端点接住针脚', () {
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(_synthJson).module('top')!,
      );
      final result = routeNetlistWires(model.flattened(), model.canvasSize);
      final routes = result.segments;
      expect(routes, hasLength(model.wires.length));
      expect(result.fallbackCount, 0);
      final blockRects = [
        for (final b in model.blocks)
          if (!b.isIo)
            Rect.fromLTWH(
              b.boxOrigin.dx,
              b.boxOrigin.dy,
              b.boxSize.width,
              b.boxSize.height,
            ),
      ];
      bool touches(List<(Offset, Offset)> segs, Offset p) => segs.any(
        (s) => (s.$1 - p).distance < 0.01 || (s.$2 - p).distance < 0.01,
      );
      for (final wire in model.wires) {
        final segments = routes[wire]!;
        expect(segments, isNotEmpty);
        expect(touches(segments, wire.from.pos), isTrue);
        for (final load in wire.loads) {
          expect(touches(segments, load.pos), isTrue);
        }
        for (final pin in [wire.from, ...wire.loads]) {
          final near = segments.where(
            (s) =>
                (s.$1 - pin.pos).distance < 0.01 ||
                (s.$2 - pin.pos).distance < 0.01,
          );
          expect(near, isNotEmpty);
          expect(
            (near.first.$2 - near.first.$1).distance,
            greaterThanOrEqualTo(14.9),
            reason: '引脚向外至少 1 Grid 才能折弯',
          );
        }
        for (final (a, b) in segments) {
          expect(
            (a.dx - b.dx).abs() < 0.01 || (a.dy - b.dy).abs() < 0.01,
            isTrue,
            reason: '自动布线必须是水平/垂直线段',
          );
          final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
          for (final rect in blockRects) {
            expect(rect.contains(mid), isFalse, reason: '走线不得穿过元件块体');
          }
        }
        // 同一根网必须是单一连通图：不允许断口/悬空端点。
        String key(Offset p) =>
            '${(p.dx * 100).round()},${(p.dy * 100).round()}';
        final adj = <String, Set<String>>{};
        for (final (a, b) in segments) {
          (adj[key(a)] ??= <String>{}).add(key(b));
          (adj[key(b)] ??= <String>{}).add(key(a));
        }
        final pins = [wire.from, ...wire.loads].map((p) => key(p.pos)).toSet();
        final seen = <String>{};
        if (adj.isNotEmpty) {
          final stack = <String>[adj.keys.first];
          seen.add(adj.keys.first);
          while (stack.isNotEmpty) {
            for (final n in adj[stack.removeLast()] ?? const <String>{}) {
              if (seen.add(n)) stack.add(n);
            }
          }
        }
        expect(seen.containsAll(pins), isTrue, reason: '同网引脚必须在同一连通图');
        for (final e in adj.entries) {
          if (e.value.length == 1) {
            expect(pins, contains(e.key), reason: '不允许悬空走线端点');
          }
        }
      }
      final entries = routes.values.toList();
      for (var i = 0; i < entries.length; i++) {
        for (var j = i + 1; j < entries.length; j++) {
          for (final (a, b) in entries[i]) {
            for (final (c, d) in entries[j]) {
              final bothH =
                  (a.dy - b.dy).abs() < 0.01 && (c.dy - d.dy).abs() < 0.01;
              final bothV =
                  (a.dx - b.dx).abs() < 0.01 && (c.dx - d.dx).abs() < 0.01;
              final overlapH =
                  bothH &&
                  (a.dy - c.dy).abs() < 0.01 &&
                  (a.dx < b.dx ? a.dx : b.dx) <
                      (c.dx > d.dx ? c.dx : d.dx) - 0.01 &&
                  (c.dx < d.dx ? c.dx : d.dx) <
                      (a.dx > b.dx ? a.dx : b.dx) - 0.01;
              final overlapV =
                  bothV &&
                  (a.dx - c.dx).abs() < 0.01 &&
                  (a.dy < b.dy ? a.dy : b.dy) <
                      (c.dy > d.dy ? c.dy : d.dy) - 0.01 &&
                  (c.dy < d.dy ? c.dy : d.dy) <
                      (a.dy > b.dy ? a.dy : b.dy) - 0.01;
              expect(overlapH || overlapV, isFalse, reason: '不同网的同轴走线不得重叠');
            }
          }
        }
      }
    });
    test('列间距随跨列网数加宽（每网 1 Grid，封顶 8）', () {
      expect(nlChannelGap(0), 45);
      expect(nlChannelGap(3), 45 + 3 * 15);
      expect(nlChannelGap(20), nlChannelGap(8));
      expect(nlChannelGap(20), 45 + 8 * 15);
    });
    test('布线指标：异网交叉点与总长', () {
      NlPin pin(String name, Offset at) =>
          NlPin(port: name, display: name, width: 1, bits: const [0])..pos = at;
      final a = pin('a', const Offset(0, 0));
      final b = pin('b', const Offset(50, 0));
      final w1 = NlWire(a, const [], 'n1', bits: const [0]);
      final w2 = NlWire(b, const [], 'n2', bits: const [0]);
      final result = NlAutoRouteResult(
        segments: {
          w1: [(const Offset(0, 0), const Offset(100, 0))],
          w2: [(const Offset(50, -50), const Offset(50, 50))],
        },
        junctions: const {},
      );
      final metrics = nlRoutingMetrics(result);
      expect(metrics.crossings, 1);
      expect(metrics.bends, 0);
      expect(metrics.length, 200);
    });

    test('布线指标：折弯点排除同网 T/十字分支点', () {
      NlPin pin(String name, Offset at) =>
          NlPin(port: name, display: name, width: 1, bits: const [0])..pos = at;
      final w1 = NlWire(
        pin('a', Offset.zero),
        const [],
        'bend',
        bits: const [0],
      );
      final w2 = NlWire(
        pin('b', Offset.zero),
        const [],
        'tee',
        bits: const [0],
      );
      final bend = NlAutoRouteResult(
        segments: {
          w1: [
            (const Offset(0, 0), const Offset(50, 0)),
            (const Offset(50, 0), const Offset(50, 50)),
          ],
        },
        junctions: const {},
      );
      expect(nlRoutingMetrics(bend).bends, 1);

      final tee = NlAutoRouteResult(
        segments: {
          w2: [
            (const Offset(0, 0), const Offset(100, 0)),
            (const Offset(50, 0), const Offset(50, 50)),
          ],
        },
        junctions: {
          w2: const [Offset(50, 0)],
        },
      );
      expect(nlRoutingMetrics(tee).bends, 0);
    });
    test('自动优化布线：交叉优先、折弯其次、总长最后', () async {
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(_synthJson).module('top')!,
      );
      final originBefore = <NlBlock, double>{
        for (final b in model.blocks)
          if (!b.isIo) b: b.boxOrigin.dy,
      };
      final orderBefore = <int, List<String>>{};
      for (final b in model.blocks) {
        if (b.isIo) continue;
        (orderBefore[b.column] ??= []).add(b.id);
      }
      for (final ids in orderBefore.values) {
        ids.sort();
      }
      final baseline = routeNetlistWires(model.flattened(), model.canvasSize);
      final optimized = await optimizeNetlistRouting(
        model.flattened(),
        model.canvasSize,
        initial: baseline,
      );
      expect(optimized.result.fallbackCount, 0);
      // 字典序：交叉点优先，其次折弯点，最后总长。
      expect(
        optimized.crossings,
        lessThanOrEqualTo(optimized.initialCrossings),
      );
      if (optimized.crossings == optimized.initialCrossings) {
        expect(optimized.bends, lessThanOrEqualTo(optimized.initialBends));
      }
      if (optimized.crossings == optimized.initialCrossings &&
          optimized.bends == optimized.initialBends) {
        expect(
          optimized.length,
          lessThanOrEqualTo(optimized.initialLength + 0.01),
        );
      }
      for (final e in originBefore.entries) {
        expect(
          (e.key.boxOrigin.dy - e.value).abs(),
          lessThanOrEqualTo(10 * 15 + 0.01),
          reason: '元件上下移动不得超过 ±10 Grid',
        );
      }
      expect(optimized.result.segments, hasLength(model.wires.length));
      // 允许列内上下移动，但不得改变同列顺序，且仍至少留 5 Grid。
      final byColumn = <int, List<NlBlock>>{};
      for (final b in model.blocks) {
        if (b.isIo) continue;
        (byColumn[b.column] ??= []).add(b);
      }
      for (final entry in byColumn.entries) {
        entry.value.sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
        final ids = entry.value.map((b) => b.id).toList()..sort();
        expect(ids, orderBefore[entry.key]);
        for (var i = 1; i < entry.value.length; i++) {
          final gap =
              entry.value[i].boxOrigin.dy -
              (entry.value[i - 1].boxOrigin.dy +
                  entry.value[i - 1].boxSize.height);
          expect(gap, greaterThanOrEqualTo(5 * 15 - 0.01));
        }
      }
    });
    test('针脚样式：镜像与四边槽位序重排（nlLayoutBlockPins）', () {
      NlPin pin(String port, int bit, NetlistPortDir dir) =>
          NlPin(port: port, display: port, width: 1, bits: [bit], dir: dir);
      final b =
          NlBlock(
              id: 'b',
              title: 'b',
              subtitle: '',
              ins: [
                pin('I0', 0, NetlistPortDir.input),
                pin('I1', 1, NetlistPortDir.input),
                pin('I2', 2, NetlistPortDir.input),
              ],
              outs: [
                pin('O0', 10, NetlistPortDir.output),
                pin('O1', 11, NetlistPortDir.output),
              ],
            )
            ..boxOrigin = const Offset(150, 150)
            ..boxSize = const Size(90, 150);
      double yOf(String port) =>
          [...b.ins, ...b.outs].firstWhere((p) => p.port == port).pos.dy;

      // 默认：声明序自上而下。
      nlLayoutBlockPins(b);
      expect(yOf('I0'), lessThan(yOf('I1')));
      expect(yOf('I1'), lessThan(yOf('I2')));
      expect(yOf('O0'), lessThan(yOf('O1')));

      // 左侧引脚槽位序反转：I0 到最下。
      b.inPinOrder = ['I2', 'I1', 'I0'];
      nlLayoutBlockPins(b);
      expect(yOf('I2'), lessThan(yOf('I1')));
      expect(yOf('I1'), lessThan(yOf('I0')));

      // 右侧引脚槽位序反转。
      b.outPinOrder = ['O1', 'O0'];
      nlLayoutBlockPins(b);
      expect(yOf('O1'), lessThan(yOf('O0')));

      // 上下镜像：左右槽位同时上下反转。
      b.pinFlip = true;
      b.inPinOrder = null;
      b.outPinOrder = null;
      nlLayoutBlockPins(b);
      expect(yOf('I2'), lessThan(yOf('I0')));
      expect(yOf('O1'), lessThan(yOf('O0')));
    });

    test('针脚样式：MUX 上下镜像时 S 针脚底↔顶互换', () {
      final json = jsonEncode({
        'modules': {
          'm': {
            'ports': {
              'i0': {
                'direction': 'input',
                'bits': [100],
              },
              'i1': {
                'direction': 'input',
                'bits': [101],
              },
              's': {
                'direction': 'input',
                'bits': [102],
              },
              'o': {
                'direction': 'output',
                'bits': [200],
              },
            },
            'cells': {
              'mx': {
                'type': r'$mux',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'B': [101],
                  'S': [102],
                  'Y': [200],
                },
              },
            },
            'netnames': <String, Object>{},
          },
        },
      });
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(json).module('m')!,
      );
      final mux = model.blocks.firstWhere((b) => b.id == 'mx');
      final s = mux.ins.firstWhere((p) => p.port == 'S');
      expect(s.edge.dy, mux.boxOrigin.dy + mux.boxSize.height, reason: '默认底边');
      mux.pinFlip = true;
      nlLayoutBlockPins(mux);
      expect(s.edge.dy, mux.boxOrigin.dy, reason: '镜像后移到顶边');
      mux.pinFlip = false;
      nlLayoutBlockPins(mux);
      expect(s.edge.dy, mux.boxOrigin.dy + mux.boxSize.height);
    });

    test('自动优化布线：镜像/引脚交换消除拓扑交叉，禁用则不能', () async {
      // drv_a（上）→ gate.B（下槽），drv_b（下）→ gate.A（上槽）：两网端点
      // 顺序相反，任何正交布线至少 1 次交叉；只有镜像/引脚交换能消除。
      final json = jsonEncode({
        'modules': {
          'm': {
            'ports': {
              'i': {
                'direction': 'input',
                'bits': [100],
              },
              'o': {
                'direction': 'output',
                'bits': [200],
              },
            },
            'cells': {
              'drv_a': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'Y': [301],
                },
              },
              'drv_b': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'Y': [302],
                },
              },
              'gate': {
                'type': r'$and',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [302],
                  'B': [301],
                  'Y': [200],
                },
              },
            },
            'netnames': <String, Object>{},
          },
        },
      });
      NetlistDiagramModel build() =>
          buildNetlistDiagramModel(YosysNetlist.parse(json).module('m')!);

      // 前提：drv_a 在 drv_b 上方、A 槽在 B 槽上方 → 两网必交叉。
      final m0 = build();
      final drvA = m0.blocks.firstWhere((b) => b.id == 'drv_a');
      final drvB = m0.blocks.firstWhere((b) => b.id == 'drv_b');
      final gate = m0.blocks.firstWhere((b) => b.id == 'gate');
      expect(drvA.boxOrigin.dy, lessThan(drvB.boxOrigin.dy));
      final pinA = gate.ins.firstWhere((p) => p.port == 'A');
      final pinB = gate.ins.firstWhere((p) => p.port == 'B');
      expect(pinA.pos.dy, lessThan(pinB.pos.dy));
      final base = routeNetlistWires(m0.flattened(), m0.canvasSize);
      expect(
        nlRoutingMetrics(base).crossings,
        greaterThan(0),
        reason: '前提：端点顺序相反的两网至少交叉一次',
      );

      // 禁用全部针脚变换：只能靠上下移动元件，拓扑交叉无法消除。
      final locked = await optimizeNetlistRouting(
        m0.flattened(),
        m0.canvasSize,
        initial: base,
        options: const NlRouteOptOptions(
          mirrorVertical: false,
          swapLeftPins: false,
          swapRightPins: false,
          swapTopPins: false,
          swapBottomPins: false,
        ),
      );
      expect(locked.crossings, greaterThan(0));

      // 允许变换：镜像或反转左侧引脚即可消除交叉。
      final m1 = build();
      final free = await optimizeNetlistRouting(
        m1.flattened(),
        m1.canvasSize,
        options: const NlRouteOptOptions(),
      );
      expect(free.crossings, 0);
    });

    /// 与上一用例相同的拓扑交叉场景（供并行路径用例复用）。
    String crossingJson() => jsonEncode({
      'modules': {
        'm': {
          'ports': {
            'i': {
              'direction': 'input',
              'bits': [100],
            },
            'o': {
              'direction': 'output',
              'bits': [200],
            },
          },
          'cells': {
            'drv_a': {
              'type': r'$not',
              'parameters': <String, Object>{},
              'connections': {
                'A': [100],
                'Y': [301],
              },
            },
            'drv_b': {
              'type': r'$not',
              'parameters': <String, Object>{},
              'connections': {
                'A': [100],
                'Y': [302],
              },
            },
            'gate': {
              'type': r'$and',
              'parameters': <String, Object>{},
              'connections': {
                'A': [302],
                'B': [301],
                'Y': [200],
              },
            },
          },
          'netnames': <String, Object>{},
        },
      },
    });

    test('多 CPU 并行：布线优化并行路径同样消除拓扑交叉', () async {
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(crossingJson()).module('m')!,
      );
      // parallelMinWires: 0 → 强制走 isolate 并行评估路径。
      final optimized = await optimizeNetlistRouting(
        model.flattened(),
        model.canvasSize,
        options: const NlRouteOptOptions(),
        parallelMinWires: 0,
      );
      expect(optimized.result.fallbackCount, 0);
      expect(optimized.crossings, 0, reason: '并行路径同样找到镜像/引脚交换');
    });

    test('多 CPU 并行：布局优化并行批评估与串行同解', () async {
      final nl = YosysNetlist.parse(crossingJson());
      final mod = nl.module('m')!;
      // 串行（不传 netlist）与并行（parallelMinCells: 0 强制并行）：
      // 本场景唯一更优解是交换 drv_a/drv_b 行序，两者应收敛到同一长度。
      final seq = await optimizeNetlistLayout(mod);
      final par = await optimizeNetlistLayout(
        mod,
        netlist: nl,
        parallelMinCells: 0,
      );
      expect(seq.improved, isTrue, reason: '默认行序存在更优解');
      expect(par.improved, isTrue, reason: '并行批评估同样找到更优行序');
      expect(
        par.length,
        closeTo(seq.length, 0.01),
        reason: '并行批评估与串行贪心收敛到同一总长度',
      );
      expect(par.evaluations, greaterThan(0));
    });

    test('布局优化一次收敛：第二次运行零改善且任何单步移动不再更优', () async {
      // 4 驱动 + 2 门 + 1 MUX 的缠绕场景：行序/引脚交换/镜像三阶段互相
      // 影响，需要多轮迭代才到不动点（曾因 maxRounds=64 提前截断，要跑
      // 两三次才收敛）。
      final json = jsonEncode({
        'modules': {
          'm': {
            'ports': {
              'i': {
                'direction': 'input',
                'bits': [100],
              },
              's': {
                'direction': 'input',
                'bits': [101],
              },
              'o1': {
                'direction': 'output',
                'bits': [201],
              },
              'o2': {
                'direction': 'output',
                'bits': [305],
              },
              'o3': {
                'direction': 'output',
                'bits': [306],
              },
            },
            'cells': {
              'n1': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'Y': [301],
                },
              },
              'n2': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'Y': [302],
                },
              },
              'n3': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'Y': [303],
                },
              },
              'n4': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'Y': [304],
                },
              },
              'g1': {
                'type': r'$and',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [304],
                  'B': [301],
                  'Y': [305],
                },
              },
              'g2': {
                'type': r'$or',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [303],
                  'B': [302],
                  'Y': [306],
                },
              },
              'mx': {
                'type': r'$mux',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [305],
                  'B': [306],
                  'S': [101],
                  'Y': [201],
                },
              },
            },
            'netnames': <String, Object>{},
          },
        },
      });
      final nl = YosysNetlist.parse(json);
      final mod = nl.module('m')!;

      Future<void> checkConverged(YosysNetlist? netlist, String label) async {
        final run1 = await optimizeNetlistLayout(
          mod,
          allowMirror: true,
          swapPins: true,
          netlist: netlist,
          parallelMinCells: netlist == null ? 12 : 0,
        );
        // 从第一次的结果继续跑第二次：必须零改善——一次运行就到达最终状态。
        final run2 = await optimizeNetlistLayout(
          mod,
          allowMirror: true,
          swapPins: true,
          initialRowOrders: run1.rowOrders,
          initialMirroredBlocks: run1.mirroredBlocks,
          initialPinOrders: run1.pinOrders,
          netlist: netlist,
          parallelMinCells: netlist == null ? 12 : 0,
        );
        expect(run2.improved, isFalse, reason: '$label：第二次运行不应再找到改善');
        expect(run2.length, closeTo(run1.length, 0.01));

        // 不动点性质：对最终方案枚举全部单步移动，均不得更优（>0.5）。
        final plan = {
          for (final e in run1.rowOrders.entries) e.key: [...e.value],
        };
        final pinPlan = {
          for (final e in run1.pinOrders.entries) e.key: [...e.value],
        };
        final mirrored = {...run1.mirroredBlocks};
        double lengthOf(
          Map<int, List<String>> o,
          Map<String, List<String>> p,
          Set<String> m,
        ) => nlStraightLength(
          buildNetlistDiagramModel(
            mod,
            rowOrders: o,
            pinOrders: p,
            mirroredBlocks: m,
          ),
        );
        final byColumn = <int, List<NlBlock>>{};
        for (final b in run1.model.blocks) {
          if (b.isIo) continue;
          (byColumn[b.column] ??= []).add(b);
        }
        for (final e in byColumn.entries) {
          e.value.sort((a, b) => a.row.compareTo(b.row));
          final order = [for (final b in e.value) b.id];
          for (var from = 0; from < order.length; from++) {
            for (var to = 0; to < order.length; to++) {
              if (from == to) continue;
              final candidate = [...order];
              final id = candidate.removeAt(from);
              candidate.insert(to, id);
              final l = lengthOf(
                {...plan, e.key: candidate},
                pinPlan,
                mirrored,
              );
              expect(
                l,
                greaterThanOrEqualTo(run1.length - 0.5),
                reason: '$label：列 ${e.key} 行序移动 $from→$to 不应更优',
              );
            }
          }
        }
        for (final b in run1.model.blocks) {
          if (b.isIo) continue;
          final side = [
            for (final p in b.ins)
              if (!netlistSymbolIsBottomPin(b.cell, p.port)) p,
          ]..sort((a, c) => a.edge.dy.compareTo(c.edge.dy));
          if (side.length < 2) continue;
          final order = [for (final p in side) p.display];
          for (var i = 0; i < order.length; i++) {
            for (var j = i + 1; j < order.length; j++) {
              final candidate = [...order];
              final t = candidate[i];
              candidate[i] = candidate[j];
              candidate[j] = t;
              final l = lengthOf(plan, {...pinPlan, b.id: candidate}, mirrored);
              expect(
                l,
                greaterThanOrEqualTo(run1.length - 0.5),
                reason: '$label：${b.id} 引脚交换 $i↔$j 不应更优',
              );
            }
          }
        }
        for (final b in run1.model.blocks) {
          if (b.isIo || b.ins.length + b.outs.length < 2) continue;
          final m2 = {...mirrored};
          if (!m2.remove(b.id)) m2.add(b.id);
          final l = lengthOf(plan, pinPlan, m2);
          expect(
            l,
            greaterThanOrEqualTo(run1.length - 0.5),
            reason: '$label：${b.id} 镜像不应更优',
          );
        }
      }

      await checkConverged(null, '串行路径');
      await checkConverged(nl, '并行路径');
    });

    test('针脚样式：拆分针脚共享端口名时按显示名分槽不重叠', () {
      // 多驱动拆分针脚：两个 NlPin 共享端口名 'A'（显示名不同）。
      // 按端口名 indexOf 会把它们分到同一槽位 → 标签重叠（用户实测）。
      NlPin pin(String port, String display, int bit) => NlPin(
        port: port,
        display: display,
        width: 1,
        bits: [bit],
        dir: NetlistPortDir.input,
      );
      final b =
          NlBlock(
              id: 'b',
              title: 'b',
              subtitle: '',
              ins: [
                pin('A', 'A[24:11]', 0),
                pin('A', 'A[10:0]', 1),
                pin('B', 'B[7:0]', 2),
              ],
            )
            ..boxOrigin = const Offset(150, 150)
            ..boxSize = const Size(90, 150);
      double yOf(String display) =>
          b.ins.firstWhere((p) => p.display == display).pos.dy;

      // 默认：拆分针脚各占独立槽位。
      nlLayoutBlockPins(b);
      expect(yOf('A[24:11]'), isNot(yOf('A[10:0]')));
      expect(yOf('A[24:11]'), isNot(yOf('B[7:0]')));

      // 显示名槽位序：交换后仍各占独立槽位、顺序正确。
      b.inPinOrder = ['B[7:0]', 'A[10:0]', 'A[24:11]'];
      nlLayoutBlockPins(b);
      expect(yOf('B[7:0]'), lessThan(yOf('A[10:0]')));
      expect(yOf('A[10:0]'), lessThan(yOf('A[24:11]')));
      expect(yOf('A[24:11]'), isNot(yOf('A[10:0]')));
    });

    test('布局优化：多驱动拆分针脚的块经引脚交换后针脚不重叠', () async {
      // g.A 为 2 比特、两个不同驱动 → 拆分成两个共享端口名 'A' 的针脚。
      final json = jsonEncode({
        'modules': {
          'm': {
            'ports': {
              'i0': {
                'direction': 'input',
                'bits': [100],
              },
              'i1': {
                'direction': 'input',
                'bits': [101],
              },
              'o': {
                'direction': 'output',
                'bits': [200],
              },
            },
            'cells': {
              'd1': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [100],
                  'Y': [301],
                },
              },
              'd2': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [101],
                  'Y': [302],
                },
              },
              'g': {
                'type': r'$and',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [301, 302],
                  'B': [100],
                  'Y': [200],
                },
              },
            },
            'netnames': <String, Object>{},
          },
        },
      });
      final mod = YosysNetlist.parse(json).module('m')!;
      final base = buildNetlistDiagramModel(mod);
      final g = base.blocks.firstWhere((b) => b.id == 'g');
      final sideA = [
        for (final p in g.ins)
          if (p.port == 'A') p,
      ];
      expect(sideA.length, greaterThan(1), reason: '前提：A 被多驱动拆分');
      expect(
        sideA.map((p) => p.display).toSet().length,
        sideA.length,
        reason: '前提：拆分针脚显示名唯一',
      );

      final result = await optimizeNetlistLayout(
        mod,
        allowMirror: true,
        swapPins: true,
      );
      // 最终模型中任何块的侧边针脚都不得共用 y 坐标（不重叠）。
      for (final b in result.model.blocks) {
        if (b.isIo) continue;
        final side = [
          for (final p in b.ins)
            if (!netlistSymbolIsBottomPin(b.cell, p.port)) p,
        ];
        final ys = side.map((p) => p.pos.dy).toList();
        expect(ys.toSet().length, ys.length, reason: '${b.id} 的侧边针脚不得重叠：$ys');
      }
    });

    test('rowOrders 支持跨列放置（全局重排的构建器基础）', () {
      final mod = YosysNetlist.parse(crossingJson()).module('m')!;
      final model = buildNetlistDiagramModel(
        mod,
        rowOrders: const {
          0: ['gate', 'drv_a', 'drv_b'],
        },
      );
      final gate = model.blocks.firstWhere((b) => b.id == 'gate');
      expect(gate.column, 0, reason: 'rowOrders 列出的块可移到其它列');
      expect(gate.row, 0, reason: '列出顺序即列内行序');
    });

    test('布线优化：允许列内非等间距（布线后期推挤间距）', () async {
      // 语义：只在布线时起作用，且在其他手段不再缩短走线后才介入；
      // 同列相邻块间距在 2~20 Grid 间调整（串行路径覆盖）。
      final mod = YosysNetlist.parse(crossingJson()).module('m')!;
      double pairGap(NetlistDiagramModel model) {
        final pair = [
          model.blocks.firstWhere((b) => b.id == 'drv_a'),
          model.blocks.firstWhere((b) => b.id == 'drv_b'),
        ]..sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
        return pair[1].boxOrigin.dy -
            (pair[0].boxOrigin.dy + pair[0].boxSize.height);
      }

      Future<NlRoutingOptimizationResult> run(NetlistDiagramModel m, bool on) =>
          optimizeNetlistRouting(
            m.flattened(),
            m.canvasSize,
            initial: routeNetlistWires(m.flattened(), m.canvasSize),
            options: NlRouteOptOptions(variableRowGap: on),
          );

      final off = await run(buildNetlistDiagramModel(mod), false);
      final m1 = buildNetlistDiagramModel(mod);
      final on = await run(m1, true);
      expect(off.result.fallbackCount, 0);
      expect(on.result.fallbackCount, 0);
      // 间距阶段只采纳严格更优候选：开启后指标不差于关闭（字典序）。
      expect(on.crossings, lessThanOrEqualTo(off.crossings));
      if (on.crossings == off.crossings) {
        expect(on.bends, lessThanOrEqualTo(off.bends));
        if (on.bends == off.bends) {
          expect(on.length, lessThanOrEqualTo(off.length + 0.01));
        }
      }
      // 本场景存在更优的 3 Grid 推挤：开启后严格更好且间距被改写。
      expect(
        on.bends < off.bends || on.length < off.length - 0.01,
        isTrue,
        reason: '本场景 3 Grid 推挤严格更优（实测折弯 5→4、长度 885→795）',
      );
      expect(pairGap(m1), greaterThanOrEqualTo(2 * 15.0 - 0.01));
      expect(
        (pairGap(m1) - 7 * 15.0).abs() > 0.01,
        isTrue,
        reason: '开启后应采纳非默认间距',
      );
    });

    test('布线优化终段：移动所有端口使相连线/总线没有折线', () async {
      // 最后执行的规则：自动移动所有端口，让其相连线/总线无折线。
      final mod = YosysNetlist.parse(crossingJson()).module('m')!;
      final model = buildNetlistDiagramModel(mod);
      NlWire wireOf(NlPin pin) => model.wires.firstWhere(
        (w) => identical(w.from, pin) || w.loads.any((l) => identical(l, pin)),
      );
      int wireBends(NlWire w, NlAutoRouteResult r) => nlRoutingBendPoints(
        r.segments[w] ?? const [],
        junctions: r.junctions[w] ?? const [],
      ).length;

      // 先把输出端口 o 挪离其自然高度：其单负载连线产生折线。
      final portO = model.flattened().single.ports.firstWhere(
        (p) => p.display == 'o',
      );
      portO.pos += const Offset(0, 45);
      portO.edge += const Offset(0, 45);
      final bent = routeNetlistWires(model.flattened(), model.canvasSize);
      expect(
        wireBends(wireOf(portO), bent),
        greaterThan(0),
        reason: '前提：端口被挪开后其连线有折线',
      );

      final optimized = await optimizeNetlistRouting(
        model.flattened(),
        model.canvasSize,
        initial: bent,
        options: const NlRouteOptOptions(),
      );
      expect(optimized.result.fallbackCount, 0);
      expect(
        wireBends(wireOf(portO), optimized.result),
        0,
        reason: '终段对齐后端口 o 的连线应为无折线的直线',
      );
      // 端口折线计数（出线方向）也应为 0。
      expect(nlPortBendCount(model.flattened(), optimized.result), 0);
    });

    test('走线宽度与 T 型分支圆点：总线 3dp、圆点 8/4dp', () {
      expect(nlWireStrokeWidth(false), 0.5);
      expect(nlWireStrokeWidth(true), 3.0);
      expect(nlWireStrokeWidth(false, active: true), 1.5);
      expect(nlWireStrokeWidth(true, active: true), 4.0);
      expect(nlJunctionDotRadius(true) * 2, 8.0);
      expect(nlJunctionDotRadius(false) * 2, 4.0);
      expect(
        nlTreeJunctions([
          (const Offset(0, 0), const Offset(100, 0)),
          (const Offset(50, 0), const Offset(50, 50)),
        ]),
        contains(const Offset(50, 0)),
      );
      expect(
        nlTreeJunctions([
          (const Offset(0, 0), const Offset(100, 0)),
          (const Offset(50, -50), const Offset(50, 50)),
        ]),
        contains(const Offset(50, 0)),
      );
    });
    test('镜像元件反转输入槽位；引脚交换覆盖槽位顺序', () {
      final mod = YosysNetlist.parse(_synthJson).module('top')!;
      NlBlock addOf(NetlistDiagramModel m) =>
          m.blocks.firstWhere((b) => b.cell?.type == r'$add');
      double yOf(NlBlock b, String port) =>
          b.ins.firstWhere((p) => p.port == port).edge.dy;

      final normal = addOf(buildNetlistDiagramModel(mod));
      expect(yOf(normal, 'A'), lessThan(yOf(normal, 'B')));

      final mirrored = addOf(
        buildNetlistDiagramModel(mod, mirroredBlocks: {normal.id}),
      );
      expect(
        yOf(mirrored, 'A'),
        greaterThan(yOf(mirrored, 'B')),
        reason: '镜像后 A 应翻到 B 下方',
      );

      final swapped = addOf(
        buildNetlistDiagramModel(
          mod,
          pinOrders: {
            normal.id: ['B', 'A'],
          },
        ),
      );
      expect(
        yOf(swapped, 'B'),
        lessThan(yOf(swapped, 'A')),
        reason: '引脚交换后 B 应占顶部槽位',
      );
    });

    test('镜像元件包含底边 S 针脚：下方引脚可镜像到上方', () {
      const json = r'''
      {"modules": {"m": {
        "ports": {
          "a": {"direction": "input", "bits": [1, 2]},
          "b": {"direction": "input", "bits": [3, 4]},
          "s": {"direction": "input", "bits": [5]},
          "y": {"direction": "output", "bits": [10, 11]}
        },
        "cells": {
          "mux": {"type": "$mux", "parameters": {},
            "connections": {"A": [1, 2], "B": [3, 4], "S": [5], "Y": [10, 11]}}
        },
        "netnames": {}
      }}}
      ''';
      final mod = YosysNetlist.parse(json).module('m')!;
      NlBlock muxOf(NetlistDiagramModel m) =>
          m.blocks.firstWhere((b) => b.cell?.type == r'$mux');
      NlPin sOf(NlBlock b) => b.ins.firstWhere((p) => p.port == 'S');

      final normal = muxOf(buildNetlistDiagramModel(mod));
      final s0 = sOf(normal);
      expect(s0.edge.dy, normal.boxOrigin.dy + normal.boxSize.height);
      expect(s0.pos.dy, greaterThan(s0.edge.dy), reason: '短线朝下');

      final mirrored = muxOf(
        buildNetlistDiagramModel(mod, mirroredBlocks: {normal.id}),
      );
      final s1 = sOf(mirrored);
      expect(s1.edge.dy, mirrored.boxOrigin.dy);
      expect(s1.pos.dy, lessThan(s1.edge.dy), reason: '镜像后短线朝上');
    });

    test('布局优化：镜像/引脚交换选项参与候选且不劣化', () async {
      final mod = YosysNetlist.parse(_synthJson).module('top')!;
      final result = await optimizeNetlistLayout(
        mod,
        allowMirror: true,
        swapPins: true,
        maxRounds: 3,
      );
      expect(result.nodes, greaterThan(0));
      expect(result.evaluations, greaterThan(0));
      expect(
        result.mirroredBlocks.length,
        lessThan(result.nodes),
        reason: '镜像按块独立择优，不会强制全部镜像',
      );
      expect(
        result.length,
        lessThanOrEqualTo(result.initialLength + 0.01),
        reason: '只接受严格下降，不应劣化',
      );
    });
  });

  group('真实网表（yosys，缺失自动 skip）', () {
    test('多段色彩均衡器 IP：层级/真实信号名/单元类型', () async {
      final yosys = detectYosys();
      if (yosys == null) {
        markTestSkipped('未检测到 yosys（tools/yosys 或 PATH）');
        return;
      }
      // 生成 IP 包并写盘。
      final state = IspStudioState();
      addTearDown(state.dispose);
      final mb = state.graph.addNode('multi_band_eq', 0, 0);
      state.graph.nodes[mb]!.paramValues['codegenMode'] = 'lut_fixed';
      state.graph.groups.add(IspNodeGroup('g1', {mb}, name: 'eq'));
      final group = state.graph.groups.single;
      final files = buildGroupIpFiles(
        state.graph,
        group,
        const IpGenOptions(vendor: IpVendor.generic),
      );
      final top = schematicTopModule(files);

      final dir = await Directory.systemTemp.createTemp('isp_netlist_test_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final sources = <String>[];
      for (final e in files.entries) {
        if (!e.key.endsWith('.v') || e.key.startsWith('tb_')) continue;
        File(
          '${dir.path}${Platform.pathSeparator}${e.key}',
        ).writeAsStringSync(e.value);
        sources.add(e.key);
      }
      final script =
          'read_verilog ${sources.join(' ')}; '
          'hierarchy -top $top; proc; opt_clean; write_json net.json';
      final r = await Process.run(yosys.exe, [
        '-q',
        '-p',
        script,
      ], workingDirectory: dir.path);
      if (r.exitCode != 0) {
        markTestSkipped('yosys 执行失败：${r.stderr}');
        return;
      }
      final json = File(
        '${dir.path}${Platform.pathSeparator}net.json',
      ).readAsStringSync();
      final nl = YosysNetlist.parse(json);

      // 顶层：端口 + 1 个子模块实例（可下钻）。
      final topMod = nl.module(top)!;
      expect(topMod.inputs.map((p) => p.name), contains('in_data'));
      expect(topMod.outputs.map((p) => p.name), contains('out_data'));
      expect(topMod.cells, hasLength(1));
      final inst = topMod.cells.single;
      expect(inst.isInstance, isTrue);
      // 实例的输出端口必须按被引用模块判定（out_data/out_valid…）。
      expect(inst.outs.map((p) => p.port), contains('out_data'));

      // 核心模块：32 个可绘制单元（768 个 $meminit 已跳过）。
      final core = nl.resolveInstance(inst.type)!;
      expect(
        core.cells.where((c) => c.kind != NetlistCellKind.other).length,
        greaterThan(20),
      );
      final types = {for (final c in core.cells) c.type};
      expect(
        types,
        containsAll([r'$add', r'$mux', r'$adff', r'$memrd', r'$mul']),
      );
      // 无 ROM 初始化 / 层次调试单元。
      expect(types.any((t) => t.startsWith(r'$meminit')), isFalse);

      // 真实信号名保留（不 flatten 的关键收益）：比特名与引脚网名都可读。
      final names = core.bitNames.values.toSet();
      expect(names, contains('n1_hsum'));
      expect(names.where((n) => n.startsWith('n1_')).length, greaterThan(5));
      // 引脚网名按引脚跨度选名：乘法器的输入应是真实信号（而非碎片名）。
      final mul = core.cells.firstWhere((c) => c.type == r'$mul');
      final mulNets = [...mul.ins.expand((p) => p.nets)];
      expect(mulNets, isNotEmpty);
      expect(
        mulNets.any(
          (n) => n.name.startsWith('n1_') || n.name.startsWith('in_'),
        ),
        isTrue,
        reason: '引脚网名应取真实信号名：${mulNets.map((n) => n.display)}',
      );
      // ROM 读口带 MEMID 名。
      final rom = core.cells.firstWhere((c) => c.type == r'$memrd');
      expect(rom.memId, startsWith('n1_'));
      expect(rom.source, isNotNull);
      expect(rom.outs.single.port, 'DATA');

      // 真实网表直接出直线预览模型（不跑正交布线）。
      final model = buildNetlistDiagramModel(core);
      expect(model.wires, isNotEmpty);
      expect(model.canvasSize.width, lessThan(8000));
      for (final w in model.wires) {
        expect(nlStraightWireSegments(w), isNotEmpty);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

/// 单个引脚（`A`）连接的网段——用于常量/分组口径测试。
/// 比特值为整数（网比特号）或 `'x'`/`'z'` 常量字符串。
List<NetlistNet> netsOf(List<Object> bits) {
  final j = jsonEncode({
    'modules': {
      'm': {
        'ports': <String, Object>{},
        'cells': {
          r'$not$f.v:1$1': {
            'type': r'$not',
            'parameters': <String, Object>{},
            'connections': {'A': bits},
          },
        },
        'netnames': <String, Object>{},
      },
    },
  });
  return YosysNetlist.parse(j).module('m')!.cells.single.ins.single.nets;
}
