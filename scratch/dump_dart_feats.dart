import 'dart:io';
import 'dart:typed_data';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_dart.dart';
import 'package:image/image.dart' as img;

Uint8List loadRgba(String path) {
  final image = img.decodePng(File(path).readAsBytesSync())!;
  final w = image.width, h = image.height;
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      final i = (y * w + x) * 4;
      rgba[i] = p.r.toInt();
      rgba[i + 1] = p.g.toInt();
      rgba[i + 2] = p.b.toInt();
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<void> main() async {
  final refAll = Float32List(10 * 2048);
  final testAll = Float32List(10 * 2048);
  for (var i = 0; i < 5; i++) {
    final fr = await inceptionPatchFeaturesParallel(
        loadRgba('scratch/eval_set/ref_$i.png'), 256, 192);
    final ft = await inceptionPatchFeaturesParallel(
        loadRgba('scratch/eval_set/test_$i.png'), 256, 192);
    refAll.setRange(i * 2 * 2048, (i + 1) * 2 * 2048, fr);
    testAll.setRange(i * 2 * 2048, (i + 1) * 2 * 2048, ft);
  }
  await File('scratch/dart_ref_feats.f32').writeAsBytes(refAll.buffer.asUint8List());
  await File('scratch/dart_test_feats.f32').writeAsBytes(testAll.buffer.asUint8List());
  print('dart kid = ${kidCompute(refAll, 10, testAll, 10)}');
}
