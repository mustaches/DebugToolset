// 一次性基线脚本（scratch，不参与静态分析）：
// 对真实 yosys 网表输出直线/正交两种形态的诊断 JSON + 诊断叠加图，
// 供布局/布线算法改动前后对比。运行：
//   flutter test scratch/netlist_metrics_baseline_test.dart
// 可选环境变量：
//   NL_METRICS_ROUTE=1  同时跑自动布线并输出 routed 诊断
//   NL_METRICS_PNG=1    同时输出 PNG（较慢）
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_routing_metrics.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_svg.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

const _netJson = 'scratch/ip_sch/isp_ip_eq6_axis/net.json';
const _outDir = 'scratch/ip_sch';

void main() {
  testWidgets('netlist metrics baseline', (tester) async {
    await tester.runAsync(() async {
      final file = File(_netJson);
      if (!file.existsSync()) {
        markTestSkipped('缺少 $_netJson');
        return;
      }
      final netlist = YosysNetlist.parse(file.readAsStringSync());
      final module = netlist.modules.values.firstWhere(
        (m) => m.cells.length > 5,
        orElse: () => netlist.modules.values.first,
      );
      final layoutName = Platform.environment['NL_METRICS_LAYOUT'] ?? 'compact';
      final layered = layoutName == 'layered';
      final suffix = layered ? '_layered' : '';
      final topo = Platform.environment['NL_METRICS_TOPO'] == 'star'
          ? NlNetTopology.star
          : NlNetTopology.clique;
      final topoSuffix = topo == NlNetTopology.star ? '_star' : '';
      final model = buildNetlistDiagramModel(
        module,
        layout: layered
            ? NlLayoutAlgorithm.layered
            : NlLayoutAlgorithm.compact,
        columns: int.tryParse(Platform.environment['NL_METRICS_COLS'] ?? ''),
      );
      final levels = model.flattened();
      print('LAYOUT $layoutName canvas=${model.canvasSize} topo=${topo.name}');

      _write(
        'straight$suffix$topoSuffix',
        computeNlRoutingDiagnostics(
          levels,
          model.canvasSize,
          topology: topo,
        ),
        model,
        topology: topo,
      );

      var routed = false;
      if (Platform.environment['NL_METRICS_ROUTE'] == '1') {
        final watch = Stopwatch()..start();
        final routes = routeNetlistWires(levels, model.canvasSize);
        watch.stop();
        print('ROUTE elapsedMs=${watch.elapsedMilliseconds} '
            'fallback=${routes.fallbackCount}');
        _write(
          'routed$suffix',
          computeNlRoutingDiagnostics(
            levels,
            model.canvasSize,
            routes: routes.segments,
            junctions: routes.junctions,
          ),
          model,
          autoRoutes: routes.segments,
          autoJunctions: routes.junctions,
        );
        routed = true;
      }

      if (Platform.environment['NL_METRICS_PNG'] == '1') {
        for (final name in [
          'straight$suffix$topoSuffix',
          if (routed) 'routed$suffix',
        ]) {
          final svg = File('$_outDir/routing_metrics_$name.svg')
              .readAsStringSync();
          final png = await rasterizeSvgPng(utf8.encode(svg), scale: 1);
          File('$_outDir/routing_metrics_$name.png').writeAsBytesSync(png);
        }
      }
    });
  });
}

void _write(
  String name,
  NlRoutingDiagnostics diag,
  NetlistDiagramModel model, {
  Map<NlWire, List<(Offset, Offset)>>? autoRoutes,
  Map<NlWire, List<Offset>>? autoJunctions,
  NlNetTopology topology = NlNetTopology.clique,
}) {
  final json = const JsonEncoder.withIndent('  ').convert(diag.toJson());
  File('$_outDir/routing_metrics_$name.json').writeAsStringSync(json);
  final svg = buildNetlistSvg(
    model,
    topology: topology,
    diagnosticOverlay: buildNlDiagnosticOverlaySvg(diag),
    autoRoutes: autoRoutes,
    autoJunctions: autoJunctions,
  );
  File('$_outDir/routing_metrics_$name.svg').writeAsStringSync(svg);
  print(
    '[$name] wires=${diag.wireCount} cross=${diag.crossings} '
    'bends=${diag.bends} p95=${diag.bendP95} max=${diag.bendMax} '
    'len=${diag.length.toStringAsFixed(0)} '
    'detour=${diag.detour?.toStringAsFixed(3) ?? '-'} '
    'parallel=${diag.parallelPairs} '
    'densityPeak=${diag.densityPeak.toStringAsFixed(2)} '
    'entropy=${diag.densityEntropy.toStringAsFixed(2)} '
    'align=${diag.portAlignmentRate.toStringAsFixed(2)} '
    'violations=${diag.violationCounts}',
  );
}
