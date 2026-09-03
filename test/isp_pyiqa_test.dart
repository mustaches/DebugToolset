// 深度评价节点（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA）测试：
// 节点注册、结果显示、PyIqaWorker 协议与端到端对拍。
//
// 节点运行时优先走进程内 Dart 计算（_analyzeDeepIqa，权重
// tools/iqa/weights/*.nnw），Python 桥接降级为回退路径；state 层
// 用例权重齐全即可运行（无需 eval_venv），PyIqaWorker 组的对拍
// 用例仍需 scratch/eval_venv（torch/torchmetrics/lpips/pyiqa），
// 环境缺失时自动跳过。基线值由 tools/iqa/iqa_bridge.py 一次性模式
// 对同帧实跑记录（busyFrame 干净/加噪对，同 test/isp_piqe_test.dart）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/clipiqa_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/musiq_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_widget.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 256x192 高纹理彩色测试帧（与 Python 参考对拍同款图案，
  /// 同 test/isp_piqe_test.dart 的 busyFrame）。
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

  group('深度评价节点注册', () {
    test('6 个类型注册，端口布局与显示名正确', () {
      for (final (id, name) in [
        ('lpips', 'LPIPS 数字表'),
        ('dists', 'DISTS 数字表'),
        ('fid', 'FID 数字表'),
        ('kid', 'KID 数字表'),
        ('musiq', 'MUSIQ 数字表'),
        ('clipiqa', 'CLIPIQA 数字表'),
      ]) {
        final type = IspNodeRegistry.byId(id);
        expect(type, isNotNull, reason: '$id 未注册');
        expect(type!.displayName, name);
        expect(type.outputs, isEmpty, reason: '$id 应为只进不出');
        expect(instrumentTypes.contains(id), isTrue);
        expect(sinkNodeTypes.contains(id), isTrue);
      }
      // 双输入（pair/dist）：8 端口（参考/测试 × 四域）。
      for (final id in ['lpips', 'dists', 'fid', 'kid']) {
        final type = IspNodeRegistry.byId(id)!;
        expect(type.inputs, hasLength(8), reason: '$id 应为 8 端口双输入');
        expect(type.inputPort('in'), isNotNull);
        expect(type.inputPort('in_test_mono')!.type, IspPortType.mono);
      }
      // 单输入（single）：4 端口四域选一。
      for (final id in ['musiq', 'clipiqa']) {
        final type = IspNodeRegistry.byId(id)!;
        expect(type.inputs, hasLength(4), reason: '$id 应为 4 端口单输入');
        expect(type.inputPort('in'), isNotNull);
      }
    });

    test('pyIqaMetrics 元信息与桥接 META 一致', () {
      expect(pyIqaMetrics['lpips']!.kind, 'pair');
      expect(pyIqaMetrics['dists']!.kind, 'pair');
      expect(pyIqaMetrics['fid']!.kind, 'dist');
      expect(pyIqaMetrics['kid']!.kind, 'dist');
      expect(pyIqaMetrics['musiq']!.kind, 'single');
      expect(pyIqaMetrics['clipiqa']!.kind, 'single');
      expect(pyIqaMetrics['musiq']!.lowerBetter, isFalse);
      expect(pyIqaMetrics['clipiqa']!.lowerBetter, isFalse);
      for (final id in ['lpips', 'dists', 'fid', 'kid']) {
        expect(pyIqaMetrics[id]!.lowerBetter, isTrue);
      }
    });
  });

  group('节点显示', () {
    Widget wrapNode(IspStudioState state, Widget child) =>
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(home: Scaffold(body: Center(child: child))),
        );

    Future<void> pumpNode(WidgetTester tester, IspStudioState state,
        String typeId, Map<String, Object?> result) async {
      final type = IspNodeRegistry.byId(typeId)!;
      final node = IspNode.create(type, '${typeId}1', 0, 0);
      state.graph.nodes[node.id] = node;
      state.instrumentResults[node.id] = result;
      await tester.pumpWidget(wrapNode(
        state,
        IspNodeWidget(
          node: node,
          type: type,
          selected: false,
          globalToCanvas: (o) => o,
          onConnectionDragEnd: () {},
          onToggleMaximize: () {},
          inputPortKeyFor: (_) => GlobalKey(),
        ),
      ));
      await tester.pump();
    }

    testWidgets('LPIPS 数字表显示分值、标签与「越小越好」', (tester) async {
      final state = IspStudioState();
      await pumpNode(
          tester, state, 'lpips', {'kind': 'lpips', 'lpips': 0.1234});
      expect(find.text('0.1234'), findsOneWidget);
      expect(find.text('LPIPS'), findsOneWidget);
      expect(find.text('越小越好'), findsOneWidget);
    });

    testWidgets('MUSIQ 数字表显示分值与「越大越好」', (tester) async {
      final state = IspStudioState();
      await pumpNode(tester, state, 'musiq', {'kind': 'musiq', 'musiq': 55.0});
      expect(find.text('55.0000'), findsOneWidget);
      expect(find.text('MUSIQ'), findsOneWidget);
      expect(find.text('越大越好'), findsOneWidget);
    });

    testWidgets('FID 样本不足显示累计进度，出分后显示分值与帧数', (tester) async {
      final state = IspStudioState();
      // 累计中（任一侧 <2 帧）。
      await pumpNode(
          tester, state, 'fid', {'kind': 'fid', 'n_ref': 1, 'n_test': 1});
      expect(find.text('…'), findsOneWidget);
      expect(find.textContaining('累计中'), findsOneWidget);
      // 出分后。
      state.instrumentResults['fid1'] = {
        'kind': 'fid',
        'fid': 12.3456,
        'n_ref': 5,
        'n_test': 5,
      };
      state.instrumentTick.value++;
      await tester.pump();
      expect(find.text('12.3456'), findsOneWidget);
      expect(find.textContaining('5v5 样本'), findsOneWidget);
    });

    testWidgets('错误结果（Python 环境缺失等）显示提示文本', (tester) async {
      final state = IspStudioState();
      await pumpNode(tester, state, 'lpips',
          {'kind': 'lpips', 'error': '需要 Python 环境'});
      expect(find.text('需要 Python 环境'), findsOneWidget);
    });
  });

  group('IspStudioState 深度评价分析', () {
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
      final file = File('${Directory.systemTemp.path}/isp_pyiqa_$stamp.bmp');
      await file.writeAsBytes(img.encodeBmp(image));
      return file;
    }

    test('运行预览后拿到 MUSIQ 分值（进程内 Dart 计算，无需 Python）',
        () async {
      if (!deepIqaWeightsAvailable('musiq')) return;
      final file = await writeTempBmp();
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('image_source', 0, 0);
        final musiqId = state.graph.addNode('musiq', 300, 0);
        expect(state.graph.connect(srcId, 'out_rgb', musiqId, 'in'), isNull);
        state.setParam(srcId, 'filePath', file.path);

        await state.runPreview();
        final result = state.instrumentResults[musiqId];
        expect(result, isNotNull, reason: 'MUSIQ 数字表应有分析结果');
        expect(result!['kind'], 'musiq');
        expect(result['error'], isNull);
        // 与直接调用进程内实现同口径比对（馈源 2x 降采样：
        // 256×192 → 128×96，见 _downsampleFeed）。
        final (d, dw, dh) = downsampleRgba82x(busyFrame(), 256, 192);
        final expected = await musiqScoreParallel(d, dw, dh);
        expect(result['musiq'] as double, closeTo(expected, 1e-6));
      } finally {
        await file.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('FID 静态图对单次运行即出分（patch 口径，进程内 Dart 计算）',
        () async {
      if (!deepIqaWeightsAvailable('fid')) return;
      final fileA = await writeTempBmp();
      final fileB = await writeTempBmp(noisy: true);
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final refId = state.graph.addNode('image_source', 0, 0);
        final testId = state.graph.addNode('image_source', 0, 200);
        final fidId = state.graph.addNode('fid', 300, 100);
        expect(state.graph.connect(refId, 'out_rgb', fidId, 'in'), isNull);
        expect(
            state.graph.connect(testId, 'out_rgb', fidId, 'in_test'), isNull);
        state.setParam(refId, 'filePath', fileA.path);
        state.setParam(testId, 'filePath', fileB.path);

        await state.runPreview();
        final result = state.instrumentResults[fidId];
        expect(result, isNotNull, reason: 'FID 数字表应有分析结果');
        expect(result!['kind'], 'fid');
        expect(result['error'], isNull);
        // patch 口径：馈源 2x 降采样后 128×96 → 每侧 2 块
        // （s=96，x 向 {0,32}），静态图对单次运行即可出分
        // （此前按帧累计，静态源永远卡在「累计中」）。
        expect(result['n_ref'], 2);
        expect(result['n_test'], 2);
        expect(result['fid'] as double, isNotNull);
      } finally {
        await fileA.delete();
        await fileB.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('Python 环境缺失但权重齐全时进程内 Dart 出分（CLIPIQA）', () async {
      if (!deepIqaWeightsAvailable('clipiqa')) return;
      final saved = pyIqaPythonPath;
      pyIqaPythonPath = 'scratch/eval_venv/Scripts/__nonexistent__.exe';
      PyIqaWorker.resetRegistry();
      final file = await writeTempBmp();
      try {
        final state = IspStudioState();
        addTearDown(state.dispose);
        final srcId = state.graph.addNode('image_source', 0, 0);
        final clipiqaId = state.graph.addNode('clipiqa', 300, 0);
        expect(
            state.graph.connect(srcId, 'out_rgb', clipiqaId, 'in'), isNull);
        state.setParam(srcId, 'filePath', file.path);

        await state.runPreview();
        final result = state.instrumentResults[clipiqaId];
        expect(result, isNotNull);
        expect(result!['error'], isNull, reason: '权重齐全时不应再需要 Python');
        final (d, dw, dh) = downsampleRgba82x(busyFrame(), 256, 192);
        final expected = await clipiqaScoreParallel(d, dw, dh);
        expect(result['clipiqa'] as double, closeTo(expected, 1e-6));
      } finally {
        pyIqaPythonPath = saved;
        PyIqaWorker.resetRegistry();
        await file.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('PyIqaWorker', () {
    test('Python 环境缺失时 available 为 false 且请求报清晰错误', () async {
      final saved = pyIqaPythonPath;
      pyIqaPythonPath = 'scratch/eval_venv/Scripts/__nonexistent__.exe';
      PyIqaWorker.resetRegistry();
      try {
        expect(PyIqaWorker.available, isFalse);
        expect(
          () => PyIqaWorker.forMetric('lpips').pairScore('a.png', 'b.png'),
          throwsA(isA<StateError>()),
        );
      } finally {
        pyIqaPythonPath = saved;
        PyIqaWorker.resetRegistry();
      }
    });

    test('与桥接进程端到端对拍（busyFrame 对，需 eval_venv）', () async {
      if (!PyIqaWorker.available) return; // 无 Python 环境时跳过
      const w = 256, h = 192;
      final aPath = await pyIqaWriteTempPng(busyFrame(), w, h);
      final bPath = await pyIqaWriteTempPng(busyFrame(noisy: true), w, h);

      // 基线：tools/iqa/iqa_bridge.py 一次性模式对同帧实跑
      // （scratch/eval_a.png / eval_b.png）。
      final lpipsV =
          await PyIqaWorker.forMetric('lpips').pairScore(aPath, bPath);
      expect(lpipsV, closeTo(0.2554149, 1e-3));
      final distsV =
          await PyIqaWorker.forMetric('dists').pairScore(aPath, bPath);
      expect(distsV, closeTo(0.2894047, 1e-2));
      final musiqV = await PyIqaWorker.forMetric('musiq').singleScore(aPath);
      expect(musiqV, closeTo(22.4998, 0.5));
      final clipiqaV =
          await PyIqaWorker.forMetric('clipiqa').singleScore(aPath);
      expect(clipiqaV, closeTo(0.47982, 0.01));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('FID/KID 逐块累计与复位（需 eval_venv）', () async {
      if (!PyIqaWorker.available) return;
      const w = 256, h = 192;
      final frames = [
        for (var i = 0; i < 3; i++) ...[
          await pyIqaWriteTempPng(busyFrame(noiseSeed: i), w, h),
          await pyIqaWriteTempPng(busyFrame(noisy: true, noiseSeed: i), w, h),
        ],
      ];
      for (final metric in ['fid', 'kid']) {
        final worker = PyIqaWorker.forMetric(metric);
        await worker.distReset();
        // 复位后无样本，不出分。
        expect(await worker.distScore(), isNull);
        // patch 口径：256×192 → 299 边长截到 192，x 向 {0,64} 两块，
        // 每次 add 每侧累计 2 个样本——静态图对一次 add 即可出分。
        await worker.distAdd('ref', frames[0]);
        await worker.distAdd('test', frames[1]);
        final s1 = await worker.distScore();
        expect(s1, isNotNull, reason: '$metric 两个样本即应出分');
        expect(s1!.$2, 2);
        expect(s1.$3, 2);
        expect(s1.$1.isFinite, isTrue);
        // 继续累计：计数随块数增长。
        await worker.distAdd('ref', frames[2]);
        await worker.distAdd('test', frames[3]);
        await worker.distAdd('ref', frames[4]);
        await worker.distAdd('test', frames[5]);
        final s2 = await worker.distScore();
        expect(s2, isNotNull);
        expect(s2!.$2, 6);
        expect(s2.$3, 6);
        // 复位后回到无样本状态。
        await worker.distReset();
        expect(await worker.distScore(), isNull);
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
