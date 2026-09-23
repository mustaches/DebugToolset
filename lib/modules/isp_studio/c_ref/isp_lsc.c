/**
 * @file isp_lsc.c
 * @brief 镜头阴影/平场校正（LSC）实现，对应 isp_kernels.dart `applyLsc`。
 */

#include "isp_lsc.h"

#include <math.h>

int isp_lsc_apply(uint16_t *buf, int width, int height, double strength,
                  double center_x, double center_y, int max_value) {
  double cx, cy, ex, ey, r_max2;
  int x, y;
  size_t i;

  if (buf == NULL || max_value < 0) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;

  /* Dart: if (strength == 0) return; —— double 精确比较 */
  if (strength == 0.0) return ISP_OK;

  /* 中心像素坐标（double，不要求整数） */
  cx = center_x * (double)(width - 1);
  cy = center_y * (double)(height - 1);
  /* 到两侧边缘的最大距离，保证最远角的增益恰好为 1 + strength */
  ex = ISP_MAX(cx, (double)(width - 1) - cx);
  ey = ISP_MAX(cy, (double)(height - 1) - cy);
  r_max2 = ex * ex + ey * ey;
  if (r_max2 <= 0.0) return ISP_OK; /* 仅 1x1 帧触发 */

  i = 0;
  for (y = 0; y < height; y++) {
    const double dy = (double)y - cy;
    for (x = 0; x < width; x++, i++) {
      const double dx = (double)x - cx;
      const double gain = 1.0 + strength * (dx * dx + dy * dy) / r_max2;
      const double v = (double)buf[i] * gain;
      /* Dart `_clampTo`：先在 double 上钳位再 round()（半值远离零；
       * 负值已被前置钳位排除，floor(v+0.5) 与之等价） */
      if (v < 0.0) {
        buf[i] = 0;
      } else if (v > (double)max_value) {
        buf[i] = (uint16_t)max_value;
      } else {
        buf[i] = (uint16_t)floor(v + 0.5);
      }
    }
  }
  return ISP_OK;
}
