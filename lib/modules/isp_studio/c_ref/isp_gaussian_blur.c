#include "isp_gaussian_blur.h"

/**
 * @file isp_gaussian_blur.c
 * @brief ISP Studio C99 参考实现 —— 高斯模糊（节点 gaussian_blur）实现。
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyGaussianBlur`。契约与环形行缓冲设计见 isp_gaussian_blur.h 文件头。
 */

int isp_gaussian_blur_apply(uint16_t *data, int width, int height,
                            int channels, double sigma, double strength,
                            void *scratch) {
  if (data == NULL || scratch == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  if (channels < 1) return ISP_ERR_ARG;
  /* Dart 首行：if (strength <= 0 || sigma <= 0) return; —— 空操作。 */
  if (strength <= 0.0 || sigma <= 0.0) return ISP_OK;

  const int radius = (int)ceil(3.0 * sigma); /* Dart: (3 * sigma).ceil() */
  const int k_len = 2 * radius + 1;
  const int row_stride = width * channels; /* 每行元素数（含通道交织） */

  /* scratch 布局：前 kLen 个 double 为权重核，其后为环形行缓冲。 */
  double *kernel = (double *)scratch;
  double *ring = kernel + k_len;

  /* 高斯权重：v = exp(-(i*i) / (2σ²))，i 从 -radius 到 radius 升序；
   * Dart 中 -(i*i) 为整数取负后转 double 做除法，2*σ*σ 左结合，
   * 此处保持完全相同的运算次序。 */
  double k_sum = 0.0;
  for (int i = -radius; i <= radius; i++) {
    const double v = exp(-(double)(i * i) / (2.0 * sigma * sigma));
    kernel[i + radius] = v;
    k_sum += v;
  }
  for (int i = 0; i < k_len; i++) {
    kernel[i] /= k_sum;
  }

  /* next_row：环形缓冲中已完成水平趟的行（0 .. next_row-1 就绪）。
   * 输出行 y 的垂直窗口上沿为 y1，处理到 y 时按需把水平趟推进到 y1。
   * 由于 y 单调递增且水平行值是原始输入行的纯函数，惰性计算与 Dart
   * 先算整帧 tmp 的结果逐位一致；行 r 的水平值在输出行 r 被写回之前
   * 就已算好（r <= y + radius 时即被计算），不会读到被覆盖的数据。
   * 窗口内行数 <= kLen，行号 mod kLen 取槽位互不冲突。 */
  int next_row = 0;
  for (int y = 0; y < height; y++) {
    const int y0 = y - radius < 0 ? 0 : y - radius;
    const int y1 = y + radius >= height ? height - 1 : y + radius;

    /* 水平趟（惰性，逐行）：data 第 next_row 行 → ring 对应槽位。
     * 窗口 [x0, x1] 钳位到图内，tap 下标越界时钳回窗口端点（边界复制）。 */
    for (; next_row <= y1; next_row++) {
      const uint16_t *src = data + (size_t)next_row * (size_t)row_stride;
      double *dst = ring + (size_t)(next_row % k_len) * (size_t)row_stride;
      for (int x = 0; x < width; x++) {
        const int x0 = x - radius < 0 ? 0 : x - radius;
        const int x1 = x + radius >= width ? width - 1 : x + radius;
        for (int c = 0; c < channels; c++) {
          double acc = 0.0;
          for (int k = 0; k < k_len; k++) {
            int xx = x + k - radius;
            if (xx < x0) {
              xx = x0;
            } else if (xx > x1) {
              xx = x1;
            }
            acc += (double)src[xx * channels + c] * kernel[k];
          }
          dst[x * channels + c] = acc;
        }
      }
    }

    /* 垂直趟：ring 内按 k 升序累加（与 Dart 读取 tmp 的顺序一致），
     * 随后强度混合并写回。Dart: (orig + (acc - orig) * strength).round()，
     * round() 半程远离零，与 C round() 一致；Dart 写回 Uint16List 按
     * mod 2^16 截断，(uint16_t) 转换同义，故无需显式钳位。 */
    for (int x = 0; x < width; x++) {
      for (int c = 0; c < channels; c++) {
        double acc = 0.0;
        for (int k = 0; k < k_len; k++) {
          int yy = y + k - radius;
          if (yy < y0) {
            yy = y0;
          } else if (yy > y1) {
            yy = y1;
          }
          acc += ring[(size_t)(yy % k_len) * (size_t)row_stride +
                      (size_t)(x * channels + c)] * kernel[k];
        }
        {
          const size_t i = ((size_t)y * (size_t)width + (size_t)x) *
                               (size_t)channels + (size_t)c;
          const double orig = (double)data[i];
          data[i] = (uint16_t)(int)round(orig + (acc - orig) * strength);
        }
      }
    }
  }
  return ISP_OK;
}
