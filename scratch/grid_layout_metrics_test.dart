// 一次性：输出 Grid 版真实网表/长链指标与预览图。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('grid layout metrics and previews', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final watch = Stopwatch()..start();
    final real = await startNetlistDiagramModelOptimization(
      core,
      onProgress: (_) {},
    ).result;
    watch.stop();
    double length(NlWire w) =>
        w.segments.fold(0.0, (sum, s) => sum + (s.$2 - s.$1).distance);
    final total = real.wires.fold<double>(0, (sum, w) => sum + length(w));
    print(
      'REAL size=${real.canvasSize} tracks=${real.trackCount} '
      'zLoads=${real.zLoadCount} trackLoads=${real.trackLoadCount} '
      'length=${total.toStringAsFixed(1)} wires=${real.wires.length} '
      'cross=${real.crossingCount} bends=${nlRoutingBendCount(real)} '
      'rounds=${real.optimizationRounds} '
      'evals=${real.optimizationEvaluations} converged=${real.optimizationConverged} '
      'variants=${real.optimizationVariants.length} '
      'elapsedMs=${watch.elapsedMilliseconds}',
    );
    for (final b in real.blocks.where((b) => b.title.contains('4687'))) {
      print(
        'ADFF ${b.title} origin=${b.boxOrigin} size=${b.boxSize} '
        '${b.ins.map((p) => '${p.port}:${p.edge}->${p.pos}').join(' | ')}',
      );
    }
    final gt = real.blocks.firstWhere((b) => b.title == 'gt246');
    for (final b in real.blocks.where((b) => b.column == gt.column)) {
      print(
        'COL ${b.title} col=${b.column} row=${b.row} '
        'origin=${b.origin} size=${b.size} box=${b.boxOrigin}/${b.boxSize}',
      );
    }
    for (final b in real.blocks) {
      for (final p in [...b.ins, ...b.outs]) {
        if ((p.pos.dy == 650 || p.pos.dy == 670) && p.pos.dx <= 440) {
          print(
            'ROW_PIN ${b.title}/${p.port} edge=${p.edge} pos=${p.pos} '
            'box=${b.boxOrigin}/${b.boxSize}',
          );
        }
      }
    }
    for (final w in real.wires.where(
      (w) => w.loads.any((l) => l.ownerTitle.contains('4687')),
    )) {
      print('WIRE ${w.label} from=${w.from.ownerTitle}/${w.from.port}');
      for (final (a, b) in [...nlWirePinStubs(w), ...w.segments]) {
        print('  ($a) -> ($b)');
      }
    }
    final realSvg = buildNetlistSvg(real);
    File('scratch/ip_sch/grid_preview.svg').writeAsStringSync(realSvg);
    final realPng = await rasterizeSvgPng(utf8.encode(realSvg));
    File('scratch/ip_sch/grid_preview.png').writeAsBytesSync(realPng);

    // Phase 1 基线快照：诊断指标 JSON + 诊断叠加层预览。
    final diag = computeNetlistRoutingDiagnostics(real);
    final s = diag.toJson()['summary'] as Map<String, Object>;
    print(
      'DIAG wires=${s['wires']} crossings=${s['crossings']} '
      'totalBends=${s['totalBends']} bendMean=${s['bendMean']} '
      'bendP95=${s['bendP95']} bendMax=${s['bendMax']} '
      'longest=${s['longest']} parallelPairs=${s['parallelSegmentPairs']} '
      'heatCells=${diag.heatCells.length}',
    );
    for (final w in diag.wires.take(8)) {
      print(
        'DIAGWIRE ${w.label} bends=${w.bends} len=${w.length.round()} '
        'cross=${w.crossings} loads=${w.loadCount} trackLoads=${w.trackLoads}',
      );
    }
    for (final w in real.wires.where((w) => w.label.isEmpty)) {
      print(
        'UNNAMED from=${w.from.ownerTitle}/${w.from.port}@col? '
        'loads=${w.loads.map((l) => '${l.ownerTitle}/${l.port}').join(',')}',
      );
    }
    const jsonEncoder = JsonEncoder.withIndent('  ');
    File(
      'scratch/ip_sch/grid_metrics.json',
    ).writeAsStringSync(jsonEncoder.convert(diag.toJson()));
    final diagSvg = buildNetlistSvg(
      real,
      diagnosticOverlay: buildNetlistRoutingDiagnosticOverlay(real),
    );
    File(
      'scratch/ip_sch/grid_preview_diag.svg',
    ).writeAsStringSync(diagSvg);
    final diagPng = await rasterizeSvgPng(utf8.encode(diagSvg));
    File('scratch/ip_sch/grid_preview_diag.png').writeAsBytesSync(diagPng);

    final top = nl.modules.values.firstWhere(
      (m) => m.cells.length == 1 && m.cells.single.isInstance,
    );
    final topModel = buildNetlistDiagramModel(top);
    print('TOP size=${topModel.canvasSize} wires=${topModel.wires.length}');
    final topSvg = buildNetlistSvg(topModel);
    File('scratch/ip_sch/grid_top_preview.svg').writeAsStringSync(topSvg);
    final topPng = await rasterizeSvgPng(utf8.encode(topSvg));
    File('scratch/ip_sch/grid_top_preview.png').writeAsBytesSync(topPng);

    final cells = <String, Object>{};
    final nets = <String, Object>{};
    for (var i = 0; i < 20; i++) {
      cells['not$i'] = {
        'type': r'$not',
        'parameters': <String, Object>{},
        'connections': {
          'A': [i == 0 ? 100 : 200 + i - 1],
          'Y': [200 + i],
        },
      };
      nets['s$i'] = {
        'bits': [200 + i],
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
    final long = buildNetlistDiagramModel(
      YosysNetlist.parse(json).module('m')!,
    );
    print(
      'LONG size=${long.canvasSize} '
      'ratio=${(long.canvasSize.width / long.canvasSize.height).toStringAsFixed(3)} '
      'tracks=${long.trackCount} zLoads=${long.zLoadCount} '
      'trackLoads=${long.trackLoadCount}',
    );
    final longSvg = buildNetlistSvg(long);
    File('scratch/ip_sch/grid_long_chain.svg').writeAsStringSync(longSvg);
    final longPng = await rasterizeSvgPng(utf8.encode(longSvg));
    File('scratch/ip_sch/grid_long_chain.png').writeAsBytesSync(longPng);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
