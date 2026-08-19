import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/dng_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在内存中构造一个最小合法 DNG（小端 TIFF：IFD0 即 RAW IFD，Strip
/// 组织，16 位容器无压缩，RGGB）。像素值 = 像素序号 % 1024。
/// [gainMapKnots] 非空时附加 OpcodeList2：一个 2x2 网点的 GainMap
/// （pitch=1 覆盖全图，间距 1.0）；[withIdentityWarp] 附加 OpcodeList3：
/// 一个恒等 WarpRectilinear。
Uint8List buildTestDng({
  int width = 4,
  int height = 4,
  int rowsPerStrip = 2,
  int whiteLevel = 1023,
  List<int> cfaColors = const [0, 1, 1, 2],
  List<int> blackLevels = const [64, 64, 64, 64],
  int compression = 1,
  List<double>? gainMapKnots,
  bool withIdentityWarp = false,
}) {
  final stripCount = (height + rowsPerStrip - 1) ~/ rowsPerStrip;
  final hasGainMap = gainMapKnots != null;
  final entryCount = 13 + (hasGainMap ? 1 : 0) + (withIdentityWarp ? 1 : 0);
  const ifdStart = 8;
  final dataStart = ifdStart + 2 + entryCount * 12 + 4;
  var cursor = dataStart;

  // 数据区布局：stripOffsets、stripByteCounts、BlackLevel、操作码、像素。
  final stripOffsetsPos = cursor;
  cursor += stripCount * 4;
  final stripByteCountsPos = cursor;
  cursor += stripCount * 4;
  final blackLevelPos = cursor;
  cursor += 4 * 8;
  // GainMap 负载：count(4) + 头(16) + 矩形(16) + 6x u32(24) +
  // 4x double(32) + mapPlanes(4) + 4x float32(16) = 112。
  final gainMapPos = cursor;
  if (hasGainMap) cursor += 112;
  // Warp 负载：count(4) + 头(16) + planes(4) + 8x double(64) = 88。
  final warpPos = cursor;
  if (withIdentityWarp) cursor += 88;
  final pixelPos = cursor;

  final bytesPerRow = width * 2;
  final stripOffsets = <int>[];
  final stripByteCounts = <int>[];
  var p = pixelPos;
  for (var s = 0; s < stripCount; s++) {
    final rows = (s == stripCount - 1) ? height - s * rowsPerStrip : rowsPerStrip;
    stripOffsets.add(p);
    stripByteCounts.add(rows * bytesPerRow);
    p += rows * bytesPerRow;
  }

  final out = ByteData(p);
  var o = 0;
  void u16(int v) {
    out.setUint16(o, v, Endian.little);
    o += 2;
  }

  void u32(int v) {
    out.setUint32(o, v, Endian.little);
    o += 4;
  }

  // 头：II + 魔数 42 + IFD0 偏移 8。
  out.setUint8(0, 0x49);
  out.setUint8(1, 0x49);
  o = 2;
  u16(42);
  u32(ifdStart);

  void entry(int tag, int type, int count, int valueOrOffset) {
    u16(tag);
    u16(type);
    u32(count);
    u32(valueOrOffset);
  }

  void entryShort2(int tag, int a, int b) {
    u16(tag);
    u16(3);
    u32(2);
    u16(a);
    u16(b);
  }

  o = ifdStart;
  u16(entryCount);
  entry(256, 4, 1, width); // ImageWidth
  entry(257, 4, 1, height); // ImageLength
  entry(258, 3, 1, 16); // BitsPerSample
  entry(259, 3, 1, compression); // Compression
  entry(262, 3, 1, 32803); // PhotometricInterpretation = CFA
  entry(273, 4, stripCount, stripOffsetsPos); // StripOffsets
  entry(278, 4, 1, rowsPerStrip); // RowsPerStrip
  entry(279, 4, stripCount, stripByteCountsPos); // StripByteCounts
  entryShort2(33421, 2, 2); // CFARepeatPatternDim
  entry(33422, 1, 4, // CFAPattern（内联 4 字节）
      cfaColors[0] | (cfaColors[1] << 8) | (cfaColors[2] << 16) | (cfaColors[3] << 24));
  entryShort2(50713, 2, 2); // BlackLevelRepeatDim
  entry(50714, 5, 4, blackLevelPos); // BlackLevel (RATIONALx4)
  entry(50717, 4, 1, whiteLevel); // WhiteLevel
  if (hasGainMap) entry(51009, 7, 112, gainMapPos); // OpcodeList2
  if (withIdentityWarp) entry(51022, 7, 88, warpPos); // OpcodeList3
  u32(0); // 无下一个 IFD

  for (var i = 0; i < stripCount; i++) {
    out.setUint32(stripOffsetsPos + i * 4, stripOffsets[i], Endian.little);
    out.setUint32(stripByteCountsPos + i * 4, stripByteCounts[i], Endian.little);
  }
  for (var i = 0; i < 4; i++) {
    out.setUint32(blackLevelPos + i * 8, blackLevels[i], Endian.little);
    out.setUint32(blackLevelPos + i * 8 + 4, 1, Endian.little);
  }
  if (hasGainMap) {
    // 操作码负载恒为大端。2x2 网点、pitch=1、间距 1.0、原点 0。
    var q = gainMapPos;
    void be32(int v) {
      out.setUint32(q, v, Endian.big);
      q += 4;
    }

    void beF64(double v) {
      out.setFloat64(q, v, Endian.big);
      q += 8;
    }

    be32(1); // 操作码个数
    be32(9); // GainMap
    be32(0x01070000); // DNG 版本 1.7.0.0
    be32(0); // flags
    be32(92); // 数据长度：16+24+32+4+16
    be32(0);
    be32(0); // top, left
    be32(height);
    be32(width); // bottom, right
    be32(0);
    be32(1); // plane, planes
    be32(1);
    be32(1); // rowPitch, colPitch
    be32(2);
    be32(2); // MapPointsV, MapPointsH
    beF64(1.0);
    beF64(1.0); // spacingV/H
    beF64(0.0);
    beF64(0.0); // originV/H
    be32(1); // mapPlanes
    for (final g in gainMapKnots) {
      out.setFloat32(q, g, Endian.big);
      q += 4;
    }
  }
  if (withIdentityWarp) {
    var q = warpPos;
    void be32(int v) {
      out.setUint32(q, v, Endian.big);
      q += 4;
    }

    be32(1); // 操作码个数
    be32(1); // WarpRectilinear
    be32(0x01070000);
    be32(0);
    be32(68); // 数据长度：4 + 8x double（仿 vivo 多写 2 个）
    be32(1); // planes
    final params = [1.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.0, 0.0];
    for (final v in params) {
      out.setFloat64(q, v, Endian.big);
      q += 8;
    }
  }
  for (var i = 0; i < width * height; i++) {
    out.setUint16(pixelPos + i * 2, i % (whiteLevel + 1), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Windows 上刚关闭的文件句柄删除时可能短暂被占用，重试几次。
Future<void> deleteQuietly(File f) async {
  for (var i = 0; i < 5; i++) {
    try {
      await f.delete();
      return;
    } on PathAccessException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  group('parseDngInfo', () {
    test('解析尺寸/位深/排列/黑电平/条带布局', () {
      final info = parseDngInfo(buildTestDng());
      expect(info.width, 4);
      expect(info.height, 4);
      expect(info.bitsPerSample, 16);
      expect(info.whiteLevel, 1023);
      expect(info.bitDepth, 10); // 由 WhiteLevel=1023 推断
      expect(info.cfaPattern, 'RGGB');
      expect(info.cfaColors, [0, 1, 1, 2]);
      expect(info.blackLevels, [64.0, 64.0, 64.0, 64.0]);
      expect(info.littleEndian, isTrue);
      expect(info.rowsPerStrip, 2);
      expect(info.stripOffsets.length, 2);
    });

    test('非 TIFF 文件抛 StateError', () {
      expect(() => parseDngInfo(Uint8List.fromList(List.filled(64, 0))),
          throwsStateError);
    });

    test('压缩存储的 DNG 抛 StateError', () {
      expect(() => parseDngInfo(buildTestDng(compression: 7)),
          throwsStateError);
    });
  });

  group('decodeDngFrameData', () {
    test('按条带拼出完整 Bayer 帧', () {
      final bytes = buildTestDng();
      final info = parseDngInfo(bytes);
      final frame = decodeDngFrameData(bytes, info);
      expect(frame.length, 16);
      for (var i = 0; i < 16; i++) {
        expect(frame[i], i);
      }
    });
  });

  group('镜头校正操作码', () {
    test('解析 GainMap 网格参数与增益表', () {
      final info = parseDngInfo(buildTestDng(
          gainMapKnots: [1.0, 2.0, 3.0, 4.0], blackLevels: [0, 0, 0, 0]));
      expect(info.gainMaps.length, 1);
      final map = info.gainMaps.first;
      expect((map.top, map.left, map.bottom, map.right), (0, 0, 4, 4));
      expect((map.rowPitch, map.colPitch), (1, 1));
      expect((map.pointsV, map.pointsH), (2, 2));
      expect((map.spacingV, map.spacingH), (1.0, 1.0));
      expect(map.gains, [1.0, 2.0, 3.0, 4.0]);
    });

    test('解析恒等 WarpRectilinear', () {
      final info = parseDngInfo(buildTestDng(withIdentityWarp: true));
      expect(info.warp, isNotNull);
      expect(info.warp!.planes, 1);
      expect(info.warp!.isIdentity, isTrue);
    });

    test('applyDngGainMaps 双线性插值并截位', () {
      // 4x4 帧，像素值 = 序号；2x2 网点 [1,2,3,4]（行主序）。
      final mosaic = Uint16List.fromList(List.generate(16, (i) => i));
      final info = parseDngInfo(buildTestDng(
          gainMapKnots: [1.0, 2.0, 3.0, 4.0], blackLevels: [0, 0, 0, 0]));
      applyDngGainMaps(mosaic, 4, 4, info.gainMaps,
          blackLevels: info.blackLevels, whiteLevel: info.whiteLevel);
      // (0,0)：增益 1.0 → 0；(1,1)：增益 1.75，5*1.75=8.75 → 9；
      // (3,3)：增益 3.25，15*3.25=48.75 → 49。
      expect(mosaic[0], 0);
      expect(mosaic[5], 9);
      expect(mosaic[15], 49);
    });

    test('黑电平补偿：减黑电平→乘增益→加回', () {
      final mosaic = Uint16List.fromList(List.generate(16, (i) => 100 + i));
      final info = parseDngInfo(buildTestDng(
          gainMapKnots: [2.0, 2.0, 2.0, 2.0], blackLevels: [64, 64, 64, 64]));
      applyDngGainMaps(mosaic, 4, 4, info.gainMaps,
          blackLevels: info.blackLevels, whiteLevel: info.whiteLevel);
      // 均匀增益 2.0：(100-64)*2+64 = 136；(101-64)*2+64 = 138。
      expect(mosaic[0], 136);
      expect(mosaic[1], 138);
    });

    test('runChainFrame 解码 DNG 时自动应用 GainMap', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_dng_lsc_${DateTime.now().microsecondsSinceEpoch}.dng');
      await tmp.writeAsBytes(buildTestDng(
          gainMapKnots: [2.0, 2.0, 2.0, 2.0], blackLevels: [0, 0, 0, 0]));
      try {
        List<int>? srcOut;
        final chain = <Map<String, Object?>>[
          {
            'typeId': 'bayer_source',
            'nodeId': 'src',
            'params': {
              'filePath': tmp.path,
              'width': 4,
              'height': 4,
              'bitDepth': '10',
              'packing': 'unpacked_lsb',
              'bayerPattern': 'RGGB',
              'littleEndian': true,
              'frameIndex': 0,
            }
          },
          {
            'typeId': 'demosaic',
            'nodeId': 'dm',
            'params': {'algorithm': 'bilinear'}
          },
        ];
        await runChainFrame(chain, 0,
            onNodeOutput: (nodeId, data, format, width, height) {
          if (nodeId == 'src') srcOut = List<int>.of(data);
        });
        // 源节点输出已翻倍（均匀增益 2.0，黑电平 0）。
        expect(srcOut, isNotNull);
        expect(srcOut![0], 0);
        expect(srcOut![5], 10);
        expect(srcOut![15], 30);
      } finally {
        await deleteQuietly(tmp);
      }
    });
  });

  group('DNG 接入流水线', () {
    test('sourceFrameCount 恒为 1，runChainFrame 端到端出图', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_dng_test_${DateTime.now().microsecondsSinceEpoch}.dng');
      await tmp.writeAsBytes(buildTestDng());
      try {
        final params = <String, Object?>{
          'filePath': tmp.path,
          // 参数故意留错：DNG 路径下应以文件头为准。
          'width': 2,
          'height': 2,
          'bitDepth': '8',
          'packing': 'unpacked_lsb',
          'bayerPattern': 'RGGB',
          'littleEndian': true,
          'frameIndex': 0,
        };
        expect(await sourceFrameCount('bayer_source', params), 1);

        final chain = <Map<String, Object?>>[
          {'typeId': 'bayer_source', 'nodeId': 'src', 'params': params},
          {
            'typeId': 'demosaic',
            'nodeId': 'dm',
            'params': {'algorithm': 'bilinear'}
          },
          {'typeId': 'preview', 'nodeId': 'pv', 'params': <String, Object?>{}},
        ];
        final rgba = await runChainFrame(chain, 0);
        expect(rgba.length, 4 * 4 * 4);
        expect(rgba[3], 255); // alpha
      } finally {
        await deleteQuietly(tmp);
      }
    });

    test('DNG 只有一帧，第二帧抛 StateError', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_dng_test2_${DateTime.now().microsecondsSinceEpoch}.dng');
      await tmp.writeAsBytes(buildTestDng());
      try {
        final chain = <Map<String, Object?>>[
          {
            'typeId': 'bayer_source',
            'params': {
              'filePath': tmp.path,
              'width': 4,
              'height': 4,
              'bitDepth': '10',
              'packing': 'unpacked_lsb',
              'bayerPattern': 'RGGB',
              'littleEndian': true,
              'frameIndex': 0,
            }
          },
          {
            'typeId': 'demosaic',
            'params': {'algorithm': 'bilinear'}
          },
        ];
        expect(() => runChainFrame(chain, 1), throwsStateError);
      } finally {
        await deleteQuietly(tmp);
      }
    });
  });
}
