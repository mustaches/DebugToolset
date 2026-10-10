/// 多段色彩均衡器（multi_band_eq）的拍平段参数键工具。
///
/// 段参数为拍平键 b{i}_h/q/dh/s/l（i 从 0），不进节点参数 spec，由卡片
/// UI 直写 paramValues；读取侧（pipeline_runner）对缺键全部回退恒等默认
/// （h=0、q=2、dh=0、s=1、l=1）。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline/isp_kernels.dart';

/// 段数上限：16（取色器「增加」到上限置灰；GPU shader uBands[24×5] 容量
/// 保留 24 不变——容量大于上限无害，有效段数由 uCount 控制；C 侧
/// ISP_MULTI_BAND_EQ_MAX_BANDS 同步为 16）。
const int kMultiBandEqMaxBands = 16;

/// 每段的拍平键后缀（`b{i}_<suffix>`）。
const List<String> kMultiBandEqBandSuffixes = ['h', 'q', 'dh', 's', 'l'];

/// 删除第 [removeIndex] 段后的参数重排：后续段的拍平键 b{i+1}_* 前移为
/// b{i}_*（源键缺失则目标键移除，保持缺键=恒等默认语义），末段残留键
/// 清除，band_count 减一；sel_band 同步修正（删除选中段回退 0，删除其
/// 之前的段则减一，删除其后的段不变）。返回新映射，不改入参。
Map<String, Object?> reindexBandParams(
    Map<String, Object?> params, int removeIndex, int bandCount) {
  final next = Map<String, Object?>.of(params);
  for (var i = removeIndex; i < bandCount - 1; i++) {
    for (final s in kMultiBandEqBandSuffixes) {
      final from = 'b${i + 1}_$s';
      final to = 'b${i}_$s';
      if (params.containsKey(from)) {
        next[to] = params[from];
      } else {
        next.remove(to);
      }
    }
  }
  // 清除末段残留键。
  for (final s in kMultiBandEqBandSuffixes) {
    next.remove('b${bandCount - 1}_$s');
  }
  next['band_count'] = bandCount - 1;
  final sel = (params['sel_band'] as num?)?.toInt() ?? 0;
  next['sel_band'] =
      sel == removeIndex ? 0 : (sel > removeIndex ? sel - 1 : sel);
  return next;
}

// ---- 色彩风格预设（.colorstyle，JSON 文本）----

/// 预设文件版本号（version 不符拒绝读取）。
const int kColorStyleVersion = 1;

/// 各段字段的数值域（与 runner 读取回退默认一致）：越界读取时 clamp
/// （宽容策略：文件可手改，越界钳位比整份拒绝更友好；结构错误才拒绝）。
const _bandFieldRanges = {
  'h': (0.0, 360.0, 0.0),
  'q': (0.5, 100.0, 2.0),
  'dh': (-180.0, 180.0, 0.0),
  's': (0.0, 5.0, 1.0),
  'l': (0.0, 5.0, 1.0),
};

/// 从节点参数提取当前段配置为预设 JSON 对象（自足文件：缺键按恒等
/// 默认补齐写出）。band_mode 只认 parallel/serial，其余落 parallel。
Map<String, Object?> encodeColorStyle(Map<String, Object?> params) {
  final count = ((params['band_count'] as num?)?.toInt() ?? 1)
      .clamp(1, kMultiBandEqMaxBands)
      .toInt();
  final mode = params['band_mode']?.toString() == 'serial'
      ? 'serial'
      : 'parallel';
  return {
    'version': kColorStyleVersion,
    'band_mode': mode,
    'bands': [
      for (var i = 0; i < count; i++)
        {
          'h': (params['b${i}_h'] as num?)?.toDouble() ?? 0.0,
          'q': (params['b${i}_q'] as num?)?.toDouble() ?? 2.0,
          'dh': (params['b${i}_dh'] as num?)?.toDouble() ?? 0.0,
          's': (params['b${i}_s'] as num?)?.toDouble() ?? 1.0,
          'l': (params['b${i}_l'] as num?)?.toDouble() ?? 1.0,
        },
    ],
  };
}

/// 解析 .colorstyle JSON 文本为参数补丁映射（band_count/band_mode/
/// sel_band=0/各段 b{i}_*，[oldBandCount] 之外的多余旧段键写 null
/// 清除——「缺键=恒等」语义），调用方经 setParams 一次写入。
/// 数值越界 clamp 到定义域（见 [_bandFieldRanges] 注释）；结构错误
/// （非 JSON/顶层非对象/version 不符/段数越界/段非对象）抛
/// [FormatException]。
Map<String, Object?> decodeColorStyle(String jsonText,
    {required int oldBandCount}) {
  final Object? root;
  try {
    root = jsonDecode(jsonText);
  } catch (e) {
    throw FormatException('不是有效的 JSON 文件：$e');
  }
  if (root is! Map) {
    throw const FormatException('预设文件格式错误：顶层应为 JSON 对象');
  }
  final version = (root['version'] as num?)?.toInt();
  if (version != kColorStyleVersion) {
    throw FormatException(
        '预设版本不支持：${root['version']}（当前支持 $kColorStyleVersion）');
  }
  final mode = root['band_mode'];
  if (mode != 'parallel' && mode != 'serial') {
    throw const FormatException('band_mode 应为 parallel 或 serial');
  }
  final bands = root['bands'];
  if (bands is! List ||
      bands.isEmpty ||
      bands.length > kMultiBandEqMaxBands) {
    throw FormatException('段数应为 1..$kMultiBandEqMaxBands');
  }
  double field(Map b, String key) {
    final (min, max, fallback) = _bandFieldRanges[key]!;
    final v = (b[key] as num?)?.toDouble() ?? fallback;
    return v.clamp(min, max).toDouble();
  }

  final next = <String, Object?>{
    'band_count': bands.length,
    'band_mode': mode,
    'sel_band': 0,
  };
  for (var i = 0; i < bands.length; i++) {
    final b = bands[i];
    if (b is! Map) {
      throw FormatException('第 ${i + 1} 段格式错误：应为 JSON 对象');
    }
    for (final s in kMultiBandEqBandSuffixes) {
      next['b${i}_$s'] = field(b, s);
    }
  }
  // 清除多余旧段键（写 null，读取侧按缺键回退恒等默认）。
  for (var i = bands.length; i < oldBandCount; i++) {
    for (final s in kMultiBandEqBandSuffixes) {
      next['b${i}_$s'] = null;
    }
  }
  return next;
}

// ---- 取色器 Q 值自动评估 ----

/// 相位突变阈值：相邻像素色相环差（°）超过该值即判定突变，停止计数。
const double kBandQHueJumpDeg = 15.0;

/// 低饱和阈值：饱和度低于该值的像素色相不稳定，视为相位突变。
const double kBandQMinSaturation = 0.05;

/// 取色器 Q 值自动评估：从 (px,py) 出发沿 8 方向统计色相连续平滑段，
/// 相邻像素色相环差 > [kBandQHueJumpDeg] 或饱和度 < [kBandQMinSaturation]
/// 视为相位突变停止计数；取最长段 d，Q = M/d（M = 图像在该方向的最大
/// 长度：水平=宽、垂直=高、斜向=对角线长），钳位到滑块域 [0.5, 100]。
/// 起始像素本身低饱和（色相无意义）时回退默认 2.0。
/// [rgba] 为 RGBA8 像素（预览图 toByteData rawRgba 口径），色相/饱和度
/// 经 [rgbToHsl]（maxValue: 255）计算，与点击取样同一量化口径。
double estimateBandQ(ByteData rgba, int width, int height, int px, int py) {
  final rgb = Uint16List(3);

  /// (色相°, 饱和度 0..1)。
  (double, double) hslAt(int x, int y) {
    final off = (y * width + x) * 4;
    rgb[0] = rgba.getUint8(off);
    rgb[1] = rgba.getUint8(off + 1);
    rgb[2] = rgba.getUint8(off + 2);
    final hsl = rgbToHsl(rgb, maxValue: 255);
    return (hsl[0] * 360.0 / 255, hsl[1] / 255.0);
  }

  final (h0, s0) = hslAt(px, py);
  if (s0 < kBandQMinSaturation) return 2.0;

  const dirs = [
    (1, 0), (-1, 0), (0, 1), (0, -1), //
    (1, 1), (1, -1), (-1, 1), (-1, -1),
  ];
  final diag = math.sqrt(width * width + height * height).roundToDouble();
  var best = 1;
  var bestM = width.toDouble();
  for (final (dx, dy) in dirs) {
    final m =
        dx == 0 ? height.toDouble() : (dy == 0 ? width.toDouble() : diag);
    var d = 1;
    var prevH = h0;
    var x = px + dx;
    var y = py + dy;
    while (x >= 0 && y >= 0 && x < width && y < height) {
      final (h, s) = hslAt(x, y);
      if (s < kBandQMinSaturation) break;
      final dh = (h - prevH).abs();
      if (math.min(dh, 360.0 - dh) > kBandQHueJumpDeg) break;
      prevH = h;
      d++;
      x += dx;
      y += dy;
    }
    if (d > best) {
      best = d;
      bestM = m;
    }
  }
  return (bestM / best).clamp(0.5, 100.0).toDouble();
}
