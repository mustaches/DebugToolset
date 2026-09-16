// FSIM 生产并行路径（compute(dualMetricInIsolate)）计时 + 与串行位级对比。
import 'dart:io';
import 'dart:isolate';
import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';

Future<void> main() async {
  final (r0, w, h) = await decodeImageFileToRgba8('IspFlow/DemoPhoto/3.jpg');
  final (t0, _, _) = await decodeImageFileToRgba8('IspFlow/DemoPhoto/3noise.png');
  final (dr, dw, dh) = downsampleRgba82x(r0, w, h);
  final (dt, _, _) = downsampleRgba82x(t0, w, h);
  final sw = Stopwatch()..start();
  final v = fsimRgba(dr, dt, dw, dh);
  print('PROBE fsimRgba 串行 ${sw.elapsedMilliseconds}ms v=${v.$1}');
  sw.reset();
  final r = await Isolate.run(() => dualMetricInIsolate(
      {'kind': 'fsim', 'ref': dr, 'test': dt, 'width': dw, 'height': dh}));
  print('PROBE dualMetricInIsolate(fsim) ${sw.elapsedMilliseconds}ms v=${r['fsim']}');
  print('PROBE bitexact=${r['fsim'] == v.$1}');
  exit(0);
}
