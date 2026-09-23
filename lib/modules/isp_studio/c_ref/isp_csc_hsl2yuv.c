/**
 * @file isp_csc_hsl2yuv.c
 * @brief ISP Studio C99 参考实现 —— HSL→YUV 色彩空间转换（声明与语义
 *        见 isp_csc_hsl2yuv.h 头注释；系数与工具见 isp_csc_common.h）。
 */

#include "isp_csc_hsl2yuv.h"

#include "isp_csc_common.h"

int isp_csc_hsl_to_yuv(const uint16_t *hsl, int w, int h, int max_value,
                       uint16_t *out) {
  int rc = isp_csc_check(hsl, out, w, h, max_value);
  const size_t pixels = (size_t)w * (size_t)h;
  const int half = max_value >> 1;
  const double inv = 1.0 / max_value;
  size_t p, i;
  if (rc != ISP_OK) return rc;
  for (p = 0, i = 0; p < pixels; p++, i += 3) {
    int r, g, b;
    /* 单遍融合：先按 hslToRgb 逻辑求 RGB 中间值（含 _clampTo 舍入钳位），
     * 再按 rgbToYuv 的 BT.601 全范围定点公式求 Y/U/V；不分配中间缓冲 */
    isp_csc_hsl_to_rgb_px(hsl[i], hsl[i + 1], hsl[i + 2], max_value, inv,
                          &r, &g, &b);
    isp_csc_rgb_to_yuv_px(r, g, b, half, max_value, out + i);
  }
  return ISP_OK;
}
