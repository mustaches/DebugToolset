#include "isp_clahe.h"

/**
 * @file isp_clahe.c
 * @brief ISP Studio C99 参考实现 —— 自适应直方图均衡（CLAHE）实现。
 *
 * 覆盖节点：ahe。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * - applyClahe        → isp_clahe_apply（RGB 版）
 * - applyClaheMono    → isp_clahe_apply_mono（单通道版）
 * - _claheTileLuts    → isp_clahe_build_luts_（static）
 * - _claheBilinear    → isp_clahe_bilinear_（static）
 * - _clampTo（double 路径）→ isp_clahe_clamp_to_（static，见该函数注释）
 *
 * scratch 布局与大小契约见 isp_clahe.h 的 ISP_CLAHE_SCRATCH_BYTES。
 */

#include <math.h>

/**
 * @brief Dart `_clampTo` 的 double 路径：先钳位再四舍五入。
 *
 * Dart 原式：v < 0 ? 0 : (v > maxValue ? maxValue : v.round())。
 * 注意顺序：与 0 / maxValue 的比较发生在舍入之前（如 v = maxValue + 0.4
 * 时直接取 maxValue，而不是先 round 得 maxValue 后再比较——此处结果相同，
 * 但 v = maxValue - 0.4 时 round 进位到 maxValue 也合法，两种路径殊途同归；
 * 唯一敏感点是 v.round() 为半值远离零舍入）。
 * 舍入用 C99 round()（半值远离零，与 Dart double.round() 同语义）；
 * 不用 floor(v + 0.5)，后者在 v 略小于 k.5 且 v + 0.5 浮点进位到
 * k + 1.0 时（如 0.49999999999999994）会多进 1，与 Dart 分歧。
 *
 * 说明：isp_common.h 的 isp_clamp_u16 只接收 int 输入，不覆盖本函数所需
 * 的 double 输入 + 半值远离零舍入语义，故按任务约定写为 static 局部
 * helper（若后续公共层补充 double 版 clamp，可替换）。
 */
static uint16_t isp_clahe_clamp_to_(double v, int max_value) {
  if (v < 0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  return (uint16_t)round(v);
}

/**
 * @brief 亮度值 v 落入的直方图 bin 下标。
 *
 * Dart 原式：v * _claheBins ~/ (maxValue + 1)（整数截断除，非负操作数
 * 与 C 的 / 语义一致）。v <= max_value 时结果恒在 [0, 255]；
 * 输入越出帧契约（v > max_value）时 Dart 会 RangeError，此处防御性
 * 钳到 255 继续运行。
 */
static int isp_clahe_bin_(int v, int max_value) {
  const int bin = v * ISP_CLAHE_BINS / (max_value + 1);
  return ISP_MIN(bin, ISP_CLAHE_BINS - 1);
}

/**
 * @brief 分 tile 构建 CLAHE 均衡 LUT（Dart `_claheTileLuts`）。
 *
 * 对单通道亮度平面 ys（w*h）按 block_size×block_size 分 tile 统计 256 bin
 * 直方图，按 clip_limit（tile 内平均计数的倍数）裁剪、超出量均匀再分配，
 * 再由累积分布（CDF）得各 tile 的均衡 LUT（bin → 均衡亮度，0..max_value）。
 * luts 长度 tiles_x*tiles_y*256，布局为 (ty * tiles_x + tx) * 256 + bin。
 *
 * 浮点求值顺序与 Dart 原式逐项一致（limit / excess / per / cdf 均为
 * double，cdf 按 b 升序累加），保证逐位一致。
 */
static void isp_clahe_build_luts_(const uint16_t *ys, int width, int height,
                                  int block_size, double clip_limit,
                                  int max_value, int tiles_x, int tiles_y,
                                  double *luts, double *hist) {
  for (int ty = 0; ty < tiles_y; ty++) {
    for (int tx = 0; tx < tiles_x; tx++) {
      /* 边缘 tile 可能不足 block_size：Dart 用 min(x0+bs, width) 裁剪。 */
      const int x0 = tx * block_size, y0 = ty * block_size;
      const int x1 = ISP_MIN(x0 + block_size, width);
      const int y1 = ISP_MIN(y0 + block_size, height);
      const int count = (x1 - x0) * (y1 - y0);
      for (int b = 0; b < ISP_CLAHE_BINS; b++) hist[b] = 0.0;
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          hist[isp_clahe_bin_(ys[y * width + x], max_value)] += 1.0;
        }
      }
      /* 裁剪：阈值为平均计数（count/bins）的 clip_limit 倍，
       * 超出量均匀再分配到全部 bin。 */
      const double limit = clip_limit * count / ISP_CLAHE_BINS;
      double excess = 0.0;
      for (int b = 0; b < ISP_CLAHE_BINS; b++) {
        if (hist[b] > limit) {
          excess += hist[b] - limit;
          hist[b] = limit;
        }
      }
      const double per = excess / ISP_CLAHE_BINS;
      double *lut = luts + (size_t)(ty * tiles_x + tx) * ISP_CLAHE_BINS;
      double cdf = 0.0;
      for (int b = 0; b < ISP_CLAHE_BINS; b++) {
        cdf += hist[b] + per;
        lut[b] = cdf / count * max_value;
      }
    }
  }
}

/**
 * @brief 4 tile 中心 LUT 双线性插值（Dart `_claheBilinear`）。
 *
 * 像素 (x, y) 的均衡亮度由周围 4 个 tile 中心的 LUT 插值得到：tile 中心
 * 位于各 tile 中点，坐标 fy = (y + 0.5) / blockSize - 0.5，ty0 = floor(fy)、
 * wy = fy - ty0；ty0 < 0 或 >= tilesY - 1 时钳到边界 tile 且 wy = 0
 * （边缘像素只用最近 tile 的 LUT）；ty1 = ty0 + 1（越界时退回 ty0）。
 * x 方向同理。插值先沿 x（top/bottom 两条），再沿 y，与 Dart 顺序一致。
 */
static double isp_clahe_bilinear_(const double *luts, int tiles_x, int tiles_y,
                                  int block_size, int x, int y, int v,
                                  int max_value) {
  const double fy = (y + 0.5) / block_size - 0.5;
  int ty0 = (int)floor(fy);
  double wy = fy - ty0;
  if (ty0 < 0) {
    ty0 = 0;
    wy = 0.0;
  } else if (ty0 >= tiles_y - 1) {
    ty0 = tiles_y - 1;
    wy = 0.0;
  }
  const int ty1 = (ty0 + 1 < tiles_y) ? ty0 + 1 : ty0;
  const double fx = (x + 0.5) / block_size - 0.5;
  int tx0 = (int)floor(fx);
  double wx = fx - tx0;
  if (tx0 < 0) {
    tx0 = 0;
    wx = 0.0;
  } else if (tx0 >= tiles_x - 1) {
    tx0 = tiles_x - 1;
    wx = 0.0;
  }
  const int tx1 = (tx0 + 1 < tiles_x) ? tx0 + 1 : tx0;
  const int bin = isp_clahe_bin_(v, max_value);
  const double l00 = luts[(size_t)(ty0 * tiles_x + tx0) * ISP_CLAHE_BINS + bin];
  const double l01 = luts[(size_t)(ty0 * tiles_x + tx1) * ISP_CLAHE_BINS + bin];
  const double l10 = luts[(size_t)(ty1 * tiles_x + tx0) * ISP_CLAHE_BINS + bin];
  const double l11 = luts[(size_t)(ty1 * tiles_x + tx1) * ISP_CLAHE_BINS + bin];
  const double top = l00 + (l01 - l00) * wx;
  const double bottom = l10 + (l11 - l10) * wx;
  return top + (bottom - top) * wy;
}

int isp_clahe_apply(uint16_t *rgb, int width, int height, int block_size,
                    double clip_limit, double strength, int max_value,
                    void *scratch) {
  /* Dart 首行短路：strength <= 0 时直接返回，不触碰帧数据。 */
  if (strength <= 0) return ISP_OK;
  if (rgb == NULL || scratch == NULL || max_value <= 0) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  /* Dart 的参数兜底修正（静默，不报错）。 */
  if (block_size < 2) block_size = 32;
  if (clip_limit <= 0) clip_limit = 1.0;

  const int tiles_x = (width + block_size - 1) / block_size;
  const int tiles_y = (height + block_size - 1) / block_size;
  /* scratch 分区：LUT 表 → 直方图工作区 → 亮度平面（double 区在前，
   * 基址 8 字节对齐时后续各区天然对齐）。 */
  double *luts = (double *)scratch;
  double *hist = luts + (size_t)tiles_x * tiles_y * ISP_CLAHE_BINS;
  uint16_t *ys = (uint16_t *)(hist + ISP_CLAHE_BINS);

  /* 1. 亮度平面：BT.601 定点加权和。Dart int 为 64 位，和最大约 4.29e9
   * 超出 32 位，必须用 int64_t 累加才能逐位一致。 */
  const int pixels = width * height;
  for (int p = 0; p < pixels; p++) {
    const int i = p * 3;
    const int64_t acc = 19595LL * rgb[i] + 38470LL * rgb[i + 1] +
                        7471LL * rgb[i + 2] + 32768;
    ys[p] = (uint16_t)(acc >> 16);
  }

  /* 2. 分 tile 直方图 → 裁剪再分配 → CDF LUT。 */
  isp_clahe_build_luts_(ys, width, height, block_size, clip_limit, max_value,
                        tiles_x, tiles_y, luts, hist);

  /* 3/4. 逐像素插值均衡亮度，按 Y'/Y 等比缩放三通道。 */
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      const int p = y * width + x;
      const int v = ys[p];
      if (v <= 0) continue; /* 黑像素无亮度比例可言，保持不动 */
      const double le = isp_clahe_bilinear_(luts, tiles_x, tiles_y,
                                            block_size, x, y, v, max_value);
      /* strength 混合在亮度域进行，再折算为通道缩放比。 */
      const double scale = (v + (le - v) * strength) / v;
      const int i = p * 3;
      rgb[i] = isp_clahe_clamp_to_(rgb[i] * scale, max_value);
      rgb[i + 1] = isp_clahe_clamp_to_(rgb[i + 1] * scale, max_value);
      rgb[i + 2] = isp_clahe_clamp_to_(rgb[i + 2] * scale, max_value);
    }
  }
  return ISP_OK;
}

int isp_clahe_apply_mono(uint16_t *mono, int width, int height,
                         int block_size, double clip_limit, double strength,
                         int max_value, void *scratch) {
  if (strength <= 0) return ISP_OK;
  if (mono == NULL || scratch == NULL || max_value <= 0) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  if (block_size < 2) block_size = 32;
  if (clip_limit <= 0) clip_limit = 1.0;

  const int tiles_x = (width + block_size - 1) / block_size;
  const int tiles_y = (height + block_size - 1) / block_size;
  /* mono 帧本身即亮度平面，只用 scratch 前部的 LUT + 直方图区。 */
  double *luts = (double *)scratch;
  double *hist = luts + (size_t)tiles_x * tiles_y * ISP_CLAHE_BINS;

  isp_clahe_build_luts_(mono, width, height, block_size, clip_limit,
                        max_value, tiles_x, tiles_y, luts, hist);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      const int p = y * width + x;
      const int v = mono[p];
      if (v <= 0) continue; /* 与 RGB 版一致：纯黑保持不动 */
      const double le = isp_clahe_bilinear_(luts, tiles_x, tiles_y,
                                            block_size, x, y, v, max_value);
      mono[p] = isp_clahe_clamp_to_(v + (le - v) * strength, max_value);
    }
  }
  return ISP_OK;
}
