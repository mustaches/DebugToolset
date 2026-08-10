import 'dart:io';

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

  // 生成 5 帧 RGBA 原始文件
  final raw = File('scratch/isp_smoke_out/bench_5f.rgba');
  final sink = raw.openWrite();
  final sw = Stopwatch()..start();
  for (var i = 0; i < 5; i++) {
    sink.add(await runChainFrame(chain, i));
  }
  await sink.close();
  print('5帧流水线(串行,进程内): ${sw.elapsedMilliseconds}ms');

  // 单独测 ffmpeg 编码
  sw.reset();
  final r = await Process.run('tools/ffmpeg/ffmpeg.exe', [
    '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '3840x2160',
    '-r', '30', '-i', raw.path,
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '18',
    'scratch/isp_smoke_out/bench_5f.mp4',
  ]);
  print('ffmpeg 编码 5 帧: ${sw.elapsedMilliseconds}ms exit=${r.exitCode}');
  print((r.stderr as String).split('\n').where((l) => l.contains('frame=') || l.contains('x264')).last);
  raw.deleteSync();
  File('scratch/isp_smoke_out/bench_5f.mp4').deleteSync();
}
