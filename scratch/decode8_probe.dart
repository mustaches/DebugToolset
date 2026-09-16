import 'dart:io';
import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';

Future<void> main() async {
  final sw = Stopwatch()..start();
  await decodeImageFileToRgba8('IspFlow/DemoPhoto/3.jpg');
  print('PROBE rgba8 3.jpg ${sw.elapsedMilliseconds}ms');
  sw.reset();
  await decodeImageFileToRgba8('IspFlow/DemoPhoto/3noise.png');
  print('PROBE rgba8 3noise.png ${sw.elapsedMilliseconds}ms');
  sw.reset();
  await decodeImageFileToRgba8('IspFlow/DemoPhoto/3.jpg');
  print('PROBE rgba8 3.jpg 第二次 ${sw.elapsedMilliseconds}ms');
  sw.reset();
  await decodeImageFileToRgba8('IspFlow/DemoPhoto/3noise.png');
  print('PROBE rgba8 3noise.png 第二次 ${sw.elapsedMilliseconds}ms');
}
