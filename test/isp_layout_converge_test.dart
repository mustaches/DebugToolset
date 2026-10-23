import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/group_ip_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_symbols.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

/// 多段色彩均衡器 IP 的 yosys 提取顶层模块名（无 yosys 时为 null）。
String? _eqTopModule;

String get schematicEqTopModule => _eqTopModule ?? '';

/// 生成多段色彩均衡器 IP 包并经 yosys 提取层级网表（无 yosys 返回 null）。
Future<YosysNetlist?> extractEqNetlist() async {
  final yosys = detectYosys();
  if (yosys == null) return null;
  final state = IspStudioState();
  addTearDown(state.dispose);
  final mb = state.graph.addNode('multi_band_eq', 0, 0);
  state.graph.nodes[mb]!.paramValues['codegenMode'] = 'lut_fixed';
  state.graph.groups.add(IspNodeGroup('g1', {mb}, name: 'eq'));
  final files = buildGroupIpFiles(
    state.graph,
    state.graph.groups.single,
    const IpGenOptions(vendor: IpVendor.generic),
  );
  final top = schematicTopModule(files);
  final dir = await Directory.systemTemp.createTemp('isp_layout_test_');
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
  final r = await Process.run(yosys.exe, [
    '-q',
    '-p',
    'read_verilog ${sources.join(' ')}; '
        'hierarchy -top $top; proc; opt_clean; write_json net.json',
  ], workingDirectory: dir.path);
  if (r.exitCode != 0) return null;
  _eqTopModule = top;
  return YosysNetlist.parse(
    File('${dir.path}${Platform.pathSeparator}net.json').readAsStringSync(),
  );
}

void main() {
  test('真实网表：布局优化一次收敛（第二次运行零改善、单步移动枚举零改善）', () async {
    final nl = await extractEqNetlist();
    if (nl == null) {
      markTestSkipped('未检测到 yosys 或提取失败');
      return;
    }
    final core = nl.module(nl.module(schematicEqTopModule)!.cells.single.type)!;

    // 与用户操作同口径：32 单元核心模块、镜像+引脚交换开启、并行路径。
    final run1 = await optimizeNetlistLayout(
      core,
      allowMirror: true,
      swapPins: true,
      netlist: nl,
    );
    expect(run1.improved, isTrue, reason: '默认布局存在更优解');

    // 从第一次的结果继续跑第二次：必须零改善——一次运行就到达最终状态。
    // （回归：引脚交换候选曾按初始物理序生成，镜像翻转后该试的另一种
    // 排列永远不被生成，要跑第二次按新初始模型重算默认序才试到。）
    final run2 = await optimizeNetlistLayout(
      core,
      allowMirror: true,
      swapPins: true,
      initialRowOrders: run1.rowOrders,
      initialMirroredBlocks: run1.mirroredBlocks,
      initialPinOrders: run1.pinOrders,
      netlist: nl,
    );
    expect(run2.improved, isFalse, reason: '第二次运行不应再找到改善');
    expect(run2.length, closeTo(run1.length, 0.01));

    // 不动点性质：枚举最终方案的全部单步移动（行序/引脚交换/镜像），
    // 均不得更优（>0.5）。
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
        core,
        rowOrders: o,
        pinOrders: p,
        mirroredBlocks: m,
      ),
    );
    final base = lengthOf(plan, pinPlan, mirrored);
    expect(base, closeTo(run1.length, 0.01), reason: '方案重建应与结果一致');

    var found = 0;
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
          final l = lengthOf({...plan, e.key: candidate}, pinPlan, mirrored);
          if (l < base - 0.5) {
            found++;
            fail('行序仍可改善: col=${e.key} 移动 $id $from→$to: $base → $l');
          }
        }
      }
    }
    for (final b in run1.model.blocks) {
      if (b.isIo) continue;
      final side = [
        for (final p in b.ins)
          if (!netlistSymbolIsBottomPin(b.cell, p.port)) p,
      ]..sort((a, c) => a.edge.dy.compareTo(c.edge.dy));
      if (side.length >= 2) {
        final order = [for (final p in side) p.display];
        for (var i = 0; i < order.length; i++) {
          for (var j = i + 1; j < order.length; j++) {
            final candidate = [...order];
            final t = candidate[i];
            candidate[i] = candidate[j];
            candidate[j] = t;
            final l = lengthOf(plan, {...pinPlan, b.id: candidate}, mirrored);
            if (l < base - 0.5) {
              found++;
              fail('引脚仍可改善: ${b.id} 交换 ${order[i]}↔${order[j]}: $base → $l');
            }
          }
        }
      }
      if (b.ins.length + b.outs.length >= 2) {
        final m2 = {...mirrored};
        if (!m2.remove(b.id)) m2.add(b.id);
        final l = lengthOf(plan, pinPlan, m2);
        if (l < base - 0.5) {
          found++;
          fail('镜像仍可改善: ${b.id}: $base → $l');
        }
      }
    }
    expect(found, 0, reason: '一次运行后任何单步移动都不应再更优');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('真实网表：允许全局重排可跨列移动且显著更优', () async {
    final nl = await extractEqNetlist();
    if (nl == null) {
      markTestSkipped('未检测到 yosys 或提取失败');
      return;
    }
    final core = nl.module(nl.module(schematicEqTopModule)!.cells.single.type)!;
    final plain = await optimizeNetlistLayout(
      core,
      allowMirror: true,
      swapPins: true,
      netlist: nl,
    );
    final global = await optimizeNetlistLayout(
      core,
      allowMirror: true,
      swapPins: true,
      allowGlobalReorder: true,
      netlist: nl,
    );
    expect(
      global.length,
      lessThan(plain.length),
      reason: '层级压缩的大图里跨列移动有真实收益（实测 −20%）',
    );
    // 至少有块离开了 BFS 原始列。
    final baseCol = {
      for (final b in buildNetlistDiagramModel(core).blocks) b.id: b.column,
    };
    final moved = [
      for (final b in global.model.blocks)
        if (!b.isIo && baseCol[b.id] != b.column) b,
    ];
    expect(moved, isNotEmpty, reason: '应有元件被重排到其它列');
    // 从全局重排的结果继续跑第二次：必须零改善（新移动集合同样收敛）。
    final run2 = await optimizeNetlistLayout(
      core,
      allowMirror: true,
      swapPins: true,
      allowGlobalReorder: true,
      initialRowOrders: global.rowOrders,
      initialMirroredBlocks: global.mirroredBlocks,
      initialPinOrders: global.pinOrders,
      netlist: nl,
    );
    expect(run2.improved, isFalse, reason: '第二次运行不应再找到改善');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
