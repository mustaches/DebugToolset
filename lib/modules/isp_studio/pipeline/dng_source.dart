/// DNG（Digital Negative，TIFF/EP 容器）RAW 文件的解析与 Bayer 帧读取。
///
/// 手机 DNG（vivo/小米/Pixel 等，Android Camera2 DngCreator 生成）的
/// 典型结构：RAW 数据直接挂在 IFD0（或 SubIFD 中 PhotometricInterpretation
/// == 32803 的 IFD），16 位容器无压缩存储，按 Strip 组织。本文件只支持
/// 这一形态；压缩（无损 JPEG）、Tile 组织、非 16 位容器的 DNG 抛
/// [StateError]（中文消息）。
///
/// 全部为纯 Dart + dart:io（无 Flutter 依赖），可在后台 isolate 中运行。
library;

import 'dart:io';
import 'dart:typed_data';

/// 路径是否为 .dng 文件（大小写不敏感）。
bool isDngPath(String path) => path.toLowerCase().endsWith('.dng');

/// DNG GainMap 操作码（DNG 1.7 opcode id=9）：图像某区域/相位范围
/// 乘以一个双线性插值的网格增益表，手机 DNG 里用于逐 Bayer 相位的
/// 镜头阴影校正（LSC）——典型形态是 4 个操作码分别覆盖 2x2 相位
/// （Top/Left 选相位、RowPitch=ColPitch=2），各带一张 MapPointsV x
/// MapPointsH 的增益网格。
class DngGainMap {
  /// 作用区域（像素坐标，[top, bottom) x [left, right)）。
  final int top, left, bottom, right;

  /// 行/列步进：只有 (y - top) % rowPitch == 0 且
  /// (x - left) % colPitch == 0 的像素被该表作用（Bayer 相位选择）。
  final int rowPitch, colPitch;

  /// 网格点数（垂直 x 水平）。
  final int pointsV, pointsH;

  /// 网点间距/原点（相对整幅图像的 0..1 坐标）。
  final double spacingV, spacingH, originV, originH;

  /// 增益表，行主序 pointsV x pointsH。
  final Float32List gains;

  const DngGainMap({
    required this.top,
    required this.left,
    required this.bottom,
    required this.right,
    required this.rowPitch,
    required this.colPitch,
    required this.pointsV,
    required this.pointsH,
    required this.spacingV,
    required this.spacingH,
    required this.originV,
    required this.originH,
    required this.gains,
  });

  /// 像素 (x, y) 处的双线性插值增益（坐标转相对整幅图像的 0..1）。
  double gainAt(int x, int y, int width, int height) {
    final gy =
        ((y / height - originV) / spacingV).clamp(0.0, pointsV - 1.0);
    final gx =
        ((x / width - originH) / spacingH).clamp(0.0, pointsH - 1.0);
    final i = gy.floor();
    final j = gx.floor();
    final fy = gy - i;
    final fx = gx - j;
    final i1 = i + 1 >= pointsV ? i : i + 1;
    final j1 = j + 1 >= pointsH ? j : j + 1;
    final g00 = gains[i * pointsH + j];
    final g01 = gains[i * pointsH + j1];
    final g10 = gains[i1 * pointsH + j];
    final g11 = gains[i1 * pointsH + j1];
    return (g00 * (1 - fx) + g01 * fx) * (1 - fy) +
        (g10 * (1 - fx) + g11 * fx) * fy;
  }
}

/// DNG WarpRectilinear 操作码（id=1）：径向畸变校正参数
/// （每平面 kr0..kr3 + 中心 cx,cy；vivo 会多写 2 个 double，忽略）。
/// 几何畸变校正在去马赛克后按 RGB 重采样才正确，目前只解析不应用。
class DngWarpRectilinear {
  final int planes;

  /// 每平面参数 [kr0, kr1, kr2, kr3, cx, cy]。
  final List<List<double>> perPlane;

  const DngWarpRectilinear(this.planes, this.perPlane);

  /// 是否恒等（kr0=1 且径向系数全 0，无需任何几何校正）。
  bool get isIdentity => perPlane.every((p) =>
      p.isNotEmpty &&
      p[0] == 1.0 &&
      p.sublist(1, 4).every((v) => v == 0.0));
}

/// 按 [maps] 对 Bayer 马赛克帧 [mosaic]（原地修改）应用网格 LSC。
/// [blackLevels] 非空时按 2x2 相位先减黑电平再乘增益、最后加回
/// （DNG 语义上 GainMap 作用于去黑电平后的线性数据；加回是为了让
/// 下游黑电平校正节点行为不变）。结果截位到 [0, whiteLevel]。
void applyDngGainMaps(
  Uint16List mosaic,
  int width,
  int height,
  List<DngGainMap> maps, {
  List<double>? blackLevels,
  required int whiteLevel,
}) {
  for (final map in maps) {
    final maxI = map.pointsV - 1.0;
    final maxJ = map.pointsH - 1.0;
    for (var y = map.top; y < map.bottom && y < height; y += map.rowPitch) {
      // 行级预计算：垂直方向的插值系数与两行网点基址。
      final gy =
          ((y / height - map.originV) / map.spacingV).clamp(0.0, maxI);
      final i = gy.floor();
      final fy = gy - i;
      final i1 = i + 1 >= map.pointsV ? i : i + 1;
      final rowA = i * map.pointsH;
      final rowB = i1 * map.pointsH;
      final rowBase = y * width;
      final blRow = y & 1;
      for (var x = map.left; x < map.right && x < width; x += map.colPitch) {
        final gx =
            ((x / width - map.originH) / map.spacingH).clamp(0.0, maxJ);
        final j = gx.floor();
        final fx = gx - j;
        final j1 = j + 1 >= map.pointsH ? j : j + 1;
        final g = (map.gains[rowA + j] * (1 - fx) +
                    map.gains[rowA + j1] * fx) *
                (1 - fy) +
            (map.gains[rowB + j] * (1 - fx) + map.gains[rowB + j1] * fx) *
                fy;
        final idx = rowBase + x;
        final v = mosaic[idx];
        final double out;
        if (blackLevels != null) {
          final bl = blackLevels[blRow * 2 + (x & 1)];
          out = (v - bl) * g + bl;
        } else {
          out = v * g;
        }
        mosaic[idx] = out <= 0
            ? 0
            : out >= whiteLevel
                ? whiteLevel
                : out.round();
      }
    }
  }
}

/// DNG RAW 数据的元信息。
class DngInfo {
  /// Bayer 帧尺寸（RAW IFD 的 ImageWidth/ImageLength）。
  final int width;
  final int height;

  /// 存储位深（只支持 16 位容器）。
  final int bitsPerSample;

  /// 饱和白电平（WhiteLevel 标签；缺省为存储位深满值）。
  final int whiteLevel;

  /// 有效位深：由 [whiteLevel] 推断（1023→10、4095→12、16383→14）。
  final int bitDepth;

  /// Bayer 排列名（'RGGB'/'BGGR'/'GRBG'/'GBRG'），由 CFAPattern 映射。
  final String? cfaPattern;

  /// CFA 各相位颜色（2x2 行主序，0=R 1=G 2=B），黑电平相位映射用。
  final List<int>? cfaColors;

  /// 2x2 相位黑电平（行主序，与 [cfaColors] 同序）；无该标签时为 null。
  final List<double>? blackLevels;

  /// 文件字节序（像素数据按此读取）。
  final bool littleEndian;

  /// Strip 组织：各条带偏移与字节数，每条带 [rowsPerStrip] 行。
  final List<int> stripOffsets;
  final List<int> stripByteCounts;
  final int rowsPerStrip;

  /// 镜头阴影校正网格（GainMap 操作码，Bayer 通常每相位一张）。
  final List<DngGainMap> gainMaps;

  /// 镜头畸变校正参数（WarpRectilinear 操作码）；目前只解析不应用。
  final DngWarpRectilinear? warp;

  const DngInfo({
    required this.width,
    required this.height,
    required this.bitsPerSample,
    required this.whiteLevel,
    required this.bitDepth,
    required this.littleEndian,
    required this.stripOffsets,
    required this.stripByteCounts,
    required this.rowsPerStrip,
    this.cfaPattern,
    this.cfaColors,
    this.blackLevels,
    this.gainMaps = const [],
    this.warp,
  });
}

/// TIFF 标签类型的字节宽度。
const _typeSize = {
  1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4,
};

/// IFD 条目解析结果（数值列表；RATIONAL 已转 double）。
class _Ifd {
  final Map<int, List<num>> tags;

  /// 各标签值域在文件中的字节范围（offset, length），操作码列表等
  /// 大体积二进制负载用。
  final Map<int, (int, int)> ranges;
  _Ifd(this.tags, this.ranges);
  List<num>? operator [](int tag) => tags[tag];
  int? intOf(int tag) => tags[tag]?.first.toInt();
}

/// 解析一个 IFD，返回 tag → 数值列表。
_Ifd _parseIfd(ByteData d, int offset, Endian endian) {
  final tags = <int, List<num>>{};
  final ranges = <int, (int, int)>{};
  final count = d.getUint16(offset, endian);
  for (var i = 0; i < count; i++) {
    final e = offset + 2 + i * 12;
    final tag = d.getUint16(e, endian);
    final type = d.getUint16(e + 2, endian);
    final n = d.getUint32(e + 4, endian);
    final unit = _typeSize[type];
    if (unit == null || n <= 0) continue;
    final total = unit * n;
    // 值域内联在 4 字节槽位或按偏移寻址。
    final valueOffset = total <= 4 ? e + 8 : d.getUint32(e + 8, endian);
    if (valueOffset < 0 || valueOffset + total > d.lengthInBytes) continue;
    ranges[tag] = (valueOffset, total);
    final values = <num>[];
    for (var k = 0; k < n; k++) {
      final o = valueOffset + k * unit;
      values.add(switch (type) {
        1 || 6 || 7 => d.getUint8(o),
        3 => d.getUint16(o, endian),
        4 || 13 => d.getUint32(o, endian),
        8 => d.getInt16(o, endian),
        9 => d.getInt32(o, endian),
        5 => () {
            final den = d.getUint32(o + 4, endian);
            return den == 0 ? 0.0 : d.getUint32(o, endian) / den;
          }(),
        10 => () {
            final den = d.getInt32(o + 4, endian);
            return den == 0 ? 0.0 : d.getInt32(o, endian) / den;
          }(),
        11 => d.getFloat32(o, endian),
        12 => d.getFloat64(o, endian),
        _ => 0,
      });
    }
    tags[tag] = values;
  }
  return _Ifd(tags, ranges);
}

/// 解析 DNG 操作码列表（OpcodeList1/2/3）的二进制负载。
/// 注意：与 TIFF 主体不同，操作码负载**恒为大端**（DNG 规范）。
/// 目前识别 GainMap(9) 与 WarpRectilinear(1)，其余操作码跳过。
(DngGainMap?, DngWarpRectilinear?) _parseOpcode(
    ByteData d, int offset, int length) {
  final id = d.getUint32(offset, Endian.big);
  final dataLen = d.getUint32(offset + 12, Endian.big);
  final body = offset + 16;
  if (body + dataLen > offset + length) return (null, null);
  if (id == 9) {
    // GainMap（DNG 1.7）：矩形 + Plane/Planes/RowPitch/ColPitch/
    // MapPointsV/MapPointsH（6x u32）+ SpacingV/H、OriginV/H（4x double）
    // + MapPlanes（u32）+ Float32 增益表。
    if (dataLen < 76) return (null, null);
    final top = d.getUint32(body, Endian.big);
    final left = d.getUint32(body + 4, Endian.big);
    final bottom = d.getUint32(body + 8, Endian.big);
    final right = d.getUint32(body + 12, Endian.big);
    final rowPitch = d.getUint32(body + 24, Endian.big);
    final colPitch = d.getUint32(body + 28, Endian.big);
    final pointsV = d.getUint32(body + 32, Endian.big);
    final pointsH = d.getUint32(body + 36, Endian.big);
    final spacingV = d.getFloat64(body + 40, Endian.big);
    final spacingH = d.getFloat64(body + 48, Endian.big);
    final originV = d.getFloat64(body + 56, Endian.big);
    final originH = d.getFloat64(body + 64, Endian.big);
    final mapPlanes = d.getUint32(body + 72, Endian.big);
    final mapCount = pointsV * pointsH * mapPlanes;
    if (rowPitch < 1 ||
        colPitch < 1 ||
        pointsV < 1 ||
        pointsH < 1 ||
        spacingV <= 0 ||
        spacingH <= 0 ||
        76 + mapCount * 4 > dataLen) {
      return (null, null);
    }
    final gains = Float32List(mapCount);
    for (var i = 0; i < mapCount; i++) {
      gains[i] = d.getFloat32(body + 76 + i * 4, Endian.big);
    }
    return (
      DngGainMap(
        top: top,
        left: left,
        bottom: bottom,
        right: right,
        rowPitch: rowPitch,
        colPitch: colPitch,
        pointsV: pointsV,
        pointsH: pointsH,
        spacingV: spacingV,
        spacingH: spacingH,
        originV: originV,
        originH: originH,
        gains: gains,
      ),
      null
    );
  }
  if (id == 1) {
    // WarpRectilinear：planes（u32）+ 每平面若干 double
    // （前 6 个为 kr0..kr3、cx、cy；个别厂商多写，忽略多余部分）。
    if (dataLen < 4) return (null, null);
    final planes = d.getUint32(body, Endian.big);
    if (planes < 1) return (null, null);
    final perPlaneDoubles = (dataLen - 4) ~/ (8 * planes);
    if (perPlaneDoubles < 6) return (null, null);
    final perPlane = <List<double>>[];
    var p = body + 4;
    for (var k = 0; k < planes; k++) {
      final params = <double>[];
      for (var j = 0; j < 6; j++) {
        params.add(d.getFloat64(p, Endian.big));
        p += 8;
      }
      p += (perPlaneDoubles - 6) * 8; // 跳过厂商附加参数
      perPlane.add(params);
    }
    return (null, DngWarpRectilinear(planes, perPlane));
  }
  return (null, null);
}

/// 解析全部操作码列表，返回 (GainMap 列表, WarpRectilinear?)。
(List<DngGainMap>, DngWarpRectilinear?) _parseOpcodeLists(
    ByteData d, _Ifd ifd) {
  final maps = <DngGainMap>[];
  DngWarpRectilinear? warp;
  for (final tag in [51008, 51009, 51022]) {
    final range = ifd.ranges[tag];
    if (range == null || range.$2 < 4) continue;
    final (start, length) = range;
    final count = d.getUint32(start, Endian.big);
    var p = start + 4;
    final end = start + length;
    for (var k = 0; k < count && p + 16 <= end; k++) {
      final dataLen = d.getUint32(p + 12, Endian.big);
      final (map, w) = _parseOpcode(d, p, 16 + dataLen);
      if (map != null) maps.add(map);
      if (w != null) warp = w;
      p += 16 + dataLen;
    }
  }
  return (maps, warp);
}

/// 由 WhiteLevel 推断有效位深（1023→10、4095→12、16383→14、65535→16，
/// 其他值向上取整位数）。
int dngEffectiveBitDepth(int whiteLevel) {
  var bits = 0;
  var v = whiteLevel;
  while (v > 0) {
    bits++;
    v >>= 1;
  }
  return bits.clamp(1, 16);
}

const _bayerNames = {'R,G,G,B': 'RGGB', 'B,G,G,R': 'BGGR', 'G,R,B,G': 'GRBG', 'G,B,R,G': 'GBRG'};

/// 从文件字节中解析 DNG 元信息（纯函数，便于测试）。
/// 找不到 CFA RAW IFD 或格式不支持时抛 [StateError]。
DngInfo parseDngInfo(Uint8List fileBytes) {
  if (fileBytes.length < 8) throw StateError('文件太小，不是有效的 DNG');
  final bo = String.fromCharCodes(fileBytes.sublist(0, 2));
  final Endian endian;
  final bool littleEndian;
  if (bo == 'II') {
    endian = Endian.little;
    littleEndian = true;
  } else if (bo == 'MM') {
    endian = Endian.big;
    littleEndian = false;
  } else {
    throw StateError('不是 TIFF/DNG 文件（缺少 II/MM 头）');
  }
  final d = ByteData.sublistView(fileBytes);
  if (d.getUint16(2, endian) != 42) {
    throw StateError('不是标准 TIFF/DNG 文件（魔数不为 42）');
  }
  final ifd0Offset = d.getUint32(4, endian);
  final ifd0 = _parseIfd(d, ifd0Offset, endian);

  // 选择 CFA RAW 所在的 IFD：优先 IFD0；若 IFD0 不是 CFA（比如主图是
  // JPEG 预览）则沿 SubIFDs 找 PhotometricInterpretation == 32803 的 IFD。
  var raw = ifd0[262]?.first == 32803 ? ifd0 : null;
  if (raw == null) {
    for (final sub in ifd0[330] ?? const <num>[]) {
      final candidate = _parseIfd(d, sub.toInt(), endian);
      if (candidate[262]?.first == 32803) {
        raw = candidate;
        break;
      }
    }
  }
  if (raw == null) throw StateError('DNG 中找不到 CFA（Bayer）RAW 数据');
  final ifd = raw;

  final width = ifd.intOf(256);
  final height = ifd.intOf(257);
  final bitsPerSample = ifd.intOf(258) ?? 16;
  final compression = ifd.intOf(259) ?? 1;
  if (width == null || height == null || width <= 0 || height <= 0) {
    throw StateError('DNG 缺少有效的图像尺寸标签');
  }
  if (compression != 1) {
    throw StateError('暂不支持压缩存储的 DNG（Compression=$compression，如无损 JPEG）');
  }
  if (bitsPerSample != 16) {
    throw StateError('暂不支持 $bitsPerSample 位容器存储的 DNG（仅支持 16 位容器）');
  }

  // CFA 排列：CFARepeatPatternDim(33421) 必须 2x2，CFAPattern(33422)
  // 四相位颜色 0=R 1=G 2=B。
  String? cfaPattern;
  List<int>? cfaColors;
  final dim = ifd[33421];
  final pattern = ifd[33422];
  if (dim != null && pattern != null) {
    if (dim.length < 2 || dim[0] != 2 || dim[1] != 2 || pattern.length < 4) {
      throw StateError('暂不支持非 2x2 的 CFA 排列（${dim.join('x')}）');
    }
    cfaColors = pattern.sublist(0, 4).map((e) => e.toInt()).toList();
    if (cfaColors.any((c) => c < 0 || c > 2)) {
      throw StateError('暂不支持非 RGB 颜色的 CFA（$cfaColors）');
    }
    final key = cfaColors.map((c) => 'RGB'[c]).join(',');
    cfaPattern = _bayerNames[key];
    if (cfaPattern == null) {
      throw StateError('不支持的 Bayer 排列: $key');
    }
  }

  // 黑电平：BlackLevelRepeatDim(50713) + BlackLevel(50714)，
  // 2x2 相位或单值（广播到四相位）。
  List<double>? blackLevels;
  final blDim = ifd[50713];
  final bl = ifd[50714];
  if (bl != null && bl.isNotEmpty) {
    final is2x2 = blDim != null &&
        blDim.length >= 2 &&
        blDim[0] == 2 &&
        blDim[1] == 2 &&
        bl.length >= 4;
    final phase =
        is2x2 ? bl.sublist(0, 4) : [bl.first, bl.first, bl.first, bl.first];
    blackLevels = phase.map((e) => e.toDouble()).toList();
  }

  final whiteLevel = ifd.intOf(50717) ?? ((1 << bitsPerSample) - 1);

  // Strip 组织（暂不支持 Tile：TileOffsets(324)）。
  if (ifd[324] != null) {
    throw StateError('暂不支持 Tile 组织存储的 DNG');
  }
  final stripOffsets = ifd[273]?.map((e) => e.toInt()).toList();
  final stripByteCounts = ifd[279]?.map((e) => e.toInt()).toList();
  if (stripOffsets == null ||
      stripByteCounts == null ||
      stripOffsets.isEmpty ||
      stripOffsets.length != stripByteCounts.length) {
    throw StateError('DNG 缺少有效的 StripOffsets/StripByteCounts');
  }
  final rowsPerStrip = ifd.intOf(278) ?? height;

  // 镜头校正操作码（挂在 IFD0 上；负载恒为大端）。
  final (gainMaps, warp) = _parseOpcodeLists(d, ifd0);

  return DngInfo(
    width: width,
    height: height,
    bitsPerSample: bitsPerSample,
    whiteLevel: whiteLevel,
    bitDepth: dngEffectiveBitDepth(whiteLevel),
    littleEndian: littleEndian,
    stripOffsets: stripOffsets,
    stripByteCounts: stripByteCounts,
    rowsPerStrip: rowsPerStrip,
    cfaPattern: cfaPattern,
    cfaColors: cfaColors,
    blackLevels: blackLevels,
    gainMaps: gainMaps,
    warp: warp,
  );
}

/// 按 [info] 的 Strip 布局从文件字节中拼出一帧并解为 uint16 像素
/// （长度 width*height，按文件字节序读取）。纯函数，便于测试。
Uint16List decodeDngFrameData(Uint8List fileBytes, DngInfo info) {
  final width = info.width;
  final height = info.height;
  final pixels = width * height;
  final d = ByteData.sublistView(fileBytes);
  final endian = info.littleEndian ? Endian.little : Endian.big;
  final out = Uint16List(pixels);
  var dstRow = 0;
  for (var s = 0; s < info.stripOffsets.length; s++) {
    final rows =
        (height - dstRow) < info.rowsPerStrip ? (height - dstRow) : info.rowsPerStrip;
    if (rows <= 0) break;
    var src = info.stripOffsets[s];
    final end = src + info.stripByteCounts[s];
    if (src < 0 || end > fileBytes.length) {
      throw StateError('DNG 条带 $s 越界（偏移 $src，${info.stripByteCounts[s]} 字节）');
    }
    for (var r = 0; r < rows; r++) {
      final rowBase = (dstRow + r) * width;
      for (var x = 0; x < width; x++) {
        out[rowBase + x] = d.getUint16(src, endian);
        src += 2;
      }
    }
    dstRow += rows;
  }
  if (dstRow < height) {
    throw StateError('DNG 条带数据不足（$dstRow/$height 行）');
  }
  return out;
}

/// 读取 DNG 文件头并解析元信息。
Future<DngInfo> readDngInfo(String path) async {
  final file = File(path);
  if (!await file.exists()) throw StateError('DNG 文件不存在: $path');
  return parseDngInfo(await file.readAsBytes());
}

/// 读取 DNG 文件并解出一帧 Bayer 像素（返回元信息与像素数组）。
Future<(DngInfo, Uint16List)> readDngFrame(String path) async {
  final file = File(path);
  if (!await file.exists()) throw StateError('DNG 文件不存在: $path');
  final bytes = await file.readAsBytes();
  final info = parseDngInfo(bytes);
  return (info, decodeDngFrameData(bytes, info));
}
