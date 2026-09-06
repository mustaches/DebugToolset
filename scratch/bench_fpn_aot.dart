// FPN CPU 核 AOT 基准：dart compile exe scratch/bench_fpn_aot.dart -o scratch/bench_fpn_aot.exe && scratch/bench_fpn_aot.exe
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';

void main() {
  for (final (w, h) in [(1920, 1080), (4096, 3072)]) {
    final data = Uint16List(w * h);
    var s = 7;
    for (var i = 0; i < data.length; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      data[i] = 1023 & s;
    }
    // 预热 + 计时。
    applyFpn(Uint16List.fromList(data),
        width: w, height: h, pattern: BayerPattern.rggb, maxCorr: 64);
    final sw = Stopwatch()..start();
    applyFpn(data,
        width: w, height: h, pattern: BayerPattern.rggb, maxCorr: 64);
    print('FPN_AOT ${w}x$h: ${sw.elapsedMilliseconds}ms');
  }
}
