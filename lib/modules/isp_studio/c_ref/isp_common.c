#include "isp_common.h"

/**
 * @file isp_common.c
 * @brief ISP Studio C99 参考实现 —— 公共基础层的小数组工具实现。
 *
 * 覆盖范围（均为各算法 kernel 共享的公共 helper）：
 * - isp_sort_u16        升序插入排序（Dart `_sortedValues` 的 ..sort()）
 * - isp_median_u16      排序取上中位（Dart `vals[vals.length ~/ 2]`）
 * - isp_phase_neighbors Bayer 同相位 / mono 全像素 3x3 邻域收集
 *                       （Dart `_phaseNeighbors` + 取值步骤的融合）
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart。
 * 规范要点速览见 isp_common.h 文件头注释。
 */

void isp_sort_u16(uint16_t *vals, int n) {
  /* 插入排序：邻域规模最多 8~24 个元素，插入排序在此规模下比较/移动
   * 次数最少，且无递归栈风险。稳定性对本项目无影响（元素为纯数值）。 */
  if (vals == NULL || n <= 1) return;
  for (int i = 1; i < n; i++) {
    const uint16_t key = vals[i];
    int j = i - 1;
    /* 把比 key 大的元素逐个右移，腾出插入位置。 */
    while (j >= 0 && vals[j] > key) {
      vals[j + 1] = vals[j];
      j--;
    }
    vals[j + 1] = key;
  }
}

uint16_t isp_median_u16(uint16_t *vals, int n) {
  /* Dart 取法为 vals[vals.length ~/ 2]：偶数长度时取上中位（0 基第 n/2
   * 项），不做两中值平均。此处保持一致以保证逐位一致。 */
  if (vals == NULL || n <= 0) return 0;
  isp_sort_u16(vals, n);
  return vals[n / 2];
}

int isp_phase_neighbors(const uint16_t *buf, int w, int h, int x, int y,
                        const IspBayerPattern *pattern, uint16_t *out) {
  /* Dart `_phaseNeighbors`：step = pattern == null ? 1 : 2；
   * dy 外层、dx 内层按行优先枚举 3x3，跳过中心 (0,0)，越界裁剪。 */
  const int step = (pattern == NULL) ? 1 : 2;
  int count = 0;
  if (buf == NULL || out == NULL) return 0;
  for (int dy = -step; dy <= step; dy += step) {
    for (int dx = -step; dx <= step; dx += step) {
      const int nx = x + dx;
      const int ny = y + dy;
      if (dx == 0 && dy == 0) continue;
      if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
      out[count++] = buf[ny * w + nx];
    }
  }
  return count;
}
