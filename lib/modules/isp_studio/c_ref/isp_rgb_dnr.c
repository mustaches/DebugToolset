#include "isp_rgb_dnr.h"

/**
 * @file isp_rgb_dnr.c
 * @brief ISP Studio C99 参考实现 —— RGB 降噪节点（rgb_dnr）实现。
 *
 * 覆盖节点：rgb_dnr。
 * 对应 Dart 函数（lib/modules/isp_studio/pipeline/isp_kernels.dart）：
 * applyRgbDenoise、rgbToYuv、yuvToRgb、_clampTo（double 路径）、
 * _phaseNeighbors（pattern == null 的 mono 3x3 邻域）。
 */

#include <math.h>

/**
 * @brief 双精度 → uint16：先与 0/max_value 比较，未越界再四舍五入。
 *
 * Dart 来源：isp_kernels.dart `_clampTo(num v, int maxValue)` 的 double
 * 路径：`v < 0 ? 0 : (v > maxValue ? maxValue : v.round())`。
 * 注意语义顺序是「先比较、后取整」：只有未越界的值才执行 round()。
 * Dart double.round() 为四舍五入且半数远离零；C99 lround 同为半数远离零，
 * 两者一致。公共层 isp_clamp_u16 只接收 int，无法承担本职责，故本文件内
 * 置 static 版本（isp_sharpen.c / isp_edge_extract.c 各持一份同名副本）。
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

/* ---------------------------------------------------------------------------
 * BT.601 全范围 16 位定点系数（与 Dart rgbToYuv/yuvToRgb 中的常量一致，
 * 均为 0.x * 65536 的取整值）。乘积累加必须走 int64_t：
 * 65535 * 32768 + 32768 已超出 int32 上限，Dart int 为 64 位不会溢出。
 * Dart 的 >> 对负数为算术右移（向下取整）；MSVC/GCC/Clang/IAR 对负数
 * 有符号右移均为算术移位，与 Dart 一致。
 * ------------------------------------------------------------------------- */

/**
 * @brief 定点 rgbToYuv（单像素）。
 *
 * Dart 来源：isp_kernels.dart `rgbToYuv` 循环体。Y∈[0,maxValue]，U/V 以
 * half = maxValue>>1 为零点；加 32768 后 >>16 实现四舍五入的定点移位；
 * 三分量分别做 int 路径钳位（Dart 为三元比较，无 round）。
 */
static void rgb_to_yuv_pixel(const uint16_t *src, uint16_t *dst, int half,
                             int max_value) {
  const int64_t r = src[0];
  const int64_t g = src[1];
  const int64_t b = src[2];
  const int y = (int)((19595 * r + 38470 * g + 7471 * b + 32768) >> 16);
  const int u = (int)((-11058 * r - 21710 * g + 32768 * b + 32768) >> 16) + half;
  const int v = (int)((32768 * r - 27439 * g - 5329 * b + 32768) >> 16) + half;
  dst[0] = isp_clamp_u16(y, max_value);
  dst[1] = isp_clamp_u16(u, max_value);
  dst[2] = isp_clamp_u16(v, max_value);
}

/**
 * @brief 定点 yuvToRgb（单像素）。
 *
 * Dart 来源：isp_kernels.dart `yuvToRgb` 循环体。U/V 先减 half 还原零点，
 * R = Y + shift(91881·V)，G = Y + shift(-22553·U - 46801·V)，
 * B = Y + shift(116130·U)，int 路径钳位。
 */
static void yuv_to_rgb_pixel(const uint16_t *src, uint16_t *dst, int half,
                             int max_value) {
  const int64_t y = src[0];
  const int64_t u = (int)src[1] - half;
  const int64_t v = (int)src[2] - half;
  const int r = (int)(y + ((91881 * v + 32768) >> 16));
  const int g = (int)(y + ((-22553 * u - 46801 * v + 32768) >> 16));
  const int b = (int)(y + ((116130 * u + 32768) >> 16));
  dst[0] = isp_clamp_u16(r, max_value);
  dst[1] = isp_clamp_u16(g, max_value);
  dst[2] = isp_clamp_u16(b, max_value);
}

int isp_rgb_dnr_apply(uint16_t *rgb, int width, int height, double luma,
                      double chroma, int max_value, uint16_t *scratch) {
  /* scratch 布局见头文件 ISP_RGB_DNR_SCRATCH_BYTES 注释。 */
  int half;
  size_t pixels;
  uint16_t *yuv;   /* w*h*3 */
  uint16_t *ys;    /* w*h   */
  uint16_t *src_u; /* w*h   */
  uint16_t *src_v; /* w*h   */

  if (rgb == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  if (max_value <= 0 || max_value > 65535) return ISP_ERR_ARG;
  /* Dart：`if (luma <= 0 && chroma <= 0) return;` —— 不修改任何像素。 */
  if (luma <= 0.0 && chroma <= 0.0) return ISP_OK;

  half = max_value >> 1;
  pixels = (size_t)width * (size_t)height;
  yuv = scratch;
  ys = yuv + pixels * 3;
  src_u = ys + pixels;
  src_v = src_u + pixels;

  /* 第一步：rgbToYuv 全帧定点转换到 scratch 的 yuv 平面。 */
  for (size_t p = 0; p < pixels; p++) {
    rgb_to_yuv_pixel(rgb + p * 3, yuv + p * 3, half, max_value);
  }

  /* 第二步：亮度 3x3 保边加权平均（Dart luma > 0 分支）。
   * 邻居集合与取值顺序复用公共层 isp_phase_neighbors（pattern 传 NULL
   * 即 Dart `_phaseNeighbors(..., null)`：步进 ±1、去掉中心、越界裁剪、
   * dy 外层 dx 内层行优先），浮点累加顺序与 Dart 完全一致。 */
  if (luma > 0.0) {
    uint16_t nb[8];
    for (size_t p = 0; p < pixels; p++) {
      ys[p] = yuv[p * 3];
    }
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        const size_t p = (size_t)y * (size_t)width + (size_t)x;
        const int v = ys[p];
        /* σ = luma × √(v+64)：噪声随亮度增长的模型。 */
        const double sigma = luma * sqrt((double)(v + 64));
        double sum = (double)v; /* 中心权重 1 */
        double wsum = 1.0;
        const int n =
            isp_phase_neighbors(ys, width, height, x, y, NULL, nb);
        for (int k = 0; k < n; k++) {
          const double d = (double)((int)nb[k] - v);
          const double t = d / sigma;
          /* w = 1/(1+(d/σ)^2)：差异越大权重越小，保边。 */
          const double wgt = 1.0 / (1.0 + t * t);
          sum += wgt * (double)nb[k];
          wsum += wgt;
        }
        /* Dart `_clampTo(sum / wsum, maxValue)`：round 后钳位。 */
        yuv[p * 3] = clamp_round_u16(sum / wsum, max_value);
      }
    }
  }

  /* 第三步：色度 3x3 盒式低通按 blend 混合（Dart chroma > 0 分支）。
   * Dart 先 `Uint16List.fromList(yuv)` 整体快照，循环内只读快照；
   * 此处仅快照 U/V 两个平面（Y 平面循环内不读，无需复制），数值等价。 */
  if (chroma > 0.0) {
    /* Dart `chroma.clamp(0.0, 1.0)`。 */
    const double blend =
        chroma < 0.0 ? 0.0 : (chroma > 1.0 ? 1.0 : chroma);
    for (size_t p = 0; p < pixels; p++) {
      src_u[p] = yuv[p * 3 + 1];
      src_v[p] = yuv[p * 3 + 2];
    }
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        const size_t p = (size_t)y * (size_t)width + (size_t)x;
        /* Dart `for (final c in [1, 2])`：U、V 两通道。 */
        for (int c = 0; c < 2; c++) {
          const uint16_t *const plane = (c == 0) ? src_u : src_v;
          int sum = 0;
          int count = 0;
          /* 3x3 盒式（含中心），越界裁剪丢弃。 */
          for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
              const int nx = x + dx;
              const int ny = y + dy;
              if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
              sum += plane[(size_t)ny * (size_t)width + (size_t)nx];
              count++;
            }
          }
          /* Dart `sum / count` 为 double 除法（Dart int/int 得 double）。 */
          const double avg = (double)sum / (double)count;
          /* src×(1-blend) + avg×blend，经 _clampTo（round+钳位）写回。 */
          yuv[p * 3 + 1 + c] = clamp_round_u16(
              (double)plane[p] * (1.0 - blend) + avg * blend, max_value);
        }
      }
    }
  }

  /* 第四步：yuvToRgb 全帧定点转换写回 rgb（Dart `rgb.setAll(0, ...)`）。 */
  for (size_t p = 0; p < pixels; p++) {
    yuv_to_rgb_pixel(yuv + p * 3, rgb + p * 3, half, max_value);
  }
  return ISP_OK;
}
