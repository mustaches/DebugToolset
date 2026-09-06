// 一次性计时脚本：量化图像评价.ispflow 各 Dart 侧环节耗时（不参与静态分析）。
import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instruments.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/brisque.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/piqe.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';

Future<void> main() async {
  var sw = Stopwatch()..start();
  final (rgb, w, h) = await decodeImageFileToRgb16(
      'IspFlow/DemoPhoto/3.jpg',
      maxValue: 255);
  print('decode 3.jpg  ($w x $h): ${sw.elapsedMilliseconds}ms');

  sw.reset();
  final (rgb2, w2, h2) = await decodeImageFileToRgb16(
      'IspFlow/DemoPhoto/3noise.png',
      maxValue: 255);
  print('decode 3noise.png ($w2 x $h2): ${sw.elapsedMilliseconds}ms');

  // 与应用同口径：RGB16 → RGBA8 → 2x 降采样
  Uint8List rgbaOf(Uint16List rgb, int w, int h) {
    final out = Uint8List(w * h * 4);
    for (var i = 0, j = 0, k = 0; i < w * h; i++, j += 3, k += 4) {
      out[k] = rgb[j];
      out[k + 1] = rgb[j + 1];
      out[k + 2] = rgb[j + 2];
      out[k + 3] = 255;
    }
    return out;
  }

  sw.reset();
  final ra = rgbaOf(rgb, w, h);
  final ta = rgbaOf(rgb2, w2, h2);
  print('rgb16->rgba8 两次: ${sw.elapsedMilliseconds}ms');

  sw.reset();
  final (ra2, rw, rh) = downsampleRgba82x(ra, w, h);
  final ta2 = downsampleRgba82x(ta, w2, h2).$1;
  print('downsample2x -> ($rw x $rh): ${sw.elapsedMilliseconds}ms');

  sw.reset();
  final (mse, psnr) = psnrRgba(ra2, ta2);
  print('psnr: ${sw.elapsedMilliseconds}ms ($psnr, mse=$mse)');

  sw.reset();
  final ssimV = ssimRgba(ra2, ta2, rw, rh);
  print('ssim: ${sw.elapsedMilliseconds}ms (${ssimV.$1})');

  sw.reset();
  final msssimV = msssimRgba(ra2, ta2, rw, rh);
  print('msssim: ${sw.elapsedMilliseconds}ms (${msssimV.$1})');

  sw.reset();
  final fsimV = fsimRgba(ra2, ta2, rw, rh);
  print('fsim: ${sw.elapsedMilliseconds}ms (${fsimV.$1})');

  sw.reset();
  final niqeV = niqeScore(ra2, rw, rh);
  print('niqe: ${sw.elapsedMilliseconds}ms ($niqeV)');

  sw.reset();
  final brisqueV = brisqueScore(ra2, rw, rh);
  print('brisque: ${sw.elapsedMilliseconds}ms ($brisqueV)');

  sw.reset();
  final piqeV = piqeScore(ra2, rw, rh);
  print('piqe: ${sw.elapsedMilliseconds}ms ($piqeV)');

  sw.reset();
  final ilniqeV = ilniqeScore(ra2, rw, rh);
  print('ilniqe: ${sw.elapsedMilliseconds}ms ($ilniqeV)');
  exit(0);
}
