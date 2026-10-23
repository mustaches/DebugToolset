// 一次性：解析导出的 SVG，统计长线段/折弯/贴线，定位观感问题。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analyze svg', () {
    final svg = File(
      'IspFlow/ISP_IPgen_out/isp_ip_multi_band_eq_core_sch.svg',
    ).readAsStringSync();
    final paths = RegExp(
      r'<path d="([^"]+)" fill="none" stroke="(#[0-9a-fA-F]+)"',
    ).allMatches(svg).where((m) => m.group(2) != '#ffffff').toList();
    var total = 0.0;
    var segCount = 0;
    var bends = 0;
    final segs = <(double, double, double, double)>[];
    final perPath = <(int, double, int)>[];
    for (final m in paths) {
      final d = m.group(1)!;
      final tokens = RegExp(
        r'([ML])\s*([-0-9.]+)[ ,]+([-0-9.]+)',
      ).allMatches(d);
      double? x, y;
      String prevDir = '';
      for (final t in tokens) {
        final cmd = t.group(1)!;
        final nx = double.parse(t.group(2)!);
        final ny = double.parse(t.group(3)!);
        if (cmd == 'M') {
          x = nx;
          y = ny;
          prevDir = '';
        } else {
          final dir = (nx - x!).abs() > 0.01 ? 'h' : 'v';
          if (prevDir.isNotEmpty && dir != prevDir) bends++;
          prevDir = dir;
          segs.add((x, y!, nx, ny));
          total += (nx - x).abs() + (ny - y).abs();
          segCount++;
          x = nx;
          y = ny;
        }
      }
    }
    print('paths=${paths.length} segs=$segCount total=${total.toStringAsFixed(0)} bends=$bends');
    final byLen = [...segs]
      ..sort(
        (a, b) => _len(b).compareTo(_len(a)),
      );
    print('TOP LONG SEGMENTS:');
    for (final s in byLen.take(12)) {
      print('  ${_len(s).toStringAsFixed(0)}  (${s.$1},${s.$2}) -> (${s.$3},${s.$4})');
    }
    // 平行贴近：两条水平段 y 差 1..45、x 重叠 >120。
    var nearPairs = 0;
    var nearLen = 0.0;
    final horiz = segs.where((s) => (s.$2 - s.$4).abs() < 0.01).toList();
    for (var i = 0; i < horiz.length; i++) {
      for (var j = i + 1; j < horiz.length; j++) {
        final dy = (horiz[i].$2 - horiz[j].$2).abs();
        if (dy < 0.1 || dy > 45) continue;
        final lo = math.max(
          math.min(horiz[i].$1, horiz[i].$3),
          math.min(horiz[j].$1, horiz[j].$3),
        );
        final hi = math.min(
          math.max(horiz[i].$1, horiz[i].$3),
          math.max(horiz[j].$1, horiz[j].$3),
        );
        if (hi - lo > 120) {
          nearPairs++;
          nearLen += hi - lo;
        }
      }
    }
    print('parallel near pairs=$nearPairs total=${nearLen.toStringAsFixed(0)}');
    // 长折弯路：每 path 段数最多的。
    for (final p in paths.take(0)) {
      // ignore
    }
    // 水平长段按 y 分布。
    final yHist = <int, int>{};
    for (final s in byLen.take(40)) {
      final y = (s.$2 / 15).round() * 15;
      yHist[y] = (yHist[y] ?? 0) + 1;
    }
    print('long seg y buckets=$yHist');
  });
}

double _len((double, double, double, double) s) =>
    (s.$3 - s.$1).abs() + (s.$4 - s.$2).abs();

int _bends(List<(double, double)> pts) {
  var n = 0;
  var dir = '';
  for (var i = 1; i < pts.length; i++) {
    final d = (pts[i].$1 - pts[i - 1].$1).abs() > 0.01 ? 'h' : 'v';
    if (dir.isNotEmpty && d != dir) n++;
    dir = d;
  }
  return n;
}
