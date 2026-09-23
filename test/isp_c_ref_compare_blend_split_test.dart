/// Dart↔C 对拍：混合/拆分合并组（blend_split）。
///
/// C 侧：test/c_ref/harness_blend_split.c ->
/// lib/modules/isp_studio/c_ref/isp_blend.c / isp_split.c。
/// Dart 侧基准：
/// - multiply / blend_mono / blend_mask 直接调 isp_kernels.dart 的
///   `multiplyMono` / `blendMono` / `blendMaskMono`；
/// - mux4 / split_* / combine_* 语义在 pipeline_runner.dart 的对应 case
///   （mux4 纯透传；分合路纯数据搬运），kernel 层无对应函数，本文件
///   逐行复刻 runner 循环作基准并注明出处。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const _tag = '_grp_blend_split';

/// mux4 基准：复刻 pipeline_runner.dart `case 'mux4'`——
/// `select = (p['select'] ?? 1).clamp(1, 4)`，选中路**透传**到输出
/// （整帧直接连接时 `frame = upstream`，不改数据、不复制）。
Uint16List dartMux4(int select, List<Uint16List> inputs) {
  final sel = select.clamp(1, 4);
  return inputs[sel - 1];
}

/// 分路基准：复刻 pipeline_runner.dart `case 'rgb_splitter'` /
/// `'yuv_splitter'` / `'hsl_splitter'` 的拆路循环——
/// `dst0[i] = src[3*i]; dst1[i] = src[3*i+1]; dst2[i] = src[3*i+2]`，
/// 纯拷贝。（各 splitter case 前的跨色彩域兜底转换属色彩空间组职责，
/// 本组对拍输入帧已是目标色彩域，不覆盖。）
List<Uint16List> dartSplit3(Uint16List src, int width, int height) {
  final pixels = width * height;
  final p0 = Uint16List(pixels);
  final p1 = Uint16List(pixels);
  final p2 = Uint16List(pixels);
  for (var i = 0; i < pixels; i++) {
    p0[i] = src[3 * i];
    p1[i] = src[3 * i + 1];
    p2[i] = src[3 * i + 2];
  }
  return [p0, p1, p2];
}

/// 合路基准：复刻 pipeline_runner.dart `case 'rgb_combiner'` /
/// `'yuv_combiner'` / `'hsl_combiner'` 的合并循环——
/// `combined[3i+c] = (data != null && i < data.length) ? data[i] : def_c`；
/// RGB/HSL 缺省值恒 0，YUV 的 Y 缺省 0、U/V 缺省 `max >> 1`。
/// [yuv] = true 时按 yuv_combiner 口径给 U/V 缺省中值。
/// （yuvPlanes8 零拷贝轨道为 PC 侧内存优化，嵌入式参考实现不移植，
/// 对拍一律走 16 位交织路径。）
Uint16List dartCombine3(List<Uint16List?> ins, int width, int height,
    int maxValue, {required bool yuv}) {
  final pixels = width * height;
  final mid = maxValue >> 1;
  final defs = yuv ? [0, mid, mid] : [0, 0, 0];
  final combined = Uint16List(pixels * 3);
  for (var i = 0; i < pixels; i++) {
    for (var c = 0; c < 3; c++) {
      final data = ins[c];
      combined[3 * i + c] =
          data != null && i < data.length ? data[i] : defs[c];
    }
  }
  return combined;
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_blend_split: C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    // ------------------------------------------------------------------
    // multiply（multiplier 节点 -> multiplyMono）
    // ------------------------------------------------------------------
    group('multiply', () {
      test('64x48 零偏移归一化相乘', () async {
        const w = 64, h = 48;
        final a = lcgFrame(w, h, 1, 11, maxValue: 1023);
        final b = lcgFrame(w, h, 1, 22, maxValue: 1023);
        final c = await runCOp('multiply',
            params: {'width': w, 'height': h, 'maxValue': 1023},
            inputs: [a, b],
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            multiplyMono(a, b, maxValue: 1023),
            context: 'multiply 零偏移');
      });

      test('64x48 小数偏移（正负，检验 double 路径与 round）', () async {
        const w = 64, h = 48;
        final a = lcgFrame(w, h, 1, 33, maxValue: 1023);
        final b = lcgFrame(w, h, 1, 44, maxValue: 1023);
        const offset1 = 64.5, offset2 = -32.25;
        final c = await runCOp('multiply', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'offset1': offset1,
          'offset2': offset2,
        }, inputs: [
          a,
          b
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            multiplyMono(a, b,
                offset1: offset1, offset2: offset2, maxValue: 1023),
            context: 'multiply 小数偏移');
      });

      test('16x16 极值：全 0 / 全 max / 渐变角点', () async {
        const w = 16, h = 16;
        final grad = gradientFrame(w, h, 1, maxValue: 1023);
        final zero = constantFrame(w, h, 1, 0);
        final full = constantFrame(w, h, 1, 1023);
        // 全 max × 全 max = max（归一化后恰好满量程）。
        var c = await runCOp('multiply',
            params: {'width': w, 'height': h, 'maxValue': 1023},
            inputs: [full, full],
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            multiplyMono(full, full, maxValue: 1023),
            context: 'multiply max×max');
        // 全 0 × 渐变 = 全 0。
        c = await runCOp('multiply',
            params: {'width': w, 'height': h, 'maxValue': 1023},
            inputs: [zero, grad],
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            multiplyMono(zero, grad, maxValue: 1023),
            context: 'multiply 0×grad');
      });

      test('32x24 maxValue=65535（16 位量程）', () async {
        const w = 32, h = 24;
        final a = lcgFrame(w, h, 1, 55, maxValue: 65535);
        final b = lcgFrame(w, h, 1, 66, maxValue: 65535);
        final c = await runCOp('multiply',
            params: {'width': w, 'height': h, 'maxValue': 65535},
            inputs: [a, b],
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            multiplyMono(a, b, maxValue: 65535),
            context: 'multiply 65535');
      });
    });

    // ------------------------------------------------------------------
    // blend_mono（adder 节点 -> blendMono）
    // ------------------------------------------------------------------
    group('blend_mono', () {
      test('64x48 balance=0.5 平衡中点', () async {
        const w = 64, h = 48;
        final a = lcgFrame(w, h, 1, 77, maxValue: 1023);
        final b = lcgFrame(w, h, 1, 88, maxValue: 1023);
        final c = await runCOp('blend_mono',
            params: {'width': w, 'height': h, 'maxValue': 1023, 'balance': 0.5},
            inputs: [a, b],
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            blendMono(a, b, balance: 0.5, maxValue: 1023),
            context: 'blend_mono 0.5');
      });

      test('64x48 balance=0.25 偏源 2', () async {
        const w = 64, h = 48;
        final a = lcgFrame(w, h, 1, 99, maxValue: 1023);
        final b = lcgFrame(w, h, 1, 111, maxValue: 1023);
        final c = await runCOp('blend_mono',
            params: {
              'width': w,
              'height': h,
              'maxValue': 1023,
              'balance': 0.25
            },
            inputs: [a, b],
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            blendMono(a, b, balance: 0.25, maxValue: 1023),
            context: 'blend_mono 0.25');
      });

      test('4x4 balance 端点 1.0/0.0（纯透源 1 / 源 2）', () async {
        const w = 4, h = 4;
        final a = gradientFrame(w, h, 1, maxValue: 1023);
        final b = lcgFrame(w, h, 1, 122, maxValue: 1023);
        for (final bal in [1.0, 0.0]) {
          final c = await runCOp('blend_mono',
              params: {
                'width': w,
                'height': h,
                'maxValue': 1023,
                'balance': bal
              },
              inputs: [a, b],
              tag: _tag);
          expectFramesEqual(c.outputs[0],
              blendMono(a, b, balance: bal, maxValue: 1023),
              context: 'blend_mono balance=$bal');
        }
      });

      test('32x24 maxValue=65535', () async {
        const w = 32, h = 24;
        final a = lcgFrame(w, h, 1, 133, maxValue: 65535);
        final b = lcgFrame(w, h, 1, 144, maxValue: 65535);
        final c = await runCOp('blend_mono',
            params: {
              'width': w,
              'height': h,
              'maxValue': 65535,
              'balance': 0.333
            },
            inputs: [a, b],
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            blendMono(a, b, balance: 0.333, maxValue: 65535),
            context: 'blend_mono 65535');
      });
    });

    // ------------------------------------------------------------------
    // blend_mask（blender 节点 -> blendMaskMono）
    // ------------------------------------------------------------------
    group('blend_mask', () {
      test('64x48 rgb 基图 + mono 混叠图（三通道同加）', () async {
        const w = 64, h = 48;
        final base = lcgFrame(w, h, 3, 201, maxValue: 1023);
        final blend = lcgFrame(w, h, 1, 202, maxValue: 1023);
        final mask = lcgFrame(w, h, 1, 203, maxValue: 1023);
        final c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'rgb',
          'blendChannels': 1,
          'strength': 1.0,
        }, inputs: [
          base,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(base, blend, mask,
                format: 'rgb', strength: 1.0, maxValue: 1023),
            context: 'blend_mask rgb/mono');
      });

      test('64x48 yuv 基图 + mono 混叠图 strength=0.5（只加 Y）', () async {
        const w = 64, h = 48;
        final base = lcgFrame(w, h, 3, 211, maxValue: 1023);
        final blend = lcgFrame(w, h, 1, 212, maxValue: 1023);
        final mask = lcgFrame(w, h, 1, 213, maxValue: 1023);
        final c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'yuv',
          'blendChannels': 1,
          'strength': 0.5,
        }, inputs: [
          base,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(base, blend, mask,
                format: 'yuv', strength: 0.5, maxValue: 1023),
            context: 'blend_mask yuv/mono');
      });

      test('32x24 hsl 基图 + mono 混叠图 strength=1.5（只加 L）', () async {
        const w = 32, h = 24;
        final base = lcgFrame(w, h, 3, 221, maxValue: 1023);
        final blend = lcgFrame(w, h, 1, 222, maxValue: 1023);
        final mask = lcgFrame(w, h, 1, 223, maxValue: 1023);
        final c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'hsl',
          'blendChannels': 1,
          'strength': 1.5,
        }, inputs: [
          base,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(base, blend, mask,
                format: 'hsl', strength: 1.5, maxValue: 1023),
            context: 'blend_mask hsl/mono');
      });

      test('32x24 mono 基图 + mono 混叠图，蒙版全 0（基图不动）', () async {
        const w = 32, h = 24;
        final base = lcgFrame(w, h, 1, 231, maxValue: 1023);
        final blend = lcgFrame(w, h, 1, 232, maxValue: 1023);
        final mask = constantFrame(w, h, 1, 0);
        final c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'mono',
          'blendChannels': 1,
          'strength': 2.0,
        }, inputs: [
          base,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(base, blend, mask,
                format: 'mono', strength: 2.0, maxValue: 1023),
            context: 'blend_mask mono 零蒙版');
      });

      test('64x48 rgb 基图 + 三通道混叠图（blendChannels=3 逐通道叠加）',
          () async {
        const w = 64, h = 48;
        final base = lcgFrame(w, h, 3, 241, maxValue: 1023);
        final blend = lcgFrame(w, h, 3, 242, maxValue: 1023);
        final mask = lcgFrame(w, h, 1, 243, maxValue: 1023);
        final c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'rgb',
          'blendChannels': 3,
          'strength': 0.75,
        }, inputs: [
          base,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(base, blend, mask,
                format: 'rgb',
                blendChannels: 3,
                strength: 0.75,
                maxValue: 1023),
            context: 'blend_mask rgb/3ch');
      });

      test('32x24 yuv 基图 + 三通道混叠图（blendChannels=3 与格式无关）',
          () async {
        const w = 32, h = 24;
        final base = lcgFrame(w, h, 3, 251, maxValue: 1023);
        final blend = lcgFrame(w, h, 3, 252, maxValue: 1023);
        final mask = lcgFrame(w, h, 1, 253, maxValue: 1023);
        final c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'yuv',
          'blendChannels': 3,
          'strength': 1.0,
        }, inputs: [
          base,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(base, blend, mask,
                format: 'yuv',
                blendChannels: 3,
                strength: 1.0,
                maxValue: 1023),
            context: 'blend_mask yuv/3ch');
      });

      test('4x4 小图：满混叠图+满蒙版截位到 maxValue + strength=0 恒等',
          () async {
        const w = 4, h = 4;
        final base = constantFrame(w, h, 3, 900);
        final blend = constantFrame(w, h, 1, 1023);
        final mask = constantFrame(w, h, 1, 1023);
        // strength=1：delta=1023*1023/1023=1023，base+delta 远超 max → 截位。
        var c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'rgb',
          'blendChannels': 1,
          'strength': 1.0,
        }, inputs: [
          base,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(base, blend, mask,
                format: 'rgb', strength: 1.0, maxValue: 1023),
            context: 'blend_mask 截位');
        // strength=0：Dart `if (strength == 0) return out;` 基图不动。
        final grad = gradientFrame(w, h, 3, maxValue: 1023);
        c = await runCOp('blend_mask', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'format': 'rgb',
          'blendChannels': 1,
          'strength': 0.0,
        }, inputs: [
          grad,
          blend,
          mask
        ], tag: _tag);
        expectFramesEqual(
            c.outputs[0],
            blendMaskMono(grad, blend, mask,
                format: 'rgb', strength: 0.0, maxValue: 1023),
            context: 'blend_mask strength=0');
      });
    });

    // ------------------------------------------------------------------
    // mux4（复刻 pipeline_runner.dart case 'mux4' 透传语义）
    // ------------------------------------------------------------------
    group('mux4', () {
      test('64x48 mono：select 1..4 各透传对应路', () async {
        const w = 64, h = 48;
        final ins = [
          lcgFrame(w, h, 1, 301, maxValue: 1023),
          lcgFrame(w, h, 1, 302, maxValue: 1023),
          lcgFrame(w, h, 1, 303, maxValue: 1023),
          lcgFrame(w, h, 1, 304, maxValue: 1023),
        ];
        for (var sel = 1; sel <= 4; sel++) {
          final c = await runCOp('mux4',
              params: {'width': w, 'height': h, 'select': sel},
              inputs: ins,
              tag: _tag);
          expectFramesEqual(c.outputs[0], dartMux4(sel, ins),
              context: 'mux4 select=$sel');
        }
      });

      test('32x24 三通道帧透传 + select 越界钳位（0->1，7->4）', () async {
        const w = 32, h = 24;
        final ins = [
          lcgFrame(w, h, 3, 311, maxValue: 1023),
          gradientFrame(w, h, 3, maxValue: 1023),
          constantFrame(w, h, 3, 0),
          constantFrame(w, h, 3, 1023),
        ];
        for (final sel in [2, 3, 0, 7]) {
          final c = await runCOp('mux4', params: {
            'width': w,
            'height': h,
            'channels': 3,
            'select': sel,
          }, inputs: ins, tag: _tag);
          expectFramesEqual(c.outputs[0], dartMux4(sel, ins),
              context: 'mux4 channels=3 select=$sel');
        }
      });
    });

    // ------------------------------------------------------------------
    // split_rgb / split_yuv / split_hsl（复刻 runner 拆路循环）
    // ------------------------------------------------------------------
    group('split_*', () {
      Future<void> runSplitCase(String op, Uint16List src, int w, int h,
          String ctx) async {
        final c = await runCOp(op,
            params: {'width': w, 'height': h, 'maxValue': 1023},
            inputs: [src],
            outputCount: 3,
            tag: _tag);
        final expected = dartSplit3(src, w, h);
        for (var i = 0; i < 3; i++) {
          expectFramesEqual(c.outputs[i], expected[i],
              context: '$ctx 平面$i');
        }
      }

      test('split_rgb 64x48 交织帧拆三平面', () async {
        const w = 64, h = 48;
        await runSplitCase(
            'split_rgb', lcgFrame(w, h, 3, 401, maxValue: 1023), w, h,
            'split_rgb 64x48');
      });

      test('split_rgb 4x4 渐变小图（0/max 角点）', () async {
        const w = 4, h = 4;
        await runSplitCase(
            'split_rgb', gradientFrame(w, h, 3, maxValue: 1023), w, h,
            'split_rgb 4x4');
      });

      test('split_yuv 64x48 交织帧拆三平面', () async {
        const w = 64, h = 48;
        await runSplitCase(
            'split_yuv', lcgFrame(w, h, 3, 411, maxValue: 1023), w, h,
            'split_yuv 64x48');
      });

      test('split_yuv 5x3 奇数尺寸小图', () async {
        const w = 5, h = 3;
        await runSplitCase(
            'split_yuv', gradientFrame(w, h, 3, maxValue: 1023), w, h,
            'split_yuv 5x3');
      });

      test('split_hsl 64x48 交织帧拆三平面', () async {
        const w = 64, h = 48;
        await runSplitCase(
            'split_hsl', lcgFrame(w, h, 3, 421, maxValue: 1023), w, h,
            'split_hsl 64x48');
      });

      test('split_hsl 4x4 渐变小图', () async {
        const w = 4, h = 4;
        await runSplitCase(
            'split_hsl', gradientFrame(w, h, 3, maxValue: 1023), w, h,
            'split_hsl 4x4');
      });
    });

    // ------------------------------------------------------------------
    // combine_rgb / combine_yuv / combine_hsl（复刻 runner 合并循环，
    // 含缺路默认值与短平面 i < data.length 兜底）
    // ------------------------------------------------------------------
    group('combine_*', () {
      test('combine_rgb 64x48 三路全接', () async {
        const w = 64, h = 48;
        final ins = [
          lcgFrame(w, h, 1, 501, maxValue: 1023),
          lcgFrame(w, h, 1, 502, maxValue: 1023),
          lcgFrame(w, h, 1, 503, maxValue: 1023),
        ];
        final c = await runCOp('combine_rgb',
            params: {'width': w, 'height': h, 'maxValue': 1023},
            inputs: ins,
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            dartCombine3(ins, w, h, 1023, yuv: false),
            context: 'combine_rgb 全接');
      });

      test('combine_rgb 32x24 缺路默认值：has_in1=0/has_in2=0 填 0', () async {
        const w = 32, h = 24;
        final r = lcgFrame(w, h, 1, 511, maxValue: 1023);
        final c = await runCOp('combine_rgb', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'has_in1': 0,
          'has_in2': 0,
        }, inputs: [
          r
        ], tag: _tag);
        expectFramesEqual(c.outputs[0],
            dartCombine3([r, null, null], w, h, 1023, yuv: false),
            context: 'combine_rgb 缺路');
      });

      test('combine_yuv 64x48 三路全接', () async {
        const w = 64, h = 48;
        final ins = [
          lcgFrame(w, h, 1, 521, maxValue: 1023),
          lcgFrame(w, h, 1, 522, maxValue: 1023),
          lcgFrame(w, h, 1, 523, maxValue: 1023),
        ];
        final c = await runCOp('combine_yuv',
            params: {'width': w, 'height': h, 'maxValue': 1023},
            inputs: ins,
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            dartCombine3(ins, w, h, 1023, yuv: true),
            context: 'combine_yuv 全接');
      });

      test('combine_yuv 32x24 缺路默认值：Y 缺省 0、U/V 缺省 max>>1=511',
          () async {
        const w = 32, h = 24;
        final y = lcgFrame(w, h, 1, 531, maxValue: 1023);
        // 只接 Y：U/V 填 511。
        var c = await runCOp('combine_yuv', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'has_in1': 0,
          'has_in2': 0,
        }, inputs: [
          y
        ], tag: _tag);
        expectFramesEqual(c.outputs[0],
            dartCombine3([y, null, null], w, h, 1023, yuv: true),
            context: 'combine_yuv 只接 Y');
        // 只接 U/V：Y 填 0。has_in0=0 时 harness 不读 in0.bin，但
        // runCOp 的 inputs 固定从 in0.bin 起编号，故首元素为占位 dummy
        // （不被读取），in1.bin/in2.bin 才是 U/V。
        final u = lcgFrame(w, h, 1, 532, maxValue: 1023);
        final v = lcgFrame(w, h, 1, 533, maxValue: 1023);
        c = await runCOp('combine_yuv', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'has_in0': 0,
        }, inputs: [
          constantFrame(w, h, 1, 0),
          u,
          v
        ], tag: _tag);
        expectFramesEqual(c.outputs[0],
            dartCombine3([null, u, v], w, h, 1023, yuv: true),
            context: 'combine_yuv 缺 Y');
      });

      test('combine_hsl 64x48 三路全接', () async {
        const w = 64, h = 48;
        final ins = [
          lcgFrame(w, h, 1, 541, maxValue: 1023),
          lcgFrame(w, h, 1, 542, maxValue: 1023),
          lcgFrame(w, h, 1, 543, maxValue: 1023),
        ];
        final c = await runCOp('combine_hsl',
            params: {'width': w, 'height': h, 'maxValue': 1023},
            inputs: ins,
            tag: _tag);
        expectFramesEqual(c.outputs[0],
            dartCombine3(ins, w, h, 1023, yuv: false),
            context: 'combine_hsl 全接');
      });

      test('combine_hsl 4x4 缺路 + 短平面（i < data.length 兜底填 0）',
          () async {
        const w = 4, h = 4;
        final hPlane = gradientFrame(w, h, 1, maxValue: 1023);
        // S 路只给前 6 个样本（len1=6）：其余位置按 Dart
        // `i < data.length` 判空填 0；L 路缺路填 0。
        final sShort = lcgFrame(6, 1, 1, 551, maxValue: 1023);
        final c = await runCOp('combine_hsl', params: {
          'width': w,
          'height': h,
          'maxValue': 1023,
          'len1': 6,
          'has_in2': 0,
        }, inputs: [
          hPlane,
          sShort
        ], tag: _tag);
        // 短平面在 Dart 基准侧按真实长度传入（data.length=6），
        // 由基准的 `i < data.length` 判空，不靠补零。
        expectFramesEqual(
            c.outputs[0],
            dartCombine3(
                [hPlane, Uint16List.fromList(sShort), null], w, h, 1023,
                yuv: false),
            context: 'combine_hsl 缺路+短平面');
      });

      test('combine_yuv 16x16 maxValue=65535（U/V 缺省 32767）', () async {
        const w = 16, h = 16;
        final y = lcgFrame(w, h, 1, 561, maxValue: 65535);
        final c = await runCOp('combine_yuv', params: {
          'width': w,
          'height': h,
          'maxValue': 65535,
          'has_in1': 0,
          'has_in2': 0,
        }, inputs: [
          y
        ], tag: _tag);
        expectFramesEqual(c.outputs[0],
            dartCombine3([y, null, null], w, h, 65535, yuv: true),
            context: 'combine_yuv 65535 缺路');
      });
    });
  });
}
