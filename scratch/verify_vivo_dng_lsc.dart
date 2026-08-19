import 'dart:typed_data';
import 'dart:io';
import 'package:debug_tool_set/modules/isp_studio/pipeline/dng_source.dart';

Future<void> main() async {
  const path = r'G:\DebugToolSet\IspFlow\BayerRGGB\IMG_20260817_213218.dng';
  final bytes = await File(path).readAsBytes();
  final info = parseDngInfo(bytes);
  print('GainMap 数量: ${info.gainMaps.length}');
  for (final m in info.gainMaps) {
    print('  相位(top=${m.top},left=${m.left}) pitch=${m.rowPitch}x${m.colPitch} '
        '网点=${m.pointsV}x${m.pointsH} 间距=${m.spacingV.toStringAsFixed(4)}/${m.spacingH.toStringAsFixed(4)} '
        '增益范围=${m.gains.reduce((a,b)=>a<b?a:b).toStringAsFixed(3)}..${m.gains.reduce((a,b)=>a>b?a:b).toStringAsFixed(3)}');
  }
  print('Warp: planes=${info.warp?.planes}, isIdentity=${info.warp?.isIdentity}');

  final mosaic = decodeDngFrameData(bytes, info);
  double meanOf(Uint16List f) {
    var s = 0; for (final v in f) s += v; return s / f.length;
  }
  // 角落 64x64 区域均值
  double cornerMean(Uint16List f) {
    var s = 0; var n = 0;
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) { s += f[y*info.width+x]; n++; }
    }
    return s / n;
  }
  final before = meanOf(mosaic);
  final cornerBefore = cornerMean(mosaic);
  final sw = Stopwatch()..start();
  applyDngGainMaps(mosaic, info.width, info.height, info.gainMaps,
      blackLevels: info.blackLevels, whiteLevel: info.whiteLevel);
  print('LSC 应用耗时: ${sw.elapsedMilliseconds} ms');
  print('全图均值: ${before.toStringAsFixed(1)} -> ${meanOf(mosaic).toStringAsFixed(1)}');
  print('左上角均值: ${cornerBefore.toStringAsFixed(1)} -> ${cornerMean(mosaic).toStringAsFixed(1)}');
}
