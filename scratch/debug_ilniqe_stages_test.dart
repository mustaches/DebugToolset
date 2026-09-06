import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';

Float64List loadF64(String path) {
  final bytes = File(path).readAsBytesSync();
  return Float64List.view(bytes.buffer, 0, bytes.length ~/ 8);
}

void compare(String name, Float64List a, Float64List b) {
  if (a.length != b.length) {
    // ignore: avoid_print
    print('$name: LENGTH MISMATCH dart=${a.length} py=${b.length}');
    return;
  }
  var maxDiff = 0.0;
  var maxIdx = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > maxDiff) {
      maxDiff = d;
      maxIdx = i;
    }
  }
  // ignore: avoid_print
  print('$name: maxDiff=$maxDiff @[$maxIdx] dart=${a[maxIdx]} py=${b[maxIdx]} '
      '(dart range ${a.reduce((x, y) => x < y ? x : y)}..${a.reduce((x, y) => x > y ? x : y)})');
}

void main() {
  test('ilniqe stage comparison', () async {
    final bytes = await File('scratch/ilniqe_test_320x240.rgb').readAsBytes();
    const w = 320, h = 240;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0, j = 0; i < w * h; i++, j += 4) {
      rgba[j] = bytes[i * 3];
      rgba[j + 1] = bytes[i * 3 + 1];
      rgba[j + 2] = bytes[i * 3 + 2];
      rgba[j + 3] = 255;
    }
    final debug = <String, Float64List>{};
    final sw = Stopwatch()..start();
    final s = ilniqeScore(rgba, w, h, debug: debug);
    // ignore: avoid_print
    print('score=$s  elapsed=${sw.elapsed}');

    compare('resized', debug['resized']!, loadF64('scratch/ilniqe_dump_resized.rgb'));
    compare('structdis', debug['structdis']!, loadF64('scratch/ilniqe_dump_structdis.raw'));
    compare('gmo1', debug['gmo1']!, loadF64('scratch/ilniqe_dump_gmo1.raw'));
    compare('ixo1', debug['ixo1']!, loadF64('scratch/ilniqe_dump_ixo1.raw'));
    compare('intensity', debug['intensity']!, loadF64('scratch/ilniqe_dump_intensity.raw'));
    compare('logresp0', debug['logresp0']!, loadF64('scratch/ilniqe_dump_logresp0.raw'));
    compare('gm0', debug['gm0']!, loadF64('scratch/ilniqe_dump_gm0.raw'));
    compare('block0_s1', debug['block0_s1']!, loadF64('scratch/ilniqe_dump_block0_s1.raw'));
  });
}
