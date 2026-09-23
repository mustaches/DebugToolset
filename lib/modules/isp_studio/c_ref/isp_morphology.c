#include "isp_morphology.h"

/**
 * @file isp_morphology.c
 * @brief ISP Studio C99 参考实现 —— 形态学腐蚀/膨胀（节点 morphology）实现。
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyMorphology`。契约与环形行缓冲设计见 isp_morphology.h 文件头。
 */

int isp_morphology_apply(uint16_t *data, int width, int height,
                         int channels, bool erode, int radius,
                         uint16_t *scratch) {
  if (data == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  if (channels < 1) return ISP_ERR_ARG;
  /* Dart 首行：if (radius <= 0) return; —— 空操作。 */
  if (radius <= 0) return ISP_OK;

  const int k_len = 2 * radius + 1;
  const int row_stride = width * channels; /* 每行元素数（含通道交织） */
  uint16_t *ring = scratch;

  /* next_row：环形缓冲中已完成水平趟的行（0 .. next_row-1 就绪）。
   * 惰性推进机制与 isp_gaussian_blur_apply 相同：水平行值是原始输入行
   * 的纯函数，且在输出行 r 被写回之前行 r 的水平值必然已算好；窗口内
   * 行数 <= kLen，行号 mod kLen 取槽位互不冲突。极值为整数运算，
   * 结果与 Dart 整帧 tmp 逐位一致。 */
  int next_row = 0;
  for (int y = 0; y < height; y++) {
    const int y0 = y - radius < 0 ? 0 : y - radius;
    const int y1 = y + radius >= height ? height - 1 : y + radius;

    /* 水平趟（惰性，逐行）：窗口 [x0, x1] 裁剪到图内，按可用邻域取
     * 极值（非边界复制）。初值取窗口首元素，比较为严格小于/大于，
     * 与 Dart 的 erode ? u < v : u > v 一致。 */
    for (; next_row <= y1; next_row++) {
      const uint16_t *src = data + (size_t)next_row * (size_t)row_stride;
      uint16_t *dst = ring + (size_t)(next_row % k_len) * (size_t)row_stride;
      for (int x = 0; x < width; x++) {
        const int x0 = x - radius < 0 ? 0 : x - radius;
        const int x1 = x + radius >= width ? width - 1 : x + radius;
        for (int c = 0; c < channels; c++) {
          uint16_t v = src[x0 * channels + c];
          for (int nx = x0 + 1; nx <= x1; nx++) {
            const uint16_t u = src[nx * channels + c];
            if (erode ? u < v : u > v) v = u;
          }
          dst[x * channels + c] = v;
        }
      }
    }

    /* 垂直趟：对水平趟结果按列在窗口 [y0, y1] 内取同种极值并写回。
     * 极值取自原数据，必然在有效范围内，无需钳位。 */
    for (int x = 0; x < width; x++) {
      for (int c = 0; c < channels; c++) {
        uint16_t v = ring[(size_t)(y0 % k_len) * (size_t)row_stride +
                          (size_t)(x * channels + c)];
        for (int ny = y0 + 1; ny <= y1; ny++) {
          const uint16_t u = ring[(size_t)(ny % k_len) * (size_t)row_stride +
                                  (size_t)(x * channels + c)];
          if (erode ? u < v : u > v) v = u;
        }
        data[((size_t)y * (size_t)width + (size_t)x) * (size_t)channels +
             (size_t)c] = v;
      }
    }
  }
  return ISP_OK;
}
