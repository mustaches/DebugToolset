// GPU 流水线 spike：验证 16 位打包纹理（RGBA8 hi/lo 字节对）「上传 →
// FragmentShader 渲染 → 回读」全链路字节级无损。（float 渲染目标在
// Windows/Impeller 上会退化为 8-bit，已实测否决，故用字节打包方案。）
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> decodeBytes(Uint8List bytes, int w, int h) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      bytes, w, h, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

Future<Uint8List> render(ui.FragmentShader shader, int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..shader = shader);
  final picture = recorder.endRecording();
  final out = picture.toImageSync(w, h);
  final bd = await out.toByteData();
  final r = bd!.buffer.asUint8List();
  out.dispose();
  picture.dispose();
  return r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('16 位打包纹理上传/渲染/回读字节无损', () async {
    const w = 8, h = 4; // 逻辑 8x4 像素 → 打包纹理 4x4 纹素
    final data = Uint16List(w * h);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 997 + 12345) % 65536; // 覆盖高低字节
    }
    final src = await decodeBytes(data.buffer.asUint8List(), w ~/ 2, h);

    final prog =
        await ui.FragmentProgram.fromAsset('shaders/isp/isp_passthrough.frag');
    final shader = prog.fragmentShader()
      ..setFloat(0, w / 2)
      ..setFloat(1, h.toDouble())
      ..setImageSampler(0, src);
    final back = await render(shader, w ~/ 2, h);
    final back16 = back.buffer.asUint16List();
    // ignore: avoid_print
    print('打包往返: 期望[0..3]=${data.sublist(0, 4)} 回读=${back16.sublist(0, 4)}');
    expect(back16, equals(data));
    src.dispose();
  });

  test('shader 内 16 位解码/运算/编码（每像素 +1000 钳位）', () async {
    const w = 8, h = 4;
    final data = Uint16List(w * h);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 3000 + 700) % 65536;
    }
    final src = await decodeBytes(data.buffer.asUint8List(), w ~/ 2, h);
    final prog = await ui.FragmentProgram.fromAsset('shaders/isp/isp_inc16.frag');
    final shader = prog.fragmentShader()
      ..setFloat(0, w / 2) // uTexSize.x
      ..setFloat(1, h.toDouble()) // uTexSize.y
      ..setFloat(2, w.toDouble()) // uWidth（逻辑像素宽）
      ..setImageSampler(0, src);
    final back = await render(shader, w ~/ 2, h);
    final back16 = back.buffer.asUint16List();
    final expected =
        Uint16List.fromList([for (final v in data) (v + 1000).clamp(0, 65535)]);
    // ignore: avoid_print
    print('inc16: 期望[0..3]=${expected.sublist(0, 4)} 回读=${back16.sublist(0, 4)}');
    expect(back16, equals(expected));
    src.dispose();
  });
}
