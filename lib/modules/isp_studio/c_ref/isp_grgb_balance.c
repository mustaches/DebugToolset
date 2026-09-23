/**
 * @file isp_grgb_balance.c
 * @brief Gr/Gb 均衡实现，对应 isp_kernels.dart `applyGrGbBalance`。
 */

#include "isp_grgb_balance.h"

#include <math.h>

int isp_grgb_balance_apply(uint16_t *buf, int width, int height,
                           IspBayerPattern pattern, double strength) {
  /* Dart 中 sum/cnt 为 int（64 位），这里用 int64_t 对齐累加范围 */
  int64_t sum_gr = 0, cnt_gr = 0, sum_gb = 0, cnt_gb = 0;
  double mean_gr, mean_gb, target, gain_gr, gain_gb;
  int x, y;
  size_t i;

  if (buf == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;

  /* Dart: if (strength <= 0) return; */
  if (strength <= 0.0) return ISP_OK;

  /* 第一遍：按水平邻相位分类统计 Gr/Gb 全局和与计数。
   * Gr：G 像素同行另一相位（x^1）为 R；Gb：为 B。 */
  i = 0;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++, i++) {
      if (isp_bayer_color_at(pattern, x, y) != ISP_CH_G) continue;
      if (isp_bayer_color_at(pattern, x ^ 1, y) == ISP_CH_R) {
        sum_gr += buf[i];
        cnt_gr++;
      } else {
        sum_gb += buf[i];
        cnt_gb++;
      }
    }
  }
  if (cnt_gr == 0 || cnt_gb == 0) return ISP_OK;

  /* Dart int/int 的 `/` 是 double 除法，必须先转 double 再除 */
  mean_gr = (double)sum_gr / (double)cnt_gr;
  mean_gb = (double)sum_gb / (double)cnt_gb;
  if (mean_gr <= 0.0 || mean_gb <= 0.0) return ISP_OK;

  /* 两相位均值的中点，按 strength 比例收敛 */
  target = (mean_gr + mean_gb) / 2.0;
  gain_gr = 1.0 + (target / mean_gr - 1.0) * strength;
  gain_gb = 1.0 + (target / mean_gb - 1.0) * strength;

  /* 第二遍：仅 G 相位像素乘对应增益。Dart 固定钳位 65535（无 max_value
   * 形参），截位语义同 `_clampTo`：double 上先钳位，再 round()
   * （非负域 floor(v+0.5) 等价半值远离零）。 */
  i = 0;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++, i++) {
      double v;
      if (isp_bayer_color_at(pattern, x, y) != ISP_CH_G) continue;
      v = (double)buf[i] *
          (isp_bayer_color_at(pattern, x ^ 1, y) == ISP_CH_R ? gain_gr
                                                             : gain_gb);
      if (v < 0.0) {
        buf[i] = 0;
      } else if (v > 65535.0) {
        buf[i] = 65535;
      } else {
        buf[i] = (uint16_t)floor(v + 0.5);
      }
    }
  }
  return ISP_OK;
}
