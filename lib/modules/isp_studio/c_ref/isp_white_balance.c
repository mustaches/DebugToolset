/**
 * @file isp_white_balance.c
 * @brief 白平衡节点实现。Dart 来源：isp_kernels.dart
 *        `autoWhiteBalanceGains` / `applyWhiteBalance`。详见头文件注释。
 */

#include "isp_white_balance.h"

#include <math.h>

/**
 * @brief 将 int64 值钳位到 [0, max_value] 后转为 uint16_t（本文件私有）。
 *
 * 语义同 isp_common.h 的 isp_clamp_u16，但输入域为 int64：
 * Dart 侧 (v*gain).round() 是 64 位 int，极端增益下可超出 int32，
 * 必须在 64 位域先钳位再窄化，才能与 Dart 逐位一致。
 */
ISP_INLINE uint16_t isp_wb_clamp_ll_(long long v, int max_value) {
  if (v < 0) return 0;
  if (v > (long long)max_value) return (uint16_t)max_value;
  return (uint16_t)v;
}

int isp_white_balance_auto_gains(const uint16_t *rgb, int w, int h,
                                 int sample_stride, double *r_gain,
                                 double *b_gain) {
  /* Dart: pixels = rgb.length ~/ 3；和/计数用 64 位（Dart int 为 64 位）。 */
  const int64_t pixels = (int64_t)w * (int64_t)h;
  int64_t stride;
  uint64_t sum_r = 0, sum_g = 0, sum_b = 0;
  int64_t count = 0;
  int64_t p;
  double mean_r, mean_g, mean_b;

  if (rgb == NULL || r_gain == NULL || b_gain == NULL) return ISP_ERR_ARG;
  if (w < 0 || h < 0) return ISP_ERR_SIZE;

  /* Dart: if (pixels == 0) return (1.0, 1.0); */
  if (pixels == 0) {
    *r_gain = 1.0;
    *b_gain = 1.0;
    return ISP_OK;
  }
  /* Dart: stride = sampleStride < 1 ? 1 : sampleStride; */
  stride = sample_stride < 1 ? 1 : sample_stride;

  /* 灰度世界统计：每隔 stride 个像素采一个样本，累加三通道值。 */
  for (p = 0; p < pixels; p += stride) {
    const int64_t i = p * 3;
    sum_r += rgb[i];
    sum_g += rgb[i + 1];
    sum_b += rgb[i + 2];
    count++;
  }
  /* Dart 防御分支：count == 0 时返回 (1.0, 1.0)（pixels > 0 时实际不可达）。 */
  if (count == 0) {
    *r_gain = 1.0;
    *b_gain = 1.0;
    return ISP_OK;
  }

  /* Dart: meanR = sumR / count（int / int 在 Dart 中为 double 除法）。 */
  mean_r = (double)sum_r / (double)count;
  mean_g = (double)sum_g / (double)count;
  mean_b = (double)sum_b / (double)count;
  /* Dart: meanR > 0 ? meanG / meanR : 1.0（meanB 同理）。 */
  *r_gain = mean_r > 0.0 ? mean_g / mean_r : 1.0;
  *b_gain = mean_b > 0.0 ? mean_g / mean_b : 1.0;
  return ISP_OK;
}

int isp_white_balance_apply(uint16_t *rgb, int w, int h, double r_gain,
                            double b_gain, int max_value) {
  const int64_t pixels = (int64_t)w * (int64_t)h;
  int64_t p;

  if (rgb == NULL) return ISP_ERR_ARG;
  if (w < 0 || h < 0) return ISP_ERR_SIZE;
  if (max_value < 0) return ISP_ERR_ARG;

  /* Dart: if (rGain == 1.0 && bGain == 1.0) return;（double 精确比较） */
  if (r_gain == 1.0 && b_gain == 1.0) return ISP_OK;

  /*
   * Dart 先为 R、B 各建一张 max_value+1 的 uint16 LUT：
   *   lut[v] = clamp((v * gain).round(), 0, maxValue)
   * 查表是纯函数，逐像素直接计算与查表逐位一致，故不建 LUT、无需 scratch。
   * Dart double.round() 为「四舍五入、0.5 远离零」，与 C99 llround 一致。
   * 钳位在 64 位域完成（Dart int 为 64 位，极端增益下 round 结果可超出
   * int32，先钳位再窄化可避免溢出），isp_wb_clamp_ll_ 为本文件私有 helper
   * （isp_common 的 isp_clamp_u16 只接收 int，无法承载 64 位中间值）。
   */
  for (p = 0; p < pixels; p++) {
    const int64_t i = p * 3;
    /* 只映射 R（i）与 B（i+2），G（i+1）保持不动（同 Dart 循环体）。 */
    rgb[i] = isp_wb_clamp_ll_(llround((double)rgb[i] * r_gain), max_value);
    rgb[i + 2] =
        isp_wb_clamp_ll_(llround((double)rgb[i + 2] * b_gain), max_value);
  }
  return ISP_OK;
}

int isp_white_balance_build_lut(double gain, int max_value,
                                uint16_t *lut_out) {
  int v;
  if (lut_out == NULL || max_value < 0) return ISP_ERR_ARG;
  /* 与 Dart whiteBalanceGainLut 逐位一致：llround 四舍五入远离零。 */
  for (v = 0; v <= max_value; v++) {
    lut_out[v] = isp_wb_clamp_ll_(llround((double)v * gain), max_value);
  }
  return ISP_OK;
}

int isp_white_balance_lut_apply(uint16_t *rgb, int w, int h,
                                const uint16_t *lut_r, const uint16_t *lut_b,
                                int max_value) {
  const int64_t pixels = (int64_t)w * (int64_t)h;
  int64_t p;
  if (rgb == NULL || lut_r == NULL || lut_b == NULL) return ISP_ERR_ARG;
  if (w < 0 || h < 0) return ISP_ERR_SIZE;
  if (max_value < 0) return ISP_ERR_ARG;
  /* 与 Dart applyWhiteBalanceLut 一致：只映射 R（i）与 B（i+2）。 */
  for (p = 0; p < pixels; p++) {
    const int64_t i = p * 3;
    rgb[i] = lut_r[rgb[i]];
    rgb[i + 2] = lut_b[rgb[i + 2]];
  }
  return ISP_OK;
}
