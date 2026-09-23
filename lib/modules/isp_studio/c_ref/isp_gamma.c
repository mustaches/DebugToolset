/**
 * @file isp_gamma.c
 * @brief 伽马/色调映射节点实现。Dart 来源：isp_kernels.dart
 *        `_tonemapLut` / `tonemapToRgba`。详见头文件注释。
 */

#include "isp_gamma.h"

#include <math.h>

int isp_gamma_tonemap_to_rgba(const uint16_t *rgb, int w, int h,
                              int max_value, double gamma, double brightness,
                              double contrast, uint8_t *out_rgba,
                              uint8_t *lut_scratch) {
  const int64_t pixels = (int64_t)w * (int64_t)h;
  const double inv_gamma = 1.0 / gamma; /* Dart: invGamma 循环外只算一次 */
  int v;
  int64_t p, j;

  if (rgb == NULL || out_rgba == NULL || lut_scratch == NULL)
    return ISP_ERR_ARG;
  if (w < 0 || h < 0) return ISP_ERR_SIZE;
  /* Dart: maxValue < 1 与 gamma <= 0 均抛 ArgumentError。 */
  if (max_value < 1) return ISP_ERR_ARG;
  if (gamma <= 0.0) return ISP_ERR_ARG;

  /*
   * 构建色调映射 LUT（Dart `_tonemapLut`）：
   * 归一化 → 加亮度 → 绕 0.5 施加对比度 → 钳位 [0,1] →
   * pow(c, 1/gamma) → 再钳位 [0,1] → round(c*255)。
   * Dart double.round() 四舍五入、0.5 远离零，与 C99 llround 一致。
   */
  for (v = 0; v <= max_value; v++) {
    double c = (double)v / (double)max_value; /* Dart: v / maxValue 为 double 除法 */
    c += brightness;
    c = (c - 0.5) * contrast + 0.5;
    if (c < 0.0) c = 0.0;
    if (c > 1.0) c = 1.0;
    c = pow(c, inv_gamma);
    if (c < 0.0) c = 0.0;
    if (c > 1.0) c = 1.0;
    lut_scratch[v] = (uint8_t)llround(c * 255.0);
  }

  /*
   * 逐像素查表（Dart `tonemapToRgba` 主循环）：
   * 输入 r/g/b 只钳上界到 max_value（Dart 同样只判 > maxValue，
   * uint16 输入不可能为负）；alpha 恒 255。
   */
  j = 0;
  for (p = 0; p < pixels; p++, j += 4) {
    const int64_t i = p * 3;
    int r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
    if (r > max_value) r = max_value;
    if (g > max_value) g = max_value;
    if (b > max_value) b = max_value;
    out_rgba[j] = lut_scratch[r];
    out_rgba[j + 1] = lut_scratch[g];
    out_rgba[j + 2] = lut_scratch[b];
    out_rgba[j + 3] = 255;
  }
  return ISP_OK;
}
