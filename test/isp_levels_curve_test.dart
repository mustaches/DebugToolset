import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/levels_curve.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('levels_curve 模型', () {
    test('参数缺失/损坏时回退恒等曲线', () {
      expect(levelsPointsFromParam(null), kLevelsIdentityPoints);
      expect(levelsPointsFromParam('junk'), kLevelsIdentityPoints);
      expect(levelsPointsFromParam(const []), kLevelsIdentityPoints);
      expect(
          levelsPointsFromParam(const [
            ['a', 1]
          ]),
          kLevelsIdentityPoints);
    });

    test('规范化：排序、钳位、强制端点 x', () {
      final pts = normalizeLevelsPoints([
        [5000.0, 5000.0],
        [100.0, 200.0],
        [-5.0, 100.0],
      ]);
      expect(pts.first[0], 0.0);
      expect(pts.last[0], kLevelsMax.toDouble());
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i][0], greaterThan(pts[i - 1][0]));
      }
      for (final p in pts) {
        expect(p[0], inInclusiveRange(0, kLevelsMax));
        expect(p[1], inInclusiveRange(0, kLevelsMax));
      }
    });

    test('曲线通过所有控制点', () {
      final pts = normalizeLevelsPoints([
        [0.0, 0.0],
        [1024.0, 2048.0],
        [2048.0, 1500.0],
        [4095.0, 4095.0],
      ]);
      for (final p in pts) {
        expect(levelsCurveEval(pts, p[0]), closeTo(p[1], 1e-6));
      }
    });

    test('单调控制点产生单调曲线（无过冲）', () {
      final pts = normalizeLevelsPoints([
        [0.0, 0.0],
        [256.0, 3000.0], // 陡升后平缓：最容易过冲的形态
        [4095.0, 4095.0],
      ]);
      var prev = levelsCurveEval(pts, 0);
      for (var x = 1; x <= kLevelsMax; x++) {
        final y = levelsCurveEval(pts, x.toDouble());
        expect(y, greaterThanOrEqualTo(prev - 1e-9));
        expect(y, inInclusiveRange(-1e-9, kLevelsMax + 1e-9));
        prev = y;
      }
    });

    test('恒等判定与恒等 LUT', () {
      expect(levelsCurveIsIdentity(kLevelsIdentityPoints), isTrue);
      expect(
          levelsCurveIsIdentity(const [
            [0.0, 0.0],
            [2048.0, 2048.0],
            [4095.0, 4095.0],
          ]),
          isTrue);
      expect(
          levelsCurveIsIdentity(const [
            [0.0, 0.0],
            [2048.0, 3000.0],
            [4095.0, 4095.0],
          ]),
          isFalse);
      final lut = levelsCurveLut(kLevelsIdentityPoints);
      expect(lut.length, kLevelsMax + 1);
      for (var x = 0; x <= kLevelsMax; x++) {
        expect(lut[x], x);
      }
    });

    test('levelsPointsFromParam 接受 JSON 解码的嵌套列表', () {
      final pts = levelsPointsFromParam([
        [0, 0],
        [2048, 3000],
        [4095, 4095],
      ]);
      expect(pts.length, 3);
      expect(pts[1], [2048.0, 3000.0]);
    });

    test('curveMode 参数解析：未知/缺失回退 spline', () {
      expect(levelsCurveModeFromParam(null), LevelsCurveMode.spline);
      expect(levelsCurveModeFromParam('junk'), LevelsCurveMode.spline);
      expect(levelsCurveModeFromParam('spline'), LevelsCurveMode.spline);
      expect(levelsCurveModeFromParam('bezier'), LevelsCurveMode.bezier);
      expect(levelsCurveModeFromParam('linear'), LevelsCurveMode.linear);
      expect(levelsCurveModeFromParam('gamma'), LevelsCurveMode.gamma);
    });

    test('gamma 曲线：γ=1 恒等，γ>1 提亮，点-γ 反解往返', () {
      final max = kLevelsMax.toDouble();
      // γ=1 恒等 LUT。
      final lut = levelsCurveLut(kLevelsIdentityPoints,
          mode: LevelsCurveMode.gamma, gamma: 1.0);
      for (var x = 0; x <= kLevelsMax; x++) {
        expect(lut[x], x);
      }
      // 端点恒为端点。
      expect(gammaCurveEval(0, 2.2), 0.0);
      expect(gammaCurveEval(max, 2.2), max);
      // γ=2.2 中间调提亮：y(2048) = 4095·0.5^(1/2.2) ≈ 2988。
      expect(gammaCurveEval(2048, 2.2), closeTo(2988.0, 1.0));
      // γ<1 压暗。
      expect(gammaCurveEval(2048, 0.5), lessThan(2048.0));
      // 点 → γ → 曲线过点 往返一致。
      final g = gammaFromPoint(1024, 2048)!;
      expect(gammaCurveEval(1024, g), closeTo(2048.0, 1e-6));
      // 边界外无法反解。
      expect(gammaFromPoint(0, 100), isNull);
      expect(gammaFromPoint(100, 0), isNull);
      expect(gammaFromPoint(100, max), isNull);
      // eval 走 mode+gamma 通路。
      expect(
          levelsCurveEval(kLevelsIdentityPoints, 2048,
              mode: LevelsCurveMode.gamma, gamma: 2.2),
          closeTo(2988.0, 1.0));
    });

    test('线段法：控制点间直线连接（不平滑）', () {
      final pts = normalizeLevelsPoints([
        [0.0, 0.0],
        [1024.0, 2048.0],
        [2048.0, 1500.0],
        [4095.0, 4095.0],
      ]);
      const mode = LevelsCurveMode.linear;
      // 控制点精确通过。
      for (final p in pts) {
        expect(levelsCurveEval(pts, p[0], mode: mode), closeTo(p[1], 1e-9));
      }
      // 段内中点恰为两端线性插值（样条在此处一般不等于线性值）。
      expect(levelsCurveEval(pts, 512, mode: mode), closeTo(1024.0, 1e-9));
      expect(levelsCurveEval(pts, 1536, mode: mode),
          closeTo((2048.0 + 1500.0) / 2, 1e-9));
      // 恒等点列线段法也是恒等 LUT。
      final lut = levelsCurveLut(kLevelsIdentityPoints, mode: mode);
      for (var x = 0; x <= kLevelsMax; x++) {
        expect(lut[x], x);
      }
    });

    test('贝塞尔法：过首尾端点，中间控制点只牵引不经过', () {
      final pts = normalizeLevelsPoints([
        [0.0, 0.0],
        [1024.0, 3000.0], // 强上拉
        [4095.0, 4095.0],
      ]);
      const mode = LevelsCurveMode.bezier;
      expect(levelsCurveEval(pts, 0, mode: mode), closeTo(0.0, 1e-6));
      expect(levelsCurveEval(pts, 4095, mode: mode), closeTo(4095.0, 1e-3));
      // x=1024 处被中间控制点上拉（大于恒等值 1024），但不过点
      // (1024,3000)——贝塞尔控制多边形的固有特性。
      final y = levelsCurveEval(pts, 1024, mode: mode);
      expect(y, greaterThan(1024.0));
      expect(y, lessThan(3000.0));
      // 全曲线不出值域（x(t) 单调可解）。
      for (var x = 0; x <= kLevelsMax; x++) {
        expect(levelsCurveEval(pts, x.toDouble(), mode: mode),
            inInclusiveRange(-1e-6, kLevelsMax + 1e-6));
      }
      // 恒等点列贝塞尔也是恒等 LUT。
      final lut = levelsCurveLut(kLevelsIdentityPoints, mode: mode);
      for (var x = 0; x <= kLevelsMax; x++) {
        expect(lut[x], x);
      }
    });
  });

  group('applyLevelsCurve 核', () {
    test('maxValue == 4095 直通查表', () {
      // 反相曲线：(0,4095) → (4095,0)。
      final lut = levelsCurveLut(const [
        [0.0, 4095.0],
        [4095.0, 0.0],
      ]);
      final src = Uint16List.fromList([0, 100, 4095, 2048, 0, 4095]);
      final out = applyLevelsCurve(src, lut, maxValue: 4095);
      expect(out[0], 4095);
      expect(out[2], 0);
      expect(out[1], 4095 - 100);
      expect(out[3], 4095 - 2048);
    });

    test('maxValue 缩放任：8bit 帧恒等 LUT 近似回读', () {
      final lut = levelsCurveLut(kLevelsIdentityPoints);
      final src = Uint16List.fromList([0, 128, 255, 64, 192, 255]);
      final out = applyLevelsCurve(src, lut, maxValue: 255);
      for (var i = 0; i < src.length; i++) {
        expect(out[i], closeTo(src[i], 1));
      }
    });

    test('8bit 帧反相', () {
      final lut = levelsCurveLut(const [
        [0.0, 4095.0],
        [4095.0, 0.0],
      ]);
      final src = Uint16List.fromList([0, 255, 128]);
      final out = applyLevelsCurve(src, lut, maxValue: 255);
      expect(out[0], 255);
      expect(out[1], 0);
      expect(out[2], closeTo(127, 1));
    });
  });

  group('levels_curves 流水线集成（image → levels → preview）', () {
    test('传递函数拉黑输出：输入直方图生成、预览全黑', () async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final srcId = state.graph.addNode('image_source', 0, 0);
      final levelsId = state.graph.addNode('levels_curves', 220, 0);
      final pvId = state.graph.addNode('preview', 520, 0);
      state.setParam(srcId, 'filePath', 'IspFlow/DemoPhoto/1.jpg');
      // (0,0)-(4095,0)：所有输入映射到 0，输出应为纯黑。
      state.setParam(levelsId, 'points', [
        [0.0, 0.0],
        [4095.0, 0.0],
      ]);
      expect(state.graph.connect(srcId, 'out_rgb', levelsId, 'in'), isNull);
      expect(state.graph.connect(levelsId, 'out', pvId, 'in'), isNull);

      await state.runPreview();
      expect(state.statusMessage, contains('预览就绪'),
          reason: '预览应成功: ${state.statusMessage}');

      // 输入 Y 直方图已生成且非空。
      final hist = state.levelsHistograms[levelsId];
      expect(hist, isNotNull, reason: '曲线调节器应有输入直方图');
      expect(hist!.fold<int>(0, (s, c) => s + c), greaterThan(0),
          reason: '直方图计数不应全为 0');

      // 预览图 RGB 全 0。
      final img = state.previewImages[pvId];
      expect(img, isNotNull, reason: '预览图应已生成');
      final byteData =
          await img!.toByteData(format: ui.ImageByteFormat.rawRgba);
      final px = byteData!.buffer.asUint8List();
      var sum = 0;
      for (var i = 0; i < px.length; i += 4) {
        sum += px[i] + px[i + 1] + px[i + 2];
      }
      expect(sum, 0, reason: '传递函数 (0,0)-(4095,0) 应把输出拉黑');
    });

    test('curveMode 参数贯通：linear 模式拉黑输出', () async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final srcId = state.graph.addNode('image_source', 0, 0);
      final levelsId = state.graph.addNode('levels_curves', 220, 0);
      final pvId = state.graph.addNode('preview', 520, 0);
      state.setParam(srcId, 'filePath', 'IspFlow/DemoPhoto/1.jpg');
      state.setParam(levelsId, 'curveMode', 'linear');
      state.setParam(levelsId, 'points', [
        [0.0, 0.0],
        [4095.0, 0.0],
      ]);
      expect(state.graph.connect(srcId, 'out_rgb', levelsId, 'in'), isNull);
      expect(state.graph.connect(levelsId, 'out', pvId, 'in'), isNull);

      await state.runPreview();
      expect(state.statusMessage, contains('预览就绪'),
          reason: '预览应成功: ${state.statusMessage}');
      final img = state.previewImages[pvId];
      expect(img, isNotNull, reason: '预览图应已生成');
      final byteData =
          await img!.toByteData(format: ui.ImageByteFormat.rawRgba);
      final px = byteData!.buffer.asUint8List();
      var sum = 0;
      for (var i = 0; i < px.length; i += 4) {
        sum += px[i] + px[i + 1] + px[i + 2];
      }
      expect(sum, 0, reason: 'linear 模式下 (0,0)-(4095,0) 应把输出拉黑');
    });

    test('默认恒等曲线：输出图像内容不变', () async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final srcId = state.graph.addNode('image_source', 0, 0);
      final levelsId = state.graph.addNode('levels_curves', 220, 0);
      final pvId = state.graph.addNode('preview', 520, 0);
      state.setParam(srcId, 'filePath', 'IspFlow/DemoPhoto/1.jpg');
      // 不写 points 参数：默认恒等曲线，核内直通。
      expect(state.graph.connect(srcId, 'out_rgb', levelsId, 'in'), isNull);
      expect(state.graph.connect(levelsId, 'out', pvId, 'in'), isNull);

      await state.runPreview();
      expect(state.statusMessage, contains('预览就绪'),
          reason: '预览应成功: ${state.statusMessage}');
      final img = state.previewImages[pvId];
      expect(img, isNotNull);
      final byteData =
          await img!.toByteData(format: ui.ImageByteFormat.rawRgba);
      final px = byteData!.buffer.asUint8List();
      var sum = 0;
      for (var i = 0; i < px.length; i += 4) {
        sum += px[i] + px[i + 1] + px[i + 2];
      }
      expect(sum, greaterThan(0), reason: '恒等曲线不应改变图像内容');
    });

    test('GPU 路径：节点标 GPU，输入/输出直方图由回读生成', () async {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final srcId = state.graph.addNode('image_source', 0, 0);
      final levelsId = state.graph.addNode('levels_curves', 220, 0);
      final pvId = state.graph.addNode('preview', 520, 0);
      state.setParam(srcId, 'filePath', 'IspFlow/DemoPhoto/1.jpg');
      // 非恒等提亮曲线（spline）。
      state.setParam(levelsId, 'points', [
        [0.0, 0.0],
        [2048.0, 3200.0],
        [4095.0, 4095.0],
      ]);
      expect(state.graph.connect(srcId, 'out_rgb', levelsId, 'in'), isNull);
      expect(state.graph.connect(levelsId, 'out', pvId, 'in'), isNull);

      await state.runPreview();
      expect(state.statusMessage, contains('预览就绪'),
          reason: '预览应成功: ${state.statusMessage}');
      // 链被 GPU 覆盖：节点与预览均标 GPU 后端。
      expect(state.nodeRunOnGpu[levelsId], isTrue, reason: '曲线调节器应走 GPU');
      expect(state.nodeRunOnGpu[pvId], isTrue);
      // GPU 覆盖时 CPU 闭包不执行：输入/输出 Y 直方图须由回读补齐。
      expect(state.levelsHistograms[levelsId], isNotNull,
          reason: 'GPU 覆盖时输入直方图应由回读生成');
      expect(state.levelsOutputHistograms[levelsId], isNotNull,
          reason: 'GPU 覆盖时输出直方图应由回读生成');
      final inHist = state.levelsHistograms[levelsId]!;
      final outHist = state.levelsOutputHistograms[levelsId]!;
      expect(inHist.fold<int>(0, (s, c) => s + c), greaterThan(0));
      expect(outHist.fold<int>(0, (s, c) => s + c), greaterThan(0));
      // 提亮曲线生效：输出直方图均值应大于输入。
      double meanOf(Uint32List hist) {
        var s = 0.0, c = 0.0;
        for (var i = 0; i < hist.length; i++) {
          s += hist[i] * i;
          c += hist[i];
        }
        return s / c;
      }

      expect(meanOf(outHist), greaterThan(meanOf(inHist)),
          reason: '提亮曲线的输出 Y 均值应高于输入');
    });
  });
}
