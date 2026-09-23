#include "isp_bayer_dnr.h"

/**
 * @file isp_bayer_dnr.c
 * @brief ISP Studio C99 参考实现 —— Bayer/mono 降噪节点（bayer_dnr）实现。
 *
 * 覆盖节点：bayer_dnr。
 * 对应 Dart 函数：isp_kernels.dart `applyBayerDenoise`。
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#include <math.h>
#include <string.h>

int isp_bayer_dnr_apply(uint16_t *buf, int w, int h,
                        const IspBayerPattern *pattern, double strength,
                        uint16_t *scratch) {
  /* Dart 首行 `if (strength <= 0) return;`：空操作，直接成功返回。 */
  if (strength <= 0.0) return ISP_OK;
  if (buf == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;

  /* Dart `final src = Uint16List.fromList(buf);`：整帧快照，后续所有
   * 邻域采样都读快照，写回不影响同一帧内其他像素的计算。 */
  const uint16_t *src = (const uint16_t *)memcpy(
      scratch, buf, (size_t)w * (size_t)h * sizeof(uint16_t));

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      const int i = y * w + x;
      const int v = src[i];
      /* σ = strength * sqrt(v + 64)：σ²=aI+b 噪声模型取 a=1、b=64。
       * v 先提升为 double 再开方，与 Dart math.sqrt(v + 64) 一致。 */
      const double sigma = strength * sqrt((double)v + 64.0);
      /* 中心像素权重固定 1.0，先放入累加器（顺序与 Dart 一致）。 */
      double sum = (double)v;
      double wsum = 1.0;

      /* 收集同相位（Bayer 步进 ±2）/ 全像素（mono 步进 ±1）3x3 邻域，
       * 收集顺序与 Dart `_phaseNeighbors` 行优先一致，保证 double
       * 累加次序逐位相同。邻域最多 8 个样本。 */
      uint16_t nb[8];
      const int ncnt = isp_phase_neighbors(src, w, h, x, y, pattern, nb);
      for (int k = 0; k < ncnt; k++) {
        /* Δ = 邻居 - 中心，int 相减后提升 double 参与除法。 */
        const double d = (double)((int)nb[k] - v);
        /* 保边权重 w = 1/(1+(Δ/σ)²)：差异越大权重越小。 */
        const double ds = d / sigma;
        const double wgt = 1.0 / (1.0 + ds * ds);
        sum += wgt * (double)nb[k];
        wsum += wgt;
      }

      /* Dart `(sum / wsum).round()`：round() 半值远离零，C99 round()
       * 语义相同（此处被舍入值恒正）。加权平均为样本凸组合，结果必落在
       * [0, 样本最大值] 内，Dart 无钳位，此处同样直接截尾转换。 */
      buf[i] = (uint16_t)round(sum / wsum);
    }
  }
  return ISP_OK;
}
