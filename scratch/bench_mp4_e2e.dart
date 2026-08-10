import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/exporters.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

Future<void> main() async {
  final chain = <Map<String, Object?>>[
    {
      'typeId': 'bayer_source',
      'params': {
        'filePath': 'BayerRGGB/RAW_3840x2160_10bits_RGGB_Linear_5frame.raw',
        'width': 3840, 'height': 2160, 'bitDepth': '10',
        'packing': 'unpacked_lsb', 'bayerPattern': 'RGGB',
        'littleEndian': true, 'frameIndex': 0,
      },
    },
    {'typeId': 'black_level', 'params': {'r': 50.0, 'gr': 50.0, 'gb': 50.0, 'b': 50.0}},
    {'typeId': 'demosaic', 'params': {'algorithm': 'bilinear'}},
    {'typeId': 'white_balance', 'params': {'mode': 'auto', 'rGain': 1.0, 'bGain': 1.0}},
    {'typeId': 'ccm', 'params': {'matrix': [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]}},
    {'typeId': 'gamma', 'params': {'gamma': 2.2, 'brightness': 0.0, 'contrast': 1.0}},
  ];

  final sw = Stopwatch()..start();
  await exportMp4(
    ffmpegPath: 'tools/ffmpeg/ffmpeg.exe',
    outputPath: 'scratch/isp_smoke_out/bench_e2e.mp4',
    width: 3840, height: 2160, fps: 30, crf: 18, frameCount: 5,
    frameProvider: (i) => Isolate.run<Uint8List>(
        () => runChainFrame(chain, i)),
  );
  print('端到端 exportMp4 5 帧(逐帧 isolate, 串行): ${sw.elapsedMilliseconds}ms');
  File('scratch/isp_smoke_out/bench_e2e.mp4').deleteSync();
}
