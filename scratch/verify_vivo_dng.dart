import 'package:debug_tool_set/modules/isp_studio/pipeline/dng_source.dart';

Future<void> main() async {
  const path = r'G:\DebugToolSet\IspFlow\BayerRGGB\IMG_20260817_213218.dng';
  final sw = Stopwatch()..start();
  final (info, frame) = await readDngFrame(path);
  print('解析+解码耗时: ${sw.elapsedMilliseconds} ms');
  print('宽x高: ${info.width}x${info.height}');
  print('存储位深: ${info.bitsPerSample}, 白电平: ${info.whiteLevel}, 有效位深: ${info.bitDepth}');
  print('CFA: ${info.cfaPattern} colors=${info.cfaColors}');
  print('黑电平: ${info.blackLevels}');
  print('小端: ${info.littleEndian}, 条带: ${info.stripOffsets.length} x ${info.rowsPerStrip}行');
  print('像素数: ${frame.length}');
  var mn = 65535, mx = 0;
  var sum = 0;
  for (final v in frame) {
    if (v < mn) mn = v;
    if (v > mx) mx = v;
    sum += v;
  }
  print('min=$mn max=$mx mean=${(sum / frame.length).toStringAsFixed(1)}');
}
