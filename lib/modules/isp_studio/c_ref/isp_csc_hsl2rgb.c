/**
 * @file isp_csc_hsl2rgb.c
 * @brief ISP Studio C99 参考实现 —— HSL→RGB 色彩空间转换（声明与语义
 *        见 isp_csc_hsl2rgb.h 头注释；单像素公式见 isp_csc_common.h）。
 */

#include "isp_csc_hsl2rgb.h"

#include "isp_csc_common.h"

int isp_csc_hsl_to_rgb(const uint16_t *hsl, int w, int h, int max_value,
                       uint16_t *out) {
  int rc = isp_csc_check(hsl, out, w, h, max_value);
  const size_t pixels = (size_t)w * (size_t)h;
  const double inv = 1.0 / max_value;
  size_t p, i;
  if (rc != ISP_OK) return rc;
  for (p = 0, i = 0; p < pixels; p++, i += 3) {
    int r, g, b;
    isp_csc_hsl_to_rgb_px(hsl[i], hsl[i + 1], hsl[i + 2], max_value, inv,
                          &r, &g, &b);
    out[i] = (uint16_t)r;
    out[i + 1] = (uint16_t)g;
    out[i + 2] = (uint16_t)b;
  }
  return ISP_OK;
}
