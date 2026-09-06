import 'dart:io';
import 'dart:typed_data';
import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';

Future<void> main() async {
  final (rgb, w, h) = await decodeImageFileToRgb16('IspFlow/DemoPhoto/3.jpg', maxValue: 255);
  final rgba = Uint8List(w * h * 4);
  for (var i = 0, j = 0, k = 0; i < w * h; i++, j += 3, k += 4) {
    rgba[k] = rgb[j]; rgba[k+1] = rgb[j+1]; rgba[k+2] = rgb[j+2]; rgba[k+3] = 255;
  }
  final (ra2, rw, rh) = downsampleRgba82x(rgba, w, h);

  // 输入 A：1688x3000（应用双路指标口径）
  var sw = Stopwatch()..start();
  ilniqeScore(ra2, rw, rh);
  print('ilniqe @1688x3000: ${sw.elapsedMilliseconds}ms');

  // 输入 B：先近邻缩到 524x524 再评分（内部缩放近似恒等）
  final small = Uint8List(524 * 524 * 4);
  for (var y = 0; y < 524; y++) {
    for (var x = 0; x < 524; x++) {
      final sy = y * rh ~/ 524, sx = x * rw ~/ 524;
      final si = (sy * rw + sx) * 4, di = (y * 524 + x) * 4;
      small[di] = ra2[si]; small[di+1] = ra2[si+1]; small[di+2] = ra2[si+2]; small[di+3] = 255;
    }
  }
  sw.reset();
  ilniqeScore(small, 524, 524);
  print('ilniqe @524x524:  ${sw.elapsedMilliseconds}ms');
  exit(0);
}
