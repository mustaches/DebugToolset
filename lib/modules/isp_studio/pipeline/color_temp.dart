/// 色温调节器（color_temp_adjuster）的色温模型与测量。
///
/// 纯 Dart，无 Flutter 依赖，可在后台 isolate 中运行。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 色温值域（开尔文）：滑块与测量的合法范围。
const int kColorTempMin = 1800;
const int kColorTempMax = 12000;

/// 默认目标色温（D65 日光）。
const double kColorTempDefault = 6500;

/// 色温 → 归一化 RGB 白点（G 通道恒为 1）。
///
/// 采用 Tanner Helland 黑体辐射近似（适用 1000K~40000K，覆盖本节点的
/// 1800~12000 范围），再把 8 位白点归一化到 G=1：返回值即「该色温
/// 光源下白色物体呈现的 R/G/B 相对强度」。R 随色温降低（暖）增大，
/// B 随色温升高（冷）增大。
List<double> cctToWhitePoint(int cct) {
  final t = cct.clamp(kColorTempMin, kColorTempMax) / 100.0;
  // 8 位白点近似公式（Tanner Helland）。
  final r = t <= 66 ? 255.0 : 329.698727446 * math.pow(t - 60, -0.1332047592);
  final g = t <= 66
      ? 99.4708025861 * math.log(t) - 161.1195681661
      : 288.1221695283 * math.pow(t - 60, -0.0755148492);
  final b = t >= 66
      ? 255.0
      : (t <= 19 ? 0.0 : 138.5177312231 * math.log(t - 10) - 305.0447927307);
  final gc = g.clamp(1.0, 255.0); // 防除零；正常范围 g≈177~255
  return [
    (r.clamp(0.0, 255.0)) / gc,
    1.0,
    (b.clamp(0.0, 255.0)) / gc,
  ];
}

/// 由「参考（基准）色温 → 目标色温」计算 RGB 通道增益（von Kries 对角
/// 模型）：gain[c] = white(target)[c] / white(reference)[c]。
/// target == reference 时三通道增益恰为 1（恒等）。参考色温 <= 0 时
/// 按默认 6500K 处理（未设定基准时滑块相对 D65 调节）。
List<double> colorTempGains(double targetCct, int referenceCct) {
  final wt = cctToWhitePoint(targetCct.round().clamp(kColorTempMin, kColorTempMax));
  final wr = cctToWhitePoint(
      referenceCct > 0 ? referenceCct : kColorTempDefault.round());
  return [wt[0] / wr[0], 1.0, wt[2] / wr[2]];
}

/// 由增益组成 3x3 CCM（对角阵，行优先）。
List<double> colorTempCcm(List<double> gains) => [
      gains[0], 0, 0, //
      0, gains[1], 0, //
      0, 0, gains[2],
    ];

/// 从 RGBA8888 帧估计色温（开尔文）。
///
/// 步长抽样取平均 RGB（压到 ~百级像素开销），经 sRGB→XYZ 矩阵求色度
/// (x, y)，再用 McCamy 公式 CCT = 449n³ + 3525n² + 6823.3n + 5520.33
/// （n = (x−0.3320)/(0.1858−y)）估计相关色温，结果钳位到
/// [kColorTempMin, kColorTempMax]。空帧返回 null。
int? measureCctFromRgba(Uint8List rgba, int width, int height) {
  final px = width * height;
  if (px <= 0 || rgba.length < px * 4) return null;
  // 抽样步长：总样本压到约 4096 个。
  final step = math.max(1, math.sqrt(px / 4096).floor());
  var rs = 0.0, gs = 0.0, bs = 0.0, n = 0;
  for (var y = 0; y < height; y += step) {
    for (var x = 0; x < width; x += step) {
      final i = (y * width + x) * 4;
      rs += rgba[i];
      gs += rgba[i + 1];
      bs += rgba[i + 2];
      n++;
    }
  }
  if (n == 0) return null;
  // 平均色（0..1）。
  final r = rs / n / 255, g = gs / n / 255, b = bs / n / 255;
  // sRGB → XYZ（D65）。
  final x0 = 0.4124 * r + 0.3576 * g + 0.1805 * b;
  final y0 = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z0 = 0.0193 * r + 0.1192 * g + 0.9505 * b;
  final sum = x0 + y0 + z0;
  if (sum <= 1e-9) return null; // 全黑帧无法估计
  final cx = x0 / sum, cy = y0 / sum;
  final denom = 0.1858 - cy;
  if (denom.abs() < 1e-6) return null;
  final nn = (cx - 0.3320) / denom;
  final cct = 449 * nn * nn * nn + 3525 * nn * nn + 6823.3 * nn + 5520.33;
  return cct.round().clamp(kColorTempMin, kColorTempMax);
}
