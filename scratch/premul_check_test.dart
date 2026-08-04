import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _img(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

Future<int> _drawAndReadBack(Uint8List rgba) async {
  final img = await _img(rgba, 1, 1);
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1), ui.Paint()..color = const ui.Color(0xFF252525));
  canvas.drawImageRect(img, const ui.Rect.fromLTWH(0, 0, 1, 1),
      const ui.Rect.fromLTWH(0, 0, 1, 1), ui.Paint()..filterQuality = ui.FilterQuality.none);
  final out = await rec.endRecording().toImage(1, 1);
  final bd = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
  return bd!.getUint8(0); // R channel over dark 0x25 background
}

void main() {
  test('premultiplied vs straight alpha readback', () async {
    final straight = Uint8List.fromList([255, 255, 255, 0]);
    final premul = Uint8List.fromList([0, 0, 0, 0]);
    final r1 = await _drawAndReadBack(straight);
    final r2 = await _drawAndReadBack(premul);
    // ignore: avoid_print
    print('straight (255,255,255,0) -> R=$r1 (0x25=37 expected if transparent)');
    // ignore: avoid_print
    print('premul  (0,0,0,0)        -> R=$r2');
  });
}
