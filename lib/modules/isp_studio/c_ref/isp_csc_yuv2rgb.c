/**
 * @file isp_csc_yuv2rgb.c
 * @brief ISP Studio C99 参考实现 —— YUV→RGB 色彩空间转换（声明与语义
 *        见 isp_csc_yuv2rgb.h 头注释；系数与工具见 isp_csc_common.h）。
 */

#include "isp_csc_yuv2rgb.h"

#include "isp_csc_common.h"

int isp_csc_yuv_to_rgb(const uint16_t *yuv, int w, int h, int max_value,
                       uint16_t *out) {
  int rc = isp_csc_check(yuv, out, w, h, max_value);
  const size_t pixels = (size_t)w * (size_t)h;
  const int half = max_value >> 1;
  size_t p, i;
  if (rc != ISP_OK) return rc;
  for (p = 0, i = 0; p < pixels; p++, i += 3) {
    int r, g, b;
    isp_csc_yuv_to_rgb_px(yuv[i], yuv[i + 1], yuv[i + 2], half, max_value,
                          &r, &g, &b);
    out[i] = (uint16_t)r;
    out[i + 1] = (uint16_t)g;
    out[i + 2] = (uint16_t)b;
  }
  return ISP_OK;
}
