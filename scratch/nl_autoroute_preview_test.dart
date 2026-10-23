// 一次性：真实网表自动布线约束自检与预览。
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_model.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/yosys_schematic.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/netlist_diagram.dart';

void main() {
  test('autoroute constraints + preview', () async {
    final nl = YosysNetlist.parse(
      File(
        'scratch/ip_sch/isp_ip_multi_band_eq_axis/net.json',
      ).readAsStringSync(),
    );
    final core = nl.modules.values.firstWhere((m) => m.cells.length > 5);
    final model = buildNetlistDiagramModel(core);
    final watch = Stopwatch()..start();
    final result = routeNetlistWires(model.flattened(), model.canvasSize);
    final optimized = await optimizeNetlistRouting(
      model.flattened(),
      model.canvasSize,
      initial: result,
    );
    watch.stop();
    final routes = optimized.result.segments;
    var segments = 0;
    var junctions = 0;
    for (final list in routes.values) {
      segments += list.length;
    }
    for (final list in optimized.result.junctions.values) {
      junctions += list.length;
    }
    for (final b in model.blocks) {
      if (b.title == 'mux4678') {
        // ignore: avoid_print
        print('MUX box=${b.boxOrigin} size=${b.boxSize}');
        for (final p in [...b.ins, ...b.outs]) {
          // ignore: avoid_print
          print('MUXPIN ${p.port} pos=${p.pos} edge=${p.edge}');
        }
      }
    }
    var tTouches = 0;
    final segs = routes.entries.toList();
    for (var i = 0; i < segs.length; i++) {
      for (var j = 0; j < segs.length; j++) {
        if (i == j) continue;
        for (final (a, b) in segs[i].value) {
          for (final p in [a, b]) {
            for (final (c, d) in segs[j].value) {
              if ((c.dy - d.dy).abs() < 0.01 &&
                  (p.dy - c.dy).abs() < 0.01 &&
                  p.dx > math.min(c.dx, d.dx) + 0.01 &&
                  p.dx < math.max(c.dx, d.dx) - 0.01) {
                tTouches++;
              }
              if ((c.dx - d.dx).abs() < 0.01 &&
                  (p.dx - c.dx).abs() < 0.01 &&
                  p.dy > math.min(c.dy, d.dy) + 0.01 &&
                  p.dy < math.max(c.dy, d.dy) - 0.01) {
                tTouches++;
              }
            }
          }
        }
      }
    }
    // ignore: avoid_print
    print('T_TOUCH=$tTouches');
    var dangling = 0;
    var split = 0;
    for (final wire in model.wires) {
      final segs = routes[wire] ?? const <(Offset, Offset)>[];
      final adj = <String, List<String>>{};
      String key(Offset p) => '${(p.dx * 100).round()},${(p.dy * 100).round()}';
      for (final (a, b) in segs) {
        (adj[key(a)] ??= []).add(key(b));
        (adj[key(b)] ??= []).add(key(a));
      }
      final pins = [wire.from, ...wire.loads].map((p) => key(p.pos)).toSet();
      final nodes = adj.keys.toSet();
      final seen = <String>{};
      final stack = <String>[];
      if (nodes.isNotEmpty) {
        stack.add(nodes.first);
        seen.add(nodes.first);
        while (stack.isNotEmpty) {
          for (final n in adj[stack.removeLast()] ?? const <String>[]) {
            if (seen.add(n)) stack.add(n);
          }
        }
      }
      if (pins.any((p) => !seen.contains(p))) split++;
      for (final e in adj.entries) {
        if (e.value.length == 1 && !pins.contains(e.key)) {
          dangling++;
          // ignore: avoid_print
          print('DANGLING "${wire.label}" ${e.key} segs=$segs');
        }
      }
    }
    // ignore: avoid_print
    print('WIRE split=$split dangling=$dangling');
    // ignore: avoid_print
    print(
      'OPT moved=${optimized.movedBlocks} cross=${optimized.initialCrossings}->${optimized.crossings} '
      'bends=${optimized.initialBends}->${optimized.bends}',
    );
    // ignore: avoid_print
    print(
      'ROUTES wires=${routes.length}/${model.wires.length} '
      'segments=$segments junctions=$junctions '
      'ms=${watch.elapsedMilliseconds} '
      'fallback=${optimized.result.fallbackCount} '
      'len=${optimized.initialLength.toStringAsFixed(0)}->'
      '${optimized.length.toStringAsFixed(0)}', 
    );

    String desc(NlWire w) =>
        '"${w.label}" ${w.from.ownerTitle}/${w.from.port} '
        'bits=${w.bits.length} loads=${w.loads.length}';

    var nonOrthogonal = 0;
    var overlaps = 0;
    final entries = routes.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      for (var j = i + 1; j < entries.length; j++) {
        for (final (a, b) in entries[i].value) {
          for (final (c, d) in entries[j].value) {
            final bothH =
                (a.dy - b.dy).abs() < 0.01 && (c.dy - d.dy).abs() < 0.01;
            final bothV =
                (a.dx - b.dx).abs() < 0.01 && (c.dx - d.dx).abs() < 0.01;
            final hOverlap = bothH &&
                (a.dy - c.dy).abs() < 0.01 &&
                math.min(a.dx, b.dx) < math.max(c.dx, d.dx) - 0.01 &&
                math.min(c.dx, d.dx) < math.max(a.dx, b.dx) - 0.01;
            final vOverlap = bothV &&
                (a.dx - c.dx).abs() < 0.01 &&
                math.min(a.dy, b.dy) < math.max(c.dy, d.dy) - 0.01 &&
                math.min(c.dy, d.dy) < math.max(a.dy, b.dy) - 0.01;
            if (hOverlap || vOverlap) {
              overlaps++;
              // ignore: avoid_print
              print(
                'OVERLAP ${hOverlap ? 'H' : 'V'} '
                '${desc(entries[i].key)} VS ${desc(entries[j].key)} '
                'A=($a)-($b) B=($c)-($d)',
              );
            }
          }
        }
      }
    }
    for (final list in routes.values) {
      for (final (a, b) in list) {
        if ((a.dx - b.dx).abs() > 0.01 && (a.dy - b.dy).abs() > 0.01) {
          nonOrthogonal++;
        }
      }
    }
    for (final wire in model.wires) {
      for (final p in [wire.from, ...wire.loads]) {
        if ((p.pos - const Offset(1350, 810)).distance < 0.01 ||
            (p.pos - const Offset(2040, 1020)).distance < 0.01 ||
            (p.pos - const Offset(1500, 1020)).distance < 0.01 ||
            (p.pos - const Offset(2025, 1230)).distance < 0.01) {
          // ignore: avoid_print
          print(
            'PIN at ${p.pos} owner=${p.ownerTitle}/${p.port} '
            'dir=${p.dir} wire="${wire.label}"',
          );
        }
      }
    }
    for (final wire in model.wires) {
      if (wire.from.ownerTitle == 'adff4687' || wire.label == 'n1_hsum') {
        // ignore: avoid_print
        print(
          'ID "${wire.label}" ${identityHashCode(wire)} '
          'from=${wire.from.pos} loads=${[for (final l in wire.loads) l.pos]}',
        );
      }
    }
    for (final wire in model.wires) {
      if (wire.from.ownerTitle == 'adff4687') {
        // ignore: avoid_print
        print('ADFF segments=${routes[wire]}');
      }
    }
    // 检查 pin 逃生段与其它网线段是否重叠。
    var escapeOverlaps = 0;
    for (final wire in model.wires) {
      final pins = [wire.from, ...wire.loads];
      for (final pin in pins) {
        final e = nlPinEscape(pin, 15);
        final segs = [(pin.pos, e)];
        for (final other in routes.entries) {
          if (identical(other.key, wire)) continue;
          for (final (a, b) in segs) {
            for (final (c, d) in other.value) {
              final bothH =
                  (a.dy - b.dy).abs() < 0.01 && (c.dy - d.dy).abs() < 0.01;
              final bothV =
                  (a.dx - b.dx).abs() < 0.01 && (c.dx - d.dx).abs() < 0.01;
              final hOverlap = bothH &&
                  (a.dy - c.dy).abs() < 0.01 &&
                  math.min(a.dx, b.dx) < math.max(c.dx, d.dx) - 0.01 &&
                  math.min(c.dx, d.dx) < math.max(a.dx, b.dx) - 0.01;
              final vOverlap = bothV &&
                  (a.dx - c.dx).abs() < 0.01 &&
                  math.min(a.dy, b.dy) < math.max(c.dy, d.dy) - 0.01 &&
                  math.min(c.dy, d.dy) < math.max(a.dy, b.dy) - 0.01;
              if (hOverlap || vOverlap) {
                escapeOverlaps++;
                // ignore: avoid_print
                print(
                  'ESCAPE OVERLAP "${wire.label}" pin=${pin.port} '
                  'seg=($a)-($b) VS "${other.key.label}"',
                );
              }
            }
          }
        }
      }
    }
    // ignore: avoid_print
    print('ESCAPE_OVERLAPS=$escapeOverlaps');
    // 折弯点重叠：不同网同坐标的折弯点。
    final bendsByWire = <NlWire, List<Offset>>{};
    for (final wire in model.wires) {
      final segs = routes[wire] ?? const <(Offset, Offset)>[];
      bendsByWire[wire] = nlRoutingBendPoints(
        segs,
        junctions: optimized.result.junctions[wire] ?? const [],
      );
    }
    for (final w in model.wires) {
      if (w.from.ownerTitle == 'adff4692' ||
          w.from.ownerTitle == '/in_sof') {
        // ignore: avoid_print
        print(
          'WIRE ${w.from.ownerTitle}/${w.from.port} from=${w.from.pos} '
          'segs=${routes[w]} bends=${bendsByWire[w]}',
        );
      }
    }
    var bendOverlaps = 0;
    final bendEntries = bendsByWire.entries.toList();
    for (var i = 0; i < bendEntries.length; i++) {
      for (var j = i + 1; j < bendEntries.length; j++) {
        for (final a in bendEntries[i].value) {
          for (final b in bendEntries[j].value) {
            if ((a - b).distance < 0.01) {
              bendOverlaps++;
              // ignore: avoid_print
              print(
                'BEND OVERLAP "${bendEntries[i].key.label}" '
                '${bendEntries[i].key.from.ownerTitle}/${bendEntries[i].key.from.port} vs '
                '"${bendEntries[j].key.label}" '
                '${bendEntries[j].key.from.ownerTitle}/${bendEntries[j].key.from.port} at $a', 
              );
            }
          }
        }
      }
    }
    // 元件覆盖：任何走线（含逃生段）与元件块矩形相交。
    var blockHits = 0;
    final rects = <Rect>[];
    for (final level in model.flattened()) {
      for (final b in level.blocks) {
        if (b.isIo) continue;
        rects.add(
          Rect.fromLTWH(
            b.boxOrigin.dx + level.offset.dx,
            b.boxOrigin.dy + level.offset.dy,
            b.boxSize.width,
            b.boxSize.height,
          ),
        );
      }
    }
    for (final level in model.flattened()) {
      for (final wire in level.wires) {
        for (final (a0, b0) in routes[wire] ?? const <(Offset, Offset)>[]) {
          final a = a0 + level.offset;
          final b = b0 + level.offset;
          for (final r in rects) {
            if ((a.dy - b.dy).abs() < 0.01) {
              if (a.dy >= r.top - 0.01 &&
                  a.dy <= r.bottom + 0.01 &&
                  math.min(a.dx, b.dx) <= r.right + 0.01 &&
                  math.max(a.dx, b.dx) >= r.left - 0.01) {
                blockHits++;
              }
            } else if (a.dx >= r.left - 0.01 &&
                a.dx <= r.right + 0.01 &&
                math.min(a.dy, b.dy) <= r.bottom + 0.01 &&
                math.max(a.dy, b.dy) >= r.top - 0.01) {
              blockHits++;
            }
          }
        }
      }
    }
    // ignore: avoid_print
    print(
      'FORCE bendOverlaps=$bendOverlaps blockHits=$blockHits',
    );
    var missingPinTouch = 0;
    var shortEscapes = 0;
    for (final wire in model.wires) {
      final list = routes[wire];
      if (list == null || list.isEmpty) {
        missingPinTouch++;
        // ignore: avoid_print
        print('NO TOUCH wire="${wire.label}"');
        continue;
      }
      bool touches(Offset p) => list.any(
        (s) => (s.$1 - p).distance < 0.01 || (s.$2 - p).distance < 0.01,
      );
      if (wire.from.port == 'clk') {
        // ignore: avoid_print
        print('CLK from=${wire.from.pos} segs=${routes[wire]}');
      }
      if (!touches(wire.from.pos)) {
        missingPinTouch++;
        // ignore: avoid_print
        print('NO FROM "${wire.label}" ${wire.from.ownerTitle}/${wire.from.port}');
      }
      for (final load in wire.loads) {
        if (!touches(load.pos)) {
          missingPinTouch++;
          // ignore: avoid_print
          print('NO LOAD "${wire.label}" ${load.ownerTitle}/${load.port}');
        }
      }
      for (final p in [wire.from, ...wire.loads]) {
        final near = list.where(
          (s) =>
              (s.$1 - p.pos).distance < 0.01 ||
              (s.$2 - p.pos).distance < 0.01,
        );
        if (near.isNotEmpty && (near.first.$2 - near.first.$1).distance < 14.9) {
          shortEscapes++;
        }
      }
    }
    // ignore: avoid_print
    print(
      'CHECK nonOrthogonal=$nonOrthogonal overlaps=$overlaps '
      'missingPinTouch=$missingPinTouch shortEscapes=$shortEscapes',
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & model.canvasSize,
      Paint()..color = const Color(0xFF1E1E1E),
    );
    for (final b in model.blocks.where((b) => !b.isIo)) {
      canvas.drawRect(
        Rect.fromLTWH(
          b.boxOrigin.dx,
          b.boxOrigin.dy,
          b.boxSize.width,
          b.boxSize.height,
        ),
        Paint()..color = const Color(0xFF2D3A4A),
      );
    }
    final colors = [
      const Color(0xFF4FC1FF),
      const Color(0xFF7BD88F),
      const Color(0xFFE2C08D),
      const Color(0xFFD19A66),
      const Color(0xFFC586C0),
    ];
    var i = 0;
    for (final entry in routes.entries) {
      final color = colors[i++ % colors.length];
      final paint = Paint()
        ..color = color
        ..strokeWidth = entry.key.isBus ? 2.0 : 0.5
        ..style = PaintingStyle.stroke;
      for (final (a, b) in entry.value) {
        canvas.drawLine(a, b, paint);
      }
      for (final p in optimized.result.junctions[entry.key] ?? const <Offset>[]) {
        canvas.drawCircle(
          p,
          nlJunctionDotRadius(entry.key.isBus),
          Paint()..color = color,
        );
      }
    }
    final image = await recorder.endRecording().toImage(
      model.canvasSize.width.round(),
      model.canvasSize.height.round(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      'scratch/nl_autoroute_preview.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
