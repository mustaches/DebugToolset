// PSNR 流程馈源路径分阶段计时探针（生产同口径，AOT）：
// dart compile exe scratch/psnr_feed_probe.dart -o scratch/psnr_feed_probe.exe
// scratch/psnr_feed_probe.exe
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';

void main(List<String> args) async {
  const refPath = 'IspFlow/DemoPhoto/3.jpg';
  const testPath = 'IspFlow/DemoPhoto/3noise.png';
  final sw = Stopwatch()..start();

  // 阶段 1+2：读文件 + img.decodeImage（两次，对照 decodeImageFileToRgb16 内部分解）
  final bytesR = File(refPath).readAsBytesSync();
  print('PROBE readFile 3.jpg ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final imR = img.decodeImage(bytesR);
  print('PROBE decodeImage 3.jpg ${sw.elapsedMilliseconds}ms '
      '(${imR!.width}x${imR.height})');
  sw.reset();
  final bytesT = File(testPath).readAsBytesSync();
  print('PROBE readFile 3noise.png ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final imT = img.decodeImage(bytesT);
  print('PROBE decodeImage 3noise.png ${sw.elapsedMilliseconds}ms '
      '(${imT!.width}x${imT.height})');

  // 阶段 3：生产链的 16 位转换（含逐像素 Uint16 循环）
  sw.reset();
  final (rgbR, w, h) = await decodeImageFileToRgb16(refPath, maxValue: 255);
  print('PROBE decodeImageFileToRgb16 3.jpg ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final (rgbT, _, _) = await decodeImageFileToRgb16(testPath, maxValue: 255);
  print('PROBE decodeImageFileToRgb16 3noise.png ${sw.elapsedMilliseconds}ms');

  // 阶段 4：链尾默认色调映射（gamma 1.0 直通，生产口径）
  sw.reset();
  final rgbaR = tonemapToRgba(rgbR, maxValue: 255, gamma: 1.0);
  print('PROBE tonemapToRgba 3.jpg ${sw.elapsedMilliseconds}ms');
  sw.reset();
  final rgbaT = tonemapToRgba(rgbT, maxValue: 255, gamma: 1.0);
  print('PROBE tonemapToRgba 3noise.png ${sw.elapsedMilliseconds}ms');

  // 阶段 5：2x 降采样
  sw.reset();
  final (dsR, dw, dh) = downsampleRgba82x(rgbaR, w, h);
  final (dsT, _, _) = downsampleRgba82x(rgbaT, w, h);
  print('PROBE downsample2x 两图 ${sw.elapsedMilliseconds}ms (${dw}x$dh)');

  // 阶段 6：PSNR 本体（串行）
  sw.reset();
  final (mse, psnr) = psnrRgba(dsR, dsT);
  print('PROBE psnrRgba ${sw.elapsedMilliseconds}ms psnr=$psnr mse=$mse');

  // 对照：8 位直通（跳过 16 位中间路径）
  sw.reset();
  final (d8R, _, _) = await decodeImageFileToRgba8(refPath);
  final (d8T, _, _) = await decodeImageFileToRgba8(testPath);
  print('PROBE decodeImageFileToRgba8 两图 ${sw.elapsedMilliseconds}ms');
  // 口径验证：8 位直通 vs 16 位往返是否逐位一致
  var identical = d8R.length == rgbaR.length;
  if (identical) {
    for (var i = 0; i < d8R.length; i++) {
      if (d8R[i] != rgbaR[i]) {
        identical = false;
        print('PROBE rgba8 直通 vs 16位往返 首差@$i: ${d8R[i]} vs ${rgbaR[i]}');
        break;
      }
    }
  }
  print('PROBE rgba8_identity=$identical');
}
