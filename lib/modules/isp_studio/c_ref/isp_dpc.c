#include "isp_dpc.h"

/**
 * @file isp_dpc.c
 * @brief ISP Studio C99 参考实现 —— 坏点校正节点（dpc）实现。
 *
 * 覆盖范围：
 * - isp_dpc_apply  坏点校正（median / directional 两模式）
 *                  （Dart isp_kernels.dart `applyDpc`）
 *
 * 数值对应要点：
 * - thr 为 double，Dart 比较 `(buf[i] - med).abs() <= thr` 时整数差提升
 *   为 double；C 侧 `(double)diff <= thr` 同式，差值 <= 65535 可被
 *   double 精确表示，逐位一致；
 * - 中位数取上中位（Dart `vals[vals.length ~/ 2]`），由 isp_median_u16
 *   保证；邻域收集顺序（dy 外层、dx 内层、行优先）由 isp_phase_neighbors
 *   保证；
 * - 方向平均 (va + vb + 1) >> 1 为整数运算（含半值向上），C 侧同式；
 * - 方向选择用严格小于（diff < best_diff）刷新最优，四个方向按
 *   水平/垂直/主对角/副对角顺序枚举，平局时保留先出现者，与 Dart 一致。
 */

int isp_dpc_apply(uint16_t *buf, int width, int height,
                  const IspBayerPattern *pattern, double threshold,
                  IspDpcMode mode, int max_value) {
  /* 满量程百分比 → 采样值阈值（double，与 Dart `threshold / 100 * maxValue`
   * 完全同式）。 */
  const double thr = threshold / 100.0 * max_value;
  /* 邻域步进：mono ±1，Bayer 同相位 ±2（与 isp_phase_neighbors 一致）。 */
  const int step = (pattern == NULL) ? 1 : 2;

  if (buf == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  if (mode != ISP_DPC_MEDIAN && mode != ISP_DPC_DIRECTIONAL)
    return ISP_ERR_ARG;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      const int i = y * width + x;
      /* 处理邻域样本：最多 8 个，固定栈数组（非 VLA）。 */
      uint16_t vals[8];
      const int n =
          isp_phase_neighbors(buf, width, height, x, y, pattern, vals);
      uint16_t med;
      int diff;
      if (n == 0) continue; /* 仅 1x1 帧的极端情况，与 Dart isEmpty 跳过一致 */

      med = isp_median_u16(vals, n);
      /* 离群判定：整数差取绝对值后与 double 阈值比较（Dart 同式）。 */
      diff = (int)buf[i] - (int)med;
      if (diff < 0) diff = -diff;
      if ((double)diff <= thr) continue;

      if (mode == ISP_DPC_MEDIAN) {
        buf[i] = med;
        continue;
      }

      /* directional：四方向各取一对对称点，选 |va - vb| 最小（梯度最小）
       * 的一对，写两点平均（含半值向上）；四方向全越界时回退 med。 */
      {
        static const int kDirs[4][2] = {
            {1, 0},  /* 水平 */
            {0, 1},  /* 垂直 */
            {1, 1},  /* 主对角 */
            {1, -1}, /* 副对角 */
        };
        int best = -1;
        int best_diff = INT32_MAX; /* Dart 初值 1 << 62，int 域内等效 */
        for (int d = 0; d < 4; d++) {
          const int ax = x - kDirs[d][0] * step;
          const int ay = y - kDirs[d][1] * step;
          const int bx = x + kDirs[d][0] * step;
          const int by = y + kDirs[d][1] * step;
          int va, vb, ddiff;
          if (ax < 0 || ax >= width || ay < 0 || ay >= height) continue;
          if (bx < 0 || bx >= width || by < 0 || by >= height) continue;
          va = buf[ay * width + ax];
          vb = buf[by * width + bx];
          ddiff = va - vb;
          if (ddiff < 0) ddiff = -ddiff;
          if (ddiff < best_diff) {
            best_diff = ddiff;
            best = (va + vb + 1) >> 1;
          }
        }
        buf[i] = (best >= 0) ? (uint16_t)best : med;
      }
    }
  }
  return ISP_OK;
}
