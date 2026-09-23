/**
 * @file isp_csc_common.h
 * @brief ISP Studio C99 参考实现 —— 色彩空间转换各变体共享的定点系数与
 *        单像素工具（仅内部使用：各 isp_csc_<变体>.c 包含本头；全部为宏与
 *        static inline 定义，不产生独立编译单元与外部符号，故无对应 .c）。
 *
 * 拆分说明：原 isp_csc.c/.h 为六向互转全家桶，单节点只用其中一个入口，
 * 编组导出会带入全部未用变体；现按变体拆为六对 isp_csc_<变体>.h/.c，
 * 共享部分集中于本头。编组导出/节点查看代码页只纳入实际用到的变体文件，
 * 忠实还原流程图。
 *
 * 数值一致性要点（与 Dart 逐位一致的关键点）：
 * - 定点路径一律用 64 位中间累加（Dart int 为 64 位；Q16 系数乘 16 位像素
 *   之和最高约 6e9，超出 32 位），再算术右移 16 位还原；
 * - 浮点路径先按 Dart 原式舍入为 int（round()：四舍五入、0.5 远离零），
 *   再按 _clampTo 的分支顺序钳位（先判 v < 0、再判 v > max_value）；
 * - Dart double 的 % 是欧几里得取模（结果符号随除数），C 侧用 fmod + 符号
 *   修正复刻；
 * - H 通道输入为 max_value 时，(h * inv) % 1.0 = 0.0，即色环绕回 0°，
 *   本实现保留该环绕语义。
 */

#ifndef ISP_CSC_COMMON_H
#define ISP_CSC_COMMON_H

#include "isp_common.h"

#include <math.h>

/* ---------------------------------------------------------------------------
 * Q16 定点系数（与 isp_kernels.dart 中的常量逐值一致）
 * ------------------------------------------------------------------------- */

/* BT.601 全范围（rgbToYuv / yuvToRgb / yuvToHsl / hslToYuv 共用） */
#define ISP_CSC_CY_R_601 19595   /* 0.299    * 65536 */
#define ISP_CSC_CY_G_601 38470   /* 0.587    * 65536 */
#define ISP_CSC_CY_B_601 7471    /* 0.114    * 65536 */
#define ISP_CSC_CU_R_601 (-11058) /* -0.168736 * 65536 */
#define ISP_CSC_CU_G_601 (-21710) /* -0.331264 * 65536 */
#define ISP_CSC_CU_B_601 32768   /* 0.5      * 65536 */
#define ISP_CSC_CV_R_601 32768   /* 0.5      * 65536 */
#define ISP_CSC_CV_G_601 (-27439) /* -0.418688 * 65536 */
#define ISP_CSC_CV_B_601 (-5329)  /* -0.081312 * 65536 */

/* BT.601 逆变换（yuvToRgb） */
#define ISP_CSC_CR_V 91881       /* 1.402     * 65536 */
#define ISP_CSC_CG_U (-22553)    /* -0.344136 * 65536 */
#define ISP_CSC_CG_V (-46801)    /* -0.714136 * 65536 */
#define ISP_CSC_CB_U 116130      /* 1.772     * 65536 */

/* BT.709 正向（convertRgbToYuvCsc 的 standard == 'bt709' 分支；
 * 注意 Dart 侧 BT.709 只覆盖 Y/U 两行系数与 V 的 G/B 分量，
 * cuB / cvR 沿用 BT.601 的 32768） */
#define ISP_CSC_CY_R_709 13933   /* 0.2126 * 65536 */
#define ISP_CSC_CY_G_709 46871   /* 0.7152 * 65536 */
#define ISP_CSC_CY_B_709 4732    /* 0.0722 * 65536 */
#define ISP_CSC_CU_R_709 (-7509) /* -0.1146 * 65536 */
#define ISP_CSC_CU_G_709 (-25260)/* -0.3854 * 65536 */
#define ISP_CSC_CV_G_709 (-29759)/* -0.4542 * 65536 */
#define ISP_CSC_CV_B_709 (-3009) /* -0.0458 * 65536 */

/* ---------------------------------------------------------------------------
 * 内部小工具（static inline：未引用的工具不产生符号，跨编译单元无冲突）
 * ------------------------------------------------------------------------- */

/**
 * @brief Dart double.round() 等价：四舍五入，恰为 .5 时远离零取整。
 * （Dart 的 round 是 half-away-from-zero，与 C 的 lround 语义相同，
 *   此处用 floor 显式实现，避免依赖平台 lround 的可用性。）
 */
static inline int64_t isp_csc_dround(double v) {
  return v >= 0.0 ? (int64_t)floor(v + 0.5) : -(int64_t)floor(-v + 0.5);
}

/**
 * @brief Dart `_clampTo` 等价：v < 0 ? 0 : (v > maxValue ? maxValue : v.round())。
 *
 * 注意分支顺序：先与 0 / max_value 比较（double 比较），仅在界内才做
 * round() 舍入；与「先舍入再钳位」在边界点（如 max_value + 0.4）结果不同，
 * 必须按 Dart 原顺序复刻。
 */
static inline int isp_csc_clamp_d(double v, int max_value) {
  if (v < 0) return 0;
  if (v > max_value) return max_value;
  return (int)isp_csc_dround(v);
}

/**
 * @brief Dart double 的 % 等价（欧几里得取模，除数 b > 0 时结果 ∈ [0, b)）。
 *
 * C 的 fmod 结果符号随被除数，Dart 的 % 结果符号随除数；本文件的用点
 * （rgbToHsl 的 `((g - b) / d) % 6`，hslToRgb/hslToYuv 的 `(h * inv) % 1.0`）
 * 除数均为正常数，故 fmod 后对负结果加 b 即逐位一致。
 */
static inline double isp_csc_euclid_mod(double a, double b) {
  double r = fmod(a, b);
  if (r < 0) r += b;
  return r;
}

/**
 * @brief Dart `_hueToRgb` 等价：HSL→RGB 的分段展开。
 *
 * Dart 来源：isp_kernels.dart `_hueToRgb`。阈值 1/6、1/2、2/3 均为 IEEE
 * double 字面量，C 侧 1.0/6.0 等与之位级一致。
 */
static inline double isp_csc_hue_to_rgb(double p, double q, double t) {
  double tt = t;
  if (tt < 0) tt += 1;
  if (tt > 1) tt -= 1;
  if (tt < 1.0 / 6.0) return p + (q - p) * 6.0 * tt;
  if (tt < 1.0 / 2.0) return q;
  if (tt < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - tt) * 6.0;
  return p;
}

/**
 * @brief 单像素 RGB→HSL（Dart `rgbToHsl` 的循环体）。
 *
 * @param ri/gi/bi  已钳位到 [0, max_value] 的 RGB 整数。
 * @param inv       1.0 / max_value。
 * @param out       输出 H/S/L（uint16_t[3]）。
 */
static inline void isp_csc_rgb_to_hsl_px(int ri, int gi, int bi, int max_value,
                                         double inv, uint16_t *out) {
  const double r = ri * inv;
  const double g = gi * inv;
  const double b = bi * inv;
  /* math.max(r, math.max(g, b)) / math.min(...) 的等价比较链 */
  double mx = g > b ? g : b;
  double mn = g < b ? g : b;
  double h = 0.0, s = 0.0, d, l;
  mx = r > mx ? r : mx;
  mn = r < mn ? r : mn;
  l = (mx + mn) / 2.0;
  d = mx - mn;
  if (d > 0) {
    s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
    if (mx == r) {
      /* Dart：((g - b) / d) % 6，欧几里得取模，结果 ∈ [0, 6) */
      h = isp_csc_euclid_mod((g - b) / d, 6.0);
    } else if (mx == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h /= 6.0;
    if (h < 0) h += 1.0; /* Dart 原式保留；欧几里得取模后实际不会触发 */
  }
  /* H 映射 0..360°→0..max_value（h 已归一化到 [0,1)），S/L 同域；
   * _clampTo 语义：先比界再 round() */
  out[0] = (uint16_t)isp_csc_clamp_d(h * max_value, max_value);
  out[1] = (uint16_t)isp_csc_clamp_d(s * max_value, max_value);
  out[2] = (uint16_t)isp_csc_clamp_d(l * max_value, max_value);
}

/**
 * @brief 单像素 HSL→RGB（Dart `hslToRgb` 的循环体），输出已按 _clampTo
 *        舍入钳位的整数，供 hslToRgb / hslToYuv 共用。
 *
 * @param hv/sv/lv  输入 H/S/L 原始采样值（Dart 不对输入做钳位，原样归一化）。
 * @param inv       1.0 / max_value。
 * @param ri/gi/bi  输出 RGB 整数（∈ [0, max_value]）。
 */
static inline void isp_csc_hsl_to_rgb_px(int hv, int sv, int lv, int max_value,
                                         double inv, int *ri, int *gi, int *bi) {
  /* Dart：(hsl[i] * inv) % 1.0 —— H = max_value 时归一化恰为 1.0，
   * % 1.0 后环绕回 0.0（色环 360° ≡ 0°），此处逐位复刻。 */
  const double h = isp_csc_euclid_mod(hv * inv, 1.0);
  const double s = sv * inv;
  const double l = lv * inv;
  double r, g, b;
  if (s == 0) {
    r = g = b = l;
  } else {
    const double q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    const double p = 2.0 * l - q;
    r = isp_csc_hue_to_rgb(p, q, h + 1.0 / 3.0);
    g = isp_csc_hue_to_rgb(p, q, h);
    b = isp_csc_hue_to_rgb(p, q, h - 1.0 / 3.0);
  }
  *ri = isp_csc_clamp_d(r * max_value, max_value);
  *gi = isp_csc_clamp_d(g * max_value, max_value);
  *bi = isp_csc_clamp_d(b * max_value, max_value);
}

/**
 * @brief 单像素 YUV→RGB 定点中间值（Dart `yuvToRgb` 的循环体，
 *        含三元钳位），供 yuvToRgb / yuvToHsl 共用。
 *
 * 乘积用 int64_t 累加（91881 * 32767 ≈ 3.0e9 已超 int32），`>> 16`
 * 为算术右移，与 Dart 64 位 int 的移位语义一致。
 */
static inline void isp_csc_yuv_to_rgb_px(int y, int u_in, int v_in, int half,
                                         int max_value, int *ri, int *gi, int *bi) {
  const int u = u_in - half;
  const int v = v_in - half;
  const int r = y + (int)(((int64_t)ISP_CSC_CR_V * v + 32768) >> 16);
  const int g =
      y + (int)(((int64_t)ISP_CSC_CG_U * u + (int64_t)ISP_CSC_CG_V * v + 32768) >> 16);
  const int b = y + (int)(((int64_t)ISP_CSC_CB_U * u + 32768) >> 16);
  *ri = isp_clamp_int(r, 0, max_value);
  *gi = isp_clamp_int(g, 0, max_value);
  *bi = isp_clamp_int(b, 0, max_value);
}

/**
 * @brief 单像素 RGB→YUV 定点公式（Dart `rgbToYuv` 的循环体，BT.601 全范围）。
 */
static inline void isp_csc_rgb_to_yuv_px(int r, int g, int b, int half, int max_value,
                                         uint16_t *out) {
  const int y = (int)(((int64_t)ISP_CSC_CY_R_601 * r + (int64_t)ISP_CSC_CY_G_601 * g +
                       (int64_t)ISP_CSC_CY_B_601 * b + 32768) >> 16);
  const int u = (int)(((int64_t)ISP_CSC_CU_R_601 * r + (int64_t)ISP_CSC_CU_G_601 * g +
                       (int64_t)ISP_CSC_CU_B_601 * b + 32768) >> 16) + half;
  const int v = (int)(((int64_t)ISP_CSC_CV_R_601 * r + (int64_t)ISP_CSC_CV_G_601 * g +
                       (int64_t)ISP_CSC_CV_B_601 * b + 32768) >> 16) + half;
  out[0] = isp_clamp_u16(y, max_value);
  out[1] = isp_clamp_u16(u, max_value);
  out[2] = isp_clamp_u16(v, max_value);
}

/** @brief 公共参数校验：非空指针、正宽高、正 max_value。 */
static inline int isp_csc_check(const uint16_t *src, const uint16_t *out, int w, int h,
                                int max_value) {
  if (src == NULL || out == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  if (max_value <= 0) return ISP_ERR_ARG;
  return ISP_OK;
}

#endif /* ISP_CSC_COMMON_H */
