/**
 * @file isp_csc_rgb2hsl.c
 * @brief ISP Studio C99 参考实现 —— RGB→HSL 色彩空间转换（声明与语义
 *        见 isp_csc_rgb2hsl.h 头注释；单像素公式见 isp_csc_common.h）。
 */

#include "isp_csc_rgb2hsl.h"

#include "isp_csc_common.h"

int isp_csc_rgb_to_hsl(const uint16_t *rgb, int w, int h, int max_value,
                       uint16_t *out) {
  int rc = isp_csc_check(rgb, out, w, h, max_value);
  const size_t pixels = (size_t)w * (size_t)h;
  const double inv = 1.0 / max_value;
  size_t p, i;
  if (rc != ISP_OK) return rc;
  for (p = 0, i = 0; p < pixels; p++, i += 3) {
    isp_csc_rgb_to_hsl_px(rgb[i], rgb[i + 1], rgb[i + 2], max_value, inv, out + i);
  }
  return ISP_OK;
}
