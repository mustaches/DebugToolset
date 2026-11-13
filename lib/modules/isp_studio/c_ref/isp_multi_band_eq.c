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

/* ------------------------------------------------------------------------- */
/* func_fixed 定点口径（codegenMode=func_fixed）：逐像素全整数定点直算，    */
/* 无 FP64/libm；与 Dart 参考 multiBandComposeFx / applyMultiBandEqFx        */
/* （isp_kernels.dart）逐行镜像、逐位一致；与 FP64 口径偏差 ≤1 LSB。         */
/* ------------------------------------------------------------------------- */

#define MB_FX_CIRCLE_Q16 23592960LL /* 360 << 16：色环一圈（Q16 度） */
#define MB_FX_HALF_Q16 11796480LL   /* 180 << 16：最短角距上界 */
#define MB_FX_C2_Q20 756405LL       /* round(0.5·log2(e)·2^20) */

/* 2^(−f)（f ∈ [0,1)）五次多项式系数的 Q16 值（dense grid 加权最小二乘拟
 * 合，相对误差口径；double 系数最大相对误差 ~2e-7，Q16 量化 + Horner 每
 * 级四舍五入后最大误差 2 ulp(Q16)；拟合脚本 scratch/fit_exp2_neg_poly.dart，
 * 与 Dart mbFxExp2NegCoefQ16 同值）。 */
static const int32_t MB_FX_EXP2_NEG_COEF[6] = {65536,  -45426, 15740,
                                               -3623,  603,    -62};

/** 定点段常量（帧入口由 double 段参数一次性换算，与 Dart MbFxBand 同口径）。 */
typedef struct {
  int32_t hc_q16; /**< 带中心色相（Q16 度，0..360<<16） */
  int32_t k_q20;  /**< q/45 的 Q20（x = d·q/45 的换算系数） */
  int32_t dh_q16; /**< 色相偏移（Q16 度） */
  int32_t s1_q14; /**< s−1 的 Q14 */
  int32_t l1_q14; /**< l−1 的 Q14 */
} MbFxBand;

/** 半值远离零的整数除法（v/d，d 为正偶数；与 Dart _mbFxRoundDiv 一致）。 */
static int64_t mb_fx_round_div(int64_t v, int64_t d) {
  return (v >= 0 ? v + (d >> 1) : v - (d >> 1)) / d;
}

/**
 * @brief 高斯权重 w = exp(−0.5·(d·q/45)²) 的 Q14 值（与 Dart
 * multiBandFxWeightQ14 逐行一致）：角距条件回绕（无 fmod）→ x² 整数乘 →
 * 2^(−u) 整数部移位 + 小数部五次多项式（Q16 Horner）。与 FP64 exp 口径
 * 偏差 ≤1 ulp(Q14)（全角距扫描实证）。
 */
static int32_t mb_fx_weight(int32_t h_q16, int32_t hc_q16, int32_t k_q20) {
  int64_t d = (int64_t)h_q16 - hc_q16;
  int64_t x_q20, x2_q20, u_q16, f, p;
  int n, k;
  if (d < 0) d = -d;
  if (d >= MB_FX_CIRCLE_Q16) d -= MB_FX_CIRCLE_Q16;
  if (d > MB_FX_HALF_Q16) d = MB_FX_CIRCLE_Q16 - d;
  x_q20 = (d * k_q20) >> 16;
  x2_q20 = (x_q20 * x_q20 + (1 << 19)) >> 20;
  u_q16 = (x2_q20 * MB_FX_C2_Q20 + (1 << 23)) >> 24;
  n = (int)(u_q16 >> 16);
  if (n >= 16) return 0; /* w·2^14 < 0.5，归 0 */
  f = u_q16 & 0xFFFF;
  p = MB_FX_EXP2_NEG_COEF[5];
  for (k = 4; k >= 0; k--) {
    p = MB_FX_EXP2_NEG_COEF[k] + ((f * p + 32768) >> 16);
  }
  return (int32_t)((p + ((int64_t)1 << (n + 1))) >> (n + 2));
}

/**
 * @brief 单个量化 H 值上的定点合成（shift/s_mul_q14/l_mul_q14）：与
 * Dart multiBandComposeFx 逐行一致；并联钳位、串联级联、单段无钳位
 * 捷径同 mb_compose 语义。
 */
static void mb_compose_fx(int hv, int max_value, int serial, int band_count,
                          const MbFxBand *fx, int32_t *shift,
                          int32_t *s_mul_q14, int32_t *l_mul_q14) {
  /* Dart: (hv * circleQ16 + maxValue/2) ~/ maxValue（Q16 度，四舍五入） */
  const int32_t h_q16 = (int32_t)(((int64_t)hv * MB_FX_CIRCLE_Q16 +
                                   (max_value >> 1)) /
                                  max_value);
  int i;

  /* 单段捷径：串联与并联语义相同，无钳位路径（同 hslBandLuts 口径）。 */
  if (band_count == 1) {
    const int32_t wgt = mb_fx_weight(h_q16, fx[0].hc_q16, fx[0].k_q20);
    *shift = (int32_t)mb_fx_round_div(
        (int64_t)wgt * fx[0].dh_q16 * max_value, 360LL << 30);
    *s_mul_q14 = 16384 + (int32_t)(((int64_t)wgt * fx[0].s1_q14 + 8192) >> 14);
    *l_mul_q14 = 16384 + (int32_t)(((int64_t)wgt * fx[0].l1_q14 + 8192) >> 14);
    return;
  }

  if (!serial) {
    /* 并联：dh_sum Q30、s/l_sum Q28，加权求和后钳位。 */
    int64_t dh_sum = 0, s_sum = 0, l_sum = 0;
    int64_t sm, lm;
    for (i = 0; i < band_count; i++) {
      const int32_t wgt = mb_fx_weight(h_q16, fx[i].hc_q16, fx[i].k_q20);
      dh_sum += (int64_t)wgt * fx[i].dh_q16;
      s_sum += (int64_t)wgt * fx[i].s1_q14;
      l_sum += (int64_t)wgt * fx[i].l1_q14;
    }
    if (dh_sum < -(180LL << 30)) {
      dh_sum = -(180LL << 30);
    } else if (dh_sum > (180LL << 30)) {
      dh_sum = 180LL << 30;
    }
    *shift = (int32_t)mb_fx_round_div(dh_sum * max_value, 360LL << 30);
    sm = 16384 + ((s_sum + 8192) >> 14);
    lm = 16384 + ((l_sum + 8192) >> 14);
    if (sm < 0) {
      sm = 0;
    } else if (sm > (5 << 14)) {
      sm = 5 << 14;
    }
    if (lm < 0) {
      lm = 0;
    } else if (lm > (5 << 14)) {
      lm = 5 << 14;
    }
    *s_mul_q14 = (int32_t)sm;
    *l_mul_q14 = (int32_t)lm;
  } else {
    /* 串联：h_cur Q16 逐段累加并条件回绕；S/L Q14 乘性合成。 */
    int64_t h_cur = h_q16, s_acc = 16384, l_acc = 16384, dd;
    for (i = 0; i < band_count; i++) {
      const int32_t wgt =
          mb_fx_weight((int32_t)h_cur, fx[i].hc_q16, fx[i].k_q20);
      s_acc = (s_acc * (16384 + (((int64_t)wgt * fx[i].s1_q14 + 8192) >> 14)) +
               8192) >>
              14;
      l_acc = (l_acc * (16384 + (((int64_t)wgt * fx[i].l1_q14 + 8192) >> 14)) +
               8192) >>
              14;
      h_cur += ((int64_t)wgt * fx[i].dh_q16 + 8192) >> 14;
      /* C 截断取模后负值加一圈，等价 Dart 欧几里得 %。 */
      h_cur %= MB_FX_CIRCLE_Q16;
      if (h_cur < 0) h_cur += MB_FX_CIRCLE_Q16;
    }
    /* 首尾色环最短路径偏移（欧几里得取模到 [0,360) 再归一 (−180,180]）。 */
    dd = (h_cur - h_q16) % MB_FX_CIRCLE_Q16;
    if (dd < 0) dd += MB_FX_CIRCLE_Q16;
    if (dd > MB_FX_HALF_Q16) dd -= MB_FX_CIRCLE_Q16;
    *shift = (int32_t)mb_fx_round_div(dd * max_value, 360LL << 16);
    if (s_acc < 0) {
      s_acc = 0;
    } else if (s_acc > (5 << 14)) {
      s_acc = 5 << 14;
    }
    if (l_acc < 0) {
      l_acc = 0;
    } else if (l_acc > (5 << 14)) {
      l_acc = 5 << 14;
    }
    *s_mul_q14 = (int32_t)s_acc;
    *l_mul_q14 = (int32_t)l_acc;
  }
}

/** Q14 定点乘 + 钳位（同 bb_clamp_q14 口径）：clamp((v·q + 2^13) >> 14)。 */
static uint16_t mb_fx_clamp_q14(int32_t v, int32_t q, int max_value) {
  const int64_t r = ((int64_t)v * q + 8192) >> 14;
  if (r < 0) return 0;
  if (r > (int64_t)max_value) return (uint16_t)max_value;
  return (uint16_t)r;
}

int isp_multi_band_eq_fx_apply(const uint16_t *src, uint16_t *dst,
                               int w, int h, int max_value, int serial,
                               int band_count,
                               const IspMultiBandEqBand *bands) {
  const size_t px_count = (size_t)w * (size_t)h;
  const int m = max_value + 1;
  MbFxBand fx[ISP_MULTI_BAND_EQ_MAX_BANDS];
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
  /* 恒等直通（Dart runner 的全段恒等判定，与 apply 同口径）。 */
  if (identity) {
    if (dst != src) {
      memmove(dst, src, (size_t)w * (size_t)h * 3u * sizeof(uint16_t));
    }
    return ISP_OK;
  }
  /* 帧入口一次性换算定点段常量（与 Dart multiBandFxBandConst 逐位一致：
   * llround 同 Dart round() 半值远离零；hc 截断取模后负值加一圈等价
   * Dart 欧几里得 %）。 */
  for (i = 0; i < band_count; i++) {
    int64_t hc = llround(bands[i].h * 65536.0) % MB_FX_CIRCLE_Q16;
    if (hc < 0) hc += MB_FX_CIRCLE_Q16;
    fx[i].hc_q16 = (int32_t)hc;
    fx[i].k_q20 = (int32_t)llround(bands[i].q / 45.0 * 1048576.0);
    fx[i].dh_q16 = (int32_t)llround(bands[i].dh * 65536.0);
    fx[i].s1_q14 = (int32_t)llround((bands[i].s - 1.0) * 16384.0);
    fx[i].l1_q14 = (int32_t)llround((bands[i].l - 1.0) * 16384.0);
  }
  for (px = 0; px < px_count; px++) {
    const size_t base = px * 3u;
    int hv = (int)src[base];
    int32_t shift, s_mul_q14, l_mul_q14;
    int h_new;
    if (hv > max_value) hv = max_value;
    mb_compose_fx(hv, max_value, serial, band_count, fx, &shift, &s_mul_q14,
                  &l_mul_q14);
    /* 色环回绕：|shift| ≤ max_value/2（见 lut_apply 注），单次条件加减
     * 与取模逐位一致。 */
    h_new = hv + (int)shift;
    if (h_new > max_value) {
      h_new -= m;
    } else if (h_new < 0) {
      h_new += m;
    }
    dst[base] = (uint16_t)h_new;
    dst[base + 1] = mb_fx_clamp_q14((int32_t)src[base + 1], s_mul_q14, max_value);
    dst[base + 2] = mb_fx_clamp_q14((int32_t)src[base + 2], l_mul_q14, max_value);
  }
  return ISP_OK;
}
