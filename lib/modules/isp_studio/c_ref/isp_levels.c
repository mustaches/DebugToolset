#include "isp_levels.h"

/**
 * @file isp_levels.c
 * @brief ISP Studio C99 参考实现 —— 曲线调节器（levels_curves 节点）实现。
 *
 * 覆盖范围：
 * - 控制点规范化（钳位/排序/去重/强制端点）与恒等判定；
 * - 四种曲线生成公式的传递函数求值：Fritsch–Carlson 单调三次 Hermite
 *   样条、贝塞尔（De Casteljau + 二分反解）、线段、gamma；
 * - 4096 级 LUT 生成（调用方提供 LUT 与 scratch 缓冲）；
 * - 交织 RGB 帧的 LUT 应用（applyLevelsCurve）。
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/levels_curve.dart、
 * lib/modules/isp_studio/pipeline/isp_kernels.dart（applyLevelsCurve）。
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#include <math.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * 内部 helper
 * ------------------------------------------------------------------------- */

/**
 * Dart double.round() 为「最近整数、恰半远离零」，与 C99 round() 语义
 * 完全一致，直接调用即可。此处集中说明，不再另写包装。
 */

/**
 * Fritsch–Carlson 单调三次 Hermite 插值求值。
 * Dart 来源：levels_curve.dart `_splineEval`。
 * scratch 布局：d[n-1]（段斜率）在前，m[n]（端点切线）在后，共 2n-1 个
 * double。单调的控制点序列产生单调曲线，段内无过冲。
 */
static double isp_levels_spline_eval(const double *points_xy, int n,
                                     double x, double *scratch) {
  double *d = scratch;
  double *m = scratch + (n - 1);
  int seg;
  double h, t, t2, t3;

  if (x <= points_xy[0]) return points_xy[1];
  if (x >= points_xy[2 * (n - 1)]) return points_xy[2 * (n - 1) + 1];

  /* 段斜率与端点切线（首末端取邻段斜率，中间取相邻两段均值）。 */
  for (int i = 0; i < n - 1; i++) {
    d[i] = (points_xy[2 * (i + 1) + 1] - points_xy[2 * i + 1]) /
           (points_xy[2 * (i + 1)] - points_xy[2 * i]);
  }
  m[0] = d[0];
  m[n - 1] = d[n - 2];
  for (int i = 1; i < n - 1; i++) {
    m[i] = (d[i - 1] + d[i]) / 2;
  }
  /* Fritsch–Carlson 单调性约束：切线限制在单调区域内（a²+b²<=9）。 */
  for (int i = 0; i < n - 1; i++) {
    if (d[i] == 0.0) {
      m[i] = 0.0;
      m[i + 1] = 0.0;
    } else {
      const double a = m[i] / d[i];
      const double b = m[i + 1] / d[i];
      const double s = a * a + b * b;
      if (s > 9.0) {
        const double tt = 3.0 / sqrt(s);
        m[i] = tt * a * d[i];
        m[i + 1] = tt * b * d[i];
      }
    }
  }
  /* 定位段并做三次 Hermite 求值。 */
  seg = 0;
  while (seg < n - 2 && x > points_xy[2 * (seg + 1)]) {
    seg++;
  }
  h = points_xy[2 * (seg + 1)] - points_xy[2 * seg];
  t = (x - points_xy[2 * seg]) / h;
  t2 = t * t;
  t3 = t2 * t;
  return (2 * t3 - 3 * t2 + 1) * points_xy[2 * seg + 1] +
         (t3 - 2 * t2 + t) * h * m[seg] +
         (-2 * t3 + 3 * t2) * points_xy[2 * (seg + 1) + 1] +
         (t3 - t2) * h * m[seg + 1];
}

/**
 * 线段法：控制点间直线连接，段内线性插值。
 * Dart 来源：levels_curve.dart `_linearEval`。
 */
static double isp_levels_linear_eval(const double *points_xy, int n,
                                     double x) {
  int seg;
  double ax, ay, bx, by, t;

  if (x <= points_xy[0]) return points_xy[1];
  if (x >= points_xy[2 * (n - 1)]) return points_xy[2 * (n - 1) + 1];
  seg = 0;
  while (seg < n - 2 && x > points_xy[2 * (seg + 1)]) {
    seg++;
  }
  ax = points_xy[2 * seg];
  ay = points_xy[2 * seg + 1];
  bx = points_xy[2 * (seg + 1)];
  by = points_xy[2 * (seg + 1) + 1];
  t = (x - ax) / (bx - ax);
  return ay + (by - ay) * t;
}

/**
 * De Casteljau 递推求贝塞尔曲线在参数 t 处的第 comp 个分量（0=x，1=y）。
 * Dart 来源：levels_curve.dart `_deCasteljau`。v 为 n 个 double 的工作区。
 */
static double isp_levels_de_casteljau(const double *points_xy, int n,
                                      double t, int comp, double *v) {
  for (int i = 0; i < n; i++) {
    v[i] = points_xy[2 * i + comp];
  }
  for (int k = n - 1; k > 0; k--) {
    for (int i = 0; i < k; i++) {
      v[i] = v[i] + (v[i + 1] - v[i]) * t;
    }
  }
  return v[0];
}

/**
 * 贝塞尔曲线法：控制点 x 单调递增 ⇒ x(t) 单调不减，故对给定 x 二分反解
 * 参数 t（固定 60 次迭代）再取 y(t)。
 * Dart 来源：levels_curve.dart `_bezierEval`。
 */
static double isp_levels_bezier_eval(const double *points_xy, int n,
                                     double x, double *v) {
  double lo = 0.0, hi = 1.0;

  if (x <= points_xy[0]) return points_xy[1];
  if (x >= points_xy[2 * (n - 1)]) return points_xy[2 * (n - 1) + 1];
  for (int i = 0; i < 60; i++) {
    const double mid = (lo + hi) / 2;
    if (isp_levels_de_casteljau(points_xy, n, mid, 0, v) < x) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return isp_levels_de_casteljau(points_xy, n, (lo + hi) / 2, 1, v);
}

/* ---------------------------------------------------------------------------
 * 节点参数解析 / 控制点规范化
 * ------------------------------------------------------------------------- */

IspLevelsCurveMode isp_levels_curve_mode_from_name(const char *name) {
  /* Dart `levelsCurveModeFromParam`：'bezier'/'linear'/'gamma' 之外一律
   * 回退默认样条。 */
  if (name != NULL) {
    if (strcmp(name, "bezier") == 0) return ISP_LEVELS_CURVE_BEZIER;
    if (strcmp(name, "linear") == 0) return ISP_LEVELS_CURVE_LINEAR;
    if (strcmp(name, "gamma") == 0) return ISP_LEVELS_CURVE_GAMMA;
  }
  return ISP_LEVELS_CURVE_SPLINE;
}

int isp_levels_normalize_points(const double *points_xy, int point_count,
                                double *out_xy, int out_capacity,
                                int *out_count) {
  const double max = (double)ISP_LEVELS_MAX;
  int n;

  if (out_xy == NULL || out_count == NULL) return ISP_ERR_ARG;
  /* 空列表回退恒等曲线（Dart `kLevelsIdentityPoints`）。 */
  if (points_xy == NULL || point_count <= 0) {
    if (out_capacity < 2) return ISP_ERR_SIZE;
    out_xy[0] = 0.0;
    out_xy[1] = 0.0;
    out_xy[2] = max;
    out_xy[3] = max;
    *out_count = 2;
    return ISP_OK;
  }
  /* 去重只会缩短列表，唯一点数不足 2 时会补第二端点，故容量上界为
   * max(point_count, 2)。 */
  if (out_capacity < (point_count < 2 ? 2 : point_count)) {
    return ISP_ERR_SIZE;
  }
  /* 钳位到 0..4095 并拷入输出缓冲（Dart `p[i].clamp(0.0, max)`；
   * if/else 写法对 NaN 原样透传，与 Dart num.clamp 一致）。 */
  for (int i = 0; i < point_count; i++) {
    double x = points_xy[2 * i];
    double y = points_xy[2 * i + 1];
    if (x < 0.0) {
      x = 0.0;
    } else if (x > max) {
      x = max;
    }
    if (y < 0.0) {
      y = 0.0;
    } else if (y > max) {
      y = max;
    }
    out_xy[2 * i] = x;
    out_xy[2 * i + 1] = y;
  }
  /* 按 x 升序排序。Dart `list.sort(compareTo)` 为不稳定快排，重复 x 的
   * 相对顺序未定义；此处取稳定的插入排序（确定性最好，点数通常很少）。
   * 重复 x 场景与 Dart 无逐位约定可循，见移植报告说明。 */
  for (int i = 1; i < point_count; i++) {
    const double kx = out_xy[2 * i];
    const double ky = out_xy[2 * i + 1];
    int j = i - 1;
    while (j >= 0 && out_xy[2 * j] > kx) {
      out_xy[2 * (j + 1)] = out_xy[2 * j];
      out_xy[2 * (j + 1) + 1] = out_xy[2 * j + 1];
      j--;
    }
    out_xy[2 * (j + 1)] = kx;
    out_xy[2 * (j + 1) + 1] = ky;
  }
  /* 去除重复 x（保后者，Dart 注释：编辑器拖点时的预期）。 */
  n = 1;
  for (int i = 1; i < point_count; i++) {
    if (out_xy[2 * i] == out_xy[2 * (n - 1)]) {
      out_xy[2 * (n - 1)] = out_xy[2 * i];
      out_xy[2 * (n - 1) + 1] = out_xy[2 * i + 1];
    } else {
      out_xy[2 * n] = out_xy[2 * i];
      out_xy[2 * n + 1] = out_xy[2 * i + 1];
      n++;
    }
  }
  /* 强制首尾为 x=0 / x=4095 的端点（y 保留）。 */
  out_xy[0] = 0.0;
  if (n == 1) {
    out_xy[2] = max;
    out_xy[3] = out_xy[1];
    n = 2;
  } else {
    out_xy[2 * (n - 1)] = max;
  }
  *out_count = n;
  return ISP_OK;
}

bool isp_levels_curve_is_identity(const double *points_xy, int point_count) {
  /* Dart `levelsCurveIsIdentity`：逐点判 |y-x| > 1e-9；空列表返回 true。 */
  if (points_xy == NULL || point_count <= 0) return true;
  for (int i = 0; i < point_count; i++) {
    if (fabs(points_xy[2 * i + 1] - points_xy[2 * i]) > 1e-9) return false;
  }
  return true;
}

/* ---------------------------------------------------------------------------
 * gamma 曲线
 * ------------------------------------------------------------------------- */

double isp_levels_gamma_eval(double x, double gamma) {
  const double max = (double)ISP_LEVELS_MAX;
  if (x <= 0.0) return 0.0;
  if (x >= max) return max;
  return max * pow(x / max, 1.0 / gamma);
}

bool isp_levels_gamma_from_point(double x, double y, double *out_gamma) {
  const double max = (double)ISP_LEVELS_MAX;
  if (out_gamma == NULL) return false;
  /* x、y 须在 (0, max) 开区间内，否则无法定义（Dart 返回 null）。 */
  if (x <= 0.0 || x >= max || y <= 0.0 || y >= max) return false;
  *out_gamma = log(x / max) / log(y / max);
  return true;
}

/* ---------------------------------------------------------------------------
 * 传递函数求值与 LUT 生成
 * ------------------------------------------------------------------------- */

double isp_levels_curve_eval(const double *points_xy, int point_count,
                             double x, IspLevelsCurveMode mode, double gamma,
                             double *scratch) {
  /* gamma 模式忽略控制点（Dart `levelsCurveEval` 的 gamma 分支）。 */
  if (mode == ISP_LEVELS_CURVE_GAMMA) {
    return isp_levels_gamma_eval(x, gamma);
  }
  if (points_xy == NULL || point_count <= 0) return 0.0;
  if (point_count == 1) return points_xy[1];
  switch (mode) {
    case ISP_LEVELS_CURVE_BEZIER:
      if (scratch == NULL) return 0.0;
      return isp_levels_bezier_eval(points_xy, point_count, x, scratch);
    case ISP_LEVELS_CURVE_LINEAR:
      return isp_levels_linear_eval(points_xy, point_count, x);
    case ISP_LEVELS_CURVE_SPLINE:
    default:
      /* 未知枚举值防御性回退样条（Dart 侧 switch 穷举无此路径）。 */
      if (scratch == NULL) return 0.0;
      return isp_levels_spline_eval(points_xy, point_count, x, scratch);
  }
}

int isp_levels_curve_lut(const double *points_xy, int point_count,
                         IspLevelsCurveMode mode, double gamma,
                         double *scratch, uint16_t *lut_out) {
  if (lut_out == NULL) return ISP_ERR_ARG;
  if (mode == ISP_LEVELS_CURVE_GAMMA) {
    /* gamma 模式忽略控制点。 */
    for (int x = 0; x <= ISP_LEVELS_MAX; x++) {
      const double v = isp_levels_gamma_eval((double)x, gamma);
      const int r = (int)round(v);
      lut_out[x] = (uint16_t)isp_clamp_int(r, 0, ISP_LEVELS_MAX);
    }
    return ISP_OK;
  }
  if (points_xy == NULL || point_count < 2) return ISP_ERR_ARG;
  /* 校验 x 严格递增（样条段长为 0 会除零；规范化的输出必满足）。 */
  for (int i = 1; i < point_count; i++) {
    if (!(points_xy[2 * i] > points_xy[2 * (i - 1)])) return ISP_ERR_ARG;
  }
  if (mode != ISP_LEVELS_CURVE_LINEAR && scratch == NULL) {
    return ISP_ERR_ARG;
  }
  /* 每级：eval(x).round().clamp(0, 4095)。Dart round() 恰半远离零，
   * 与 C99 round() 同语义；样条/bezier 每点重算系数，与 Dart 逐次调用
   * levelsCurveEval 的路径完全同序，结果逐位一致。 */
  for (int x = 0; x <= ISP_LEVELS_MAX; x++) {
    const double v = isp_levels_curve_eval(points_xy, point_count, (double)x,
                                           mode, gamma, scratch);
    const int r = (int)round(v);
    lut_out[x] = (uint16_t)isp_clamp_int(r, 0, ISP_LEVELS_MAX);
  }
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * LUT 应用（帧级 kernel）
 * ------------------------------------------------------------------------- */

int isp_levels_apply_rgb(const uint16_t *rgb, int w, int h,
                         const uint16_t *lut, int max_value, uint16_t *out) {
  size_t total;

  if (rgb == NULL || lut == NULL || out == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  if (max_value <= 0) return ISP_ERR_ARG;

  total = (size_t)w * (size_t)h * 3u;
  /* max_value == 4095 时直通查表（Dart applyLevelsCurve 的快路径）。 */
  if (max_value == ISP_LEVELS_MAX) {
    for (size_t i = 0; i < total; i++) {
      out[i] = lut[rgb[i]];
    }
    return ISP_OK;
  }
  /* 帧值按 max_value 线性缩放到 0..4095 查表，再缩放回 0..max_value。
   * 两侧均为「加半除数再整除」的最近舍入：Dart `~/` 为向下取整，正数域
   * 与 C 的截断除法一致（rgb[i]*4095 <= 65535*4095 < 2^31，无溢出）。 */
  for (size_t i = 0; i < total; i++) {
    int idx = ((int)rgb[i] * ISP_LEVELS_MAX + (max_value >> 1)) / max_value;
    /* 调用契约 rgb[i] <= max_value；越界时 Dart 抛 RangeError，C 侧钳位
     * 下标以避免越界读（防御性差异，正常数据不触发）。 */
    if (idx > ISP_LEVELS_MAX) idx = ISP_LEVELS_MAX;
    if (idx < 0) idx = 0;
    out[i] = (uint16_t)(((int)lut[idx] * max_value + (ISP_LEVELS_MAX >> 1)) /
                        ISP_LEVELS_MAX);
  }
  return ISP_OK;
}
