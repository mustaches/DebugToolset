import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe.dart';

void main() {
  test('debug ilniqe score vs python reference', () async {
    final bytes = await File('scratch/ilniqe_test_320x240.rgb').readAsBytes();
    const w = 320, h = 240;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0, j = 0; i < w * h; i++, j += 4) {
      rgba[j] = bytes[i * 3];
      rgba[j + 1] = bytes[i * 3 + 1];
      rgba[j + 2] = bytes[i * 3 + 2];
      rgba[j + 3] = 255;
    }
    final sw = Stopwatch()..start();
    final s = ilniqeScore(rgba, w, h);
    // ignore: avoid_print
    print('dart ILNIQE=$s (python ref: 145.843853)  ${sw.elapsed}');
  });
}
