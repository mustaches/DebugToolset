// FID/KID 进程内 Dart 实现（metrics/inception_dart.dart、
// metrics/fid_kid_dart.dart、nn/eig.dart）的测试：
//
// 1. eig 黄金值对拍：test/golden/eig_golden.json（tools/iqa/
//    dump_golden.py 生成，numpy.linalg.eigvals），另加解析解 sanity。
// 2. FidAccumulator/KID 自洽性（小维度随机特征，无需权重）。
// 3. Inception 特征对拍：test/golden/inception_feats_golden.{nnw,json}
//    （tools/iqa/dump_inception_feats.py 生成，iqa_bridge 口径），
//    余弦相似度 >0.9999、L2 相对误差 <1e-3；同步与 patch 并行位级一致。
// 4. FID/KID 端到端对拍：eval_set 5 对图，Python 基线走 iqa_bridge
//    --serve（add×10 + score，同 test/isp_pyiqa_test.dart 的桥接用法）。
//    FID 相对误差 ≤1e-2；KID 抽样序列与 torch randperm 不同，只比数量级。
//
// 权重（tools/iqa/weights/inception_v3_fid.nnw）、黄金文件或
// scratch/eval_venv Python 环境缺失时对应分组自动跳过。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/fid_kid_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/metrics/inception_dart.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/eig.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/nn/nnw_reader.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pyiqa_worker.dart';

void main() {
  const goldenDir = 'test/golden';
  const evalDir = 'scratch/eval_set';

  bool eigGoldenExist() => File('$goldenDir/eig_golden.json').existsSync();

  bool inceptionAssetsExist() =>
      File(inceptionV3WeightsPath).existsSync() &&
      File('$goldenDir/inception_feats_golden.nnw').existsSync() &&
      File('$goldenDir/inception_feats_golden.json').existsSync() &&
      File('$evalDir/ref_0.png').existsSync() &&
      File('$evalDir/test_0.png').existsSync();

  bool evalSetExist() =>
      File(inceptionV3WeightsPath).existsSync() &&
      [for (var i = 0; i < 5; i++) ...['ref_$i.png', 'test_$i.png']]
          .every((f) => File('$evalDir/$f').existsSync());

  /// PNG → RGBA8888。
  Uint8List loadRgba(String path) {
    final image = img.decodePng(File(path).readAsBytesSync())!;
    final w = image.width, h = image.height;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        final i = (y * w + x) * 4;
        rgba[i] = p.r.toInt();
        rgba[i + 1] = p.g.toInt();
        rgba[i + 2] = p.b.toInt();
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  group('eig 特征值求解器', () {
    test('解析解 sanity（2×2 实/复特征值、3×3 上三角）', () {
      var ev = eigvalsReal(Float64List.fromList([0, 1, -2, -3]), 2);
      expect(ev.re, unorderedEquals([-1.0, -2.0]));
      expect(ev.im, [0.0, 0.0]);
      ev = eigvalsReal(Float64List.fromList([0, -1, 1, 0]), 2);
      expect(ev.re, [0.0, 0.0]);
      expect(ev.im, unorderedEquals([1.0, -1.0]));
      ev = eigvalsReal(
          Float64List.fromList([1, 2, 3, 0, 4, 5, 0, 0, 6]), 3);
      expect(ev.re, unorderedEquals([1.0, 4.0, 6.0]));
      expect(ev.im, [0.0, 0.0, 0.0]);
    });

    test('与 numpy.linalg.eigvals 黄金值对拍', () {
      if (!eigGoldenExist()) return;
      final cases = (jsonDecode(
                  File('$goldenDir/eig_golden.json').readAsStringSync())
              as Map<String, dynamic>)['cases'] as List;
      expect(cases, hasLength(5));
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final n = c['n'] as int;
        final x = Float64List.fromList((c['x'] as List)
            .expand((row) => (row as List).cast<num>())
            .map((v) => v.toDouble())
            .toList());
        final golden = List.generate(
            n,
            (i) => (
                  (c['eig_re'] as List)[i] as double,
                  (c['eig_im'] as List)[i] as double
                ));
        var scale = 1.0;
        for (final (re, im) in golden) {
          scale = math.max(scale, math.sqrt(re * re + im * im));
        }
        final ev = eigvalsReal(x, n);
        final got = List.generate(n, (i) => (ev.re[i], ev.im[i]));
        int cmp((double, double) a, (double, double) b) {
          final d = a.$1.compareTo(b.$1);
          return d != 0 ? d : a.$2.compareTo(b.$2);
        }

        got.sort(cmp);
        golden.sort(cmp);
        for (var i = 0; i < n; i++) {
          expect((got[i].$1 - golden[i].$1).abs(), lessThan(1e-9 * scale),
              reason: '${c['name']} λ$i 实部');
          expect((got[i].$2 - golden[i].$2).abs(), lessThan(1e-9 * scale),
              reason: '${c['name']} λ$i 虚部');
        }
      }
    });
  });

  group('FidAccumulator / KID 自洽（无需权重）', () {
    /// 固定种子随机特征 [n,dim]。
    Float32List randFeats(int n, int dim, int seed, {double offset = 0}) {
      final rng = math.Random(seed);
      final out = Float32List(n * dim);
      for (var i = 0; i < out.length; i++) {
        out[i] = rng.nextDouble() + offset;
      }
      return out;
    }

    test('同分布 FID≈0，偏移分布 FID 显著更大（小维度）', () {
      const dim = 32;
      final x = randFeats(50, dim, 1);
      final y = randFeats(50, dim, 2, offset: 0.5);
      final fidSame = fidScoreFromFeatures(x, 50, x, 50, dim: dim);
      expect(fidSame.abs(), lessThan(1e-6));
      final fidDiff = fidScoreFromFeatures(x, 50, y, 50, dim: dim);
      expect(fidDiff, greaterThan(1.0));
      // ignore: avoid_print
      print('小维度自洽：fid(x,x)=$fidSame fid(x,y)=$fidDiff');
    });

    test('FID 低秩快路径与 2048² 旧路径一致（噪声底内）：对称/不对称样本数',
        () {
      double slowPath(
          Float32List x, int nx, Float32List y, int ny, int dim) {
        final accX = FidAccumulator(dim)..addBatch(x, nx);
        final accY = FidAccumulator(dim)..addBatch(y, ny);
        return fidCompute(accX, accY);
      }

      // 快路径触发条件 min(n) < dim 意味着 σ1σ2 恒秩亏（rank ≤ n−1），
      // 旧路径的 dim−rank 个真零特征值经 Re(√λ) 把 QR 残差
      // （~1e-16·‖σ1σ2‖）放大为 ~1e-8/个 的系统性噪声底（dim=64 时实测
      // 总差 ~1e-7），故断言阈值取 1e-6；两路径数学上严格等价，差异即
      // 旧路径的零特征值数值残差。
      const tol = 1e-6;
      const dim = 64;
      // 对称 n1 = n2 = 12（min(n) < dim → fidScoreFromFeatures 走快路径）。
      final x = randFeats(12, dim, 42);
      final y = randFeats(12, dim, 43, offset: 0.3);
      final fastSym = fidScoreFromFeatures(x, 12, y, 12, dim: dim);
      final slowSym = slowPath(x, 12, y, 12, dim);
      expect((fastSym - slowSym).abs(), lessThan(tol),
          reason: '对称 n=12：fast=$fastSym slow=$slowSym');
      // 不对称 n1=12 vs n2=20（小样本侧在后）。
      final z = randFeats(20, dim, 44, offset: 0.1);
      final fastAsym = fidScoreFromFeatures(x, 12, z, 20, dim: dim);
      final slowAsym = slowPath(x, 12, z, 20, dim);
      expect((fastAsym - slowAsym).abs(), lessThan(tol),
          reason: '不对称 12 vs 20：fast=$fastAsym slow=$slowAsym');
      // 反向不对称（小样本侧在前）。
      final fastAsym2 = fidScoreFromFeatures(z, 20, x, 12, dim: dim);
      final slowAsym2 = slowPath(z, 20, x, 12, dim);
      expect((fastAsym2 - slowAsym2).abs(), lessThan(tol),
          reason: '不对称 20 vs 12：fast=$fastAsym2 slow=$slowAsym2');
      // ignore: avoid_print
      print('FID 快路径 vs 旧路径：sym 差 '
          '${(fastSym - slowSym).abs()} asym 差 ${(fastAsym - slowAsym).abs()} '
          'asym2 差 ${(fastAsym2 - slowAsym2).abs()}');
    });

    test('样本不足（任一侧 <2）抛错', () {
      const dim = 8;
      final x = randFeats(1, dim, 1);
      expect(() => fidScoreFromFeatures(x, 1, x, 1, dim: dim),
          throwsStateError);
      final two = randFeats(2, fidFeatureDim, 3);
      expect(() => kidCompute(two, 1, two, 1), throwsStateError);
      expect(() => kidCompute(two, 1, two, 2), throwsStateError);
    });

    test('KID：同分布接近 0，偏移分布显著为正', () {
      final x = randFeats(40, fidFeatureDim, 4);
      final y = randFeats(40, fidFeatureDim, 5, offset: 2.0);
      final kidSame = kidCompute(x, 40, x, 40);
      final kidDiff = kidCompute(x, 40, y, 40);
      // 同分布无偏 MMD 估计围绕 0 小幅波动；偏移分布应大得多。
      expect(kidSame.abs(), lessThan(0.05));
      expect(kidDiff, greaterThan(kidSame.abs() * 10 + 0.1));
      // ignore: avoid_print
      print('KID 自洽：kid(x,x)=$kidSame kid(x,y)=$kidDiff');
    });
  });

  group('Inception 特征对拍（需权重与黄金值）', () {
    test('eval_set ref_0/test_0 patch 特征：余弦 >0.9999，relL2 <1e-3',
        () async {
      if (!inceptionAssetsExist()) return;
      final meta = jsonDecode(
              File('$goldenDir/inception_feats_golden.json')
                  .readAsStringSync())
          as Map<String, dynamic>;
      final reader =
          NnwReader.open('$goldenDir/inception_feats_golden.nnw');
      addTearDown(reader.close);

      for (final key in ['ref_0.feats', 'test_0.feats']) {
        final info = (meta['images'] as Map<String, dynamic>)[key]
            as Map<String, dynamic>;
        final w = info['width'] as int, h = info['height'] as int;
        final golden = reader.readTensor(key); // [n,2048]
        final n = golden.shape[0];
        expect(n, info['patches']);
        final rgba = loadRgba('$evalDir/${info['file']}');

        // 同步单线程（兼测单 patch 耗时）。
        final net = InceptionV3Dart.load(inceptionV3WeightsPath);
        final sw = Stopwatch()..start();
        final syncFeats = net.inceptionPatchFeatures(rgba, w, h);
        sw.stop();
        // patch 间并行：与同步版位级一致。
        final parFeats =
            await inceptionPatchFeaturesParallel(rgba, w, h, workers: 4);
        expect(parFeats.length, syncFeats.length);
        for (var i = 0; i < syncFeats.length; i++) {
          expect(parFeats[i], syncFeats[i], reason: '$key 并行/同步位级一致');
        }

        var worstCos = 1.0, worstL2 = 0.0;
        for (var p = 0; p < n; p++) {
          var dot = 0.0, na = 0.0, nb = 0.0, d2 = 0.0;
          final off = p * inceptionFeatureDim;
          for (var i = 0; i < inceptionFeatureDim; i++) {
            final a = syncFeats[off + i];
            final b = golden.data[off + i];
            dot += a * b;
            na += a * a;
            nb += b * b;
            d2 += (a - b) * (a - b);
          }
          final cos = dot / math.sqrt(na * nb);
          final relL2 = math.sqrt(d2) / math.sqrt(nb);
          worstCos = math.min(worstCos, cos);
          worstL2 = math.max(worstL2, relL2);
        }
        // ignore: avoid_print
        print('Inception $key: ${w}x$h $n patch，单 patch 同步耗时 '
            '${sw.elapsed.inMilliseconds ~/ n}ms，worstCos=$worstCos '
            'worstRelL2=$worstL2');
        expect(worstCos, greaterThan(0.9999), reason: key);
        expect(worstL2, lessThan(1e-3), reason: key);
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });

  group('FID/KID 端到端对拍（需 eval_venv）', () {
    test('eval_set 5 对图：FID 相对误差 ≤1e-2，KID 同量级', () async {
      if (!PyIqaWorker.available || !evalSetExist()) return;

      // Python 基线：桥接 --serve，add×10 + score。
      Future<double> pyScore(String metric) async {
        final worker = PyIqaWorker.forMetric(metric);
        await worker.distReset();
        for (var i = 0; i < 5; i++) {
          await worker.distAdd('ref', '$evalDir/ref_$i.png');
          await worker.distAdd('test', '$evalDir/test_$i.png');
        }
        final s = await worker.distScore();
        expect(s, isNotNull, reason: 'Python $metric 应出分');
        expect(s!.$2, 10, reason: '256×192 → 每帧 2 patch × 5 帧');
        expect(s.$3, 10);
        return s.$1;
      }

      final pyFid = await pyScore('fid');
      final pyKid = await pyScore('kid');

      // Dart 侧：逐帧 patch 特征（并行），驻留特征供 FID/KID 出分。
      final refFeats = <Float32List>[];
      final testFeats = <Float32List>[];
      final sw = Stopwatch()..start();
      for (var i = 0; i < 5; i++) {
        final rgbaR = loadRgba('$evalDir/ref_$i.png');
        final rgbaT = loadRgba('$evalDir/test_$i.png');
        final fr = await inceptionPatchFeaturesParallel(rgbaR, 256, 192);
        final ft = await inceptionPatchFeaturesParallel(rgbaT, 256, 192);
        refFeats.add(fr);
        testFeats.add(ft);
      }
      // ignore: avoid_print
      print('Dart 特征提取（10 帧 × 2 patch）耗时 ${sw.elapsed}');
      final refAll = Float32List(10 * fidFeatureDim);
      final testAll = Float32List(10 * fidFeatureDim);
      for (var i = 0; i < 5; i++) {
        refAll.setRange(i * 2 * fidFeatureDim, (i + 1) * 2 * fidFeatureDim,
            refFeats[i]);
        testAll.setRange(i * 2 * fidFeatureDim, (i + 1) * 2 * fidFeatureDim,
            testFeats[i]);
      }

      sw.reset();
      // n=10 < 2048 → 低秩快路径（与 2048² 旧路径 <1e-9 一致，见上组
      // 自洽用例），出分从 ~40s 降到亚秒级。
      final dartFid = fidScoreFromFeatures(refAll, 10, testAll, 10);
      // ignore: avoid_print
      print('Dart FID 出分（低秩快路径）耗时 ${sw.elapsed}');
      sw.reset();
      final dartKid = kidCompute(refAll, 10, testAll, 10);
      // ignore: avoid_print
      print('Dart KID 出分耗时 ${sw.elapsed}');

      // ignore: avoid_print
      print('FID: dart=$dartFid python=$pyFid '
          'relErr=${(dartFid - pyFid).abs() / pyFid.abs()}');
      // ignore: avoid_print
      print('KID: dart=$dartKid python=$pyKid');
      expect((dartFid - pyFid).abs() / pyFid.abs(), lessThanOrEqualTo(1e-2),
          reason: 'FID 相对误差');
      // KID 抽样随机性（torch randperm vs 固定种子 Fisher–Yates）：
      // 只比数量级。
      if (pyKid.abs() > 1e-9) {
        expect(dartKid / pyKid, inInclusiveRange(0.1, 10.0),
            reason: 'KID 同量级（dart=$dartKid python=$pyKid）');
      } else {
        expect(dartKid.abs(), lessThan(0.01),
            reason: 'Python KID≈0 时 Dart 也应接近 0');
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  });
}
