#include "isp_blend.h"

/**
 * @file isp_blend.c
 * @brief ISP Studio C99 参考实现 —— 双源运算组实现（multiplier / adder / blender / mux4）。
 *
 * 覆盖范围与 Dart 来源对应关系见 isp_blend.h 文件头注释。
 * 本组函数均为逐像素双精度浮点中间计算 + `_clampTo` 收尾，无需临时缓冲。
 */

#include <math.h>

/**
 * @brief Dart `_clampTo` 的浮点路径复刻（isp_kernels.dart 845 行）。
 *
 * Dart 原式：v < 0 ? 0 : (v > maxValue ? maxValue : v.round())。
 * 注意顺序：**先按 double 原值与 0/maxValue 比较**（不先舍入），
 * 界内才调 round()。Dart double.round() 为「最邻近、半点远离零」，
 * 与 C99 round() 完全一致；此分支内 v >= 0，等价于四舍五入。
 * isp_common.h 的 isp_clamp_u16 只接收整数输入，故本 helper 为
 * 本文件私有 static（double 路径的钳位点不同，不能混用）。
 */
static uint16_t blend_clamp_to(double v, int max_value) {
  if (v < 0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  return (uint16_t)round(v);
}

int isp_blend_multiply(const uint16_t *a, const uint16_t *b, int n,
                       double offset1, double offset2, int max_value,
                       uint16_t *out) {
  if (a == NULL || b == NULL || out == NULL) return ISP_ERR_ARG;
  if (n <= 0 || max_value <= 0) return ISP_ERR_ARG;
  /* Dart：out[i] = _clampTo((a[i]+offset1) * (b[i]+offset2) / maxValue,
   * maxValue)——int+double 提升为 double，全程双精度。 */
  for (int i = 0; i < n; i++) {
    const double v =
        ((double)a[i] + offset1) * ((double)b[i] + offset2) / (double)max_value;
    out[i] = blend_clamp_to(v, max_value);
  }
  return ISP_OK;
}

int isp_blend_add(const uint16_t *a, const uint16_t *b, int n,
                  double balance, int max_value, uint16_t *out) {
  if (a == NULL || b == NULL || out == NULL) return ISP_ERR_ARG;
  if (n <= 0 || max_value <= 0) return ISP_ERR_ARG;
  /* Dart：wb = 1 - balance；out[i] = _clampTo(a[i]*balance + b[i]*wb,
   * maxValue)。两路增益总和恒为 1。 */
  const double wb = 1.0 - balance;
  for (int i = 0; i < n; i++) {
    const double v = (double)a[i] * balance + (double)b[i] * wb;
    out[i] = blend_clamp_to(v, max_value);
  }
  return ISP_OK;
}

int isp_blend_mask_apply(uint16_t *base, const uint16_t *blend,
                         const uint16_t *mask, int w, int h,
                         IspBlendFormat format, int blend_channels,
                         double strength, int max_value) {
  int channels;
  int pixels;
  double k;
  if (base == NULL || blend == NULL || mask == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0 || max_value <= 0) return ISP_ERR_ARG;
  if (blend_channels != 1 && blend_channels != 3) return ISP_ERR_ARG;
  switch (format) {
    case ISP_BLEND_FORMAT_RGB:
    case ISP_BLEND_FORMAT_YUV:
    case ISP_BLEND_FORMAT_HSL:
      channels = 3;
      break;
    case ISP_BLEND_FORMAT_MONO:
      channels = 1;
      break;
    default:
      return ISP_ERR_ARG;
  }
  /* Dart：if (strength == 0) return out; —— double 精确比较，基图不动。 */
  if (strength == 0) return ISP_OK;
  pixels = w * h;
  /* Dart：k = strength / maxValue（int 除数提升为 double）。 */
  k = strength / (double)max_value;
  for (int p = 0; p < pixels; p++) {
    const int i = p * channels;
    if (blend_channels == 3) {
      /* 三通道交织混叠图：逐通道对应叠加（Y 加到 Y、U 加到 U……），
       * 与基图格式无关（mono 基图时 channels=1，只取 blend 的 c=0，
       * 与 Dart 的 `for c in 0..channels` 行为一致）。 */
      for (int c = 0; c < channels; c++) {
        /* Dart 中 blend[p*3+c] 与 mask[p] 为 int，先按 64 位精确相乘
         * 再乘 double k（65535² 会溢出 int32，故经 int64 中转）。 */
        const double delta =
            (double)((int64_t)blend[p * 3 + c] * (int64_t)mask[p]) * k;
        /* Dart：if (delta <= 0) continue; —— 负 delta 不下压，基图保留。 */
        if (delta <= 0) continue;
        base[i + c] = blend_clamp_to((double)base[i + c] + delta, max_value);
      }
      continue;
    }
    /* mono 混叠图：单一增量按基图格式选目标通道。 */
    {
      const double delta =
          (double)((int64_t)blend[p] * (int64_t)mask[p]) * k;
      if (delta <= 0) continue;
      switch (format) {
        case ISP_BLEND_FORMAT_RGB:
          /* 三通道同加：等效亮度增量（不改变量比，不产生色偏）。 */
          for (int c = 0; c < 3; c++) {
            base[i + c] =
                blend_clamp_to((double)base[i + c] + delta, max_value);
          }
          break;
        case ISP_BLEND_FORMAT_YUV:
          /* 只加 Y（下标 i），U/V 不变。 */
          base[i] = blend_clamp_to((double)base[i] + delta, max_value);
          break;
        case ISP_BLEND_FORMAT_HSL:
          /* 只加 L（下标 i+2）。 */
          base[i + 2] = blend_clamp_to((double)base[i + 2] + delta, max_value);
          break;
        default: /* ISP_BLEND_FORMAT_MONO */
          base[i] = blend_clamp_to((double)base[i] + delta, max_value);
          break;
      }
    }
  }
  return ISP_OK;
}

const uint16_t *isp_mux4_select(int select, const uint16_t *in1,
                                const uint16_t *in2, const uint16_t *in3,
                                const uint16_t *in4) {
  /* Dart：select = (p['select'] ?? 1).clamp(1, 4)，越界钳位后纯透传。 */
  select = isp_clamp_int(select, 1, 4);
  switch (select) {
    case 1: return in1;
    case 2: return in2;
    case 3: return in3;
    default: return in4;
  }
}
