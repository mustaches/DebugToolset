#include "isp_highlight.h"

/**
 * @file isp_highlight.c
 * @brief ISP Studio C99 参考实现 —— 高光恢复节点（highlight）实现。
 *
 * 覆盖节点：highlight。
 * 对应 Dart 函数：isp_kernels.dart `applyHighlightRecovery`。
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#include <math.h>
#include <string.h>

int isp_highlight_apply(uint16_t *buf, int w, int h,
                        const IspBayerPattern *pattern, int max_value,
                        IspHighlightMode mode, double knee,
                        uint16_t *scratch) {
  double knee_pt;

  if (buf == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  if (mode != ISP_HIGHLIGHT_RECOVER && mode != ISP_HIGHLIGHT_CLIP) {
    return ISP_ERR_ARG;
  }

  /* Dart `final kneePt = knee.clamp(0.0, 1.0) * maxValue;`
   * 膝点为 double，后续所有饱和判定都是 int 提升 double 的浮点比较。 */
  knee = ISP_MAX(0.0, ISP_MIN(1.0, knee));
  knee_pt = knee * (double)max_value;

  if (mode == ISP_HIGHLIGHT_CLIP) {
    /* ---- clip 分支：膝点以上软压缩，逐像素独立，无需快照 ---- */
    /* Dart `final range = maxValue - kneePt; if (range <= 0) return;` */
    const double range = (double)max_value - knee_pt;
    const int pixels = w * h;
    if (range <= 0.0) return ISP_OK;
    for (int i = 0; i < pixels; i++) {
      const int v = buf[i];
      double d;
      /* Dart `if (v <= kneePt) continue;`：int 提升 double 比较。 */
      if ((double)v <= knee_pt) continue;
      d = (double)v - knee_pt;
      /* v' = kneePt + d*range/(range+d)：有理函数软压缩，d→∞ 时
       * 渐近收敛到 maxValue。round() 与 Dart round() 同为半值远离零
       * （被舍入值恒正）。结果必 <= maxValue，Dart 无钳位，此处同。 */
      buf[i] = (uint16_t)round(knee_pt + d * range / (range + d));
    }
    return ISP_OK;
  }

  /* ---- recover 分支：饱和像素用同相位未饱和邻域均值重建 ---- */
  if (scratch == NULL) return ISP_ERR_ARG;
  /* Dart `final src = Uint16List.fromList(buf);`：整帧快照，饱和判定
   * 与邻域采样一律读快照，写回不影响同帧其他像素。 */
  {
    const uint16_t *src = (const uint16_t *)memcpy(
        scratch, buf, (size_t)w * (size_t)h * sizeof(uint16_t));

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        const int i = y * w + x;
        int sum = 0;
        int count = 0;
        int ncnt;
        int k;
        uint16_t nb[8];

        /* Dart `if (src[i] < kneePt) continue;`：int 提升 double 比较，
         * 只有达到膝点（>= kneePt）的像素才重建。 */
        if ((double)src[i] < knee_pt) continue;

        /* 同相位（Bayer 步进 ±2）/ 全像素（mono 步进 ±1）3x3 邻域，
         * 收集顺序与 Dart `_phaseNeighbors` 行优先一致（此处仅做整数
         * 累加，顺序不影响结果，但保持同源便于对拍）。 */
        ncnt = isp_phase_neighbors(src, w, h, x, y, pattern, nb);
        for (k = 0; k < ncnt; k++) {
          /* Dart `if (src[n] >= kneePt) continue;`：只用未饱和邻居。 */
          if ((double)nb[k] >= knee_pt) continue;
          sum += (int)nb[k];
          count++;
        }
        /* Dart `if (count > 0) buf[i] = (sum + count ~/ 2) ~/ count;`
         * 整数除法四舍五入：正数下 ~/ 与 C 的 / 同为截断；sum 最大
         * 8*65535+4，int 不溢出。count == 0（邻域全饱和）时保持原值。 */
        if (count > 0) {
          buf[i] = (uint16_t)((sum + count / 2) / count);
        }
      }
    }
  }
  return ISP_OK;
}

int isp_highlight_clip_lut_apply(uint16_t *buf, int w, int h,
                                 const uint16_t *lut) {
  const int64_t n = (int64_t)w * (int64_t)h;
  int64_t i;
  if (buf == NULL || lut == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  /* 与 Dart applyHighlightClipLut 一致：逐值查表。 */
  for (i = 0; i < n; i++) {
    buf[i] = lut[buf[i]];
  }
  return ISP_OK;
}
