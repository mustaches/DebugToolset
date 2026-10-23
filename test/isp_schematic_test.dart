// ISP Studio 电路图标签页（sch: 标签页）测试：RTL 网表
// （yosys 出 JSON、Dart 自研布局绘制）。网表提取用注入的假实现，
// 不依赖真实工具链；真机提取在 isp_netlist_model_test.dart 里自动 skip。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_symbols.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_block_diagram.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/schematic_tab.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

/// 两级层级网表：顶层（端口 + 一个子模块实例）与核心（若干 RTL 单元）。
/// 与 yosys 真实产物口径一致（数组=总线，单数=位宽 1，字符串=常量）。
const _fakeNetJson = r'''
{
  "modules": {
    "isp_ip_eq_top": {
      "ports": {
        "clk":     {"direction": "input",  "bits": [1,2]},
        "in_data": {"direction": "input",  "bits": [10,11,12,13,14,15,16,17]},
        "out_data":{"direction": "output", "bits": [20,21,22,23,24,25,26,27]}
      },
      "cells": {
        "u_core": {
          "type": "$paramod$deadbeef\\isp_ip_eq_core",
          "parameters": {"WIDTH": "00000000000000000000000000001000"},
          "connections": {
            "clk": [1,2],
            "in_data": [10,11,12,13,14,15,16,17],
            "out_data": [20,21,22,23,24,25,26,27]
          }
        }
      },
      "netnames": {"clk": {"bits": [1,2]}, "in_data": {"bits": [10,11,12,13,14,15,16,17]}}
    },
    "isp_ip_eq_core": {
      "ports": {
        "clk":     {"direction": "input",  "bits": [1,2]},
        "in_data": {"direction": "input",  "bits": [10,11,12,13,14,15,16,17]},
        "out_data":{"direction": "output", "bits": [20,21,22,23,24,25,26,27]}
      },
      "cells": {
        "$add$core.v:40$1": {
          "type": "$add",
          "parameters": {"A_WIDTH": "00000000000000000000000000001000",
                          "Y_WIDTH": "00000000000000000000000000001000"},
          "connections": {"A": [10,11,12,13,14,15,16,17], "B": [0,0,0,0,0,0,0,0],
                           "Y": [40,41,42,43,44,45,46,47]}
        },
        "$mux$core.v:52$2": {
          "type": "$mux",
          "parameters": {"WIDTH": "00000000000000000000000000001000"},
          "connections": {"A": [40,41,42,43,44,45,46,47], "B": [1,1,1,1,1,1,1,1],
                           "S": 2, "Y": [20,21,22,23,24,25,26,27]}
        },
        "$adff$core.v:60$3": {
          "type": "$adff",
          "parameters": {"WIDTH": "00000000000000000000000000001000"},
          "connections": {"CLK": 2, "ARST": 1, "D": [20,21,22,23,24,25,26,27],
                           "Q": [50,51,52,53,54,55,56,57]}
        }
      },
      "netnames": {
        "in_data": {"bits": [10,11,12,13,14,15,16,17]},
        "n1_sum":  {"bits": [40,41,42,43,44,45,46,47]}
      }
    }
  }
}
''';

YosysNetlist _fakeNetlist() => YosysNetlist.parse(_fakeNetJson);

SchNetlistResult _okResult() => SchNetlistResult(
  success: true,
  netlist: _fakeNetlist(),
  topModule: 'isp_ip_eq_top',
  log: 'fake 提取日志\n',
);

/// 点是否落在某条线段上（含线段内部——同轴线段合并后，针脚可能位于
/// 合并段中间，几何上依然相连）。
bool onSegments(List<(Offset, Offset)> segs, Offset p) {
  for (final (a, b) in segs) {
    if ((a.dy - b.dy).abs() < 0.01 &&
        (p.dy - a.dy).abs() < 0.01 &&
        p.dx >= math.min(a.dx, b.dx) - 0.01 &&
        p.dx <= math.max(a.dx, b.dx) + 0.01) {
      return true;
    }
    if ((a.dx - b.dx).abs() < 0.01 &&
        (p.dx - a.dx).abs() < 0.01 &&
        p.dy >= math.min(a.dy, b.dy) - 0.01 &&
        p.dy <= math.max(a.dy, b.dy) + 0.01) {
      return true;
    }
  }
  return false;
}

void main() {
  /// 含编组的简单状态（multi_band_eq lut_fixed，IP 导出白名单形态）。
  (IspStudioState, String) makeGroup() {
    final state = IspStudioState();
    final mb = state.graph.addNode('multi_band_eq', 0, 0);
    state.graph.nodes[mb]!.paramValues['codegenMode'] = 'lut_fixed';
    state.graph.groups.add(IspNodeGroup('g1', {mb}, name: 'eq'));
    return (state, 'g1');
  }

  group('标签生命周期', () {
    test('openSchematicTab / 重复激活 / ungroup 联动关闭', () {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      state.openSchematicTab(groupId, IpVendor.generic);
      expect(state.openCodeTabs, contains('sch:$groupId@generic'));
      final n = state.openCodeTabs.length;
      state.openSchematicTab(groupId, IpVendor.generic);
      expect(state.openCodeTabs.length, n, reason: '同厂商重复打开不新增标签');
      state.openSchematicTab(groupId, IpVendor.vivado);
      expect(state.openCodeTabs, contains('sch:$groupId@vivado'));
      state.ungroup(groupId);
      expect(
        state.openCodeTabs.where((k) => k.startsWith('sch:$groupId')),
        isEmpty,
        reason: '编组解散后电路图标签联动关闭',
      );
    });
  });

  group('工具链探测', () {
    test('detectYosys：空目录返回 null，有 yosys.exe 返回路径', () {
      final empty = Directory.systemTemp.createTempSync('no_yosys_');
      addTearDown(() => empty.deleteSync(recursive: true));
      expect(detectYosys(searchDirs: [empty.path]), isNull);
      File('${empty.path}\\yosys.exe').writeAsStringSync('');
      final found = detectYosys(searchDirs: [empty.path]);
      expect(found, isNotNull);
      expect(found!.exe, endsWith('yosys.exe'));
    });
  });

  group('顶层模块选择', () {
    test('厂商封装优先：axis > libero > top，vendorHint 优先对应封装', () {
      final files = {
        'isp_ip_eq_top.v': '',
        'isp_ip_eq_axis.v': '',
        'isp_ip_eq_libero.v': '',
      };
      expect(schematicTopModule(files), 'isp_ip_eq_axis');
      expect(
        schematicTopModule(files, vendorHint: 'libero'),
        'isp_ip_eq_libero',
      );
      expect(schematicTopModule(files, vendorHint: 'vivado'), 'isp_ip_eq_axis');
      expect(schematicTopModule({'isp_ip_eq_top.v': ''}), 'isp_ip_eq_top');
    });
  });

  group('配色', () {
    test('悬停与选中高亮统一使用亮黄色', () {
      expect(SchPalette.dark.hover, const Color(0xFFFFD600));
      expect(SchPalette.vivadoLight.hover, const Color(0xFFFFD600));
    });

    test('暗色元件边框与 pin 元素统一为白色', () {
      const white = Color(0xFFFFFFFF);
      expect(SchPalette.dark.blockBorder, white);
      expect(SchPalette.dark.instanceText, white);
      expect(SchPalette.dark.moduleText, white);
      expect(SchPalette.dark.pinText, white);
      expect(SchPalette.dark.portBorder, white);
      expect(SchPalette.dark.portText, white);
      expect(SchPalette.dark.cellConst, white);
    });

    test('浅色实例标注与展开按钮使用深蓝配色', () {
      expect(
        nlBlockLabelColorOf(SchPalette.vivadoLight),
        nlBlockLabelLightColor,
      );
      expect(nlBlockLabelColorOf(SchPalette.dark), nlBlockLabelColor);
      expect(nlExpandLightFill, const Color(0xFF33486C));
      expect(nlExpandLightBorder, const Color(0xFF22385A));
      expect(SchPalette.vivadoLight.pinText, const Color(0xFF000000));
      expect(SchPalette.vivadoLight.pinStroke, const Color(0xFF000000));
      // 暗色未指定 pinStroke：针脚图形跟随块边框白色。
      expect(SchPalette.dark.pinStrokeOrBorder, SchPalette.dark.blockBorder);
    });
  });

  group('网表图模型（buildNetlistDiagramModel）', () {
    test('块 = 单元 + 端口组；每网直线接得住针脚；画布尺寸有限', () {
      final nl = _fakeNetlist();
      final core = nl.module('isp_ip_eq_core')!;
      final model = buildNetlistDiagramModel(core);
      // 3 个单元 + 输入/输出端口组。
      expect(model.blocks.where((b) => !b.isIo).length, 3);
      expect(model.blocks.where((b) => b.isIo).length, 2);
      expect(model.wires, isNotEmpty);
      expect(model.canvasSize.width, greaterThan(0));
      expect(model.canvasSize.height, greaterThan(0));
      // 团拓扑包含 (驱动, 每个负载) 的直线，连线接得住针脚。
      for (final w in model.wires) {
        final segments = nlStraightWireSegments(w);
        expect(segments, isNotEmpty);
        for (final l in w.loads) {
          expect(
            segments,
            contains((w.from.pos, l.pos)),
            reason: '负载 ${l.display} 应连到直线端点',
          );
        }
      }
      // 坐标全部有限（NaN/Inf 会让 InteractiveViewer 直接崩）。
      for (final b in model.blocks) {
        expect(b.origin.dx.isFinite && b.origin.dy.isFinite, isTrue);
      }
      for (final w in model.wires) {
        for (final (a, b) in nlStraightWireSegments(w)) {
          expect(a.dx.isFinite && a.dy.isFinite, isTrue);
          expect(b.dx.isFinite && b.dy.isFinite, isTrue);
        }
      }
    });

    test('扇出：团拓扑 4 pin 全对相连 6 条、星形 4 条', () {
      // 一个 $not 的输出同时驱动 3 个负载。
      const json = r'''
      {"modules": {"m": {
        "ports": {
          "i": {"direction": "input", "bits": [1]},
          "o": {"direction": "output", "bits": [99]}
        },
        "cells": {
          "$not$c.v:1$1": {"type": "$not", "parameters": {},
            "connections": {"A": [1], "Y": [10]}},
          "$not$c.v:2$2": {"type": "$not", "parameters": {},
            "connections": {"A": [10], "Y": [20]}},
          "$not$c.v:3$3": {"type": "$not", "parameters": {},
            "connections": {"A": [10], "Y": [21]}},
          "$not$c.v:4$4": {"type": "$not", "parameters": {},
            "connections": {"A": [10], "Y": [22]}},
          "$not$c.v:5$5": {"type": "$not", "parameters": {},
            "connections": {"A": [20], "Y": [30]}},
          "$not$c.v:6$6": {"type": "$not", "parameters": {},
            "connections": {"A": [30], "Y": [99]}}
        },
        "netnames": {"n": {"bits": [10]}}
      }}}
      ''';
      final mod = YosysNetlist.parse(json).module('m')!;
      final model = buildNetlistDiagramModel(mod);
      final fan = model.wires.where((w) => w.from.bits.contains(10)).toList();
      expect(fan, hasLength(1), reason: '同一根网不应拆成多条走线');
      expect(fan.single.loads, hasLength(3));
      expect(
        nlStraightWireSegments(fan.single),
        hasLength(6),
        reason: '1 驱动 + 3 负载 = 4 pin，团拓扑 C(4,2)=6',
      );
      expect(
        nlStraightWireSegments(fan.single, NlNetTopology.star),
        hasLength(4),
        reason: '星形每 pin 连到质心',
      );
    });

    testWidgets('网名标签层位于所有元件块之后', (tester) async {
      final model = buildNetlistDiagramModel(
        _fakeNetlist().module('isp_ip_eq_core')!,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: NetlistDiagram(model: model),
            ),
          ),
        ),
      );
      final layer = find.byKey(const ValueKey('nl-label-layer'));
      expect(layer, findsOneWidget);
      expect(tester.widget<IgnorePointer>(layer).ignoring, isTrue);
      final stack = tester.widget<Stack>(
        find.ancestor(of: layer, matching: find.byType(Stack)).first,
      );
      expect(stack.children.last.key, const ValueKey('nl-label-layer'));
      final mainPainter =
          (stack.children.first as CustomPaint).painter as NetlistWirePainter;
      final labelPainter =
          (stack.children.last as IgnorePointer).child as CustomPaint;
      final labelPainterModel = labelPainter.painter as NetlistWirePainter;
      expect(mainPainter.drawLabels, isFalse);
      expect(labelPainterModel.labelsOnly, isTrue);
    });

    test('层级原位展开：实例块变容器，内部递归出子模块的块与网', () {
      final nl = _fakeNetlist();
      final top = nl.module('isp_ip_eq_top')!;
      // 折叠态：无容器、1 层。
      final m0 = buildNetlistDiagramModel(top);
      expect(m0.flattened(), hasLength(1));
      expect(m0.blocks.any((b) => b.isContainer), isFalse);
      // 展开态：容器出现，层数 +1，容器内能看到子模块的块与网。
      final m1 = buildNetlistDiagramModel(
        top,
        expanded: {'u_core'},
        resolve: (t) => nl.resolveInstance(t) ?? nl.module(t),
      );
      final container = m1.blocks.firstWhere((b) => b.isContainer);
      expect(container.sub, isNotNull);
      expect(
        container.boxSize.width,
        greaterThan(container.sub!.canvasSize.width),
      );
      final levels = m1.flattened();
      expect(levels, hasLength(2));
      expect(levels[1].wires, isNotEmpty, reason: '容器内应有子模块网');
      // 子层偏移 = 容器在父画布的位置 + 容器内留白：子电路必须画在容器框内。
      expect(levels[1].offset, container.boxOrigin + container.subOffset);
      for (final cb in levels[1].blocks) {
        if (cb.isIo) continue;
        final abs = levels[1].offset + cb.origin;
        expect(abs.dx, greaterThanOrEqualTo(container.boxOrigin.dx));
        expect(
          abs.dx + cb.size.width,
          lessThanOrEqualTo(container.boxOrigin.dx + container.boxSize.width),
          reason: '${cb.title} 不得越出容器右边界',
        );
      }
      // 边缘针脚 → 子模块端口 连接短线：起点在容器左/右边缘，终点在框内。
      final rightEdge = container.boxOrigin.dx + container.boxSize.width;
      for (final (a, c) in container.subLinks) {
        final onLeft = (a.dx - container.boxOrigin.dx).abs() < 1e-9;
        final onRight = (a.dx - rightEdge).abs() < 1e-9;
        expect(onLeft || onRight, isTrue, reason: '连接短线起点须在容器边缘');
        expect(c.dx, greaterThan(container.boxOrigin.dx));
        expect(c.dx, lessThan(rightEdge), reason: '子模块端口须在容器框内');
        expect(a.dy, closeTo(c.dy, 1e-9));
      }
      // 展开命中：「−」与折叠态「＋」都位于框内左上角（boxOrigin）。
      final hit = nlExpandTargetAt(
        levels,
        container.boxOrigin + const Offset(4, 4),
      );
      expect(hit?.name, 'u_core');
      expect(
        nlExpandTargetAt(levels, container.origin + const Offset(4, 4))?.name,
        'u_core',
        reason: '实例名移入符号内后，origin 与 boxOrigin 重合',
      );
      final collapsed = m0.blocks.firstWhere(
        (b) => b.cell?.isInstance ?? false,
      );
      expect(
        nlExpandTargetAt(
          m0.flattened(),
          collapsed.boxOrigin + const Offset(4, 4),
        )?.name,
        'u_core',
      );
      expect(nlExpandTargetAt(levels, const Offset(-50, -50)), isNull);
    });

    test('长链压列：20 级链不被展成 1:N 长条（宽高比受控）', () {
      // 20 个 $not 串成一条链 —— 纯分层会得到 20 列、1:20 长条。
      final cells = <String, Object>{};
      final nets = <String, Object>{};
      for (var i = 0; i < 20; i++) {
        final from = i == 0 ? 100 : 200 + (i - 1);
        final to = 200 + i;
        cells[r'$not$c.v:'
            '${i + 1}'
            r'$'
            '${i + 1}'] = {
          'type': r'$not',
          'parameters': <String, Object>{},
          'connections': {
            'A': [from],
            'Y': [to],
          },
        };
        nets['s$i'] = {
          'bits': [to],
        };
      }
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
                'bits': [219],
              },
            },
            'cells': cells,
            'netnames': nets,
          },
        },
      });
      final mod = YosysNetlist.parse(json).module('m')!;
      expect(mod.cells, hasLength(20));
      final model = buildNetlistDiagramModel(mod);
      final ratio = model.canvasSize.width / model.canvasSize.height;
      expect(ratio, lessThan(9.0), reason: '不应是 1:N 长条（实测 $ratio）');
      expect(model.canvasSize.width, lessThan(4000));
    });
  });

  group('标准电路符号', () {
    NetlistCell cellOf(String type, {Map<String, int> params = const {}}) {
      final meta = cellMeta(type);
      return NetlistCell(
        name: 'u_$type',
        type: type,
        kind: kindOf(type),
        typeLabel: meta.$1,
        label: 'u_$type',
        desc: meta.$2,
        ins: const [],
        outs: const [],
        params: params,
      );
    }

    test('门/选择器/运算符按类型生成不同标准几何', () {
      const rect = Rect.fromLTWH(10, 20, 90, 46);
      final and = buildNetlistSymbol(cellOf(r'$and'), rect);
      final or = buildNetlistSymbol(cellOf(r'$or'), rect);
      final xor = buildNetlistSymbol(cellOf(r'$xor'), rect);
      final not = buildNetlistSymbol(cellOf(r'$not'), rect);
      final mux = buildNetlistSymbol(cellOf(r'$mux'), rect);
      expect(and.kind, NetlistSymbolKind.andGate);
      expect(and.outline.toSvg(), contains('C'));
      expect(or.kind, NetlistSymbolKind.orGate);
      expect(or.outline.toSvg(), contains('Q'));
      expect(xor.details, hasLength(1), reason: 'XOR 输入侧应多一条弧线');
      expect(not.kind, NetlistSymbolKind.notGate);
      expect(not.bubbles, hasLength(1), reason: 'NOT 输出有反相气泡');
      expect(mux.kind, NetlistSymbolKind.mux);
      expect(mux.outline.toSvg(), isNot(contains('Q')));
      expect(buildNetlistSymbol(cellOf(r'$add'), rect).centerLabel, '+');
      expect(buildNetlistSymbol(cellOf(r'$mul'), rect).centerLabel, '×');
      expect(buildNetlistSymbol(cellOf(r'$gt'), rect).centerLabel, '>');
      expect(buildNetlistSymbol(cellOf(r'$shl'), rect).centerLabel, '<<');
    });

    test('DFF 有时钟三角，低有效复位有反相气泡', () {
      final cell = cellOf(
        r'$adff',
        params: {'CLK_POLARITY': 1, 'ARST_POLARITY': 0},
      );
      final geometry = buildNetlistSymbol(
        cell,
        const Rect.fromLTWH(10, 20, 100, 70),
        pins: const [
          NetlistSymbolPin(
            port: 'CLK',
            display: 'CLK',
            edge: Offset(10, 45),
            isInput: true,
          ),
          NetlistSymbolPin(
            port: 'ARST',
            display: 'ARST',
            edge: Offset(10, 61),
            isInput: true,
          ),
        ],
      );
      expect(geometry.kind, NetlistSymbolKind.flipFlop);
      expect(geometry.details, hasLength(1));
      expect(geometry.details.single.toSvg(), contains('L'));
      expect(geometry.bubbles, hasLength(1));
      expect(geometry.bubbles.single.center, const Offset(10, 61));
    });

    test('布局：MUX 选择端在底边、组合逻辑输出居中、DFF 的 Q 对齐 D', () {
      final core = _fakeNetlist().module('isp_ip_eq_core')!;
      final model = buildNetlistDiagramModel(core);
      NlBlock blockOf(String type) =>
          model.blocks.firstWhere((b) => b.cell?.type == type);
      Rect rectOf(NlBlock b) => Rect.fromLTWH(
        b.boxOrigin.dx,
        b.boxOrigin.dy,
        b.boxSize.width,
        b.boxSize.height,
      );

      final mux = blockOf(r'$mux');
      final muxRect = rectOf(mux);
      final select = mux.ins.firstWhere((p) => p.port == 'S');
      expect(select.edge, Offset(muxRect.center.dx, muxRect.bottom));
      expect(select.pos.dy, greaterThan(muxRect.bottom));
      expect(mux.outs.single.edge.dy, muxRect.center.dy);

      final add = blockOf(r'$add');
      expect(add.outs.single.edge.dy, rectOf(add).center.dy);
      final dff = blockOf(r'$adff');
      final d = dff.ins.firstWhere((p) => p.port == 'D');
      expect(dff.outs.single.edge.dy, d.edge.dy);
    });

    test('元件之间至少保留 5 条走线空间', () {
      final json = {
        'modules': {
          'm': {
            'ports': {
              'a': {
                'direction': 'input',
                'bits': [1],
              },
              'y0': {
                'direction': 'output',
                'bits': [2],
              },
              'y1': {
                'direction': 'output',
                'bits': [3],
              },
            },
            'cells': {
              r'$not$c.v:1$1': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [1],
                  'Y': [2],
                },
              },
              r'$not$c.v:2$2': {
                'type': r'$not',
                'parameters': <String, Object>{},
                'connections': {
                  'A': [1],
                  'Y': [3],
                },
              },
            },
            'netnames': {
              'a': {
                'bits': [1],
              },
            },
          },
        },
      };
      final model = buildNetlistDiagramModel(
        YosysNetlist.parse(jsonEncode(json)).module('m')!,
      );
      final byColumn = <int, List<NlBlock>>{};
      for (final b in model.blocks) {
        if (b.isIo) continue;
        (byColumn[b.column] ??= []).add(b);
      }
      var verticalGaps = 0;
      for (final blocks in byColumn.values) {
        if (blocks.length < 2) continue;
        blocks.sort((a, b) => a.boxOrigin.dy.compareTo(b.boxOrigin.dy));
        for (var i = 1; i < blocks.length; i++) {
          verticalGaps++;
          final gap =
              blocks[i].boxOrigin.dy -
              (blocks[i - 1].boxOrigin.dy + blocks[i - 1].boxSize.height);
          expect(
            gap,
            greaterThanOrEqualTo(5 * 15 - 0.01),
            reason: '上下元件之间要能通过 5 条走线',
          );
        }
      }
      expect(verticalGaps, greaterThan(0));

      // 横向：用真实布局的宽图验证相邻列之间也能过 5 条走线。
      final wide = buildNetlistDiagramModel(
        _fakeNetlist().module('isp_ip_eq_core')!,
      );
      final wideByColumn = <int, List<NlBlock>>{};
      for (final b in wide.blocks) {
        if (b.isIo) continue;
        (wideByColumn[b.column] ??= []).add(b);
      }
      final wideColumns = wideByColumn.keys.toList()..sort();
      for (var i = 1; i < wideColumns.length; i++) {
        final left = wideByColumn[wideColumns[i - 1]]!;
        final right = wideByColumn[wideColumns[i]]!;
        final maxRight = left
            .map((b) => b.boxOrigin.dx + b.boxSize.width)
            .reduce(math.max);
        final minLeft = right.map((b) => b.boxOrigin.dx).reduce(math.min);
        expect(
          minLeft - maxRight,
          greaterThanOrEqualTo(5 * 15 - 0.01),
          reason: '左右元件之间要能通过 5 条走线',
        );
      }
      expect(verticalGaps, greaterThan(0));
      final columns = byColumn.keys.toList()..sort();
      for (var i = 1; i < columns.length; i++) {
        final left = byColumn[columns[i - 1]]!;
        final right = byColumn[columns[i]]!;
        final maxRight = left
            .map((b) => b.boxOrigin.dx + b.boxSize.width)
            .reduce(math.max);
        final minLeft = right.map((b) => b.boxOrigin.dx).reduce(math.min);
        expect(
          minLeft - maxRight,
          greaterThanOrEqualTo(5 * 15 - 0.01),
          reason: '左右元件之间要能通过 5 条走线',
        );
      }
    });
    test('实例名/类型名位于符号内部，针脚仍保留行高', () {
      final top = _fakeNetlist().module('isp_ip_eq_top')!;
      final model = buildNetlistDiagramModel(top);
      final block = model.blocks.firstWhere((b) => b.cell?.isInstance ?? false);
      expect(block.boxOrigin.dy, block.origin.dy, reason: '不再占用符号上方空间');
      expect(block.size.height, block.boxSize.height, reason: '不再占用符号下方空间');

      final rows = <double>{
        for (final p in [...block.ins, ...block.outs]) p.edge.dy,
      }.toList()..sort();
      expect(rows.first - block.boxOrigin.dy, greaterThanOrEqualTo(20));
      expect(
        block.boxOrigin.dy + block.boxSize.height - rows.last,
        greaterThanOrEqualTo(20),
        reason: '末行针脚文字不得被块底边裁切',
      );
      for (var i = 1; i < rows.length; i++) {
        expect(
          rows[i] - rows[i - 1],
          greaterThanOrEqualTo(20),
          reason: '10px 针脚字体（约 12px 文本高度）不能使用 10px 行高',
        );
      }
    });

    test('OR 输入短线落在内凹曲线上，输出仍在符号中心', () {
      const json = r'''
      {"modules": {"m": {
        "ports": {"a": {"direction": "input", "bits": [1]},
                  "b": {"direction": "input", "bits": [2]},
                  "y": {"direction": "output", "bits": [3]}},
        "cells": {"$or$c.v:1$1": {"type": "$or", "parameters": {},
          "connections": {"A": 1, "B": 2, "Y": 3}}},
        "netnames": {}
      }}}
      ''';
      final mod = YosysNetlist.parse(json).module('m')!;
      final model = buildNetlistDiagramModel(mod);
      final block = model.blocks.firstWhere((b) => b.cell?.type == r'$or');
      final rect = Rect.fromLTWH(
        block.boxOrigin.dx,
        block.boxOrigin.dy,
        block.boxSize.width,
        block.boxSize.height,
      );
      for (final p in block.ins) {
        expect(p.edge.dx, greaterThan(rect.left));
        expect(p.pos.dx, rect.left - 15);
        expect(p.pos.dy, p.edge.dy);
        expect(p.edge.dx % 15, 0);
        expect(p.edge.dy % 15, 0);
        final curveX = netlistSymbolInputEdgeX(block.cell, rect, p.edge.dy);
        expect(p.edge.dx, closeTo(curveX, 5.0));
      }
      expect(block.outs.single.edge.dy, rect.center.dy);
      expect(block.outs.single.edge.dy % 15, 0);
    });
  });

  group('网表 SVG 导出（自研）', () {
    test('根尺寸 = 画布尺寸、无 <style> 块、含单元块与端口', () {
      final core = _fakeNetlist().module('isp_ip_eq_core')!;
      final model = buildNetlistDiagramModel(core);
      final svg = buildNetlistSvg(model, fontFamily: 'SimHei');
      expect(svg, contains('<svg'));
      expect(svg, contains('</svg>'));
      expect(svg, isNot(contains('<style')));
      expect(svg, contains('fill="#1e1e1e"'), reason: 'SVG 默认使用暗色背景');
      final size = parseSvgSize(svg)!;
      expect(size.w, closeTo(model.canvasSize.width, 0.2));
      expect(size.h, closeTo(model.canvasSize.height, 0.2));
      // 单元类型名与端口名都在。
      expect(svg, contains('ADD'));
      expect(svg, contains('MUX'));
      expect(svg, contains('in_data'));
      expect(svg, contains('data-symbol="operatorBlock"'));
      expect(svg, contains('data-symbol="mux"'));
      expect(svg, contains('data-symbol="flipFlop"'));
      expect(svg, contains('>+</text>'));
      // 文本转义（防止 `&`/`<` 破坏 XML）。
      expect(buildNetlistSvg(model).contains('<text'), isTrue);
    });

    test('直线预览 SVG：团拓扑全对相连、星形各 pin 到质心', () {
      NlPin pin(double x, double y, {bool output = false}) {
        final p = NlPin(
          port: 'p',
          display: 'p',
          width: 1,
          bits: [x.toInt()],
          dir: output ? NetlistPortDir.output : NetlistPortDir.input,
        );
        p.pos = Offset(x, y);
        return p;
      }

      final driver = pin(0, 0, output: true);
      final loads = [pin(100, 40), pin(100, 80), pin(100, 120)];
      final wire = NlWire(driver, loads, 'n', bits: [0]);
      final model = NetlistDiagramModel(
        blocks: const [],
        wires: [wire],
        canvasSize: const Size(200, 160),
        moduleName: 'm',
        cellCount: 4,
      );

      final clique = buildNetlistSvg(model, topology: NlNetTopology.clique);
      expect('<path d="M'.allMatches(clique).length, 1, reason: '单网导出一条 path');
      expect(
        'M'.allMatches(clique).length,
        6,
        reason: '4 pin 全对相连 = C(4,2) 段直线',
      );
      // 团拓扑包含负载之间的连线。
      expect(clique.contains('M100.0,40.0 L100.0,80.0'), isTrue);
      final star = buildNetlistSvg(model, topology: NlNetTopology.star);
      expect('M'.allMatches(star).length, 4, reason: '4 pin 各连到质心');
      // 质心 (75, 60)：星形包含驱动端 → 质心的线，不含负载间连线。
      expect(star.contains('M0.0,0.0 L75.0,60.0'), isTrue);
      expect(star.contains('M100.0,40.0 L100.0,80.0'), isFalse);
    });

    test('正交布线 SVG：使用 autoRoutes 线段并画同网分支点', () {
      NlPin pin(double x, double y, {bool output = false}) {
        final p = NlPin(
          port: 'p',
          display: 'p',
          width: 1,
          bits: [x.toInt()],
          dir: output ? NetlistPortDir.output : NetlistPortDir.input,
        );
        p.pos = Offset(x, y);
        return p;
      }

      final driver = pin(0, 0, output: true);
      final loads = [pin(100, 40), pin(100, 60)];
      final wire = NlWire(driver, loads, 'n', bits: [0]);
      final model = NetlistDiagramModel(
        blocks: const [],
        wires: [wire],
        canvasSize: const Size(200, 160),
        moduleName: 'm',
        cellCount: 3,
      );
      final mid = const Offset(0, 60);
      final svg = buildNetlistSvg(
        model,
        autoRoutes: {
          wire: [(const Offset(0, 0), mid), (mid, const Offset(100, 60))],
        },
        autoJunctions: {
          wire: [mid],
        },
      );
      expect(svg.contains('M0.0,0.0 L0.0,60.0'), isTrue);
      expect(svg.contains('M0.0,60.0 L100.0,60.0'), isTrue);
      expect(svg, contains('r="2.0"'), reason: '同网分支点应画实心圆');
      expect(svg.contains('M0.0,0.0 L100.0,40.0'), isFalse);
    });

    test('元件、pin 与端口轮廓的 SVG 线宽均为 0.5dp（总线 pin 为 2dp）', () {
      final core = _fakeNetlist().module('isp_ip_eq_core')!;
      final model = buildNetlistDiagramModel(core);
      final svg = buildNetlistSvg(model);
      expect(svg, contains('<g stroke="#ffffff" stroke-width="0.5">'));
      expect(svg, isNot(contains('stroke-width="1"')));
      // 总线针脚短线加粗到 2dp（独立分组）。
      expect(svg, contains('<g stroke="#ffffff" stroke-width="2.0">'));
      expect(svg, contains('stroke="#00bfff" stroke-width="3.0"'));
      expect(SchPalette.dark.wireBus, const Color(0xFF00BFFF));
      expect(SchPalette.vivadoLight.wireBus, const Color(0xFF1F4E79));
      expect(SchPalette.vivadoLight.wire, const Color(0xFF14651A));
      // 符号内实例名/类型名：黄色、缩小 3dp。
      expect(svg, contains('font-size="7.5"'));
      expect(svg, contains('font-size="6"'));
      expect(svg, contains('fill="#ffd54f"'));
    });

    test('左侧常量 pin 的参数值放在元件外侧并显示为白色', () {
      final core = _fakeNetlist().module('isp_ip_eq_core')!;
      final model = buildNetlistDiagramModel(core);
      final svg = buildNetlistSvg(model);
      final block = model.blocks.firstWhere((b) => b.cell?.type == r'$add');
      final pin = block.ins.firstWhere((p) => p.port == 'B');
      expect(pin.constText, '8\'h00');
      const textWidth = 5 * 9 * 0.56;
      final x = nlConstLabelX(pin, textWidth);
      expect(x, lessThan(pin.pos.dx));
      expect(x, lessThan(block.boxOrigin.dx));
      expect(svg, contains('x="${x.toStringAsFixed(1)}"'));
      expect(svg, contains('fill="#ffffff">8\'h00</text>'));
    });

    test('多段常量气泡按 MSB 位域和常量段两行显示', () {
      final pin = NlPin(
        port: 'B',
        display: 'B[17:0]',
        width: 18,
        bits: List<int>.generate(18, (i) => i),
        nets: [
          NetlistNet(
            name: "13'h0000",
            bits: List<int>.generate(13, (i) => i),
            isConst: true,
            constValue: 0,
          ),
          const NetlistNet(
            name: "1'b1",
            bits: [13],
            isConst: true,
            constValue: 1,
          ),
          NetlistNet(
            name: "4'h0",
            bits: List<int>.generate(4, (i) => 14 + i),
            isConst: true,
            constValue: 0,
          ),
        ],
        constText: "13'h0000|1'b1|4'h0",
      );
      expect(
        nlConstTooltip(pin),
        "[17:14] [13] [12:0]\n4'h0 | 1'b1 | 13'h0000",
      );
      final single = NlPin(
        port: 'B',
        display: 'B[7:0]',
        width: 8,
        bits: List<int>.generate(8, (i) => i),
        nets: [
          NetlistNet(
            name: "8'h00",
            bits: List<int>.generate(8, (i) => i),
            isConst: true,
            constValue: 0,
          ),
        ],
        constText: "8'h00",
      );
      expect(nlConstTooltip(single), "[7:0]\n8'h00");
    });

    testWidgets('常量参数平时隐藏，悬停标记时以气泡显示', (tester) async {
      final model = buildNetlistDiagramModel(
        _fakeNetlist().module('isp_ip_eq_core')!,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: NetlistDiagram(model: model),
            ),
          ),
        ),
      );
      await tester.pump();
      final marker = find.byTooltip('[7:0]\n8\'h00');
      expect(marker, findsOneWidget);
      expect(find.text('[7:0]\n8\'h00'), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(marker));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('[7:0]\n8\'h00'), findsOneWidget);
      // 悬停时主绘制层收到该常量引脚 → 方框填充实心黄高亮。
      NetlistWirePainter mainPainter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<NetlistWirePainter>()
          .firstWhere((p) => !p.labelsOnly);
      expect(
        mainPainter().hoverConst?.constText,
        "8'h00",
        reason: '悬停常量标记应高亮（painter.hoverConst 指向该引脚）',
      );
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('[7:0]\n8\'h00'), findsNothing);
      expect(mainPainter().hoverConst, isNull, reason: '移开后取消高亮');
      await mouse.removePointer();
    });

    test('CLK/ARST 的网线终止于外部 pin 节点，不画到元件框', () {
      final core = _fakeNetlist().module('isp_ip_eq_core')!;
      final model = buildNetlistDiagramModel(core);
      final svg = buildNetlistSvg(model);
      final dff = model.blocks.firstWhere((b) => b.cell?.type == r'$adff');
      for (final name in ['CLK', 'ARST']) {
        final pin = dff.ins.firstWhere((p) => p.port == name);
        final segment =
            'M${pin.edge.dx.toStringAsFixed(1)},'
            '${pin.edge.dy.toStringAsFixed(1)} '
            'L${pin.pos.dx.toStringAsFixed(1)},'
            '${pin.pos.dy.toStringAsFixed(1)}';
        final paths = svg
            .split('<path')
            .where((part) => part.contains(segment))
            .toList();
        expect(paths, isEmpty, reason: '$name 的彩色网路径不得延伸到 edge');
        final grayStub =
            '<line x1="${pin.edge.dx.toStringAsFixed(1)}" '
            'y1="${pin.edge.dy.toStringAsFixed(1)}" '
            'x2="${pin.pos.dx.toStringAsFixed(1)}" '
            'y2="${pin.pos.dy.toStringAsFixed(1)}"/>';
        expect(svg, contains(grayStub), reason: '$name 保留灰色针脚自身短线');
        expect(pin.pos.dx - pin.edge.dx, lessThanOrEqualTo(-15));
        expect(pin.pos.dy, pin.edge.dy);
      }
    });
  });

  group('电路图标签页', () {
    Future<void> pumpTab(
      WidgetTester tester,
      IspStudioState state,
      String groupId, {
      required Future<SchNetlistResult> Function(
        Map<String, String> files, {
        required String topName,
        void Function(String chunk)? onOutput,
      })
      renderer,
      Future<Map<String, String>> Function(
        IspGraph g,
        IspNodeGroup gr,
        IpGenOptions o,
      )?
      filesBuilder,
    }) {
      return tester.pumpWidget(
        ChangeNotifierProvider<IspStudioState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: SchematicTab(
                groupId: groupId,
                renderer: renderer,
                filesBuilder:
                    filesBuilder ??
                    (g, gr, o) async => {
                      'isp_ip_eq_core.v': '// core',
                      'isp_ip_eq_top.v': '// top',
                    },
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('默认 RTL 顶层网表：模块框图入口已移除', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(NetlistDiagram), findsOneWidget);
      expect(find.byTooltip('模块框图（编组 IR 直绘）'), findsNothing);
      expect(find.byTooltip('切换浅色配色（Vivado 风格）'), findsOneWidget);
      expect(find.text('编组·电路图'), findsOneWidget);
      expect(find.text('只读'), findsOneWidget);
    });

    testWidgets('切到 RTL 网表：自研电路图 + 顶层信息 + 日志默认收起', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async {
          expect(topName, 'isp_ip_eq_top');
          onOutput?.call('fake 提取日志\n');
          return _okResult();
        },
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(NetlistDiagram), findsOneWidget);
      expect(
        tester.widget<NetlistDiagram>(find.byType(NetlistDiagram)).light,
        isFalse,
      );
      // 信息区含模块名/单元数与端口方向分类统计（I/O/IO）。
      expect(find.textContaining('模块 isp_ip_eq_top'), findsOneWidget);
      expect(find.textContaining('1 单元'), findsOneWidget);
      expect(find.textContaining('I 2 / O 1'), findsOneWidget);
      expect(find.byTooltip('重新生成'), findsOneWidget);
      expect(find.byTooltip('导出SVG'), findsOneWidget);
      expect(find.byTooltip('导出PNG'), findsOneWidget);
      // 成功后日志面板默认收起。
      expect(find.textContaining('fake 提取日志'), findsNothing);
      // 顶层只有一个实例块：点它下钻到核心模块。
      expect(find.text('u_core'), findsOneWidget);
    });

    testWidgets('工具栏布局布线设置：拓扑单选 + 镜像元件/引脚交换复选', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();

      // 工具栏不再直接放「团/星」切换按钮。
      expect(find.byKey(const ValueKey('nl-topology-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('nl-settings-button')), findsOneWidget);
      expect(find.textContaining('直线·星形'), findsOneWidget);
      final beforeModel = tester
          .widget<NetlistDiagram>(find.byType(NetlistDiagram))
          .model;

      await tester.tap(find.byKey(const ValueKey('nl-settings-button')));
      await tester.pumpAndSettle();
      expect(find.text('布局布线设置'), findsOneWidget);
      expect(find.text('布局拓扑策略选择'), findsOneWidget);
      expect(find.text('团形拓扑'), findsOneWidget);
      expect(find.text('星形拓扑'), findsOneWidget);
      expect(find.byKey(const ValueKey('nl-settings-clique')), findsOneWidget);
      expect(find.byKey(const ValueKey('nl-settings-star')), findsOneWidget);
      // 两个拓扑单选在同一行。
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('nl-settings-star')),
          matching: find.byType(Row),
        ),
        findsWidgets,
      );
      CheckboxListTile mirrorTile() => tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('nl-settings-mirror')),
      );
      CheckboxListTile swapTile() => tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('nl-settings-swap-pins')),
      );
      // 三个分区：布局拓扑策略选择 / 布局优化选项 / 布线优化选项。
      expect(find.text('布局优化选项'), findsOneWidget);
      expect(find.text('布线优化选项'), findsOneWidget);
      expect(find.text('镜像元件'), findsOneWidget);
      expect(find.text('引脚交换'), findsOneWidget);
      expect(mirrorTile().value, isTrue, reason: '镜像元件默认勾选');
      expect(swapTile().value, isTrue, reason: '引脚交换默认勾选');
      // 允许全局重排：默认关闭，勾选后保留。
      CheckboxListTile globalTile() => tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('nl-settings-global-reorder')),
      );
      expect(find.text('允许全局重排'), findsOneWidget);
      expect(globalTile().value, isFalse, reason: '允许全局重排默认关闭');
      // 允许列内非等间距：默认关闭。
      CheckboxListTile rowGapTile() => tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('nl-settings-row-gap')),
      );
      expect(find.text('允许列内非等间距'), findsOneWidget);
      expect(rowGapTile().value, isFalse, reason: '允许列内非等间距默认关闭');
      // 列分配算法：分层布局为默认，关闭可回退经典压缩。
      expect(find.text('分层布局'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('nl-settings-layered')),
            )
            .value,
        isFalse,
        reason: '分层布局默认关闭',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-global-reorder')),
      );
      await tester.tap(
        find.byKey(const ValueKey('nl-settings-global-reorder')),
      );
      await tester.pumpAndSettle();
      expect(globalTile().value, isTrue);
      // 勾选只是优化选项，不立即改模型。
      expect(
        identical(
          tester.widget<NetlistDiagram>(find.byType(NetlistDiagram)).model,
          beforeModel,
        ),
        isTrue,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-global-reorder')),
      );
      await tester.tap(
        find.byKey(const ValueKey('nl-settings-global-reorder')),
      );
      await tester.pumpAndSettle();
      expect(globalTile().value, isFalse);
      // 布线优化选项：镜像/四边引脚交换默认开启，左右镜像禁用待完成。
      CheckboxListTile routeTile(String key) => tester.widget<CheckboxListTile>(
        find.byKey(ValueKey('nl-settings-route-$key')),
      );
      expect(find.text('上下镜像元件'), findsOneWidget);
      expect(find.text('左右镜像元件'), findsOneWidget);
      expect(find.text('交换左侧引脚'), findsOneWidget);
      expect(find.text('交换右侧引脚'), findsOneWidget);
      expect(find.text('交换上方引脚'), findsOneWidget);
      expect(find.text('交换下方引脚'), findsOneWidget);
      expect(routeTile('mirror-v').value, isTrue);
      expect(routeTile('mirror-h').value, isFalse);
      expect(routeTile('mirror-h').onChanged, isNull, reason: '左右镜像待完成');
      expect(routeTile('swap-l').value, isTrue);
      expect(routeTile('swap-r').value, isTrue);
      expect(routeTile('swap-t').value, isTrue);
      expect(routeTile('swap-b').value, isTrue);

      // 切换团形（对话框保持打开；先滚回顶部，刚才的 ensureVisible 把
      // 单选滚出了可视区）。
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-clique')),
      );
      await tester.tap(find.byKey(const ValueKey('nl-settings-clique')));
      await tester.pumpAndSettle();
      expect(find.textContaining('直线·团'), findsOneWidget);

      // 取消勾选镜像元件：立即撤销已采纳的镜像并重建模型。
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-mirror')),
      );
      await tester.tap(find.byKey(const ValueKey('nl-settings-mirror')));
      await tester.pumpAndSettle();
      expect(mirrorTile().value, isFalse);

      // 取消勾选引脚交换：同样立即重建。
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-swap-pins')),
      );
      await tester.tap(find.byKey(const ValueKey('nl-settings-swap-pins')));
      await tester.pumpAndSettle();
      expect(swapTile().value, isFalse);
      final rebuiltModel = tester
          .widget<NetlistDiagram>(find.byType(NetlistDiagram))
          .model;
      expect(
        identical(rebuiltModel, beforeModel),
        isFalse,
        reason: '取消勾选会撤销已采纳优化并重建模型',
      );

      // 重新勾选：仅作为优化选项，不立即改模型。
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-mirror')),
      );
      await tester.tap(find.byKey(const ValueKey('nl-settings-mirror')));
      await tester.pumpAndSettle();
      expect(mirrorTile().value, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-swap-pins')),
      );
      await tester.tap(find.byKey(const ValueKey('nl-settings-swap-pins')));
      await tester.pumpAndSettle();
      expect(swapTile().value, isTrue);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      final diagram = tester.widget<NetlistDiagram>(
        find.byType(NetlistDiagram),
      );
      expect(diagram.topology, NlNetTopology.clique);
      expect(
        identical(diagram.model, rebuiltModel),
        isTrue,
        reason: '重新勾选只是优化选项，不立即改模型',
      );
      expect(find.textContaining('直线·团'), findsOneWidget);

      // 重新打开：复选状态保留；切回星形。
      await tester.tap(find.byKey(const ValueKey('nl-settings-button')));
      await tester.pumpAndSettle();
      expect(mirrorTile().value, isTrue);
      expect(swapTile().value, isTrue);
      await tester.tap(find.byKey(const ValueKey('nl-settings-star')));
      await tester.pumpAndSettle();
      // 关闭一个布线优化选项：状态更新（并撤销已采纳的布线优化，重建模型）。
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-route-swap-l')),
      );
      await tester.tap(find.byKey(const ValueKey('nl-settings-route-swap-l')));
      await tester.pumpAndSettle();
      expect(routeTile('swap-l').value, isFalse);
      await tester.ensureVisible(
        find.byKey(const ValueKey('nl-settings-route-swap-l')),
      );
      await tester.tap(find.byKey(const ValueKey('nl-settings-route-swap-l')));
      await tester.pumpAndSettle();
      expect(routeTile('swap-l').value, isTrue);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.textContaining('直线·星形'), findsOneWidget);
    });
    testWidgets('设置：分层布局默认关闭，开关可切换重建模型', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('压缩列'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nl-settings-button')));
      await tester.pumpAndSettle();
      final layered = find.byKey(const ValueKey('nl-settings-layered'));
      await tester.ensureVisible(layered);
      expect(tester.widget<CheckboxListTile>(layered).value, isFalse);
      await tester.tap(layered);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(layered).value, isTrue);
      expect(find.textContaining('分层列'), findsOneWidget);

      await tester.tap(layered);
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(layered).value,
        isFalse,
        reason: '关闭后回退经典压缩',
      );
      expect(find.textContaining('压缩列'), findsOneWidget);
    });

    testWidgets('优化布局：右上角浮层显示模块数/端点数与总直线长度并完成', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async =>
            SchNetlistResult(
              success: true,
              netlist: _fakeNetlist(),
              topModule: 'isp_ip_eq_core',
              log: 'fake 提取日志\n',
            ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-optimize-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('nl-layout-progress')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('nl-optimize-button')));
      await tester.pump();
      expect(find.text('布局优化中'), findsOneWidget);
      expect(find.textContaining('模块数'), findsOneWidget);
      expect(find.textContaining('端点数'), findsOneWidget);
      expect(find.textContaining('总直线长度'), findsOneWidget);
      expect(find.textContaining('用时'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('布局优化完成'), findsOneWidget);
      expect(find.textContaining('模块数'), findsOneWidget);
      expect(find.textContaining('端点数'), findsOneWidget);
      expect(find.textContaining('总直线长度'), findsOneWidget);
      expect(find.textContaining('用时'), findsOneWidget, reason: '完成后保留最终用时');
      // 浮层可关闭。
      await tester.tap(find.byKey(const ValueKey('nl-layout-progress-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nl-layout-progress')), findsNothing);
    });

    testWidgets('浅色配色下优化浮层文字为深色可读', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async =>
            SchNetlistResult(
              success: true,
              netlist: _fakeNetlist(),
              topModule: 'isp_ip_eq_core',
              log: 'fake 提取日志\n',
            ),
      );
      await tester.pump();
      await tester.pump();
      // 切到 Vivado 浅色配色（白底浮层上白色文字会看不见）。
      await tester.tap(find.byTooltip('切换浅色配色（Vivado 风格）'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('nl-optimize-button')));
      await tester.pumpAndSettle();
      expect(find.text('布局优化完成'), findsOneWidget);
      final title = tester.widget<Text>(find.text('布局优化完成'));
      expect(title.style?.color, const Color(0xFF1A1A1A), reason: '浅色模式标题应为深色');
      final body = tester.widget<Text>(find.textContaining('模块数'));
      expect(body.style?.color, const Color(0xFF3C3C3C), reason: '浅色模式正文应为深色');

      // 布线优化浮层同一配色口径（自动布线已合并布线优化为单按钮）。
      await tester.tap(find.byKey(const ValueKey('nl-autoroute-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 20));
      expect(find.byKey(const ValueKey('nl-routing-progress')), findsOneWidget);
      final routingBody = tester.widget<Text>(find.textContaining('交叉点'));
      expect(routingBody.style?.color, const Color(0xFF3C3C3C));
    });

    testWidgets('连续缩小：缩放持续生效不锁死（z 轴同步缩放）', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      double scale() => tester
          .widget<NetlistDiagram>(find.byType(NetlistDiagram))
          .controller!
          .value
          .getMaxScaleOnAxis();
      final s0 = scale();
      // 回归：z 轴未同步时 getMaxScaleOnAxis 读回 1.0，缩放锁死在 0.8、
      // 只剩平移漂移（画布向右下角移动）。
      await tester.tap(find.byTooltip('Zoom Out'));
      await tester.pump();
      final s1 = scale();
      expect(s1, closeTo(s0 * 0.8, 0.01));
      await tester.tap(find.byTooltip('Zoom Out'));
      await tester.pump();
      final s2 = scale();
      expect(s2, closeTo(s1 * 0.8, 0.01), reason: '第二次缩小必须继续变小');
      await tester.tap(find.byTooltip('Zoom Out'));
      await tester.pump();
      expect(scale(), closeTo(s2 * 0.8, 0.01), reason: '第三次缩小必须继续变小');
    });

    testWidgets('工具栏热力图：叠加走线密度层并可关闭', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('nl-heatmap-layer')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nl-heatmap-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-heatmap-layer')), findsOneWidget);
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter);
      expect(
        painters.any((p) => p is NetlistHeatmapPainter),
        isTrue,
        reason: '开启后应叠加密度热力图层',
      );

      await tester.tap(find.byKey(const ValueKey('nl-heatmap-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-heatmap-layer')), findsNothing);
    });

    testWidgets('工具栏走线诊断：叠加诊断层并显示指标面板', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('nl-diagnostics-layer')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nl-diagnostics-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-diagnostics-layer')), findsOneWidget);
      expect(find.byKey(const ValueKey('nl-diagnostics-panel')), findsOneWidget);
      final diagRect = tester.getRect(
        find.byKey(const ValueKey('nl-diagnostics-panel')),
      );
      expect(diagRect.width, 236, reason: '诊断窗与优化窗等宽');
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter);
      expect(
        painters.any((p) => p is NetlistDiagnosticPainter),
        isTrue,
        reason: '开启后应叠加交叉/长尾网诊断层',
      );
      expect(find.textContaining('交叉'), findsWidgets);

      // 打开布局优化：诊断窗移到信息窗左侧，顶部对齐、间距 8。
      await tester.tap(find.byKey(const ValueKey('nl-optimize-button')));
      await tester.pumpAndSettle();
      final layoutRect = tester.getRect(
        find.byKey(const ValueKey('nl-layout-progress')),
      );
      final diagWithLayout = tester.getRect(
        find.byKey(const ValueKey('nl-diagnostics-panel')),
      );
      expect(layoutRect.width, 236);
      expect(diagWithLayout.top, closeTo(layoutRect.top, 0.01));
      expect(diagWithLayout.right, closeTo(layoutRect.left - 8, 0.01));

      // 关闭布局优化：诊断窗自动回到右上。
      await tester.tap(find.byKey(const ValueKey('nl-layout-progress-close')));
      await tester.pumpAndSettle();
      final moved = tester.getRect(
        find.byKey(const ValueKey('nl-diagnostics-panel')),
      );
      expect(moved.right, greaterThan(diagWithLayout.right));

      await tester.tap(find.byKey(const ValueKey('nl-diagnostics-close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-diagnostics-layer')), findsNothing);
      expect(find.byKey(const ValueKey('nl-diagnostics-panel')), findsNothing);
    });

    testWidgets('右侧信息窗：布局在上、布线在下，关闭布局后布线上移', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();

      // 先跑自动布线：布线窗独占右上。
      await tester.tap(find.byKey(const ValueKey('nl-autoroute-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 20));
      final routing0 = tester.getRect(
        find.byKey(const ValueKey('nl-routing-progress')),
      );
      expect(routing0.width, 236);

      // 再开布局优化：布局窗在上，布线窗下移。
      await tester.tap(find.byKey(const ValueKey('nl-optimize-button')));
      await tester.pumpAndSettle();
      final layout = tester.getRect(
        find.byKey(const ValueKey('nl-layout-progress')),
      );
      final routing = tester.getRect(
        find.byKey(const ValueKey('nl-routing-progress')),
      );
      expect(layout.top, lessThan(routing.top));
      expect(layout.right, closeTo(routing.right, 0.01));
      expect(layout.width, routing.width);
      expect(routing.top, closeTo(layout.bottom + 8, 0.01));

      // 关闭布局：布线窗自动回到右上（与最初位置一致）。
      await tester.tap(find.byKey(const ValueKey('nl-layout-progress-close')));
      await tester.pumpAndSettle();
      final routingMoved = tester.getRect(
        find.byKey(const ValueKey('nl-routing-progress')),
      );
      expect(routingMoved.top, closeTo(routing0.top, 0.01));
    });

    testWidgets('编辑模式：拖动元件事务重布并可撤销', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nl-edit-button')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('nl-manual-progress')),
        findsOneWidget,
        reason: '进入编辑模式应自动显示手动布局优化窗',
      );
      expect(
        find.byKey(const ValueKey('nl-learn-layout')),
        findsOneWidget,
        reason: '手动布局窗应提供学习入口',
      );
      final diagram = tester.widget<NetlistDiagram>(
        find.byType(NetlistDiagram),
      );
      expect(diagram.editMode, isTrue);
      expect(
        diagram.straightDashed,
        isTrue,
        reason: '编辑模式下直线预览应显示为虚线',
      );
      final block = diagram.model.blocks.firstWhere(
        (b) => !b.isIo && b.boxSize.height > 0,
      );
      final beforeDy = block.boxOrigin.dy;
      diagram.onBlockDragStart!(block);
      nlShiftBlock(block, 30);
      diagram.onBlockDragEnd!(block, 0, 30);
      await tester.pumpAndSettle();
      expect(block.boxOrigin.dy, beforeDy + 30);
      expect(
        tester.widget<NetlistDiagram>(find.byType(NetlistDiagram)).autoRoutes,
        isNull,
        reason: '直线预览下移动元件不应自动进入布线状态',
      );
      await tester.tap(find.byKey(const ValueKey('nl-edit-undo')));
      await tester.pumpAndSettle();
      expect(block.boxOrigin.dy, beforeDy);
    });

    testWidgets('编辑模式：端口上下拖动并可撤销', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nl-edit-button')));
      await tester.pump();
      final diagram = tester.widget<NetlistDiagram>(
        find.byType(NetlistDiagram),
      );
      final port = diagram.model.flattened().first.ports.first;
      final before = port.pos.dy;
      diagram.onPortDragStart!(port);
      nlShiftPin(port, 30);
      diagram.onPortDragEnd!(port, 30);
      await tester.pumpAndSettle();
      expect(port.pos.dy, before + 30, reason: '拖过相邻端口后交换槽位');
      await tester.tap(find.byKey(const ValueKey('nl-edit-undo')));
      await tester.pumpAndSettle();
      expect(port.pos.dy, before);
    });

    testWidgets('编辑模式：右键镜像元件并可撤销', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nl-edit-button')));
      await tester.pump();
      final diagram = tester.widget<NetlistDiagram>(
        find.byType(NetlistDiagram),
      );
      final block = diagram.model.blocks.firstWhere(
        (b) => !b.isIo && b.boxSize.height > 0,
      );
      final before = block.pinFlip;
      diagram.onMirrorBlock!(block);
      await tester.pumpAndSettle();
      expect(block.pinFlip, !before);
      await tester.tap(find.byKey(const ValueKey('nl-edit-undo')));
      await tester.pumpAndSettle();
      expect(block.pinFlip, before);
    });

    testWidgets('编辑模式：拖动引脚调整顺序并可撤销', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nl-edit-button')));
      await tester.pump();
      final diagram = tester.widget<NetlistDiagram>(
        find.byType(NetlistDiagram),
      );
      NlBlock? block;
      NlPin? pin;
      for (final b in diagram.model.blocks) {
        if (b.isIo) continue;
        if (b.ins.length >= 2) {
          block = b;
          pin = b.ins.first;
          break;
        }
      }
      expect(block, isNotNull);
      diagram.onPinDragStart!(block!, pin!);
      nlShiftPin(pin, 30);
      diagram.onPinDragEnd!(block, pin, 30);
      await tester.pumpAndSettle();
      expect(
        block.inPinOrder != null ||
            block.outPinOrder != null ||
            block.topPinOrder != null ||
            block.bottomPinOrder != null,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('nl-edit-undo')));
      await tester.pumpAndSettle();
      expect(
        block.inPinOrder == null &&
            block.outPinOrder == null &&
            block.topPinOrder == null &&
            block.bottomPinOrder == null,
        isTrue,
      );
    });

    testWidgets('热力图使用自动布线结果，而不是直线预览', (tester) async {
      final core = _fakeNetlist().module('isp_ip_eq_core')!;
      final model = buildNetlistDiagramModel(core);
      final wire = model.wires.first;
      final routes = <NlWire, List<(Offset, Offset)>>{
        wire: [
          (const Offset(0, 0), const Offset(300, 0)),
          (const Offset(300, 0), const Offset(300, 300)),
        ],
      };
      Widget build(Map<NlWire, List<(Offset, Offset)>>? autoRoutes) =>
          MaterialApp(
            home: Scaffold(
              body: NetlistDiagram(
                model: model,
                heatmap: true,
                autoRoutes: autoRoutes,
              ),
            ),
          );
      NetlistHeatmapPainter heatmapPainter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<NetlistHeatmapPainter>()
          .single;

      await tester.pumpWidget(build(routes));
      final routedValues = List<double>.of(heatmapPainter().heatmap.values);
      await tester.pumpWidget(build(null));
      final straightValues = List<double>.of(heatmapPainter().heatmap.values);
      expect(routedValues, isNot(equals(straightValues)));
    });
    testWidgets('工具栏查看网表：弹窗显示模块网表并可关闭', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-netlist-button')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nl-netlist-button')));
      await tester.pumpAndSettle();
      expect(find.text('查看网表'), findsOneWidget);
      expect(find.textContaining('module isp_ip_eq_top'), findsOneWidget);
      expect(find.byTooltip('复制网表'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('查看网表'), findsNothing);
    });
    testWidgets('工具栏自动布线：生成布线并自动优化（合并单按钮）', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      // 独立的「自动优化布线」按钮已移除，功能并入「自动布线」。
      expect(
        find.byKey(const ValueKey('nl-optimize-routing-button')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('nl-autoroute-button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nl-autoroute-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 20));

      final diagram = tester.widget<NetlistDiagram>(
        find.byType(NetlistDiagram),
      );
      expect(diagram.autoRoutes, isNotNull);
      expect(diagram.autoRoutes, isNotEmpty);
      expect(find.byType(SnackBar), findsOneWidget);
    });
    testWidgets('自动布线不会关闭布局优化浮层', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async =>
            SchNetlistResult(
              success: true,
              netlist: _fakeNetlist(),
              topModule: 'isp_ip_eq_core',
              log: 'fake 提取日志\n',
            ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nl-optimize-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nl-layout-progress')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nl-autoroute-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 20));
      expect(
        find.byKey(const ValueKey('nl-layout-progress')),
        findsOneWidget,
        reason: '自动布线不应关闭布局优化窗',
      );
      expect(find.byKey(const ValueKey('nl-routing-progress')), findsOneWidget);
      expect(find.textContaining('用时'), findsWidgets);
      final layout = tester.getRect(
        find.byKey(const ValueKey('nl-layout-progress')),
      );
      final routing = tester.getRect(
        find.byKey(const ValueKey('nl-routing-progress')),
      );
      expect(layout.top, lessThan(routing.top));
      expect(layout.right, closeTo(routing.right, 0.01));
    });
    testWidgets('工具栏自动布线：生成正交走线并自动优化（单一功能）', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-autoroute-button')), findsOneWidget);
      expect(
        tester.widget<NetlistDiagram>(find.byType(NetlistDiagram)).autoRoutes,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('nl-autoroute-button')));
      // 自动布线后自动进入布线优化（合并单按钮），等两阶段全部完成。
      await tester.pumpAndSettle(const Duration(milliseconds: 20));
      final routed = tester.widget<NetlistDiagram>(find.byType(NetlistDiagram));
      expect(routed.autoRoutes, isNotNull);
      expect(routed.autoRoutes, isNotEmpty);
      expect(routed.autoJunctions, isNotNull);
      final wirePainter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<NetlistWirePainter>()
          .first;
      expect(wirePainter.autoRoutes, isNotNull, reason: '绘制层应收到布线结果');

      // 单一功能：不再有「恢复直线预览」，再次点击 = 重新布线并优化。
      expect(find.byTooltip('恢复直线预览'), findsNothing);
      expect(find.byTooltip('自动布线'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nl-autoroute-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 20));
      expect(
        tester.widget<NetlistDiagram>(find.byType(NetlistDiagram)).autoRoutes,
        isNotNull,
        reason: '再次点击仍为布线结果（重新布线），不恢复直线预览',
      );
    });
    testWidgets('点实例块 ＋ 原位展开（容器内显示子模块），− 收起', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // 折叠态：实例块左上角是「＋」，仍是顶层模块。
      expect(find.textContaining('模块 isp_ip_eq_top'), findsOneWidget);
      expect(find.byKey(const ValueKey('nl-plus-u_core')), findsOneWidget);
      expect(find.byKey(const ValueKey('nl-minus-u_core')), findsNothing);
      // 展开态由模型层单测覆盖（见上），这里只校验页面对 ＋/− 存在性的渲染。
    });

    testWidgets('RTL 视图：实例块带 ＋（原位展开入口），信息区仍显示顶层模块', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(NetlistDiagram), findsOneWidget);
      expect(find.textContaining('模块 isp_ip_eq_top'), findsOneWidget);
      // 每个可展开的实例块都有 ＋ 入口（点击由 Listener 命中，见模型层单测）。
      expect(find.byKey(const ValueKey('nl-plus-u_core')), findsOneWidget);
    });

    testWidgets('默认 RTL 顶层网表：直接显示实例展开入口', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(NetlistDiagram), findsOneWidget);
      expect(find.textContaining('模块 isp_ip_eq_top'), findsOneWidget);
      expect(find.byKey(const ValueKey('nl-plus-u_core')), findsOneWidget);
    });

    testWidgets('浅色模式：实例展开按钮使用深蓝底白色符号', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('切换浅色配色（Vivado 风格）'));
      await tester.pump();
      final plusKey = find.byKey(const ValueKey('nl-plus-u_core'));
      expect(plusKey, findsOneWidget);
      final container = tester.widget<Container>(
        find.descendant(of: plusKey, matching: find.byType(Container)).first,
      );
      final icon = tester.widget<Icon>(
        find.descendant(of: plusKey, matching: find.byType(Icon)).first,
      );
      final decoration = container.decoration! as BoxDecoration;
      final border = decoration.border! as Border;
      expect(decoration.color, nlExpandLightFill);
      expect(border.top.color, nlExpandLightBorder);
      expect(icon.color, const Color(0xFFFFFFFF));
    });

    testWidgets('点 ＋ 就地展开成容器、点 − 收起（页面级真实交互）', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // ＋ 入口存在；用与页面同一份输入算出实例框内左上角 ＋ 的画布坐标。
      final plusKey = find.byKey(const ValueKey('nl-plus-u_core'));
      expect(plusKey, findsOneWidget);
      expect(find.byTooltip('展开实例'), findsOneWidget);
      Container buttonOf(Finder key) => tester.widget<Container>(
        find.descendant(of: key, matching: find.byType(Container)).first,
      );
      Icon iconOf(Finder key) => tester.widget<Icon>(
        find.descendant(of: key, matching: find.byType(Icon)).first,
      );
      void expectButtonStyle(Finder key, Color color) {
        final decoration = buttonOf(key).decoration! as BoxDecoration;
        final border = decoration.border! as Border;
        expect(buttonOf(key).alignment, Alignment.center);
        expect(tester.getSize(key), const Size(15, 15));
        expect(iconOf(key).size, 8, reason: '15px 按钮内的图标应保持居中');
        expect(border.top.color, color);
        expect(border.top.width, 0.5);
        expect(iconOf(key).color, color);
      }

      expectButtonStyle(plusKey, const Color(0xFFFFFFFF));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(plusKey));
      await tester.pump();
      expectButtonStyle(plusKey, SchPalette.dark.hover);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expectButtonStyle(plusKey, const Color(0xFFFFFFFF));
      final top = _fakeNetlist().module('isp_ip_eq_top')!;
      final ref = buildNetlistDiagramModel(top);
      final blk = ref.blocks.firstWhere((b) => !b.isIo && b.cell != null);
      final plusAt = blk.boxOrigin + const Offset(7.5, 7.5);
      // 驱动 Listener（画布那个 translucent 命中层，与鼠标同一入口）。
      final listener = tester
          .widgetList<Listener>(
            find.descendant(
              of: find.byType(NetlistDiagram),
              matching: find.byType(Listener),
            ),
          )
          .firstWhere(
            (l) =>
                l.onPointerDown != null &&
                l.behavior == HitTestBehavior.translucent,
          );
      listener.onPointerDown!(PointerDownEvent(position: plusAt));
      await tester.pump();
      final minusKey = find.byKey(const ValueKey('nl-minus-u_core'));
      expect(minusKey, findsOneWidget);
      expect(find.byTooltip('收起实例'), findsOneWidget);
      expectButtonStyle(minusKey, const Color(0xFFFFFFFF));
      await mouse.moveTo(tester.getCenter(minusKey));
      await tester.pump();
      expectButtonStyle(minusKey, SchPalette.dark.hover);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(find.textContaining('模块 isp_ip_eq_top'), findsOneWidget);
      expect(find.text('回顶层'), findsNothing);
      // 再驱动一次（− 在同一位置）→ 收起。
      listener.onPointerDown!(PointerDownEvent(position: plusAt));
      await tester.pump();
      expect(find.byKey(const ValueKey('nl-minus-u_core')), findsNothing);
      expect(find.byKey(const ValueKey('nl-plus-u_core')), findsOneWidget);
      await mouse.removePointer();
    });

    testWidgets('工具缺失显示安装提示（yosys）', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async =>
            const SchNetlistResult(
              success: false,
              log: '未检测到 yosys',
              missingTool: 'yosys',
            ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('未检测到 yosys'), findsOneWidget);
      // 日志面板强制展开（失败可排查）。
      expect(find.text('提取日志'), findsOneWidget);
    });

    testWidgets('提取失败显示错误与日志面板', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async =>
            const SchNetlistResult(success: false, log: 'yosys 失败（退出码 1）\n'),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('电路图提取失败'), findsOneWidget);
      expect(find.text('提取日志'), findsOneWidget);
    });

    testWidgets('编组解散后显示占位', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      state.ungroup(groupId);
      await tester.pump();
      expect(find.text('编组已被解散'), findsOneWidget);
    });

    testWidgets('编组变更过期提示：参数修改后显示，重新生成后消失', (tester) async {
      final (state, groupId) = makeGroup();
      addTearDown(state.dispose);
      await pumpTab(
        tester,
        state,
        groupId,
        renderer: (files, {required topName, onOutput}) async => _okResult(),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('可能已过期'), findsNothing);
      // 改参数 → 过期提示出现（selectNode 触发一次通知刷新）。
      final nodeId = state.graph.groups.single.nodeIds.single;
      state.graph.nodes[nodeId]!.paramValues['b0_h'] = 123.0;
      state.selectNode(nodeId);
      await tester.pump();
      expect(find.textContaining('可能已过期'), findsOneWidget);
      // 重新生成 → 提示消失。
      await tester.tap(find.text('重新生成').last);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('可能已过期'), findsNothing);
    });
  });

  group('视图缩放与自适应', () {
    test('框图初始自适应 + 缩放按钮', () async {
      final vp = const Size(800, 600);
      final content = const Size(1600, 1200);
      final ctrl = TransformationController();
      addTearDown(ctrl.dispose);
      schFitView(ctrl, vp, content);
      final s = ctrl.value.getMaxScaleOnAxis();
      expect(s, closeTo(0.5, 0.01));
      final t = ctrl.value.getTranslation();
      expect(t.x, closeTo(0, 1));
      expect(t.y, closeTo(0, 1));
    });

    test('schFitView：极端长宽比内容按宽适配顶对齐（不缩到不可见）', () {
      final ctrl = TransformationController();
      addTearDown(ctrl.dispose);
      schFitView(ctrl, const Size(1000, 600), const Size(2000, 90000));
      final s = ctrl.value.getMaxScaleOnAxis();
      expect(s, greaterThanOrEqualTo(0.05));
      expect(ctrl.value.getTranslation().y, closeTo(12, 1));
    });
  });

  group('SVG 工具（自研导出复用）', () {
    test('parseSvgSize：解析根元素 width/height，缺失返回 null', () {
      expect(parseSvgSize('<svg width="120" height="60"></svg>')!.w, 120);
      expect(parseSvgSize('<svg viewBox="0 0 10 10"></svg>'), isNull);
    });

    test('rasterizeSvgPng：PNG 魔数 + 2 倍尺寸', () async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">'
          '<rect width="40" height="20" fill="#123456"/></svg>';
      final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(png.length, greaterThan(50));
    });
  });

  group('端到端提取（无 yosys 自动 skip）', () {
    test('多段色彩均衡器 IP 包 → 层级网表（顶层实例可下钻）', () async {
      final yosys = detectYosys();
      if (yosys == null) {
        markTestSkipped('未检测到 yosys（tools/yosys 或 PATH）');
        return;
      }
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
      final r = await extractSchematicNetlist(files, topName: top);
      expect(r.success, isTrue, reason: r.log);
      expect(r.netlist, isNotNull);
      final topMod = r.netlist!.module(top)!;
      expect(topMod.cells, hasLength(1));
      final inst = topMod.cells.single;
      expect(inst.isInstance, isTrue);
      expect(inst.moduleRef, isNotNull);
      // 下钻模块可取出且含 RTL 单元。
      final core = r.netlist!.resolveInstance(inst.type)!;
      expect(core.cells.length, greaterThan(20));
      // 自研布局模型可直接构建（画布有限、比例受控）。
      final model = buildNetlistDiagramModel(core);
      expect(model.canvasSize.width.isFinite, isTrue);
      final ratio = model.canvasSize.width / model.canvasSize.height;
      expect(ratio, lessThan(6.0), reason: '不应是 1:N 长条（实测 $ratio）');
      // 自研 SVG 可产出并被解析。
      final svg = buildNetlistSvg(model);
      expect(parseSvgSize(svg), isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
