// 一次性：对真实网表跑布局优化，输出前后总直线长度与预览图。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/ip_block_diagram.dart'
    show SchPalette;
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('layout optimizer snapshot', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final before = buildNetlistDiagramModel(core);
    final watch = Stopwatch()..start();
    final result = await optimizeNetlistLayout(
      core,
      onProgress: (_) {},
    );
    watch.stop();
    // ignore: avoid_print
    print(
      'LEN ${result.initialLength.toStringAsFixed(1)} -> '
      '${result.length.toStringAsFixed(1)} '
      '(${((1 - result.length / result.initialLength) * 100).toStringAsFixed(1)}%) '
      'nodes=${result.nodes} evals=${result.evaluations} '
      'rounds=${result.rounds} improved=${result.improved} '
      'ms=${watch.elapsedMilliseconds}',
    );
    final watch2 = Stopwatch()..start();
    final withOptions = await optimizeNetlistLayout(
      core,
      allowMirror: true,
      swapPins: true,
    );
    watch2.stop();
    // ignore: avoid_print
    print(
      'OPTIONS LEN ${withOptions.initialLength.toStringAsFixed(1)} -> '
      '${withOptions.length.toStringAsFixed(1)} '
      '(${((1 - withOptions.length / withOptions.initialLength) * 100).toStringAsFixed(1)}%) '
      'evals=${withOptions.evaluations} rounds=${withOptions.rounds} '
      'ms=${watch2.elapsedMilliseconds}',
    );    final svg = buildNetlistSvg(result.model, palette: SchPalette.dark);
    File('scratch/nl_layout_optimized.svg').writeAsStringSync(svg);
    final png = await rasterizeSvgPng(utf8.encode(svg), scale: 2);
    File('scratch/nl_layout_optimized.png').writeAsBytesSync(png);
    final mirrored = buildNetlistDiagramModel(
      core,
      mirroredBlocks: {
        for (final b in before.blocks)
          if (!b.isIo) b.id,
      },
    );
    File(
      'scratch/nl_layout_mirrored.svg',
    ).writeAsStringSync(buildNetlistSvg(mirrored, palette: SchPalette.dark));
    await File('scratch/nl_layout_mirrored.png').writeAsBytes(
      await rasterizeSvgPng(
        utf8.encode(buildNetlistSvg(mirrored, palette: SchPalette.dark)),
      ),
    );
    final beforePng = await rasterizeSvgPng(
      utf8.encode(buildNetlistSvg(before, palette: SchPalette.dark)),
      scale: 1,
    );
    File('scratch/nl_layout_before.png').writeAsBytesSync(beforePng);
  });
}
