/**
 * @file isp_ccm.c
 * @brief 色彩校正矩阵节点实现。Dart 来源：isp_kernels.dart `applyCcm`。
 *        详见头文件注释。
 */

#include "isp_ccm.h"

#include <math.h>

/**
 * @brief 将 int64 值钳位到 [0, max_value] 后转为 uint16_t（本文件私有）。
 *
 * 语义同 isp_common.h 的 isp_clamp_u16，但输入域为 int64：CCM 的定点
 * 乘加结果在 64 位域（Dart int 为 64 位），极端矩阵下可超出 int32，
 * 必须在 64 位域先钳位再窄化，才能与 Dart 逐位一致。
 */
ISP_INLINE uint16_t isp_ccm_clamp_i64_(int64_t v, int max_value) {
  if (v < 0) return 0;
  if (v > (int64_t)max_value) return (uint16_t)max_value;
  return (uint16_t)v;
}

int isp_ccm_apply(uint16_t *rgb, int w, int h, const double *matrix,
                  int max_value) {
  /* Dart: scale = 1 << 20; half = scale >> 1; */
  enum { kScale = 1 << 20, kHalf = kScale >> 1 };
  const int64_t pixels = (int64_t)w * (int64_t)h;
  int64_t m[9];
  int i;
  int64_t p;
  bool is_identity = true;

  if (rgb == NULL || matrix == NULL) return ISP_ERR_ARG;
  if (w < 0 || h < 0) return ISP_ERR_SIZE;
  if (max_value < 0) return ISP_ERR_ARG;

  /*
   * Dart: m = [for (x in matrix) (x * scale).round()]
   * double.round() 四舍五入、0.5 远离零，与 C99 llround 一致；
   * 定点系数本身用 int64 保存（Dart int 为 64 位）。
   */
  for (i = 0; i < 9; i++) {
    m[i] = (int64_t)llround(matrix[i] * (double)kScale);
  }

  /*
   * Dart: 单位矩阵在定点表示下精确判断（对角为 scale、其余为 0），
   * 注意 i % 4 == 0 恰好选中行主序 3x3 的对角元（0、4、8）。
   */
  for (i = 0; i < 9; i++) {
    if (m[i] != (i % 4 == 0 ? (int64_t)kScale : 0)) {
      is_identity = false;
      break;
    }
  }
  if (is_identity) return ISP_OK;

  /*
   * 每像素 3x3 定点乘加：先读出 r/g/b（原地写回前必须读完），
   * 加 half 实现 Dart `+ half) >> 20` 的四舍五入；>> 20 为算术右移，
   * 对负中间值等价于向下取整（与 Dart int 的 >> 一致；MSVC/GCC/Clang
   * 对有符号右移均为算术移位，嵌入式主流工具链同）。
   */
  for (p = 0; p < pixels; p++) {
    const int64_t idx = p * 3;
    const int64_t r = rgb[idx];
    const int64_t g = rgb[idx + 1];
    const int64_t b = rgb[idx + 2];
    const int64_t nr = (m[0] * r + m[1] * g + m[2] * b + kHalf) >> 20;
    const int64_t ng = (m[3] * r + m[4] * g + m[5] * b + kHalf) >> 20;
    const int64_t nb = (m[6] * r + m[7] * g + m[8] * b + kHalf) >> 20;
    rgb[idx] = isp_ccm_clamp_i64_(nr, max_value);
    rgb[idx + 1] = isp_ccm_clamp_i64_(ng, max_value);
    rgb[idx + 2] = isp_ccm_clamp_i64_(nb, max_value);
  }
  return ISP_OK;
}
