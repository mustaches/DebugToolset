// 临时测量：fidCompute 的 dgemm 与 eig 耗时构成（n 可调，三次方外推）。
// dart run scratch/eig_prof.dart [n]
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';

void main(List<String> args) {
  final n = args.isEmpty ? 1024 : int.parse(args[0]);
  final rng = math.Random(0);
  // 造两个 PSD 协方差（B Bᵀ + 小对角），模拟 FID 的 σ1σ2。
  Float64List mkCov() {
    final b = Float64List(n * 16);
    for (var i = 0; i < b.length; i++) {
      b[i] = rng.nextDouble() - 0.5;
    }
    final c = Float64List(n * n);
    for (var i = 0; i < n; i++) {
      for (var j = i; j < n; j++) {
        var s = i == j ? 0.05 : 0.0;
        for (var k = 0; k < 16; k++) {
          s += b[i * 16 + k] * b[j * 16 + k];
        }
        c[i * n + j] = s;
        c[j * n + i] = s;
      }
    }
    return c;
  }

  final s1 = mkCov(), s2 = mkCov();
  var sw = Stopwatch()..start();
  final prod = Float64List(n * n);
  dgemmNn(s1, s2, prod, n, n, n);
  final gemmMs = sw.elapsedMilliseconds;
  sw = Stopwatch()..start();
  final ev = eigvalsReal(prod, n);
  final eigMs = sw.elapsedMilliseconds;
  var c = 0.0;
  for (var i = 0; i < n; i++) {
    c += math.sqrt((math.sqrt(ev.re[i] * ev.re[i] + ev.im[i] * ev.im[i]) +
            ev.re[i]) /
        2);
  }
  print('n=$n: dgemm ${gemmMs}ms, eig ${eigMs}ms, ΣRe√λ=$c');
}
