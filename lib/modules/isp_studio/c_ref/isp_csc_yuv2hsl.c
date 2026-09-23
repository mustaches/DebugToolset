/**
 * @file isp_csc_yuv2hsl.c
 * @brief ISP Studio C99 参考实现 —— YUV→HSL 色彩空间转换（声明与语义
 *        见 isp_csc_yuv2hsl.h 头注释；单像素公式见 isp_csc_common.h）。
 */

#include "isp_csc_yuv2hsl.h"

#include "isp_csc_common.h"

int isp_csc_yuv_to_hsl(const uint16_t *yuv, int w, int h, int max_value,
                       uint16_t *out) {
  int rc = isp_csc_check(yuv, out, w, h, max_value);
  const size_t pixels = (size_t)w * (size_t)h;
  const int half = max_value >> 1;
  const double inv = 1.0 / max_value;
  size_t p, i;
  if (rc != ISP_OK) return rc;
  for (p = 0, i = 0; p < pixels; p++, i += 3) {
    int r, g, b;
    /* 单遍融合：先按 yuvToRgb 定点公式求 RGB 中间值（含钳位），
     * 再按 rgbToHsl 逻辑求 H/S/L；不分配中间缓冲，结果与两段中转逐点一致 */
    isp_csc_yuv_to_rgb_px(yuv[i], yuv[i + 1], yuv[i + 2], half, max_value,
                          &r, &g, &b);
    isp_csc_rgb_to_hsl_px(r, g, b, max_value, inv, out + i);
  }
  return ISP_OK;
}
