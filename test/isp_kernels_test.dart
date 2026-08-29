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

    test('8-bit unpacked uses one 16-bit word per pixel', () {
      // unpacked 固定每像素 2 字节（16 位字），8 位深同样按字读取并 LSB 对齐。
      final bytes = Uint8List.fromList([0, 0, 128, 0, 255, 0, 7, 0]);
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

  group('HSL 调整（adjustHsl）', () {
    test('恒等参数直接返回原数据（不拷贝）', () {
      final hsl = Uint16List.fromList([10, 200, 100, 0, 0, 0]);
      final out = adjustHsl(hsl, maxValue: 255);
      expect(identical(out, hsl), isTrue);
    });

    test('纯红偏移 180° 变青色', () {
      final red = rgbToHsl(Uint16List.fromList([255, 0, 0]), maxValue: 255);
      final rgb =
          hslToRgb(adjustHsl(red, maxValue: 255, hShiftDeg: 180),
              maxValue: 255);
      // 色环按 1/(maxValue+1) 量化（半步约 0.7°），通道误差放宽到 ≤4。
      expect(rgb[0], lessThanOrEqualTo(4)); // R ≈ 0
      expect((rgb[1] - 255).abs(), lessThanOrEqualTo(4)); // G ≈ max
      expect((rgb[2] - 255).abs(), lessThanOrEqualTo(4)); // B ≈ max
    });

    test('s_gain=0 时 S 通道全零，H/L 不变', () {
      final hsl = Uint16List.fromList([10, 200, 100, 0, 128, 60]);
      final out = adjustHsl(hsl, maxValue: 255, sGain: 0);
      expect(out[1], 0);
      expect(out[4], 0);
      expect(out[0], 10);
      expect(out[2], 100);
      expect(out[3], 0);
      expect(out[5], 60);
    });

    test('增益结果钳位到 maxValue 不溢出', () {
      final hsl = Uint16List.fromList([0, 200, 250]);
      final out = adjustHsl(hsl, maxValue: 255, sGain: 2, lGain: 2);
      expect(out[1], 255);
      expect(out[2], 255);
    });

    test('h_shift 负值在色环上正确环绕', () {
      // shift = round(-90/360*255) = -64；H=10 → (10-64) mod 256 = 202。
      final hsl = Uint16List.fromList([10, 128, 128]);
      final out = adjustHsl(hsl, maxValue: 255, hShiftDeg: -90);
      expect(out[0], 202);
      expect(out[1], 128);
      expect(out[2], 128);
    });
  });

  group('色饱和度/亮度调节（adjustSatBright）', () {
    test('恒等参数直接返回原数据（不拷贝）', () {
      for (final fmt in ['rgb', 'yuv', 'hsl']) {
        final data = Uint16List.fromList([10, 200, 100]);
        final out = adjustSatBright(data, format: fmt, maxValue: 255);
        expect(identical(out, data), isTrue, reason: fmt);
      }
    });

    test('非法格式抛 ArgumentError', () {
      final data = Uint16List.fromList([10, 200, 100]);
      expect(
          () => adjustSatBright(data,
              format: 'mosaic', maxValue: 255, satGain: 2),
          throwsArgumentError);
    });

    test('RGB 域：satGain=0 变为 BT.601 灰度，亮度增益再整体缩放', () {
      // 纯红 [255,0,0]：Y = 0.299*255 ≈ 76；satGain=0 → R=G=B=76；
      // brightGain=2 → 152。
      final rgb = Uint16List.fromList([255, 0, 0]);
      final out = adjustSatBright(rgb,
          format: 'rgb', maxValue: 255, satGain: 0, brightGain: 2);
      expect(out[0], 152);
      expect(out[1], 152);
      expect(out[2], 152);
    });

    test('RGB 域：satGain=1 时仅亮度增益生效', () {
      final rgb = Uint16List.fromList([100, 150, 200]);
      final out = adjustSatBright(rgb,
          format: 'rgb', maxValue: 255, brightGain: 0.5);
      expect(out[0], 50);
      expect(out[1], 75);
      expect(out[2], 100);
    });

    test('YUV 域：Y 乘亮度增益，U/V 围绕中点乘饱和度增益', () {
      // half = 127；U=187 → 127 + 60*0.5 = 157；V=67 → 127 - 60*0.5 = 97。
      final yuv = Uint16List.fromList([100, 187, 67]);
      final out = adjustSatBright(yuv,
          format: 'yuv', maxValue: 255, satGain: 0.5, brightGain: 2);
      expect(out[0], 200);
      expect(out[1], 157);
      expect(out[2], 97);
    });

    test('YUV 域：satGain=0 时 U/V 回到中性点', () {
      final yuv = Uint16List.fromList([100, 200, 30]);
      final out =
          adjustSatBright(yuv, format: 'yuv', maxValue: 255, satGain: 0);
      expect(out[0], 100);
      expect(out[1], 127);
      expect(out[2], 127);
    });

    test('HSL 域：S/L 分别乘增益，H 不变，结果钳位不溢出', () {
      final hsl = Uint16List.fromList([10, 200, 250]);
      final out = adjustSatBright(hsl,
          format: 'hsl', maxValue: 255, satGain: 2, brightGain: 2);
      expect(out[0], 10);
      expect(out[1], 255);
      expect(out[2], 255);
    });
  });

  group('亮度/对比度调节（adjustBrightContrast）', () {
    test('bright=100 且 gain=100 时恒等直通（基线任意值，不拷贝）', () {
      for (final fmt in ['rgb', 'yuv', 'hsl']) {
        final data = Uint16List.fromList([10, 200, 100]);
        final out = adjustSatBright(data, format: fmt, maxValue: 255);
        expect(identical(out, data), isTrue, reason: fmt);
        final out2 = adjustBrightContrast(data,
            format: fmt, maxValue: 255, baselinePct: 80);
        expect(identical(out2, data), isTrue, reason: fmt);
      }
      // mono 域（w*h 单通道）同样恒等直通。
      final mono = Uint16List.fromList([10, 200, 100, 0]);
      final out3 = adjustBrightContrast(mono, format: 'mono', maxValue: 255);
      expect(identical(out3, mono), isTrue);
    });

    test('非法格式抛 ArgumentError', () {
      final data = Uint16List.fromList([10, 200, 100]);
      expect(
          () => adjustBrightContrast(data,
              format: 'mosaic', maxValue: 255, brightPct: 150),
          throwsArgumentError);
    });

    test('YUV 域：按公式调 Y，U/V 不变', () {
      // base = 50% × 255 = 127.5；bright=200、gain=100：
      // Y' = (100×2 − 127.5) × 1 + 127.5 = 200。
      final yuv = Uint16List.fromList([100, 130, 60]);
      final out = adjustBrightContrast(yuv,
          format: 'yuv', maxValue: 255, brightPct: 200);
      expect(out[0], 200);
      expect(out[1], 130);
      expect(out[2], 60);
    });

    test('YUV 域：结果钳位到 0..maxValue', () {
      // (200×2 − 127.5) + 127.5 = 400 → 255。
      final yuv = Uint16List.fromList([200, 128, 128]);
      final out = adjustBrightContrast(yuv,
          format: 'yuv', maxValue: 255, brightPct: 200);
      expect(out[0], 255);
      // baseline=100、gain=200：base=255；(100−255)×2+255 = −55 → 0。
      final dark = adjustBrightContrast(Uint16List.fromList([100, 128, 128]),
          format: 'yuv', maxValue: 255, baselinePct: 100, gainPct: 200);
      expect(dark[0], 0);
    });

    test('RGB 域：按亮度比例等比缩放三通道', () {
      // Y = 0.299×100 + 0.587×50 + 0.114×50 = 64.95 ≈ 65；
      // baseline=0、bright=200 → Y' = 130；ratio = 130/64.95 ≈ 2.0015；
      // R' = 200.15→200，G'/B' = 100.08→100。
      final rgb = Uint16List.fromList([100, 50, 50]);
      final out = adjustBrightContrast(rgb,
          format: 'rgb', maxValue: 255, brightPct: 200, baselinePct: 0);
      expect(out[0], 200);
      expect(out[1], 100);
      expect(out[2], 100);
    });

    test('RGB 域：纯黑像素（Y=0）保持 0，不做除零', () {
      final rgb = Uint16List.fromList([0, 0, 0]);
      final out = adjustBrightContrast(rgb,
          format: 'rgb', maxValue: 255, brightPct: 0, baselinePct: 100);
      expect(out[0], 0);
      expect(out[1], 0);
      expect(out[2], 0);
    });

    test('HSL 域：作用于 L 通道，H/S 不变', () {
      // baseline=0、bright=200：L' = 100×2 = 200。
      final hsl = Uint16List.fromList([10, 200, 100]);
      final out = adjustBrightContrast(hsl,
          format: 'hsl', maxValue: 255, brightPct: 200, baselinePct: 0);
      expect(out[0], 10);
      expect(out[1], 200);
      expect(out[2], 200);
    });

    test('Mono 域：直接作用于单通道亮度（w*h 逐元素）', () {
      // base = 50% × 255 = 127.5；bright=200、gain=100：
      // v' = (v×2 − 127.5) + 127.5 = 2v → [20, 400→255, 0]。
      final mono = Uint16List.fromList([10, 200, 0]);
      final out = adjustBrightContrast(mono,
          format: 'mono', maxValue: 255, brightPct: 200);
      expect(out, [20, 255, 0]);
    });
  });

  group('YUV/HSL 组合转换', () {
    test('yuvToHsl：纯红 YUV 得 H=0、S=max、L=max/2', () {
      final yuv = rgbToYuv(Uint16List.fromList([255, 0, 0]), maxValue: 255);
      final hsl = yuvToHsl(yuv, maxValue: 255);
      expect((hsl[0]).abs(), lessThanOrEqualTo(2));
      expect((hsl[1] - 255).abs(), lessThanOrEqualTo(2));
      expect((hsl[2] - 128).abs(), lessThanOrEqualTo(2));
    });

    test('hslToYuv：灰点（S=0）的 U/V 位于中点', () {
      final yuv = hslToYuv(Uint16List.fromList([0, 0, 128]), maxValue: 255);
      expect((yuv[0] - 128).abs(), lessThanOrEqualTo(2));
      expect((yuv[1] - 128).abs(), lessThanOrEqualTo(2));
      expect((yuv[2] - 128).abs(), lessThanOrEqualTo(2));
    });

    test('YUV→HSL→YUV 往返误差 ≤8', () {
      final rgb = Uint16List.fromList(
          [0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 37, 200, 90]);
      final yuv = rgbToYuv(rgb, maxValue: 255);
      final back = hslToYuv(yuvToHsl(yuv, maxValue: 255), maxValue: 255);
      for (var i = 0; i < yuv.length; i++) {
        expect((back[i] - yuv[i]).abs(), lessThanOrEqualTo(8),
            reason: 'channel $i');
      }
    });

    test('HSL→YUV→HSL 往返误差 ≤8', () {
      // H 取值避开 0/maxValue 回绕点；灰点 H 取 0（灰度 H 任意，还原后为 0）。
      final src = [0, 0, 0, 0, 0, 128, 60, 255, 128, 128, 200, 100, 220, 255, 60];
      final hsl = Uint16List.fromList(src);
      final back = yuvToHsl(hslToYuv(hsl, maxValue: 255), maxValue: 255);
      for (var i = 0; i < src.length; i++) {
        expect((back[i] - src[i]).abs(), lessThanOrEqualTo(8),
            reason: 'channel $i');
      }
    });
  });

  group('CLAHE 自适应直方图均衡', () {
    /// 16x16 灰度水平渐变：亮度 100..110 的低对比度图。
    Uint16List lowContrast() {
      final rgb = Uint16List(16 * 16 * 3);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          final v = 100 + (x * 10) ~/ 15;
          final i = (y * 16 + x) * 3;
          rgb[i] = v;
          rgb[i + 1] = v;
          rgb[i + 2] = v;
        }
      }
      return rgb;
    }

    int rangeOf(Uint16List rgb) {
      var mn = 1 << 30, mx = 0;
      for (final v in rgb) {
        if (v < mn) mn = v;
        if (v > mx) mx = v;
      }
      return mx - mn;
    }

    test('均匀灰图均衡后仍近似均匀、亮度不变', () {
      final rgb = Uint16List(16 * 16 * 3);
      for (var p = 0; p < 16 * 16; p++) {
        rgb[p * 3] = 128;
        rgb[p * 3 + 1] = 128;
        rgb[p * 3 + 2] = 128;
      }
      applyClahe(rgb, width: 16, height: 16, blockSize: 8, maxValue: 255);
      for (var p = 0; p < 16 * 16; p++) {
        // 三通道一致（仍是均匀灰），亮度变化在容差内。
        expect(rgb[p * 3], rgb[p * 3 + 1], reason: 'pixel $p');
        expect(rgb[p * 3 + 1], rgb[p * 3 + 2], reason: 'pixel $p');
        expect((rgb[p * 3] - 128).abs(), lessThanOrEqualTo(2),
            reason: 'pixel $p');
      }
    });

    test('strength=0 时输出等于原图', () {
      final rgb = lowContrast();
      final orig = Uint16List.fromList(rgb);
      applyClahe(rgb,
          width: 16, height: 16, blockSize: 8, strength: 0, maxValue: 255);
      expect(rgb, orig);
    });

    test('低对比度图像均衡后取值范围展宽', () {
      final before = rangeOf(lowContrast());
      final rgb = lowContrast();
      // 单 tile（blockSize 16 = 整幅）即全局 CLAHE。
      applyClahe(rgb, width: 16, height: 16, blockSize: 16, maxValue: 255);
      expect(rangeOf(rgb), greaterThan(before));
    });

    test('clipLimit 越大对比度增强越明显', () {
      final weak = lowContrast();
      applyClahe(weak,
          width: 16, height: 16, blockSize: 16, clipLimit: 1.0,
          maxValue: 255);
      final strong = lowContrast();
      applyClahe(strong,
          width: 16, height: 16, blockSize: 16, clipLimit: 10.0,
          maxValue: 255);
      expect(rangeOf(strong), greaterThan(rangeOf(weak)));
    });

    /// 16x16 低对比度 Mono 帧（100..110 水平渐变，w*h 单通道）。
    Uint16List lowContrastMono() {
      final mono = Uint16List(16 * 16);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          mono[y * 16 + x] = 100 + (x * 10) ~/ 15;
        }
      }
      return mono;
    }

    test('Mono 通路：均匀帧均衡后近似不变', () {
      final mono = Uint16List(16 * 16)..fillRange(0, 256, 128);
      applyClaheMono(mono, width: 16, height: 16, blockSize: 8, maxValue: 255);
      for (var p = 0; p < 256; p++) {
        expect((mono[p] - 128).abs(), lessThanOrEqualTo(2),
            reason: 'pixel $p');
      }
    });

    test('Mono 通路：strength=0 时输出等于原图', () {
      final mono = lowContrastMono();
      final orig = Uint16List.fromList(mono);
      applyClaheMono(mono,
          width: 16, height: 16, blockSize: 8, strength: 0, maxValue: 255);
      expect(mono, orig);
    });

    test('Mono 通路：低对比度帧均衡后取值范围展宽', () {
      final before = rangeOf(lowContrastMono());
      final mono = lowContrastMono();
      applyClaheMono(mono, width: 16, height: 16, blockSize: 16, maxValue: 255);
      expect(rangeOf(mono), greaterThan(before));
    });
  });

  group('ICG RAW 域核', () {
    test('applyDpc median：同相位离群像素替换为邻域中值', () {
      // 5x5 rggb：全部 100，中心 (2,2) 坏点 1000。
      final buf = Uint16List(25)..fillRange(0, 25, 100);
      buf[2 * 5 + 2] = 1000;
      applyDpc(buf,
          width: 5,
          height: 5,
          pattern: BayerPattern.rggb,
          threshold: 5,
          mode: 'median',
          maxValue: 255);
      expect(buf[2 * 5 + 2], 100);
      // 其余像素不变。
      expect(buf.where((v) => v != 100), isEmpty);
    });

    test('applyDpc directional：沿最小梯度方向两点平均', () {
      // 中心 (2,2) 坏点 1000；同相位邻域垂直对为 90/90（梯度最小），
      // 其余方向对的取值差都在离群阈值以内（不会被先校正掉）。
      final buf = Uint16List(25)..fillRange(0, 25, 100);
      buf[0 * 5 + 2] = 90; // (2,0) 垂直对上端
      buf[4 * 5 + 2] = 90; // (2,4) 垂直对下端
      buf[2 * 5 + 4] = 104; // (4,2) 水平对：差 4
      buf[4 * 5 + 4] = 105; // (4,4) 主对角对：差 5
      buf[4 * 5 + 0] = 106; // (0,4) 副对角对：差 6
      buf[2 * 5 + 2] = 1000; // 坏点
      applyDpc(buf,
          width: 5,
          height: 5,
          pattern: BayerPattern.rggb,
          threshold: 5,
          mode: 'directional',
          maxValue: 255);
      expect(buf[2 * 5 + 2], 90);
      // median 模式则取邻域中值 100。
      final buf2 = Uint16List(25)..fillRange(0, 25, 100);
      buf2[0 * 5 + 2] = 90;
      buf2[4 * 5 + 2] = 90;
      buf2[2 * 5 + 4] = 104;
      buf2[4 * 5 + 4] = 105;
      buf2[4 * 5 + 0] = 106;
      buf2[2 * 5 + 2] = 1000;
      applyDpc(buf2,
          width: 5,
          height: 5,
          pattern: BayerPattern.rggb,
          threshold: 5,
          mode: 'median',
          maxValue: 255);
      expect(buf2[2 * 5 + 2], 100);
    });

    test('applyDpc mono（pattern null）：全像素 3x3 邻域', () {
      final buf = Uint16List(9)..fillRange(0, 9, 100);
      buf[4] = 1000; // 中心坏点
      applyDpc(buf,
          width: 3, height: 3, pattern: null, threshold: 5, maxValue: 255);
      expect(buf[4], 100);
    });

    test('applyDpc 2x2 小图无同相位邻域时不崩且不变', () {
      final buf = Uint16List.fromList([10, 20, 30, 1000]);
      applyDpc(buf,
          width: 2,
          height: 2,
          pattern: BayerPattern.rggb,
          threshold: 5,
          maxValue: 255);
      expect(buf, [10, 20, 30, 1000]);
    });

    test('applyFpn：行/列中值偏移扣除并限幅', () {
      // 4x4：行 0 偏 +10、行 1 偏 −10、其余 100。
      final buf = Uint16List(16);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          buf[y * 4 + x] = y == 0 ? 110 : (y == 1 ? 90 : 100);
        }
      }
      applyFpn(buf, width: 4, height: 4, row: true, col: false, maxCorr: 64);
      expect(buf.every((v) => v == 100), isTrue);
      // 限幅：maxCorr=5 时行 0 只扣 5。
      final buf2 = Uint16List(16);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          buf2[y * 4 + x] = y == 0 ? 110 : (y == 1 ? 90 : 100);
        }
      }
      applyFpn(buf2, width: 4, height: 4, row: true, col: false, maxCorr: 5);
      expect(buf2[0], 105);
      expect(buf2[4], 95);
      expect(buf2[8], 100);
    });

    test('applyFpn：内容条纹不被当作 FPN（竖条保持）', () {
      // 64x16 竖条（条宽 32 > 低通窗半径 8）：左半 200 右半 50，无 FPN
      // 时必须是无操作（旧实现按列中值扣除会把暗条整体抬亮 maxCorr）。
      final buf = Uint16List(64 * 16);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 64; x++) {
          buf[y * 64 + x] = x < 32 ? 200 : 50;
        }
      }
      applyFpn(buf, width: 64, height: 16, maxCorr: 64);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 64; x++) {
          expect(buf[y * 64 + x], x < 32 ? 200 : 50,
              reason: '($x,$y) 不应被校正');
        }
      }
    });

    test('applyFpn：叠加列 FPN 的竖条内容仍被校正', () {
      // 竖条内容 + 第 10 列 +12 列噪声：校正后第 10 列回到内容值附近
      // （低通窗均摊引入 ±1 量化误差）；条带边缘列被掩膜保持原值。
      final buf = Uint16List(64 * 16);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 64; x++) {
          buf[y * 64 + x] = (x < 32 ? 200 : 50) + (x == 10 ? 12 : 0);
        }
      }
      applyFpn(buf, width: 64, height: 16, maxCorr: 64);
      for (var y = 0; y < 16; y++) {
        expect(buf[y * 64 + 10], inInclusiveRange(200, 201));
        expect(buf[y * 64 + 19], 200); // 左条内部（低通窗不含噪声列）
        expect(buf[y * 64 + 31], 200); // 条带边缘列：掩膜，保持原值
        expect(buf[y * 64 + 50], 50); // 右条内部
      }
    });

    test('applyLsc：径向增益边缘亮中心暗并截位', () {
      final buf = Uint16List(16)..fillRange(0, 16, 100);
      applyLsc(buf,
          width: 4,
          height: 4,
          strength: 1.0,
          centerX: 0.5,
          centerY: 0.5,
          maxValue: 65535);
      expect(buf[0], 200); // 角落 gain = 2
      expect(buf[1 * 4 + 1], 111); // 近中心 gain ≈ 1.11
      // 饱和截位。
      final sat = Uint16List(16)..fillRange(0, 16, 40000);
      applyLsc(sat,
          width: 4,
          height: 4,
          strength: 1.0,
          centerX: 0.5,
          centerY: 0.5,
          maxValue: 65535);
      expect(sat[0], 65535);
    });

    test('applyGrGbBalance：Gr/Gb 向均值中点收敛', () {
      // 4x4 rggb：R=B=100，Gr=120，Gb=80 → 均衡后 G 全为 100。
      final buf = Uint16List(16);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final c = BayerPattern.rggb.colorAt(x, y);
          if (c != 1) {
            buf[y * 4 + x] = 100;
          } else {
            final isGr = BayerPattern.rggb.colorAt(x ^ 1, y) == 0;
            buf[y * 4 + x] = isGr ? 120 : 80;
          }
        }
      }
      applyGrGbBalance(buf,
          width: 4, height: 4, pattern: BayerPattern.rggb, strength: 1.0);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          if (BayerPattern.rggb.colorAt(x, y) == 1) {
            expect(buf[y * 4 + x], inInclusiveRange(99, 101),
                reason: 'G at ($x,$y)');
          }
        }
      }
    });

    test('applyBayerDenoise：平坦区域保持不变，strength 0 直通', () {
      final buf = Uint16List(16)..fillRange(0, 16, 500);
      applyBayerDenoise(buf,
          width: 4, height: 4, pattern: BayerPattern.rggb, strength: 1.0);
      expect(buf.every((v) => v == 500), isTrue);
      final buf2 = Uint16List.fromList([1, 2, 3, 4]);
      applyBayerDenoise(buf2, width: 2, height: 2, pattern: null, strength: 0);
      expect(buf2, [1, 2, 3, 4]);
    });

    test('applyHighlightRecovery：recover 用未饱和邻域重建，clip 软压缩', () {
      // 4x4 rggb，maxValue 255，膝点 0.9 → 229.5；中心 R 饱和 255，其余 R=100。
      final buf = Uint16List(16)..fillRange(0, 16, 100);
      buf[2 * 4 + 2] = 255;
      applyHighlightRecovery(buf,
          width: 4,
          height: 4,
          pattern: BayerPattern.rggb,
          maxValue: 255,
          mode: 'recover',
          knee: 0.9);
      expect(buf[2 * 4 + 2], 100);
      // clip：255 → 229.5 + 25.5*25.5/(25.5+25.5) ≈ 242。
      final buf2 = Uint16List.fromList([255, 100, 100, 100]);
      applyHighlightRecovery(buf2,
          width: 2,
          height: 2,
          pattern: BayerPattern.rggb,
          maxValue: 255,
          mode: 'clip',
          knee: 0.9);
      expect(buf2[0], inInclusiveRange(241, 243));
      expect(buf2[1], 100); // 膝点以下不变
    });
  });

  group('ICG RGB 域核', () {
    test('applyRgbDenoise：平坦区域基本不变', () {
      final rgb = Uint16List(4 * 4 * 3);
      for (var p = 0; p < 16; p++) {
        rgb[p * 3] = 100;
        rgb[p * 3 + 1] = 150;
        rgb[p * 3 + 2] = 200;
      }
      applyRgbDenoise(rgb,
          width: 4, height: 4, luma: 1.0, chroma: 0.5, maxValue: 1023);
      for (var p = 0; p < 16; p++) {
        expect((rgb[p * 3] - 100).abs(), lessThanOrEqualTo(2));
        expect((rgb[p * 3 + 1] - 150).abs(), lessThanOrEqualTo(2));
        expect((rgb[p * 3 + 2] - 200).abs(), lessThanOrEqualTo(2));
      }
    });

    test('applySharpen：边缘增强、平坦不变、amount 0 直通', () {
      // 4x1 灰度阶跃 [0, 0, 1000, 1000]，maxValue 1023。
      Uint16List step() {
        final rgb = Uint16List(4 * 3);
        for (var x = 2; x < 4; x++) {
          rgb[x * 3] = 1000;
          rgb[x * 3 + 1] = 1000;
          rgb[x * 3 + 2] = 1000;
        }
        return rgb;
      }

      final none = step();
      applySharpen(none,
          width: 4, height: 1, amount: 0, threshold: 0, maxValue: 1023);
      expect(none, step());
      final sharp = step();
      applySharpen(sharp,
          width: 4, height: 1, amount: 1.0, threshold: 0, maxValue: 1023);
      // x=2：Y=1000，模糊 667，detail 333 → Y' 1333 截位 1023。
      expect(sharp[2 * 3], 1023);
      // 平坦区 detail 为 0，x=3 不变。
      expect(sharp[3 * 3], 1000);
    });

    test('convertRgbToYuvCsc：bt601 full 与 rgbToYuv 一致', () {
      final rgb = Uint16List.fromList([10, 200, 90, 255, 128, 0]);
      expect(convertRgbToYuvCsc(rgb, width: 2, height: 1, maxValue: 255),
          rgbToYuv(rgb, maxValue: 255));
    });

    test('convertRgbToYuvCsc：bt709 纯红系数与 limited 范围', () {
      final red = Uint16List.fromList([255, 0, 0]);
      final yuv = convertRgbToYuvCsc(red,
          width: 1, height: 1, standard: 'bt709', maxValue: 255);
      expect((yuv[0] - 54).abs(), lessThanOrEqualTo(1)); // 0.2126*255
      expect(yuv[1], inInclusiveRange(97, 101));
      expect(yuv[2], 255); // 钳位
      // limited：128 灰 → Y=126（16+128*219/255），U/V 保持中点。
      final gray = Uint16List.fromList([128, 128, 128]);
      final yuv2 = convertRgbToYuvCsc(gray,
          width: 1, height: 1, range: 'limited', maxValue: 255);
      expect(yuv2[0], inInclusiveRange(125, 127));
      expect((yuv2[1] - 128).abs(), lessThanOrEqualTo(1));
      expect((yuv2[2] - 128).abs(), lessThanOrEqualTo(1));
    });
  });

  group('ICG 荧光 mono 域核', () {
    test('applyFluoroLeak：统一扣除并限幅、钳位 0', () {
      final mono = Uint16List.fromList([10, 100, 200]);
      applyFluoroLeak(mono, level: 50, maxSub: 100);
      expect(mono, [0, 50, 150]);
      final mono2 = Uint16List.fromList([100]);
      applyFluoroLeak(mono2, level: 80, maxSub: 60); // 限幅到 60
      expect(mono2, [40]);
    });

    test('applyFluoroBackground：块均值背景按强度扣除', () {
      // 4x4，blockSize 2：四个 2x2 块常量 10/20/30/40。
      final mono = Uint16List(16);
      const vals = [10, 20, 30, 40];
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          mono[y * 4 + x] = vals[(y ~/ 2) * 2 + (x ~/ 2)];
        }
      }
      final full = Uint16List.fromList(mono);
      applyFluoroBackground(full,
          width: 4, height: 4, blockSize: 2, strength: 1.0);
      expect(full.every((v) => v == 0), isTrue);
      final half = Uint16List.fromList(mono);
      applyFluoroBackground(half,
          width: 4, height: 4, blockSize: 2, strength: 0.5);
      expect(half[0], 5); // 10 − 0.5*10
      expect(half[3 * 4 + 3], 20); // 40 − 0.5*40
    });

    test('applyFluoroNormalize：按全帧均值拉到参考电平', () {
      final mono = Uint16List.fromList([100, 200, 300, 400]);
      applyFluoroNormalize(mono, reference: 500, epsilon: 1, maxValue: 65535);
      expect(mono, [200, 400, 600, 800]); // 均值 250 → gain 2
      // 均值低于 epsilon：直通。
      final dark = Uint16List.fromList([0, 1]);
      applyFluoroNormalize(dark, reference: 500, epsilon: 10, maxValue: 65535);
      expect(dark, [0, 1]);
      // reference 0：直通。
      final off = Uint16List.fromList([100, 200]);
      applyFluoroNormalize(off, reference: 0, epsilon: 1, maxValue: 65535);
      expect(off, [100, 200]);
    });

    test('applyTemporalIir：无历史直通，有历史按 α 混合', () {
      final mono = Uint16List.fromList([100, 200]);
      final (out0, hist0) = applyTemporalIir(mono, alpha: 0.5, maxValue: 65535);
      expect(out0, [100, 200]);
      expect(hist0, [100, 200]);
      final (out1, _) = applyTemporalIir(mono,
          history: Uint16List.fromList([0, 100]),
          alpha: 0.5,
          maxValue: 65535);
      expect(out1, [50, 150]);
      // 运动自适应：帧差超过 maxValue/16 时强制用当前帧。
      final (out2, _) = applyTemporalIir(mono,
          history: Uint16List.fromList([0, 100]),
          alpha: 0.5,
          motionAdapt: true,
          maxValue: 255);
      expect(out2, [100, 200]);
    });

    test('monoPseudoColor：green/magenta/hot 色表', () {
      final mono = Uint16List.fromList([0, 255]);
      final green =
          monoPseudoColor(mono, width: 2, height: 1, maxValue: 255);
      expect(green, [0, 0, 0, 0, 255, 0]);
      final magenta = monoPseudoColor(mono,
          width: 2, height: 1, colormap: 'magenta', maxValue: 255);
      expect(magenta, [0, 0, 0, 255, 0, 255]);
      final hot = monoPseudoColor(Uint16List.fromList([128]),
          width: 1, height: 1, colormap: 'hot', maxValue: 255);
      expect(hot[0], 255); // 3t > 1 → 红满
      expect(hot[1], inInclusiveRange(127, 131)); // 黄过渡
      expect(hot[2], 0);
      // gain 放大：0.5 满量程 × 2 → 满。
      final gained = monoPseudoColor(Uint16List.fromList([128]),
          width: 1, height: 1, gain: 2.0, maxValue: 255);
      expect(gained[1], 255);
    });

    test('fuseFluorescence：alpha 模式按强度门限融合', () {
      // 2x1：白光全 100 灰，荧光 [255, 0]，threshold 128、alphaMax 1。
      final wl = Uint16List.fromList([100, 100, 100, 100, 100, 100]);
      final fl = Uint16List.fromList([255, 0]);
      final out = fuseFluorescence(wl, fl,
          width: 2,
          height: 1,
          threshold: 128,
          alphaMax: 1.0,
          maxValue: 255);
      // 荧光满强度 → α=1 → 纯绿伪彩。
      expect([out[0], out[1], out[2]], [0, 255, 0]);
      // 荧光 0 → α=0 → 白光原样。
      expect([out[3], out[4], out[5]], [100, 100, 100]);
      // 偏移 1 像素：像素 0 采到 fl[1]=0 → 白光。
      final shifted = fuseFluorescence(wl, fl,
          width: 2,
          height: 1,
          threshold: 128,
          alphaMax: 1.0,
          offsetX: 1,
          maxValue: 255);
      expect([shifted[0], shifted[1], shifted[2]], [100, 100, 100]);
    });

    test('fuseFluorescence：contour 模式只叠加 mask 轮廓', () {
      // 3x3：中心荧光 255，周围 0；threshold 128。
      final wl = Uint16List(9 * 3)..fillRange(0, 27, 100);
      final fl = Uint16List(9);
      fl[4] = 255;
      final out = fuseFluorescence(wl, fl,
          width: 3, height: 3, mode: 'contour', threshold: 128, maxValue: 255);
      // 中心是 mask 边缘（邻域全是 mask 外）→ 伪彩全强度。
      expect([out[12], out[13], out[14]], [0, 255, 0]);
      // 角落非 mask → 白光。
      expect([out[0], out[1], out[2]], [100, 100, 100]);
    });
  });

  group('applyColorBalance 色彩平衡', () {
    test('三值全 0 直通不拷贝', () {
      final src = Uint16List.fromList([10, 20, 30, 200, 100, 50]);
      final out = applyColorBalance(src, format: 'rgb', maxValue: 255);
      expect(identical(out, src), isTrue, reason: '恒等时应返回原列表');
    });

    test('中间调偏移：正值加红，负值偏青，G/B 不变', () {
      // 中灰像素 Y≈0.502，w≈0.996。
      final src = Uint16List.fromList([128, 128, 128]);
      final out =
          applyColorBalance(src, format: 'rgb', maxValue: 255, cyanRed: 10);
      // dr = 10/100*255 = 25.5；r' ≈ 128 + 25.5*0.996 ≈ 153。
      expect(out[0], closeTo(153, 1));
      expect(out[1], 128);
      expect(out[2], 128);
      // 负值向青（减 R）。
      final neg = applyColorBalance(src, format: 'rgb', maxValue: 255, cyanRed: -10);
      expect(neg[0], closeTo(103, 1));
    });

    test('纯黑/纯白不受中间调权重影响', () {
      final src = Uint16List.fromList([0, 0, 0, 255, 255, 255]);
      final out = applyColorBalance(src,
          format: 'rgb',
          maxValue: 255,
          cyanRed: 100,
          magentaGreen: 100,
          yellowBlue: 100);
      expect(out, src, reason: 'w=0 时黑/白像素不应偏移');
    });

    test('结果钳位到 maxValue', () {
      final src = Uint16List.fromList([200, 200, 200]);
      final out = applyColorBalance(src,
          format: 'rgb', maxValue: 255, yellowBlue: 100);
      expect(out[2], 255, reason: 'B 通道偏移超限时钳位');
    });

    test('YUV 域：青↔红走 V 轴、黄↔蓝走 U 轴、Y 不变', () {
      // 中性色：U=V=128（maxValue 255 的中点），Y=128 → w≈1。
      final src = Uint16List.fromList([128, 128, 128]);
      final out = applyColorBalance(src,
          format: 'yuv', maxValue: 255, cyanRed: 50, yellowBlue: -50);
      expect(out[0], 128, reason: 'Y 通道不变');
      // du = -50×(255/2/100) ≈ -63.75；dv = +63.75；w≈0.996。
      expect(out[1], closeTo(64, 1), reason: 'yellow_blue=-50 偏黄（U 减）');
      expect(out[2], closeTo(192, 1), reason: 'cyan_red=50 偏红（V 增）');
      // 洋红↔绿走 U/V 对角：绿 = −U−V。
      final green = applyColorBalance(src,
          format: 'yuv', maxValue: 255, magentaGreen: 100);
      expect(green[1], lessThan(128));
      expect(green[2], lessThan(128));
    });

    test('HSL 域：经 RGB 往返施加偏移，小偏移近似恒等', () {
      // 中性灰 HSL ≈ (0, 0, 128)：往返转换 + 零偏移应近似回读。
      final src = Uint16List.fromList([0, 0, 128]);
      final out = applyColorBalance(src,
          format: 'hsl', maxValue: 255, cyanRed: 10);
      // 偏移后仍为 HSL 三通道合法值（不越界）。
      for (final v in out) {
        expect(v, inInclusiveRange(0, 255));
      }
    });

    test('非 RGB/YUV/HSL 格式抛错', () {
      expect(
          () => applyColorBalance(Uint16List(3),
              format: 'mosaic', maxValue: 255, cyanRed: 1),
          throwsStateError);
    });
  });

  group('extractHighFreq 高频边缘提取', () {
    test('平坦图像输出纯黑', () {
      final src = Uint16List(4 * 4 * 3)..fillRange(0, 48, 100);
      final out = extractHighFreq(src,
          width: 4, height: 4, threshold: 0, maxValue: 255);
      for (final v in out) {
        expect(v, 0, reason: 'detail=0 → 黑底（gain×|detail| = 0）');
      }
    });

    test('亮点脉冲：中心与邻域均为满量程亮线、远处纯黑', () {
      // 4x4 全 0，(1,1) 处亮点 255。
      final src = Uint16List(4 * 4 * 3);
      final c = (1 * 4 + 1) * 3;
      src[c] = src[c + 1] = src[c + 2] = 255;
      final out = extractHighFreq(src,
          width: 4, height: 4, threshold: 0, maxValue: 255);
      // 中心 detail = 255 − 255/9，相对对比度 8 → 截位到满量程。
      expect(out[c], 255, reason: '亮点处相对对比度 8 → 截位满量程');
      // 亮点右侧像素 (1,2)：detail<0 取幅值，相对对比度 1 → 满量程。
      final n = (1 * 4 + 2) * 3;
      expect(out[n], 255, reason: '暗侧边缘同为亮线（黑底白线不区分极性）');
      // 远处像素 detail=0 → 纯黑。
      final far = (3 * 4 + 3) * 3;
      expect(out[far], 0);
      // 三通道同值（灰度图）。
      expect(out[c], out[c + 1]);
      expect(out[c], out[c + 2]);
    });

    test('门限抑制弱 detail，增益按比例放大', () {
      // 左半 100 右半 140 的 4x4 缓变边缘。
      Uint16List edge() {
        final f = Uint16List(4 * 4 * 3);
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final v = x < 2 ? 100 : 140;
            final i = (y * 4 + x) * 3;
            f[i] = f[i + 1] = f[i + 2] = v;
          }
        }
        return f;
      }

      // threshold 50 → 相对门限 50/255≈0.196 > 边缘 rel≈0.105，
      // 全部置零 → 纯黑。
      final suppressed = extractHighFreq(edge(),
          width: 4, height: 4, threshold: 50, maxValue: 255);
      for (final v in suppressed) {
        expect(v, 0);
      }
      // threshold 0：边界右侧像素 rel≈0.105 → √rel×255 ≈ 83；
      // gain=2 更亮（≈165）。
      final g1 = extractHighFreq(edge(),
          width: 4, height: 4, threshold: 0, maxValue: 255);
      final g2 = extractHighFreq(edge(),
          width: 4, height: 4, gain: 2, threshold: 0, maxValue: 255);
      final i = (1 * 4 + 2) * 3;
      expect(g1[i], 83);
      expect(g2[i], greaterThan(g1[i]));
      // 平坦区（左半内部）detail=0 → 纯黑。
      expect(g1[(1 * 4 + 0) * 3], 0);
    });

    test('暗区边缘：按相对对比度归一化，与亮区同反差边缘输出同亮度', () {
      // 暗边缘 4|8 与亮边缘 100|200 的相对反差相同（2:1），输出应一致。
      Uint16List edge(int lo, int hi) {
        final f = Uint16List(4 * 4 * 3);
        for (var y = 0; y < 4; y++) {
          for (var x = 0; x < 4; x++) {
            final v = x < 2 ? lo : hi;
            final i = (y * 4 + x) * 3;
            f[i] = f[i + 1] = f[i + 2] = v;
          }
        }
        return f;
      }

      final i = (1 * 4 + 2) * 3;
      final dark = extractHighFreq(edge(4, 8),
          width: 4, height: 4, threshold: 0, maxValue: 255);
      final bright = extractHighFreq(edge(100, 200),
          width: 4, height: 4, threshold: 0, maxValue: 255);
      // 边界像素 rel = |hi − (lo+2hi)/3| / ((lo+2hi)/3) = 0.2
      // → √0.2×255 ≈ 114。
      expect(dark[i], 114, reason: '暗区边缘按相对对比度放大，清晰可见');
      expect(dark[i], bright[i], reason: '亮度不变性：同反差输出同亮度');
      // 平坦区仍为纯黑。
      expect(dark[(1 * 4 + 0) * 3], 0);
      expect(bright[(1 * 4 + 0) * 3], 0);
    });

    test('YUV 域：取 Y 通道求 detail，U/V 输出中灰', () {
      // 4x4 全 0，(1,1) 处 Y=255 亮点；U/V 任意值不影响结果。
      final src = Uint16List(4 * 4 * 3);
      final c = (1 * 4 + 1) * 3;
      src[c] = 255;
      src[c + 1] = 30;
      src[c + 2] = 200;
      final out = extractHighFreq(src,
          width: 4, height: 4, format: 'yuv', threshold: 0, maxValue: 255);
      expect(out[c], 255, reason: '亮点处相对对比度 8 → Y 截位满量程');
      // U/V 输出中性中灰（白线不带色）。
      expect(out[c + 1], 127);
      expect(out[c + 2], 127);
      // 远处像素 Y detail=0 → 黑。
      final far = (3 * 4 + 3) * 3;
      expect(out[far], 0);
    });

    test('HSL 域：取 L 通道求 detail，H=0、S=0', () {
      // 4x4 全 0，(1,1) 处 L=255 亮点。
      final src = Uint16List(4 * 4 * 3);
      final c = (1 * 4 + 1) * 3;
      src[c + 2] = 255;
      final out = extractHighFreq(src,
          width: 4, height: 4, format: 'hsl', threshold: 0, maxValue: 255);
      expect(out[c + 2], 255, reason: '亮点处相对对比度 8 → L 截位满量程');
      expect(out[c], 0, reason: 'S=0 时 H 无意义，输出 0');
      expect(out[c + 1], 0, reason: '黑底白线图 S=0');
      final far = (3 * 4 + 3) * 3;
      expect(out[far + 2], 0, reason: '远处像素 detail=0 → L 黑');
    });

    test('RGB 默认格式与 format: rgb 一致；非法格式抛 ArgumentError', () {
      final src = Uint16List(4 * 4 * 3)..fillRange(0, 48, 100);
      final a = extractHighFreq(src, width: 4, height: 4, maxValue: 255);
      final b = extractHighFreq(src,
          width: 4, height: 4, format: 'rgb', maxValue: 255);
      expect(a, b);
      expect(
          () => extractHighFreq(src,
              width: 4, height: 4, format: 'mosaic', maxValue: 255),
          throwsArgumentError);
    });
  });

  group('multiplyMono 乘法器', () {
    test('归一化相乘：out = a×b/maxValue', () {
      final a = Uint16List.fromList([0, 64, 128, 255]);
      final b = Uint16List.fromList([255, 128, 128, 255]);
      final out = multiplyMono(a, b, maxValue: 255);
      expect(out, [0, 32, 64, 255],
          reason: '0×1=0，64×128/255≈32，128×128/255≈64，255×255/255=255');
    });

    test('满量程 × 满量程 = 满量程（截位不溢出）', () {
      final a = Uint16List.fromList([65535, 65535]);
      final b = Uint16List.fromList([65535, 40000]);
      final out = multiplyMono(a, b);
      expect(out[0], 65535);
      expect(out[1], 40000, reason: '65535×40000/65535 = 40000');
    });

    test('与零相乘得零；长度不一致按短者截断', () {
      final a = Uint16List.fromList([100, 200, 300]);
      final b = Uint16List.fromList([0, 128]);
      final out = multiplyMono(a, b, maxValue: 255);
      expect(out.length, 2);
      expect(out, [0, 100], reason: '200×128/255 ≈ 100');
    });

    test('offset：抬升后参与相乘，负值截位到 0', () {
      final a = Uint16List.fromList([0, 100, 10]);
      final b = Uint16List.fromList([128, 128, 128]);
      // (0+100)×128/255 ≈ 50；(100+100)×128/255 ≈ 100。
      final out = multiplyMono(a, b,
          offset1: 100, offset2: 0, maxValue: 255);
      expect(out[0], 50, reason: 'offset1 把零值像素抬到 100 再相乘');
      expect(out[1], 100);
      final neg = multiplyMono(a, b,
          offset1: -50, offset2: 0, maxValue: 255);
      expect(neg[0], 0, reason: '(0−50)×128 < 0 → 截位到 0');
      expect(neg[1], 25, reason: '(100−50)×128/255 ≈ 25');
      // offset2 同理作用于第二路。
      final out2 = multiplyMono(a, b,
          offset1: 0, offset2: 127, maxValue: 255);
      expect(out2[1], 100, reason: '100×(128+127)/255 = 100');
    });
  });

  group('blendMono 加法器', () {
    test('balance=0.5 取两路均值，增益总和恒为 1', () {
      final a = Uint16List.fromList([100, 200, 0]);
      final b = Uint16List.fromList([300, 100, 65535]);
      final out = blendMono(a, b);
      expect(out[0], 200, reason: '(100+300)/2 = 200');
      expect(out[1], 150, reason: '(200+100)/2 = 150');
      expect(out[2], 32768, reason: '65535/2 ≈ 32768');
    });

    test('balance 为 0/1 时退化为单路直通', () {
      final a = Uint16List.fromList([100, 200]);
      final b = Uint16List.fromList([300, 400]);
      expect(blendMono(a, b, balance: 1), [100, 200], reason: 'balance=1 全源1');
      expect(blendMono(a, b, balance: 0), [300, 400], reason: 'balance=0 全源2');
    });

    test('加权和截位到 maxValue；长度不一致按短者截断', () {
      final a = Uint16List.fromList([65535, 100, 50]);
      final b = Uint16List.fromList([65535, 100]);
      final out = blendMono(a, b, balance: 0.8, maxValue: 255);
      expect(out.length, 2);
      expect(out[0], 255, reason: '加权和超 maxValue 截位');
      expect(out[1], 100, reason: '同值混合不变');
    });
  });

  group('blendMaskMono 混叠器（正常模式）', () {
    test('RGB 基图：三通道同加（等效亮度叠加）', () {
      // 2 像素 RGB 基图；混叠图 200、蒙版取半（128/255）→ delta≈100×强度。
      final base = Uint16List.fromList([10, 20, 30, 40, 50, 60]);
      final blend = Uint16List.fromList([200, 0]);
      final mask = Uint16List.fromList([128, 255]);
      final out = blendMaskMono(base, blend, mask,
          format: 'rgb', strength: 1.0, maxValue: 255);
      // delta = 200×128/255 ≈ 100.4 → 各通道 +100；混叠图为 0 → 不变。
      expect(out, [110, 120, 130, 40, 50, 60]);
      // 强度加倍 → delta 加倍。
      final out2 = blendMaskMono(base, blend, mask,
          format: 'rgb', strength: 2.0, maxValue: 255);
      expect(out2, [211, 221, 231, 40, 50, 60]);
      // 蒙版为 0 → 无混叠，输出等于基图（且基图缓冲不被修改）。
      final out3 = blendMaskMono(base, blend, Uint16List(2),
          format: 'rgb', maxValue: 255);
      expect(out3, base);
    });

    test('YUV 基图：只加 Y，U/V 不变（锐化不产生色偏）', () {
      final base = Uint16List.fromList([10, 128, 130, 40, 128, 130]);
      final blend = Uint16List.fromList([200, 200]);
      final mask = Uint16List.fromList([128, 255]);
      final out = blendMaskMono(base, blend, mask,
          format: 'yuv', strength: 1.0, maxValue: 255);
      // 像素0：Y 10+100=110，U/V 不变；像素1：Y 40+200=240，U/V 不变。
      expect(out, [110, 128, 130, 240, 128, 130]);
    });

    test('HSL 基图：只加 L；截位到 maxValue；强度 0 直通', () {
      final base = Uint16List.fromList([0, 0, 250, 0, 0, 10]);
      final blend = Uint16List.fromList([255, 255]);
      final mask = Uint16List.fromList([255, 255]);
      final out = blendMaskMono(base, blend, mask,
          format: 'hsl', strength: 1.0, maxValue: 255);
      expect(out, [0, 0, 255, 0, 0, 255],
          reason: 'L 250+255 截位到 255，L 10+255 截位到 255；H/S 不变');
      final same = blendMaskMono(base, blend, mask,
          format: 'hsl', strength: 0, maxValue: 255);
      expect(same, base, reason: '强度 0 输出等于基图');
    });

    test('Mono 基图：单通道叠加并截位', () {
      final base = Uint16List.fromList([250, 10]);
      final blend = Uint16List.fromList([255, 255]);
      final mask = Uint16List.fromList([255, 255]);
      final out = blendMaskMono(base, blend, mask,
          format: 'mono', strength: 1.0, maxValue: 255);
      expect(out, [255, 255]);
    });

    test('三通道混叠图：逐通道对应叠加（Y 加到 Y、U 加到 U）', () {
      // YUV 基图 2 像素；混叠图为三通道交织，每通道独立增量。
      final base = Uint16List.fromList([10, 128, 130, 40, 128, 130]);
      final blend = Uint16List.fromList([200, 255, 0, 100, 0, 51]);
      final mask = Uint16List.fromList([128, 255]);
      final out = blendMaskMono(base, blend, mask,
          format: 'yuv', blendChannels: 3, strength: 1.0, maxValue: 255);
      // 像素0：Y 10+200×128/255≈110，U 128+255×128/255≈255（截位），
      // V 130+0=130；像素1：Y 40+100=140，U 128+0=128，V 130+51=181。
      expect(out, [110, 255, 130, 140, 128, 181]);
    });
  });

  group('applyMorphology', () {
    test('膨胀：单亮点扩散为 (2r+1)² 方块', () {
      // 5x5 全 0，中心亮点 1000，radius=1 膨胀 → 中心 3x3 全 1000。
      final img = Uint16List(25);
      img[2 * 5 + 2] = 1000;
      applyMorphology(img, width: 5, height: 5, erode: false, radius: 1);
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          final inBox = x >= 1 && x <= 3 && y >= 1 && y <= 3;
          expect(img[y * 5 + x], inBox ? 1000 : 0,
              reason: '($x,$y) ${inBox ? "在" : "不在"}扩散范围内');
        }
      }
    });

    test('腐蚀：亮块收缩一圈，孤立亮点消失', () {
      // 5x5 全 0，中心 3x3 亮块 → radius=1 腐蚀后只剩中心点。
      final img = Uint16List(25);
      for (var y = 1; y <= 3; y++) {
        for (var x = 1; x <= 3; x++) {
          img[y * 5 + x] = 800;
        }
      }
      applyMorphology(img, width: 5, height: 5, radius: 1);
      expect(img[2 * 5 + 2], 800, reason: '3x3 亮块腐蚀后剩中心点');
      img[2 * 5 + 2] = 0;
      expect(img.every((v) => v == 0), isTrue, reason: '亮块其余像素被腐蚀');
      // 孤立亮点（1x1）腐蚀后消失。
      final imp = Uint16List(25);
      imp[2 * 5 + 2] = 65535;
      applyMorphology(imp, width: 5, height: 5, radius: 1);
      expect(imp.every((v) => v == 0), isTrue);
    });

    test('腐蚀与膨胀互逆：常量图不变，radius=0 直通', () {
      final flat = Uint16List(16)..fillRange(0, 16, 500);
      applyMorphology(flat, width: 4, height: 4, radius: 2);
      expect(flat.every((v) => v == 500), isTrue, reason: '常量图腐蚀不变');
      applyMorphology(flat, width: 4, height: 4, erode: false, radius: 2);
      expect(flat.every((v) => v == 500), isTrue, reason: '常量图膨胀不变');
      final img = Uint16List.fromList([1, 2, 3, 4]);
      applyMorphology(img, width: 2, height: 2, radius: 0);
      expect(img, [1, 2, 3, 4], reason: 'radius=0 不处理');
    });

    test('RGB 三通道独立取极值', () {
      // 2x1 RGB：左像素 R 亮，右像素 G 亮；radius=1 膨胀后两像素
      // R、G 都取到各自通道极大值，B 仍为 0（通道间不串扰）。
      final rgb = Uint16List.fromList([900, 0, 0, 0, 700, 0]);
      applyMorphology(rgb,
          width: 2, height: 1, channels: 3, erode: false, radius: 1);
      expect(rgb, [900, 700, 0, 900, 700, 0]);
      // 腐蚀则取各通道极小值（均为 0）。
      final rgb2 = Uint16List.fromList([900, 0, 0, 0, 700, 0]);
      applyMorphology(rgb2,
          width: 2, height: 1, channels: 3, radius: 1);
      expect(rgb2, [0, 0, 0, 0, 0, 0]);
    });
  });
}
