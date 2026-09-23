/// Dart↔C 对拍：unpack 组 —— RAW 位流解包 + 帧字节数计算。
///
/// C 侧：test/c_ref/harness_unpack.c `op_unpack` ->
/// lib/modules/isp_studio/c_ref/isp_unpack.c
/// （isp_unpack_bayer / isp_frame_byte_size）。
/// Dart 侧基准：lib/modules/isp_studio/pipeline/isp_kernels.dart
/// `unpackBayer` / `frameByteSize`（直接调真实实现）。
///
/// 覆盖：
/// - unpackedLsb/unpackedMsb × 8/10/12/16 位 × LE/BE 合法组合；
/// - MIPI 10/12 打包字节流（Dart 侧按打包公式手工构造原始字节）；
/// - byte_offset 切帧（多帧拼接缓冲取第 1 帧，unpacked 与 MIPI 各一）；
/// - 小图 4x2、极值帧（全 0 / 全 maxValue / 渐变角点）；
/// - frame_byte_size 标量与 Dart frameByteSize 一致（含 size_only 的
///   取整公式用例与非法组合的负错误码）。
library;

import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const String _tag = '_grp_unpack';

// ---------------------------------------------------------------------------
// Dart 侧打包构造（unpackBayer 的逆操作，按 isp_kernels.dart 注释的格式公式）
// ---------------------------------------------------------------------------

/// 把 u16 像素帧打包为 unpacked 字节流（每像素固定 2 字节）。
///
/// [msb] 为 true 时左对齐（value << (16-bitDepth)），并在低位掺入确定性
/// 垃圾位（解包时应被 >> 丢弃，检验 C 侧没有误读低位）；false 时右对齐。
Uint8List packUnpacked(Uint16List pixels, int bitDepth,
    {required bool littleEndian, required bool msb}) {
  final out = Uint8List(pixels.length * 2);
  var state = 0x12345678;
  for (var i = 0; i < pixels.length; i++) {
    var raw = msb ? pixels[i] << (16 - bitDepth) : pixels[i];
    if (msb && bitDepth < 16) {
      // 低位掺垃圾（LCG 低 shift 位），unpackBayer 的 MSB 分支应将其丢弃。
      state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
      raw |= state & ((1 << (16 - bitDepth)) - 1);
    }
    if (littleEndian) {
      out[i * 2] = raw & 0xFF;
      out[i * 2 + 1] = (raw >> 8) & 0xFF;
    } else {
      out[i * 2] = (raw >> 8) & 0xFF;
      out[i * 2 + 1] = raw & 0xFF;
    }
  }
  return out;
}

/// MIPI 10bit 打包：4 像素 5 字节，第 5 字节 bits[2i,2i+1] 为像素 i 低 2 位。
Uint8List packMipi10(Uint16List pixels) {
  assert(pixels.length % 4 == 0);
  final out = Uint8List(pixels.length ~/ 4 * 5);
  var p = 0, o = 0;
  while (o < pixels.length) {
    var lsb = 0;
    for (var i = 0; i < 4; i++) {
      final v = pixels[o++];
      out[p + i] = (v >> 2) & 0xFF;
      lsb |= (v & 0x3) << (2 * i);
    }
    out[p + 4] = lsb;
    p += 5;
  }
  return out;
}

/// MIPI 12bit 打包：2 像素 3 字节，p0=b0:b2[3:0]，p1=b1:b2[7:4]。
Uint8List packMipi12(Uint16List pixels) {
  assert(pixels.length % 2 == 0);
  final out = Uint8List(pixels.length ~/ 2 * 3);
  var p = 0, o = 0;
  while (o < pixels.length) {
    final v0 = pixels[o++];
    final v1 = pixels[o++];
    out[p] = (v0 >> 4) & 0xFF;
    out[p + 1] = (v1 >> 4) & 0xFF;
    out[p + 2] = ((v0 & 0xF) | ((v1 & 0xF) << 4)) & 0xFF;
    p += 3;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 公共驱动
// ---------------------------------------------------------------------------

/// 跑一个 unpack 用例：C 解包结果 + frame_byte_size 标量 与 Dart 基准比对。
Future<void> checkUnpack(String context, Uint8List bytes,
    {required int width,
    required int height,
    required int bitDepth,
    required BayerPacking packing,
    bool littleEndian = true,
    int byteOffset = 0}) async {
  final c = await runCOp('unpack', params: {
    'width': width,
    'height': height,
    'bit_depth': bitDepth,
    'packing': packing.name, // 字符串形态（unpackedLsb/unpackedMsb/mipi）
    'little_endian': littleEndian,
    'byte_offset': byteOffset,
    'raw_len': bytes.length,
  }, inRaw: bytes, tag: _tag);
  final expected = unpackBayer(bytes,
      width: width,
      height: height,
      bitDepth: bitDepth,
      packing: packing,
      littleEndian: littleEndian,
      byteOffset: byteOffset);
  expectFramesEqual(c.outputs[0], expected, context: context);
  // frame_byte_size 标量与 Dart frameByteSize 一致。
  expect(c.scalars['frame_byte_size'],
      frameByteSize(width: width, height: height, bitDepth: bitDepth, packing: packing).toDouble(),
      reason: '$context: frame_byte_size 标量');
}

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: _tag);

  group('isp_c_ref_compare_unpack: unpack C↔Dart 对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    test('unpackedLsb 10bit LE 64x48 lcg', () async {
      const w = 64, h = 48, bd = 10;
      final px = lcgFrame(w, h, 1, 11, maxValue: 1023);
      await checkUnpack(
          'lsb10-le', packUnpacked(px, bd, littleEndian: true, msb: false),
          width: w, height: h, bitDepth: bd, packing: BayerPacking.unpackedLsb);
    });

    test('unpackedLsb 8bit BE 32x24 lcg', () async {
      const w = 32, h = 24, bd = 8;
      final px = lcgFrame(w, h, 1, 12, maxValue: 255);
      await checkUnpack(
          'lsb8-be', packUnpacked(px, bd, littleEndian: false, msb: false),
          width: w,
          height: h,
          bitDepth: bd,
          packing: BayerPacking.unpackedLsb,
          littleEndian: false);
    });

    test('unpackedMsb 12bit LE 16x16（低位掺垃圾应被丢弃）', () async {
      const w = 16, h = 16, bd = 12;
      final px = lcgFrame(w, h, 1, 13, maxValue: 4095);
      await checkUnpack(
          'msb12-le', packUnpacked(px, bd, littleEndian: true, msb: true),
          width: w, height: h, bitDepth: bd, packing: BayerPacking.unpackedMsb);
    });

    test('unpackedMsb 16bit BE 8x8 渐变（shift=0，含 0/65535 角点）', () async {
      const w = 8, h = 8, bd = 16;
      final px = gradientFrame(w, h, 1, maxValue: 65535);
      await checkUnpack(
          'msb16-be', packUnpacked(px, bd, littleEndian: false, msb: true),
          width: w,
          height: h,
          bitDepth: bd,
          packing: BayerPacking.unpackedMsb,
          littleEndian: false);
    });

    test('unpackedLsb 10bit LE 极值帧（全 0 与全 1023）', () async {
      const w = 16, h = 8, bd = 10;
      for (final (tag, v) in [('zero', 0), ('max', 1023)]) {
        final px = constantFrame(w, h, 1, v);
        await checkUnpack(
            'lsb10-$tag', packUnpacked(px, bd, littleEndian: true, msb: false),
            width: w,
            height: h,
            bitDepth: bd,
            packing: BayerPacking.unpackedLsb);
      }
    });

    test('mipi10 64x48 lcg（手工打包）', () async {
      const w = 64, h = 48;
      final px = lcgFrame(w, h, 1, 14, maxValue: 1023);
      await checkUnpack('mipi10', packMipi10(px),
          width: w, height: h, bitDepth: 10, packing: BayerPacking.mipi);
    });

    test('mipi10 32x16 渐变（含 0/1023 角点）', () async {
      const w = 32, h = 16;
      final px = gradientFrame(w, h, 1, maxValue: 1023);
      await checkUnpack('mipi10-grad', packMipi10(px),
          width: w, height: h, bitDepth: 10, packing: BayerPacking.mipi);
    });

    test('mipi12 32x24 lcg（手工打包）', () async {
      const w = 32, h = 24;
      final px = lcgFrame(w, h, 1, 15, maxValue: 4095);
      await checkUnpack('mipi12', packMipi12(px),
          width: w, height: h, bitDepth: 12, packing: BayerPacking.mipi);
    });

    test('mipi12 16x8 极值帧（全 0 与全 4095）', () async {
      const w = 16, h = 8;
      for (final (tag, v) in [('zero', 0), ('max', 4095)]) {
        final px = constantFrame(w, h, 1, v);
        await checkUnpack('mipi12-$tag', packMipi12(px),
            width: w, height: h, bitDepth: 12, packing: BayerPacking.mipi);
      }
    });

    test('byte_offset 切帧：两帧 unpackedLsb 10bit 拼接取第 1 帧', () async {
      const w = 32, h = 24, bd = 10;
      final px0 = lcgFrame(w, h, 1, 16, maxValue: 1023);
      final px1 = lcgFrame(w, h, 1, 17, maxValue: 1023);
      final b0 = packUnpacked(px0, bd, littleEndian: true, msb: false);
      final b1 = packUnpacked(px1, bd, littleEndian: true, msb: false);
      final buf = Uint8List.fromList([...b0, ...b1]);
      await checkUnpack('offset-unpacked', buf,
          width: w,
          height: h,
          bitDepth: bd,
          packing: BayerPacking.unpackedLsb,
          byteOffset: b0.length);
    });

    test('byte_offset 切帧：两帧 mipi12 拼接取第 1 帧', () async {
      const w = 16, h = 12;
      final px0 = lcgFrame(w, h, 1, 18, maxValue: 4095);
      final px1 = lcgFrame(w, h, 1, 19, maxValue: 4095);
      final b0 = packMipi12(px0);
      final b1 = packMipi12(px1);
      final buf = Uint8List.fromList([...b0, ...b1]);
      await checkUnpack('offset-mipi12', buf,
          width: w,
          height: h,
          bitDepth: 12,
          packing: BayerPacking.mipi,
          byteOffset: b0.length);
    });

    test('小图 4x2：unpackedLsb/mipi10/mipi12', () async {
      const w = 4, h = 2;
      final px10 = lcgFrame(w, h, 1, 20, maxValue: 1023);
      await checkUnpack(
          '4x2-lsb10', packUnpacked(px10, 10, littleEndian: true, msb: false),
          width: w, height: h, bitDepth: 10, packing: BayerPacking.unpackedLsb);
      await checkUnpack('4x2-mipi10', packMipi10(px10),
          width: w, height: h, bitDepth: 10, packing: BayerPacking.mipi);
      final px12 = lcgFrame(w, h, 1, 21, maxValue: 4095);
      await checkUnpack('4x2-mipi12', packMipi12(px12),
          width: w, height: h, bitDepth: 12, packing: BayerPacking.mipi);
    });

    test('packing 枚举整数形态（0=unpackedLsb）', () async {
      const w = 8, h = 4, bd = 10;
      final px = lcgFrame(w, h, 1, 22, maxValue: 1023);
      final bytes = packUnpacked(px, bd, littleEndian: true, msb: false);
      final c = await runCOp('unpack', params: {
        'width': w,
        'height': h,
        'bit_depth': bd,
        'packing': 0, // 枚举整数形态
        'little_endian': true,
        'raw_len': bytes.length,
      }, inRaw: bytes, tag: _tag);
      expectFramesEqual(
          c.outputs[0],
          unpackBayer(bytes,
              width: w,
              height: h,
              bitDepth: bd,
              packing: BayerPacking.unpackedLsb),
          context: 'packing-int');
    });

    test('frame_byte_size 取整公式（size_only，pixels 非整组）', () async {
      // mipi10：30 像素（%4!=0，无法成功解包，仅验证字节数取整公式）
      // (30*5+3)~/4 = 38；mipi12：15 像素 (15*3+1)~/2 = 23。
      for (final (w, h, bd, packing, expected) in [
        (6, 5, 10, 'mipi', 38),
        (5, 3, 12, 'mipi', 23),
        (7, 3, 10, 'unpackedLsb', 42), // pixels*2，与位深无关
        (7, 3, 8, 'unpackedMsb', 42),
      ]) {
        final c = await runCOp('unpack', params: {
          'width': w,
          'height': h,
          'bit_depth': bd,
          'packing': packing,
          'size_only': 1,
        }, outputCount: 0, tag: _tag);
        expect(c.scalars['frame_byte_size'], expected.toDouble(),
            reason: 'size_only ${w}x$h ${bd}bit $packing');
        expect(
            frameByteSize(
                width: w,
                height: h,
                bitDepth: bd,
                packing: packing == 'mipi'
                    ? BayerPacking.mipi
                    : (packing == 'unpackedLsb'
                        ? BayerPacking.unpackedLsb
                        : BayerPacking.unpackedMsb)),
            expected,
            reason: 'Dart 基准自洽 ${w}x$h ${bd}bit $packing');
      }
    });

    test('frame_byte_size 非法组合（mipi 8bit）返回负错误码', () async {
      // Dart frameByteSize 对 MIPI 非 10/12 位深抛 ArgumentError；
      // C isp_frame_byte_size 返回 ISP_ERR_UNSUPPORTED(-3)。
      expect(
          () => frameByteSize(
              width: 8, height: 4, bitDepth: 8, packing: BayerPacking.mipi),
          throwsArgumentError);
      final c = await runCOp('unpack', params: {
        'width': 8,
        'height': 4,
        'bit_depth': 8,
        'packing': 'mipi',
        'size_only': 1,
      }, outputCount: 0, tag: _tag);
      expect(c.scalars['frame_byte_size'], -3.0,
          reason: 'mipi 8bit 应为 ISP_ERR_UNSUPPORTED(-3)');
    });
  });
}
