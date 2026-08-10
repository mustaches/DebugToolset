import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';

void main() {
  const w = 1920, h = 1080;
  final bytes = File('BayerRGGB/RAW_1920x1080_10bits_RGGB_Linear_1frame.raw')
      .readAsBytesSync();
  final mosaic = unpackBayer(bytes,
      width: w, height: h, bitDepth: 10,
      packing: BayerPacking.unpackedLsb, littleEndian: true);
  final rgb = demosaicBilinear(mosaic, width: w, height: h, pattern: BayerPattern.rggb);

  const bars = [
    '白', '黄', '青', '绿', '品红', '红', '蓝', '黑',
  ];
  const expect8 = [
    (255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
    (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0),
  ];
  var ok = true;
  for (var bar = 0; bar < 8; bar++) {
    final x = bar * 240 + 120; // 每条中心
    const y = 540;
    final i = (y * w + x) * 3;
    final r = rgb[i] >> 2, g = rgb[i + 1] >> 2, b = rgb[i + 2] >> 2;
    final (er, eg, eb) = expect8[bar];
    final match = (r - er).abs() <= 2 && (g - eg).abs() <= 2 && (b - eb).abs() <= 2;
    if (!match) ok = false;
    print('${bars[bar]}: ($r, $g, $b) 期望 ($er, $eg, $eb) ${match ? "OK" : "FAIL"}');
  }
  print(ok ? '全部通过' : '存在失败');
}
