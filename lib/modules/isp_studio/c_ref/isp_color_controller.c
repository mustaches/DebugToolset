#include "isp_color_controller.h"

/**
 * @file isp_color_controller.c
 * @brief ISP Studio C99 参考实现 —— 色彩控制器（高斯色相带选择性调整）实现。
 *
 * 覆盖节点：color_controller。
 * 对应的 Dart 来源：isp_kernels.dart 的 `adjustHslBand` / `adjustHslBandRows`
 * 与 `_clampTo`（hsl_band_pool.dart 条带池为 PC 侧并行加速，不移植）。
 *
 * 与 Dart 数值口径的说明（2026-08 对拍后修订）：
 * 本实现曾用栈上 181 项（整数度 0..180°）高斯权重 LUT + 线性插值近似
 * Dart 的逐点 exp 权重；Dart↔C 对拍（test/isp_c_ref_compare_adjust_test.dart）
 * 发现量化 H 映射到小数度后插值误差成片出现（q=8 窄带时 64x48 帧约 2%
 * 元素差 ±1、个别 ±2），不符合逐位一致口径。现改为逐像素直接计算
 * exp（与 Dart adjustHslBandRows 同一表达式：x = d/σ, w = exp(-x²/2)，
 * 两者同为 IEEE double 且同宿主机 libm，逐位一致）；不再需要任何 LUT
 * 缓冲，内存占用反而更小，代价是每像素一次 exp。H 环绕、S/L 的
 * _clampTo 收尾、恒等直通语义均与 Dart 逐位一致。
 */

#include <math.h>
#include <string.h>

/**
 * @brief Dart `_clampTo` 的浮点路径收尾：先比界、界内才 round()。
 *
 * Dart 来源：isp_kernels.dart `_clampTo`：
 *   v < 0 ? 0 : (v > maxValue ? maxValue : v.round())
 * 注意顺序不可颠倒——必须先按浮点原值比界，界内才四舍五入；例如
 * max_value + 0.4 应裁为 max_value（而非先 round 成 max_value + 1 再裁，
 * 虽然此处殊途同归，但 max_value - 0.5 之类的临界值会暴露顺序差异）。
 * Dart round() 与 C99 lround() 同为「四舍五入、半值远离零」。
 *
 * （isp_common.h 未提供浮点版 clamp，故写为本文件 static helper。）
 *
 * @param v         浮点中间结果。
 * @param max_value 采样最大值。
 * @return 钳位/舍入后的采样值。
 */
static uint16_t cc_clamp_to(double v, int max_value) {
  if (v < 0.0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  return (uint16_t)lround(v);
}

int isp_color_controller_apply(const uint16_t *src, uint16_t *dst,
                               int w, int h, int max_value,
                               double h_center_deg, double q,
                               double h_shift_deg, double s_gain,
                               double l_gain) {
  double sigma;
  int m;
  size_t px_count;
  size_t px;

  if (src == NULL || dst == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0 || max_value <= 0) return ISP_ERR_SIZE;
  if (!(q > 0.0)) return ISP_ERR_ARG; /* σ = 45°/q，q 必须为正有限数（!(q>0) 同时挡住 NaN） */

  /* 恒等直通（Dart adjustHslBand 首行）：三个调整量均为恒等值时不处理。
   * Dart 零拷贝返回原缓冲；C 侧输出缓冲由调用方提供，故把输入搬到输出
   *（memmove 允许重叠；src == dst 时直接返回）。 */
  if (h_shift_deg == 0.0 && s_gain == 1.0 && l_gain == 1.0) {
    if (dst != src) {
      memmove(dst, src, (size_t)w * (size_t)h * 3u * sizeof(uint16_t));
    }
    return ISP_OK;
  }

  m = max_value + 1; /* 色环模数：H 在 0..max_value 上循环（Dart: maxValue + 1） */
  sigma = 45.0 / q;

  px_count = (size_t)w * (size_t)h;
  for (px = 0; px < px_count; px++) {
    const size_t i = px * 3u;
    int hv = (int)src[i];
    double h_deg;
    double d;
    double x;
    double weight;
    double s_mul;
    double l_mul;
    int shift;
    int h_new;

    /* 防御：H 量化值不应超过 max_value（Dart 侧越界查 LUT 会直接抛异常，
     * C 侧钳位兜底）。 */
    if (hv > max_value) hv = max_value;

    /* 色环最短角距 Δ（0..180°）。对应 Dart：
     *   hDeg = hv * 360.0 / maxValue;
     *   d = (hDeg - hCenterDeg).abs() % 360.0;
     *   if (d > 180) d = 360 - d;
     * abs 之后被取模值非负，Dart 的 % 与 C fmod 在非负域完全一致。 */
    h_deg = (double)hv * 360.0 / (double)max_value;
    d = fabs(h_deg - h_center_deg);
    d = fmod(d, 360.0);
    if (d > 180.0) d = 360.0 - d;

    /* 高斯权重逐像素精确计算（对拍后修订，见文件头注释）：
     * 表达式与 Dart 逐行一致（x = d / sigma; w = exp(-0.5 * x * x)），
     * 同宿主机 libm，逐位一致。 */
    x = d / sigma;
    weight = exp(-0.5 * x * x);

    /* H' = H + round(hShiftDeg × w / 360 × maxValue)，色环环绕。
     * Dart: shiftLut[hv] = (hShiftDeg * w / 360 * maxValue).round()，
     * 乘除顺序保持左结合一致；lround 与 Dart round() 同半值远离零。
     * C 的 % 与被除数同号，负数修正后等价 Dart ((x % m) + m) % m。 */
    shift = (int)lround(h_shift_deg * weight / 360.0 * (double)max_value);
    h_new = (hv + shift) % m;
    if (h_new < 0) h_new += m;
    dst[i] = (uint16_t)h_new;

    /* S/L 按 1 + (gain − 1) × w 渐变（Dart: 1 + (sGain - 1) * w），
     * 乘回采样值后走 _clampTo 浮点路径收尾。 */
    s_mul = 1.0 + (s_gain - 1.0) * weight;
    l_mul = 1.0 + (l_gain - 1.0) * weight;
    dst[i + 1] = cc_clamp_to((double)src[i + 1] * s_mul, max_value);
    dst[i + 2] = cc_clamp_to((double)src[i + 2] * l_mul, max_value);
  }
  return ISP_OK;
}

int isp_color_controller_lut_apply(const uint16_t *src, uint16_t *dst,
                                   int w, int h, int max_value,
                                   const int32_t *shift_lut,
                                   const double *s_mul_lut,
                                   const double *l_mul_lut) {
  const size_t px_count = (size_t)w * (size_t)h;
  const int m = max_value + 1; /* 色环模数（Dart: maxValue + 1） */
  size_t px;
  if (src == NULL || dst == NULL || shift_lut == NULL ||
      s_mul_lut == NULL || l_mul_lut == NULL) {
    return ISP_ERR_ARG;
  }
  if (w <= 0 || h <= 0 || max_value <= 0) return ISP_ERR_SIZE;
  /* 与 Dart applyHslBandLuts 一致：3 次查表 + 2 次乘法 + 1 次取模。 */
  for (px = 0; px < px_count; px++) {
    const size_t i = px * 3u;
    int hv = (int)src[i];
    int h_new;
    if (hv > max_value) hv = max_value; /* 防御钳位（同直算路径） */
    h_new = (hv + shift_lut[hv]) % m;
    if (h_new < 0) h_new += m; /* Dart ((x % m) + m) % m 修正环绕 */
    dst[i] = (uint16_t)h_new;
    dst[i + 1] = cc_clamp_to((double)src[i + 1] * s_mul_lut[hv], max_value);
    dst[i + 2] = cc_clamp_to((double)src[i + 2] * l_mul_lut[hv], max_value);
  }
  return ISP_OK;
}
