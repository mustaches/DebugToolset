import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BayerPattern', () {
    test('fromName parses all four patterns', () {
      expect(BayerPattern.fromName('RGGB'), BayerPattern.rggb);
      expect(BayerPattern.fromName('BGGR'), BayerPattern.bggr);
      expect(BayerPattern.fromName('GRBG'), BayerPattern.grbg);
      expect(BayerPattern.fromName('GBRG'), BayerPattern.gbrg);
      expect(BayerPattern.fromName('rggb'), BayerPattern.rggb);
    });

    test('fromName rejects garbage', () {
      expect(() => BayerPattern.fromName('XXXX'), throwsArgumentError);
      expect(() => BayerPattern.fromName(''), throwsArgumentError);
      expect(() => BayerPattern.fromName('RGB'), throwsArgumentError);
    });

    test('colorAt of rggb matches the 2x2 tile', () {
      const p = BayerPattern.rggb;
      expect(p.colorAt(0, 0), 0); // R
      expect(p.colorAt(1, 0), 1); // G
      expect(p.colorAt(0, 1), 1); // G
      expect(p.colorAt(1, 1), 2); // B
      // tiling repeats
      expect(p.colorAt(2, 2), 0);
      expect(p.colorAt(3, 3), 2);
    });
  });

  group('unpackBayer', () {
    test('unpackedLsb 10-bit little-endian decodes known words', () {
      // 4x2 = 8 pixels, values chosen to exercise masking (incl. >10 bits).
      final values = [0, 1, 512, 1023, 100, 801, 3, 0xFFFF];
      final bytes = Uint8List(16);
      for (var i = 0; i < values.length; i++) {
        bytes[i * 2] = values[i] & 0xFF;
        bytes[i * 2 + 1] = (values[i] >> 8) & 0xFF;
      }
      final out = unpackBayer(bytes,
          width: 4,
          height: 2,
          bitDepth: 10,
          packing: BayerPacking.unpackedLsb);
      expect(out.length, 8);
      for (var i = 0; i < values.length; i++) {
        expect(out[i], values[i] & 1023, reason: 'pixel $i');
      }
    });

    test('unpackedLsb big-endian and byteOffset work', () {
      final bytes = Uint8List.fromList([
        0xAA, 0xBB, // skipped by offset
        0x01, 0x00, // BE word 0x0100 -> 256
        0x03, 0xFF, // BE word 0x03FF -> 1023
      ]);
      final out = unpackBayer(bytes,
          width: 2,
          height: 1,
          bitDepth: 10,
          packing: BayerPacking.unpackedLsb,
          littleEndian: false,
          byteOffset: 2);
      expect(out, [256, 1023]);
    });

    test('unpackedMsb shifts left-aligned data down', () {
      // 10-bit MSB-aligned: value 512 stored as 512 << 6 = 0x8000.
      final bytes = Uint8List.fromList([0x00, 0x80, 0xC0, 0xFF]);
      final out = unpackBayer(bytes,
          width: 2, height: 1, bitDepth: 10, packing: BayerPacking.unpackedMsb);
      expect(out, [512, 1023]);
    });

    test('8-bit path uses one byte per pixel', () {
      final bytes = Uint8List.fromList([0, 128, 255, 7]);
      final out = unpackBayer(bytes,
          width: 2,
          height: 2,
          bitDepth: 8,
          packing: BayerPacking.unpackedLsb);
      expect(out, [0, 128, 255, 7]);
    });

    test('too-small buffer throws ArgumentError', () {
      final bytes = Uint8List(15); // need 16 for 4x2 10-bit unpacked
      expect(
          () => unpackBayer(bytes,
              width: 4,
              height: 2,
              bitDepth: 10,
              packing: BayerPacking.unpackedLsb),
          throwsArgumentError);
      expect(
          () => unpackBayer(Uint8List(16),
              width: 4,
              height: 2,
              bitDepth: 10,
              packing: BayerPacking.unpackedLsb,
              byteOffset: 1),
          throwsArgumentError);
    });

    test('mipi 10-bit roundtrip of 4 known pixels', () {
      final px = [0, 1, 512, 1023];
      // Standard MIPI CSI-2 RAW10: 4 MSB bytes, then 1 byte of 2-bit LSBs.
      final bytes = Uint8List(5);
      for (var i = 0; i < 4; i++) {
        bytes[i] = (px[i] >> 2) & 0xFF;
        bytes[4] |= (px[i] & 0x3) << (2 * i);
      }
      final out = unpackBayer(bytes,
          width: 4, height: 1, bitDepth: 10, packing: BayerPacking.mipi);
      expect(out, px);
    });

    test('mipi 12-bit roundtrip of 2 known pixels', () {
      final px = [0xABC, 0x123];
      final bytes = Uint8List.fromList([
        (px[0] >> 4) & 0xFF,
        (px[1] >> 4) & 0xFF,
        (px[0] & 0xF) | ((px[1] & 0xF) << 4),
      ]);
      final out = unpackBayer(bytes,
          width: 2, height: 1, bitDepth: 12, packing: BayerPacking.mipi);
      expect(out, px);
    });

    test('mipi with unsupported bit depth throws', () {
      expect(
          () => unpackBayer(Uint8List(16),
              width: 4, height: 2, bitDepth: 8, packing: BayerPacking.mipi),
          throwsArgumentError);
    });
  });

  test('bayerMaxValue', () {
    expect(bayerMaxValue(8), 255);
    expect(bayerMaxValue(10), 1023);
    expect(bayerMaxValue(12), 4095);
  });

  test('frameByteSize matches the real 4K 10-bit file', () {
    expect(
        frameByteSize(
            width: 3840,
            height: 2160,
            bitDepth: 10,
            packing: BayerPacking.unpackedLsb),
        3840 * 2160 * 2);
    expect(
        frameByteSize(
            width: 3840,
            height: 2160,
            bitDepth: 10,
            packing: BayerPacking.mipi),
        3840 * 2160 * 5 ~/ 4);
  });

  group('applyBlackLevel', () {
    test('subtracts per phase and clamps at 0', () {
      // 4x2 rggb:
      // row0: R G R G
      // row1: G B G B
      final bayer = Uint16List.fromList([
        810, 820, 805, 5, // R=810, Gr=820, R=805, Gr=5
        815, 830, 10, 840, // Gb=815, B=830, Gb=10, B=840
      ]);
      applyBlackLevel(bayer,
          width: 4, height: 2, pattern: BayerPattern.rggb,
          r: 800, gr: 801, gb: 802, b: 803);
      expect(bayer[0], 10); // R: 810-800
      expect(bayer[1], 19); // Gr: 820-801
      expect(bayer[2], 5); // R: 805-800
      expect(bayer[3], 0); // Gr: 5-801 -> clamp 0
      expect(bayer[4], 13); // Gb: 815-802
      expect(bayer[5], 27); // B: 830-803
      expect(bayer[6], 0); // Gb: 10-802 -> clamp 0
      expect(bayer[7], 37); // B: 840-803
    });
  });

  group('demosaicBilinear', () {
    test('uniform color field is reproduced at interior pixels', () {
      const w = 8, h = 8;
      final bayer = Uint16List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          switch (BayerPattern.rggb.colorAt(x, y)) {
            case 0:
              bayer[y * w + x] = 1000;
            case 1:
              bayer[y * w + x] = 500;
            case 2:
              bayer[y * w + x] = 100;
          }
        }
      }
      final rgb = demosaicBilinear(bayer,
          width: w, height: h, pattern: BayerPattern.rggb);
      expect(rgb.length, w * h * 3);
      // Interior pixels: every channel average of a uniform field is exact.
      for (var y = 2; y < h - 2; y++) {
        for (var x = 2; x < w - 2; x++) {
          final i = (y * w + x) * 3;
          expect((rgb[i] - 1000).abs(), lessThanOrEqualTo(1),
              reason: 'R at ($x,$y)');
          expect((rgb[i + 1] - 500).abs(), lessThanOrEqualTo(1),
              reason: 'G at ($x,$y)');
          expect((rgb[i + 2] - 100).abs(), lessThanOrEqualTo(1),
              reason: 'B at ($x,$y)');
        }
      }
    });

    test('2x2 minimal image does not crash and keeps own channels', () {
      final bayer = Uint16List.fromList([10, 20, 30, 40]);
      final rgb = demosaicBilinear(bayer,
          width: 2, height: 2, pattern: BayerPattern.rggb);
      expect(rgb.length, 12);
      expect(rgb[0], 10); // R at (0,0)
      expect(rgb[4], 20); // G at (1,0)
      expect(rgb[7], 30); // G at (0,1)
      expect(rgb[11], 40); // B at (1,1)
      // B at (0,0): only diagonal neighbor is (1,1)=40.
      expect(rgb[2], 40);
      // R at (1,1): only diagonal neighbor is (0,0)=10.
      expect(rgb[9], 10);
    });
  });

  test('autoWhiteBalanceGains equalizes means to green', () {
    // Mean R is twice mean G, mean B is half mean G.
    final rgb = Uint16List(256 * 3);
    for (var p = 0; p < 256; p++) {
      rgb[p * 3] = 400; // R
      rgb[p * 3 + 1] = 200; // G
      rgb[p * 3 + 2] = 100; // B
    }
    final (rGain, bGain) = autoWhiteBalanceGains(rgb);
    expect(rGain, closeTo(0.5, 1e-9));
    expect(bGain, closeTo(2.0, 1e-9));
  });

  test('applyWhiteBalance scales and clamps', () {
    final rgb = Uint16List.fromList([400, 200, 100, 900, 200, 100]);
    applyWhiteBalance(rgb, rGain: 0.5, bGain: 2.0, maxValue: 1023);
    expect(rgb, [200, 200, 200, 450, 200, 200]);
    applyWhiteBalance(rgb, rGain: 10.0, bGain: 0.0, maxValue: 1023);
    expect(rgb[0], 1023); // clamped high
    expect(rgb[2], 0); // clamped low
  });

  group('applyCcm', () {
    test('identity leaves data unchanged', () {
      final rgb = Uint16List.fromList([10, 20, 30, 1000, 500, 100]);
      final before = Uint16List.fromList(rgb);
      applyCcm(rgb,
          matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1], maxValue: 1023);
      expect(rgb, before);
    });

    test('swap matrix swaps R and B channels', () {
      final rgb = Uint16List.fromList([10, 20, 30]);
      applyCcm(rgb,
          matrix: [0, 0, 1, 0, 1, 0, 1, 0, 0], maxValue: 1023);
      expect(rgb, [30, 20, 10]);
    });

    test('rejects non-9-element matrix and clamps output', () {
      final rgb = Uint16List.fromList([20, 20, 30]);
      expect(() => applyCcm(rgb, matrix: [1, 0, 0], maxValue: 1023),
          throwsArgumentError);
      applyCcm(rgb, matrix: [100, 0, 0, 0, 1, 0, 0, 0, -1], maxValue: 1023);
      expect(rgb, [1023, 20, 0]); // 20*100=2000 clamps high; -30 clamps low
    });
  });

  group('tonemapToRgba', () {
    test('gamma 1 maps 0 -> 0 and max -> 255 with alpha 255', () {
      final rgb = Uint16List.fromList([0, 1023, 512]);
      final out = tonemapToRgba(rgb, maxValue: 1023, gamma: 1.0);
      expect(out.length, 4);
      expect(out[0], 0);
      expect(out[1], 255);
      expect(out[2], 128); // 512/1023*255 ~ 127.7 -> 128
      expect(out[3], 255);
    });

    test('LUT output is monotonic for a gradient', () {
      const n = 256;
      final rgb = Uint16List(n * 3);
      for (var p = 0; p < n; p++) {
        final v = p * 4; // 0..1020
        rgb[p * 3] = v;
        rgb[p * 3 + 1] = v;
        rgb[p * 3 + 2] = v;
      }
      final out = tonemapToRgba(rgb, maxValue: 1023, gamma: 2.2);
      var prev = -1;
      for (var p = 0; p < n; p++) {
        expect(out[p * 4], greaterThanOrEqualTo(prev));
        prev = out[p * 4];
        expect(out[p * 4 + 3], 255);
      }
      // gamma 2.2 brightens mid-tones
      expect(out[128 * 4], greaterThan(128));
    });

    test('brightness and contrast are applied', () {
      final dark = Uint16List.fromList([100, 100, 100]);
      final plain = tonemapToRgba(dark, maxValue: 1023, gamma: 1.0);
      final bright =
          tonemapToRgba(dark, maxValue: 1023, gamma: 1.0, brightness: 0.3);
      expect(bright[0], greaterThan(plain[0]));
      final mid = Uint16List.fromList([512, 512, 512]);
      final c2 = tonemapToRgba(mid, maxValue: 1023, gamma: 1.0, contrast: 2.0);
      // (0.5005-0.5)*2+0.5 ~ 0.501 -> ~128; contrast around 0.5 leaves mid ~same
      expect((c2[0] - 128).abs(), lessThanOrEqualTo(2));
    });
  });

  group('monoToRgb', () {
    test('单通道复制为三通道', () {
      final out = monoToRgb(Uint16List.fromList([1, 2, 65535]));
      expect(out, [1, 1, 1, 2, 2, 2, 65535, 65535, 65535]);
    });
  });

  /// 按 2x2 相位填充 4x4 常量马赛克：[a,b / c,d]。
  Uint16List mosaic2x2(int a, int b, int c, int d) {
    final m = Uint16List(16);
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        m[y * 4 + x] = [a, b, c, d][((y & 1) << 1) | (x & 1)];
      }
    }
    return m;
  }

  group('非 Bayer CFA demosaic', () {
    test('RCCB：G ≈ C − (R+B)/2', () {
      // R=100, C=200, B=50 → G = 200 − 75 = 125
      final rgb = demosaicRccb(mosaic2x2(100, 200, 200, 50),
          width: 4, height: 4, maxValue: 1023);
      for (var i = 0; i < rgb.length; i += 3) {
        expect([rgb[i], rgb[i + 1], rgb[i + 2]], [100, 125, 50],
            reason: 'pixel ${i ~/ 3}');
      }
    });

    test('RCCG：B ≈ C − R − G', () {
      // R=100, C=200, G=60 → B = 200 − 100 − 60 = 40
      final rgb = demosaicRccb(mosaic2x2(100, 200, 200, 60),
          width: 4, height: 4, rccg: true, maxValue: 1023);
      for (var i = 0; i < rgb.length; i += 3) {
        expect([rgb[i], rgb[i + 1], rgb[i + 2]], [100, 60, 40]);
      }
    });

    test('RCCC：G = B = (C − R)/2', () {
      final rgb = demosaicRccc(mosaic2x2(100, 300, 300, 300),
          width: 4, height: 4, maxValue: 1023);
      for (var i = 0; i < rgb.length; i += 3) {
        expect([rgb[i], rgb[i + 1], rgb[i + 2]], [100, 100, 100]);
      }
    });

    test('RYYCy：G = Y − R，B = Cy − G', () {
      // R=100, Y=160 (G=60), Cy=110 (B=50)
      final rgb = demosaicRyycy(mosaic2x2(100, 160, 160, 110),
          width: 4, height: 4, maxValue: 1023);
      for (var i = 0; i < rgb.length; i += 3) {
        expect([rgb[i], rgb[i + 1], rgb[i + 2]], [100, 60, 50]);
      }
    });

    test('RGB-IR：按比例扣除 IR 分量', () {
      // 4x4 平铺：R=100, G=60, B=40, IR=20，扣除 50% → (90, 50, 30)
      final m = Uint16List(16);
      const tile = [
        100, 60, 20, 60, //
        60, 40, 60, 20, //
        20, 60, 100, 60, //
        60, 20, 60, 40, //
      ];
      m.setAll(0, tile);
      final rgb = demosaicRgbIr(m,
          width: 4, height: 4, maxValue: 1023, irSubtraction: 0.5);
      for (var i = 0; i < rgb.length; i += 3) {
        expect([rgb[i], rgb[i + 1], rgb[i + 2]], [90, 50, 30],
            reason: 'pixel ${i ~/ 3}');
      }
    });
  });

  group('YUV 转换', () {
    test('灰色像素的 U/V 位于中点', () {
      final yuv = rgbToYuv(Uint16List.fromList([128, 128, 128]),
          maxValue: 255);
      expect((yuv[0] - 128).abs(), lessThanOrEqualTo(1));
      expect((yuv[1] - 128).abs(), lessThanOrEqualTo(1));
      expect((yuv[2] - 128).abs(), lessThanOrEqualTo(1));
    });

    test('RGB→YUV→RGB 往返误差 ≤2', () {
      final src = [0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 37, 200, 90];
      final rgb = Uint16List.fromList(src);
      final back = yuvToRgb(rgbToYuv(rgb, maxValue: 255), maxValue: 255);
      for (var i = 0; i < src.length; i++) {
        expect((back[i] - src[i]).abs(), lessThanOrEqualTo(2),
            reason: 'channel $i');
      }
    });
  });

  group('HSL 转换', () {
    test('纯红：H=0，S=max，L=max/2', () {
      final hsl = rgbToHsl(Uint16List.fromList([255, 0, 0]), maxValue: 255);
      expect(hsl[0], 0);
      expect(hsl[1], 255);
      expect((hsl[2] - 128).abs(), lessThanOrEqualTo(1));
    });

    test('RGB→HSL→RGB 往返误差 ≤2', () {
      final src = [0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 37, 200, 90];
      final rgb = Uint16List.fromList(src);
      final back = hslToRgb(rgbToHsl(rgb, maxValue: 255), maxValue: 255);
      for (var i = 0; i < src.length; i++) {
        expect((back[i] - src[i]).abs(), lessThanOrEqualTo(2),
            reason: 'channel $i');
      }
    });
  });
}
