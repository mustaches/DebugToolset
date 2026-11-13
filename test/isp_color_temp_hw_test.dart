import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/color_temp.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/color_temp_hw.dart';
import 'package:flutter_test/flutter_test.dart';

/// 色温 IP 运行期控制/测量的定点参考（与生成 Verilog 逐位一致的口径）。
void main() {
  group('color_temp_hw 定点参考', () {
    final tables = CtWhiteTables();

    test('白点/倒数表规模与取值范围', () {
      expect(tables.lowerR.length, kCtSegCount);
      expect(tables.upperB.length, kCtSegCount);
      expect(tables.recip.length, kCtRecipCount);
      // Q16 白点最大约 2.0（1800K 的 r 通道），表项须装进 RTL 的 19 位。
      expect(tables.lowerR.every((v) => v > 0 && v < (1 << 19)), isTrue);
      expect(tables.recip.every((v) => v > 0 && v < (1 << 24)), isTrue);
    });

    test('目标==参考时增益恒等（≤1 LSB）', () {
      // 1900K 以下 b 通道白点为 0（Tanner Helland 式在 t<=19 恒 0），
      // 0/0 无意义；FP64 那里给 NaN，硬件给 0——从 2000K 起断言。
      for (var k = 2000; k <= 12000; k += 500) {
        final g = ctGainsQ14(k, k, tables: tables);
        expect((g[0] - 16384).abs(), lessThanOrEqualTo(1), reason: 'K=$k R');
        expect(g[1], 16384);
        expect((g[2] - 16384).abs(), lessThanOrEqualTo(1), reason: 'K=$k B');
      }
    });

    test('目标更高偏冷：B 增 R 减；与 FP64 增益偏差 ≤2 LSB（常规区间）', () {
      final warm = ctGainsQ14(4000, 6500, tables: tables);
      final cool = ctGainsQ14(9000, 6500, tables: tables);
      expect(cool[2], greaterThan(warm[2]), reason: '高色温 B 增益更大');
      expect(cool[0], lessThan(warm[0]), reason: '高色温 R 增益更小');
      var worst = 0.0;
      for (var t = 2000; t <= 12000; t += 250) {
        for (var r = 4000; r <= 8000; r += 250) {
          final fp = colorTempGains(t.toDouble(), r);
          final fx = ctGainsQ14(t, r, tables: tables);
          for (final c in [0, 2]) {
            if (!fp[c].isFinite || fp[c] > 3.5 || fp[c] < 0.25) continue;
            final d = (fx[c] / 16384.0 - fp[c]).abs() * 255;
            if (d > worst) worst = d;
          }
        }
      }
      expect(worst, lessThanOrEqualTo(2.5),
          reason: '与 FP64 口径最大偏差 ${worst.toStringAsFixed(2)} LSB');
    });

    test('测量：灰阶中性色落在 D65 邻域，暖/冷方向正确', () {
      const n = 4096;
      final gray = ctMeasureCct(128 * n, 128 * n, 128 * n);
      expect(gray, isNotNull);
      expect((gray! - 6500).abs(), lessThan(50), reason: '中性灰约 6500K');
      final warm = ctMeasureCct(200 * n, 150 * n, 100 * n)!;
      final cool = ctMeasureCct(100 * n, 150 * n, 200 * n)!;
      expect(warm, lessThan(gray), reason: '偏红偏暖');
      expect(cool, greaterThan(gray), reason: '偏蓝偏冷');
      expect(ctMeasureCct(0, 0, 0), isNull, reason: '全黑无法估计');
    });

    test('测量：与 FP64 McCamy 同口径（≤5 K）', () {
      const n = 1024;
      var worst = 0;
      for (var k = 2500; k <= 11000; k += 500) {
        final wp = cctToWhitePoint(k);
        final g = 200.0;
        final r = (wp[0] * g).clamp(0.0, 255.0).round();
        final b = (wp[2] * g).clamp(0.0, 255.0).round();
        final fixed = ctMeasureCct(r * n, 200 * n, b * n);
        // FP64 口径：同一条平均色（整数 RGB）走 measureCctFromRgba。
        final rgba = List<int>.generate(n * 4, (i) {
          switch (i % 4) {
            case 0:
              return r;
            case 1:
              return 200;
            case 2:
              return b;
            default:
              return 255;
          }
        });
        final fp = measureCctFromRgba(
          Uint8List.fromList(rgba),
          n,
          1,
        );
        expect(fixed, isNotNull, reason: 'K=$k');
        expect(fp, isNotNull, reason: 'K=$k');
        final d = (fixed! - fp!).abs();
        if (d > worst) worst = d;
      }
      expect(worst, lessThanOrEqualTo(5),
          reason: '定点与 FP64 最大偏差 ${worst}K');
    });
  });
}
