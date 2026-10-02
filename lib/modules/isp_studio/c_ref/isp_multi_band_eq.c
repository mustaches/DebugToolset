#include "isp_multi_band_eq.h"

/**
 * @file isp_multi_band_eq.c
 * @brief ISP Studio C99 参考实现 —— 多段色彩均衡器实现。
 *
 * 覆盖节点：multi_band_eq。
 * 对应的 Dart 来源：isp_kernels.dart 的 `multiBandLuts` /
 * `applyHslBandLuts` 与 `_clampTo`。
 *
 * 与 Dart 数值口径的说明：
 * 权重/合成表达式与 Dart 逐行一致（同为 IEEE double 且同宿主机 libm）：
 * - 段权重：d = fabs(hDeg − h)；d = fmod(d, 360)（非负域与 Dart % 一致）；
 *   d > 180 时 d = 360 − d；x = d / (45.0 / q)；w = exp(−0.5·x²)。
 * - 并联：dhSum/sSum/lSum 按段序累加（w·dh、w·(g−1)），ΔH 钳位 ±180°
 *   后 round（lround 与 Dart round() 同半值远离零），乘子 1+Σ 钳位 0..5。
 * - 串联：hCur 逐段 fmod 归一（Dart double % 为欧几里得取模，C fmod
 *   负数加 360 修正后等价）；首尾偏移 dd 同样先欧几里得取模到 [0,360)
 *   再归一到 (−180,180]；增益乘性合成钳位 0..5。
 * - 单段捷径：与 hslBandLuts 同公式（无钳位路径），两种模式逐位一致。
 * 直算（apply）与「建表 + 查表」（build_luts + lut_apply）共享同一
 * 逐 H 值合成 helper（mb_compose），故 func/lut 两模式逐位一致。
 */

#include <math.h>
#include <string.h>

/**
 * @brief Dart `_clampTo` 的浮点路径收尾：先比界、界内才 round()。
 * （同 isp_color_controller.c 的 cc_clamp_to，本文件 static 副本。）
 */
static uint16_t mb_clamp_to(double v, int max_value) {
  if (v < 0.0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  /* lround 快路径（界内 v ≥ 0）：floor(v+0.5) + 加法进位修正（t 恰为整
   * 数且 v 严格小于中点 t-0.5 时退一格），与 lround(v) 逐位一致——
   * libm lround 是函数调用，逐像素路径上占耗时大头（实测 4K ~64ms/帧）。 */
  {
    const double t = v + 0.5;
    const int r = (int)t;
    return (uint16_t)(t == (double)r && v < t - 0.5 ? r - 1 : r);
  }
}

/** Dart double.clamp(lo, hi)（入参均非 NaN 的使用域内）。 */
static double mb_clampd(double v, double lo, double hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/**
 * @brief 段在色相 h_deg（度）上的高斯权重（与 Dart multiBandLuts 的
 * weight 闭包逐行一致）。
 */
static double mb_weight(const IspMultiBandEqBand *b, double h_deg) {
  double d = fabs(h_deg - b->h);
  double x;
  d = fmod(d, 360.0);
  if (d > 180.0) d = 360.0 - d;
  x = d / (45.0 / b->q);
  return exp(-0.5 * x * x);
}

/**
 * @brief 单个量化 H 值上的合成结果（shift/s_mul/l_mul）：build_luts
 * 逐 hv 与 apply 逐像素共用，保证两条路径逐位一致。
 */
static void mb_compose(int hv, int max_value, int serial, int band_count,
                       const IspMultiBandEqBand *bands, int32_t *shift,
                       double *s_mul, double *l_mul) {
  /* Dart: hDeg = hv * 360.0 / maxValue */
  const double h_deg = (double)hv * 360.0 / (double)max_value;
  int i;

  /* 单段捷径：串联与并联语义相同，走色彩控制器同公式（Dart
   * multiBandLuts 委派 hslBandLuts，无钳位路径）。 */
  if (band_count == 1) {
    const double wgt = mb_weight(&bands[0], h_deg);
    /* Dart: (hShiftDeg * w / 360 * maxValue).round()（左结合顺序一致） */
    *shift = (int32_t)lround(bands[0].dh * wgt / 360.0 * (double)max_value);
    *s_mul = 1.0 + (bands[0].s - 1.0) * wgt;
    *l_mul = 1.0 + (bands[0].l - 1.0) * wgt;
    return;
  }

  if (!serial) {
    /* 并联：全部段在原 H 上各取权重，加权求和。 */
    double dh_sum = 0.0, s_sum = 0.0, l_sum = 0.0;
    for (i = 0; i < band_count; i++) {
      const double wgt = mb_weight(&bands[i], h_deg);
      dh_sum += wgt * bands[i].dh;
      s_sum += wgt * (bands[i].s - 1.0);
      l_sum += wgt * (bands[i].l - 1.0);
    }
    /* Dart: dhSum.clamp(-180.0, 180.0) → (dhClamped / 360 * maxValue).round() */
    *shift = (int32_t)lround(mb_clampd(dh_sum, -180.0, 180.0) / 360.0 *
                             (double)max_value);
    *s_mul = mb_clampd(1.0 + s_sum, 0.0, 5.0);
    *l_mul = mb_clampd(1.0 + l_sum, 0.0, 5.0);
  } else {
    /* 串联：按段序级联，后段在前段更新后的中间色相上取权重。 */
    double h_cur = h_deg, s_acc = 1.0, l_acc = 1.0;
    double dd;
    for (i = 0; i < band_count; i++) {
      const double wgt = mb_weight(&bands[i], h_cur);
      s_acc *= 1.0 + wgt * (bands[i].s - 1.0);
      l_acc *= 1.0 + wgt * (bands[i].l - 1.0);
      /* Dart double % 为欧几里得取模（结果恒非负）；C fmod 与被除数
       * 同号，负数加 360 修正后等价。 */
      h_cur = fmod(h_cur + wgt * bands[i].dh, 360.0);
      if (h_cur < 0.0) h_cur += 360.0;
    }
    /* 首尾色环最短路径偏移（多段累计量可超 ±180°，需环绕归一）。 */
    dd = fmod(h_cur - h_deg, 360.0);
    if (dd < 0.0) dd += 360.0;
    if (dd > 180.0) dd -= 360.0;
    if (dd < -180.0) dd += 360.0;
    *shift = (int32_t)lround(dd / 360.0 * (double)max_value);
    *s_mul = mb_clampd(s_acc, 0.0, 5.0);
    *l_mul = mb_clampd(l_acc, 0.0, 5.0);
  }
}

int isp_multi_band_eq_build_luts(int32_t *shift_lut, double *s_mul_lut,
                                 double *l_mul_lut, int max_value, int serial,
                                 int band_count,
                                 const IspMultiBandEqBand *bands) {
  int hv;
  if (shift_lut == NULL || s_mul_lut == NULL || l_mul_lut == NULL) {
    return ISP_ERR_ARG;
  }
  if (max_value <= 0) return ISP_ERR_SIZE;
  if (band_count < 0 || band_count > ISP_MULTI_BAND_EQ_MAX_BANDS) {
    return ISP_ERR_ARG;
  }
  if (band_count > 0 && bands == NULL) return ISP_ERR_ARG;
  for (hv = 0; hv < band_count; hv++) {
    /* σ = 45°/q，q 必须为正有限数（!(q>0) 同时挡住 NaN） */
    if (!(bands[hv].q > 0.0)) return ISP_ERR_ARG;
  }
  for (hv = 0; hv <= max_value; hv++) {
    mb_compose(hv, max_value, serial, band_count, bands, &shift_lut[hv],
               &s_mul_lut[hv], &l_mul_lut[hv]);
  }
  return ISP_OK;
}

int isp_multi_band_eq_lut_apply(const uint16_t *src, uint16_t *dst,
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
  /* 与 Dart applyHslBandLuts 一致：3 次查表 + 2 次乘法 + 色环回绕。
   * 回绕用单次条件加减替代 % m：表项恒满足 |shift| ≤ max_value/2（dh
   * ≤ ±180° 钳位，见 build_luts/mb_compose），hv ∈ [0, max_value]，与
   * ((x % m) + m) % m 逐位一致——max_value 为运行时参数，% 退化为逐像
   * 素整数除法，是单帧耗时大头。 */
  for (px = 0; px < px_count; px++) {
    const size_t i = px * 3u;
    int hv = (int)src[i];
    int h_new;
    if (hv > max_value) hv = max_value; /* 防御钳位（同色彩控制器） */
    h_new = hv + shift_lut[hv];
    if (h_new > max_value) {
      h_new -= m;
    } else if (h_new < 0) {
      h_new += m;
    }
    dst[i] = (uint16_t)h_new;
    dst[i + 1] = mb_clamp_to((double)src[i + 1] * s_mul_lut[hv], max_value);
    dst[i + 2] = mb_clamp_to((double)src[i + 2] * l_mul_lut[hv], max_value);
  }
  return ISP_OK;
}

int isp_multi_band_eq_apply(const uint16_t *src, uint16_t *dst,
                            int w, int h, int max_value, int serial,
                            int band_count, const IspMultiBandEqBand *bands) {
  const size_t px_count = (size_t)w * (size_t)h;
  const int m = max_value + 1;
  int identity = 1;
  int i;
  size_t px;
  if (src == NULL || dst == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0 || max_value <= 0) return ISP_ERR_SIZE;
  if (band_count < 0 || band_count > ISP_MULTI_BAND_EQ_MAX_BANDS) {
    return ISP_ERR_ARG;
  }
  if (band_count > 0 && bands == NULL) return ISP_ERR_ARG;
  for (i = 0; i < band_count; i++) {
    if (!(bands[i].q > 0.0)) return ISP_ERR_ARG;
    if (bands[i].dh != 0.0 || bands[i].s != 1.0 || bands[i].l != 1.0) {
      identity = 0;
    }
  }
  /* 恒等直通（Dart runner 的全段恒等判定）：输出缓冲由调用方提供，
   * 故把输入搬到输出（src == dst 时跳过）。 */
  if (identity) {
    if (dst != src) {
      memmove(dst, src, (size_t)w * (size_t)h * 3u * sizeof(uint16_t));
    }
    return ISP_OK;
  }
  for (px = 0; px < px_count; px++) {
    const size_t base = px * 3u;
    int hv = (int)src[base];
    int32_t shift;
    double s_mul, l_mul;
    int h_new;
    if (hv > max_value) hv = max_value;
    mb_compose(hv, max_value, serial, band_count, bands, &shift, &s_mul,
               &l_mul);
    /* 色环回绕：|shift| ≤ max_value/2（见 lut_apply 注），单次条件加减
     * 与取模逐位一致。 */
    h_new = hv + (int)shift;
    if (h_new > max_value) {
      h_new -= m;
    } else if (h_new < 0) {
      h_new += m;
    }
    dst[base] = (uint16_t)h_new;
    dst[base + 1] = mb_clamp_to((double)src[base + 1] * s_mul, max_value);
    dst[base + 2] = mb_clamp_to((double)src[base + 2] * l_mul, max_value);
  }
  return ISP_OK;
}
