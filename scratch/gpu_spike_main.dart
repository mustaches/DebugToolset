// GPU spike 独立入口：flutter run -d windows -t scratch/gpu_spike_main.dart
// 在真实 Windows/Impeller 环境验证 float32 渲染目标往返精度。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

Future<ui.Image> decodeFloat(Float32List values, int w, int h) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(values.buffer.asUint8List(), w, h,
      ui.PixelFormat.rgbaFloat32, completer.complete);
  return completer.future;
}

Future<void> spike() async {
  const w = 64, h = 32;
  final values = Float32List(w * h * 4);
  for (var i = 0; i < values.length; i++) {
    values[i] = i * 0.25 + 0.125;
  }
  final sw = Stopwatch()..start();
  final src = await decodeFloat(values, w, h);
  final uploadMs = sw.elapsedMilliseconds;

  final prog =
      await ui.FragmentProgram.fromAsset('shaders/isp/isp_passthrough.frag');
  final shader = prog.fragmentShader()
    ..setFloat(0, w.toDouble())
    ..setFloat(1, h.toDouble())
    ..setImageSampler(0, src);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..shader = shader);
  final picture = recorder.endRecording();

  sw.reset();
  final out = picture.toImageSync(w, h,
      targetFormat: ui.TargetPixelFormat.rgbaFloat32);
  final bd =
      await out.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128);
  final renderReadMs = sw.elapsedMilliseconds;

  final back = bd!.buffer.asFloat32List();
  var maxDiff = 0.0;
  for (var i = 0; i < values.length; i++) {
    final d = (back[i] - values[i]).abs();
    if (d > maxDiff) maxDiff = d;
  }
  print('SPIKE_RESULT maxDiff=$maxDiff upload=${uploadMs}ms '
      'render+read=${renderReadMs}ms back[0..3]=${back.sublist(0, 4)} '
      'back[last]=${back[values.length - 1]}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('gpu spike')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await spike();
    } catch (e, st) {
      print('SPIKE_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
