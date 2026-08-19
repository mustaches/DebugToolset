/// 临时定位：对比完整白光流程 vs 精简旧式链的输出图与直方统计。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:image/image.dart' as img;

void stats(String tag, List<int> rgba) {
  final buckets = List<int>.filled(8, 0);
  var sum = 0, n = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    final v = (rgba[i] + rgba[i + 1] + rgba[i + 2]) ~/ 3;
    buckets[v * 8 ~/ 256]++;
    sum += v;
    n++;
  }
  print('$tag mean=${(sum / n / 255 * 100).toStringAsFixed(1)}% '
      '直方(0..255 八桶)= $buckets');
}

Future<void> savePng(String path, List<int> rgba, int w, int h) async {
  final u8 = rgba is Uint8List ? rgba : Uint8List.fromList(rgba);
  final im = img.Image.fromBytes(
      width: w, height: h, bytes: u8.buffer, numChannels: 4);
  await File(path).writeAsBytes(img.encodePng(im));
  print('saved $path');
}

Future<void> main() async {
  final json = jsonDecode(
      await File('IspFlow/白光ISP流程.ispflow').readAsString())
      as Map<String, Object?>;
  final graph = IspGraph.fromJson(json);
  final chain = compileChain(graph, 'n15');

  final full = await runChainFrame(chain, 0);
  stats('完整链', full);
  await savePng('scratch/bisect_full.png', full, 1920, 1080);

  // 精简旧式链：源 → 黑电平 → 去马赛克 → 白平衡 → CCM → Gamma → 预览
  final keep = {'cis_bayer_rggb', 'black_level', 'demosaic', 'white_balance',
      'ccm', 'gamma', 'preview'};
  final minimal = [
    for (final op in chain)
      if (keep.contains(op['typeId'])) op,
  ];
  final mini = await runChainFrame(minimal, 0);
  stats('精简链', mini);
  await savePng('scratch/bisect_minimal.png', mini, 1920, 1080);

  // 逐个排除新 RAW 算子，定位发黑/发白的引入者。
  for (final drop in [
    {'fpn'},
    {'lsc'},
    {'fpn', 'lsc'},
    {'grgb_balance'},
    {'bayer_dnr'},
    {'highlight'},
  ]) {
    final sub = [
      for (final op in chain)
        if (!drop.contains(op['typeId'])) op,
    ];
    final out = await runChainFrame(sub, 0);
    stats('去掉 ${drop.join('+')}', out);
    await savePng('scratch/bisect_no_${drop.join('_')}.png', out, 1920, 1080);
  }
  exit(0);
}
