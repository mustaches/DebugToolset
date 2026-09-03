/// NN 推理引擎与 torch 黄金值对拍：
/// 读 test/golden/nn_ops_golden.{json,nnw}（由 tools/iqa/dump_golden.py
/// 生成），逐 case 跑对应 op 并比较输出。另有 gemm 自洽测试与
/// NnPool 并行/单线程一致性测试。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/gemm.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nn_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nnw_reader.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/ops.dart'
    as ops;
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/tensor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 最大绝对误差（double 域计算）。
double maxAbsDiff(Float32List a, Float32List b) {
  var d = 0.0;
  for (var i = 0; i < a.length; i++) {
    final v = (a[i] - b[i]).abs();
    if (v > d) {
      d = v;
    }
  }
  return d;
}

/// 位级一致（并行 vs 单线程应完全相同）。
int countBitDiff(Float32List a, Float32List b) {
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      n++;
    }
  }
  return n;
}

void main() {
  final goldenDir = 'test/golden';
  final casesJson = jsonDecode(
          File('$goldenDir/nn_ops_golden.json').readAsStringSync())
      as Map<String, dynamic>;
  final cases = (casesJson['cases'] as List).cast<Map<String, dynamic>>();

  late NnwReader reader;

  NnTensor t(String name) => reader.readTensor(name);

  /// 按 case 描述分发执行对应 op。
  NnTensor runCase(Map<String, dynamic> c) {
    final op = c['op'] as String;
    final attrs = (c['attrs'] as Map).cast<String, dynamic>();
    final inputs = (c['inputs'] as Map).cast<String, String>();
    List<int> ints(String key) => (attrs[key] as List).cast<int>();
    double dbl(String key) => (attrs[key] as num).toDouble();
    Float32List? optData(String key) =>
        inputs.containsKey(key) ? t(inputs[key]!).data : null;
    switch (op) {
      case 'conv2d':
        final s = ints('stride');
        final p = ints('padding');
        return ops.conv2d(t(inputs['x']!), t(inputs['weight']!),
            bias: optData('bias'),
            strideH: s[0],
            strideW: s[1],
            padH: p[0],
            padW: p[1],
            groups: attrs['groups'] as int);
      case 'maxpool2d':
        final k = ints('kernel_size');
        final s = ints('stride');
        final p = ints('padding');
        return ops.maxPool2d(
            t(inputs['x']!), k[0], k[1], s[0], s[1], p[0], p[1]);
      case 'avgpool2d':
        final k = ints('kernel_size');
        final s = ints('stride');
        final p = ints('padding');
        return ops.avgPool2d(t(inputs['x']!), k[0], k[1], s[0], s[1], p[0],
            p[1],
            countIncludePad: attrs['count_include_pad'] as bool);
      case 'adaptive_avgpool2d':
        final size = ints('output_size');
        expect(size, [1, 1], reason: '测试仅覆盖 1x1');
        return ops.adaptiveAvgPool1x1(t(inputs['x']!));
      case 'resize_bilinear':
        final size = ints('size');
        return ops.resizeBilinear(t(inputs['x']!), size[0], size[1]);
      case 'resize_bicubic':
        final size = ints('size');
        return ops.resizeBicubic(t(inputs['x']!), size[0], size[1]);
      case 'layernorm':
        return ops.layerNorm(t(inputs['x']!), ints('normalized_shape'),
            t(inputs['weight']!).data, t(inputs['bias']!).data,
            eps: dbl('eps'));
      case 'groupnorm':
        return ops.groupNorm(t(inputs['x']!), attrs['num_groups'] as int,
            t(inputs['weight']!).data, t(inputs['bias']!).data,
            eps: dbl('eps'));
      case 'gelu':
        expect(attrs['approximate'], 'none');
        return ops.gelu(t(inputs['x']!));
      case 'softmax':
        expect(attrs['dim'], -1);
        return ops.softmax(t(inputs['x']!));
      case 'linear':
        return ops.linear(t(inputs['x']!), t(inputs['weight']!),
            bias: optData('bias'));
      case 'l2_normalize_channels':
        expect(attrs['dim'], 1);
        return ops.l2NormalizeChannels(t(inputs['x']!), eps: dbl('eps'));
      case 'l2pooling_dists':
        return ops.l2PoolingDists(t(inputs['x']!),
            weight: optData('weight'), sqrtEps: dbl('sqrt_eps'));
      default:
        throw ArgumentError('未知 op: $op');
    }
  }

  group('nn ops golden 对拍（torch 生成）', () {
    setUpAll(() {
      reader = NnwReader.open('$goldenDir/nn_ops_golden.nnw');
    });
    tearDownAll(() => reader.close());

    for (final c in cases) {
      test(c['name'] as String, () {
        final got = runCase(c);
        final ref = t(c['output'] as String);
        expect(got.shape, ref.shape, reason: '${c['name']} 输出形状');
        final diff = maxAbsDiff(got.data, ref.data);
        // fp32 累加顺序差异给 2e-5；gelu/erf 相关收紧到 1e-6。
        final tol = c['op'] == 'gelu' ? 1e-6 : 2e-5;
        expect(diff, lessThanOrEqualTo(tol),
            reason: '${c['name']} max|diff|=$diff');
      });
    }
  });

  group('sgemm 自洽', () {
    final rng = math.Random(42);
    Float32List randMat(int rows, int cols) => Float32List.fromList(
        [for (var i = 0; i < rows * cols; i++) rng.nextDouble() * 4 - 2]);

    /// 朴素三重循环参考（double 累加）。
    Float32List naiveGemm(Float32List a, Float32List b, int m, int n, int k,
        {bool transA = false, bool transB = false}) {
      final c = Float32List(m * n);
      for (var i = 0; i < m; i++) {
        for (var j = 0; j < n; j++) {
          var sum = 0.0;
          for (var kk = 0; kk < k; kk++) {
            final av = transA ? a[kk * m + i] : a[i * k + kk];
            final bv = transB ? b[j * k + kk] : b[kk * n + j];
            sum += av * bv;
          }
          c[i * n + j] = sum;
        }
      }
      return c;
    }

    for (final (transA, transB) in [
      (false, false),
      (false, true),
      (true, false),
      (true, true),
    ]) {
      test('transA=$transA transB=$transB 与朴素三重循环一致', () {
        const m = 37, n = 53, k = 29;
        final a = randMat(transA ? k : m, transA ? m : k);
        final b = randMat(transB ? n : k, transB ? k : n);
        final got = Float32List(m * n);
        sgemm(a, b, got, m, n, k, transA: transA, transB: transB);
        final ref = naiveGemm(a, b, m, n, k, transA: transA, transB: transB);
        expect(maxAbsDiff(got, ref), lessThanOrEqualTo(1e-4));
      });
    }

    test('alpha/beta 语义', () {
      const m = 8, n = 6, k = 5;
      final a = randMat(m, k);
      final b = randMat(k, n);
      final c0 = randMat(m, n);
      final got = Float32List.fromList(c0);
      sgemm(a, b, got, m, n, k, alpha: 2.0, beta: 3.0);
      final ref = naiveGemm(a, b, m, n, k);
      for (var i = 0; i < m * n; i++) {
        expect(got[i], closeTo(2.0 * ref[i] + 3.0 * c0[i], 1e-4));
      }
    });
  });

  group('NnPool 并行一致性', () {
    test('parallelGemm 与单线程位级一致', () async {
      final pool = NnPool();
      await pool.start(4);
      try {
        final rng = math.Random(7);
        const m = 100, n = 96, k = 48;
        final a = Float32List.fromList(
            [for (var i = 0; i < m * k; i++) rng.nextDouble() * 4 - 2]);
        final b = Float32List.fromList(
            [for (var i = 0; i < k * n; i++) rng.nextDouble() * 4 - 2]);
        final single = Float32List(m * n);
        sgemm(a, b, single, m, n, k);
        final par = await pool.parallelGemm(a, b, m, n, k);
        expect(countBitDiff(par, single), 0);

        // transB 路径也位级一致。
        final bt = Float32List.fromList(
            [for (var i = 0; i < n * k; i++) rng.nextDouble() * 4 - 2]);
        final singleT = Float32List(m * n);
        sgemm(a, bt, singleT, m, n, k, transB: true);
        final parT = await pool.parallelGemm(a, bt, m, n, k, transB: true);
        expect(countBitDiff(parT, singleT), 0);
      } finally {
        pool.dispose();
      }
    });

    test('parallelConv2d 与单线程位级一致（普通/depthwise）', () async {
      reader = NnwReader.open('$goldenDir/nn_ops_golden.nnw');
      addTearDown(reader.close);
      final pool = NnPool();
      await pool.start(4);
      try {
        // 普通 conv：3x3/s1/p1，cout=7 不能整除 4 块，验证不均匀切分。
        final x = t('conv2d_3x3_s1_p1.x');
        final w = t('conv2d_3x3_s1_p1.weight');
        final bias = t('conv2d_3x3_s1_p1.bias').data;
        final single = ops.conv2d(x, w, bias: bias, padH: 1, padW: 1);
        final par = await pool.parallelConv2d(x, w,
            bias: bias, padH: 1, padW: 1);
        expect(par.shape, single.shape);
        expect(countBitDiff(par.data, single.data), 0);

        // depthwise：groups=cin=4。
        final dx = t('conv2d_dw_3x3_s2_p1.x');
        final dw = t('conv2d_dw_3x3_s2_p1.weight');
        final db = t('conv2d_dw_3x3_s2_p1.bias').data;
        final dSingle = ops.conv2d(dx, dw,
            bias: db, strideH: 2, strideW: 2, padH: 1, padW: 1, groups: 4);
        final dPar = await pool.parallelConv2d(dx, dw,
            bias: db, strideH: 2, strideW: 2, padH: 1, padW: 1, groups: 4);
        expect(dPar.shape, dSingle.shape);
        expect(countBitDiff(dPar.data, dSingle.data), 0);
      } finally {
        pool.dispose();
      }
    });
  });
}
