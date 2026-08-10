// 冒烟脚本：用真实 4K Bayer RAW 跑完整 ISP 链并导出 JPG/PNG。
// 运行: dart run scratch/smoke_isp_pipeline.dart
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/pipeline/exporters.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

Future<void> main() async {
  const rawPath = 'BayerRGGB/RAW_3840x2160_10bits_RGGB_Linear_1frame_1.raw';
  final outDir = Directory('scratch/isp_smoke_out')..createSync();

  final chain = <Map<String, Object?>>[
    {
      'typeId': 'bayer_source',
      'params': {
        'filePath': rawPath,
        'width': 3840,
        'height': 2160,
        'bitDepth': '10',
        'packing': 'unpacked_lsb',
        'bayerPattern': 'RGGB',
        'littleEndian': true,
        'frameIndex': 0,
      }
    },
    {
      'typeId': 'black_level',
      // .txt 中的 801/802 是 16 倍刻度，实际约 50。
      'params': {'r': 50.0, 'gr': 50.0, 'gb': 50.0, 'b': 50.0}
    },
    {
      'typeId': 'demosaic',
      'params': {'algorithm': 'bilinear'}
    },
    {
      'typeId': 'white_balance',
      'params': {'mode': 'auto', 'rGain': 1.0, 'bGain': 1.0}
    },
    {
      'typeId': 'ccm',
      'params': {
        'matrix': [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
      }
    },
    {
      'typeId': 'gamma',
      'params': {'gamma': 2.2, 'brightness': 0.0, 'contrast': 1.0}
    },
  ];

  final sw = Stopwatch()..start();
  final rgba = await runChainFrame(chain, 0);
  print('pipeline: ${sw.elapsedMilliseconds} ms, rgba=${rgba.length}');

  sw.reset();
  final jpg = encodeJpgRgba(rgba, 3840, 2160, 100);
  File('${outDir.path}/frame0_q100.jpg').writeAsBytesSync(jpg);
  print('jpg q100: ${sw.elapsedMilliseconds} ms, ${jpg.length} bytes');

  sw.reset();
  final png = encodePngRgba(rgba, 3840, 2160);
  File('${outDir.path}/frame0.png').writeAsBytesSync(png);
  print('png: ${sw.elapsedMilliseconds} ms, ${png.length} bytes');

  // 简单统计， sanity check 亮度/颜色分布
  var sumR = 0, sumG = 0, sumB = 0;
  for (var i = 0; i < rgba.length; i += 400) {
    sumR += rgba[i];
    sumG += rgba[i + 1];
    sumB += rgba[i + 2];
  }
  final n = rgba.length ~/ 400;
  print('mean RGB ~ (${sumR ~/ n}, ${sumG ~/ n}, ${sumB ~/ n})');
}
