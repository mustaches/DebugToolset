// 深度评价节点进程内 Dart 计算（_analyzeDeepIqa）的 state 层集成测试：
// 权重齐全（tools/iqa/weights/*.nnw）时无需 Python 环境即可出分——
// 用不存在的 python 路径强制证明不依赖桥接；权重缺失且 Python 缺失
// 时给出「需要权重文件…」提示；FID/KID 接同一对源时共享 Inception
// patch 特征并逐帧累计出分。
//
// 权重缺失时自动跳过出分类用例（同 test/isp_lpips_dists_dart_test.dart
// 的跳过模式）。busyFrame 图案与 test/isp_pyiqa_test.dart 相同。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/lpips_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/vgg16_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clip_rn50_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_v3_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  // flutter_tester 是软件光栅（SkVM）：VGG16/RN50 GPU 驻留链在上面要跑
  // 分钟级，本文件的用例统一关闭 GPU 路径走 CPU 池（GPU 链由
  // test/isp_nn_gpu_vgg_test.dart / test/isp_nn_gpu_rn50_test.dart
  // 单独覆盖）。
  Vgg16AsyncForward.enabled = false;
  ClipRn50Gpu.enabled = false;
  InceptionV3Gpu.enabled = false;

  /// 256x192 高纹理彩色测试帧（同 test/isp_pyiqa_test.dart）。
  Uint8List busyFrame({bool noisy = false, int noiseSeed = 0}) {
    const w = 256, h = 192;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        var r = (128 +
                70 * math.sin(x / 3.1) * math.cos(y / 2.7) +
                40 * math.sin((x + 2 * y) / 5.3))
            .clamp(0.0, 255.0)
            .toInt();
        var g = (128 +
                70 * math.cos(x / 4.1) * math.sin(y / 3.3) +
                40 * math.cos((2 * x - y) / 6.7))
            .clamp(0.0, 255.0)
            .toInt();
        var b = (128 +
                70 * math.sin((x - y) / 3.7) * math.cos((x + y) / 4.9))
            .clamp(0.0, 255.0)
            .toInt();
        if (noisy) {
          // 确定性噪声（元素序按 RGB 三通道计）。
          final base = ((y * w + x) * 3) + noiseSeed * 7;
          r = (r + (base * 31) % 61 - 30).clamp(0, 255);
          g = (g + ((base + 1) * 31) % 61 - 30).clamp(0, 255);
          b = (b + ((base + 2) * 31) % 61 - 30).clamp(0, 255);
        }
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  /// 用 busyFrame 写一张临时 BMP（image_source 节点输入）。
  Future<File> writeTempBmp({bool noisy = false}) async {
    final frame = busyFrame(noisy: noisy);
    final image = img.Image(width: 256, height: 192);
    for (var y = 0; y < 192; y++) {
      for (var x = 0; x < 256; x++) {
        final i = (y * 256 + x) * 4;
        image.setPixelRgb(x, y, frame[i], frame[i + 1], frame[i + 2]);
      }
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File('${Directory.systemTemp.path}/isp_deep_iqa_$stamp.bmp');
    await file.writeAsBytes(img.encodeBmp(image));
    return file;
  }

  /// 双 image_source（干净/加噪）→ 双输入评价节点的图骨架。
  (IspStudioState, String) dualGraph(String metricId, File a, File b) {
    final state = IspStudioState();
    final refId = state.graph.addNode('image_source', 0, 0);
    final testId = state.graph.addNode('image_source', 0, 200);
    final metricNodeId = state.graph.addNode(metricId, 300, 100);
    expect(state.graph.connect(refId, 'out_rgb', metricNodeId, 'in'), isNull);
    expect(state.graph.connect(testId, 'out_rgb', metricNodeId, 'in_test'),
        isNull);
    state.setParam(refId, 'filePath', a.path);
    state.setParam(testId, 'filePath', b.path);
    return (state, metricNodeId);
  }

  group('进程内 Dart 计算（权重齐全，无需 Python）', () {
    test('LPIPS 双输入节点出分并与直接调用一致', () async {
      if (!deepIqaWeightsAvailable('lpips')) return;
      // 强制 Python 桥接不可用，证明进程内路径不依赖 Python。
      final saved = pyIqaPythonPath;
      pyIqaPythonPath = 'scratch/eval_venv/Scripts/__nonexistent__.exe';
      PyIqaWorker.resetRegistry();
      final fileA = await writeTempBmp();
      final fileB = await writeTempBmp(noisy: true);
      try {
        final (state, lpipsId) = dualGraph('lpips', fileA, fileB);
        addTearDown(state.dispose);

        await state.runPreview();
        final result = state.instrumentResults[lpipsId];
        expect(result, isNotNull, reason: 'LPIPS 数字表应有分析结果');
        expect(result!['kind'], 'lpips');
        expect(result['error'], isNull);
        // 与直接调用进程内实现同口径比对（馈源 2x 降采样：
        // 256×192 → 128×96，见 _downsampleFeed）。
        final (da, dw, dh) = downsampleRgba82x(busyFrame(), 256, 192);
        final (db, _, _) = downsampleRgba82x(busyFrame(noisy: true), 256, 192);
        final expected = await lpipsScoreParallel(da, db, dw, dh);
        expect(result['lpips'] as double, closeTo(expected, 1e-6));
        expect(result['lpips'] as double, inInclusiveRange(0.0, 1.0));
        // 右侧「节点流程图」面板的耗时与 GPU/CPU 徽标：仪器分析路径
        // 必须回填（flutter test 为软件光栅，VGG16 GPU 链不可用或
        // 预检拒绝，实际后端为 CPU）。
        expect(state.nodeRunTimesUs[lpipsId], isNotNull,
            reason: '仪器节点应回填运行耗时');
        expect(state.nodeRunTimesUs[lpipsId]!, greaterThan(0));
        expect(state.nodeRunOnGpu[lpipsId], isFalse);
      } finally {
        pyIqaPythonPath = saved;
        PyIqaWorker.resetRegistry();
        await fileA.delete();
        await fileB.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('DISTS 双输入节点出分并在合理值域', () async {
      if (!deepIqaWeightsAvailable('dists')) return;
      final saved = pyIqaPythonPath;
      pyIqaPythonPath = 'scratch/eval_venv/Scripts/__nonexistent__.exe';
      PyIqaWorker.resetRegistry();
      final fileA = await writeTempBmp();
      final fileB = await writeTempBmp(noisy: true);
      try {
        final (state, distsId) = dualGraph('dists', fileA, fileB);
        addTearDown(state.dispose);

        await state.runPreview();
        final result = state.instrumentResults[distsId];
        expect(result, isNotNull, reason: 'DISTS 数字表应有分析结果');
        expect(result!['kind'], 'dists');
        expect(result['error'], isNull);
        final v = result['dists'] as double;
        expect(v.isFinite, isTrue);
        // 加噪图与干净图应可区分（DISTS > 0 且远小于饱和值）。
        expect(v, greaterThan(0.0));
        expect(v, lessThan(1.0));
      } finally {
        pyIqaPythonPath = saved;
        PyIqaWorker.resetRegistry();
        await fileA.delete();
        await fileB.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('FID/KID 接同一对源各自出分（特征共享、patch 累计）', () async {
      if (!deepIqaWeightsAvailable('fid') ||
          !deepIqaWeightsAvailable('kid')) {
        return;
      }
      final saved = pyIqaPythonPath;
      pyIqaPythonPath = 'scratch/eval_venv/Scripts/__nonexistent__.exe';
      PyIqaWorker.resetRegistry();
      final fileA = await writeTempBmp();
      final fileB = await writeTempBmp(noisy: true);
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final refId = state.graph.addNode('image_source', 0, 0);
        final testId = state.graph.addNode('image_source', 0, 200);
        final fidId = state.graph.addNode('fid', 300, 0);
        final kidId = state.graph.addNode('kid', 300, 200);
        state.setParam(refId, 'filePath', fileA.path);
        state.setParam(testId, 'filePath', fileB.path);
        for (final metricId in [fidId, kidId]) {
          expect(state.graph.connect(refId, 'out_rgb', metricId, 'in'),
              isNull);
          expect(
              state.graph.connect(testId, 'out_rgb', metricId, 'in_test'),
              isNull);
        }

        await state.runPreview();
        for (final (id, key) in [(fidId, 'fid'), (kidId, 'kid')]) {
          final result = state.instrumentResults[id];
          expect(result, isNotNull, reason: '$key 数字表应有分析结果');
          expect(result!['kind'], key);
          expect(result['error'], isNull, reason: '$key 不应报错');
          // 馈源 128×96 → 每帧 2 patch（s=96，x 向 {0,32}），静态图对
          // 单次运行即各累计 2 样本出分。
          expect(result['n_ref'], 2, reason: '$key n_ref');
          expect(result['n_test'], 2, reason: '$key n_test');
          expect(result[key] as double, isNotNull);
          expect((result[key] as double).isFinite, isTrue);
        }
      } finally {
        pyIqaPythonPath = saved;
        PyIqaWorker.resetRegistry();
        await fileA.delete();
        await fileB.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });

  group('权重缺失回退', () {
    test('deepIqaWeightsAvailable 反映权重文件存在性', () {
      final saved = deepIqaWeightFiles['lpips']!;
      try {
        deepIqaWeightFiles['lpips'] = [
          'tools/iqa/weights/__nonexistent__.nnw'
        ];
        expect(deepIqaWeightsAvailable('lpips'), isFalse);
      } finally {
        deepIqaWeightFiles['lpips'] = saved;
      }
    });

    test('权重与 Python 均缺失时返回「需要权重文件」提示', () async {
      final savedWeights = deepIqaWeightFiles['lpips']!;
      final savedPython = pyIqaPythonPath;
      deepIqaWeightFiles['lpips'] = ['tools/iqa/weights/__nonexistent__.nnw'];
      pyIqaPythonPath = 'scratch/eval_venv/Scripts/__nonexistent__.exe';
      PyIqaWorker.resetRegistry();
      final fileA = await writeTempBmp();
      final fileB = await writeTempBmp(noisy: true);
      try {
        final (state, lpipsId) = dualGraph('lpips', fileA, fileB);
        addTearDown(state.dispose);

        await state.runPreview();
        final result = state.instrumentResults[lpipsId];
        expect(result, isNotNull);
        expect(result!['kind'], 'lpips');
        expect(result['error'] as String, contains('需要权重文件'));
        expect(result['error'] as String, contains('Python'));
      } finally {
        deepIqaWeightFiles['lpips'] = savedWeights;
        pyIqaPythonPath = savedPython;
        PyIqaWorker.resetRegistry();
        await fileA.delete();
        await fileB.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
