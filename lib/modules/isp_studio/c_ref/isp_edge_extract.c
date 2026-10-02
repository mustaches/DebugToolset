#include "isp_edge_extract.h"

/**
 * @file isp_edge_extract.c
 * @brief ISP Studio C99 参考实现 —— 高频边缘提取节点（edge_extract）实现。
 *
 * 覆盖节点：edge_extract。
 * 对应 Dart 函数（lib/modules/isp_studio/pipeline/isp_kernels.dart）：
 * extractHighFreq、_clampTo（double 路径）；detail 定义与 applySharpen
 * 相同，RGB 域亮度公式与 rgbToYuv 的 Y 一致。
 */

#include <math.h>

/**
 * @brief 双精度 → uint16：先与 0/max_value 比较，未越界再四舍五入。
 *
 * Dart 来源：isp_kernels.dart `_clampTo(num v, int maxValue)` 的 double
 * 路径：`v < 0 ? 0 : (v > maxValue ? maxValue : v.round())`。
 * Dart double.round() 与 C99 lround 均为四舍五入、半数远离零。
 * 公共层 isp_clamp_u16 只接收 int，故本文件内置 static 版本
 * （与 isp_rgb_dnr.c / isp_sharpen.c 中的同名副本一致）。
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

int isp_edge_extract_run(const uint16_t *data, uint16_t *out, int width,
                         int height, IspEdgeExtractFormat format, double gain,
                         double threshold, int max_value, uint16_t *scratch) {
  uint16_t *const ys = scratch; /* w*h 亮度平面 */
  int mid;
  double mean_floor;
  double rel_threshold;
  size_t pixels;

  if (data == NULL || out == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  if (max_value <= 0 || max_value > 65535) return ISP_ERR_ARG;
  if (format != ISP_EDGE_EXTRACT_RGB && format != ISP_EDGE_EXTRACT_YUV &&
      format != ISP_EDGE_EXTRACT_HSL) {
    /* 对应 Dart default 分支抛 ArgumentError，C 侧以错误码报告。 */
    return ISP_ERR_ARG;
  }

  mid = max_value >> 1;
  /* Dart `maxValue / 128`：int/int 在 Dart 中得 double，非整除。 */
  mean_floor = (double)max_value / 128.0;
  /* Dart `threshold / maxValue`：同为 double 除法。 */
  rel_threshold = threshold / (double)max_value;
  pixels = (size_t)width * (size_t)height;

  /* 第一步：按色彩域抽取亮度平面。
   * RGB 域：BT.601 定点亮度（与 rgbToYuv 的 Y / applySharpen 同一公式，
   * 系数和 65536 不超 uint16，无钳位；乘积累加走 int64_t）；
   * YUV 域：通道 0（Y）；HSL 域：通道 2（L）。 */
  switch (format) {
    case ISP_EDGE_EXTRACT_RGB:
      for (size_t p = 0; p < pixels; p++) {
        const size_t i = p * 3;
        ys[p] = (uint16_t)((19595 * (int64_t)data[i] +
                            38470 * (int64_t)data[i + 1] +
                            7471 * (int64_t)data[i + 2] + 32768) >>
                           16);
      }
      break;
    case ISP_EDGE_EXTRACT_YUV:
      for (size_t p = 0; p < pixels; p++) {
        ys[p] = data[p * 3];
      }
      break;
    default: /* ISP_EDGE_EXTRACT_HSL */
      for (size_t p = 0; p < pixels; p++) {
        ys[p] = data[p * 3 + 2];
      }
      break;
  }

  /* 第二步：逐像素高通 + 相对对比度归一化 + √rel 显示压缩。
   * 循环内只读 ys（已全帧抽取完），故 out 允许与 data 重叠。 */
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      const size_t p = (size_t)y * (size_t)width + (size_t)x;
      const size_t i = p * 3;
      int sum = 0;
      int count = 0;
      double detail;
      double mean;
      double rel;
      uint16_t v;
      /* 3x3 盒式（含中心），越界裁剪丢弃（与 sharpen 同一边界口径）。 */
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          const int nx = x + dx;
          const int ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          sum += ys[(size_t)ny * (size_t)width + (size_t)nx];
          count++;
        }
      }
      /* Dart `ys[p] - sum / count`：double 除法，detail 为 double。 */
      detail = (double)ys[p] - (double)sum / (double)count;
      mean = (double)sum / (double)count;
      /* Dart `detail.abs() / (mean < meanFloor ? meanFloor : mean)`：
       * 均值下限防近黑区域除零爆增益；保持 Dart 原式（非 >= 的 max）。 */
      rel = fabs(detail) / (mean < mean_floor ? mean_floor : mean);
      /* Dart `if (rel < relThreshold) rel = 0;` —— 严格小于的相对门限。 */
      if (rel < rel_threshold) rel = 0.0;
      /* Dart `_clampTo(gain * math.sqrt(rel) * maxValue, maxValue)`：
       * 乘法左结合（gain×√rel 先乘），round 后钳位。 */
      v = clamp_round_u16(gain * sqrt(rel) * (double)max_value, max_value);
      /* 黑底白线：平坦区为黑、亮边暗边均为亮线；按域保持格式。 */
      switch (format) {
        case ISP_EDGE_EXTRACT_RGB:
          out[i] = v;
          out[i + 1] = v;
          out[i + 2] = v;
          break;
        case ISP_EDGE_EXTRACT_YUV:
          out[i] = v;
          out[i + 1] = (uint16_t)mid; /* U = 中灰 */
          out[i + 2] = (uint16_t)mid; /* V = 中灰 */
          break;
        default: /* ISP_EDGE_EXTRACT_HSL */
          out[i] = 0; /* H 无意义（S=0） */
          out[i + 1] = 0;
          out[i + 2] = v; /* L = v */
          break;
      }
    }
  }
  return ISP_OK;
}
