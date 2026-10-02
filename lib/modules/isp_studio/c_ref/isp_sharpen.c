#include "isp_sharpen.h"

/**
 * @file isp_sharpen.c
 * @brief ISP Studio C99 参考实现 —— 锐化节点（sharpen）实现。
 *
 * 覆盖节点：sharpen。
 * 对应 Dart 函数（lib/modules/isp_studio/pipeline/isp_kernels.dart）：
 * applySharpen、_clampTo（double 路径）；亮度公式与 rgbToYuv 的 Y 一致。
 */

#include <math.h>

/**
 * @brief 双精度 → uint16：先与 0/max_value 比较，未越界再四舍五入。
 *
 * Dart 来源：isp_kernels.dart `_clampTo(num v, int maxValue)` 的 double
 * 路径：`v < 0 ? 0 : (v > maxValue ? maxValue : v.round())`。
 * Dart double.round() 与 C99 lround 均为四舍五入、半数远离零。
 * 公共层 isp_clamp_u16 只接收 int，故本文件内置 static 版本
 * （与 isp_rgb_dnr.c / isp_edge_extract.c 中的同名副本一致）。
 */
static uint16_t clamp_round_u16(double v, int max_value) {
  if (v < 0.0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  /* lround 快路径（界内 v ≥ 0）：floor(v+0.5) + 加法进位修正（t 恰为整
   * 数且 v 严格小于中点 t-0.5 时退一格），与 lround(v) 逐位一致——
   * libm lround 是函数调用，逐像素路径上占耗时大头。 */
  {
    const double t = v + 0.5;
    const int r = (int)t;
    return (uint16_t)(t == (double)r && v < t - 0.5 ? r - 1 : r);
  }
}

int isp_sharpen_apply(uint16_t *rgb, int width, int height, double amount,
                      double threshold, int max_value, uint16_t *scratch) {
  uint16_t *const ys = scratch; /* w*h 亮度平面 */

  if (rgb == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  if (max_value <= 0 || max_value > 65535) return ISP_ERR_ARG;
  /* Dart：`if (amount == 0) return;` —— 不修改任何像素。 */
  if (amount == 0.0) return ISP_OK;

  /* 第一步：全帧求 BT.601 定点亮度（与 rgbToYuv 的 Y 同一公式）。
   * 系数和 19595+38470+7471 = 65536，结果最大 (65536·65535+32768)>>16
   * = 65535，不超 uint16，Dart 此处无钳位；乘积累加走 int64_t
   * （Dart int 为 64 位，int32 会溢出）。 */
  {
    const size_t pixels = (size_t)width * (size_t)height;
    for (size_t p = 0; p < pixels; p++) {
      const size_t i = p * 3;
      ys[p] = (uint16_t)((19595 * (int64_t)rgb[i] +
                          38470 * (int64_t)rgb[i + 1] +
                          7471 * (int64_t)rgb[i + 2] + 32768) >>
                         16);
    }
  }

  /* 第二步：逐像素 unsharp mask。循环内只读 ys（已全帧算完）、只写 rgb
   * 当前像素，故 rgb 原地处理安全。 */
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      const size_t p = (size_t)y * (size_t)width + (size_t)x;
      const int v = ys[p];
      int sum = 0;
      int count = 0;
      double detail;
      double y2;
      double scale;
      /* 3x3 盒式（含中心），越界裁剪丢弃。 */
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          const int nx = x + dx;
          const int ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          sum += ys[(size_t)ny * (size_t)width + (size_t)nx];
          count++;
        }
      }
      /* Dart `v - sum / count`：sum/count 为 double 除法，detail 为
       * double（非整数截断），这是易错点。 */
      detail = (double)v - (double)sum / (double)count;
      /* Dart `if (detail.abs() < threshold) detail = 0;` —— 严格小于。 */
      if (fabs(detail) < threshold) detail = 0.0;
      /* Dart `if (detail == 0 || v <= 0) continue;` —— 像素保持不变。 */
      if (detail == 0.0 || v <= 0) continue;
      /* Dart `(v + amount * detail).clamp(0.0, maxValue.toDouble())`：
       * double 域钳位。 */
      y2 = (double)v + amount * detail;
      if (y2 < 0.0) {
        y2 = 0.0;
      } else if (y2 > (double)max_value) {
        y2 = (double)max_value;
      }
      /* 三通道按 Y'/Y 等比缩放，保持色调。v > 0 已在上面的 continue
       * 中保证，此处除法安全。 */
      scale = y2 / (double)v;
      rgb[p * 3] = clamp_round_u16((double)rgb[p * 3] * scale, max_value);
      rgb[p * 3 + 1] =
          clamp_round_u16((double)rgb[p * 3 + 1] * scale, max_value);
      rgb[p * 3 + 2] =
          clamp_round_u16((double)rgb[p * 3 + 2] * scale, max_value);
    }
  }
  return ISP_OK;
}
