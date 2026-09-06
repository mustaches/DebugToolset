// 验证 3×3 盒式模糊：可分离两趟 vs 原 2-D 9 点 的逐像素差。
import 'dart:math' as math;
import 'dart:typed_data';

Float64List box2d(Float64List p, int w, int h) {
  final out = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = y > 0 ? y - 1 : 0;
    final y1 = y < h - 1 ? y + 1 : h - 1;
    for (var x = 0; x < w; x++) {
      final x0 = x > 0 ? x - 1 : 0;
      final x1 = x < w - 1 ? x + 1 : w - 1;
      var s = 0.0;
      for (var yy = y0; yy <= y1; yy++) {
        final row = yy * w;
        for (var xx = x0; xx <= x1; xx++) {
          s += p[row + xx];
        }
      }
      out[y * w + x] = s / ((x1 - x0 + 1) * (y1 - y0 + 1));
    }
  }
  return out;
}

Float64List boxSep(Float64List p, int w, int h) {
  final tmp = Float64List(w * h);
  final out = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final x0 = x > 0 ? x - 1 : 0;
      final x1 = x < w - 1 ? x + 1 : w - 1;
      var s = p[row + x];
      if (x0 != x) s += p[row + x0];
      if (x1 != x) s += p[row + x1];
      tmp[row + x] = s / (x1 - x0 + 1);
    }
  }
  for (var y = 0; y < h; y++) {
    final y0 = y > 0 ? y - 1 : 0;
    final y1 = y < h - 1 ? y + 1 : h - 1;
    final r0 = y0 * w, r1 = y * w, r2 = y1 * w;
    final n = y1 - y0 + 1;
    for (var x = 0; x < w; x++) {
      var s = tmp[r1 + x];
      if (y0 != y) s += tmp[r0 + x];
      if (y1 != y) s += tmp[r2 + x];
      out[r1 + x] = s / n;
    }
  }
  return out;
}

void main() {
  const w = 960, h = 540;
  final p = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      p[y * w + x] = (128 +
              70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
              40 * math.sin((x + 2 * y) / 5.3))
          .clamp(0.0, 255.0);
    }
  }
  final a = box2d(p, w, h);
  final b = boxSep(p, w, h);
  var maxD = 0.0;
  var maxI = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > maxD) {
      maxD = d;
      maxI = i;
    }
  }
  print('max|box2d-boxSep| = $maxD @ (x=${maxI % w}, y=${maxI ~/ w})');
  print('box2d=${a[maxI]} boxSep=${b[maxI]} p=${p[maxI]}');
  // 统计差值分布：内部/边缘各多少超 1e-9。
  var badInterior = 0, badEdge = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if ((a[i] - b[i]).abs() > 1e-9) {
        if (x == 0 || y == 0 || x == w - 1 || y == h - 1) {
          badEdge++;
        } else {
          badInterior++;
          if (badInterior <= 3) {
            print('interior diff @ (x=$x, y=$y): ${a[i]} vs ${b[i]}');
          }
        }
      }
    }
  }
  print('badEdge=$badEdge badInterior=$badInterior');
}
