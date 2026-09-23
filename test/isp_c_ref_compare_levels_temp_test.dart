/// Dart↔C 对拍：levels / 色温组 —— levels_lut（levelsCurveLut）、
/// levels_apply（applyLevelsCurve）、color_temp_gains / whitepoint / ccm /
/// measure_cct（color_temp.dart 公开函数）。
///
/// C 侧：test/c_ref/harness_levels_temp.c ->
/// lib/modules/isp_studio/c_ref/isp_levels.c、isp_color_temp.c。
/// Dart 侧基准：
/// - lib/modules/isp_studio/pipeline/levels_curve.dart
///   `normalizeLevelsPoints` + `levelsCurveLut`；
/// - lib/modules/isp_studio/pipeline/isp_kernels.dart `applyLevelsCurve`；
/// - lib/modules/isp_studio/pipeline/color_temp.dart `colorTempGains` /
///   `cctToWhitePoint` / `colorTempCcm` / `measureCctFromRgba`。
///
/// 控制点经 params 字符串 "x0,y0;x1,y1;..." 传递（harness 侧 strtod 解析，
/// 与 Dart double.toString 最短往返表示精确往返）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/color_temp.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/levels_curve.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_levels_temp';

/// 控制点编码为 params 字符串（与 harness parse_points 对应）。
String encodePoints(List<List<double>> pts) =>
    pts.map((p) => '${p[0]},${p[1]}').join(';');

/// Dart 侧 LUT 基准：先 normalize（与 harness 内 isp_levels_normalize_points
/// 对应），再生成 4096 级 LUT。gamma 模式忽略控制点。
Uint16List dartLevelsLut(List<List<double>> points, String mode, double gamma) {
  final pts = normalizeLevelsPoints(points);
  return levelsCurveLut(pts,
      mode: levelsCurveModeFromParam(mode), gamma: gamma);
}

/// 确定性 LCG RGBA8888 帧（measure_cct 输入）。
Uint8List lcgRgbaFrame(int width, int height, int seed) {
  final out = Uint8List(width * height * 4);
  var state = seed & 0xFFFFFFFF;
  for (var i = 0; i < width * height; i++) {
    for (var c = 0; c < 3; c++) {
      state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
      out[i * 4 + c] = (state >> 16) & 0xFF;
    }
    out[i * 4 + 3] = 255;
  }
  return out;
}

/// 标量比对（默认 tol=0 即 double 完全相等；%.17g 精确往返）。
void expectScalarEqual(Map<String, double> scalars, String key, double expected,
    {String context = '', double tol = 0}) {
  final actual = scalars[key];
  expect(actual, isNotNull, reason: '$context: 缺标量 $key');
  final d = (actual! - expected).abs();
  if (d > tol) {
    fail('$context: 标量 $key actual=$actual expected=$expected '
        'd=$d tol=$tol');
  }
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_levels_temp: levels / 色温 C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    group('levels_lut', () {
      test('spline 单调 5 控制点', () async {
        const pts = [
          [0.0, 0.0],
          [1024.0, 1536.0],
          [2048.0, 2048.0],
          [3072.0, 2560.0],
          [4095.0, 4095.0],
        ];
        final c = await runCOp('levels_lut',
            params: {'mode': 'spline', 'points': encodePoints(pts)},
            tag: _tag);
        expectFramesEqual(c.outputs[0], dartLevelsLut(pts, 'spline', 1.0),
            context: 'spline 单调 5 点');
      });

      test('spline 非单调控制点（Fritsch–Carlson 约束路径）', () async {
        const pts = [
          [0.0, 0.0],
          [1000.0, 3200.0],
          [2000.0, 1200.0],
          [3000.0, 3600.0],
          [4095.0, 4095.0],
        ];
        final c = await runCOp('levels_lut',
            params: {'mode': 'spline', 'points': encodePoints(pts)},
            tag: _tag);
        expectFramesEqual(c.outputs[0], dartLevelsLut(pts, 'spline', 1.0),
            context: 'spline 非单调');
      });

      test('spline 乱序+重复 x+越界点（normalize 钳位/排序/去重）', () async {
        // 故意乱序、重复 x=2000（保后者）、越界 x=-100 与 y=6000。
        const pts = [
          [4095.0, 4095.0],
          [2000.0, 2000.0],
          [-100.0, 6000.0],
          [2000.0, 2500.0],
          [0.0, 0.0],
        ];
        final c = await runCOp('levels_lut',
            params: {'mode': 'spline', 'points': encodePoints(pts)},
            tag: _tag);
        expectFramesEqual(c.outputs[0], dartLevelsLut(pts, 'spline', 1.0),
            context: 'spline normalize 路径');
      });

      test('bezier 4 控制点（二分反解 + De Casteljau）', () async {
        const pts = [
          [0.0, 0.0],
          [1024.0, 3000.0],
          [2048.0, 500.0],
          [4095.0, 4095.0],
        ];
        final c = await runCOp('levels_lut',
            params: {'mode': 'bezier', 'points': encodePoints(pts)},
            tag: _tag);
        expectFramesEqual(c.outputs[0], dartLevelsLut(pts, 'bezier', 1.0),
            context: 'bezier 4 点');
      });

      test('linear 4 控制点（含小数坐标）', () async {
        const pts = [
          [0.0, 0.0],
          [1000.5, 800.25],
          [2500.0, 3000.75],
          [4095.0, 4095.0],
        ];
        final c = await runCOp('levels_lut',
            params: {'mode': 'linear', 'points': encodePoints(pts)},
            tag: _tag);
        expectFramesEqual(c.outputs[0], dartLevelsLut(pts, 'linear', 1.0),
            context: 'linear 4 点');
      });

      test('gamma 多值（2.2 / 0.5 / 1.0，忽略控制点）', () async {
        for (final gamma in [2.2, 0.5, 1.0]) {
          final c = await runCOp('levels_lut',
              params: {'mode': 'gamma', 'gamma': gamma}, tag: _tag);
          expectFramesEqual(c.outputs[0], dartLevelsLut(const [], 'gamma', gamma),
              context: 'gamma=$gamma');
        }
      });

      test('缺省 mode + 无控制点 → 恒等曲线', () async {
        final c = await runCOp('levels_lut', params: const {}, tag: _tag);
        expectFramesEqual(c.outputs[0], dartLevelsLut(const [], 'spline', 1.0),
            context: '恒等 LUT');
      });
    });

    group('levels_apply', () {
      /// 生成一条非恒等 LUT 供应用用例使用。
      Uint16List splineLut() => dartLevelsLut(const [
            [0.0, 0.0],
            [1024.0, 1536.0],
            [2048.0, 2048.0],
            [3072.0, 2560.0],
            [4095.0, 4095.0],
          ], 'spline', 1.0);

      test('64x48 maxValue=1023 LCG 帧（缩放查表路径）', () async {
        const w = 64, h = 48, mv = 1023;
        final input = lcgFrame(w, h, 3, 11, maxValue: mv);
        final lut = splineLut();
        final c = await runCOp('levels_apply',
            params: {'width': w, 'height': h, 'max_value': mv},
            inputs: [input, lut],
            tag: _tag);
        expectFramesEqual(
            c.outputs[0], applyLevelsCurve(input, lut, maxValue: mv),
            context: '64x48 mv=1023');
      });

      test('64x48 maxValue=4095 直通查表路径', () async {
        const w = 64, h = 48, mv = 4095;
        final input = lcgFrame(w, h, 3, 12, maxValue: mv);
        final lut = splineLut();
        final c = await runCOp('levels_apply',
            params: {'width': w, 'height': h, 'max_value': mv},
            inputs: [input, lut],
            tag: _tag);
        expectFramesEqual(
            c.outputs[0], applyLevelsCurve(input, lut, maxValue: mv),
            context: '64x48 mv=4095 直通');
      });

      test('32x24 maxValue=65535（16 位缩放路径 + gamma LUT）', () async {
        const w = 32, h = 24, mv = 65535;
        final input = lcgFrame(w, h, 3, 13, maxValue: mv);
        final lut = dartLevelsLut(const [], 'gamma', 2.2);
        final c = await runCOp('levels_apply',
            params: {'width': w, 'height': h, 'max_value': mv},
            inputs: [input, lut],
            tag: _tag);
        expectFramesEqual(
            c.outputs[0], applyLevelsCurve(input, lut, maxValue: mv),
            context: '32x24 mv=65535');
      });

      test('8x6 渐变帧 0/max 角点（linear LUT）', () async {
        const w = 8, h = 6, mv = 1023;
        final input = gradientFrame(w, h, 3, maxValue: mv);
        final lut = dartLevelsLut(const [
          [0.0, 0.0],
          [1000.0, 800.0],
          [2500.0, 3000.0],
          [4095.0, 4095.0],
        ], 'linear', 1.0);
        final c = await runCOp('levels_apply',
            params: {'width': w, 'height': h, 'max_value': mv},
            inputs: [input, lut],
            tag: _tag);
        expectFramesEqual(
            c.outputs[0], applyLevelsCurve(input, lut, maxValue: mv),
            context: '8x6 渐变角点');
      });
    });

    group('color_temp_gains', () {
      test('典型色温对（3200→6500 等 4 组，含恒等与默认参考）', () async {
        final cases = [
          (3200.0, 6500),
          (7500.4, 0), // referenceCct<=0 走默认 6500K
          (6500.0, 6500), // target==reference → 增益恒为 1
          (4321.7, 5000), // 小数目标检验 round 路径
        ];
        for (final (target, ref) in cases) {
          final c = await runCOp('color_temp_gains',
              params: {'targetCct': target, 'referenceCct': ref}, outputCount: 0, tag: _tag);
          final exp = colorTempGains(target, ref);
          final ctx = 'gains target=$target ref=$ref';
          expectScalarEqual(c.scalars, 'r', exp[0], context: ctx);
          expectScalarEqual(c.scalars, 'g', exp[1], context: ctx);
          expectScalarEqual(c.scalars, 'b', exp[2], context: ctx);
        }
      });

      test('边界色温（钳位 1800/12000 与分段边界 6600K）', () async {
        final cases = [
          (1800.0, 6500),
          (12000.0, 6500),
          (6600.0, 6500), // t=66 恰在 Tanner Helland 分段边界
          (500.0, 3000), // 目标钳到 1800
          (99999.0, 2000), // 目标钳到 12000
        ];
        for (final (target, ref) in cases) {
          final c = await runCOp('color_temp_gains',
              params: {'targetCct': target, 'referenceCct': ref}, outputCount: 0, tag: _tag);
          final exp = colorTempGains(target, ref);
          final ctx = 'gains 边界 target=$target ref=$ref';
          expectScalarEqual(c.scalars, 'r', exp[0], context: ctx);
          expectScalarEqual(c.scalars, 'g', exp[1], context: ctx);
          expectScalarEqual(c.scalars, 'b', exp[2], context: ctx);
        }
      });
    });

    group('color_temp_whitepoint', () {
      test('多个色温点（含分段边界 t=66/19 与钳位）', () async {
        // 2700(t=27)、6500(t=65 对数段)、6600(t=66 边界)、6601(t=66.01 幂段)、
        // 1900(t=19 b=0 边界)、1800/12000（值域端点）、500/99999（钳位）。
        for (final cct in [2700, 6500, 6600, 6601, 1900, 1800, 12000, 500, 99999]) {
          final c = await runCOp('color_temp_whitepoint',
              params: {'cct': cct}, outputCount: 0, tag: _tag);
          final exp = cctToWhitePoint(cct);
          final ctx = 'whitepoint cct=$cct';
          expectScalarEqual(c.scalars, 'r', exp[0], context: ctx);
          expectScalarEqual(c.scalars, 'g', exp[1], context: ctx);
          expectScalarEqual(c.scalars, 'b', exp[2], context: ctx);
        }
      });
    });

    group('color_temp_ccm', () {
      test('任意增益与 colorTempGains 输出增益（对角阵 9 元素）', () async {
        final gainSets = [
          [1.25, 1.0, 0.75],
          colorTempGains(3200.0, 6500),
          [0.001, 1.0, 255.0], // 极值增益
        ];
        for (final gains in gainSets) {
          final c = await runCOp('color_temp_ccm',
              params: {'r': gains[0], 'g': gains[1], 'b': gains[2]},
              outputCount: 0, tag: _tag);
          final exp = colorTempCcm(gains);
          for (var i = 0; i < 9; i++) {
            expectScalarEqual(c.scalars, 'm$i', exp[i],
                context: 'ccm gains=$gains m$i');
          }
        }
      });
    });

    group('color_temp_measure_cct', () {
      test('64x48 中性灰常量帧', () async {
        const w = 64, h = 48;
        final rgba = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          rgba[i * 4] = 200;
          rgba[i * 4 + 1] = 200;
          rgba[i * 4 + 2] = 200;
          rgba[i * 4 + 3] = 255;
        }
        final c = await runCOp('color_temp_measure_cct',
            params: {'width': w, 'height': h},
            inRaw: rgba, outputCount: 0, tag: _tag);
        expectScalarEqual(c.scalars, 'cct',
            measureCctFromRgba(rgba, w, h)!.toDouble(),
            context: '中性灰');
      });

      test('64x48 暖色常量帧（220,170,110）', () async {
        const w = 64, h = 48;
        final rgba = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          rgba[i * 4] = 220;
          rgba[i * 4 + 1] = 170;
          rgba[i * 4 + 2] = 110;
          rgba[i * 4 + 3] = 255;
        }
        final c = await runCOp('color_temp_measure_cct',
            params: {'width': w, 'height': h},
            inRaw: rgba, outputCount: 0, tag: _tag);
        expectScalarEqual(c.scalars, 'cct',
            measureCctFromRgba(rgba, w, h)!.toDouble(),
            context: '暖色常量');
      });

      test('200x150 LCG 噪声帧（step=2 抽样路径）', () async {
        const w = 200, h = 150;
        final rgba = lcgRgbaFrame(w, h, 42);
        final c = await runCOp('color_temp_measure_cct',
            params: {'width': w, 'height': h},
            inRaw: rgba, outputCount: 0, tag: _tag);
        expectScalarEqual(c.scalars, 'cct',
            measureCctFromRgba(rgba, w, h)!.toDouble(),
            context: 'LCG 噪声 step=2');
      });

      test('全黑帧无法估计（Dart null ↔ C 非零退出）', () async {
        const w = 32, h = 32;
        final rgba = Uint8List(w * h * 4); // 全 0（含 alpha=0，忽略）
        expect(measureCctFromRgba(rgba, w, h), isNull,
            reason: 'Dart 基准：全黑帧返回 null');
        // C 侧 isp_color_temp_measure_cct 返回 ISP_ERR_UNSUPPORTED，
        // harness 进程非零退出，runCOp 抛 StateError。
        await expectLater(
          runCOp('color_temp_measure_cct',
              params: {'width': w, 'height': h}, inRaw: rgba, tag: _tag),
          throwsStateError,
        );
      });
    });
  });
}
