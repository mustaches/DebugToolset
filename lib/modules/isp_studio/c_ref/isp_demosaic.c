#include "isp_demosaic.h"

/**
 * @file isp_demosaic.c
 * @brief ISP Studio C99 参考实现 —— 去马赛克基础组（demosaic 节点）实现。
 *
 * 覆盖节点：demosaic 的 bilinear（Bayer）与全部非 Bayer CFA 路径。
 * Dart 来源：lib/modules/isp_studio/pipeline/isp_kernels.dart 的
 * demosaicBilinear / _avgNeighbors / _demosaicPixel / demosaicRccb /
 * demosaicRccc / demosaicRyycy / demosaicRgbIr 及 _interpChannel /
 * _channelAt / _clampTo。数值语义与 Dart 逐位一致（见各函数注释）。
 *
 * 本文件自带两个 static helper（未放入 isp_common，避免跨代理改动公共层）：
 * - isp_demosaic_interp_channel / isp_demosaic_channel_at：通用通道插值；
 * - isp_demosaic_clamp_double：_clampTo 的 double 路径。
 */

#include <math.h>

/* ---------------------------------------------------------------------------
 * 内部类型与常量
 * ------------------------------------------------------------------------- */

/** CFA 相位函数指针类型（签名与 isp_common.h 的 isp_cfa_*_at 一致）。 */
typedef int (*IspDemosaicCfaAtFn)(int x, int y);

/**
 * 轴向邻域偏移表。
 * Dart 来源：isp_kernels.dart `_axial`。
 */
static const int kIspDemosaicAxial[4][2] = {
    {-1, 0}, {1, 0}, {0, -1}, {0, 1}};

/**
 * 对角邻域偏移表。
 * Dart 来源：isp_kernels.dart `_diagonal`。
 */
static const int kIspDemosaicDiagonal[4][2] = {
    {-1, -1}, {1, -1}, {-1, 1}, {1, 1}};

/* ---------------------------------------------------------------------------
 * 内部 helper
 * ------------------------------------------------------------------------- */

/**
 * @brief _clampTo 的 double 路径：v < 0 → 0，v > max → max，否则 round()。
 *
 * Dart 来源：isp_kernels.dart `_clampTo(num v, int maxValue)` 当 v 为
 * double 时的分支。Dart double.round() 为四舍五入、半值远离零，
 * 与 C99 round() 一致。
 */
static uint16_t isp_demosaic_clamp_double(double v, int max_value) {
  if (v < 0.0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  return (uint16_t)round(v);
}

/**
 * @brief 平均 (x, y) 在 offsets 邻域内属于通道 color 的邻居。
 *
 * Dart 来源：isp_kernels.dart `_avgNeighbors`。
 * 越界邻居与颜色不符的邻居均跳过；平均式 (sum + count/2) / count
 * （Dart `(sum + count ~/ 2) ~/ count`，非负整数下与 C 整除一致，
 * 即四舍五入）；count == 0 时回退像素自身值。
 */
static int isp_demosaic_avg_neighbors(const uint16_t *bayer, int width,
                                      int height, int x, int y,
                                      IspBayerPattern pattern, int color,
                                      const int offsets[][2], int n_offsets) {
  int sum = 0;
  int count = 0;
  int k;
  for (k = 0; k < n_offsets; k++) {
    const int nx = x + offsets[k][0];
    const int ny = y + offsets[k][1];
    if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
    if (isp_bayer_color_at(pattern, nx, ny) != color) continue;
    sum += bayer[ny * width + nx];
    count++;
  }
  if (count == 0) return bayer[y * width + x];
  return (sum + count / 2) / count;
}

/**
 * @brief 按邻域搜索为 (x, y) 计算三个通道（Dart 的通用路径）。
 *
 * Dart 来源：isp_kernels.dart `_demosaicPixel`。
 * 说明：Dart demosaicBilinear 对内部像素走预计算 _PxPlan 快速路径，
 * 但快速路径的 (a+b+1)>>1 / (a+b+c+d+2)>>2 与本通用路径在内部像素上
 * 代数等价（内部像素邻居齐全：count 恰为 2 或 4，(sum+1)/2 == (sum+1)>>1，
 * (sum+2)/4 == (sum+2)>>2），故 C 版统一走本函数，结果逐位一致。
 */
static void isp_demosaic_pixel(const uint16_t *bayer, uint16_t *rgb_out,
                               int width, int height, int x, int y,
                               IspBayerPattern pattern) {
  const int i = (y * width + x) * 3;
  const int own = isp_bayer_color_at(pattern, x, y);
  const int self = bayer[y * width + x];
  int c;
  for (c = 0; c < 3; c++) {
    if (c == own) {
      rgb_out[i + c] = (uint16_t)self;
    } else if (c == 1) {
      /* R/B 站点缺 G：轴向邻居。 */
      rgb_out[i + c] = (uint16_t)isp_demosaic_avg_neighbors(
          bayer, width, height, x, y, pattern, c, kIspDemosaicAxial, 4);
    } else if (own == 1) {
      /* G 站点缺 R/B：该颜色的轴向邻居（横向或纵向，由颜色筛选决定）。 */
      rgb_out[i + c] = (uint16_t)isp_demosaic_avg_neighbors(
          bayer, width, height, x, y, pattern, c, kIspDemosaicAxial, 4);
    } else {
      /* R 站点缺 B（或反之）：对角邻居。 */
      rgb_out[i + c] = (uint16_t)isp_demosaic_avg_neighbors(
          bayer, width, height, x, y, pattern, c, kIspDemosaicDiagonal, 4);
    }
  }
}

/**
 * @brief 通用通道插值：平均 3x3 邻域内属于通道 ch 的样本，找不到时
 * 扩大到 5x5，仍没有则返回像素自身值。
 *
 * Dart 来源：isp_kernels.dart `_interpChannel`。
 * 注意每轮 radius 重新统计 sum/count（Dart 在 for 循环体内声明），
 * 且中心像素自身不计入（dx==0 && dy==0 跳过）。
 */
static int isp_demosaic_interp_channel(const uint16_t *mosaic, int width,
                                       int height, int x, int y, int ch,
                                       IspDemosaicCfaAtFn channel_at) {
  int radius;
  for (radius = 1; radius <= 2; radius++) {
    int sum = 0;
    int count = 0;
    int dy, dx;
    for (dy = -radius; dy <= radius; dy++) {
      for (dx = -radius; dx <= radius; dx++) {
        const int nx = x + dx;
        const int ny = y + dy;
        if (dx == 0 && dy == 0) continue;
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
        if (channel_at(nx, ny) != ch) continue;
        sum += mosaic[ny * width + nx];
        count++;
      }
    }
    if (count > 0) return (sum + count / 2) / count;
  }
  return mosaic[y * width + x];
}

/**
 * @brief 取像素 (x, y) 上通道 ch 的值：自身携带则用真值，否则邻域插值。
 *
 * Dart 来源：isp_kernels.dart `_channelAt`。
 */
static int isp_demosaic_channel_at(const uint16_t *mosaic, int width,
                                   int height, int x, int y, int ch,
                                   IspDemosaicCfaAtFn channel_at) {
  return channel_at(x, y) == ch
             ? mosaic[y * width + x]
             : isp_demosaic_interp_channel(mosaic, width, height, x, y, ch,
                                           channel_at);
}

/** 参数校验：空指针 / 非法尺寸。max_value 允许任意 int（Dart 侧亦不校验）。 */
static int isp_demosaic_check(const uint16_t *mosaic, int width, int height,
                              const uint16_t *rgb_out) {
  if (mosaic == NULL || rgb_out == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * 导出函数
 * ------------------------------------------------------------------------- */

/**
 * Dart 来源：isp_kernels.dart `demosaicBilinear`。
 * 全图统一走通用路径（与 Dart 快速路径逐位等价，见 isp_demosaic_pixel 注释）。
 */
int isp_demosaic_bilinear(const uint16_t *bayer, int width, int height,
                          IspBayerPattern pattern, uint16_t *rgb_out) {
  int x, y;
  const int rc = isp_demosaic_check(bayer, width, height, rgb_out);
  if (rc != ISP_OK) return rc;
  if (pattern < ISP_BAYER_RGGB || pattern > ISP_BAYER_GBRG) return ISP_ERR_ARG;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++) {
      isp_demosaic_pixel(bayer, rgb_out, width, height, x, y, pattern);
    }
  }
  return ISP_OK;
}

/**
 * Dart 来源：isp_kernels.dart `demosaicRccb`（rccg 参数）。
 * RCCB：G = round(C - (R+B)/2.0)（double 路径 _clampTo）；
 * RCCG：B = clamp_int(C - R - G)（纯整数路径 _clampTo，int.round() 恒等）。
 */
int isp_demosaic_rccb(const uint16_t *mosaic, int width, int height,
                      bool rccg, int max_value, uint16_t *rgb_out) {
  const IspDemosaicCfaAtFn at = rccg ? isp_cfa_rccg_at : isp_cfa_rccb_at;
  int x, y;
  size_t i = 0;
  const int rc = isp_demosaic_check(mosaic, width, height, rgb_out);
  if (rc != ISP_OK) return rc;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++, i += 3) {
      const int r =
          isp_demosaic_channel_at(mosaic, width, height, x, y, ISP_CH_R, at);
      const int c =
          isp_demosaic_channel_at(mosaic, width, height, x, y, ISP_CH_C, at);
      if (rccg) {
        const int g =
            isp_demosaic_channel_at(mosaic, width, height, x, y, ISP_CH_G, at);
        rgb_out[i] = (uint16_t)r;
        rgb_out[i + 1] = (uint16_t)g;
        /* Dart `_clampTo(c - r - g, maxValue)`：int 路径，仅钳位。 */
        rgb_out[i + 2] = isp_clamp_u16(c - r - g, max_value);
      } else {
        const int b = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                              ISP_CH_B, at);
        rgb_out[i] = (uint16_t)r;
        /* Dart `_clampTo(c - (r + b) / 2, maxValue)`：(r+b)/2 为 double
         * 除法，round() 半值远离零。 */
        rgb_out[i + 1] =
            isp_demosaic_clamp_double(c - (r + b) / 2.0, max_value);
        rgb_out[i + 2] = (uint16_t)b;
      }
    }
  }
  return ISP_OK;
}

/**
 * Dart 来源：isp_kernels.dart `demosaicRccc`。
 * G = B = round((C - R) / 2.0)（double 路径 _clampTo）。
 */
int isp_demosaic_rccc(const uint16_t *mosaic, int width, int height,
                      int max_value, uint16_t *rgb_out) {
  int x, y;
  size_t i = 0;
  const int rc = isp_demosaic_check(mosaic, width, height, rgb_out);
  if (rc != ISP_OK) return rc;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++, i += 3) {
      const int r = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                            ISP_CH_R, isp_cfa_rccc_at);
      const int c = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                            ISP_CH_C, isp_cfa_rccc_at);
      /* Dart `_clampTo((c - r) / 2, maxValue)`：(c-r)/2 为 double 除法。 */
      const uint16_t gb =
          isp_demosaic_clamp_double((c - r) / 2.0, max_value);
      rgb_out[i] = (uint16_t)r;
      rgb_out[i + 1] = gb;
      rgb_out[i + 2] = gb;
    }
  }
  return ISP_OK;
}

/**
 * Dart 来源：isp_kernels.dart `demosaicRyycy`。
 * G = clamp(Y - R)；B = clamp(Cy - G)（用上一步钳位后的 G），纯整数路径。
 */
int isp_demosaic_ryycy(const uint16_t *mosaic, int width, int height,
                       int max_value, uint16_t *rgb_out) {
  int x, y;
  size_t i = 0;
  const int rc = isp_demosaic_check(mosaic, width, height, rgb_out);
  if (rc != ISP_OK) return rc;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++, i += 3) {
      const int r = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                            ISP_CH_R, isp_cfa_ryycy_at);
      const int yv = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                             ISP_CH_Y, isp_cfa_ryycy_at);
      const int cy = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                             ISP_CH_CY, isp_cfa_ryycy_at);
      /* Dart `_clampTo(yv - r, maxValue)`：int 路径。 */
      const int g = isp_clamp_u16(yv - r, max_value);
      rgb_out[i] = (uint16_t)r;
      rgb_out[i + 1] = (uint16_t)g;
      /* Dart `_clampTo(cy - g, maxValue)`：用钳位后的 g。 */
      rgb_out[i + 2] = isp_clamp_u16(cy - g, max_value);
    }
  }
  return ISP_OK;
}

/**
 * Dart 来源：isp_kernels.dart `demosaicRgbIr`。
 * sub = ir * irSubtraction（double 乘法）；各通道 _clampTo(channel - sub)。
 */
int isp_demosaic_rgb_ir(const uint16_t *mosaic, int width, int height,
                        int max_value, double ir_subtraction,
                        uint16_t *rgb_out) {
  int x, y;
  size_t i = 0;
  const int rc = isp_demosaic_check(mosaic, width, height, rgb_out);
  if (rc != ISP_OK) return rc;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++, i += 3) {
      const int ir = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                             ISP_CH_IR, isp_cfa_rgbir_at);
      const double sub = ir * ir_subtraction;
      const int r = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                            ISP_CH_R, isp_cfa_rgbir_at);
      const int g = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                            ISP_CH_G, isp_cfa_rgbir_at);
      const int b = isp_demosaic_channel_at(mosaic, width, height, x, y,
                                            ISP_CH_B, isp_cfa_rgbir_at);
      rgb_out[i] = isp_demosaic_clamp_double(r - sub, max_value);
      rgb_out[i + 1] = isp_demosaic_clamp_double(g - sub, max_value);
      rgb_out[i + 2] = isp_demosaic_clamp_double(b - sub, max_value);
    }
  }
  return ISP_OK;
}
