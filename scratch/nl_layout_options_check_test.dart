// 一次性：验证「镜像元件」「引脚交换」对模型/优化结果的实际影响。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('mirror + pin swap effect', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);

    final normal = buildNetlistDiagramModel(core);
    final mirrored = buildNetlistDiagramModel(
      core,
      mirroredBlocks: {
        for (final b in normal.blocks)
          if (!b.isIo) b.id,
      },
    );
    // ignore: avoid_print
    print(
      'MIRROR len ${nlStraightLength(normal).toStringAsFixed(1)} -> '
      '${nlStraightLength(mirrored).toStringAsFixed(1)}',
    );

    // 统计输入针脚上下顺序发生变化的块数。
    var flipped = 0;
    for (final b in normal.blocks) {
      if (b.isIo) continue;
      final mb = mirrored.blocks.firstWhere((x) => x.id == b.id);
      final a = [
        for (final p in b.ins) p.port,
      ];
      final c = [
        for (final p in mb.ins) p.port,
      ];
      final byYNormal = [...b.ins]
        ..sort((x, y) => x.edge.dy.compareTo(y.edge.dy));
      final byYMirror = [...mb.ins]
        ..sort((x, y) => x.edge.dy.compareTo(y.edge.dy));
      final normalOrder = [for (final p in byYNormal) p.port];
      final mirrorOrder = [for (final p in byYMirror) p.port];
      if (normalOrder.join(',') != mirrorOrder.join(',')) flipped++;
      if (a.isEmpty && c.isEmpty) continue;
    }
    // ignore: avoid_print
    print('MIRROR flipped blocks=$flipped');

    final noSwap = await optimizeNetlistLayout(core);
    final mirrorOnly = await optimizeNetlistLayout(core, allowMirror: true);
    // ignore: avoid_print
    print(
      'MIRROR-OPT len ${noSwap.length.toStringAsFixed(1)} vs '
      '${mirrorOnly.length.toStringAsFixed(1)} '
      'mirrored=${mirrorOnly.mirroredBlocks.length} '
      'evals=${mirrorOnly.evaluations}',
    );
    final swap = await optimizeNetlistLayout(
      core,
      allowMirror: true,
      swapPins: true,
    );
    // ignore: avoid_print
    print(
      'SWAP len ${noSwap.length.toStringAsFixed(1)} vs '
      '${swap.length.toStringAsFixed(1)} '
      '(evals ${noSwap.evaluations} vs ${swap.evaluations})',
    );

    // 优化结果里相对默认布局发生输入槽位变化的块数。
    int changedPinBlocks(
      NetlistDiagramModel a,
      NetlistDiagramModel b,
    ) {
      var n = 0;
      for (final blk in a.blocks) {
        if (blk.isIo) continue;
        final bb = b.blocks.firstWhere((x) => x.id == blk.id);
        final oa = [for (final p in blk.ins) p.port]..sort();
        // 用 edge.y 排序得到视觉槽位顺序。
        final va = [...blk.ins]
          ..sort((x, y) => x.edge.dy.compareTo(y.edge.dy));
        final vb = [...bb.ins]
          ..sort((x, y) => x.edge.dy.compareTo(y.edge.dy));
        if ([for (final p in va) p.port].join(',') !=
            [for (final p in vb) p.port].join(',')) {
          n++;
        }
        if (oa.isEmpty) continue;
      }
      return n;
    }

    // ignore: avoid_print
    print(
      'SWAP changed pin blocks '
      '${changedPinBlocks(noSwap.model, swap.model)}',
    );
  });
}
