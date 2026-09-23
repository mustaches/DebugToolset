#include "isp_color_temp.h"

/**
 * @file isp_color_temp.c
 * @brief ISP Studio C99 参考实现 —— 色温调节器（color_temp_adjuster 节点）
 *        的色温模型与测量实现。
 *
 * 覆盖范围（color_temp.dart 的全部公开函数）：
 * - isp_color_temp_white_point  Tanner Helland 黑体近似白点
 * - isp_color_temp_gains        von Kries 对角增益（目标/参考色温白点之比）
 * - isp_color_temp_ccm          增益 → 对角 3x3 CCM
 * - isp_color_temp_measure_cct  RGBA 帧抽样平均色 → McCamy 相关色温估计
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/color_temp.dart。
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#include <math.h>

/**
 * 双精度钳位：if/else 写法对 NaN 原样透传，与 Dart num.clamp 的语义
 * 一致（Dart 的 double.clamp 在 NaN 输入时返回 NaN）。
 */
static double isp_color_temp_clampd(double v, double lo, double hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/* ---------------------------------------------------------------------------
 * 色温模型
 * ------------------------------------------------------------------------- */

int isp_color_temp_white_point(int cct, double out_rgb[3]) {
  double t, r, g, b, gc;

  if (out_rgb == NULL) return ISP_ERR_ARG;
  /* Dart `cct.clamp(kColorTempMin, kColorTempMax) / 100.0`（int 钳位后
   * 转 double 除以 100）。 */
  t = (double)isp_clamp_int(cct, ISP_COLOR_TEMP_MIN, ISP_COLOR_TEMP_MAX) /
      100.0;
  /* 8 位白点近似公式（Tanner Helland），分段边界与 Dart 逐项一致：
   * R：t<=66 恒 255，否则幂函数；G：t<=66 对数式，否则幂函数；
   * B：t>=66 恒 255，t<=19 为 0，中间对数式。 */
  r = (t <= 66.0) ? 255.0
                  : 329.698727446 * pow(t - 60.0, -0.1332047592);
  g = (t <= 66.0) ? 99.4708025861 * log(t) - 161.1195681661
                  : 288.1221695283 * pow(t - 60.0, -0.0755148492);
  b = (t >= 66.0) ? 255.0
                  : (t <= 19.0
                         ? 0.0
                         : 138.5177312231 * log(t - 10.0) - 305.0447927307);
  /* gc = g.clamp(1.0, 255.0)：防除零；正常范围 g≈177~255。 */
  gc = isp_color_temp_clampd(g, 1.0, 255.0);
  out_rgb[0] = isp_color_temp_clampd(r, 0.0, 255.0) / gc;
  out_rgb[1] = 1.0;
  out_rgb[2] = isp_color_temp_clampd(b, 0.0, 255.0) / gc;
  return ISP_OK;
}

int isp_color_temp_gains(double target_cct, int reference_cct,
                         double out_gains[3]) {
  double wt[3], wr[3];
  int tc, rc, ret;

  if (out_gains == NULL) return ISP_ERR_ARG;
  /* Dart `targetCct.round().clamp(min, max)`：double.round() 为最近整数、
   * 恰半远离零，与 C99 round() 同语义。 */
  tc = isp_clamp_int((int)round(target_cct), ISP_COLOR_TEMP_MIN,
                     ISP_COLOR_TEMP_MAX);
  /* 参考色温 <= 0 时按默认 6500K（Dart `kColorTempDefault.round()`）。 */
  rc = (reference_cct > 0) ? reference_cct : ISP_COLOR_TEMP_DEFAULT;
  ret = isp_color_temp_white_point(tc, wt);
  if (ret != ISP_OK) return ret;
  ret = isp_color_temp_white_point(rc, wr);
  if (ret != ISP_OK) return ret;
  out_gains[0] = wt[0] / wr[0];
  out_gains[1] = 1.0;
  out_gains[2] = wt[2] / wr[2];
  return ISP_OK;
}

void isp_color_temp_ccm(const double gains[3], double out_ccm[9]) {
  if (gains == NULL || out_ccm == NULL) return;
  /* 对角阵，行优先：[g0,0,0, 0,g1,0, 0,0,g2]。 */
  out_ccm[0] = gains[0];
  out_ccm[1] = 0.0;
  out_ccm[2] = 0.0;
  out_ccm[3] = 0.0;
  out_ccm[4] = gains[1];
  out_ccm[5] = 0.0;
  out_ccm[6] = 0.0;
  out_ccm[7] = 0.0;
  out_ccm[8] = gains[2];
}

/* ---------------------------------------------------------------------------
 * 色温测量
 * ------------------------------------------------------------------------- */

int isp_color_temp_measure_cct(const uint8_t *rgba, int w, int h,
                               int *out_cct) {
  long px, n;
  int step, x, y;
  double rs, gs, bs;
  double r, g, b, x0, y0, z0, sum, cx, cy, denom, nn, cct;

  if (rgba == NULL || out_cct == NULL) return ISP_ERR_ARG;
  px = (long)w * (long)h;
  if (px <= 0) return ISP_ERR_SIZE; /* Dart 空帧返回 null */

  /* 抽样步长：总样本压到约 4096 个。Dart `sqrt(px / 4096).floor()`：
   * `/` 为 double 除法，floor 后与 1 取大。 */
  step = (int)floor(sqrt((double)px / 4096.0));
  if (step < 1) step = 1;
  /* 步长抽样累加 RGB（y 外层、x 内层，顺序与 Dart 一致——浮点累加顺序
   * 影响末位，必须同序）。alpha 通道忽略。 */
  rs = 0.0;
  gs = 0.0;
  bs = 0.0;
  n = 0;
  for (y = 0; y < h; y += step) {
    for (x = 0; x < w; x += step) {
      const size_t i = ((size_t)y * (size_t)w + (size_t)x) * 4u;
      rs += (double)rgba[i];
      gs += (double)rgba[i + 1];
      bs += (double)rgba[i + 2];
      n++;
    }
  }
  if (n == 0) return ISP_ERR_UNSUPPORTED;
  /* 平均色（0..1）。Dart `rs / n / 255`：两次 double 除法，同序。 */
  r = rs / (double)n / 255.0;
  g = gs / (double)n / 255.0;
  b = bs / (double)n / 255.0;
  /* sRGB → XYZ（D65），系数与 Dart 一致。 */
  x0 = 0.4124 * r + 0.3576 * g + 0.1805 * b;
  y0 = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  z0 = 0.0193 * r + 0.1192 * g + 0.9505 * b;
  sum = x0 + y0 + z0;
  if (sum <= 1e-9) return ISP_ERR_UNSUPPORTED; /* 全黑帧无法估计 */
  cx = x0 / sum;
  cy = y0 / sum;
  denom = 0.1858 - cy;
  if (fabs(denom) < 1e-6) return ISP_ERR_UNSUPPORTED;
  /* McCamy 公式：CCT = 449n³ + 3525n² + 6823.3n + 5520.33。 */
  nn = (cx - 0.3320) / denom;
  cct = 449.0 * nn * nn * nn + 3525.0 * nn * nn + 6823.3 * nn + 5520.33;
  /* Dart `cct.round().clamp(min, max)`：round 恰半远离零 = C99 round()。 */
  *out_cct =
      isp_clamp_int((int)round(cct), ISP_COLOR_TEMP_MIN, ISP_COLOR_TEMP_MAX);
  return ISP_OK;
}
