#include "isp_demosaic_adv.h"

/**
 * @file isp_demosaic_adv.c
 * @brief ISP Studio C99 参考实现 —— 高级 Bayer 去马赛克（MHC / AAHD / AMaZE / LMMSE / IGV）。
 *
 * 覆盖节点：demosaic（去马赛克）节点的 algorithm 参数 mhc / aahd / amaze /
 * lmmse / igv 五条路径。逐函数移植 demosaic_advanced.dart 的简化实现，
 * 公共件（_gHorz/_gVert/_fillChrominance/_median9/_rgbToLab/_conv5/_emit/
 * _clamp16）移植为本文件 static 函数。契约与数值要点见 isp_demosaic_adv.h
 * 文件头注释。
 */

#include <math.h>
#include <string.h>

#include "isp_demosaic.h" /* isp_demosaic_bilinear（边界环与小图回退铺底） */

/* ---------------------------------------------------------------------------
 * 公共件（对应 demosaic_advanced.dart 的私有 helper）
 * ------------------------------------------------------------------------- */

/**
 * @brief Dart `_clamp16` 的 double 路径：先比较 0 / maxValue，再 round()。
 *
 * Dart 来源：demosaic_advanced.dart `_clamp16`：
 * `v < 0 ? 0 : (v > maxValue ? maxValue : v.round())`。
 * 比较发生在未舍入的 double 上；Dart double.round() 为四舍五入
 * （半数远离零），与 C99 round() 一致。v >= 0 分支内 round(v) <= maxValue。
 */
static uint16_t isp_dmv_clamp16(double v, int max_value) {
  if (v < 0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  return (uint16_t)round(v);
}

/**
 * @brief 写出内部像素（三通道各经 isp_dmv_clamp16 钳位）。
 *
 * Dart 来源：demosaic_advanced.dart `_emit`。
 */
static void isp_dmv_emit(uint16_t *rgb, int p, double r, double g, double b,
                         int max_value) {
  const int i = p * 3;
  rgb[i] = isp_dmv_clamp16(r, max_value);
  rgb[i + 1] = isp_dmv_clamp16(g, max_value);
  rgb[i + 2] = isp_dmv_clamp16(b, max_value);
}

/**
 * @brief 方向性 G 估计（梯度校正）：R/B 站点沿水平方向。
 *
 * Dart 来源：demosaic_advanced.dart `_gHorz`：
 * g = (G_W+G_E)/2 + (2C − C_W2 − C_E2)/4。调用方保证 p±2 不越界。
 */
static double isp_dmv_g_horz(const uint16_t *bayer, int p) {
  return (bayer[p - 1] + bayer[p + 1]) / 2.0 +
         (2.0 * bayer[p] - bayer[p - 2] - bayer[p + 2]) / 4.0;
}

/**
 * @brief 方向性 G 估计：垂直方向（同 isp_dmv_g_horz，步进换行宽）。
 *
 * Dart 来源：demosaic_advanced.dart `_gVert`。调用方保证 p±2*width 不越界。
 */
static double isp_dmv_g_vert(const uint16_t *bayer, int width, int p) {
  return (bayer[p - width] + bayer[p + width]) / 2.0 +
         (2.0 * bayer[p] - bayer[p - 2 * width] - bayer[p + 2 * width]) / 4.0;
}

/**
 * @brief 色差平滑插值：在已知 G 平面 g 上重建通道 color（0=R / 2=B）。
 *
 * Dart 来源：demosaic_advanced.dart `_fillChrominance`。
 * 同色站点取真值；其余像素用 ±2 邻域内同色站点的 (C−G) 均值加回 G。
 * g 仅在 border 环以内有效，邻域触及无效区的采样点直接跳过。
 * 浮点累加顺序与 Dart 一致（dy 外层、dx 内层），保证逐位一致。
 */
static void isp_dmv_fill_chrominance(double *ch, const double *g,
                                     const uint16_t *bayer, int color,
                                     int width, int height,
                                     IspBayerPattern pattern, int border) {
  int x, y, dx, dy;
  for (y = border; y < height - border; y++) {
    for (x = border; x < width - border; x++) {
      const int p = y * width + x;
      double sum = 0.0;
      int count = 0;
      if (isp_bayer_color_at(pattern, x, y) == color) {
        ch[p] = bayer[p];
        continue;
      }
      for (dy = -2; dy <= 2; dy++) {
        const int ny = y + dy;
        if (ny < border || ny >= height - border) continue;
        for (dx = -2; dx <= 2; dx++) {
          const int nx = x + dx;
          int q;
          if (dx == 0 && dy == 0) continue;
          if (nx < border || nx >= width - border) continue;
          if (isp_bayer_color_at(pattern, nx, ny) != color) continue;
          q = ny * width + nx;
          sum += bayer[q] - g[q];
          count++;
        }
      }
      ch[p] = g[p] + (count > 0 ? sum / count : 0.0);
    }
  }
}

/**
 * @brief 3x3 中值（AMaZE 色差平面去拉链用），取第 5 小值 v[4]。
 *
 * Dart 来源：demosaic_advanced.dart `_median9`（收集 3x3 后 ..sort() 取 v[4]）。
 * 插入排序与 Dart sort 的结果值相同（同值元素取哪个不影响数值）。
 */
static double isp_dmv_median9(const double *plane, int width, int x, int y) {
  double v[9];
  int n = 0, i, j, dx, dy;
  for (dy = -1; dy <= 1; dy++) {
    for (dx = -1; dx <= 1; dx++) {
      v[n++] = plane[(y + dy) * width + x + dx];
    }
  }
  for (i = 1; i < 9; i++) {
    const double t = v[i];
    for (j = i - 1; j >= 0 && v[j] > t; j--) {
      v[j + 1] = v[j];
    }
    v[j + 1] = t;
  }
  return v[4];
}

/**
 * @brief sRGB 分量线性化（_rgbToLab 内部件）。
 *
 * Dart 来源：demosaic_advanced.dart `_rgbToLab` 的 lin()。
 * 注意负值走线性分支（c <= 0.04045），不会进入 pow。
 */
static double isp_dmv_srgb_lin(double c) {
  return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

/**
 * @brief CIELab 立方根分段函数（_rgbToLab 内部件）。
 *
 * Dart 来源：demosaic_advanced.dart `_rgbToLab` 的 f()。
 * Dart 的 `16 / 116` 是 double 除法（≈0.137931），此处必须写 16.0 / 116，
 * 写成整数 16/116 会得到 0（易错点）。`pow(t, 1/3)` 的 1/3 同样是 double。
 */
static double isp_dmv_lab_f(double t) {
  return t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116;
}

/**
 * @brief 简化 sRGB → CIELab（D65）。输入归一化 0..1 的线性化前 RGB。
 *
 * Dart 来源：demosaic_advanced.dart `_rgbToLab`。
 */
static void isp_dmv_rgb_to_lab(double r, double g, double b, double *out_l,
                               double *out_a, double *out_b) {
  const double rl = isp_dmv_srgb_lin(r);
  const double gl = isp_dmv_srgb_lin(g);
  const double bl = isp_dmv_srgb_lin(b);
  const double x = (0.4124 * rl + 0.3576 * gl + 0.1805 * bl) / 0.95047;
  const double y = 0.2126 * rl + 0.7152 * gl + 0.0722 * bl;
  const double z = (0.0193 * rl + 0.1192 * gl + 0.9505 * bl) / 1.08883;
  const double fx = isp_dmv_lab_f(x);
  const double fy = isp_dmv_lab_f(y);
  const double fz = isp_dmv_lab_f(z);
  *out_l = 116.0 * fy - 16.0;
  *out_a = 500.0 * (fx - fy);
  *out_b = 200.0 * (fy - fz);
}

/* ---------------------------------------------------------------------------
 * 参数校验（五个导出函数共用）
 * ------------------------------------------------------------------------- */

/**
 * @brief 公共参数检查：空指针、尺寸、pattern 枚举、max_value 范围。
 *
 * Dart 侧无显式校验（由调用方保证）；C 侧按 c_ref 规范做防御性检查。
 */
static int isp_dmv_check(const uint16_t *bayer, int width, int height,
                         IspBayerPattern pattern, int max_value,
                         const uint16_t *rgb_out) {
  if (bayer == NULL || rgb_out == NULL) return ISP_ERR_ARG;
  if (pattern < ISP_BAYER_RGGB || pattern > ISP_BAYER_GBRG) return ISP_ERR_ARG;
  if (max_value <= 0 || max_value > 65535) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * MHC（Malvar, He, Cutler 2004）
 * ------------------------------------------------------------------------- */

/* Malvar 2004 的 5x5 线性核（×2 整数化，/16 归一化），与 Dart 常量一致。 */

/** G @ R/B 站点（Dart `_kGatC`）。 */
static const int kIspDmvGatC[5][5] = {
    {0, 0, -2, 0, 0},
    {0, 0, 4, 0, 0},
    {-2, 4, 8, 4, -2},
    {0, 0, 4, 0, 0},
    {0, 0, -2, 0, 0},
};

/** R/B @ 同色横行的 G 站点（Dart `_kCatGRow`）。 */
static const int kIspDmvCatGRow[5][5] = {
    {0, 0, 1, 0, 0},
    {0, -2, 0, -2, 0},
    {-2, 8, 10, 8, -2},
    {0, -2, 0, -2, 0},
    {0, 0, 1, 0, 0},
};

/** R/B @ 同色竖列的 G 站点（Dart `_kCatGCol`，为 _kCatGRow 的转置）。 */
static const int kIspDmvCatGCol[5][5] = {
    {0, 0, -2, 0, 0},
    {0, -2, 8, -2, 0},
    {1, 0, 10, 0, 1},
    {0, -2, 8, -2, 0},
    {0, 0, -2, 0, 0},
};

/** R @ B 站点 / B @ R 站点（对角方向，Dart `_kCatOpp`）。 */
static const int kIspDmvCatOpp[5][5] = {
    {0, 0, -3, 0, 0},
    {0, 4, 0, 4, 0},
    {-3, 0, 12, 0, -3},
    {0, 4, 0, 4, 0},
    {0, 0, -3, 0, 0},
};

/**
 * @brief 5x5 整数卷积（核系数和为 16，+8 四舍五入后右移 4 位）。
 *
 * Dart 来源：demosaic_advanced.dart `_conv5`。调用方保证 (x, y) 距边界
 * ≥2 像素。acc 为 int（最坏 |acc| < 16*65535 << 2^31，不溢出）；
 * (acc + 8) >> 4 对负 acc 依赖算术右移，MSVC/GCC/主流嵌入式编译器
 * 均为算术右移，与 Dart int 的 >> 语义一致。
 */
static int isp_dmv_conv5(const uint16_t *bayer, int width, int p,
                         const int k[5][5]) {
  int acc = 0;
  int dx, dy;
  for (dy = -2; dy <= 2; dy++) {
    const int *row = k[dy + 2];
    const int q = p + dy * width;
    for (dx = -2; dx <= 2; dx++) {
      const int c = row[dx + 2];
      if (c != 0) acc += c * bayer[q + dx];
    }
  }
  return (acc + 8) >> 4;
}

int isp_demosaic_adv_mhc(const uint16_t *bayer, int width, int height,
                         IspBayerPattern pattern, int max_value,
                         uint16_t *rgb_out) {
  int ret, x, y;
  ret = isp_dmv_check(bayer, width, height, pattern, max_value, rgb_out);
  if (ret != ISP_OK) return ret;
  /* 双线性铺底（Dart：先 demosaicBilinear 再覆写内部像素）。 */
  ret = isp_demosaic_bilinear(bayer, width, height, pattern, rgb_out);
  if (ret != ISP_OK) return ret;
  /* 小图整体回退双线性（Dart：width < 5 || height < 5 时直接返回）。 */
  if (width < 5 || height < 5) return ISP_OK;
  for (y = 2; y < height - 2; y++) {
    for (x = 2; x < width - 2; x++) {
      const int p = y * width + x;
      const int i = p * 3;
      const int own = isp_bayer_color_at(pattern, x, y);
      rgb_out[i + own] = bayer[p];
      if (own == ISP_CH_G) {
        /* G 站点：横向邻居是 R 则 R 用横行核、B 用竖列核，反之亦然。 */
        const int r_row =
            isp_bayer_color_at(pattern, x + 1, y) == ISP_CH_R;
        rgb_out[i] = isp_clamp_u16(
            isp_dmv_conv5(bayer, width, p,
                          r_row ? kIspDmvCatGRow : kIspDmvCatGCol),
            max_value);
        rgb_out[i + 2] = isp_clamp_u16(
            isp_dmv_conv5(bayer, width, p,
                          r_row ? kIspDmvCatGCol : kIspDmvCatGRow),
            max_value);
      } else {
        /* R/B 站点：G 用 _kGatC，对方颜色用对角核 _kCatOpp。 */
        const int opp = (own == ISP_CH_R) ? ISP_CH_B : ISP_CH_R;
        rgb_out[i + 1] =
            isp_clamp_u16(isp_dmv_conv5(bayer, width, p, kIspDmvGatC),
                          max_value);
        rgb_out[i + opp] =
            isp_clamp_u16(isp_dmv_conv5(bayer, width, p, kIspDmvCatOpp),
                          max_value);
      }
    }
  }
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * AAHD / AHD（Hirakawa & Parks 2005，简化实现）
 * ------------------------------------------------------------------------- */

int isp_demosaic_adv_aahd(const uint16_t *bayer, int width, int height,
                          IspBayerPattern pattern, int max_value,
                          uint16_t *rgb_out, void *scratch) {
  const int border = 3;
  /* 同质性阈值（Lab 单位，经验值，与 Dart epsL/epsAB 一致）。 */
  const double eps_l = 2.0, eps_ab = 4.0;
  int ret, x, y, dx, dy;
  int pixels;
  double inv;
  double *base;
  double *g_h, *g_v, *r_h, *b_h, *r_v, *b_v;
  double *l_h, *a_h, *b_h2, *l_v, *a_v, *b_v2;
  int32_t *hom_h, *hom_v;

  ret = isp_dmv_check(bayer, width, height, pattern, max_value, rgb_out);
  if (ret != ISP_OK) return ret;
  ret = isp_demosaic_bilinear(bayer, width, height, pattern, rgb_out);
  if (ret != ISP_OK) return ret;
  /* 小图回退（Dart：width < 2*border+1 || height < 2*border+1）。 */
  if (width < 2 * border + 1 || height < 2 * border + 1) return ISP_OK;
  if (scratch == NULL) return ISP_ERR_ARG;

  pixels = width * height;
  inv = 1.0 / max_value;
  /* scratch 切分：12 个 double 平面 + 2 个 int32 平面
   * （见 ISP_DEMOSAIC_ADV_SCRATCH_BYTES）。 */
  base = (double *)scratch;
  g_h = base; g_v = g_h + pixels; r_h = g_v + pixels; b_h = r_h + pixels;
  r_v = b_h + pixels; b_v = r_v + pixels;
  l_h = b_v + pixels; a_h = l_h + pixels; b_h2 = a_h + pixels;
  l_v = b_h2 + pixels; a_v = l_v + pixels; b_v2 = a_v + pixels;
  hom_h = (int32_t *)(b_v2 + pixels);
  hom_v = hom_h + pixels;

  /* 1. 两方向候选图的 G 平面：G 站点取真值，R/B 站点沿方向梯度校正插值。
   *    有效区为 2 像素环以内（_gHorz/_gVert 需要 ±2 邻域）。 */
  for (y = 2; y < height - 2; y++) {
    for (x = 2; x < width - 2; x++) {
      const int p = y * width + x;
      if (isp_bayer_color_at(pattern, x, y) == ISP_CH_G) {
        g_h[p] = bayer[p];
        g_v[p] = g_h[p];
      } else {
        g_h[p] = isp_dmv_g_horz(bayer, p);
        g_v[p] = isp_dmv_g_vert(bayer, width, p);
      }
    }
  }
  /* R/B 经色差平滑（border=2，与 g 平面有效区一致）。 */
  isp_dmv_fill_chrominance(r_h, g_h, bayer, ISP_CH_R, width, height, pattern, 2);
  isp_dmv_fill_chrominance(b_h, g_h, bayer, ISP_CH_B, width, height, pattern, 2);
  isp_dmv_fill_chrominance(r_v, g_v, bayer, ISP_CH_R, width, height, pattern, 2);
  isp_dmv_fill_chrominance(b_v, g_v, bayer, ISP_CH_B, width, height, pattern, 2);

  /* 2. 两候选图转 Lab（简化 sRGB 流程，归一化系数 1/maxValue）。 */
  for (y = 2; y < height - 2; y++) {
    for (x = 2; x < width - 2; x++) {
      const int p = y * width + x;
      isp_dmv_rgb_to_lab(r_h[p] * inv, g_h[p] * inv, b_h[p] * inv,
                         &l_h[p], &a_h[p], &b_h2[p]);
      isp_dmv_rgb_to_lab(r_v[p] * inv, g_v[p] * inv, b_v[p] * inv,
                         &l_v[p], &a_v[p], &b_v2[p]);
    }
  }
  /* 逐像素 3x3 邻域同质性计数（含中心自身，差值为 0 必然计入，
   * 与 Dart 不跳过 dx==0&&dy==0 一致；邻域落在 Lab 有效区内）。 */
  for (y = border; y < height - border; y++) {
    for (x = border; x < width - border; x++) {
      const int p = y * width + x;
      int ch = 0, cv = 0;
      for (dy = -1; dy <= 1; dy++) {
        for (dx = -1; dx <= 1; dx++) {
          const int q = (y + dy) * width + x + dx;
          if (fabs(l_h[p] - l_h[q]) <= eps_l &&
              fabs(a_h[p] - a_h[q]) <= eps_ab &&
              fabs(b_h2[p] - b_h2[q]) <= eps_ab) {
            ch++;
          }
          if (fabs(l_v[p] - l_v[q]) <= eps_l &&
              fabs(a_v[p] - a_v[q]) <= eps_ab &&
              fabs(b_v2[p] - b_v2[q]) <= eps_ab) {
            cv++;
          }
        }
      }
      hom_h[p] = ch;
      hom_v[p] = cv;
    }
  }

  /* 3. 逐像素选向：计数相等取水平候选（Dart：homH[p] >= homV[p]）。 */
  for (y = border; y < height - border; y++) {
    for (x = border; x < width - border; x++) {
      const int p = y * width + x;
      if (hom_h[p] >= hom_v[p]) {
        isp_dmv_emit(rgb_out, p, r_h[p], g_h[p], b_h[p], max_value);
      } else {
        isp_dmv_emit(rgb_out, p, r_v[p], g_v[p], b_v[p], max_value);
      }
    }
  }
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * AMaZE（Zhang & Wu 2005 方向滤波融合路线，简化实现）
 * ------------------------------------------------------------------------- */

int isp_demosaic_adv_amaze(const uint16_t *bayer, int width, int height,
                           IspBayerPattern pattern, int max_value,
                           uint16_t *rgb_out, void *scratch) {
  const int border = 3;
  int ret, x, y;
  int pixels;
  double *g, *r, *b, *dr, *db;

  ret = isp_dmv_check(bayer, width, height, pattern, max_value, rgb_out);
  if (ret != ISP_OK) return ret;
  ret = isp_demosaic_bilinear(bayer, width, height, pattern, rgb_out);
  if (ret != ISP_OK) return ret;
  if (width < 2 * border + 1 || height < 2 * border + 1) return ISP_OK;
  if (scratch == NULL) return ISP_ERR_ARG;

  pixels = width * height;
  /* scratch 切分：5 个 double 平面（g / r / b / dr / db）。 */
  g = (double *)scratch;
  r = g + pixels;
  b = r + pixels;
  dr = b + pixels;
  db = dr + pixels;

  /* 1. G 平面：R/B 站点 H/V 两方向梯度校正估计，按方向梯度反比加权融合。
   *    方向梯度 = 一阶差绝对值 + 亮度二阶差绝对值（整数域计算，与 Dart
   *    的 int.abs() 求和一致；2*65535-0-0 不超 int 范围）。 */
  for (y = 2; y < height - 2; y++) {
    for (x = 2; x < width - 2; x++) {
      const int p = y * width + x;
      double gh, gv, wh, wv;
      int dh, dv, t;
      if (isp_bayer_color_at(pattern, x, y) == ISP_CH_G) {
        g[p] = bayer[p];
        continue;
      }
      gh = isp_dmv_g_horz(bayer, p);
      gv = isp_dmv_g_vert(bayer, width, p);
      t = bayer[p - 1] - bayer[p + 1];
      dh = t < 0 ? -t : t;
      t = 2 * bayer[p] - bayer[p - 2] - bayer[p + 2];
      dh += t < 0 ? -t : t;
      t = bayer[p - width] - bayer[p + width];
      dv = t < 0 ? -t : t;
      t = 2 * bayer[p] - bayer[p - 2 * width] - bayer[p + 2 * width];
      dv += t < 0 ? -t : t;
      wh = 1.0 / (1.0 + dh);
      wv = 1.0 / (1.0 + dv);
      g[p] = (wh * gh + wv * gv) / (wh + wv);
    }
  }
  /* R/B 经色差平滑（border=2）。 */
  isp_dmv_fill_chrominance(r, g, bayer, ISP_CH_R, width, height, pattern, 2);
  isp_dmv_fill_chrominance(b, g, bayer, ISP_CH_B, width, height, pattern, 2);

  /* 2. 色差平面（3x3 中值滤波去拉链，不动 G 本身）。 */
  for (y = 2; y < height - 2; y++) {
    for (x = 2; x < width - 2; x++) {
      const int p = y * width + x;
      dr[p] = r[p] - g[p];
      db[p] = b[p] - g[p];
    }
  }
  for (y = border; y < height - border; y++) {
    for (x = border; x < width - border; x++) {
      const int p = y * width + x;
      isp_dmv_emit(rgb_out, p, g[p] + isp_dmv_median9(dr, width, x, y), g[p],
                   g[p] + isp_dmv_median9(db, width, x, y), max_value);
    }
  }
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * LMMSE（Zhang & Wu 2005，简化实现）
 * ------------------------------------------------------------------------- */

int isp_demosaic_adv_lmmse(const uint16_t *bayer, int width, int height,
                           IspBayerPattern pattern, int max_value,
                           uint16_t *rgb_out, void *scratch) {
  const int border = 3;
  int ret, x, y, dx, dy;
  int pixels;
  double eps;
  double *g, *r, *b;

  ret = isp_dmv_check(bayer, width, height, pattern, max_value, rgb_out);
  if (ret != ISP_OK) return ret;
  ret = isp_demosaic_bilinear(bayer, width, height, pattern, rgb_out);
  if (ret != ISP_OK) return ret;
  if (width < 2 * border + 1 || height < 2 * border + 1) return ISP_OK;
  if (scratch == NULL) return ISP_ERR_ARG;

  pixels = width * height;
  eps = max_value * 1e-3; /* 能量下限（平坦区两方向等权），与 Dart 一致 */
  /* scratch 切分：3 个 double 平面（g / r / b）。 */
  g = (double *)scratch;
  r = g + pixels;
  b = r + pixels;

  /* 1. G 平面：R/B 站点 H/V 梯度校正估计，方向能量 = 3x3 窗口内各点沿
   *    H/V 的亮度二阶差分绝对值之和，按 1/(能量+eps) 逆能量加权融合。
   *    能量窗口触及 ±3 邻域（中心 ±1 再沿方向 ±2），故 G 有效区为
   *    3 像素环以内（Dart 循环即从 border=3 开始）。 */
  for (y = border; y < height - border; y++) {
    for (x = border; x < width - border; x++) {
      const int p = y * width + x;
      double gh, gv, eh, ev, wh, wv;
      if (isp_bayer_color_at(pattern, x, y) == ISP_CH_G) {
        g[p] = bayer[p];
        continue;
      }
      gh = isp_dmv_g_horz(bayer, p);
      gv = isp_dmv_g_vert(bayer, width, p);
      eh = 0.0;
      ev = 0.0;
      for (dy = -1; dy <= 1; dy++) {
        for (dx = -1; dx <= 1; dx++) {
          const int q = (y + dy) * width + x + dx;
          int t;
          t = 2 * bayer[q] - bayer[q - 2] - bayer[q + 2];
          eh += t < 0 ? -t : t;
          t = 2 * bayer[q] - bayer[q - 2 * width] - bayer[q + 2 * width];
          ev += t < 0 ? -t : t;
        }
      }
      wh = 1.0 / (eh + eps);
      wv = 1.0 / (ev + eps);
      g[p] = (wh * gh + wv * gv) / (wh + wv);
    }
  }
  /* R/B 经色差平滑（border=3，与 g 平面有效区一致）。 */
  isp_dmv_fill_chrominance(r, g, bayer, ISP_CH_R, width, height, pattern,
                           border);
  isp_dmv_fill_chrominance(b, g, bayer, ISP_CH_B, width, height, pattern,
                           border);
  for (y = border; y < height - border; y++) {
    for (x = border; x < width - border; x++) {
      const int p = y * width + x;
      isp_dmv_emit(rgb_out, p, r[p], g[p], b[p], max_value);
    }
  }
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * IGV（Pekkucuksen & Altunbasak 2010 风格，等价思想简化实现）
 * ------------------------------------------------------------------------- */

/**
 * @brief 5 样本窗口方差（无阈值方向权重用）。
 *
 * Dart 来源：demosaic_advanced.dart `demosaicIgv` 内嵌的 variance5()。
 * 采样点 q0 + k*step（k=-2..2），返回 s2/5 − (s/5)^2。
 * 累加顺序与 Dart 一致，保证浮点结果逐位一致。
 */
static double isp_dmv_variance5(const uint16_t *bayer, int q0, int step) {
  double s = 0.0, s2 = 0.0;
  int k;
  for (k = -2; k <= 2; k++) {
    const double v = bayer[q0 + k * step];
    s += v;
    s2 += v * v;
  }
  return s2 / 5.0 - (s / 5.0) * (s / 5.0);
}

int isp_demosaic_adv_igv(const uint16_t *bayer, int width, int height,
                         IspBayerPattern pattern, int max_value,
                         uint16_t *rgb_out, void *scratch) {
  int ret, x, y;
  int pixels;
  double eps;
  double *g, *r, *b;

  ret = isp_dmv_check(bayer, width, height, pattern, max_value, rgb_out);
  if (ret != ISP_OK) return ret;
  ret = isp_demosaic_bilinear(bayer, width, height, pattern, rgb_out);
  if (ret != ISP_OK) return ret;
  /* 小图回退（Dart：width < 5 || height < 5）。 */
  if (width < 5 || height < 5) return ISP_OK;
  if (scratch == NULL) return ISP_ERR_ARG;

  pixels = width * height;
  /* 方差下限 eps = maxValue^2 * 1e-6。Dart int 为 64 位不溢出；
   * C 侧必须先转 double 再相乘，否则 65535^2 溢出 32 位 int（易错点）。 */
  eps = (double)max_value * (double)max_value * 1e-6;
  /* scratch 切分：3 个 double 平面（g / r / b）。 */
  g = (double *)scratch;
  r = g + pixels;
  b = r + pixels;

  /* 1. G 平面：MHC 式梯度校正得到 H/V 估计，按 5 样本窗口方差
   *    1/(方差+eps) 无阈值加权融合（方差小者权重大）。
   *    方差窗口沿方向 ±2，故 G 有效区为 2 像素环以内。 */
  for (y = 2; y < height - 2; y++) {
    for (x = 2; x < width - 2; x++) {
      const int p = y * width + x;
      double gh, gv, var_h, var_v, wh, wv;
      if (isp_bayer_color_at(pattern, x, y) == ISP_CH_G) {
        g[p] = bayer[p];
        continue;
      }
      gh = isp_dmv_g_horz(bayer, p);
      gv = isp_dmv_g_vert(bayer, width, p);
      var_h = isp_dmv_variance5(bayer, p, 1);
      var_v = isp_dmv_variance5(bayer, p, width);
      wh = 1.0 / (var_h + eps);
      wv = 1.0 / (var_v + eps);
      g[p] = (wh * gh + wv * gv) / (wh + wv);
    }
  }
  /* R/B 经色差平滑（border=2）。 */
  isp_dmv_fill_chrominance(r, g, bayer, ISP_CH_R, width, height, pattern, 2);
  isp_dmv_fill_chrominance(b, g, bayer, ISP_CH_B, width, height, pattern, 2);
  for (y = 2; y < height - 2; y++) {
    for (x = 2; x < width - 2; x++) {
      const int p = y * width + x;
      isp_dmv_emit(rgb_out, p, r[p], g[p], b[p], max_value);
    }
  }
  return ISP_OK;
}
