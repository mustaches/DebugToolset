/// 曲线调节器（levels_curves）的传递函数模型：控制点 + 可选的曲线生成
/// 公式（单调三次样条 / 贝塞尔曲线 / 线段）。
///
/// 纯 Dart，无 Flutter 依赖，可在后台 isolate 中运行。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 曲线值域：固定 0..4095（12bit 满量程）。端点为 A1(0,0) 与
/// C1(4095,4095)，用户在其间加入控制点 Bn；应用到帧时按帧 maxValue
/// 线性缩放到该域。
const int kLevelsMax = 4095;

/// 曲线生成公式（节点参数 `curveMode`）。
enum LevelsCurveMode {
  /// Fritsch–Carlson 单调三次样条（默认）：平滑且单调，段内无过冲。
  spline,

  /// 贝塞尔曲线：控制点整体作为贝塞尔控制多边形，De Casteljau 求值。
  /// 曲线过首尾端点，中间控制点牵引形状但不一定经过。
  bezier,

  /// 线段法：控制点间直线连接，不做平滑处理。
  linear,

  /// gamma 曲线：y = max·(x/max)^(1/γ)。只允许一个控制点，控制点落
  /// 在曲线上（拖动它即调整 γ，γ 由点位置反解）。
  gamma,
}

/// 从节点参数还原曲线生成公式（缺失/未知值回退默认样条）。
LevelsCurveMode levelsCurveModeFromParam(Object? raw) => switch (raw) {
      'bezier' => LevelsCurveMode.bezier,
      'linear' => LevelsCurveMode.linear,
      'gamma' => LevelsCurveMode.gamma,
      _ => LevelsCurveMode.spline,
    };

/// gamma 曲线求值：y = max·(x/max)^(1/γ)。γ = 1 为恒等；γ > 1 提亮
/// 中间调，γ < 1 压暗。端点 x=0/max 恒为 0/max。
double gammaCurveEval(double x, double gamma) {
  final max = kLevelsMax.toDouble();
  if (x <= 0) return 0.0;
  if (x >= max) return max;
  return max * math.pow(x / max, 1.0 / gamma);
}

/// 由控制点位置反解 gamma 值：γ = ln(x/max) / ln(y/max)。
/// x、y 须在 (0, max) 开区间内，否则无法定义（返回 null）。
double? gammaFromPoint(double x, double y) {
  final max = kLevelsMax.toDouble();
  if (x <= 0 || x >= max || y <= 0 || y >= max) return null;
  return math.log(x / max) / math.log(y / max);
}

/// 恒等曲线（默认参数）：A1→C1 对角线。
const List<List<double>> kLevelsIdentityPoints = [
  [0.0, 0.0],
  [4095.0, 4095.0],
];

/// 从节点参数还原控制点列表（`paramValues['points']` 为 JSON 安全的
/// `[[x, y], …]`）。缺失/损坏时回退恒等曲线。
List<List<double>> levelsPointsFromParam(Object? raw) {
  if (raw is! List) return kLevelsIdentityPoints;
  final pts = <List<double>>[];
  for (final e in raw) {
    if (e is List && e.length >= 2 && e[0] is num && e[1] is num) {
      pts.add([(e[0] as num).toDouble(), (e[1] as num).toDouble()]);
    }
  }
  return normalizeLevelsPoints(pts);
}

/// 规范化控制点：钳位到 0..4095、按 x 排序、去除重复 x（保后者）、
/// 强制首尾为 x=0 / x=4095 的端点（y 保留）。空列表回退恒等曲线。
List<List<double>> normalizeLevelsPoints(List<List<double>> points) {
  if (points.isEmpty) return kLevelsIdentityPoints;
  final max = kLevelsMax.toDouble();
  final list = [
    for (final p in points)
      [p[0].clamp(0.0, max), p[1].clamp(0.0, max)],
  ]..sort((a, b) => a[0].compareTo(b[0]));
  // 重复 x 会使 Hermite 段长为 0，去重保后者（编辑器拖点时的预期）。
  final deduped = <List<double>>[list.first];
  for (var i = 1; i < list.length; i++) {
    if (list[i][0] == deduped.last[0]) {
      deduped[deduped.length - 1] = list[i];
    } else {
      deduped.add(list[i]);
    }
  }
  deduped.first[0] = 0.0;
  if (deduped.length == 1) {
    deduped.add([max, deduped.first[1]]);
  } else {
    deduped.last[0] = max;
  }
  return deduped;
}

/// 恒等判定：所有控制点都在对角线上（单调插值不引入过冲，点点共线
/// 即整线恒等）。
bool levelsCurveIsIdentity(List<List<double>> points) {
  for (final p in points) {
    if ((p[1] - p[0]).abs() > 1e-9) return false;
  }
  return true;
}

/// 按 [mode] 指定的生成公式求传递函数在 [x] 处的值。[points] 须先经
/// [normalizeLevelsPoints]（x 严格递增）。gamma 模式忽略 [points]，
/// 由 [gamma] 决定曲线（y = max·(x/max)^(1/γ)）。
double levelsCurveEval(List<List<double>> points, double x,
    {LevelsCurveMode mode = LevelsCurveMode.spline, double gamma = 1.0}) {
  return switch (mode) {
    LevelsCurveMode.spline => _splineEval(points, x),
    LevelsCurveMode.bezier => _bezierEval(points, x),
    LevelsCurveMode.linear => _linearEval(points, x),
    LevelsCurveMode.gamma => gammaCurveEval(x, gamma),
  };
}

/// Fritsch–Carlson 单调三次 Hermite 插值求值。单调的控制点序列产生
/// 单调曲线：传递函数不会引入影调反转之外的伪轮廓，且段内无过冲。
double _splineEval(List<List<double>> points, double x) {
  final n = points.length;
  if (x <= points.first[0]) return points.first[1];
  if (x >= points.last[0]) return points.last[1];
  final xs = [for (final p in points) p[0]];
  final ys = [for (final p in points) p[1]];
  // 段斜率与端点切线。
  final d = List<double>.filled(n - 1, 0.0);
  final m = List<double>.filled(n, 0.0);
  for (var i = 0; i < n - 1; i++) {
    d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]);
  }
  m[0] = d[0];
  m[n - 1] = d[n - 2];
  for (var i = 1; i < n - 1; i++) {
    m[i] = (d[i - 1] + d[i]) / 2;
  }
  // Fritsch–Carlson 单调性约束：切线限制在单调区域内。
  for (var i = 0; i < n - 1; i++) {
    if (d[i] == 0) {
      m[i] = 0;
      m[i + 1] = 0;
    } else {
      final a = m[i] / d[i];
      final b = m[i + 1] / d[i];
      final s = a * a + b * b;
      if (s > 9) {
        final t = 3 / math.sqrt(s);
        m[i] = t * a * d[i];
        m[i + 1] = t * b * d[i];
      }
    }
  }
  // 定位段并做三次 Hermite 求值。
  var seg = 0;
  while (seg < n - 2 && x > xs[seg + 1]) {
    seg++;
  }
  final h = xs[seg + 1] - xs[seg];
  final t = (x - xs[seg]) / h;
  final t2 = t * t;
  final t3 = t2 * t;
  return (2 * t3 - 3 * t2 + 1) * ys[seg] +
      (t3 - 2 * t2 + t) * h * m[seg] +
      (-2 * t3 + 3 * t2) * ys[seg + 1] +
      (t3 - t2) * h * m[seg + 1];
}

/// 生成 0..4095 共 4096 级的传递函数 LUT。
Uint16List levelsCurveLut(List<List<double>> points,
    {LevelsCurveMode mode = LevelsCurveMode.spline, double gamma = 1.0}) {
  final lut = Uint16List(kLevelsMax + 1);
  for (var x = 0; x <= kLevelsMax; x++) {
    lut[x] = levelsCurveEval(points, x.toDouble(), mode: mode, gamma: gamma)
        .round()
        .clamp(0, kLevelsMax);
  }
  return lut;
}

/// 线段法：控制点间直线连接（不做平滑处理），段内线性插值。
double _linearEval(List<List<double>> points, double x) {
  if (x <= points.first[0]) return points.first[1];
  if (x >= points.last[0]) return points.last[1];
  var seg = 0;
  while (seg < points.length - 2 && x > points[seg + 1][0]) {
    seg++;
  }
  final a = points[seg];
  final b = points[seg + 1];
  final t = (x - a[0]) / (b[0] - a[0]);
  return a[1] + (b[1] - a[1]) * t;
}

/// 贝塞尔曲线法：控制点整体作为贝塞尔控制多边形，B(t) = ΣBᵢⁿ(t)·Pᵢ
/// （De Casteljau 求值）。控制点 x 单调递增 ⇒ x(t) 单调不减（x'(t)
/// 是控制点 x 差分的非负 Bernstein 加权和），故可对给定 x 二分反解
/// 参数 t 再取 y(t)。曲线只保证过首尾端点，中间控制点牵引形状但不
/// 一定经过——贝塞尔控制多边形的固有特性。
double _bezierEval(List<List<double>> points, double x) {
  if (x <= points.first[0]) return points.first[1];
  if (x >= points.last[0]) return points.last[1];
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 60; i++) {
    final mid = (lo + hi) / 2;
    if (_deCasteljau(points, mid, 0) < x) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return _deCasteljau(points, (lo + hi) / 2, 1);
}

/// De Casteljau 递推求贝塞尔曲线在参数 [t] 处的第 [comp] 个分量
/// （0=x，1=y）。
double _deCasteljau(List<List<double>> points, double t, int comp) {
  final v = [for (final p in points) p[comp]];
  for (var n = v.length - 1; n > 0; n--) {
    for (var i = 0; i < n; i++) {
      v[i] = v[i] + (v[i + 1] - v[i]) * t;
    }
  }
  return v[0];
}
