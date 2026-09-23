/**
 * @file isp_fpn.c
 * @brief 行/列固定图案噪声校正（FPN）实现，对应 isp_kernels.dart `applyFpn`
 * 及私有 helper `_verticalBoxMean` / `_horizontalBoxMean` / `_gradientEdge`
 * / `_dilateMask` / `_clampedMedian`。
 */

#include "isp_fpn.h"

#include <math.h>
#include <string.h>

/**
 * @brief 垂直方向滑窗盒式均值（每列独立，窗口 [y-radius, y+radius] 截断）。
 *
 * Dart 来源：isp_kernels.dart `_verticalBoxMean`。
 * Dart 把 colSum/count（double 除法）存入 Float32List（窄化为 float32），
 * 使用时再 .round()；这里合并为「除法 -> 窄化 float32 -> 半值远离零舍入」
 * 直接得到 int32 低通，数值与 Dart 逐位一致（像素非负，round 等价
 * floor(f + 0.5)，f 为 float32 提升回的 double，精确无二次舍入）。
 */
static void isp_fpn_vbox_mean(const uint16_t *buf, int w, int h, int radius,
                              int32_t *low, int32_t *col_sum) {
  int x, y;
  int count = 0;

  for (x = 0; x < w; x++) col_sum[x] = 0;
  /* 初始窗口：行 0..min(radius, h-1) */
  for (y = 0; y <= radius && y < h; y++) {
    const uint16_t *row = buf + (size_t)y * (size_t)w;
    for (x = 0; x < w; x++) col_sum[x] += row[x];
    count++;
  }
  for (y = 0; y < h; y++) {
    const size_t base = (size_t)y * (size_t)w;
    const int add = y + radius + 1;
    const int del = y - radius;
    for (x = 0; x < w; x++) {
      const float f = (float)((double)col_sum[x] / (double)count);
      low[base + (size_t)x] = (int32_t)floor((double)f + 0.5);
    }
    if (add < h) {
      const uint16_t *arow = buf + (size_t)add * (size_t)w;
      for (x = 0; x < w; x++) col_sum[x] += arow[x];
      count++;
    }
    if (del >= 0) {
      const uint16_t *drow = buf + (size_t)del * (size_t)w;
      for (x = 0; x < w; x++) col_sum[x] -= drow[x];
      count--;
    }
  }
}

/**
 * @brief 水平方向滑窗盒式均值（每行独立，窗口 [x-radius, x+radius] 截断）。
 *
 * Dart 来源：isp_kernels.dart `_horizontalBoxMean`。舍入同垂直版。
 */
static void isp_fpn_hbox_mean(const uint16_t *buf, int w, int h, int radius,
                              int32_t *low) {
  int x, y;
  size_t row_base = 0;

  for (y = 0; y < h; y++, row_base += (size_t)w) {
    int sum = 0;
    int count = 0;
    for (x = 0; x <= radius && x < w; x++) {
      sum += buf[row_base + (size_t)x];
      count++;
    }
    for (x = 0; x < w; x++) {
      const int add = x + radius + 1;
      const int del = x - radius;
      const float f = (float)((double)sum / (double)count);
      low[row_base + (size_t)x] = (int32_t)floor((double)f + 0.5);
      if (add < w) {
        sum += buf[row_base + (size_t)add];
        count++;
      }
      if (del >= 0) {
        sum -= buf[row_base + (size_t)del];
        count--;
      }
    }
  }
}

/**
 * @brief 梯度边缘图：vertical 非 0 检测水平边缘（垂直方向梯度超过阈值）。
 *
 * Dart 来源：isp_kernels.dart `_gradientEdge`。
 * 梯度为 int 差取绝对值后提升 double 与 thresh 比较（像素 <= 65535，
 * 提升精确）；首末行/列不参与，恒为 0（Dart 靠 Uint8List 零初始化，
 * 这里显式 memset）。
 */
static void isp_fpn_gradient_edge(const uint16_t *buf, int w, int h,
                                  double thresh, int vertical, uint8_t *out) {
  int x, y;

  memset(out, 0, (size_t)w * (size_t)h);
  if (vertical) {
    for (y = 1; y < h - 1; y++) {
      const size_t base = (size_t)y * (size_t)w;
      for (x = 0; x < w; x++) {
        int diff = (int)buf[base + (size_t)w + (size_t)x] -
                   (int)buf[base - (size_t)w + (size_t)x];
        if (diff < 0) diff = -diff;
        if ((double)diff > thresh) out[base + (size_t)x] = 1;
      }
    }
  } else {
    for (y = 0; y < h; y++) {
      const size_t base = (size_t)y * (size_t)w;
      for (x = 1; x < w - 1; x++) {
        int diff = (int)buf[base + (size_t)x + 1] -
                   (int)buf[base + (size_t)x - 1];
        if (diff < 0) diff = -diff;
        if ((double)diff > thresh) out[base + (size_t)x] = 1;
      }
    }
  }
}

/**
 * @brief 边缘图按 radius 做滑窗膨胀（vertical 非 0 沿垂直方向）。
 *
 * Dart 来源：isp_kernels.dart `_dilateMask`。
 * 窗口 [i-radius, i+radius] 截断内计数 > 0 即置 1；垂直方向用逐列计数
 * 数组 col_cnt + 行优先遍历（与 Dart 同一滑窗过程），水平方向逐行滑窗。
 */
static void isp_fpn_dilate_mask(const uint8_t *edge, int w, int h, int radius,
                                int vertical, uint8_t *out, int32_t *col_cnt) {
  int x, y;

  if (vertical) {
    for (x = 0; x < w; x++) col_cnt[x] = 0;
    for (y = 0; y <= radius && y < h; y++) {
      const size_t base = (size_t)y * (size_t)w;
      for (x = 0; x < w; x++) col_cnt[x] += edge[base + (size_t)x];
    }
    for (y = 0; y < h; y++) {
      const size_t base = (size_t)y * (size_t)w;
      const int add = y + radius + 1;
      const int del = y - radius;
      for (x = 0; x < w; x++) {
        out[base + (size_t)x] = (uint8_t)(col_cnt[x] > 0 ? 1 : 0);
      }
      if (add < h) {
        const size_t ab = (size_t)add * (size_t)w;
        for (x = 0; x < w; x++) col_cnt[x] += edge[ab + (size_t)x];
      }
      if (del >= 0) {
        const size_t db = (size_t)del * (size_t)w;
        for (x = 0; x < w; x++) col_cnt[x] -= edge[db + (size_t)x];
      }
    }
  } else {
    size_t row_base = 0;
    for (y = 0; y < h; y++, row_base += (size_t)w) {
      int cnt = 0;
      for (x = 0; x <= radius && x < w; x++) cnt += edge[row_base + (size_t)x];
      for (x = 0; x < w; x++) {
        const int add = x + radius + 1;
        const int del = x - radius;
        out[row_base + (size_t)x] = (uint8_t)(cnt > 0 ? 1 : 0);
        if (add < w) cnt += edge[row_base + (size_t)add];
        if (del >= 0) cnt -= edge[row_base + (size_t)del];
      }
    }
  }
}

/**
 * @brief 取 int32 数组排序后第 k 项（0 基次序统计量，Hoare 式快选）。
 *
 * 等价于 Dart `_clampedMedian` 桶计数定位的「首个累计 > n>>1 的桶」
 * 对应的值（见 isp_fpn.h 第 5 条等价性说明）；会原地打乱 a 的顺序，
 * 但本文件里 a 只是残差收集缓冲，顺序无意义。
 */
static int32_t isp_fpn_kth(int32_t *a, int n, int k) {
  int lo = 0;
  int hi = n - 1;

  while (hi > lo) {
    int i = lo;
    int j = hi;
    const int32_t pivot = a[lo + ((hi - lo) >> 1)];
    do {
      while (a[i] < pivot) i++;
      while (a[j] > pivot) j--;
      if (i <= j) {
        const int32_t t = a[i];
        a[i] = a[j];
        a[j] = t;
        i++;
        j--;
      }
    } while (i <= j);
    if (j < k) lo = i;
    if (k < i) hi = j;
  }
  return a[k];
}

/**
 * @brief Dart `applyFpn` 的 clampCorr：限幅到 ±max_corr（double 比较）。
 */
ISP_INLINE double isp_fpn_clamp_corr(double c, double max_corr) {
  if (c < -max_corr) return -max_corr;
  if (c > max_corr) return max_corr;
  return c;
}

/**
 * @brief 对一个方向（行或列）内单行/单列做校正施加。
 *
 * Dart 来源：`applyFpn` 末尾的施加循环：`v = buf[i] - corr`（double），
 * `v <= 0 ? 0 : v.round()`，写入 Uint16List 模 2^16 截断。
 * v > 0 时 round 等价 floor(v + 0.5)（半值远离零，正值分支）。
 */
ISP_INLINE uint16_t isp_fpn_apply_corr(uint16_t pix, double corr) {
  const double v = (double)pix - corr;
  if (v <= 0.0) return 0;
  return (uint16_t)((int)floor(v + 0.5) & 0xFFFF);
}

int isp_fpn_apply(uint16_t *buf, int width, int height, int row_enable,
                  int col_enable, double max_corr, int radius, void *scratch,
                  size_t scratch_bytes) {
  const double edge_thresh = 2.0 * max_corr; /* 超过它的梯度视为内容边缘 */
  int32_t *low;
  int32_t *med;
  int32_t *col_acc;
  uint8_t *edge;
  uint8_t *mask;
  size_t wh;
  int x, y;

  if (buf == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (!(max_corr >= 0.0)) return ISP_ERR_ARG; /* 含 NaN；Dart 会抛异常 */
  if (radius < 0 || radius > 16383) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  /* Dart 首行：if (!row && !col) return; */
  if (!row_enable && !col_enable) return ISP_OK;

  wh = (size_t)width * (size_t)height;
  if (scratch_bytes < ISP_FPN_SCRATCH_BYTES(width, height)) {
    return ISP_ERR_SIZE;
  }

  /* 切分 scratch：int32 区在前保证 4 字节对齐 */
  low = (int32_t *)scratch;
  med = low + wh;
  col_acc = med + (size_t)(width > height ? width : height);
  edge = (uint8_t *)(col_acc + width);
  mask = edge + wh;

  if (row_enable) {
    /* 垂直低通分离内容：逐行 FPN 被平滑掉，竖条内容保留在低频里 */
    isp_fpn_vbox_mean(buf, width, height, radius, low, col_acc);
    /* 水平边缘（垂直梯度）的垂直膨胀掩膜：被污染像素不参与行统计 */
    isp_fpn_gradient_edge(buf, width, height, edge_thresh, 1, edge);
    isp_fpn_dilate_mask(edge, width, height, radius, 1, mask, col_acc);
    for (y = 0; y < height; y++) {
      const size_t base = (size_t)y * (size_t)width;
      int n = 0;
      double corr;
      for (x = 0; x < width; x++) {
        if (mask[base + (size_t)x] != 0) continue;
        med[n++] = (int32_t)buf[base + (size_t)x] - low[base + (size_t)x];
      }
      /* 残差行中位数即行偏移稳健估计，限幅 ±max_corr；n == 0 时
       * Dart `_clampedMedian` 返回 0，corr 为 0 同样跳过 */
      corr = (n == 0)
                 ? 0.0
                 : isp_fpn_clamp_corr(
                       (double)isp_fpn_kth(med, n, n >> 1), max_corr);
      if (corr == 0.0) continue;
      for (x = 0; x < width; x++) {
        buf[base + (size_t)x] = isp_fpn_apply_corr(buf[base + (size_t)x], corr);
      }
    }
  }

  if (col_enable) {
    /* 列方向在行校正后的画面上执行（与 Dart 顺序一致）。
     * Dart 的 64 列分块桶计数纯为缓存优化，逐列统计结果相同。 */
    isp_fpn_hbox_mean(buf, width, height, radius, low);
    isp_fpn_gradient_edge(buf, width, height, edge_thresh, 0, edge);
    isp_fpn_dilate_mask(edge, width, height, radius, 0, mask, col_acc);
    for (x = 0; x < width; x++) {
      int n = 0;
      double corr;
      for (y = 0; y < height; y++) {
        const size_t i = (size_t)y * (size_t)width + (size_t)x;
        if (mask[i] != 0) continue;
        med[n++] = (int32_t)buf[i] - low[i];
      }
      corr = (n == 0)
                 ? 0.0
                 : isp_fpn_clamp_corr(
                       (double)isp_fpn_kth(med, n, n >> 1), max_corr);
      if (corr == 0.0) continue;
      for (y = 0; y < height; y++) {
        const size_t i = (size_t)y * (size_t)width + (size_t)x;
        buf[i] = isp_fpn_apply_corr(buf[i], corr);
      }
    }
  }
  return ISP_OK;
}
