// 一次性：定位 gt274 与 mux4670 的实际走线重叠。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

List<(Offset, Offset)> segmentsOf(NlWire w) => [
  ...w.segments,
  (w.from.edge, w.from.pos),
  for (final load in w.loads) (load.edge, load.pos),
];

List<String> overlaps(List<NlWire> wires) {
  final out = <String>[];
  for (var i = 0; i < wires.length; i++) {
    for (var j = i + 1; j < wires.length; j++) {
      final a = wires[i], b = wires[j];
      for (final (p, q) in segmentsOf(a)) {
        for (final (r, s) in segmentsOf(b)) {
          final ah = (p.dy - q.dy).abs() < 0.01;
          final bh = (r.dy - s.dy).abs() < 0.01;
          if (ah != bh) continue;
          final axisA = ah ? p.dy : p.dx;
          final axisB = ah ? r.dy : r.dx;
          if ((axisA - axisB).abs() >= 10.0) continue;
          final alo = ah ? math.min(p.dx, q.dx) : math.min(p.dy, q.dy);
          final ahi = ah ? math.max(p.dx, q.dx) : math.max(p.dy, q.dy);
          final blo = ah ? math.min(r.dx, s.dx) : math.min(r.dy, s.dy);
          final bhi = ah ? math.max(r.dx, s.dx) : math.max(r.dy, s.dy);
          if (alo < bhi - 0.01 && blo < ahi - 0.01) {
            out.add(
              '${a.from.ownerTitle}/${a.from.port} ${a.label} '
              'vs ${b.from.ownerTitle}/${b.from.port} ${b.label} '
              '${ah ? 'H' : 'V'} axis=$axisA '
              'A=(${p.dx},${p.dy})-(${q.dx},${q.dy}) '
              'B=(${r.dx},${r.dy})-(${s.dx},${s.dy})',
            );
          }
        }
      }
    }
  }
  return out;
}

void main() {
  test('diagnose gt274 and mux4670 overlap', () {
    final files = Directory('scratch/ip_sch')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('net.json'));
    for (final file in files) {
      final nl = YosysNetlist.parse(file.readAsStringSync());
      for (final core in nl.modules.values.where((m) => m.cells.length > 5)) {
        final model = buildNetlistDiagramModel(core);
        final bad = overlaps(model.wires);
        print('MODEL ${file.path} ${core.name} OVERLAP_COUNT=${bad.length}');
        for (final w in model.wires) {
          if (w.from.ownerTitle == 'gt274' ||
              w.from.ownerTitle == 'mux4670' ||
              w.from.ownerTitle == 'adff4692' ||
              w.from.ownerTitle == 'mux4681' ||
              w.from.ownerTitle == 'mux274') {
            print(
              'TARGET ${w.from.ownerTitle}/${w.from.port} ${w.label} '
              'bits=${w.bits.length} bus=${w.isBus}',
            );
            for (final (a, b) in w.segments) {
              print('  (${a.dx},${a.dy}) -> (${b.dx},${b.dy})');
            }
          }
        }
        for (final s in bad) {
          print(s);
        }
      }
    }
  });
}
