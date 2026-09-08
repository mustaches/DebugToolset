// NN GPU 原语逐一定位探针（Flutter 3.47.2 升级后数值漂移定位用）：
//   flutter run -d windows -t scratch/nn_gpu_primitive_probe_main.dart
// 对每个 GPU 原语：确定性输入 → CPU 参考（ops）→ GPU 执行 → 回读 →
// 逐元素比较，打印 PROBE 行。比较口径照搬 test/isp_nn_gpu_test.dart /
// test/isp_nn_gpu_rn50_test.dart 的 errStats（maxAbs / relToRms）。
//
// exact 语义：与「Dart 侧模拟的 fp16 管线」（上传量化 → fp32 模拟 shader
// 逐指令算术 → 输出量化）逐位比较。纯拷贝/选择类原语（roundtrip/relu/
// maxpool/concat/stitch 链控制项）与简单算术（addrelu/avgpool/pool3x3/
// l2pool）可精确模拟；conv 的 dot 累加顺序/fma 由驱动决定，不做逐位
// 模拟，只报 relToRms（exact=na）。
//
// banded 用例照搬 isp_nn_gpu_rn50_test.dart：debugMaxBandTexels=65536，
// 64ch 65x48 → 带 [32,32,1]，覆盖 stitch halo 拼接与 uYOff=1 路径；
// 并加 banded relu（无 stitch）作分块上传/回读的控制项，以及
// 单纹理 GPU 输出作 GPU-vs-GPU 对照（隔离 stitch 贡献）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_gpu.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart'
    as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

// ------------------------------------------------------------------
// 工具
// ------------------------------------------------------------------

final Float32List _f32box = Float32List(1);
final Uint32List _u32box = _f32box.buffer.asUint32List();

/// double → 最近 fp32（模拟 shader 内 fp32 算术的每次舍入）。
double f32(double v) {
  _f32box[0] = v;
  return _f32box[0];
}

int f32bits(double v) {
  _f32box[0] = v;
  return _u32box[0];
}

/// Dart 侧 fp16 往返（上传量化 + 回读解码的参考实现）。
double hround(double v) => halfBitsToFloat(floatToHalfBits(v));

class Lcg {
  Lcg(int seed) : _s = seed & 0x7fffffff;
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 2147483648.0;
  }
}

/// 宽量级确定性输入：|v| ∈ ~[2.5e-8, 1.25e3]，覆盖正/负/大/小/fp16 次
/// 正规（<6.1e-5）区间。
Float32List wideF32(int n, int seed) {
  final r = Lcg(seed);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final m = r.next();
    final e = r.next();
    final sgn = r.next() < 0.5 ? -1.0 : 1.0;
    out[i] = sgn * (0.25 + m) * math.pow(10.0, e * 10 - 7).toDouble();
  }
  return out;
}

/// 与测试一致的均匀分布输入（conv 用，避免累加溢出 fp16）。
Float32List randF32(int n, int seed, {double scale = 1.0}) {
  final rng = math.Random(seed);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (rng.nextDouble() * 2 - 1) * scale;
  }
  return out;
}

/// 比较并打印 PROBE 行。[expected] 为 CPU fp32 参考（maxAbs/relToRms
/// 口径同测试）；[exactRef] 非空时与 actual 逐位比较得 exact，否则
/// exact=na。
void report(String op, Float32List actual, Float32List expected,
    {Float32List? exactRef}) {
  if (actual.length != expected.length) {
    print('PROBE_ERROR $op 长度不符 ${actual.length} vs ${expected.length}');
    return;
  }
  var maxAbs = 0.0, sumSq = 0.0;
  var worst = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > maxAbs) {
      maxAbs = d;
      worst = i;
    }
    sumSq += expected[i] * expected[i];
  }
  final rel = maxAbs / math.sqrt(sumSq / expected.length);
  String exactStr = 'na';
  if (exactRef != null) {
    var diffN = 0;
    var firstDiff = -1;
    for (var i = 0; i < actual.length; i++) {
      if (f32bits(actual[i]) != f32bits(exactRef[i])) {
        diffN++;
        if (firstDiff < 0) firstDiff = i;
      }
    }
    exactStr =
        '${diffN == 0} diffN=$diffN firstDiff@$firstDiff'
        '${firstDiff >= 0 ? ' exp=${exactRef[firstDiff]} act=${actual[firstDiff]}' : ''}';
  }
  print('PROBE $op maxAbs=$maxAbs relToRms=$rel exact=$exactStr '
      'worst@$worst exp=${expected[worst]} act=${actual[worst]}');
}

/// 两 GPU 结果互差（banded vs 单纹理对照）。
void reportPair(String op, Float32List a, Float32List b) {
  var maxAbs = 0.0;
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > maxAbs) maxAbs = d;
    if (f32bits(a[i]) != f32bits(b[i])) n++;
  }
  print('PROBE_PAIR $op maxAbs=$maxAbs diffN=$n/${a.length}');
}

/// 逐位差异的按行分布（定位 stitch halo 行损坏）。
void reportRows(String op, Float32List actual, Float32List expected, int c,
    int h, int w) {
  final counts = List<int>.filled(h, 0);
  for (var ch = 0; ch < c; ch++) {
    final base = ch * h * w;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = base + y * w + x;
        if (f32bits(actual[i]) != f32bits(expected[i])) counts[y]++;
      }
    }
  }
  print('PROBE_ROWS $op diffByRow=$counts');
}

/// 逐位差异的按通道组分布（定位 concat 哪一路源损坏）。
void reportGroups(String op, Float32List actual, Float32List expected, int c,
    int h, int w) {
  final g = c ~/ 4;
  final counts = List<int>.filled(g, 0);
  for (var ch = 0; ch < c; ch++) {
    final base = ch * h * w;
    for (var i = 0; i < h * w; i++) {
      if (f32bits(actual[base + i]) != f32bits(expected[base + i])) {
        counts[ch ~/ 4]++;
      }
    }
  }
  print('PROBE_GROUPS $op diffByGroup=$counts');
}

/// 逐位差异按折叠布局的物理纹理行（8192 纹素/行）分布
/// （定位大纹理劣化是否集中在特定纹理行/瓦片边界）。
void reportTexRows(String op, Float32List actual, Float32List expected, int c,
    int h, int w) {
  final texels = 2 * (c ~/ 4) * h * w;
  final tw = texels < 8192 ? texels : 8192;
  final th = (texels + tw - 1) ~/ tw;
  final counts = List<int>.filled(th, 0);
  for (var ch = 0; ch < c; ch++) {
    final base = ch * h * w;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (f32bits(actual[base + y * w + x]) !=
            f32bits(expected[base + y * w + x])) {
          final t = (ch >> 2) * h * w + y * w + x;
          final texel = (t * 4 + (ch & 3)) >> 1;
          counts[texel ~/ tw]++;
        }
      }
    }
  }
  print('PROBE_TEXROWS $op tw=$tw th=$th diffByTexRow=$counts');
}

Future<void> runCase(String name, Future<void> Function() body) async {
  try {
    await body();
  } catch (e) {
    print('PROBE_ERROR $name $e');
  }
}

// ------------------------------------------------------------------
// Dart 侧 fp16 管线模拟（与 shader 逐指令同序的 fp32 算术）
// ------------------------------------------------------------------

Float32List simRelu(NnTensor x) => Float32List.fromList(
    [for (final v in x.data) hround(math.max(hround(v), 0.0))]);

Float32List simAddRelu(NnTensor a, NnTensor b) => Float32List.fromList([
      for (var i = 0; i < a.numel; i++)
        hround(math.max(f32(hround(a.data[i]) + hround(b.data[i])), 0.0))
    ]);

/// 窗口选择类（max）模拟：max 不产生新值，输出恒为某输入 half 的精确值。
Float32List simMaxPool(NnTensor x, int k, int s, int p) {
  final c = x.channels, h = x.height, w = x.width;
  final oh = (h + 2 * p - k) ~/ s + 1, ow = (w + 2 * p - k) ~/ s + 1;
  final out = Float32List(c * oh * ow);
  for (var ch = 0; ch < c; ch++) {
    final xC = ch * h * w, oC = ch * oh * ow;
    for (var oy = 0; oy < oh; oy++) {
      for (var ox = 0; ox < ow; ox++) {
        var best = double.negativeInfinity;
        for (var r = 0; r < k; r++) {
          final iy = oy * s - p + r;
          if (iy < 0 || iy >= h) continue;
          for (var c2 = 0; c2 < k; c2++) {
            final ix = ox * s - p + c2;
            if (ix < 0 || ix >= w) continue;
            final v = hround(x.data[xC + iy * w + ix]);
            if (v > best) best = v;
          }
        }
        out[oC + oy * ow + ox] = best;
      }
    }
  }
  return out;
}

/// AvgPool 2x2/s2/p0 模拟（窗口恒完整）：((a+b)+c)+d 后 *0.25，全 fp32。
Float32List simAvgPool2x2(NnTensor x) {
  final c = x.channels, h = x.height, w = x.width;
  final oh = h ~/ 2, ow = w ~/ 2;
  final out = Float32List(c * oh * ow);
  for (var ch = 0; ch < c; ch++) {
    final xC = ch * h * w, oC = ch * oh * ow;
    for (var oy = 0; oy < oh; oy++) {
      for (var ox = 0; ox < ow; ox++) {
        final i00 = xC + 2 * oy * w + 2 * ox;
        var s = f32(hround(x.data[i00]) + hround(x.data[i00 + 1]));
        s = f32(s + hround(x.data[i00 + w]));
        s = f32(s + hround(x.data[i00 + w + 1]));
        out[oC + oy * ow + ox] = hround(f32(s * 0.25));
      }
    }
  }
  return out;
}

/// 3x3 avg countIncludePad=false 模拟：首 tap 赋值后行主序 fp32 累加，
/// 除数 = 有效元素数，fp32 除法。
Float32List simPool3x3Avg(NnTensor x, int s, int p) {
  final c = x.channels, h = x.height, w = x.width;
  final oh = (h + 2 * p - 3) ~/ s + 1, ow = (w + 2 * p - 3) ~/ s + 1;
  final out = Float32List(c * oh * ow);
  for (var ch = 0; ch < c; ch++) {
    final xC = ch * h * w, oC = ch * oh * ow;
    for (var oy = 0; oy < oh; oy++) {
      for (var ox = 0; ox < ow; ox++) {
        var m = 0.0, cnt = 0;
        var first = true;
        for (var r = 0; r < 3; r++) {
          final iy = oy * s - p + r;
          if (iy < 0 || iy >= h) continue;
          for (var c2 = 0; c2 < 3; c2++) {
            final ix = ox * s - p + c2;
            if (ix < 0 || ix >= w) continue;
            final v = hround(x.data[xC + iy * w + ix]);
            if (first) {
              m = v;
              first = false;
            } else {
              m = f32(m + v);
            }
            cnt++;
          }
        }
        out[oC + oy * ow + ox] = hround(f32(m / cnt));
      }
    }
  }
  return out;
}

/// DISTS L2pooling 模拟：v²*(wr*wc) 行主序 fp32 累加 → +1e-12 → sqrt。
Float32List simL2Pool(NnTensor x) {
  final c = x.channels, h = x.height, w = x.width;
  final oh = (h + 1) ~/ 2, ow = (w + 1) ~/ 2;
  final out = Float32List(c * oh * ow);
  const eps32 = 9.999999960041972e-13; // fp32(1e-12)
  for (var ch = 0; ch < c; ch++) {
    final xC = ch * h * w, oC = ch * oh * ow;
    for (var oy = 0; oy < oh; oy++) {
      for (var ox = 0; ox < ow; ox++) {
        var acc = 0.0;
        for (var r = 0; r < 3; r++) {
          final iy = 2 * oy + r - 1;
          if (iy < 0 || iy >= h) continue;
          final wr = r == 1 ? 0.5 : 0.25;
          for (var c2 = 0; c2 < 3; c2++) {
            final ix = 2 * ox + c2 - 1;
            if (ix < 0 || ix >= w) continue;
            final wc = c2 == 1 ? 0.5 : 0.25;
            final v = hround(x.data[xC + iy * w + ix]);
            acc = f32(acc + f32(f32(v * v) * f32(wr * wc)));
          }
        }
        out[oC + oy * ow + ox] =
            hround(f32(math.sqrt(f32(acc + eps32))));
      }
    }
  }
  return out;
}

Float32List hroundTensor(NnTensor x) =>
    Float32List.fromList([for (final v in x.data) hround(v)]);

// ------------------------------------------------------------------
// 探针主体
// ------------------------------------------------------------------

Future<void> probes() async {
  final g = await GpuNnBackend.tryCreate();
  if (g == null) {
    print('PROBE_FATAL GpuNnBackend 初始化失败（无 GPU 环境）');
    return;
  }
  try {
    const c = 16, h = 37, w = 53;

    // 1. 上传→回读往返（无 shader，控制项）
    await runCase('fp16_roundtrip', () async {
      final x = NnTensor(wideF32(c * h * w, 101), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final out = await g.downloadFeatureMap(xg, channels: c);
      xg.dispose();
      report('fp16_roundtrip ${c}ch ${h}x$w', out.data, x.data,
          exactRef: hroundTensor(x));
    });

    // 2. relu（最简 shader：h2f → max → f2h）
    await runCase('relu', () async {
      final x = NnTensor(wideF32(c * h * w, 102), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.reluGpu(xg);
      final out = await g.downloadFeatureMap(yg, channels: c);
      xg.dispose();
      yg.dispose();
      report('relu ${c}ch ${h}x$w', out.data, ops.relu(x).data,
          exactRef: simRelu(x));
    });

    // 3. addrelu（RN50 独有）
    await runCase('addrelu', () async {
      final a = NnTensor(wideF32(c * h * w, 103), [1, c, h, w]);
      final b = NnTensor(wideF32(c * h * w, 104), [1, c, h, w]);
      final ag = await g.uploadFeatureMap(a);
      final bg = await g.uploadFeatureMap(b);
      final yg = g.addReluGpu(ag, bg);
      final out = await g.downloadFeatureMap(yg, channels: c);
      ag.dispose();
      bg.dispose();
      yg.dispose();
      final ref = ops.relu(NnTensor(
          Float32List.fromList(
              [for (var i = 0; i < a.numel; i++) a.data[i] + b.data[i]]),
          [1, c, h, w]));
      report('addrelu ${c}ch ${h}x$w', out.data, ref.data,
          exactRef: simAddRelu(a, b));
    });

    // 4. avgpool2x2（RN50 独有，奇数尺寸）
    await runCase('avgpool2x2', () async {
      final x = NnTensor(wideF32(c * h * w, 105), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.avgPool2x2Gpu(xg);
      final out = await g.downloadFeatureMap(yg, channels: c);
      xg.dispose();
      yg.dispose();
      report('avgpool2x2 ${c}ch ${h}x$w', out.data,
          ops.avgPool2d(x, 2, 2, 2, 2, 0, 0).data,
          exactRef: simAvgPool2x2(x));
    });

    // 5. maxpool2x2（已知无漂移基线，奇数尺寸）
    await runCase('maxpool2x2', () async {
      final x = NnTensor(wideF32(c * h * w, 106), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.maxPool2x2Gpu(xg);
      final out = await g.downloadFeatureMap(yg, channels: c);
      xg.dispose();
      yg.dispose();
      report('maxpool2x2 ${c}ch ${h}x$w', out.data,
          ops.maxPool2d(x, 2, 2, 2, 2, 0, 0).data,
          exactRef: simMaxPool(x, 2, 2, 0));
    });

    // 6. pool3x3（Inception 独有）：max s2/p0、max s1/p1、avg s1/p1
    await runCase('pool3x3_max_s2', () async {
      final x = NnTensor(wideF32(c * h * w, 107), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.pool3x3Gpu(xg, avg: false, stride: 2, pad: 0);
      final out = await g.downloadFeatureMap(yg, channels: c);
      xg.dispose();
      yg.dispose();
      report('pool3x3_max_s2 ${c}ch ${h}x$w', out.data,
          ops.maxPool2d(x, 3, 3, 2, 2, 0, 0).data,
          exactRef: simMaxPool(x, 3, 2, 0));
    });
    await runCase('pool3x3_max_s1p1', () async {
      final x = NnTensor(wideF32(c * h * w, 108), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.pool3x3Gpu(xg, avg: false, stride: 1, pad: 1);
      final out = await g.downloadFeatureMap(yg, channels: c);
      xg.dispose();
      yg.dispose();
      report('pool3x3_max_s1p1 ${c}ch ${h}x$w', out.data,
          ops.maxPool2d(x, 3, 3, 1, 1, 1, 1).data,
          exactRef: simMaxPool(x, 3, 1, 1));
    });
    await runCase('pool3x3_avg_s1p1', () async {
      final x = NnTensor(wideF32(c * h * w, 109), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.pool3x3Gpu(xg, avg: true, stride: 1, pad: 1);
      final out = await g.downloadFeatureMap(yg, channels: c);
      xg.dispose();
      yg.dispose();
      report('pool3x3_avg_s1p1 ${c}ch ${h}x$w', out.data,
          ops.avgPool2d(x, 3, 3, 1, 1, 1, 1, countIncludePad: false).data,
          exactRef: simPool3x3Avg(x, 1, 1));
    });

    // 7. l2pool（DISTS；单纹理路径已知无漂移基线）
    await runCase('l2pool', () async {
      final x = NnTensor(wideF32(c * h * w, 110), [1, c, h, w]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.l2PoolDistsGpu(xg);
      final out = await g.downloadFeatureMap(yg, channels: c);
      xg.dispose();
      yg.dispose();
      report('l2pool ${c}ch ${h}x$w', out.data, ops.l2PoolingDists(x).data,
          exactRef: simL2Pool(x));
    });

    // 8. concat4（Inception 独有，纯字节拷贝）
    await runCase('concat4', () async {
      const ch = 13, cw = 17;
      final srcs = [
        for (final (cc, seed) in [(8, 111), (16, 112), (8, 113), (16, 114)])
          NnTensor(wideF32(cc * ch * cw, seed), [1, cc, ch, cw])
      ];
      final gs = [for (final s in srcs) await g.uploadFeatureMap(s)];
      final yg = g.concatChannelsGpu(gs);
      final out =
          await g.downloadFeatureMap(yg, channels: 48);
      for (final t in gs) {
        t.dispose();
      }
      yg.dispose();
      report('concat4 8+16+8+16 ${ch}x$cw', out.data,
          ops.concatChannels(srcs).data,
          exactRef: ops
              .concatChannels(
                  [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
              .data);
      reportGroups('concat4 8+16+8+16 ${ch}x$cw', out.data,
          ops
              .concatChannels(
                  [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
              .data,
          48, ch, cw);
    });

    // 8b. concat4 尺寸/路数扫描（定位损坏与纹理尺寸/路数的关系）
    await runCase('concat4_bigtex', () async {
      // 4 路 16ch 64x48：每路 2*4*64*48=24576 纹素 → 8192x3（TH>1）。
      const ch = 64, cw = 48;
      final srcs = [
        for (final seed in [141, 142, 143, 144])
          NnTensor(wideF32(16 * ch * cw, seed), [1, 16, ch, cw])
      ];
      final gs = [for (final s in srcs) await g.uploadFeatureMap(s)];
      final yg = g.concatChannelsGpu(gs);
      final out = await g.downloadFeatureMap(yg, channels: 64);
      for (final t in gs) {
        t.dispose();
      }
      yg.dispose();
      final sim = ops
          .concatChannels(
              [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
          .data;
      report('concat4_bigtex 16x4 ${ch}x$cw', out.data,
          ops.concatChannels(srcs).data,
          exactRef: sim);
      reportGroups('concat4_bigtex 16x4 ${ch}x$cw', out.data, sim, 64, ch, cw);
    });
    await runCase('concat2way', () async {
      const ch = 13, cw = 17;
      final srcs = [
        NnTensor(wideF32(8 * ch * cw, 145), [1, 8, ch, cw]),
        NnTensor(wideF32(16 * ch * cw, 146), [1, 16, ch, cw]),
      ];
      final gs = [for (final s in srcs) await g.uploadFeatureMap(s)];
      final yg = g.concatChannelsGpu(gs);
      final out = await g.downloadFeatureMap(yg, channels: 24);
      for (final t in gs) {
        t.dispose();
      }
      yg.dispose();
      final sim = ops
          .concatChannels(
              [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
          .data;
      report('concat2way 8+16 ${ch}x$cw', out.data,
          ops.concatChannels(srcs).data,
          exactRef: sim);
      reportGroups('concat2way 8+16 ${ch}x$cw', out.data, sim, 24, ch, cw);
    });
    await runCase('concat4_repeat', () async {
      // 与用例 8 完全相同的输入再跑一次（确定性/残留状态检查）。
      const ch = 13, cw = 17;
      final srcs = [
        for (final (cc, seed) in [(8, 111), (16, 112), (8, 113), (16, 114)])
          NnTensor(wideF32(cc * ch * cw, seed), [1, cc, ch, cw])
      ];
      final gs = [for (final s in srcs) await g.uploadFeatureMap(s)];
      final yg = g.concatChannelsGpu(gs);
      final out = await g.downloadFeatureMap(yg, channels: 48);
      for (final t in gs) {
        t.dispose();
      }
      yg.dispose();
      final sim = ops
          .concatChannels(
              [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
          .data;
      report('concat4_repeat 8+16+8+16 ${ch}x$cw', out.data,
          ops.concatChannels(srcs).data,
          exactRef: sim);
      reportGroups(
          'concat4_repeat 8+16+8+16 ${ch}x$cw', out.data, sim, 48, ch, cw);
    });
    await runCase('concat3way', () async {
      const ch = 13, cw = 17;
      final srcs = [
        for (final (cc, seed) in [(8, 161), (16, 162), (8, 163)])
          NnTensor(wideF32(cc * ch * cw, seed), [1, cc, ch, cw])
      ];
      final gs = [for (final s in srcs) await g.uploadFeatureMap(s)];
      final yg = g.concatChannelsGpu(gs);
      final out = await g.downloadFeatureMap(yg, channels: 32);
      for (final t in gs) {
        t.dispose();
      }
      yg.dispose();
      final sim = ops
          .concatChannels(
              [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
          .data;
      report('concat3way 8+16+8 ${ch}x$cw', out.data,
          ops.concatChannels(srcs).data,
          exactRef: sim);
      reportGroups('concat3way 8+16+8 ${ch}x$cw', out.data, sim, 32, ch, cw);
    });
    await runCase('concat4_16x16', () async {
      // 输出 2*12*16*16=6144 纹素（与 stitch 失败宽度 6144 相同）。
      const ch = 16, cw = 16;
      final srcs = [
        for (final (cc, seed) in [(8, 171), (16, 172), (8, 173), (16, 174)])
          NnTensor(wideF32(cc * ch * cw, seed), [1, cc, ch, cw])
      ];
      final gs = [for (final s in srcs) await g.uploadFeatureMap(s)];
      final yg = g.concatChannelsGpu(gs);
      final out = await g.downloadFeatureMap(yg, channels: 48);
      for (final t in gs) {
        t.dispose();
      }
      yg.dispose();
      final sim = ops
          .concatChannels(
              [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
          .data;
      report('concat4 8+16+8+16 ${ch}x$cw', out.data,
          ops.concatChannels(srcs).data,
          exactRef: sim);
      reportGroups('concat4 8+16+8+16 ${ch}x$cw', out.data, sim, 48, ch, cw);
    });
    await runCase('concat4_32x32', () async {
      // 源 8ch:4096×1 / 16ch:8192×1（TH=1），输出 24576→8192×3（TH=3）。
      const ch = 32, cw = 32;
      final srcs = [
        for (final (cc, seed) in [(8, 181), (16, 182), (8, 183), (16, 184)])
          NnTensor(wideF32(cc * ch * cw, seed), [1, cc, ch, cw])
      ];
      final gs = [for (final s in srcs) await g.uploadFeatureMap(s)];
      final yg = g.concatChannelsGpu(gs);
      final out = await g.downloadFeatureMap(yg, channels: 48);
      for (final t in gs) {
        t.dispose();
      }
      yg.dispose();
      final sim = ops
          .concatChannels(
              [for (final s in srcs) NnTensor(hroundTensor(s), s.shape)])
          .data;
      report('concat4 8+16+8+16 ${ch}x$cw', out.data,
          ops.concatChannels(srcs).data,
          exactRef: sim);
      reportGroups('concat4 8+16+8+16 ${ch}x$cw', out.data, sim, 48, ch, cw);
    });

    // 9. conv3x3 s1（已知无漂移基线）
    await runCase('conv_s1', () async {
      const cin = 8, cout = 16;
      final x = NnTensor(randF32(cin * h * w, 121), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 9, 122, scale: 0.3),
          [cout, cin, 3, 3]);
      final bias = randF32(cout, 123, scale: 0.5);
      final ref = ops.conv2d(x, wgt, bias: bias, padH: 1, padW: 1);
      final out =
          await g.conv2dAsync(x, wgt, bias: bias, padH: 1, padW: 1);
      report('conv3x3_s1 $cin->$cout ${h}x$w', out.data, ref.data);
    });

    // 10. conv3x3 s2（RN50 独有 uStride=2 分支）
    await runCase('conv_s2', () async {
      const cin = 8, cout = 16;
      final x = NnTensor(randF32(cin * h * w, 124), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 9, 125, scale: 0.3),
          [cout, cin, 3, 3]);
      final bias = randF32(cout, 126, scale: 0.5);
      final ref = ops.conv2d(x, wgt,
          bias: bias, strideH: 2, strideW: 2, padH: 1, padW: 1);
      final out = await g.conv2dAsync(x, wgt,
          bias: bias, strideH: 2, strideW: 2, padH: 1, padW: 1);
      report('conv3x3_s2 $cin->$cout ${h}x$w', out.data, ref.data);
    });

    // 11. conv1x1 s1（嵌入 3x3 中心 tap 路径的原始形态）
    await runCase('conv_1x1', () async {
      const cin = 16, cout = 8;
      final x = NnTensor(randF32(cin * h * w, 127), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin, 128, scale: 0.3),
          [cout, cin, 1, 1]);
      final ref = ops.conv2d(x, wgt);
      final out = await g.conv2dAsync(x, wgt);
      report('conv1x1_s1 $cin->$cout ${h}x$w', out.data, ref.data);
    });

    // 11b. conv1x1 测试原形状（isp_nn_gpu_test.dart 的 24x24 16->16）
    await runCase('conv_1x1_testshape', () async {
      const cin = 16, cout = 16, hh = 24, ww = 24;
      final x = NnTensor(randF32(cin * hh * ww, 147), [1, cin, hh, ww]);
      final wgt = NnTensor(randF32(cout * cin, 148, scale: 0.3),
          [cout, cin, 1, 1]);
      final ref = ops.conv2d(x, wgt);
      final out = await g.conv2dAsync(x, wgt);
      report('conv1x1_s1 $cin->$cout ${hh}x$ww(testshape)', out.data, ref.data);
    });

    // 11c. conv1x1 生产路径（embed1x1 嵌入 3x3 中心 tap + pad 1，RN50 用法）
    await runCase('conv_1x1_embed', () async {
      const cin = 16, cout = 8;
      final x = NnTensor(randF32(cin * h * w, 149), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin, 150, scale: 0.3),
          [cout, cin, 1, 1]);
      final ref = ops.conv2d(x, wgt);
      final wgtE = GpuNnBackend.embed1x1(wgt);
      final out = await g.conv2dAsync(x, wgtE, padH: 1, padW: 1);
      report('conv1x1_embed $cin->$cout ${h}x$w', out.data, ref.data);
    });

    // 11d. conv7x7 s2 p3（RN50 stem 形态，k≤7 泛化路径）
    await runCase('conv_7x7_s2p3', () async {
      const cin = 8, cout = 16;
      final x = NnTensor(randF32(cin * h * w, 151), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 49, 152, scale: 0.1),
          [cout, cin, 7, 7]);
      final ref = ops.conv2d(x, wgt,
          strideH: 2, strideW: 2, padH: 3, padW: 3);
      final out = await g.conv2dAsync(x, wgt,
          strideH: 2, strideW: 2, padH: 3, padW: 3);
      report('conv7x7_s2p3 $cin->$cout ${h}x$w', out.data, ref.data);
    });

    // 11e. conv1x7 / 7x1 s1（Inception 非对称 k≤7 路径）
    await runCase('conv_1x7', () async {
      const cin = 8, cout = 16;
      final x = NnTensor(randF32(cin * h * w, 153), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 7, 154, scale: 0.2),
          [cout, cin, 1, 7]);
      final ref = ops.conv2d(x, wgt, padH: 0, padW: 3);
      final out = await g.conv2dAsync(x, wgt, padH: 0, padW: 3);
      report('conv1x7_s1p03 $cin->$cout ${h}x$w', out.data, ref.data);
    });
    await runCase('conv_7x1', () async {
      const cin = 8, cout = 16;
      final x = NnTensor(randF32(cin * h * w, 155), [1, cin, h, w]);
      final wgt = NnTensor(randF32(cout * cin * 7, 156, scale: 0.2),
          [cout, cin, 7, 1]);
      final ref = ops.conv2d(x, wgt, padH: 3, padW: 0);
      final out = await g.conv2dAsync(x, wgt, padH: 3, padW: 0);
      report('conv7x1_s1p30 $cin->$cout ${h}x$w', out.data, ref.data);
    });

    // ----------------------------------------------------------------
    // 第三轮：bias 有无 × kernel × 通道数的判别矩阵
    // （动机：VGG 全部 conv 有 bias 且无漂移；RN50/Inception 全部 conv
    // 无 bias 且漂移）
    // ----------------------------------------------------------------
    Future<void> convCase(String name, int cin, int cout, int k,
        {bool bias = false, int hh = 37, int ww = 53, int seed = 200}) async {
      await runCase(name, () async {
        final x = NnTensor(randF32(cin * hh * ww, seed), [1, cin, hh, ww]);
        final wgt = NnTensor(
            randF32(cout * cin * k * k, seed + 1, scale: 0.3),
            [cout, cin, k, k]);
        final b = bias ? randF32(cout, seed + 2, scale: 0.5) : null;
        final pad = k == 3 ? 1 : 0;
        final ref = ops.conv2d(x, wgt, bias: b, padH: pad, padW: pad);
        final out =
            await g.conv2dAsync(x, wgt, bias: b, padH: pad, padW: pad);
        report('$name $cin->$cout ${hh}x$ww k$k bias=$bias', out.data,
            ref.data);
      });
    }

    await convCase('conv_k3_16to8_nobias', 16, 8, 3, seed: 210);
    await convCase('conv_k3_16to8_bias', 16, 8, 3, bias: true, seed: 220);
    await convCase('conv_k1_16to8_bias', 16, 8, 1, bias: true, seed: 230);
    await convCase('conv_k3_8to16_nobias', 8, 16, 3, seed: 240);
    await convCase('conv_k1_8to16_nobias', 8, 16, 1, seed: 250);
    await convCase('conv_k1_16to16_24_bias', 16, 16, 1,
        bias: true, hh: 24, ww: 24, seed: 260);
    await convCase('conv_k1_16to16_24_nobias', 16, 16, 1,
        hh: 24, ww: 24, seed: 270);

    // ----------------------------------------------------------------
    // 第四轮：输出纹理尺寸阈值定位
    // （数据指向：写入宽度 ∈ (4104, 8192) 的 TH=1 折叠纹理时损坏；
    // 1x1/16→8 失败实为输出 7844×1/4608×1 所致，与 kernel/通道无关）
    // ----------------------------------------------------------------
    // 4a. 诅咒尺寸的上传→回读往返（无 shader：判别回读路径 vs 渲染路径）
    await runCase('roundtrip_7844', () async {
      const cc = 8, hh = 37, ww = 53; // 2*2*37*53 = 7844 纹素
      final x = NnTensor(wideF32(cc * hh * ww, 301), [1, cc, hh, ww]);
      final xg = await g.uploadFeatureMap(x);
      final out = await g.downloadFeatureMap(xg, channels: cc);
      xg.dispose();
      report('roundtrip_7844 ${cc}ch ${hh}x$ww', out.data, x.data,
          exactRef: hroundTensor(x));
    });
    await runCase('roundtrip_4608', () async {
      const cc = 16, hh = 24, ww = 24; // 2*4*24*24 = 4608 纹素
      final x = NnTensor(wideF32(cc * hh * ww, 302), [1, cc, hh, ww]);
      final xg = await g.uploadFeatureMap(x);
      final out = await g.downloadFeatureMap(xg, channels: cc);
      xg.dispose();
      report('roundtrip_4608 ${cc}ch ${hh}x$ww', out.data, x.data,
          exactRef: hroundTensor(x));
    });
    // 4b. relu 写入 7844×1（最简渲染 pass 进诅咒尺寸目标）
    await runCase('relu_7844', () async {
      const cc = 8, hh = 37, ww = 53;
      final x = NnTensor(wideF32(cc * hh * ww, 303), [1, cc, hh, ww]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.reluGpu(xg);
      final out = await g.downloadFeatureMap(yg, channels: cc);
      xg.dispose();
      yg.dispose();
      report('relu_7844 ${cc}ch ${hh}x$ww', out.data, ops.relu(x).data,
          exactRef: simRelu(x));
    });
    // 4c. conv 8→8 输出宽度扫描（cinG=2 已知良好侧，隔离输出尺寸效应）
    for (final (hh, ww) in [
      (16, 16), // out 2048
      (32, 24), // out 3072
      (32, 32), // out 4096
      (33, 32), // out 4224
      (34, 32), // out 4352
      (36, 32), // out 4608
      (24, 48), // out 4608
      (37, 53), // out 7844
    ]) {
      await convCase('conv_k3_8to8_sweep', 8, 8, 3,
          hh: hh, ww: ww, seed: 310 + hh * 100 + ww);
    }
    // 4d. relu 输出宽度扫描（同尺寸逐元素 pass，定位阈值）
    for (final (hh, ww) in [(32, 32), (34, 32), (36, 32), (37, 53)]) {
      await runCase('relu_sweep_$hh x$ww', () async {
        const cc = 8;
        final x = NnTensor(wideF32(cc * hh * ww, 400 + hh), [1, cc, hh, ww]);
        final xg = await g.uploadFeatureMap(x);
        final yg = g.reluGpu(xg);
        final out = await g.downloadFeatureMap(yg, channels: cc);
        xg.dispose();
        yg.dispose();
        report('relu_sweep ${cc}ch ${hh}x$ww '
            '(texels=${2 * 2 * hh * ww})', out.data, ops.relu(x).data,
            exactRef: simRelu(x));
      });
    }

    // ----------------------------------------------------------------
    // 第五轮：诅咒区间上界确认 + 内容损坏 vs 回读损坏判别
    // ----------------------------------------------------------------
    // 5a. 上界：8000 / 8192(恰 32KiB) / 8704(→8192×2，对照)
    for (final (cc, hh, ww) in [(8, 40, 50), (16, 32, 32), (16, 32, 34)]) {
      await runCase('relu_bound_${cc}ch_${hh}x$ww', () async {
        final x = NnTensor(wideF32(cc * hh * ww, 500 + hh), [1, cc, hh, ww]);
        final xg = await g.uploadFeatureMap(x);
        final yg = g.reluGpu(xg);
        final out = await g.downloadFeatureMap(yg, channels: cc);
        xg.dispose();
        yg.dispose();
        report('relu_bound ${cc}ch ${hh}x$ww '
            '(texels=${2 * (cc ~/ 4) * hh * ww})', out.data,
            ops.relu(x).data,
            exactRef: simRelu(x));
      });
    }
    // 5b. relu（输出 7844×1，诅咒）→ maxpool2x2（输出 3744×1，安全）：
    // 若池化结果精确，则诅咒纹理内容本身完好、损坏在回读/物化环节；
    // 若不精确，则渲染已写入错误内容。
    await runCase('relu_cursed_then_maxpool', () async {
      const cc = 8, hh = 37, ww = 53;
      final x = NnTensor(wideF32(cc * hh * ww, 510), [1, cc, hh, ww]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.reluGpu(xg); // 7844×1 诅咒中间纹理
      final zg = g.maxPool2x2Gpu(yg); // 3744×1 安全输出
      final out = await g.downloadFeatureMap(zg, channels: cc);
      xg.dispose();
      yg.dispose();
      zg.dispose();
      report('relu_cursed_then_maxpool ${cc}ch ${hh}x$ww', out.data,
          ops.maxPool2d(ops.relu(x), 2, 2, 2, 2, 0, 0).data,
          exactRef: simMaxPool(NnTensor(simRelu(x), [1, cc, hh, ww]), 2, 2, 0));
    });
    // 5c. 反向：安全渲染输出（8192×2）经 relu 后从诅咒尺寸输入采样——
    // 5b 的对照（输入 8192×2 安全纹理，输出 3744×1 安全），应恒精确。
    await runCase('relu_safe_then_maxpool', () async {
      const cc = 16, hh = 37, ww = 53; // 中间 8192×2 安全
      final x = NnTensor(wideF32(cc * hh * ww, 511), [1, cc, hh, ww]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.reluGpu(xg);
      final zg = g.maxPool2x2Gpu(yg);
      final out = await g.downloadFeatureMap(zg, channels: cc);
      xg.dispose();
      yg.dispose();
      zg.dispose();
      report('relu_safe_then_maxpool ${cc}ch ${hh}x$ww', out.data,
          ops.maxPool2d(ops.relu(x), 2, 2, 2, 2, 0, 0).data,
          exactRef: simMaxPool(NnTensor(simRelu(x), [1, cc, hh, ww]), 2, 2, 0));
    });

    // ----------------------------------------------------------------
    // 第六轮：更大尺寸的渲染损坏扫描（RN50@224² 的中间纹理为
    // 12544/25088/50176/100352/200704/401408 纹素，远超已测范围）
    // ----------------------------------------------------------------
    for (final (hh, ww) in [
      (32, 48), // 12288
      (28, 56), // 12544 RN50 layer4 512ch@7² 同纹素数
      (32, 64), // 16384
      (40, 64), // 20480
      (48, 64), // 24576
      (56, 56), // 25088 RN50 layer3 256ch@14²
      (64, 64), // 32768
      (64, 80), // 40960
      (64, 96), // 49152
      (56, 112), // 50176 RN50 多尺寸
      (128, 64), // 65536
      (112, 112), // 100352 RN50 56²×64ch
    ]) {
      await runCase('relu_big_$hh x$ww', () async {
        const cc = 16;
        final x = NnTensor(wideF32(cc * hh * ww, 600 + hh), [1, cc, hh, ww]);
        final xg = await g.uploadFeatureMap(x);
        final yg = g.reluGpu(xg);
        final out = await g.downloadFeatureMap(yg, channels: cc);
        xg.dispose();
        yg.dispose();
        report('relu_big ${cc}ch ${hh}x$ww '
            '(texels=${2 * 4 * hh * ww})', out.data, ops.relu(x).data,
            exactRef: simRelu(x));
      });
    }

    // ----------------------------------------------------------------
    // 第七轮：RN50@224² 真实形状的原语复测（ curse 区间已全部排除，
    // 剩余变量：大纹理上的 no-bias conv / embed1x1 / s2 / avgpool /
    // addrelu）
    // ----------------------------------------------------------------
    await convCase('conv_k3_64to64_56_nobias', 64, 64, 3,
        hh: 56, ww: 56, seed: 710);
    await convCase('conv_k3_64to64_56_bias', 64, 64, 3,
        hh: 56, ww: 56, bias: true, seed: 720);
    await runCase('conv_embed1x1_64to64_56', () async {
      const cin = 64, cout = 64, hh = 56, ww = 56;
      final x = NnTensor(randF32(cin * hh * ww, 730), [1, cin, hh, ww]);
      final wgt = NnTensor(randF32(cout * cin, 731, scale: 0.1),
          [cout, cin, 1, 1]);
      final ref = ops.conv2d(x, wgt);
      final out =
          await g.conv2dAsync(x, GpuNnBackend.embed1x1(wgt), padH: 1, padW: 1);
      report('conv_embed1x1_64to64_56 $cin->$cout ${hh}x$ww', out.data,
          ref.data);
    });
    await runCase('conv_k3s2_64to128_56', () async {
      const cin = 64, cout = 128, hh = 56, ww = 56;
      final x = NnTensor(randF32(cin * hh * ww, 740), [1, cin, hh, ww]);
      final wgt = NnTensor(randF32(cout * cin * 9, 741, scale: 0.1),
          [cout, cin, 3, 3]);
      final ref = ops.conv2d(x, wgt,
          strideH: 2, strideW: 2, padH: 1, padW: 1);
      final out = await g.conv2dAsync(x, wgt,
          strideH: 2, strideW: 2, padH: 1, padW: 1);
      report('conv_k3s2_64to128_56 $cin->$cout ${hh}x$ww', out.data, ref.data);
    });
    await runCase('avgpool_128ch_56', () async {
      const cc = 128, hh = 56, ww = 56;
      final x = NnTensor(wideF32(cc * hh * ww, 750), [1, cc, hh, ww]);
      final xg = await g.uploadFeatureMap(x);
      final yg = g.avgPool2x2Gpu(xg);
      final out = await g.downloadFeatureMap(yg, channels: cc);
      xg.dispose();
      yg.dispose();
      report('avgpool_128ch_56 ${cc}ch ${hh}x$ww (out texels='
          '${2 * 32 * 28 * 28})', out.data,
          ops.avgPool2d(x, 2, 2, 2, 2, 0, 0).data,
          exactRef: simAvgPool2x2(x));
    });
    await runCase('addrelu_256ch_56', () async {
      const cc = 256, hh = 56, ww = 56;
      final a = NnTensor(wideF32(cc * hh * ww, 760), [1, cc, hh, ww]);
      final b = NnTensor(wideF32(cc * hh * ww, 761), [1, cc, hh, ww]);
      final ag = await g.uploadFeatureMap(a);
      final bg = await g.uploadFeatureMap(b);
      final yg = g.addReluGpu(ag, bg);
      final out = await g.downloadFeatureMap(yg, channels: cc);
      ag.dispose();
      bg.dispose();
      yg.dispose();
      report('addrelu_256ch_56 ${cc}ch ${hh}x$ww', out.data,
          ops
              .relu(NnTensor(
                  Float32List.fromList([
                    for (var i = 0; i < a.numel; i++) a.data[i] + b.data[i]
                  ]),
                  [1, cc, hh, ww]))
              .data,
          exactRef: simAddRelu(a, b));
    });

    // ----------------------------------------------------------------
    // 第八轮：addrelu 大纹理劣化的触发条件矩阵
    // （通道组数 cinG × 总纹素数 × 纹理行数 TH 三变量分离；
    // 已确认 16ch 8192×2 精确、256ch 8192×49 出现 ~28% 的 -1 ulp 劣化）
    // ----------------------------------------------------------------
    Future<void> addReluCase(int cc, int hh, int ww, int seed) async {
      await runCase('addrelu_${cc}ch_${hh}x$ww', () async {
        final a = NnTensor(wideF32(cc * hh * ww, seed), [1, cc, hh, ww]);
        final b = NnTensor(wideF32(cc * hh * ww, seed + 1), [1, cc, hh, ww]);
        final ag = await g.uploadFeatureMap(a);
        final bg = await g.uploadFeatureMap(b);
        final yg = g.addReluGpu(ag, bg);
        final out = await g.downloadFeatureMap(yg, channels: cc);
        ag.dispose();
        bg.dispose();
        yg.dispose();
        final ref = ops.relu(NnTensor(
            Float32List.fromList(
                [for (var i = 0; i < a.numel; i++) a.data[i] + b.data[i]]),
            [1, cc, hh, ww]));
        report(
            'addrelu ${cc}ch ${hh}x$ww '
            '(texels=${2 * (cc ~/ 4) * hh * ww} TH='
            '${(2 * (cc ~/ 4) * hh * ww + 8191) ~/ 8192})',
            out.data, ref.data,
            exactRef: simAddRelu(a, b));
      });
    }

    await addReluCase(256, 14, 14, 801); // 100352 TH=13
    await addReluCase(256, 28, 28, 803); // 200704 TH=25
    await addReluCase(128, 56, 56, 805); // 200704 TH=25 同纹素不同通道
    await addReluCase(64, 112, 112, 807); // 200704 TH=25
    await addReluCase(16, 224, 224, 809); // 401408 TH=49 同纹素不同通道
    await addReluCase(256, 44, 44, 811); // 247808 <2^18
    await addReluCase(256, 46, 46, 813); // 270848 >2^18
    await addReluCase(64, 56, 56, 815); // 100352 对照
    await addReluCase(512, 7, 7, 817); // 50176 RN50 layer4 形状

    // 第九轮：劣化元素的纹理行分布（256ch 56² 失败例 + 28² 精确对照）
    // 第十轮：打印前若干个劣化元素的完整位型（操作数 half bits、精确
    // 和、sim/GPU 输出 bits），判定算术层面的劣化机制
    await runCase('addrelu_256ch_56_bits', () async {
      const cc = 256, hh = 56, ww = 56;
      final a = NnTensor(wideF32(cc * hh * ww, 760), [1, cc, hh, ww]);
      final b = NnTensor(wideF32(cc * hh * ww, 761), [1, cc, hh, ww]);
      final ag = await g.uploadFeatureMap(a);
      final bg = await g.uploadFeatureMap(b);
      final yg = g.addReluGpu(ag, bg);
      final out = await g.downloadFeatureMap(yg, channels: cc);
      ag.dispose();
      bg.dispose();
      yg.dispose();
      final sim = simAddRelu(a, b);
      var printed = 0;
      var downN = 0, upN = 0;
      for (var i = 0; i < out.numel && printed < 12; i++) {
        if (f32bits(out.data[i]) == f32bits(sim[i])) continue;
        final ha = floatToHalfBits(a.data[i]);
        final hb = floatToHalfBits(b.data[i]);
        final va = halfBitsToFloat(ha), vb = halfBitsToFloat(hb);
        final sum = va + vb;
        final gpuBits = floatToHalfBits(out.data[i]);
        final simBits = floatToHalfBits(sim[i]);
        print('PROBE_BITS @$i a=0x${ha.toRadixString(16)}($va) '
            'b=0x${hb.toRadixString(16)}($vb) sum=$sum '
            'simBits=0x${simBits.toRadixString(16)} '
            'gpuBits=0x${gpuBits.toRadixString(16)} '
            'gpuVal=${out.data[i]}');
        printed++;
      }
      for (var i = 0; i < out.numel; i++) {
        if (f32bits(out.data[i]) == f32bits(sim[i])) continue;
        if (out.data[i] < sim[i]) {
          downN++;
        } else {
          upN++;
        }
      }
      print('PROBE_BITS_SUMMARY down=$downN up=$upN');
    });
    await runCase('addrelu_128ch_56_texrows', () async {
      const cc = 128, hh = 56, ww = 56;
      final a = NnTensor(wideF32(cc * hh * ww, 805), [1, cc, hh, ww]);
      final b = NnTensor(wideF32(cc * hh * ww, 806), [1, cc, hh, ww]);
      final ag = await g.uploadFeatureMap(a);
      final bg = await g.uploadFeatureMap(b);
      final yg = g.addReluGpu(ag, bg);
      final out = await g.downloadFeatureMap(yg, channels: cc);
      ag.dispose();
      bg.dispose();
      yg.dispose();
      reportTexRows('addrelu_128ch_56', out.data, simAddRelu(a, b), cc, hh, ww);
    });
    // ----------------------------------------------------------------
    // banded 用例（照搬 isp_nn_gpu_rn50_test.dart：预算 65536，
    // 64ch 65x48 → 带 [32,32,1]）
    // ----------------------------------------------------------------
    const bc = 64, bh = 65, bw = 48;
    GpuNnBackend.debugMaxBandTexels = 65536;
    try {
      // 12. banded relu（无 stitch，分块上传/回读控制项）
      await runCase('banded_relu', () async {
        final x = NnTensor(wideF32(bc * bh * bw, 130), [1, bc, bh, bw]);
        final xg = await g.uploadFeatureMapBanded(x);
        print('PROBE_INFO banded_relu 带=${xg.bandHeights}');
        final yg = g.reluGpuBanded(xg);
        final out = await g.downloadFeatureMapBanded(yg, channels: bc);
        xg.dispose();
        yg.dispose();
        report('banded_relu ${bc}ch ${bh}x$bw', out.data, ops.relu(x).data,
            exactRef: simRelu(x));
      });

      // 13. banded conv s1（stitch ±1 行 halo + uYOff=1）
      await runCase('banded_conv_s1', () async {
        const cin = bc, cout = bc;
        final x = NnTensor(randF32(cin * bh * bw, 131), [1, cin, bh, bw]);
        final wgt = NnTensor(randF32(cout * cin * 9, 132, scale: 0.1),
            [cout, cin, 3, 3]);
        final bias = randF32(cout, 133, scale: 0.1);
        final ref = ops.conv2d(x, wgt, bias: bias, padH: 1, padW: 1);
        final xg = await g.uploadFeatureMapBanded(x);
        print('PROBE_INFO banded_conv_s1 输入带=${xg.bandHeights}');
        final wg = await g.uploadConvWeights(wgt, cin, bias: bias);
        final outB = g.conv2dGpuBanded(xg, wg);
        print('PROBE_INFO banded_conv_s1 输出带=${outB.bandHeights}');
        final out = await g.downloadFeatureMapBanded(outB, channels: cout);
        xg.dispose();
        wg.dispose();
        outB.dispose();
        report('banded_conv_s1 $cin->$cout ${bh}x$bw', out.data, ref.data);
        // GPU-vs-GPU：同输入单纹理路径（隔离 stitch/uYOff 贡献）
        final single =
            await g.conv2dAsync(x, wgt, bias: bias, padH: 1, padW: 1);
        reportPair('banded_conv_s1_vs_single', out.data, single.data);
        reportRows(
            'banded_conv_s1_vs_single', out.data, single.data, cout, bh, bw);
      });

      // 13b. stitch 隔离：恒等中心 tap conv（输出应 = 输入的 fp16 往返，
      // 任何偏差只能来自 stitch 拼接）
      await runCase('stitch_identity', () async {
        const cc = bc;
        final x = NnTensor(wideF32(cc * bh * bw, 140), [1, cc, bh, bw]);
        final wData = Float32List(cc * cc * 9);
        for (var i = 0; i < cc; i++) {
          wData[(i * cc + i) * 9 + 4] = 1.0; // 中心 tap 单位脉冲
        }
        final wgt = NnTensor(wData, [cc, cc, 3, 3]);
        final xg = await g.uploadFeatureMapBanded(x);
        final wg = await g.uploadConvWeights(wgt, cc);
        final outB = g.conv2dGpuBanded(xg, wg);
        final out = await g.downloadFeatureMapBanded(outB, channels: cc);
        xg.dispose();
        wg.dispose();
        outB.dispose();
        final single = await g.conv2dAsync(x, wgt, padH: 1, padW: 1);
        report('stitch_identity ${cc}ch ${bh}x$bw', out.data,
            hroundTensor(x),
            exactRef: single.data);
        reportRows('stitch_identity_vs_single', out.data, single.data, cc,
            bh, bw);
      });

      // 13c. stitch 尺寸扫描：h=66 → 末带 2 行（padded 输出 6144×1）；
      // h=68 → 末带 4 行（padded 输出 9216→8192×2，TH=2）。判别损坏是否
      // 跟随 padded 带纹理 TH=1。
      for (final hh in [66, 68]) {
        await runCase('stitch_identity_h$hh', () async {
          const cc = bc;
          final x = NnTensor(wideF32(cc * hh * bw, 140 + hh), [1, cc, hh, bw]);
          final wData = Float32List(cc * cc * 9);
          for (var i = 0; i < cc; i++) {
            wData[(i * cc + i) * 9 + 4] = 1.0;
          }
          final wgt = NnTensor(wData, [cc, cc, 3, 3]);
          final xg = await g.uploadFeatureMapBanded(x);
          print('PROBE_INFO stitch_identity_h$hh 输入带=${xg.bandHeights}');
          final wg = await g.uploadConvWeights(wgt, cc);
          final outB = g.conv2dGpuBanded(xg, wg);
          final out = await g.downloadFeatureMapBanded(outB, channels: cc);
          xg.dispose();
          wg.dispose();
          outB.dispose();
          final single = await g.conv2dAsync(x, wgt, padH: 1, padW: 1);
          report('stitch_identity_h$hh ${cc}ch ${hh}x$bw', out.data,
              hroundTensor(x),
              exactRef: single.data);
          reportRows('stitch_identity_h${hh}_vs_single', out.data,
              single.data, cc, hh, bw);
        });
      }

      // 14. banded conv s2（stitch 2th+2 行 padded 带 + uYOff=1 + uStride=2）
      await runCase('banded_conv_s2', () async {
        const cin = bc, cout = bc;
        final x = NnTensor(randF32(cin * bh * bw, 134), [1, cin, bh, bw]);
        final wgt = NnTensor(randF32(cout * cin * 9, 135, scale: 0.1),
            [cout, cin, 3, 3]);
        final bias = randF32(cout, 136, scale: 0.1);
        final ref = ops.conv2d(x, wgt,
            bias: bias, strideH: 2, strideW: 2, padH: 1, padW: 1);
        final xg = await g.uploadFeatureMapBanded(x);
        final wg = await g.uploadConvWeights(wgt, cin, bias: bias);
        final outB = g.conv2dGpuBanded(xg, wg, stride: 2);
        print('PROBE_INFO banded_conv_s2 输出带=${outB.bandHeights}');
        final out = await g.downloadFeatureMapBanded(outB, channels: cout);
        xg.dispose();
        wg.dispose();
        outB.dispose();
        report('banded_conv_s2 $cin->$cout ${bh}x$bw', out.data, ref.data);
        final single = await g.conv2dAsync(x, wgt,
            bias: bias, strideH: 2, strideW: 2, padH: 1, padW: 1);
        reportPair('banded_conv_s2_vs_single', out.data, single.data);
        reportRows('banded_conv_s2_vs_single', out.data, single.data, cout,
            (bh + 1) ~/ 2, bw ~/ 2);
      });

      // 15. banded l2pool（DISTS 大图的 stitch + uYOff=1 路径）
      await runCase('banded_l2pool', () async {
        final x = NnTensor(wideF32(bc * bh * bw, 137), [1, bc, bh, bw]);
        final ref = ops.l2PoolingDists(x);
        final xg = await g.uploadFeatureMapBanded(x);
        final outB = g.l2PoolDistsGpuBanded(xg);
        print('PROBE_INFO banded_l2pool 输出带=${outB.bandHeights}');
        final out = await g.downloadFeatureMapBanded(outB, channels: bc);
        xg.dispose();
        outB.dispose();
        report('banded_l2pool ${bc}ch ${bh}x$bw', out.data, ref.data);
        final xgs = await g.uploadFeatureMap(x);
        final single = await g
            .downloadFeatureMap(g.l2PoolDistsGpu(xgs), channels: bc);
        xgs.dispose();
        reportPair('banded_l2pool_vs_single', out.data, single.data);
        reportRows('banded_l2pool_vs_single', out.data, single.data, bc,
            (bh + 1) ~/ 2, (bw + 1) ~/ 2);
      });

      // 16. banded avgpool（逐带直接执行，无 stitch；奇偶/末带高 1 控制项）
      await runCase('banded_avgpool', () async {
        final x = NnTensor(wideF32(bc * bh * bw, 138), [1, bc, bh, bw]);
        final ref = ops.avgPool2d(x, 2, 2, 2, 2, 0, 0);
        final xg = await g.uploadFeatureMapBanded(x);
        final outB = g.avgPool2x2GpuBanded(xg);
        print('PROBE_INFO banded_avgpool 输出带=${outB.bandHeights}');
        final out = await g.downloadFeatureMapBanded(outB, channels: bc);
        xg.dispose();
        outB.dispose();
        report('banded_avgpool ${bc}ch ${bh}x$bw', out.data, ref.data);
        final xgs = await g.uploadFeatureMap(x);
        final single = await g
            .downloadFeatureMap(g.avgPool2x2Gpu(xgs), channels: bc);
        xgs.dispose();
        reportPair('banded_avgpool_vs_single', out.data, single.data);
      });
    } finally {
      GpuNnBackend.debugMaxBandTexels = 0;
    }
  } finally {
    g.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('nn gpu primitive probe')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await probes();
      print('PROBE_DONE');
    } catch (e, st) {
      print('PROBE_FATAL $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  });
}
