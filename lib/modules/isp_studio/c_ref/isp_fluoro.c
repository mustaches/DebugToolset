#include "isp_fluoro.h"

/**
 * @file isp_fluoro.c
 * @brief ISP Studio C99 参考实现 —— 荧光处理组实现。
 *
 * 覆盖节点与 Dart 来源的对应关系见 isp_fluoro.h 文件头注释。
 *
 * 本文件内的 static helper（isp_common 未提供，按任务约定就地实现）：
 * - isp_fluoro__clamp_to   Dart `_clampTo` 的浮点路径（先钳位再 round）
 * - isp_fluoro__round_pos  Dart round() 的非负路径（floor(v+0.5)）
 * - isp_fluoro__clamp01    Dart v.clamp(0.0, 1.0)
 * - isp_fluoro__colormap   green/magenta/hot 三色表（两处复用）
 * - isp_fluoro__sample_fl  带偏移/边界钳位的双线性采样（fuse 内层函数）
 */

#include <math.h>
#include <string.h>

/**
 * @brief Dart `_clampTo`（isp_kernels.dart:845）的等价实现：
 *        v < 0 → 0；v > max_value → max_value；否则四舍五入取整。
 *
 * Dart double.round() 为「半值远离零」；能走到舍入分支的 v 必在
 * [0, max_value] 内（非负），故 floor(v + 0.5) 与之等价。
 */
static int isp_fluoro__clamp_to(double v, int max_value) {
  if (v < 0) return 0;
  if (v > max_value) return max_value;
  return (int)floor(v + 0.5);
}

/**
 * @brief Dart round() 的非负路径：floor(v + 0.5) 后转 uint16_t。
 *        仅用于调用点已保证 v > 0（或非负）的场合（leak/background/iir）。
 */
static uint16_t isp_fluoro__round_pos(double v) {
  return (uint16_t)floor(v + 0.5);
}

/** @brief Dart v.clamp(0.0, 1.0)。 */
static double isp_fluoro__clamp01(double v) {
  if (v < 0.0) return 0.0;
  if (v > 1.0) return 1.0;
  return v;
}

/**
 * @brief 三色表映射（Dart 来源：`monoPseudoColor` 与 `fuseFluorescence`
 *        中逐字相同的 switch 分支）。
 *
 * @param t  归一化强度，调用方已钳位到 [0,1]。
 * @param cm 色表。
 * @param r  输出 R（0..1）。
 * @param g  输出 G（0..1）。
 * @param b  输出 B（0..1）。
 */
static void isp_fluoro__colormap(double t, IspFluoroColormap cm, double *r,
                                 double *g, double *b) {
  switch (cm) {
    case ISP_FLUORO_CMAP_MAGENTA:
      *r = t;
      *g = 0.0;
      *b = t;
      break;
    case ISP_FLUORO_CMAP_HOT:
      /* 黑 → 红 → 黄 → 白。 */
      *r = ISP_MIN(3.0 * t, 1.0);
      *g = isp_fluoro__clamp01(3.0 * t - 1.0);
      *b = isp_fluoro__clamp01(3.0 * t - 2.0);
      break;
    default: /* ISP_FLUORO_CMAP_GREEN：ICG 荧光惯例的纯绿映射。 */
      *r = 0.0;
      *g = t;
      *b = 0.0;
      break;
  }
}

/**
 * @brief 荧光图双线性采样（Dart 来源：`fuseFluorescence` 内层函数
 *        `sampleFl`）：坐标先钳位到 [0, w−1]/[0, h−1]（double），
 *        floor 取整点，边界处 x1/y1 回退为 x0/y0，再按 tx/ty 双线性插值。
 */
static double isp_fluoro__sample_fl(const uint16_t *fl, int w, int h, double fx,
                                    double fy) {
  int x0, y0, x1, y1;
  double tx, ty, v00, v10, v01, v11;
  /* Dart：fx = fx.clamp(0.0, width - 1.0)。 */
  if (fx < 0.0) fx = 0.0;
  if (fx > (double)(w - 1)) fx = (double)(w - 1);
  if (fy < 0.0) fy = 0.0;
  if (fy > (double)(h - 1)) fy = (double)(h - 1);
  x0 = (int)floor(fx);
  y0 = (int)floor(fy);
  x1 = (x0 + 1 < w) ? x0 + 1 : x0;
  y1 = (y0 + 1 < h) ? y0 + 1 : y0;
  tx = fx - x0;
  ty = fy - y0;
  v00 = fl[y0 * w + x0];
  v10 = fl[y0 * w + x1];
  v01 = fl[y1 * w + x0];
  v11 = fl[y1 * w + x1];
  return (v00 * (1.0 - tx) + v10 * tx) * (1.0 - ty) +
         (v01 * (1.0 - tx) + v11 * tx) * ty;
}

int isp_fluoro_leak_apply(uint16_t *mono, int width, int height, double level,
                          double max_sub) {
  const double sub = (level < max_sub) ? level : max_sub;
  int n, i;
  if (mono == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  /* Dart：sub <= 0 直接返回（double 精确比较）。 */
  if (sub <= 0.0) return ISP_OK;
  n = width * height;
  for (i = 0; i < n; i++) {
    const double v = mono[i] - sub;
    /* v <= 0 写 0，否则 round(v)；Dart 无上限钳位（减正数不超量程）。 */
    mono[i] = (v <= 0.0) ? 0 : isp_fluoro__round_pos(v);
  }
  return ISP_OK;
}

int isp_fluoro_background_apply(uint16_t *mono, int width, int height,
                                int block_size, double strength,
                                void *scratch) {
  int bs, bx, by, byi, bxi, x, y;
  double *means;
  uint16_t *src;
  if (mono == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  /* Dart：strength <= 0 直接返回。 */
  if (strength <= 0.0) return ISP_OK;
  bs = ISP_FLUORO_BG_EFFECTIVE_BS(block_size);
  /* 向上取整分块（边缘块截短）。 */
  bx = (width + bs - 1) / bs;
  by = (height + bs - 1) / bs;
  /* scratch 布局：means 表（double，首部保证对齐）+ src 副本（uint16）。 */
  means = (double *)scratch;
  src = (uint16_t *)(means + (size_t)bx * (size_t)by);
  /* 1) 逐块求均值：64 位整数累加（Dart int 语义），均值 = sum/count。 */
  for (byi = 0; byi < by; byi++) {
    for (bxi = 0; bxi < bx; bxi++) {
      const int y0 = byi * bs;
      const int y1 = ISP_MIN(y0 + bs, height);
      const int x0 = bxi * bs;
      const int x1 = ISP_MIN(x0 + bs, width);
      uint64_t sum = 0;
      int count = 0;
      for (y = y0; y < y1; y++) {
        for (x = x0; x < x1; x++) {
          sum += mono[y * width + x];
          count++;
        }
      }
      means[byi * bx + bxi] = (count > 0) ? (double)sum / count : 0.0;
    }
  }
  /* 2) 备份输入帧（Dart：final src = Uint16List.fromList(mono)）。 */
  memcpy(src, mono, (size_t)width * (size_t)height * sizeof(uint16_t));
  /* 3) 逐像素查所属块均值扣除；v <= 0 写 0，否则 round(v)。 */
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++) {
      const int i = y * width + x;
      const double bg = means[(y / bs) * bx + (x / bs)];
      const double v = src[i] - strength * bg;
      mono[i] = (v <= 0.0) ? 0 : isp_fluoro__round_pos(v);
    }
  }
  return ISP_OK;
}

int isp_fluoro_normalize_apply(uint16_t *mono, int width, int height,
                               double reference, double epsilon,
                               int max_value) {
  const int n = width * height;
  uint64_t sum = 0;
  double mean, gain;
  int i;
  if (mono == NULL || max_value < 0) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  /* Dart 短路链：reference <= 0 → 不动帧。 */
  if (reference <= 0.0) return ISP_OK;
  for (i = 0; i < n; i++) sum += mono[i];
  mean = (double)sum / n;
  /* Dart：mean < epsilon → 不动帧（防除零）。 */
  if (mean < epsilon) return ISP_OK;
  gain = reference / mean;
  /* Dart：gain == 1.0（double 精确比较）→ 不动帧。 */
  if (gain == 1.0) return ISP_OK;
  /* v = mono[i] * gain 后按 _clampTo 截位（先钳位再四舍五入）。 */
  for (i = 0; i < n; i++) {
    mono[i] = (uint16_t)isp_fluoro__clamp_to(mono[i] * gain, max_value);
  }
  return ISP_OK;
}

int isp_fluoro_temporal_iir_apply(const uint16_t *mono, uint16_t *history,
                                  bool has_history, uint16_t *out, int width,
                                  int height, double alpha, bool motion_adapt,
                                  int max_value) {
  const size_t bytes = (size_t)width * (size_t)height * sizeof(uint16_t);
  int n, i;
  double a, motion_thr;
  if (mono == NULL || history == NULL || out == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  n = width * height;
  /* 无历史（Dart history == null 或尺寸不符）：直通并把当前帧作为历史。 */
  if (!has_history) {
    if (out != mono) memcpy(out, mono, bytes);
    memcpy(history, mono, bytes);
    return ISP_OK;
  }
  /* α 钳位到 [0,1]；运动阈值 = max_value/16（double 除法）。 */
  a = isp_fluoro__clamp01(alpha);
  motion_thr = max_value / 16.0;
  for (i = 0; i < n; i++) {
    const int f = mono[i];
    const int prev = history[i];
    /* Dart：(f - prev).abs()；规范头文件清单不含 stdlib.h，手工取绝对值。 */
    const int diff = f - prev;
    const int adiff = (diff < 0) ? -diff : diff;
    double aa = a;
    /* 运动像素强制 α=1（用当前帧，避免拖影）。 */
    if (motion_adapt && adiff > motion_thr) aa = 1.0;
    /* Dart 不钳位到 max_value：两路同量程加权和必在量程内。 */
    out[i] = isp_fluoro__round_pos(aa * f + (1.0 - aa) * prev);
  }
  /* Dart 返回的新历史 = 输出帧副本；原地更新调用方持有的历史缓冲。 */
  if (history != out) memcpy(history, out, bytes);
  return ISP_OK;
}

int isp_fluoro_pseudo_color_apply(const uint16_t *mono, uint16_t *out_rgb,
                                  int width, int height,
                                  IspFluoroColormap colormap, double gain,
                                  int max_value) {
  const double inv = 1.0 / max_value;
  int n, i, j;
  if (mono == NULL || out_rgb == NULL || max_value <= 0) return ISP_ERR_ARG;
  if (colormap != ISP_FLUORO_CMAP_GREEN && colormap != ISP_FLUORO_CMAP_MAGENTA &&
      colormap != ISP_FLUORO_CMAP_HOT) {
    return ISP_ERR_ARG;
  }
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  n = width * height;
  for (i = 0, j = 0; i < n; i++, j += 3) {
    /* t = mono[i] × gain / max_value，钳位 [0,1] 后查色表。 */
    const double t = isp_fluoro__clamp01(mono[i] * gain * inv);
    double r, g, b;
    isp_fluoro__colormap(t, colormap, &r, &g, &b);
    /* 每通道 v = c × max_value，按 _clampTo 截位。 */
    out_rgb[j] = (uint16_t)isp_fluoro__clamp_to(r * max_value, max_value);
    out_rgb[j + 1] = (uint16_t)isp_fluoro__clamp_to(g * max_value, max_value);
    out_rgb[j + 2] = (uint16_t)isp_fluoro__clamp_to(b * max_value, max_value);
  }
  return ISP_OK;
}

int isp_fluoro_fuse_apply(const uint16_t *rgb_wl, const uint16_t *mono_fl,
                          uint16_t *out_rgb, int width, int height,
                          IspFluoroFusionMode mode, double threshold,
                          double alpha_max, IspFluoroColormap colormap,
                          double offset_x, double offset_y, int max_value) {
  const int contour = (mode == ISP_FLUORO_FUSION_CONTOUR);
  /* Dart：range = maxValue - threshold（double，全程复用）。 */
  const double range = max_value - threshold;
  int x, y;
  if (rgb_wl == NULL || mono_fl == NULL || out_rgb == NULL || max_value <= 0) {
    return ISP_ERR_ARG;
  }
  if (mode != ISP_FLUORO_FUSION_ALPHA && mode != ISP_FLUORO_FUSION_CONTOUR) {
    return ISP_ERR_ARG;
  }
  if (colormap != ISP_FLUORO_CMAP_GREEN && colormap != ISP_FLUORO_CMAP_MAGENTA &&
      colormap != ISP_FLUORO_CMAP_HOT) {
    return ISP_ERR_ARG;
  }
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  for (y = 0; y < height; y++) {
    for (x = 0; x < width; x++) {
      const int i = (y * width + x) * 3;
      /* 1) 带配准偏移的荧光双线性采样。 */
      const double fl =
          isp_fluoro__sample_fl(mono_fl, width, height, x + offset_x,
                                y + offset_y);
      /* 2) 伪彩（增益恒 1，融合内不再叠加增益）。 */
      const double t = isp_fluoro__clamp01(fl / max_value);
      double pr, pg, pb;
      isp_fluoro__colormap(t, colormap, &pr, &pg, &pb);
      if (contour) {
        /* 3) 轮廓模式：mask 内像素若 3x3 邻域存在 mask 外点即为边缘。
         *    邻域同样经偏移采样（与 Dart 逐项对应：dy 外层 dx 内层，
         *    跳过中心；结果仅为布尔，短路顺序不影响数值）。 */
        int edge = 0;
        if (fl >= threshold) {
          int dy, dx;
          for (dy = -1; dy <= 1 && !edge; dy++) {
            for (dx = -1; dx <= 1; dx++) {
              if (dx == 0 && dy == 0) continue;
              if (isp_fluoro__sample_fl(mono_fl, width, height,
                                        (double)(x + dx) + offset_x,
                                        (double)(y + dy) + offset_y) <
                  threshold) {
                edge = 1;
                break;
              }
            }
          }
        }
        if (edge) {
          /* 轮廓处：伪彩全强度叠加（替换白光）。 */
          out_rgb[i] = (uint16_t)isp_fluoro__clamp_to(pr * max_value, max_value);
          out_rgb[i + 1] =
              (uint16_t)isp_fluoro__clamp_to(pg * max_value, max_value);
          out_rgb[i + 2] =
              (uint16_t)isp_fluoro__clamp_to(pb * max_value, max_value);
        } else {
          /* 非轮廓：透传白光。 */
          out_rgb[i] = rgb_wl[i];
          out_rgb[i + 1] = rgb_wl[i + 1];
          out_rgb[i + 2] = rgb_wl[i + 2];
        }
        continue;
      }
      /* 4) alpha 模式：强度门限 → α 映射（上限 alpha_max）。 */
      {
        double a = 0.0;
        if (range > 0.0 && fl > threshold) {
          a = alpha_max * ((fl - threshold) / range);
          if (a > alpha_max) a = alpha_max;
        }
        out_rgb[i] = (uint16_t)isp_fluoro__clamp_to(
            rgb_wl[i] * (1.0 - a) + pr * max_value * a, max_value);
        out_rgb[i + 1] = (uint16_t)isp_fluoro__clamp_to(
            rgb_wl[i + 1] * (1.0 - a) + pg * max_value * a, max_value);
        out_rgb[i + 2] = (uint16_t)isp_fluoro__clamp_to(
            rgb_wl[i + 2] * (1.0 - a) + pb * max_value * a, max_value);
      }
    }
  }
  return ISP_OK;
}

int isp_fluoro_pseudo_color_lut_apply(const uint16_t *mono, uint16_t *out_rgb,
                                      int width, int height,
                                      const uint16_t *lut_r,
                                      const uint16_t *lut_g,
                                      const uint16_t *lut_b, int max_value) {
  int n, i, j;
  if (mono == NULL || out_rgb == NULL || lut_r == NULL || lut_g == NULL ||
      lut_b == NULL || max_value <= 0) {
    return ISP_ERR_ARG;
  }
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  n = width * height;
  /* 与 Dart applyPseudoColorLut 一致：逐值三通道查表。 */
  for (i = 0, j = 0; i < n; i++, j += 3) {
    const uint16_t v = mono[i];
    out_rgb[j] = lut_r[v];
    out_rgb[j + 1] = lut_g[v];
    out_rgb[j + 2] = lut_b[v];
  }
  return ISP_OK;
}
