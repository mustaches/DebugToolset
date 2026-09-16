// FSIM 单跑计时分解（AOT）：dart compile exe 后运行。
import 'dart:io';
import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';

Future<void> main() async {
  final sw = Stopwatch()..start();
  final (r0, w, h) = await decodeImageFileToRgba8('IspFlow/DemoPhoto/3.jpg');
  final (t0, _, _) = await decodeImageFileToRgba8('IspFlow/DemoPhoto/3noise.png');
  print('PROBE 解码两图 ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final (dr, dw, dh) = downsampleRgba82x(r0, w, h);
  final (dt, _, _) = downsampleRgba82x(t0, w, h);
  print('PROBE 降采样 ${sw.elapsedMilliseconds}ms (${dw}x$dh)');
  sw.reset();
  final v1 = fsimRgba(dr, dt, dw, dh);
  print('PROBE fsimRgba 串行 ${sw.elapsedMilliseconds}ms v=${v1.$1}');
}
