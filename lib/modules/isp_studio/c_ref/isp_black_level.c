#include "isp_black_level.h"

/**
 * @file isp_black_level.c
 * @brief ISP Studio C99 参考实现 —— 黑电平校正节点（black_level）实现。
 *
 * 覆盖范围：
 * - isp_black_level_apply       Bayer/CFA 2x2 四相位偏移扣除
 *                               （Dart isp_kernels.dart `applyBlackLevel`）
 * - isp_black_level_apply_mono  mono 帧统一偏移扣除
 *                               （Dart pipeline_runner.dart black_level mono 分支）
 *
 * 舍入说明：Dart `v.round()` 与 C99 `round()` 同为「最近整数、半值远离
 * 零」，v <= 0 分支已先行截零，剩余均为正值，两侧语义完全一致。
 * 写回前先 round 为 long 再转 uint16_t（避免 double 直接转整型的越界
 * 未定义行为）；超出 16 位按模 2^16 回绕，与 Dart 写回 Uint16List 一致。
 */

#include <math.h>

int isp_black_level_apply(uint16_t *bayer, int width, int height,
                          IspBayerPattern pattern,
                          double r, double gr, double gb, double b) {
  /* 2x2 平铺四相位各自的偏移，phase = (py << 1) | px。 */
  double offsets[4];
  if (bayer == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;

  /* 第一步：解析四相位偏移。
   * R/B 相位直接用 r/b；G 相位看同行另一像素（px^1）的颜色：
   * 与 R 同行为 gr，与 B 同行为 gb（与 Dart 的 else 分支一致）。 */
  for (int py = 0; py < 2; py++) {
    for (int px = 0; px < 2; px++) {
      const int phase = (py << 1) | px;
      const int color = isp_bayer_color_at(pattern, px, py);
      if (color == ISP_CH_R) {
        offsets[phase] = r;
      } else if (color == ISP_CH_B) {
        offsets[phase] = b;
      } else {
        offsets[phase] =
            (isp_bayer_color_at(pattern, px ^ 1, py) == ISP_CH_R) ? gr : gb;
      }
    }
  }

  /* 第二步：逐像素扣除，v <= 0 截零，否则四舍五入写回（不截顶）。 */
  {
    int i = 0;
    for (int y = 0; y < height; y++) {
      const int row_phase = (y & 1) << 1;
      for (int x = 0; x < width; x++, i++) {
        const double v = (double)bayer[i] - offsets[row_phase | (x & 1)];
        bayer[i] = (v <= 0.0) ? 0 : (uint16_t)(long)round(v);
      }
    }
  }
  return ISP_OK;
}

int isp_black_level_apply_mono(uint16_t *buf, int width, int height,
                               double offset) {
  if (buf == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  /* mono：统一偏移逐像素扣除，截零、四舍五入，与 mosaic 分支同规则。 */
  {
    const int n = width * height;
    for (int i = 0; i < n; i++) {
      const double v = (double)buf[i] - offset;
      buf[i] = (v <= 0.0) ? 0 : (uint16_t)(long)round(v);
    }
  }
  return ISP_OK;
}
