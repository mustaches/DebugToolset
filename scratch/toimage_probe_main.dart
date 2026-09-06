// toImageSync/toImage 决定性探针（一次性诊断脚本，scratch 不参与分析）：
//   flutter run -d windows --release -t scratch/toimage_probe_main.dart
//   flutter run -d windows --release --enable-impeller -t scratch/toimage_probe_main.dart
//
// 目的：NN GPU 链的 conv pass 提交（GpuNnBackend.conv2dGpu 用
// PictureRecorder + drawRect(FragmentShader) + picture.toImageSync）在
// 本机疑似落到 CPU 软件光栅化（1688×3000 VGG 单侧前向 21s ≈ CPU 量级，
// --enable-impeller 不变，任务管理器 GPU 占用 0）。本探针用真实的
// conv shader（shaders/nn/nn_conv3x3_f16.frag）与代表性负载
// （输入特征 64ch×143×1688 的带、64 输出通道、3x3/p1/s1，单 pass，
// 输出纹理 8192×944，与 VGG 分块链一层的形态一致）对比三种提交方式
// 各 50 pass 的总耗时：
//   sync       —— picture.toImageSync(tw, th)（现状，经
//                 GpuNnBackend.conv2dGpu 原样调用，固定输入）；
//   async      —— await picture.toImage(tw, th)（走光栅线程管线，
//                 输入纹理固定）；
//   asyncChain —— 同 async，但上一 pass 的输出作为下一 pass 的输入
//                 sampler（模拟真实纹理驻留链的依赖形态）；
//   syncChain  —— 同 asyncChain 的链式依赖，但提交用 toImageSync
//                 （conv2dGpu 的真实现状形态：上一 pass 输出图像在新
//                 pass 提交完成后才 dispose，同 nn_gpu.dart 的
//                 accum 生命周期管理）；
//   sceneChain —— 同 asyncChain 的链式依赖，但提交走合成器管线：
//                 ui.SceneBuilder pushOffset/addPicture 把 Picture
//                 放进 scene，build() 后 await scene.toImage(tw, th)
//                 （测试合成器路径能否把光栅化送上 GPU）。
// 每轮先 warm-up 3 pass（排除 shader 编译）；轮间停 1s 并在窗口/控制台
// 打印轮次标记，便于对照任务管理器 GPU 占用（或另一终端 nvidia-smi）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 代表性负载形态（VGG 分块链一层）：[1,64,143,1688] → 64ch 3x3/p1/s1。
const int kCin = 64, kH = 143, kW = 1688;
const int kPasses = 50;

/// 探针进度（窗口中文显示 + 控制台标记）。
final status = ValueNotifier<String>('探针初始化…');

void say(String s) {
  status.value = s;
  // ignore: avoid_print
  print(s);
}

/// ui.Image 上传（同 GpuNnBackend._upload 的机制）。
Future<ui.Image> upload(Uint16List halves, int tw, int th) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(halves.buffer.asUint8List(), tw, th,
      ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// 与 GpuNnBackend.conv2dGpu 的单 pass 提交逐参数一致（cin=64 单 pass、
/// 带 bias、relu 融合），返回录制好的 Picture（提交方式由调用方选
/// toImageSync / toImage）。
ui.Picture recordConvPass(
  ui.FragmentProgram prog, {
  required ui.Image src,
  required int srcTexW,
  required int srcTexH,
  required ui.Image wgt,
  required int wgtTexW,
  required int wgtTexH,
  required ui.Image bias,
  required ui.Image dummy,
  required int outTW,
  required int outTH,
}) {
  final shader = prog.fragmentShader();
  shader.setFloat(0, srcTexW.toDouble());
  shader.setFloat(1, srcTexH.toDouble());
  shader.setFloat(2, kW.toDouble()); // 输入空间宽
  shader.setFloat(3, kH.toDouble()); // 输入空间高
  shader.setFloat(4, (kCin ~/ 4).toDouble()); // cinGpass
  shader.setFloat(5, 0); // giBase（单 pass）
  shader.setFloat(6, wgtTexW.toDouble());
  shader.setFloat(7, wgtTexH.toDouble());
  shader.setFloat(8, outTW.toDouble());
  shader.setFloat(9, outTH.toDouble());
  shader.setFloat(10, 0); // 无 accum（单 pass）
  shader.setFloat(11, 1); // 有 bias
  shader.setFloat(12, (kCin ~/ 4 * 2).toDouble()); // coutG*2
  shader.setFloat(13, 0); // yOff
  shader.setFloat(14, kW.toDouble()); // oW
  shader.setFloat(15, kH.toDouble()); // oH
  shader.setFloat(16, 1); // stride
  shader.setFloat(17, 3); // kH
  shader.setFloat(18, 3); // kW
  shader.setFloat(19, 1); // padH
  shader.setFloat(20, 1); // padW
  shader.setFloat(21, 1); // relu
  shader.setImageSampler(0, src);
  shader.setImageSampler(1, wgt);
  shader.setImageSampler(2, dummy);
  shader.setImageSampler(3, bias);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, outTW.toDouble(), outTH.toDouble()),
      ui.Paint()..shader = shader);
  return recorder.endRecording();
}

Future<void> probe() async {
  // 环境信息（看 --enable-impeller 等是否在命令行参数里）。
  say('TOIMAGE_PROBE_ENV args=${Platform.executableArguments} '
      'exe=${Platform.resolvedExecutable}');
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    say('TOIMAGE_PROBE_ERROR backend 初始化失败（shader 加载）');
    return;
  }
  // async 路径自加载同一 conv shader（backend 内部程序不对外开放）。
  final prog =
      await ui.FragmentProgram.fromAsset('shaders/nn/nn_conv3x3_f16.frag');

  // 输入特征与权重（确定性伪随机；打包经 GpuNnBackend 公共 API，与
  // 生产路径同机制）。
  final rng = math.Random(0);
  final inData = Float32List(kCin * kH * kW);
  for (var i = 0; i < inData.length; i++) {
    inData[i] = rng.nextDouble() * 2 - 1;
  }
  final wData = Float32List(kCin * kCin * 9);
  for (var i = 0; i < wData.length; i++) {
    wData[i] = (rng.nextDouble() * 2 - 1) * 0.1;
  }
  final biasData = Float32List(kCin);
  for (var i = 0; i < biasData.length; i++) {
    biasData[i] = (rng.nextDouble() * 2 - 1) * 0.1;
  }
  final x = await g.uploadFeatureMap(NnTensor(inData, [1, kCin, kH, kW]));
  final wgt = await g.uploadConvWeights(
      NnTensor(wData, [kCin, kCin, 3, 3]), kCin,
      bias: biasData);
  final dummy = await upload(Uint16List(2), 1, 1);

  // 输出物理纹理尺寸（同 conv2dGpu 的折叠布局公式）：s1 输出空间不变。
  final outTexels = 2 * (kCin ~/ 4) * kH * kW;
  final outTW = math.min(GpuNnBackend.maxTextureDim, outTexels);
  final outTH = (outTexels + outTW - 1) ~/ outTW;
  say('TOIMAGE_PROBE 输入 64ch x ${kH}x$kW（纹理 ${x.texW}x${x.texH}），'
      '输出纹理 ${outTW}x$outTH，每轮 $kPasses pass（另有 3 warm-up）');

  // ---------------- 轮 a：toImageSync（现状，原样走 conv2dGpu） ----------
  try {
    say('TOIMAGE_PROBE === round 1/5 sync（toImageSync，固定输入，现状），'
        '现在观察任务管理器 GPU 占用，同时可在另一终端跑 nvidia-smi '
        '看本进程是否占用 GPU ===');
    for (var i = 0; i < 3; i++) {
      g.conv2dGpu(x, wgt, relu: true).dispose();
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < kPasses; i++) {
      g.conv2dGpu(x, wgt, relu: true).dispose();
    }
    final ms = sw.elapsedMilliseconds;
    say('TOIMAGE_PROBE sync ${kPasses}pass = ${ms}ms '
        '(per-pass ${(ms / kPasses).toStringAsFixed(1)}ms)');
  } catch (e) {
    say('TOIMAGE_PROBE_ERROR sync $e');
  }
  await Future<void>.delayed(const Duration(seconds: 1));

  // ---------------- 轮 b：await toImage（输入固定） ----------------
  try {
    say('TOIMAGE_PROBE === round 2/5 async（await toImage，固定输入），'
        '现在观察任务管理器 GPU 占用，同时可在另一终端跑 nvidia-smi '
        '看本进程是否占用 GPU ===');
    Future<void> one() async {
      final pic = recordConvPass(prog,
          src: x.tex,
          srcTexW: x.texW,
          srcTexH: x.texH,
          wgt: wgt.passTex[0],
          wgtTexW: wgt.passTexW[0],
          wgtTexH: wgt.passTexH[0],
          bias: wgt.biasTex!,
          dummy: dummy,
          outTW: outTW,
          outTH: outTH);
      final img = await pic.toImage(outTW, outTH);
      pic.dispose();
      img.dispose();
    }

    for (var i = 0; i < 3; i++) {
      await one();
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < kPasses; i++) {
      await one();
    }
    final ms = sw.elapsedMilliseconds;
    say('TOIMAGE_PROBE async ${kPasses}pass = ${ms}ms '
        '(per-pass ${(ms / kPasses).toStringAsFixed(1)}ms)');
  } catch (e) {
    say('TOIMAGE_PROBE_ERROR async $e');
  }
  await Future<void>.delayed(const Duration(seconds: 1));

  // ------------- 轮 c：await toImage 链式（上输出=下输入） -------------
  try {
    say('TOIMAGE_PROBE === round 3/5 asyncChain（await toImage 链式依赖），'
        '现在观察任务管理器 GPU 占用，同时可在另一终端跑 nvidia-smi '
        '看本进程是否占用 GPU ===');
    Future<ui.Image> one(ui.Image src) async {
      final pic = recordConvPass(prog,
          src: src,
          srcTexW: x.texW,
          srcTexH: x.texH,
          wgt: wgt.passTex[0],
          wgtTexW: wgt.passTexW[0],
          wgtTexH: wgt.passTexH[0],
          bias: wgt.biasTex!,
          dummy: dummy,
          outTW: outTW,
          outTH: outTH);
      final img = await pic.toImage(outTW, outTH);
      pic.dispose();
      return img;
    }

    // warm-up（链式，末尾丢弃）。
    var prev = await one(x.tex);
    for (var i = 1; i < 3; i++) {
      final cur = await one(prev);
      prev.dispose();
      prev = cur;
    }
    prev.dispose();
    final sw = Stopwatch()..start();
    prev = await one(x.tex); // 第 0 个正式 pass：输入为上传纹理
    for (var i = 1; i < kPasses; i++) {
      final cur = await one(prev);
      prev.dispose();
      prev = cur;
    }
    prev.dispose();
    final ms = sw.elapsedMilliseconds;
    say('TOIMAGE_PROBE asyncChain ${kPasses}pass = ${ms}ms '
        '(per-pass ${(ms / kPasses).toStringAsFixed(1)}ms)');
  } catch (e) {
    say('TOIMAGE_PROBE_ERROR asyncChain $e');
  }
  await Future<void>.delayed(const Duration(seconds: 1));

  // --------- 轮 d：toImageSync 链式（conv2dGpu 的真实现状形态） ---------
  try {
    say('TOIMAGE_PROBE === round 4/5 syncChain（toImageSync 链式依赖，'
        'conv2dGpu 现状形态），现在观察任务管理器 GPU 占用，同时可在'
        '另一终端跑 nvidia-smi 看本进程是否占用 GPU ===');
    ui.Image one(ui.Image src) {
      final pic = recordConvPass(prog,
          src: src,
          srcTexW: x.texW,
          srcTexH: x.texH,
          wgt: wgt.passTex[0],
          wgtTexW: wgt.passTexW[0],
          wgtTexH: wgt.passTexH[0],
          bias: wgt.biasTex!,
          dummy: dummy,
          outTW: outTW,
          outTH: outTH);
      final img = pic.toImageSync(outTW, outTH);
      pic.dispose();
      return img;
    }

    // warm-up（链式；上一输出在新 pass 提交完成后才 dispose，同
    // conv2dGpu 的 accum 生命周期）。
    var prev = one(x.tex);
    for (var i = 1; i < 3; i++) {
      final cur = one(prev);
      prev.dispose();
      prev = cur;
    }
    prev.dispose();
    final sw = Stopwatch()..start();
    prev = one(x.tex); // 第 0 个正式 pass：输入为上传纹理
    for (var i = 1; i < kPasses; i++) {
      final cur = one(prev);
      prev.dispose();
      prev = cur;
    }
    prev.dispose();
    final ms = sw.elapsedMilliseconds;
    say('TOIMAGE_PROBE syncChain ${kPasses}pass = ${ms}ms '
        '(per-pass ${(ms / kPasses).toStringAsFixed(1)}ms)');
  } catch (e) {
    say('TOIMAGE_PROBE_ERROR syncChain $e');
  }
  await Future<void>.delayed(const Duration(seconds: 1));

  // ----- 轮 e：合成器路径链式（SceneBuilder + scene.toImage） -----
  try {
    say('TOIMAGE_PROBE === round 5/5 sceneChain（SceneBuilder 合成器 + '
        'await scene.toImage，链式依赖），现在观察任务管理器 GPU 占用，'
        '同时可在另一终端跑 nvidia-smi 看本进程是否占用 GPU ===');
    Future<ui.Image> one(ui.Image src) async {
      final pic = recordConvPass(prog,
          src: src,
          srcTexW: x.texW,
          srcTexH: x.texH,
          wgt: wgt.passTex[0],
          wgtTexW: wgt.passTexW[0],
          wgtTexH: wgt.passTexH[0],
          bias: wgt.biasTex!,
          dummy: dummy,
          outTW: outTW,
          outTH: outTH);
      // 合成器/光栅化管线：Picture 放进 scene 再异步转图像。
      final builder = ui.SceneBuilder();
      builder.pushOffset(0, 0);
      builder.addPicture(ui.Offset.zero, pic);
      builder.pop();
      final scene = builder.build();
      final img = await scene.toImage(outTW, outTH);
      scene.dispose();
      pic.dispose();
      return img;
    }

    // warm-up（链式，末尾丢弃）。
    var prev = await one(x.tex);
    for (var i = 1; i < 3; i++) {
      final cur = await one(prev);
      prev.dispose();
      prev = cur;
    }
    prev.dispose();
    final sw = Stopwatch()..start();
    prev = await one(x.tex); // 第 0 个正式 pass：输入为上传纹理
    for (var i = 1; i < kPasses; i++) {
      final cur = await one(prev);
      prev.dispose();
      prev = cur;
    }
    prev.dispose();
    final ms = sw.elapsedMilliseconds;
    say('TOIMAGE_PROBE sceneChain ${kPasses}pass = ${ms}ms '
        '(per-pass ${(ms / kPasses).toStringAsFixed(1)}ms)');
  } catch (e) {
    say('TOIMAGE_PROBE_ERROR sceneChain $e');
  }

  say('TOIMAGE_PROBE 完成。判读：syncChain 慢而 asyncChain/sceneChain 快'
      '且 GPU 有占用 → toImageSync 链式快照落 CPU 光栅化，应改造为异步'
      '提交（scene 路径更快则走合成器管线）；全都相近 → 瓶颈不在提交'
      '方式，需另查光栅后端。');
  x.dispose();
  wgt.dispose();
  dummy.dispose();
  g.dispose();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF202020),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, s, _) => Text(s,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  ));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await probe();
    } catch (e, st) {
      say('TOIMAGE_PROBE_ERROR 顶层 $e\n$st');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(0);
  });
}
